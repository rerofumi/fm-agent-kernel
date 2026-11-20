import 'dart:async';

import 'cancellation.dart';
import 'pcb.dart';

/// OS-style process control signal kinds ([D-312]).
enum ProcessSignalKind {
  sigstop('SIGSTOP'),
  sigcont('SIGCONT'),
  sigkill('SIGKILL');

  const ProcessSignalKind(this.wireValue);

  final String wireValue;

  /// Parses a wire signal name (case-insensitive).
  static ProcessSignalKind? tryParse(String raw) {
    final normalized = raw.trim().toUpperCase();
    for (final value in ProcessSignalKind.values) {
      if (value.wireValue == normalized) {
        return value;
      }
    }
    return null;
  }
}

/// Cooperative suspend/resume controller attached to each [ProcessControlBlock] ([D-312], [D-313]).
///
/// Avoids raw `Isolate.pause()` deadlocks by suspending only at safe syscall and
/// ReAct step boundaries, while queuing policy constraints for injection after
/// all in-flight `CanonicalToolResultTurn` records are committed.
class ProcessSuspendController {
  bool _isSuspended = false;
  Completer<void>? _resumeCompleter;
  final List<String> _pendingConstraints = <String>[];

  /// Whether the process is currently requested to suspend.
  bool get isSuspended => _isSuspended;

  /// Whether one or more `SIGCONT` policy constraints are queued for injection.
  bool get hasPendingConstraints => _pendingConstraints.isNotEmpty;

  /// Transitions into suspended state (idempotent if already suspended).
  void requestStop({String? reason}) {
    _isSuspended = true;
    _resumeCompleter ??= Completer<void>();
  }

  /// Queues an optional policy constraint and unblocks any suspended waiter.
  void requestContinue({String? constraintMessage}) {
    if (constraintMessage != null) {
      final trimmed = constraintMessage.trim();
      if (trimmed.isNotEmpty) {
        _pendingConstraints.add(trimmed);
      }
    }
    _isSuspended = false;
    final completer = _resumeCompleter;
    _resumeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Immediately aborts any suspended wait on `SIGKILL` or cancellation.
  void releaseForTermination() {
    _isSuspended = false;
    final completer = _resumeCompleter;
    _resumeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Drains queued constraint messages in FIFO order, joining multiple messages with `\n`.
  String? drainPendingConstraintText() {
    if (_pendingConstraints.isEmpty) {
      return null;
    }
    final joined = _pendingConstraints.join('\n');
    _pendingConstraints.clear();
    return joined;
  }

  /// Awaits resume or [cancelToken] cancellation when [isSuspended] is true.
  Future<void> waitIfSuspended({
    required ProcessControlBlock pcb,
    CancellationToken? cancelToken,
  }) async {
    if (!_isSuspended || (cancelToken?.isCancelled ?? false)) {
      return;
    }

    final prevState = pcb.state;
    pcb.state = ProcessState.stopped;
    try {
      while (_isSuspended && !(cancelToken?.isCancelled ?? false)) {
        final completer = _resumeCompleter ??= Completer<void>();
        if (cancelToken != null) {
          await Future.any<void>(<Future<void>>[
            completer.future,
            cancelToken.onCancel,
          ]);
        } else {
          await completer.future;
        }
      }
    } finally {
      if (pcb.state == ProcessState.stopped) {
        pcb.state = (prevState == ProcessState.ready ||
                prevState == ProcessState.stopped)
            ? ProcessState.running
            : prevState;
      }
    }
  }
}

/// Supervisor restart policy strategy for Ring 3 child tasks ([D-315]).
enum RestartStrategy {
  never('never'),
  onFailure('on_failure');

  const RestartStrategy(this.wireValue);

  final String wireValue;

  static RestartStrategy? tryParse(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final value in RestartStrategy.values) {
      if (value.wireValue == normalized) {
        return value;
      }
    }
    return null;
  }
}

/// Declarative Supervisor automatic recovery policy attached to a `sys_spawn` task ([D-315]).
class SupervisionPolicy {
  const SupervisionPolicy({
    this.restart = RestartStrategy.never,
    this.maxRetries = 0,
    this.fallbackModel,
  }) : assert(maxRetries >= 0 && maxRetries <= maxAllowedRetries);

  static const int maxAllowedRetries = 3;
  static const int minRetryTokenReserve = 512;
  static const SupervisionPolicy none = SupervisionPolicy();

  final RestartStrategy restart;

  /// Maximum retry attempts AFTER the initial attempt (`0` = 1 attempt total).
  final int maxRetries;

  /// Optional canonical `<providerId>/<modelName>` switched in on `attemptIndex >= 2`.
  final String? fallbackModel;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'restart': restart.wireValue,
      'maxRetries': maxRetries,
      'fallbackModel': fallbackModel,
    };
  }
}

/// Per-attempt execution record tracked by Supervisor across retries ([D-315]).
class SupervisorAttemptRecord {
  const SupervisorAttemptRecord({
    required this.attemptIndex,
    required this.pid,
    required this.model,
    this.workspaceName,
    this.baseChangeId,
    this.workingChangeId,
    this.finalCommitId,
    required this.ok,
    required this.exitCode,
    required this.reason,
    this.errorCode,
    required this.attemptConsumedTokens,
    required this.cumulativeConsumedTokens,
    required this.attemptConsumedCostMicroUsd,
    required this.cumulativeConsumedCostMicroUsd,
    required this.durationMs,
    required this.workspaceCleanedUp,
  });

  final int attemptIndex;
  final Pid pid;
  final String model;
  final String? workspaceName;
  final String? baseChangeId;
  final String? workingChangeId;
  final String? finalCommitId;
  final bool ok;
  final int exitCode;
  final String reason;
  final String? errorCode;
  final int attemptConsumedTokens;
  final int cumulativeConsumedTokens;
  final int attemptConsumedCostMicroUsd;
  final int cumulativeConsumedCostMicroUsd;
  final int durationMs;
  final bool workspaceCleanedUp;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'attemptIndex': attemptIndex,
      'pid': pid,
      'model': model,
      if (workspaceName != null) 'workspaceName': workspaceName,
      if (baseChangeId != null) 'baseChangeId': baseChangeId,
      if (workingChangeId != null) 'workingChangeId': workingChangeId,
      if (finalCommitId != null) 'finalCommitId': finalCommitId,
      'ok': ok,
      'exitCode': exitCode,
      'reason': reason,
      if (errorCode != null) 'errorCode': errorCode,
      'attemptConsumedTokens': attemptConsumedTokens,
      'cumulativeConsumedTokens': cumulativeConsumedTokens,
      'attemptConsumedCostMicroUsd': attemptConsumedCostMicroUsd,
      'cumulativeConsumedCostMicroUsd': cumulativeConsumedCostMicroUsd,
      'durationMs': durationMs,
      'workspaceCleanedUp': workspaceCleanedUp,
    };
  }
}
