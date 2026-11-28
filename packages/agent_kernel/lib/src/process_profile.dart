import 'capability.dart';
import 'pcb.dart';
import 'supervision.dart';

/// Sandboxed Ring 3 child process profiles ([D-211], [D-306]).
enum ProcessProfileId {
  explorer('explorer'),
  webResearcher('web_researcher'),
  workspaceWorker('workspace_worker'),
  conflictResolver('conflict_resolver');

  const ProcessProfileId(this.wireValue);

  /// Wire string used in `sys_spawn` arguments and audit records.
  final String wireValue;

  /// Protection ring enforced for this profile (`ring3` fixed).
  ProtectionRing get ring => ProtectionRing.ring3;

  /// Default capability rights granted to this profile ([D-211] §2.2, [D-306] §1.1).
  Set<CapRight> get defaultRights {
    return switch (this) {
      ProcessProfileId.explorer => const <CapRight>{
          CapRight.read,
          CapRight.vcsRead,
          CapRight.llmInfer,
          CapRight.memManage,
          CapRight.ipc,
          CapRight.procSelf,
        },
      ProcessProfileId.webResearcher => const <CapRight>{
          CapRight.netRead,
          CapRight.llmInfer,
          CapRight.ipc,
          CapRight.procSelf,
        },
      ProcessProfileId.workspaceWorker ||
      ProcessProfileId.conflictResolver => const <CapRight>{
          CapRight.read,
          CapRight.writeCow,
          CapRight.exec,
          CapRight.vcsRead,
          CapRight.llmInfer,
          CapRight.memManage,
          CapRight.ipc,
          CapRight.procSelf,
        },
    };
  }

  /// Primary CSpace resource scope for this profile.
  String get primaryResourceScope {
    return switch (this) {
      ProcessProfileId.explorer ||
      ProcessProfileId.workspaceWorker ||
      ProcessProfileId.conflictResolver => '/workspace',
      ProcessProfileId.webResearcher => 'net:public_readonly',
    };
  }

  /// Whether `/workspace` is mounted for this profile.
  bool get mountsWorkspace => this != ProcessProfileId.webResearcher;

  /// Whether `/skills` is mounted Read-Only for this profile.
  bool get mountsSkills => this != ProcessProfileId.webResearcher;

  /// Whether this profile requires an isolated `.agent_os/ws/<pid>` Jujutsu workspace ([D-306]).
  bool get requiresIsolatedJjWorkspace =>
      this == ProcessProfileId.workspaceWorker ||
      this == ProcessProfileId.conflictResolver;

  /// Whether this profile is permitted to mutate files and run preset commands in its isolated workspace ([D-306]).
  bool get allowsIsolatedWorkspaceMutation =>
      this == ProcessProfileId.workspaceWorker ||
      this == ProcessProfileId.conflictResolver;

  /// Whether `sys_jj_*` calls must force `--ignore-working-copy` ([D-204], [D-306]).
  bool get forcesVcsIgnoreWorkingCopy => this != ProcessProfileId.webResearcher;

  /// Parses a wire profile identifier.
  static ProcessProfileId? tryParse(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final value in ProcessProfileId.values) {
      if (value.wireValue == normalized) {
        return value;
      }
    }
    return null;
  }
}

/// Validated specification for spawning a Ring 3 child process via `sys_spawn` ([D-211], [D-307], [D-315], [D-502]).
class SpawnSpec {
  SpawnSpec({
    required this.profile,
    required this.taskPrompt,
    this.name,
    this.model,
    List<String>? allowedSubpaths,
    this.maxTotalTokens,
    this.maxCostMicroUsd,
    this.maxWallTimeMs = defaultMaxWallTimeMs,
    this.maxSteps = defaultMaxSteps,
    this.heartbeatTimeoutMs = defaultHeartbeatTimeoutMs,
    Set<CapRight>? requestedRights,
    this.baseChangeId,
    this.logicalTaskId,
    this.supervision,
  })  : assert(maxWallTimeMs > 0 && maxWallTimeMs <= maxAllowedWallTimeMs),
        assert(maxSteps > 0 && maxSteps <= maxAllowedSteps),
        assert(
          heartbeatTimeoutMs > 0 &&
              heartbeatTimeoutMs <= maxAllowedHeartbeatTimeoutMs,
        ),
        allowedSubpaths = allowedSubpaths == null
            ? null
            : List<String>.unmodifiable(allowedSubpaths),
        requestedRights = requestedRights == null
            ? null
            : Set<CapRight>.unmodifiable(requestedRights);

  static const int defaultMaxWallTimeMs = 600000;
  static const int maxAllowedWallTimeMs = 3600000;
  static const int defaultMaxSteps = 32;
  static const int maxAllowedSteps = 128;
  static const int defaultHeartbeatTimeoutMs = 300000;
  static const int maxAllowedHeartbeatTimeoutMs = 600000;

  final ProcessProfileId profile;
  final String taskPrompt;
  final String? name;
  final String? model;
  final List<String>? allowedSubpaths;
  final int? maxTotalTokens;
  final int? maxCostMicroUsd;
  final int maxWallTimeMs;
  final int maxSteps;
  final int heartbeatTimeoutMs;
  final Set<CapRight>? requestedRights;
  final String? baseChangeId;
  final String? logicalTaskId;
  final SupervisionPolicy? supervision;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'profile': profile.wireValue,
      'taskPrompt': taskPrompt,
      if (name != null) 'name': name,
      if (model != null) 'model': model,
      if (allowedSubpaths != null) 'allowedSubpaths': allowedSubpaths,
      if (maxTotalTokens != null) 'maxTotalTokens': maxTotalTokens,
      if (maxCostMicroUsd != null) 'maxCostMicroUsd': maxCostMicroUsd,
      'maxWallTimeMs': maxWallTimeMs,
      'maxSteps': maxSteps,
      'heartbeatTimeoutMs': heartbeatTimeoutMs,
      if (requestedRights != null)
        'requestedRights': requestedRights!.map((r) => r.name).toList(),
      if (baseChangeId != null) 'baseChangeId': baseChangeId,
      if (logicalTaskId != null) 'logicalTaskId': logicalTaskId,
      if (supervision != null) 'supervision': supervision!.toJson(),
    };
  }
}

