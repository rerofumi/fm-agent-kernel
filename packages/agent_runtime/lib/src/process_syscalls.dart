import 'package:agent_kernel/agent_kernel.dart';

import 'isolate_worker_host.dart';

/// Standard mapping from Stage 1 / Stage 2 syscall names to their required [CapRight] ([D-202], [D-213]).
const Map<String, CapRight> defaultSyscallRequiredRights = <String, CapRight>{
  'sys_read_lines': CapRight.read,
  'sys_glob': CapRight.read,
  'sys_grep': CapRight.read,
  'sys_edit_block': CapRight.writeCow,
  'sys_write_file': CapRight.writeCow,
  'sys_jj_status': CapRight.vcsRead,
  'sys_jj_log': CapRight.vcsRead,
  'sys_jj_diff': CapRight.vcsRead,
  'sys_jj_conflicts': CapRight.vcsRead,
  'sys_jj_merge': CapRight.vcsTx,
  'sys_jj_integrate': CapRight.vcsTx,
  'sys_tx_begin': CapRight.vcsTx,
  'sys_tx_describe': CapRight.vcsTx,
  'sys_tx_squash': CapRight.vcsTx,
  'sys_tx_rollback': CapRight.vcsTx,
  'sys_exec': CapRight.exec,
  'sys_llm_chat': CapRight.llmInfer,
  'sys_mem_pagein': CapRight.memManage,
  'sys_spawn': CapRight.procSpawn,
  'sys_wait': CapRight.procSpawn,
  'sys_kill': CapRight.procSpawn,
  'sys_task_stack': CapRight.vcsTx,
  'sys_exit': CapRight.procSelf,
  'sys_send': CapRight.ipc,
  'sys_recv': CapRight.ipc,
  'sys_web_search': CapRight.netRead,
  'sys_web_fetch': CapRight.netRead,
  'sys_skill_list': CapRight.read,
  'sys_skill_read': CapRight.read,
};

/// Exact 5-tool allowlist permitted for the sterile Ring 3 `WebResearcher` profile ([D-218]).
const Set<String> webResearcherAllowedToolNames = <String>{
  'sys_exit',
  'sys_recv',
  'sys_send',
  'sys_web_fetch',
  'sys_web_search',
};

