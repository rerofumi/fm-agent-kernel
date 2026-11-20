import 'dart:collection';

import 'pcb.dart';
import 'syscall_error.dart';

/// Lifecycle state of a Kanban / Stacked Changes task node ([D-311]).
enum StackedTaskState {
  todo('todo'),
  running('running'),
  paused('paused'),
  conflict('conflict'),
  review('review'),
  done('done'),
  failed('failed');

  const StackedTaskState(this.wireValue);

  final String wireValue;

  static StackedTaskState? tryParse(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final value in StackedTaskState.values) {
      if (value.wireValue == normalized) {
        return value;
      }
    }
    return null;
  }
}

/// Pure Ring 0 descriptor for a Stacked Changes task node (`c_A -> c_B`) ([D-311]).
class StackedTaskNode {
  StackedTaskNode({
    required this.taskId,
    required this.title,
    this.description = '',
    this.parentTaskId,
    required this.baseChangeId,
    required this.workingChangeId,
    required this.commitId,
    required this.workspaceName,
    required this.workspaceRoot,
    this.assignedModel,
    this.activePid,
    this.state = StackedTaskState.todo,
    this.hasConflicts = false,
    List<String> conflictedFiles = const <String>[],
    this.lastSyncedOpId,
  }) : conflictedFiles = List<String>.from(conflictedFiles);

  final String taskId;
  String title;
  String description;
  final String? parentTaskId;
  String baseChangeId;
  String workingChangeId;
  String commitId;
  final String workspaceName;
  final String workspaceRoot;
  String? assignedModel;
  Pid? activePid;
  StackedTaskState state;
  bool hasConflicts;
  List<String> conflictedFiles;
  String? lastSyncedOpId;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'taskId': taskId,
      'title': title,
      'description': description,
      'parentTaskId': parentTaskId,
      'baseChangeId': baseChangeId,
      'workingChangeId': workingChangeId,
      'commitId': commitId,
      'workspaceName': workspaceName,
      'workspaceRoot': workspaceRoot,
      'assignedModel': assignedModel,
      'activePid': activePid,
      'state': state.wireValue,
      'hasConflicts': hasConflicts,
      'conflictedFiles': List<String>.from(conflictedFiles),
      'lastSyncedOpId': lastSyncedOpId,
    };
  }
}

/// In-memory DAG registry tracking Stacked Changes tasks and topological descendant order ([D-311]).
class StackedTaskRegistry {
  static final RegExp validTaskIdPattern = RegExp(r'^[a-zA-Z0-9_-]{1,48}$');

  final Map<String, StackedTaskNode> _nodes = <String, StackedTaskNode>{};
  final Map<String, List<String>> _childrenByParent = <String, List<String>>{};

  /// Read-only view of all registered task nodes keyed by `taskId`.
  UnmodifiableMapView<String, StackedTaskNode> get nodes =>
      UnmodifiableMapView<String, StackedTaskNode>(_nodes);

  /// All registered task nodes in insertion order.
  List<StackedTaskNode> get allTasks =>
      List<StackedTaskNode>.unmodifiable(_nodes.values);

  /// Top-level tasks with no [StackedTaskNode.parentTaskId].
  List<StackedTaskNode> get rootTasks => _nodes.values
      .where((n) => n.parentTaskId == null)
      .toList(growable: false);

  /// Looks up a task node by [taskId].
  StackedTaskNode? getByTaskId(String taskId) => _nodes[taskId];

  /// Looks up a task node by its current `jj` [workingChangeId].
  StackedTaskNode? findByWorkingChangeId(String changeId) {
    for (final node in _nodes.values) {
      if (node.workingChangeId == changeId) {
        return node;
      }
    }
    return null;
  }

  /// Direct child task nodes of [parentTaskId].
  List<StackedTaskNode> childrenOf(String parentTaskId) {
    final ids = _childrenByParent[parentTaskId];
    if (ids == null || ids.isEmpty) {
      return const <StackedTaskNode>[];
    }
    return ids
        .map((id) => _nodes[id])
        .whereType<StackedTaskNode>()
        .toList(growable: false);
  }

