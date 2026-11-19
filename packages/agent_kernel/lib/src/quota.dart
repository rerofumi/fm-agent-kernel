import 'pcb.dart';
import 'syscall_error.dart';

/// Resource quota policy assigned to a process ([D-005], [D-214]).
class ResourceQuota {
  const ResourceQuota({
    this.maxChildProcesses = 0,
    this.maxSyscallCountPerTurn = 64,
    this.maxTotalSyscalls,
    this.maxTotalTokens,
    this.maxCostMicroUsd,
    this.maxWallTimeMs,
  })  : assert(maxChildProcesses >= 0),
        assert(maxSyscallCountPerTurn > 0),
        assert(maxTotalSyscalls == null || maxTotalSyscalls > 0),
        assert(maxWallTimeMs == null || maxWallTimeMs > 0);

  /// Stage 1 safety lock default: zero child agent processes permitted.
  static const ResourceQuota stage1Default = ResourceQuota();

  /// Stage 2 LeadAgent default: up to 8 concurrent child processes permitted ([D-214]).
  static const ResourceQuota stage2Default = ResourceQuota(
    maxChildProcesses: 8,
    maxSyscallCountPerTurn: 64,
  );

  /// Maximum number of concurrent child agent processes permitted (`0` in Stage 1).
  final int maxChildProcesses;

  /// Maximum number of syscalls allowed within a single agent turn.
  final int maxSyscallCountPerTurn;

  /// Optional lifetime syscall limit across the entire process execution (Stage 2).
  final int? maxTotalSyscalls;

  /// Optional total token budget across the session / process lifetime.
  final int? maxTotalTokens;

  /// Optional cost budget in micro-USD across the session / process lifetime.
  final int? maxCostMicroUsd;

  /// Optional wall-clock execution time limit in milliseconds (Stage 2).
  final int? maxWallTimeMs;
}

/// Mutable resource consumption tracker attached to a PCB ([D-005], [D-214]).
class QuotaConsumption {
  QuotaConsumption({
    this.syscallCountInTurn = 0,
    this.totalSyscallsExecuted = 0,
    this.totalTokensUsed = 0,
    this.costMicroUsdUsed = 0,
    this.activeChildProcesses = 0,
    this.donatedTokensOut = 0,
    this.donatedCostMicroUsdOut = 0,
    this.startedAtUtc,
  });

  int syscallCountInTurn;
  int totalSyscallsExecuted;
  int totalTokensUsed;
  int costMicroUsdUsed;
  int activeChildProcesses;

  /// Token budget currently reserved/donated out to active child processes.
  int donatedTokensOut;

  /// Cost budget (micro-USD) currently reserved/donated out to active child processes.
  int donatedCostMicroUsdOut;

  /// UTC timestamp when the process started running (used for `maxWallTimeMs`).
  DateTime? startedAtUtc;

  /// Resets per-turn counters at a new user input turn boundary.
  void resetTurn() {
    syscallCountInTurn = 0;
  }

  /// Marks the process start time if not yet recorded.
  void markStarted([DateTime? nowUtc]) {
    startedAtUtc ??= (nowUtc ?? DateTime.now()).toUtc();
  }

  /// Remaining unreserved token budget under [quota], or `null` if unlimited.
  int? availableTokens(ResourceQuota quota) {
    final maxTokens = quota.maxTotalTokens;
    if (maxTokens == null) {
      return null;
    }
    return maxTokens - totalTokensUsed - donatedTokensOut;
  }

  /// Remaining unreserved micro-USD cost budget under [quota], or `null` if unlimited.
  int? availableCostMicroUsd(ResourceQuota quota) {
    final maxCost = quota.maxCostMicroUsd;
    if (maxCost == null) {
      return null;
    }
    return maxCost - costMicroUsdUsed - donatedCostMicroUsdOut;
  }