/// Deterministically filters [allSchemas] to the exact subset callable by [pcb] ([D-213] §4.2, [D-218], [D-219]).
///
/// 1. Excludes any syscall whose required [CapRight] is absent from `pcb.cspace`.
/// 2. Enforces `Workspace ⊕ Net`: excludes `sys_web_search` and `sys_web_fetch` from any
///    process holding `/workspace` or `/skills` mounts, or `read` / `writeCow` / `exec` rights.
/// 3. Excludes `sys_exit` from Ring 2 `LeadAgent` (root-process protection).
/// 4. Excludes `sys_spawn` and `sys_wait` from Ring 3 children (depth-1 lock).
/// 5. Restricts `WebResearcher` strictly to [webResearcherAllowedToolNames] (5 tools).
/// 6. Excludes `sys_skill_list` / `sys_skill_read` when `/skills` is unmounted or has no accessible skills.
/// 7. Returns results sorted lexicographically by tool name for Prefix cache stability.
List<SyscallToolSchema> filterToolSchemasForPcb({
  required ProcessControlBlock pcb,
  required List<SyscallToolSchema> allSchemas,
  Map<String, CapRight>? requiredRightsBySyscall,
}) {
  final rightsMap = requiredRightsBySyscall ?? defaultSyscallRequiredRights;
  final cspaceRights = pcb.cspace.allRights;
  final hasWorkspaceOrSkillsOrExec = pcb.namespace.isWorkspaceMounted ||
      pcb.namespace.isSkillsMounted ||
      cspaceRights.contains(CapRight.read) ||
      cspaceRights.contains(CapRight.writeCow) ||
      cspaceRights.contains(CapRight.exec);
  final hasAccessibleSkills = pcb.namespace.isSkillsMounted &&
      pcb.namespace.skillsMount!.listAccessibleBy(pcb.cspace, pcb.namespace).isNotEmpty;

  final filtered = <SyscallToolSchema>[];
  final seen = <String>{};

  for (final schema in allSchemas) {
    final name = schema.name;
    if (!seen.add(name)) {
      continue;
    }

    // Ring 2 parent exclusions (root-process protection).
    if (pcb.ring == ProtectionRing.ring2 && name == 'sys_exit') {
      continue;
    }

    // Workspace ⊕ Net isolation ([D-204] §3.2(1)): deny web tools to any process with workspace/skills/exec.
    if ((name == 'sys_web_search' || name == 'sys_web_fetch') &&
        hasWorkspaceOrSkillsOrExec) {
      continue;
    }

    // On-demand /skills tools only advertised when /skills has >= 1 accessible skill ([D-219] §4.2(3)).
    if ((name == 'sys_skill_list' || name == 'sys_skill_read') &&
        !hasAccessibleSkills) {
      continue;
    }

    // Ring 3 child exclusions (depth-1 lock, TTY monopoly, and sterile WebResearcher 5-tool boundary).
    if (pcb.ring == ProtectionRing.ring3) {
      if (name == 'sys_spawn' ||
          name == 'sys_wait' ||
          name == 'sys_kill' ||
          name.startsWith('sys_tx_') ||
          name == 'sys_jj_merge' ||
          name == 'sys_jj_integrate' ||
          name == 'sys_task_stack' ||
          name == 'sys_mcp_list_tools' ||
          name == 'sys_mcp_call') {
        continue;
      }
      if (pcb.profile == ProcessProfileId.webResearcher &&
          !webResearcherAllowedToolNames.contains(name)) {
        continue;
      }
    }

    final reqRight = rightsMap[name];
    if (reqRight != null && !cspaceRights.contains(reqRight)) {
      continue;
    }

    filtered.add(schema);
  }

  filtered.sort((a, b) => a.name.compareTo(b.name));
  return List<SyscallToolSchema>.unmodifiable(filtered);
}