  /// Registers [node] after validating `taskId` format, uniqueness, parent existence, and acyclicity.
  SyscallResult<StackedTaskNode> register(StackedTaskNode node) {
    if (!validTaskIdPattern.hasMatch(node.taskId)) {
      return SyscallResult<StackedTaskNode>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_TASK_ID',
          message:
              'Invalid taskId "${node.taskId}": must match [a-zA-Z0-9_-]{1,48}.',
          recoverable: true,
        ),
      );
    }
    if (_nodes.containsKey(node.taskId)) {
      return SyscallResult<StackedTaskNode>.failure(
        SyscallError(
          code: SyscallErrorCode.eexist,
          reason: 'TASK_ALREADY_EXISTS',
          message: 'Task "${node.taskId}" is already registered.',
          recoverable: true,
        ),
      );
    }
    final parentId = node.parentTaskId;
    if (parentId != null) {
      if (parentId == node.taskId) {
        return SyscallResult<StackedTaskNode>.failure(
          const SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'STACK_CYCLE_DETECTED',
            message: 'A stacked task cannot be its own parent.',
            recoverable: true,
          ),
        );
      }
      if (!_nodes.containsKey(parentId)) {
        return SyscallResult<StackedTaskNode>.failure(
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'TASK_NOT_FOUND',
            message: 'Parent task "$parentId" was not found.',
            recoverable: true,
          ),
        );
      }
      if (_wouldCreateCycle(node.taskId, parentId)) {
        return SyscallResult<StackedTaskNode>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'STACK_CYCLE_DETECTED',
            message:
                'Registering "${node.taskId}" under "$parentId" would create a dependency cycle.',
            recoverable: true,
          ),
        );
      }
    }

    _nodes[node.taskId] = node;
    if (parentId != null) {
      (_childrenByParent[parentId] ??= <String>[]).add(node.taskId);
    }
    return SyscallResult<StackedTaskNode>.success(node);
  }

  /// Returns all descendant tasks of [rootTaskId] in BFS topological order (children -> grandchildren -> ...).
  List<StackedTaskNode> descendantsInTopologicalOrder(String rootTaskId) {
    if (!_nodes.containsKey(rootTaskId)) {
      return const <StackedTaskNode>[];
    }
    final result = <StackedTaskNode>[];
    final visited = <String>{rootTaskId};
    final queue = Queue<String>()..add(rootTaskId);

    while (queue.isNotEmpty) {
      final currentId = queue.removeFirst();
      final childIds = _childrenByParent[currentId];
      if (childIds == null) {
        continue;
      }
      for (final childId in childIds) {
        if (visited.add(childId)) {
          final childNode = _nodes[childId];
          if (childNode != null) {
            result.add(childNode);
            queue.add(childId);
          }
        }
      }
    }
    return List<StackedTaskNode>.unmodifiable(result);
  }

  /// Removes a leaf task node by [taskId] (returns `ECONFLICT` if active children remain).
  SyscallResult<StackedTaskNode> remove(String taskId) {
    final node = _nodes[taskId];
    if (node == null) {
      return SyscallResult<StackedTaskNode>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'TASK_NOT_FOUND',
          message: 'Task "$taskId" was not found.',
          recoverable: true,
        ),
      );
    }
    final children = childrenOf(taskId);
    if (children.isNotEmpty) {
      return SyscallResult<StackedTaskNode>.failure(
        SyscallError(
          code: SyscallErrorCode.econflict,
          reason: 'TASK_HAS_DESCENDANTS',
          message:
              'Cannot remove task "$taskId" while child tasks exist: ${children.map((c) => c.taskId).join(', ')}.',
          recoverable: true,
        ),
      );
    }
    _nodes.remove(taskId);
    _childrenByParent.remove(taskId);
    if (node.parentTaskId != null) {
      _childrenByParent[node.parentTaskId!]?.remove(taskId);
    }
    return SyscallResult<StackedTaskNode>.success(node);
  }

  bool _wouldCreateCycle(String candidateId, String parentId) {
    String? cursor = parentId;
    final visited = <String>{};
    while (cursor != null) {
      if (cursor == candidateId) {
        return true;
      }
      if (!visited.add(cursor)) {
        return true;
      }
      cursor = _nodes[cursor]?.parentTaskId;
    }
    return false;
  }
}
