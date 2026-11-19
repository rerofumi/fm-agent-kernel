import 'syscall_error.dart';

/// Resource quota policy assigned to a process ([D-005]).
class ResourceQuota {
  const ResourceQuota({
    this.maxChildProcesses = 0,
    this.maxSyscallCountPerTurn = 64,
    this.maxTotalTokens,
    this.maxCostMicroUsd,
  })  : assert(maxChildProcesses >= 0),
        assert(maxSyscallCountPerTurn > 0);

  /// Stage 1 safety lock default: zero child agent processes permitted.
  static const ResourceQuota stage1Default = ResourceQuota();

  /// Maximum number of child agent processes permitted (`0` in Stage 1).
  final int maxChildProcesses;

  /// Maximum number of syscalls allowed within a single agent turn.
  final int maxSyscallCountPerTurn;

  /// Optional total token budget across the session.
  final int? maxTotalTokens;

  /// Optional cost budget in micro-USD across the session.
  final int? maxCostMicroUsd;
}

/// Mutable resource consumption tracker attached to a PCB ([D-005]).
class QuotaConsumption {
  QuotaConsumption({
    this.syscallCountInTurn = 0,
    this.totalTokensUsed = 0,
    this.costMicroUsdUsed = 0,
    this.activeChildProcesses = 0,
  });

  int syscallCountInTurn;
  int totalTokensUsed;
  int costMicroUsdUsed;
  int activeChildProcesses;

  /// Resets per-turn counters at a new user input turn boundary.
  void resetTurn() {
    syscallCountInTurn = 0;
  }

  /// Checks whether another syscall invocation is allowed under [quota].
  SyscallError? checkBeforeSyscall(ResourceQuota quota) {
    if (syscallCountInTurn >= quota.maxSyscallCountPerTurn) {
      return SyscallError(
        code: SyscallErrorCode.edquot,
        reason: 'SYSCALL_QUOTA_EXCEEDED',
        message:
            'Turn syscall quota exceeded ($syscallCountInTurn/${quota.maxSyscallCountPerTurn}).',
        recoverable: false,
        hint: 'Stop issuing further tool calls in this turn and summarize progress.',
        details: <String, dynamic>{
          'syscallCountInTurn': syscallCountInTurn,
          'maxSyscallCountPerTurn': quota.maxSyscallCountPerTurn,
        },
      );
    }
    if (quota.maxTotalTokens != null && totalTokensUsed >= quota.maxTotalTokens!) {
      return SyscallError(
        code: SyscallErrorCode.edquot,
        reason: 'TOKEN_QUOTA_EXCEEDED',
        message:
            'Token quota exceeded ($totalTokensUsed/${quota.maxTotalTokens}).',
        recoverable: false,
        details: <String, dynamic>{
          'totalTokensUsed': totalTokensUsed,
          'maxTotalTokens': quota.maxTotalTokens,
        },
      );
    }
    if (quota.maxCostMicroUsd != null &&
        costMicroUsdUsed >= quota.maxCostMicroUsd!) {
      return SyscallError(
        code: SyscallErrorCode.edquot,
        reason: 'COST_QUOTA_EXCEEDED',
        message:
            'Cost quota exceeded ($costMicroUsdUsed/${quota.maxCostMicroUsd} micro-USD).',
        recoverable: false,
        details: <String, dynamic>{
          'costMicroUsdUsed': costMicroUsdUsed,
          'maxCostMicroUsd': quota.maxCostMicroUsd,
        },
      );
    }
    return null;
  }

  /// Increments the per-turn syscall counter.
  void recordSyscall() {
    syscallCountInTurn += 1;
  }

  /// Accumulates LLM token and cost usage.
  void recordUsage({int tokens = 0, int costMicroUsd = 0}) {
    totalTokensUsed += tokens;
    costMicroUsdUsed += costMicroUsd;
  }
}