/// Builds the 5 Stage 2 process & IPC [SyscallDefinition]s ([D-202], [D-211], [D-212]).
List<SyscallDefinition> buildProcessSyscallDefinitions({
  required IsolateWorkerHost host,
  required KernelProcessTable processTable,
}) {
  return <SyscallDefinition>[
    SyscallDefinition(
      name: 'sys_spawn',
      requiredRight: CapRight.procSpawn,
      kind: 'other',
      applyIoCap: false,
      validateArgs: _validateSpawnArgs,
      evaluatePolicy: (_, _) async => RingDecision.allow,
      resultSummaryBuilder: (_, result) {
        if (!result.ok || result.value == null) {
          return null;
        }
        final v = result.value!;
        return <String, dynamic>{
          'childPid': v['childPid'],
          'logicalTaskId': v['logicalTaskId'],
          'workspaceName': v['workspaceName'],
          'baseChangeId': v['baseChangeId'],
          'workingChangeId': v['workingChangeId'],
        };
      },
      handler: (exec) async {
        final specResult = _parseSpawnSpec(exec.args);
        if (!specResult.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(specResult.error!);
        }
        final maxTotalSyscalls = (exec.args['maxTotalSyscalls'] as num?)?.toInt();
        return host.spawnChild(
          exec,
          specResult.value!,
          maxTotalSyscalls: maxTotalSyscalls,
        );
      },
    ),
    SyscallDefinition(
      name: 'sys_wait',
      requiredRight: CapRight.procSpawn,
      kind: 'other',
      applyIoCap: true,
      cappedTextFields: const <String>['summary'],
      validateArgs: _validateWaitArgs,
      evaluatePolicy: (_, _) async => RingDecision.allow,
      resultSummaryBuilder: (_, result) {
        if (!result.ok || result.value == null) {
          return null;
        }
        final children = result.value!['children'];
        if (children is! List) {
          return null;
        }
        final pids = <Object?>[];
        final taskIds = <Object?>[];
        for (final entry in children) {
          if (entry is Map) {
            pids.add(entry['pid']);
            taskIds.add(entry['logicalTaskId']);
          }
        }
        return <String, dynamic>{
          'childCount': children.length,
          'pids': pids,
          'logicalTaskIds': taskIds,
        };
      },
      handler: (exec) {
        final rawPids = exec.args['pids'] as List<dynamic>?;
        final pids = rawPids?.map((e) => (e as num).toInt()).toList(growable: false);
        final timeoutMs = (exec.args['timeoutMs'] as num?)?.toInt() ?? 120000;
        return host.waitForChildren(
          exec,
          pids: pids,
          timeoutMs: timeoutMs,
        );
      },
    ),
    SyscallDefinition(
      name: 'sys_exit',
      requiredRight: CapRight.procSelf,
      kind: 'other',
      applyIoCap: false,
      validateArgs: _validateExitArgs,
      evaluatePolicy: (_, _) async => RingDecision.allow,
      handler: (exec) {
        final exitCode = (exec.args['exitCode'] as num?)?.toInt() ?? 0;
        final summary = (exec.args['summary'] as String?) ?? '';
        return host.handleChildExit(
          exec,
          exitCode: exitCode,
          summary: summary,
        );
      },
    ),
    SyscallDefinition(
      name: 'sys_send',
      requiredRight: CapRight.ipc,
      kind: 'other',
      applyIoCap: false,
      validateArgs: _validateSendArgs,
      evaluatePolicy: (_, _) async => RingDecision.allow,
      handler: (exec) async {
        final sender = exec.pcb;
        final toPid = (exec.args['toPid'] as num).toInt();
        final payload = exec.args['payload'] as Object;
        final schemaType = (exec.args['schemaType'] as String?)?.trim();
        final effectiveSchemaType =
            (schemaType == null || schemaType.isEmpty) ? 'message' : schemaType;

        final target = processTable.getProcess(toPid);
        if (target == null) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eperm,
              reason: 'IPC_TARGET_FORBIDDEN',
              message: 'Target process $toPid does not exist or is not reachable.',
              recoverable: true,
            ),
          );
        }

        // Strict parent-child topology enforcement ([D-212] §3.3).
        final bool isParentToOwnChild =
            sender.pid == 1 && target.parentPid == sender.pid;
        final bool isChildToOwnParent =
            sender.ring == ProtectionRing.ring3 &&
            sender.parentPid != null &&
            toPid == sender.parentPid;

        if (!isParentToOwnChild && !isChildToOwnParent) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eperm,
              reason: 'IPC_TARGET_FORBIDDEN',
              message:
                  'IPC from pid=${sender.pid} to pid=$toPid is forbidden (only parent<->own-child messaging is permitted).',
              recoverable: true,
            ),
          );
        }

        if (target.state == ProcessState.terminated) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'PROCESS_TERMINATED',
              message:
                  'Cannot send IPC message to terminated process pid=$toPid.',
              recoverable: true,
            ),
          );
        }

        final enqRes = target.mailbox.enqueueData(
          fromPid: sender.pid,
          toPid: toPid,
          payload: payload,
          schemaType: effectiveSchemaType,
        );
        if (!enqRes.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(enqRes.error!);
        }

        final env = enqRes.value!;
        return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
          'msgId': env.msgId,
          'fromPid': env.fromPid,
          'toPid': env.toPid,
          'schemaType': env.schemaType,
          'queuedCount': target.mailbox.dataLength,
        });
      },
    ),
    SyscallDefinition(
      name: 'sys_recv',
      requiredRight: CapRight.ipc,
      kind: 'other',
      applyIoCap: false,
      validateArgs: _validateRecvArgs,
      evaluatePolicy: (_, _) async => RingDecision.allow,
      handler: (exec) async {
        final maxMessages = (exec.args['maxMessages'] as num?)?.toInt() ?? 8;
        final waitTimeoutMs = (exec.args['waitTimeoutMs'] as num?)?.toInt() ?? 0;

        final messages = await exec.pcb.mailbox.receiveData(
          maxCount: maxMessages,
          waitTimeout: Duration(milliseconds: waitTimeoutMs),
          cancelToken: exec.context.cancelToken,
        );

        return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
          'messages': messages.map((m) => m.toJson()).toList(growable: false),
          'remainingCount': exec.pcb.mailbox.dataLength,
        });
      },
    ),
    SyscallDefinition(
      name: 'sys_kill',
      requiredRight: CapRight.procSpawn,
      kind: 'other',
      applyIoCap: false,
      validateArgs: _validateKillArgs,
      evaluatePolicy: (_, _) async => RingDecision.allow,
      resultSummaryBuilder: (_, result) {
        if (!result.ok || result.value == null) {
          return null;
        }
        final v = result.value!;
        return <String, dynamic>{
          'targetPid': v['targetPid'],
          'signal': v['signal'],
          'resultingState': v['state'],
        };
      },
      handler: (exec) {
        final rawSignal = (exec.args['signal'] as String).trim();
        final signal = ProcessSignalKind.tryParse(rawSignal)!;
        final pid = (exec.args['pid'] as num?)?.toInt();
        final logicalTaskId = (exec.args['logicalTaskId'] as String?)?.trim();
        final constraintMessage = exec.args['constraintMessage'] as String?;
        return host.handleSysKill(
          exec,
          pid: pid,
          logicalTaskId: logicalTaskId,
          signal: signal,
          constraintMessage: constraintMessage,
        );
      },
    ),
  ];
}