/// Immutable host-observed heartbeat and loop-symptom snapshot for a Ring 3 child ([D-503]).
class ChildHeartbeatSnapshot {
  const ChildHeartbeatSnapshot({
    required this.currentStep,
    required this.maxSteps,
    required this.totalSyscalls,
    required this.elapsedMs,
    required this.idleMs,
    required this.heartbeatTimeoutMs,
    required this.lastHeartbeatAt,
    required this.isPaused,
    this.activeSyscall,
    this.lastSyscall,
    required this.consecutiveErrors,
    this.lastErrorReason,
  });

  final int currentStep;
  final int maxSteps;
  final int totalSyscalls;
  final int elapsedMs;
  final int idleMs;
  final int heartbeatTimeoutMs;
  final String lastHeartbeatAt; // ISO-8601 UTC string
  final bool isPaused;
  final String? activeSyscall;
  final String? lastSyscall;
  final int consecutiveErrors;
  final String? lastErrorReason;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'currentStep': currentStep,
        'maxSteps': maxSteps,
        'totalSyscalls': totalSyscalls,
        'elapsedMs': elapsedMs,
        'idleMs': idleMs,
        'heartbeatTimeoutMs': heartbeatTimeoutMs,
        'lastHeartbeatAt': lastHeartbeatAt,
        'isPaused': isPaused,
        'activeSyscall': activeSyscall,
        'lastSyscall': lastSyscall,
        'consecutiveErrors': consecutiveErrors,
        'lastErrorReason': lastErrorReason,
      };
}

/// Non-destructive progress snapshot for an active or retrying child returned in `sys_wait.running` ([D-504]).
class ChildRunningSnapshot {
  const ChildRunningSnapshot({
    required this.pid,
    required this.logicalTaskId,
    required this.name,
    required this.profile,
    required this.state,
    required this.model,
    required this.attemptIndex,
    required this.maxWallTimeMs,
    this.workspaceName,
    this.baseChangeId,
    this.workingChangeId,
    required this.consumedTokens,
    required this.consumedCostMicroUsd,
    this.heartbeat,
  });

  final Pid pid;
  final String logicalTaskId;
  final String name;
  final ProcessProfileId profile;
  final String state;
  final String model;
  final int attemptIndex;
  final int maxWallTimeMs;
  final String? workspaceName;
  final String? baseChangeId;
  final String? workingChangeId;
  final int consumedTokens;
  final int consumedCostMicroUsd;
  final ChildHeartbeatSnapshot? heartbeat;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pid': pid,
        'logicalTaskId': logicalTaskId,
        'name': name,
        'profile': profile.wireValue,
        'state': state,
        'model': model,
        'attemptIndex': attemptIndex,
        'maxWallTimeMs': maxWallTimeMs,
        'workspaceName': workspaceName,
        'baseChangeId': baseChangeId,
        'workingChangeId': workingChangeId,
        'consumedTokens': consumedTokens,
        'consumedCostMicroUsd': consumedCostMicroUsd,
        'heartbeat': heartbeat?.toJson(),
      };
}

/// Summary status returned by `sys_wait` when a child process terminates ([D-211], [D-214], [D-307], [D-315]).
class ChildExitStatus {
  const ChildExitStatus({
    required this.pid,
    required this.name,
    required this.profile,
    required this.ok,
    required this.exitCode,
    required this.reason,
    this.errorCode,
    required this.summary,
    required this.consumedTokens,
    required this.consumedCostMicroUsd,
    required this.durationMs,
    this.logicalTaskId,
    this.workspaceName,
    this.baseChangeId,
    this.workingChangeId,
    this.finalCommitId,
    this.workspaceCleanedUp = true,
    this.attempts = const <SupervisorAttemptRecord>[],
  });

  final Pid pid;
  final String name;
  final ProcessProfileId profile;
  final bool ok;
  final int exitCode;
  final String reason;
  final String? errorCode;
  final String summary;
  final int consumedTokens;
  final int consumedCostMicroUsd;
  final int durationMs;
  final String? logicalTaskId;
  final String? workspaceName;
  final String? baseChangeId;
  final String? workingChangeId;
  final String? finalCommitId;
  final bool workspaceCleanedUp;
  final List<SupervisorAttemptRecord> attempts;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'pid': pid,
      'name': name,
      'profile': profile.wireValue,
      'ok': ok,
      'exitCode': exitCode,
      'reason': reason,
      if (errorCode != null) 'errorCode': errorCode,
      'summary': summary,
      'consumedTokens': consumedTokens,
      'consumedCostMicroUsd': consumedCostMicroUsd,
      'durationMs': durationMs,
      if (logicalTaskId != null) 'logicalTaskId': logicalTaskId,
      if (workspaceName != null) 'workspaceName': workspaceName,
      if (baseChangeId != null) 'baseChangeId': baseChangeId,
      if (workingChangeId != null) 'workingChangeId': workingChangeId,
      if (finalCommitId != null) 'finalCommitId': finalCommitId,
      'workspaceCleanedUp': workspaceCleanedUp,
      'attempts': attempts.map((a) => a.toJson()).toList(growable: false),
    };
  }
}
