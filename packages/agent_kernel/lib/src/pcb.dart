import 'dart:collection';

import 'capability.dart';
import 'context_memory.dart';
import 'mailbox.dart';
import 'process_profile.dart';
import 'quota.dart';
import 'supervision.dart';
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
    this.anchorWorkingChangeId,
    Iterable<String> pendingWorkerChangeIds = const <String>[],
    Iterable<String> allowedCheckpointOpIds = const <String>[],
  })  : pendingWorkerChangeIds = Set<String>.from(pendingWorkerChangeIds),
        _allowedCheckpointOpIds = Set<String>.from(allowedCheckpointOpIds);

  TxState state;
  String? baseOpId;
  String? parentChangeId;
  String? workingChangeId;
  String? currentOpId;
  String? anchorWorkingChangeId;
  final Set<String> pendingWorkerChangeIds;
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

/// Kernel Process Control Block holding isolation, capability, quota, mailbox, and context state ([D-005], [D-211], [D-212]).
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
    BoundedMailbox? mailbox,
    this.profile,
    this.jjWorkspaceName,
    this.jjWorkspaceRoot,
    this.logicalTaskId,
    ProcessSuspendController? suspendController,
  })  : quotaUsage = quotaUsage ?? QuotaConsumption(),
        jjContext = jjContext ?? JjTxContext(),
        mailbox = mailbox ?? BoundedMailbox(),
        suspendController = suspendController ?? ProcessSuspendController();

  final Pid pid;
  final Pid? parentPid;
  final String name;
  final ProtectionRing ring;
  ProcessState state;
  final CapabilityTable cspace;
  final ResourceQuota quota;
  final QuotaConsumption quotaUsage;
  VfsNamespace namespace;
  final JjTxContext jjContext;
  final VirtualContextMemory memory;
  final BoundedMailbox mailbox;
  final ProcessProfileId? profile;
  String? jjWorkspaceName;
  String? jjWorkspaceRoot;
  final String? logicalTaskId;
  final ProcessSuspendController suspendController;

  /// Whether this process is backed by an isolated `.agent_os/ws/<pid>` Jujutsu workspace ([D-306]).
  bool get hasIsolatedJjWorkspace =>
      jjWorkspaceRoot != null && jjWorkspaceName != null;

  /// Alias matching audit log attribution naming ([D-215]).
  String get processName => name;
}

/// Process table enforcing the Stage 1 single-process safety lock and Stage 2 multi-process limits ([D-005], [D-211]).
class KernelProcessTable {
  KernelProcessTable({this.maxActiveProcesses = stage1MaxActiveProcesses})
      : assert(maxActiveProcesses >= 1);

  /// Creates a Stage 2 multi-process table supporting up to [maxActiveProcesses] concurrent processes ([D-211]).
  factory KernelProcessTable.stage2({
    int maxActiveProcesses = stage2DefaultMaxActiveProcesses,
  }) {
    return KernelProcessTable(maxActiveProcesses: maxActiveProcesses);
  }

  static const int stage1MaxActiveProcesses = 1;
  static const int stage2DefaultMaxActiveProcesses = 16;

  final int maxActiveProcesses;
  final Map<Pid, ProcessControlBlock> _processes = <Pid, ProcessControlBlock>{};
  int _nextPid = 1;

  /// Unmodifiable view of registered PCBs.
  UnmodifiableMapView<Pid, ProcessControlBlock> get processes =>
      UnmodifiableMapView<Pid, ProcessControlBlock>(_processes);

  /// Looks up a PCB by [pid].
  ProcessControlBlock? getProcess(Pid pid) => _processes[pid];

  /// Allocates the next strictly monotonically increasing PID without ever reusing terminated PIDs ([D-211]).
  Pid allocateNextPid() {
    while (_processes.containsKey(_nextPid)) {
      _nextPid += 1;
    }
    final allocated = _nextPid;
    _nextPid += 1;
    return allocated;
  }

  /// Returns all registered child PCBs spawned by [parentPid].
  List<ProcessControlBlock> childrenOf(Pid parentPid) {
    return _processes.values
        .where((p) => p.parentPid == parentPid)
        .toList(growable: false);
  }

  /// Returns non-terminated child PCBs spawned by [parentPid].
  List<ProcessControlBlock> activeChildrenOf(Pid parentPid) {
    return _processes.values
        .where(
          (p) => p.parentPid == parentPid && p.state != ProcessState.terminated,
        )
        .toList(growable: false);
  }

  /// Registers a process while enforcing [maxActiveProcesses].
  SyscallResult<ProcessControlBlock> registerProcess(ProcessControlBlock pcb) {
    final activeCount = _processes.values
        .where((p) => p.state != ProcessState.terminated)
        .length;
    if (!_processes.containsKey(pcb.pid) && activeCount >= maxActiveProcesses) {
      if (maxActiveProcesses == stage1MaxActiveProcesses) {
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
      return SyscallResult<ProcessControlBlock>.failure(
        SyscallError(
          code: SyscallErrorCode.edquot,
          reason: 'CHILD_PROCESS_QUOTA_EXCEEDED',
          message:
              'Cannot register process ${pcb.pid}: active process table limit ($maxActiveProcesses) reached.',
          recoverable: true,
          hint: 'Wait for running child processes with sys_wait before spawning more.',
          details: <String, dynamic>{
            'activeProcesses': activeCount,
            'maxActiveProcesses': maxActiveProcesses,
          },
        ),
      );
    }
    _processes[pcb.pid] = pcb;
    if (pcb.pid >= _nextPid) {
      _nextPid = pcb.pid + 1;
    }
    return SyscallResult<ProcessControlBlock>.success(pcb);
  }

  /// Validates whether [parentPid] is permitted to spawn a child process ([D-005], [D-211]).
  ///
  /// - Stage 1 lock (`maxChildProcesses == 0` or `maxActiveProcesses == 1`):
  ///   returns `EPERM: STAGE1_SINGLE_PROCESS_LOCK` (`recoverable: false`).
  /// - Stage 2 active child / table capacity reached:
  ///   returns `EDQUOT: CHILD_PROCESS_QUOTA_EXCEEDED` (`recoverable: true`).
  SyscallError? validateSpawnAllowed(Pid parentPid) {
    final parent = _processes[parentPid];
    if (parent == null) {
      return SyscallError(
        code: SyscallErrorCode.eperm,
        reason: 'UNKNOWN_PROCESS',
        message: 'Unknown parent process $parentPid.',
      );
    }
    if (parent.quota.maxChildProcesses == 0 ||
        maxActiveProcesses == stage1MaxActiveProcesses) {
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
      return SyscallError(
        code: SyscallErrorCode.edquot,
        reason: 'CHILD_PROCESS_QUOTA_EXCEEDED',
        message:
            'Concurrent child process quota exceeded (activeChildren=${parent.quotaUsage.activeChildProcesses}/${parent.quota.maxChildProcesses}, activeProcesses=$activeCount/$maxActiveProcesses).',
        recoverable: true,
        hint: 'Wait for active child processes with sys_wait before spawning another child.',
        details: <String, dynamic>{
          'activeChildProcesses': parent.quotaUsage.activeChildProcesses,
          'maxChildProcesses': parent.quota.maxChildProcesses,
          'activeProcesses': activeCount,
          'maxActiveProcesses': maxActiveProcesses,
        },
      );
    }
    return null;
  }
}