/// Canonical tool schemas for `sys_spawn`, `sys_wait`, `sys_exit`, `sys_send`, and `sys_recv` ([D-202], [D-211], [D-212]).
List<SyscallToolSchema> buildProcessToolSchemas() {
  return <SyscallToolSchema>[
    SyscallToolSchema(
      name: 'sys_spawn',
      description:
          'Spawn a sandboxed Ring 3 sub-agent Isolate (explorer, web_researcher, workspace_worker, or conflict_resolver) with attenuated capabilities and donated quota.',
      parametersJsonSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'profile': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'explorer',
              'web_researcher',
              'workspace_worker',
              'conflict_resolver',
            ],
            'description':
                'Sandbox profile: "explorer" (read-only /workspace), "web_researcher" (sterile public web), "workspace_worker" (isolated jj workspace editing & dart test/analyze), or "conflict_resolver" (isolated jj conflict resolution).',
          },
          'taskPrompt': <String, dynamic>{
            'type': 'string',
            'description':
                'Clear, self-contained task description and desired concise output format for the child agent.',
          },
          'name': <String, dynamic>{
            'type': 'string',
            'description': 'Optional human-readable identifier for the child process.',
          },
          'baseChangeId': <String, dynamic>{
            'type': 'string',
            'description':
                'Optional Jujutsu Change ID / revision to branch the isolated workspace from (defaults to LeadAgent working change).',
          },
          'logicalTaskId': <String, dynamic>{
            'type': 'string',
            'description':
                'Optional logical task identifier for tracking across retries.',
          },
          'model': <String, dynamic>{
            'type': 'string',
            'description':
                'Optional "<providerId>/<modelName>" override for the child; defaults to parent current turn model.',
          },
          'allowedSubpaths': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
            'description':
                'Optional /workspace subpaths permitted for explorer (e.g., ["/workspace/packages/agent_kernel"]).',
          },
          'maxTotalTokens': <String, dynamic>{
            'type': 'integer',
            'description': 'Optional token budget donated to the child process.',
          },
          'maxCostMicroUsd': <String, dynamic>{
            'type': 'integer',
            'description': 'Optional cost budget (micro-USD) donated to the child.',
          },
          'maxWallTimeMs': <String, dynamic>{
            'type': 'integer',
            'description': 'Wall-clock time limit in ms (default 90000, max 300000).',
          },
          'maxSteps': <String, dynamic>{
            'type': 'integer',
            'description': 'Maximum ReAct steps for the child (default 16, max 32).',
          },
          'requestedRights': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
            'description':
                'Optional further subset of CapRight names to attenuate within the profile.',
          },
          'supervision': <String, dynamic>{
            'type': 'object',
            'description':
                'Optional Supervisor automatic recovery policy ({restart: "never"|"on_failure", maxRetries: 0..3, fallbackModel: "<provider>/<model>"}).',
            'properties': <String, dynamic>{
              'restart': <String, dynamic>{
                'type': 'string',
                'enum': <String>['never', 'on_failure'],
              },
              'maxRetries': <String, dynamic>{
                'type': 'integer',
                'minimum': 0,
                'maximum': 3,
              },
              'fallbackModel': <String, dynamic>{
                'type': 'string',
              },
            },
          },
        },
        'required': <String>['profile', 'taskPrompt'],
      },
    ),
    SyscallToolSchema(
      name: 'sys_wait',
      description:
          'Wait for spawned Ring 3 child processes to finish and collect their concise exit summaries without importing raw child context.',
      parametersJsonSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pids': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'integer'},
            'description':
                'Optional list of child PIDs to wait on; omit to wait for all unreaped children.',
          },
          'timeoutMs': <String, dynamic>{
            'type': 'integer',
            'description': 'Maximum wait time in ms (default 120000, max 300000).',
          },
        },
      },
    ),
    SyscallToolSchema(
      name: 'sys_exit',
      description:
          'Terminate the current Ring 3 child process and return a concise summary to the parent LeadAgent.',
      parametersJsonSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'exitCode': <String, dynamic>{
            'type': 'integer',
            'description': '0 for success, non-zero for failure (default 0).',
          },
          'summary': <String, dynamic>{
            'type': 'string',
            'description': 'Concise final findings summary returned to parent.',
          },
        },
        'required': <String>['summary'],
      },
    ),
    SyscallToolSchema(
      name: 'sys_send',
      description:
          'Send a bounded structured IPC message (<= 64 KiB) between parent and its own child process.',
      parametersJsonSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'toPid': <String, dynamic>{
            'type': 'integer',
            'description': 'Recipient PID (must be parent or own active child).',
          },
          'payload': <String, dynamic>{
            'description': 'JSON object or string payload (max 64 KiB UTF-8).',
          },
          'schemaType': <String, dynamic>{
            'type': 'string',
            'description': 'Optional message schema tag (default "message").',
          },
        },
        'required': <String>['toPid', 'payload'],
      },
    ),
    SyscallToolSchema(
      name: 'sys_recv',
      description:
          'Dequeue pending IPC messages from the current process BoundedMailbox.',
      parametersJsonSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'maxMessages': <String, dynamic>{
            'type': 'integer',
            'description': 'Maximum messages to dequeue (default 8, max 32).',
          },
          'waitTimeoutMs': <String, dynamic>{
            'type': 'integer',
            'description':
                'Optional wait timeout in ms when empty (default 0 = non-blocking, max 30000).',
          },
        },
      },
    ),
    SyscallToolSchema(
      name: 'sys_kill',
      description:
          'Send a control signal (SIGSTOP, SIGCONT, or SIGKILL) to an active Ring 3 child process.',
      parametersJsonSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pid': <String, dynamic>{
            'type': 'integer',
            'description': 'Target child PID (mutually optional with logicalTaskId).',
          },
          'logicalTaskId': <String, dynamic>{
            'type': 'string',
            'description': 'Target logicalTaskId across Supervisor retries.',
          },
          'signal': <String, dynamic>{
            'type': 'string',
            'enum': <String>['SIGSTOP', 'SIGCONT', 'SIGKILL'],
            'description': 'Signal to deliver: SIGSTOP, SIGCONT, or SIGKILL.',
          },
          'constraintMessage': <String, dynamic>{
            'type': 'string',
            'description':
                'Optional runtime policy constraint injected on SIGCONT.',
          },
        },
        'required': <String>['signal'],
      },
    ),
  ];
}

