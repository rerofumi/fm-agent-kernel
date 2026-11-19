import 'capability.dart';
import 'pcb.dart';

/// Standard Stage 2 sandboxed Ring 3 child process profiles ([D-211]).
enum ProcessProfileId {
  explorer('explorer'),
  webResearcher('web_researcher');

  const ProcessProfileId(this.wireValue);

  /// Wire string used in `sys_spawn` arguments and audit records.
  final String wireValue;

  /// Protection ring enforced for this profile (`ring3` fixed in Stage 2).
  ProtectionRing get ring => ProtectionRing.ring3;

  /// Default capability rights granted to this profile ([D-211] §2.2).
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
    };
  }

  /// Primary CSpace resource scope for this profile.
  String get primaryResourceScope {
    return switch (this) {
      ProcessProfileId.explorer => '/workspace',
      ProcessProfileId.webResearcher => 'net:public_readonly',
    };
  }

  /// Whether `/workspace` is mounted for this profile.
  bool get mountsWorkspace => this == ProcessProfileId.explorer;

  /// Whether `/skills` is mounted Read-Only for this profile.
  bool get mountsSkills => this == ProcessProfileId.explorer;

  /// Whether `sys_jj_*` calls must force `--ignore-working-copy` ([D-204]).
  bool get forcesVcsIgnoreWorkingCopy => this == ProcessProfileId.explorer;

  /// Parses a wire profile identifier (`"explorer"` or `"web_researcher"`).
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

/// Validated specification for spawning a Ring 3 child process via `sys_spawn` ([D-211]).
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
    Set<CapRight>? requestedRights,
  })  : assert(maxWallTimeMs > 0 && maxWallTimeMs <= maxAllowedWallTimeMs),
        assert(maxSteps > 0 && maxSteps <= maxAllowedSteps),
        allowedSubpaths = allowedSubpaths == null
            ? null
            : List<String>.unmodifiable(allowedSubpaths),
        requestedRights = requestedRights == null
            ? null
            : Set<CapRight>.unmodifiable(requestedRights);

  static const int defaultMaxWallTimeMs = 90000;
  static const int maxAllowedWallTimeMs = 300000;
  static const int defaultMaxSteps = 16;
  static const int maxAllowedSteps = 32;

  final ProcessProfileId profile;
  final String taskPrompt;
  final String? name;
  final String? model;
  final List<String>? allowedSubpaths;
  final int? maxTotalTokens;
  final int? maxCostMicroUsd;
  final int maxWallTimeMs;
  final int maxSteps;
  final Set<CapRight>? requestedRights;

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
      if (requestedRights != null)
        'requestedRights': requestedRights!.map((r) => r.name).toList(),
    };
  }
}

/// Summary status returned by `sys_wait` when a child process terminates ([D-211], [D-214]).
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
    };
  }
}
