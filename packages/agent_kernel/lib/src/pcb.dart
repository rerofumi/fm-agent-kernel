import 'dart:collection';

import 'capability.dart';
import 'context_memory.dart';
import 'quota.dart';
import 'syscall_error.dart';
import 'vfs_namespace.dart';

/// Process identifier ([D-005]).
typedef Pid = int;

/// Kernel protection ring level ([D-005]).
enum ProtectionRing {
  ring0,
  ring1,
  ring2,
  ring3,
}

/// Execution lifecycle state of a process ([D-005]).
enum ProcessState {
  ready,
  running,
  waitingSyscall,
  waitingApproval,
  stopped,
  terminated,
}

/// Jujutsu transaction isolation state tracked in the PCB ([D-003], [D-015]).
enum TxState {
  readOnly,
  active,
}

/// Per-process Jujutsu Copy-on-Write transaction context ([D-005], [D-015]).
class JjTxContext {
  JjTxContext({
    this.state = TxState.readOnly,
    this.baseOpId,
    this.parentChangeId,
    this.workingChangeId,
    this.currentOpId,
    Iterable<String> allowedCheckpointOpIds = const <String>[],
  }) : _allowedCheckpointOpIds = Set<String>.from(allowedCheckpointOpIds);

  TxState state;
  String? baseOpId;
  String? parentChangeId;
  String? workingChangeId;
  String? currentOpId;
  final Set<String> _allowedCheckpointOpIds;

  /// Unmodifiable set of operation IDs recorded during this session for safe rollback validation.
  UnmodifiableSetView<String> get allowedCheckpointOpIds =>
      UnmodifiableSetView<String>(_allowedCheckpointOpIds);

  /// Transitions context into an active isolated working-change transaction.
  void enterActive({
    required String baseOpId,
    required String parentChangeId,
    required String workingChangeId,
    String? currentOpId,
  }) {
    state = TxState.active;
    this.baseOpId = baseOpId;
    this.parentChangeId = parentChangeId;
    this.workingChangeId = workingChangeId;
    this.currentOpId = currentOpId ?? baseOpId;
    _allowedCheckpointOpIds.add(baseOpId);
    if (this.currentOpId != null) {
      _allowedCheckpointOpIds.add(this.currentOpId!);
    }
  }

  /// Updates the latest observed `jjOpId` and `workingChangeId` after a snapshot sync.
  void updateSnapshot({
    String? currentOpId,
    String? workingChangeId,
  }) {
    if (currentOpId != null && currentOpId.isNotEmpty) {
      this.currentOpId = currentOpId;
      _allowedCheckpointOpIds.add(currentOpId);
    }
    if (workingChangeId != null && workingChangeId.isNotEmpty) {
      this.workingChangeId = workingChangeId;
    }
  }

  /// Transitions context back to read-only after squash or rollback.
  void resetToReadOnly({String? currentOpId, String? workingChangeId}) {
    state = TxState.readOnly;
    if (currentOpId != null && currentOpId.isNotEmpty) {
      this.currentOpId = currentOpId;
      _allowedCheckpointOpIds.add(currentOpId);
    }
    if (workingChangeId != null) {
      this.workingChangeId = workingChangeId;
    }
  }
}

/// Kernel Process Control Block holding isolation, capability, quota, and context state ([D-005]).
class ProcessControlBlock {
  ProcessControlBlock({
    required this.pid,
    this.parentPid,
    required this.name,
    required this.ring,
    this.state = ProcessState.ready,
    required this.cspace,
    required this.quota,
    QuotaConsumption? quotaUsage,
    required this.namespace,
    JjTxContext? jjContext,
    required this.memory,
  })  : quotaUsage = quotaUsage ?? QuotaConsumption(),
        jjContext = jjContext ?? JjTxContext();

  final Pid pid;
  final Pid? parentPid;
  final String name;
  final ProtectionRing ring;
  ProcessState state;
  final CapabilityTable cspace;
  final ResourceQuota quota;
  final QuotaConsumption quotaUsage;
  final VfsNamespace namespace;
  final JjTxContext jjContext;
  final VirtualContextMemory memory;
}

/// Process table enforcing the Stage 1 single-process safety lock ([D-005]).
class KernelProcessTable {
  KernelProcessTable({this.maxActiveProcesses = stage1MaxActiveProcesses})
      : assert(maxActiveProcesses >= 1);

  static const int stage1MaxActiveProcesses = 1;

  final int maxActiveProcesses;
  final Map<Pid, ProcessControlBlock> _processes = <Pid, ProcessControlBlock>{};

  /// Unmodifiable view of registered PCBs.
  UnmodifiableMapView<Pid, ProcessControlBlock> get processes =>
      UnmodifiableMapView<Pid, ProcessControlBlock>(_processes);

  /// Looks up a PCB by [pid].
  ProcessControlBlock? getProcess(Pid pid) => _processes[pid];

  /// Registers a process while enforcing [maxActiveProcesses].
  SyscallResult<ProcessControlBlock> registerProcess(ProcessControlBlock pcb) {
    final activeCount = _processes.values
        .where((p) => p.state != ProcessState.terminated)
        .length;
    if (!_processes.containsKey(pcb.pid) && activeCount >= maxActiveProcesses) {
      return SyscallResult<ProcessControlBlock>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'STAGE1_SINGLE_PROCESS_LOCK',
          message:
              'Cannot register process ${pcb.pid}: Stage 1 single-process lock limits active processes to $maxActiveProcesses.',
          recoverable: false,
        ),
      );
    }
    _processes[pcb.pid] = pcb;
    return SyscallResult<ProcessControlBlock>.success(pcb);
  }

  /// Validates whether [parentPid] is permitted to spawn a child process (`EPERM` when locked).
  SyscallError? validateSpawnAllowed(Pid parentPid) {
    final parent = _processes[parentPid];
    if (parent == null) {
      return SyscallError(
        code: SyscallErrorCode.eperm,
        reason: 'UNKNOWN_PROCESS',
        message: 'Unknown parent process $parentPid.',
      );
    }
    if (parent.quota.maxChildProcesses == 0) {
      return const SyscallError(
        code: SyscallErrorCode.eperm,
        reason: 'STAGE1_SINGLE_PROCESS_LOCK',
        message:
            'Child process spawning is disabled by the Stage 1 single-process safety lock (maxChildProcesses = 0).',
        recoverable: false,
      );
    }
    final activeCount = _processes.values
        .where((p) => p.state != ProcessState.terminated)
        .length;
    if (parent.quotaUsage.activeChildProcesses >=
            parent.quota.maxChildProcesses ||
        activeCount >= maxActiveProcesses) {
      return const SyscallError(
        code: SyscallErrorCode.eperm,
        reason: 'STAGE1_SINGLE_PROCESS_LOCK',
        message: 'Process limit reached; cannot spawn child process.',
        recoverable: false,
      );
    }
    return null;
  }
}