SyscallError? _validateSpawnArgs(Map<String, dynamic> args) {
  final rawProfile = args['profile'];
  if (rawProfile is! String || ProcessProfileId.tryParse(rawProfile) == null) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_PROFILE',
      message:
          'Argument "profile" must be one of: explorer, web_researcher, workspace_worker, conflict_resolver.',
      recoverable: true,
    );
  }
  final baseChangeId = args['baseChangeId'];
  if (baseChangeId != null) {
    if (baseChangeId is! String ||
        baseChangeId.trim().isEmpty ||
        baseChangeId.trim().startsWith('-')) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_REVISION',
        message:
            'Argument "baseChangeId" must be a non-empty non-flag revision string.',
        recoverable: true,
      );
    }
  }
  final logicalTaskId = args['logicalTaskId'];
  if (logicalTaskId != null &&
      (logicalTaskId is! String || logicalTaskId.trim().isEmpty)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "logicalTaskId" must be a non-empty string.',
      recoverable: true,
    );
  }
  final taskPrompt = args['taskPrompt'];
  if (taskPrompt is! String || taskPrompt.trim().isEmpty) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_TASK_PROMPT',
      message: 'Argument "taskPrompt" must be a non-empty string.',
      recoverable: true,
    );
  }
  final name = args['name'];
  if (name != null && name is! String) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "name" must be a string.',
      recoverable: true,
    );
  }
  final model = args['model'];
  if (model != null) {
    if (model is! String || model.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_MODEL',
        message: 'Argument "model" must be a non-empty "<providerId>/<modelName>" string.',
        recoverable: true,
      );
    }
    final parsed = ModelIdentifier.parse(model);
    if (!parsed.ok) {
      return parsed.error;
    }
  }
  final subpaths = args['allowedSubpaths'];
  if (subpaths != null) {
    if (subpaths is! List || subpaths.any((e) => e is! String)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ALLOWED_SUBPATHS',
        message: 'Argument "allowedSubpaths" must be a list of strings.',
        recoverable: true,
      );
    }
  }
  final maxTotalTokens = args['maxTotalTokens'];
  if (maxTotalTokens != null && (maxTotalTokens is! int || maxTotalTokens <= 0)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_QUOTA_ARG',
      message: 'Argument "maxTotalTokens" must be a positive integer.',
      recoverable: true,
    );
  }
  final maxCostMicroUsd = args['maxCostMicroUsd'];
  if (maxCostMicroUsd != null &&
      (maxCostMicroUsd is! int || maxCostMicroUsd < 0)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_QUOTA_ARG',
      message: 'Argument "maxCostMicroUsd" must be a non-negative integer.',
      recoverable: true,
    );
  }
  final maxWallTimeMs = args['maxWallTimeMs'];
  if (maxWallTimeMs != null &&
      (maxWallTimeMs is! int ||
          maxWallTimeMs <= 0 ||
          maxWallTimeMs > SpawnSpec.maxAllowedWallTimeMs)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_QUOTA_ARG',
      message:
          'Argument "maxWallTimeMs" must be an integer between 1 and ${SpawnSpec.maxAllowedWallTimeMs}.',
      recoverable: true,
    );
  }
  final maxSteps = args['maxSteps'];
  if (maxSteps != null &&
      (maxSteps is! int ||
          maxSteps <= 0 ||
          maxSteps > SpawnSpec.maxAllowedSteps)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message:
          'Argument "maxSteps" must be an integer between 1 and ${SpawnSpec.maxAllowedSteps}.',
      recoverable: true,
    );
  }
  final maxTotalSyscalls = args['maxTotalSyscalls'];
  if (maxTotalSyscalls != null &&
      (maxTotalSyscalls is! int || maxTotalSyscalls <= 0)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_QUOTA_ARG',
      message: 'Argument "maxTotalSyscalls" must be a positive integer.',
      recoverable: true,
    );
  }
  final requestedRights = args['requestedRights'];
  if (requestedRights != null) {
    if (requestedRights is! List || requestedRights.any((e) => e is! String)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_REQUESTED_RIGHTS',
        message: 'Argument "requestedRights" must be a list of CapRight names.',
        recoverable: true,
      );
    }
    for (final rawRight in requestedRights.cast<String>()) {
      final matched = CapRight.values.any((r) => r.name == rawRight);
      if (!matched) {
        return SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'UNKNOWN_CAP_RIGHT',
          message: 'Unknown CapRight "$rawRight" in requestedRights.',
          recoverable: true,
        );
      }
    }
  }
  final supervision = args['supervision'];
  if (supervision != null) {
    if (supervision is! Map) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_SUPERVISION_POLICY',
        message: 'Argument "supervision" must be a JSON object.',
        recoverable: true,
      );
    }
    final rawRestart = supervision['restart'];
    if (rawRestart != null &&
        (rawRestart is! String || RestartStrategy.tryParse(rawRestart) == null)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_SUPERVISION_POLICY',
        message: 'supervision.restart must be "never" or "on_failure".',
        recoverable: true,
      );
    }
    final maxRetries = supervision['maxRetries'];
    if (maxRetries != null &&
        (maxRetries is! int ||
            maxRetries < 0 ||
            maxRetries > SupervisionPolicy.maxAllowedRetries)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_SUPERVISION_POLICY',
        message:
            'supervision.maxRetries must be an integer between 0 and ${SupervisionPolicy.maxAllowedRetries}.',
        recoverable: true,
      );
    }
    final fallbackModel = supervision['fallbackModel'];
    if (fallbackModel != null) {
      if (fallbackModel is! String || fallbackModel.trim().isEmpty) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_MODEL',
          message:
              'supervision.fallbackModel must be a non-empty "<providerId>/<modelName>" string.',
          recoverable: true,
        );
      }
      final parsedFallback = ModelIdentifier.parse(fallbackModel);
      if (!parsedFallback.ok) {
        return parsedFallback.error;
      }
    }
  }
  return null;
}