  /// Checks whether another syscall invocation is allowed under [quota] ([D-005], [D-214]).
  SyscallError? checkBeforeSyscall(ResourceQuota quota, {DateTime? nowUtc}) {
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
    if (quota.maxTotalSyscalls != null &&
        totalSyscallsExecuted >= quota.maxTotalSyscalls!) {
      return SyscallError(
        code: SyscallErrorCode.edquot,
        reason: 'TOTAL_SYSCALL_QUOTA_EXCEEDED',
        message:
            'Lifetime syscall quota exceeded ($totalSyscallsExecuted/${quota.maxTotalSyscalls}).',
        recoverable: false,
        hint: 'Lifetime syscall limit reached; conclude with gathered findings.',
        details: <String, dynamic>{
          'totalSyscallsExecuted': totalSyscallsExecuted,
          'maxTotalSyscalls': quota.maxTotalSyscalls,
        },
      );
    }
    final committedTokens = totalTokensUsed + donatedTokensOut;
    if (quota.maxTotalTokens != null &&
        committedTokens >= quota.maxTotalTokens!) {
      return SyscallError(
        code: SyscallErrorCode.edquot,
        reason: 'TOKEN_QUOTA_EXCEEDED',
        message:
            'Token quota exceeded ($committedTokens/${quota.maxTotalTokens}, used=$totalTokensUsed, donatedOut=$donatedTokensOut).',
        recoverable: false,
        details: <String, dynamic>{
          'totalTokensUsed': totalTokensUsed,
          'donatedTokensOut': donatedTokensOut,
          'committedTokens': committedTokens,
          'maxTotalTokens': quota.maxTotalTokens,
        },
      );
    }
    final committedCost = costMicroUsdUsed + donatedCostMicroUsdOut;
    if (quota.maxCostMicroUsd != null &&
        committedCost >= quota.maxCostMicroUsd!) {
      return SyscallError(
        code: SyscallErrorCode.edquot,
        reason: 'COST_QUOTA_EXCEEDED',
        message:
            'Cost quota exceeded ($committedCost/${quota.maxCostMicroUsd} micro-USD, used=$costMicroUsdUsed, donatedOut=$donatedCostMicroUsdOut).',
        recoverable: false,
        details: <String, dynamic>{
          'costMicroUsdUsed': costMicroUsdUsed,
          'donatedCostMicroUsdOut': donatedCostMicroUsdOut,
          'committedCostMicroUsd': committedCost,
          'maxCostMicroUsd': quota.maxCostMicroUsd,
        },
      );
    }
    if (quota.maxWallTimeMs != null && startedAtUtc != null) {
      final elapsedMs = (nowUtc ?? DateTime.now())
          .toUtc()
          .difference(startedAtUtc!)
          .inMilliseconds;
      if (elapsedMs >= quota.maxWallTimeMs!) {
        return SyscallError(
          code: SyscallErrorCode.edquot,
          reason: 'WALL_TIME_QUOTA_EXCEEDED',
          message:
              'Wall-clock execution quota exceeded (${elapsedMs}ms/${quota.maxWallTimeMs}ms).',
          recoverable: false,
          details: <String, dynamic>{
            'elapsedMs': elapsedMs,
            'maxWallTimeMs': quota.maxWallTimeMs,
          },
        );
      }
    }
    return null;
  }

  /// Increments both the per-turn and lifetime syscall counters.
  void recordSyscall() {
    syscallCountInTurn += 1;
    totalSyscallsExecuted += 1;
  }

  /// Accumulates LLM token and cost usage.
  void recordUsage({int tokens = 0, int costMicroUsd = 0}) {
    totalTokensUsed += tokens;
    costMicroUsdUsed += costMicroUsd;
  }
}

/// Record of an active quota reservation donated from a parent to a child ([D-214]).
class QuotaDonation {
  const QuotaDonation({
    required this.parentPid,
    required this.childPid,
    required this.donatedTokens,
    required this.donatedCostMicroUsd,
    required this.childQuota,
  });

  final Pid parentPid;
  final Pid childPid;
  final int donatedTokens;
  final int donatedCostMicroUsd;
  final ResourceQuota childQuota;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'parentPid': parentPid,
      'childPid': childPid,
      'donatedTokens': donatedTokens,
      'donatedCostMicroUsd': donatedCostMicroUsd,
      'maxTotalTokens': childQuota.maxTotalTokens,
      'maxCostMicroUsd': childQuota.maxCostMicroUsd,
      'maxWallTimeMs': childQuota.maxWallTimeMs,
      'maxTotalSyscalls': childQuota.maxTotalSyscalls,
    };
  }
}

/// Settlement summary produced once when a child terminates and returns unused budget ([D-214]).
class QuotaSettlement {
  const QuotaSettlement({
    required this.parentPid,
    required this.childPid,
    required this.donatedTokens,
    required this.consumedTokens,
    required this.returnedTokens,
    required this.donatedCostMicroUsd,
    required this.consumedCostMicroUsd,
    required this.returnedCostMicroUsd,
  });

  final Pid parentPid;
  final Pid childPid;
  final int donatedTokens;
  final int consumedTokens;
  final int returnedTokens;
  final int donatedCostMicroUsd;
  final int consumedCostMicroUsd;
  final int returnedCostMicroUsd;
}

