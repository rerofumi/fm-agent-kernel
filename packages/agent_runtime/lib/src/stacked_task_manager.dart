import 'dart:async';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

/// Manages Kanban-aligned Stacked Changes task trees (`c_A -> c_B -> ...`),
/// isolated `ws-task-<taskId>` workspaces, and topological `update-stale` cascades ([D-311]).
class StackedTaskManager {
  StackedTaskManager({
    required this.jjDriver,
    StackedTaskRegistry? registry,
  }) : registry = registry ?? StackedTaskRegistry() {
    jjDriver.stackedTaskRegistry = this.registry;
  }

  final JjDriver jjDriver;
  final StackedTaskRegistry registry;

  int _taskSeq = 0;

  /// Creates a new stacked task node and its isolated `--no-colocate` `jj workspace` (`action: "create"`).
  Future<SyscallResult<Map<String, dynamic>>> createTask({
    String? taskId,
    required String title,
    String description = '',
    String? parentTaskId,
    String? baseChangeId,
    String? model,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message: 'Argument "title" must be a non-empty string.',
          recoverable: true,
        ),
      );
    }

    String? normalizedModel;
    if (model != null && model.trim().isNotEmpty) {
      final parsedModel = ModelIdentifier.parse(model.trim());
      if (!parsedModel.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(parsedModel.error!);
      }
      normalizedModel = parsedModel.value!.canonicalId;
    }

    late final String effectiveTaskId;
    if (taskId != null && taskId.trim().isNotEmpty) {
      effectiveTaskId = taskId.trim();
      if (!StackedTaskRegistry.validTaskIdPattern.hasMatch(effectiveTaskId)) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_TASK_ID',
            message:
                'Invalid taskId "$effectiveTaskId": must match [a-zA-Z0-9_-]{1,48}.',
            recoverable: true,
          ),
        );
      }
      if (registry.getByTaskId(effectiveTaskId) != null) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eexist,
            reason: 'TASK_ALREADY_EXISTS',
            message: 'Task "$effectiveTaskId" is already registered.',
            recoverable: true,
          ),
        );
      }
    } else {
      do {
        _taskSeq += 1;
        effectiveTaskId = 'task_${_taskSeq.toString().padLeft(2, '0')}';
      } while (registry.getByTaskId(effectiveTaskId) != null);
    }

    String? effectiveParentTaskId;
    String? effectiveBase =
        (baseChangeId != null && baseChangeId.trim().isNotEmpty)
            ? baseChangeId.trim()
            : null;
    if (parentTaskId != null && parentTaskId.trim().isNotEmpty) {
      effectiveParentTaskId = parentTaskId.trim();
      final parentNode = registry.getByTaskId(effectiveParentTaskId);
      if (parentNode == null) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'TASK_NOT_FOUND',
            message: 'Parent task "$effectiveParentTaskId" was not found.',
            recoverable: true,
          ),
        );
      }
      effectiveBase = parentNode.workingChangeId;
    }

    final allocRes = await jjDriver.allocateTaskWorkspace(
      taskId: effectiveTaskId,
      baseChangeId: effectiveBase,
      description: 'task($effectiveTaskId): $trimmedTitle',
    );
    if (!allocRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(allocRes.error!);
    }
    final ws = allocRes.value!;

    // Resolve Pub Workspaces dependencies offline when pubspec.yaml exists ([D-307], OM-301).
    final pubspecFile = File(p.join(ws.workspaceRoot, 'pubspec.yaml'));
    if (pubspecFile.existsSync()) {
      try {
        final pubRes = await Process.run(
          'dart',
          const <String>['pub', 'get', '--offline'],
          workingDirectory: ws.workspaceRoot,
          runInShell: false,
          environment: Win32JobExecDriver.buildSanitizedEnvironment(),
        ).timeout(const Duration(seconds: 60));
        if (pubRes.exitCode != 0) {
          await jjDriver.removeTaskWorkspace(
            workspaceName: ws.workspaceName,
            workspaceRoot: ws.workspaceRoot,
            workingChangeId: ws.workingChangeId,
            abandonChange: true,
          );
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'PUB_GET_OFFLINE_FAILED',
              message:
                  'dart pub get --offline failed in ${ws.workspaceRoot} (exit=${pubRes.exitCode}): ${pubRes.stderr}',
              recoverable: true,
            ),
          );
        }
      } on Object catch (e) {
        await jjDriver.removeTaskWorkspace(
          workspaceName: ws.workspaceName,
          workspaceRoot: ws.workspaceRoot,
          workingChangeId: ws.workingChangeId,
          abandonChange: true,
        );
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'PUB_GET_OFFLINE_FAILED',
            message: 'dart pub get --offline threw error: $e',
            recoverable: true,
          ),
        );
      }
    }

    final node = StackedTaskNode(
      taskId: effectiveTaskId,
      title: trimmedTitle,
      description: description,
      parentTaskId: effectiveParentTaskId,
      baseChangeId: ws.baseChangeId,
      workingChangeId: ws.workingChangeId,
      commitId: ws.commitId,
      workspaceName: ws.workspaceName,
      workspaceRoot: ws.workspaceRoot,
      assignedModel: normalizedModel,
      lastSyncedOpId: ws.currentOpId.isEmpty ? null : ws.currentOpId,
    );

    final regRes = registry.register(node);
    if (!regRes.ok) {
      await jjDriver.removeTaskWorkspace(
        workspaceName: ws.workspaceName,
        workspaceRoot: ws.workspaceRoot,
        workingChangeId: ws.workingChangeId,
        abandonChange: true,
      );
      return SyscallResult<Map<String, dynamic>>.failure(regRes.error!);
    }

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'action': 'create',
      'task': node.toJson(),
      'jjOpId': ws.currentOpId,
    });
  }

  /// Lists all registered stacked tasks with non-destructively refreshed commit & conflict metadata (`action: "list"`).
  Future<SyscallResult<Map<String, dynamic>>> listTasks() async {
    for (final node in registry.allTasks) {
      final metaRes = await jjDriver.inspectTaskNodeMetadata(taskNode: node);
      if (!metaRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(metaRes.error!);
      }
    }
    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'action': 'list',
      'tasks':
          registry.allTasks.map((n) => n.toJson()).toList(growable: false),
    });
  }

  /// Focuses a task, optionally updating `state` or `assignedModel`, and returns its non-destructive diff (`action: "focus"`).
  Future<SyscallResult<Map<String, dynamic>>> focusTask({
    required String taskId,
    String? state,
    String? model,
  }) async {
    final node = registry.getByTaskId(taskId);
    if (node == null) {
      return SyscallResult<Map<String, dynamic>>.failure(
        _taskNotFoundError(taskId),
      );
    }

    if (state != null && state.trim().isNotEmpty) {
      final parsedState = StackedTaskState.tryParse(state);
      if (parsedState == null) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_TASK_STATE',
            message: 'Unknown StackedTaskState "$state".',
            recoverable: true,
          ),
        );
      }
      node.state = parsedState;
    }

    if (model != null && model.trim().isNotEmpty) {
      final parsedModel = ModelIdentifier.parse(model.trim());
      if (!parsedModel.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(parsedModel.error!);
      }
      node.assignedModel = parsedModel.value!.canonicalId;
    }

    final metaRes = await jjDriver.inspectTaskNodeMetadata(taskNode: node);
    if (!metaRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(metaRes.error!);
    }

    final diffRes = await jjDriver.diffForTask(taskNode: node);
    if (!diffRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(diffRes.error!);
    }

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'action': 'focus',
      'task': node.toJson(),
      'diff': diffRes.value!,
    });
  }

  /// Edits a file inside a task's workspace with VFS boundary + optional CAS check,
  /// then immediately snapshots and cascades `update-stale` to all descendants (`action: "edit"`).
  Future<SyscallResult<Map<String, dynamic>>> editTaskFile({
    required String taskId,
    required String relativePath,
    required String content,
    String? expectedSha256,
  }) async {
    final node = registry.getByTaskId(taskId);
    if (node == null) {
      return SyscallResult<Map<String, dynamic>>.failure(
        _taskNotFoundError(taskId),
      );
    }

    final cleanRel = relativePath.replaceAll('\\', '/').trim();
    if (cleanRel.isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message: 'Argument "relativePath" must be a non-empty path.',
          recoverable: true,
        ),
      );
    }
    final virtualPath =
        cleanRel.startsWith('/workspace/') ? cleanRel : '/workspace/$cleanRel';

    final taskNs = VfsNamespace(workspaceHostRoot: node.workspaceRoot);
    final fsDriver = HostFsDriver(namespace: taskNs);
    final writeRes = await fsDriver.writeFile(
      path: virtualPath,
      content: content,
      expectedSha256: expectedSha256,
      namespaceOverride: taskNs,
    );
    if (!writeRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(writeRes.error!);
    }

    final descendants = registry.descendantsInTopologicalOrder(taskId);
    final syncRes = await jjDriver.syncTaskWorkspaceAndCascade(
      taskNode: node,
      descendants: descendants,
    );
    if (!syncRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(syncRes.error!);
    }

    final payload = syncRes.value!;
    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'action': 'edit',
      'task': node.toJson(),
      'cascadedTasks':
          payload.cascaded.map((c) => c.toJson()).toList(growable: false),
      'jjOpId': payload.opId,
    });
  }

  /// Integrates completed worker Change IDs into [taskId]'s change and cascades `update-stale` (`action: "integrate_worker"`).
  Future<SyscallResult<Map<String, dynamic>>> integrateWorker({
    required String taskId,
    required List<String> workerChangeIds,
    bool abandonWorkerChanges = true,
  }) async {
    final node = registry.getByTaskId(taskId);
    if (node == null) {
      return SyscallResult<Map<String, dynamic>>.failure(
        _taskNotFoundError(taskId),
      );
    }

    final descendants = registry.descendantsInTopologicalOrder(taskId);
    final intRes = await jjDriver.integrateWorkerChangesIntoTask(
      taskNode: node,
      workerChangeIds: workerChangeIds,
      abandonWorkerChanges: abandonWorkerChanges,
      descendants: descendants,
    );
    if (!intRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(intRes.error!);
    }

    final payload = intRes.value!;
    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'action': 'integrate_worker',
      'task': node.toJson(),
      'cascadedTasks':
          payload.cascaded.map((c) => c.toJson()).toList(growable: false),
      'hasConflicts': node.hasConflicts,
      'conflictedFiles': List<String>.from(node.conflictedFiles),
      'jjOpId': payload.opId,
    });
  }

  /// Snapshots [taskId] (or all root tasks when omitted) and cascades `update-stale` (`action: "sync"`).
  Future<SyscallResult<Map<String, dynamic>>> syncTasks({
    String? taskId,
  }) async {
    final allCascaded = <Map<String, dynamic>>[];
    var latestOpId = '';

    if (taskId != null && taskId.trim().isNotEmpty) {
      final id = taskId.trim();
      final node = registry.getByTaskId(id);
      if (node == null) {
        return SyscallResult<Map<String, dynamic>>.failure(
          _taskNotFoundError(id),
        );
      }
      final descendants = registry.descendantsInTopologicalOrder(id);
      final syncRes = await jjDriver.syncTaskWorkspaceAndCascade(
        taskNode: node,
        descendants: descendants,
      );
      if (!syncRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(syncRes.error!);
      }
      allCascaded.addAll(syncRes.value!.cascaded.map((c) => c.toJson()));
      latestOpId = syncRes.value!.opId;
    } else {
      for (final root in registry.rootTasks) {
        final descendants = registry.descendantsInTopologicalOrder(root.taskId);
        final syncRes = await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: root,
          descendants: descendants,
        );
        if (!syncRes.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(syncRes.error!);
        }
        allCascaded.addAll(syncRes.value!.cascaded.map((c) => c.toJson()));
        if (syncRes.value!.opId.isNotEmpty) {
          latestOpId = syncRes.value!.opId;
        }
      }
    }

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'action': 'sync',
      'updatedTask': taskId?.trim(),
      'tasks':
          registry.allTasks.map((n) => n.toJson()).toList(growable: false),
      'cascadedTasks': allCascaded,
      'jjOpId': latestOpId,
    });
  }

  /// Removes a leaf stacked task and cleans up its workspace (`action: "remove"`).
  Future<SyscallResult<Map<String, dynamic>>> removeTask({
    required String taskId,
    bool abandonChange = false,
  }) async {
    final remRes = registry.remove(taskId);
    if (!remRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(remRes.error!);
    }
    final node = remRes.value!;
    final cleanup = await jjDriver.removeTaskWorkspace(
      workspaceName: node.workspaceName,
      workspaceRoot: node.workspaceRoot,
      workingChangeId: node.workingChangeId,
      abandonChange: abandonChange,
    );
    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'action': 'remove',
      'removedTaskId': taskId,
      'workspaceCleanedUp': cleanup.cleanedUp,
      'jjOpId': cleanup.opId,
    });
  }

  /// Cleans up all registered task workspaces on session disposal ([D-311]).
  Future<void> dispose() async {
    final nodes = registry.allTasks.reversed.toList(growable: false);
    for (final node in nodes) {
      await jjDriver.removeTaskWorkspace(
        workspaceName: node.workspaceName,
        workspaceRoot: node.workspaceRoot,
        workingChangeId: node.workingChangeId,
        abandonChange: false,
      );
    }
  }

  /// Builds the Ring 2 `sys_task_stack` [SyscallDefinition] ([D-302], [D-311]).
  SyscallDefinition buildSyscallDefinition() {
    return SyscallDefinition(
      name: 'sys_task_stack',
      requiredRight: CapRight.vcsTx,
      kind: 'other',
      applyIoCap: true,
      cappedTextFields: const <String>['diff'],
      validateArgs: _validateTaskStackArgs,
      evaluatePolicy: (_, _) async => RingDecision.allow,
      resultSummaryBuilder: (args, result) {
        if (!result.ok || result.value == null) {
          return null;
        }
        final v = result.value!;
        final taskMap = v['task'];
        final cascaded = v['cascadedTasks'];
        return <String, dynamic>{
          'action': v['action'],
          'taskId': taskMap is Map
              ? taskMap['taskId']
              : (v['removedTaskId'] ?? v['updatedTask'] ?? args['taskId']),
          'workingChangeId':
              taskMap is Map ? taskMap['workingChangeId'] : null,
          'cascadedCount': cascaded is List ? cascaded.length : 0,
        };
      },
      handler: (exec) async {
        final action = (exec.args['action'] as String).trim();
        switch (action) {
          case 'create':
            return createTask(
              taskId: exec.args['taskId'] as String?,
              title: exec.args['title'] as String,
              description: (exec.args['description'] as String?) ?? '',
              parentTaskId: exec.args['parentTaskId'] as String?,
              baseChangeId: exec.args['baseChangeId'] as String?,
              model: exec.args['model'] as String?,
            );
          case 'list':
            return listTasks();
          case 'focus':
            return focusTask(
              taskId: (exec.args['taskId'] as String).trim(),
              state: exec.args['state'] as String?,
              model: exec.args['model'] as String?,
            );
          case 'edit':
            return editTaskFile(
              taskId: (exec.args['taskId'] as String).trim(),
              relativePath: exec.args['relativePath'] as String,
              content: exec.args['content'] as String,
              expectedSha256: exec.args['expectedSha256'] as String?,
            );
          case 'integrate_worker':
            return integrateWorker(
              taskId: (exec.args['taskId'] as String).trim(),
              workerChangeIds:
                  (exec.args['workerChangeIds'] as List<dynamic>).cast<String>(),
              abandonWorkerChanges:
                  (exec.args['abandonWorkerChanges'] as bool?) ?? true,
            );
          case 'sync':
            return syncTasks(taskId: exec.args['taskId'] as String?);
          case 'remove':
            return removeTask(
              taskId: (exec.args['taskId'] as String).trim(),
              abandonChange: (exec.args['abandonChange'] as bool?) ?? false,
            );
          default:
            return SyscallResult<Map<String, dynamic>>.failure(
              SyscallError(
                code: SyscallErrorCode.einval,
                reason: 'INVALID_STACK_ACTION',
                message: 'Unsupported sys_task_stack action "$action".',
                recoverable: true,
              ),
            );
        }
      },
    );
  }

  /// Canonical tool schema for `sys_task_stack` ([D-311]).
  static SyscallToolSchema buildToolSchema() {
    return SyscallToolSchema(
      name: 'sys_task_stack',
      description:
          'Manage Stacked Changes task trees (create, list, focus, edit, integrate_worker, sync, remove) with automatic rebase and workspace update-stale cascading.',
      parametersJsonSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'action': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'create',
              'list',
              'focus',
              'edit',
              'integrate_worker',
              'sync',
              'remove',
            ],
            'description': 'Stacked Changes operation to perform.',
          },
          'taskId': <String, dynamic>{
            'type': 'string',
            'description': 'Task identifier ([a-zA-Z0-9_-]{1,48}).',
          },
          'title': <String, dynamic>{
            'type': 'string',
            'description': 'Task title (required for "create").',
          },
          'description': <String, dynamic>{
            'type': 'string',
            'description': 'Optional task description for "create".',
          },
          'parentTaskId': <String, dynamic>{
            'type': 'string',
            'description':
                'Optional parent taskId whose workingChangeId becomes the base for "create".',
          },
          'baseChangeId': <String, dynamic>{
            'type': 'string',
            'description': 'Optional explicit base Change ID for "create".',
          },
          'model': <String, dynamic>{
            'type': 'string',
            'description': 'Optional "<providerId>/<modelName>" for "create" or "focus".',
          },
          'state': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'todo',
              'running',
              'paused',
              'conflict',
              'review',
              'done',
              'failed',
            ],
            'description': 'Optional StackedTaskState update for "focus".',
          },
          'relativePath': <String, dynamic>{
            'type': 'string',
            'description': 'Workspace-relative path to write for "edit".',
          },
          'content': <String, dynamic>{
            'type': 'string',
            'description': 'UTF-8 file content to write for "edit".',
          },
          'expectedSha256': <String, dynamic>{
            'type': 'string',
            'description': 'Optional CAS SHA-256 guard for "edit".',
          },
          'workerChangeIds': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
            'description':
                'Worker Change IDs to integrate into taskId for "integrate_worker".',
          },
          'abandonWorkerChanges': <String, dynamic>{
            'type': 'boolean',
            'description':
                'Whether to abandon integrated worker changes (default true).',
          },
          'abandonChange': <String, dynamic>{
            'type': 'boolean',
            'description':
                'Whether to abandon the task change on "remove" (default false).',
          },
        },
        'required': <String>['action'],
      },
    );
  }

  static SyscallError? _validateTaskStackArgs(Map<String, dynamic> args) {
    final rawAction = args['action'];
    if (rawAction is! String || rawAction.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_STACK_ACTION',
        message: 'Argument "action" must be a non-empty string.',
        recoverable: true,
      );
    }
    final action = rawAction.trim();
    const validActions = <String>{
      'create',
      'list',
      'focus',
      'edit',
      'integrate_worker',
      'sync',
      'remove',
    };
    if (!validActions.contains(action)) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_STACK_ACTION',
        message:
            'Unknown sys_task_stack action "$action". Must be one of: ${validActions.join(', ')}.',
        recoverable: true,
      );
    }

    switch (action) {
      case 'create':
        final title = args['title'];
        if (title is! String || title.trim().isEmpty) {
          return const SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_ARGS',
            message: 'Action "create" requires a non-empty "title" string.',
            recoverable: true,
          );
        }
      case 'focus':
      case 'remove':
        final taskId = args['taskId'];
        if (taskId is! String || taskId.trim().isEmpty) {
          return SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_ARGS',
            message: 'Action "$action" requires a non-empty "taskId" string.',
            recoverable: true,
          );
        }
      case 'edit':
        final taskId = args['taskId'];
        final relativePath = args['relativePath'];
        final content = args['content'];
        if (taskId is! String ||
            taskId.trim().isEmpty ||
            relativePath is! String ||
            relativePath.trim().isEmpty ||
            content is! String) {
          return const SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_ARGS',
            message:
                'Action "edit" requires "taskId", "relativePath", and "content" strings.',
            recoverable: true,
          );
        }
      case 'integrate_worker':
        final taskId = args['taskId'];
        final workerChangeIds = args['workerChangeIds'];
        if (taskId is! String ||
            taskId.trim().isEmpty ||
            workerChangeIds is! List ||
            workerChangeIds.isEmpty ||
            workerChangeIds.any((e) => e is! String)) {
          return const SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_ARGS',
            message:
                'Action "integrate_worker" requires "taskId" and non-empty string list "workerChangeIds".',
            recoverable: true,
          );
        }
      case 'list':
      case 'sync':
        break;
    }
    return null;
  }

  static SyscallError _taskNotFoundError(String taskId) => SyscallError(
        code: SyscallErrorCode.enoent,
        reason: 'TASK_NOT_FOUND',
        message: 'Stacked task "$taskId" was not found.',
        recoverable: true,
      );
}