SyscallResult<SpawnSpec> _parseSpawnSpec(Map<String, dynamic> args) {
  final profile = ProcessProfileId.tryParse(args['profile'] as String)!;
  final rawSubpaths = args['allowedSubpaths'] as List<dynamic>?;
  final rawRights = args['requestedRights'] as List<dynamic>?;
  Set<CapRight>? requestedRights;
  if (rawRights != null) {
    requestedRights = <CapRight>{};
    for (final name in rawRights.cast<String>()) {
      requestedRights.add(CapRight.values.firstWhere((r) => r.name == name));
    }
  }

  SupervisionPolicy? supervision;
  final rawSupervision = args['supervision'];
  if (rawSupervision is Map) {
    final rawRestart = rawSupervision['restart'] as String?;
    final restart = rawRestart != null
        ? RestartStrategy.tryParse(rawRestart)!
        : RestartStrategy.never;
    final maxRetries = (rawSupervision['maxRetries'] as int?) ?? 0;
    final fallbackRaw = (rawSupervision['fallbackModel'] as String?)?.trim();
    supervision = SupervisionPolicy(
      restart: restart,
      maxRetries: maxRetries,
      fallbackModel:
          (fallbackRaw == null || fallbackRaw.isEmpty) ? null : fallbackRaw,
    );
  }

  return SyscallResult<SpawnSpec>.success(
    SpawnSpec(
      profile: profile,
      taskPrompt: (args['taskPrompt'] as String).trim(),
      name: args['name'] as String?,
      model: args['model'] as String?,
      allowedSubpaths: rawSubpaths?.cast<String>(),
      maxTotalTokens: args['maxTotalTokens'] as int?,
      maxCostMicroUsd: args['maxCostMicroUsd'] as int?,
      maxWallTimeMs:
          (args['maxWallTimeMs'] as int?) ?? SpawnSpec.defaultMaxWallTimeMs,
      maxSteps: (args['maxSteps'] as int?) ?? SpawnSpec.defaultMaxSteps,
      requestedRights: requestedRights,
      baseChangeId: (args['baseChangeId'] as String?)?.trim(),
      logicalTaskId: (args['logicalTaskId'] as String?)?.trim(),
      supervision: supervision,
    ),
  );
}