/// Hierarchical quota donation and conservation-law settlement ledger ([D-214]).
///
/// Guarantees that:
/// 1. Parent + active children can never exceed the parent's initial token/cost budget
///    because donated amounts are atomically reserved in `donatedTokensOut` / `donatedCostMicroUsdOut`.
/// 2. On child exit, `settleChildExit` runs at most once per child PID, releasing the
///    reservation and charging only actual child consumption to the parent (automatically
///    returning `donated - consumed` to the parent's available budget).
class QuotaLedger {
  static const int defaultChildTokenDonation = 16384;

  final Map<Pid, QuotaDonation> _activeDonations = <Pid, QuotaDonation>{};
  final Set<Pid> _settledChildren = <Pid>{};

  /// Returns active (unsettled) donation for [childPid], if any.
  QuotaDonation? activeDonationFor(Pid childPid) => _activeDonations[childPid];

  /// Whether [childPid] has already been settled.
  bool isSettled(Pid childPid) => _settledChildren.contains(childPid);

  /// Atomically reserves a sub-budget from [parent] for [childPid] ([D-214] §5.2).
  SyscallResult<QuotaDonation> donateToChild({
    required ProcessControlBlock parent,
    required Pid childPid,
    int? requestedTokens,
    int? requestedCostMicroUsd,
    int? maxWallTimeMs,
    int? maxTotalSyscalls,
    int maxSyscallCountPerTurn = 64,
  }) {
    if (_activeDonations.containsKey(childPid) ||
        _settledChildren.contains(childPid)) {
      return SyscallResult<QuotaDonation>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'DUPLICATE_CHILD_QUOTA_DONATION',
          message: 'Quota donation for child pid=$childPid already exists.',
          recoverable: false,
        ),
      );
    }

    if (requestedTokens != null && requestedTokens <= 0) {
      return const SyscallResult<QuotaDonation>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_QUOTA_ARG',
          message: 'requestedTokens must be a positive integer.',
          recoverable: true,
        ),
      );
    }
    if (requestedCostMicroUsd != null && requestedCostMicroUsd < 0) {
      return const SyscallResult<QuotaDonation>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_QUOTA_ARG',
          message: 'requestedCostMicroUsd must be non-negative.',
          recoverable: true,
        ),
      );
    }
    if (maxWallTimeMs != null && maxWallTimeMs <= 0) {
      return const SyscallResult<QuotaDonation>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_QUOTA_ARG',
          message: 'maxWallTimeMs must be a positive integer.',
          recoverable: true,
        ),
      );
    }
    if (maxTotalSyscalls != null && maxTotalSyscalls <= 0) {
      return const SyscallResult<QuotaDonation>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_QUOTA_ARG',
          message: 'maxTotalSyscalls must be a positive integer.',
          recoverable: true,
        ),
      );
    }

    if (parent.quota.maxChildProcesses == 0) {
      return const SyscallResult<QuotaDonation>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'STAGE1_SINGLE_PROCESS_LOCK',
          message: 'Parent process is not allowed to spawn children (maxChildProcesses = 0).',
          recoverable: false,
        ),
      );
    }
    if (parent.quotaUsage.activeChildProcesses >=
        parent.quota.maxChildProcesses) {
      return SyscallResult<QuotaDonation>.failure(
        SyscallError(
          code: SyscallErrorCode.edquot,
          reason: 'CHILD_PROCESS_QUOTA_EXCEEDED',
          message:
              'Active child limit reached (${parent.quotaUsage.activeChildProcesses}/${parent.quota.maxChildProcesses}).',
          recoverable: true,
          hint: 'Wait for running child processes before spawning another.',
        ),
      );
    }

    // 1. Validate token donation against parent's unreserved available tokens.
    int donatedTokens = 0;
    int? childMaxTokens;
    final parentAvailableTokens =
        parent.quotaUsage.availableTokens(parent.quota);
    if (parentAvailableTokens != null) {
      final candidate = requestedTokens ??
          (parentAvailableTokens < defaultChildTokenDonation
              ? parentAvailableTokens
              : defaultChildTokenDonation);
      if (candidate <= 0 || candidate > parentAvailableTokens) {
        return SyscallResult<QuotaDonation>.failure(
          SyscallError(
            code: SyscallErrorCode.edquot,
            reason: 'INSUFFICIENT_PARENT_TOKEN_QUOTA',
            message:
                'Requested child token budget ($candidate) exceeds parent available tokens ($parentAvailableTokens).',
            recoverable: true,
            hint:
                'Requested child token budget exceeds parent available tokens; pass a smaller maxTotalTokens or perform inspection directly.',
            details: <String, dynamic>{
              'requestedTokens': candidate,
              'availableTokens': parentAvailableTokens,
            },
          ),
        );
      }
      donatedTokens = candidate;
      childMaxTokens = candidate;
    } else {
      childMaxTokens = requestedTokens;
    }

    // 2. Validate cost donation against parent's unreserved available cost.
    int donatedCost = 0;
    int? childMaxCost;
    final parentAvailableCost =
        parent.quotaUsage.availableCostMicroUsd(parent.quota);
    if (parentAvailableCost != null) {
      final candidate = requestedCostMicroUsd ?? parentAvailableCost;
      if (candidate < 0 || candidate > parentAvailableCost) {
        return SyscallResult<QuotaDonation>.failure(
          SyscallError(
            code: SyscallErrorCode.edquot,
            reason: 'INSUFFICIENT_PARENT_COST_QUOTA',
            message:
                'Requested child cost budget ($candidate micro-USD) exceeds parent available cost ($parentAvailableCost micro-USD).',
            recoverable: true,
            hint:
                'Requested child cost budget exceeds parent available budget; pass a smaller maxCostMicroUsd or perform inspection directly.',
            details: <String, dynamic>{
              'requestedCostMicroUsd': candidate,
              'availableCostMicroUsd': parentAvailableCost,
            },
          ),
        );
      }
      donatedCost = candidate;
      childMaxCost = candidate;
    } else {
      childMaxCost = requestedCostMicroUsd;
    }

    // 3. Atomically reserve budget and increment active child count on parent.
    parent.quotaUsage.donatedTokensOut += donatedTokens;
    parent.quotaUsage.donatedCostMicroUsdOut += donatedCost;
    parent.quotaUsage.activeChildProcesses += 1;

    final donation = QuotaDonation(
      parentPid: parent.pid,
      childPid: childPid,
      donatedTokens: donatedTokens,
      donatedCostMicroUsd: donatedCost,
      childQuota: ResourceQuota(
        maxChildProcesses: 0,
        maxSyscallCountPerTurn: maxSyscallCountPerTurn,
        maxTotalSyscalls: maxTotalSyscalls,
        maxTotalTokens: childMaxTokens,
        maxCostMicroUsd: childMaxCost,
        maxWallTimeMs: maxWallTimeMs,
      ),
    );
    _activeDonations[childPid] = donation;
    return SyscallResult<QuotaDonation>.success(donation);
  }

  /// Settles a terminated child's actual usage back into [parent] exactly once ([D-214] §5.2).
  ///
  /// Returns `null` if [child] has no active donation or was already settled (idempotent guard).
  QuotaSettlement? settleChildExit({
    required ProcessControlBlock parent,
    required ProcessControlBlock child,
  }) {
    final donation = _activeDonations.remove(child.pid);
    if (donation == null) {
      return null;
    }
    _settledChildren.add(child.pid);

    final consumedTokens = child.quotaUsage.totalTokensUsed;
    final consumedCost = child.quotaUsage.costMicroUsdUsed;

    parent.quotaUsage.donatedTokensOut -= donation.donatedTokens;
    if (parent.quotaUsage.donatedTokensOut < 0) {
      parent.quotaUsage.donatedTokensOut = 0;
    }
    parent.quotaUsage.totalTokensUsed += consumedTokens;

    parent.quotaUsage.donatedCostMicroUsdOut -= donation.donatedCostMicroUsd;
    if (parent.quotaUsage.donatedCostMicroUsdOut < 0) {
      parent.quotaUsage.donatedCostMicroUsdOut = 0;
    }
    parent.quotaUsage.costMicroUsdUsed += consumedCost;

    if (parent.quotaUsage.activeChildProcesses > 0) {
      parent.quotaUsage.activeChildProcesses -= 1;
    }

    final returnedTokens = donation.donatedTokens > 0
        ? donation.donatedTokens - consumedTokens
        : 0;
    final returnedCost = donation.donatedCostMicroUsd > 0
        ? donation.donatedCostMicroUsd - consumedCost
        : 0;

    return QuotaSettlement(
      parentPid: parent.pid,
      childPid: child.pid,
      donatedTokens: donation.donatedTokens,
      consumedTokens: consumedTokens,
      returnedTokens: returnedTokens,
      donatedCostMicroUsd: donation.donatedCostMicroUsd,
      consumedCostMicroUsd: consumedCost,
      returnedCostMicroUsd: returnedCost,
    );
  }
}