SyscallError? _validateKillArgs(Map<String, dynamic> args) {
  final rawSignal = args['signal'];
  if (rawSignal is! String || ProcessSignalKind.tryParse(rawSignal) == null) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_SIGNAL',
      message: 'Argument "signal" must be one of: SIGSTOP, SIGCONT, SIGKILL.',
      recoverable: true,
    );
  }
  final pid = args['pid'];
  if (pid != null && (pid is! int || pid <= 0)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "pid" must be a positive integer PID.',
      recoverable: true,
    );
  }
  final logicalTaskId = args['logicalTaskId'];
  if (logicalTaskId != null &&
      (logicalTaskId is! String || logicalTaskId.trim().isEmpty)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "logicalTaskId" must be a non-empty string.',
      recoverable: true,
    );
  }
  if (pid == null && logicalTaskId == null) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'MISSING_SIGNAL_TARGET',
      message: 'Either "pid" or "logicalTaskId" must be provided.',
      recoverable: true,
    );
  }
  final constraintMessage = args['constraintMessage'];
  if (constraintMessage != null && constraintMessage is! String) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "constraintMessage" must be a string.',
      recoverable: true,
    );
  }
  return null;
}

SyscallError? _validateWaitArgs(Map<String, dynamic> args) {
  final pids = args['pids'];
  if (pids != null) {
    if (pids is! List || pids.any((e) => e is! int || e <= 0)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "pids" must be a list of positive integer PIDs.',
        recoverable: true,
      );
    }
  }
  final timeoutMs = args['timeoutMs'];
  if (timeoutMs != null &&
      (timeoutMs is! int || timeoutMs <= 0 || timeoutMs > 300000)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "timeoutMs" must be an integer between 1 and 300000.',
      recoverable: true,
    );
  }
  return null;
}

SyscallError? _validateExitArgs(Map<String, dynamic> args) {
  final exitCode = args['exitCode'];
  if (exitCode != null && exitCode is! int) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "exitCode" must be an integer.',
      recoverable: true,
    );
  }
  final summary = args['summary'];
  if (summary != null && summary is! String) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "summary" must be a string.',
      recoverable: true,
    );
  }
  return null;
}

SyscallError? _validateSendArgs(Map<String, dynamic> args) {
  final toPid = args['toPid'];
  if (toPid is! int || toPid <= 0) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "toPid" must be a positive integer PID.',
      recoverable: true,
    );
  }
  final payload = args['payload'];
  if (payload == null || (payload is! String && payload is! Map)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_IPC_PAYLOAD',
      message: 'Argument "payload" must be a String or JSON object.',
      recoverable: true,
    );
  }
  final schemaType = args['schemaType'];
  if (schemaType != null && schemaType is! String) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "schemaType" must be a string.',
      recoverable: true,
    );
  }
  return null;
}

SyscallError? _validateRecvArgs(Map<String, dynamic> args) {
  final maxMessages = args['maxMessages'];
  if (maxMessages != null &&
      (maxMessages is! int || maxMessages < 1 || maxMessages > 32)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "maxMessages" must be an integer between 1 and 32.',
      recoverable: true,
    );
  }
  final waitTimeoutMs = args['waitTimeoutMs'];
  if (waitTimeoutMs != null &&
      (waitTimeoutMs is! int || waitTimeoutMs < 0 || waitTimeoutMs > 30000)) {
    return const SyscallError(
      code: SyscallErrorCode.einval,
      reason: 'INVALID_ARGS',
      message: 'Argument "waitTimeoutMs" must be an integer between 0 and 30000.',
      recoverable: true,
    );
  }
  return null;
}
