import 'dart:collection';

import 'capability.dart';
import 'syscall_error.dart';
import 'vfs_namespace.dart';

/// Parsed metadata and host location of a mounted `SKILL.md` package ([D-219]).
class SkillManifest {
  SkillManifest({
    required this.name,
    this.description = '',
    required this.virtualPath,
    required this.hostFilePath,
    required this.hostDirectoryPath,
    required this.sourceRootPath,
    Set<CapRight> requiredCapabilities = const <CapRight>{},
    Map<String, dynamic> metadata = const <String, dynamic>{},
  })  : requiredCapabilities = UnmodifiableSetView<CapRight>(
          Set<CapRight>.from(requiredCapabilities),
        ),
        metadata = Map<String, dynamic>.unmodifiable(metadata);

  /// Validated skill identifier matching [SkillRegistry.skillNamePattern].
  final String name;

  /// Short human/agent description from YAML frontmatter (may be empty).
  final String description;

  /// Virtual read-only path under `/skills/<name>/SKILL.md`.
  final String virtualPath;

  /// Canonical host path to the skill's `SKILL.md` file.
  final String hostFilePath;

  /// Canonical host path to the skill's directory.
  final String hostDirectoryPath;

  /// Canonical host path to the parent skills root directory that supplied this skill.
  final String sourceRootPath;

  /// Additional [CapRight] values required to view or read this skill.
  ///
  /// Empty when `required_capabilities` is omitted in `SKILL.md` (`B-03` compatibility).
  final UnmodifiableSetView<CapRight> requiredCapabilities;

  /// Plain unwrapped frontmatter metadata safe for JSON/Isolate transfer.
  final Map<String, dynamic> metadata;

  /// Returns a compact summary map suitable for `sys_skill_list` responses.
  Map<String, dynamic> toSummaryJson() {
    final sortedCaps = requiredCapabilities.map((r) => r.name).toList()..sort();
    return <String, dynamic>{
      'name': name,
      'description': description,
      'virtualPath': virtualPath,
      'requiredCapabilities': sortedCaps,
    };
  }
}

/// Diagnostic record for a skill directory skipped during startup scanning ([D-219]).
class SkillLoadSkip {
  const SkillLoadSkip({
    required this.sourcePath,
    required this.reason,
    required this.message,
  });

  final String sourcePath;
  final String reason;
  final String message;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'sourcePath': sourcePath,
      'reason': reason,
      'message': message,
    };
  }
}

/// Read-only registry of dynamically mounted `SKILL.md` manifests with CSpace enforcement ([D-203], [D-219]).
///
/// Enforces:
/// - First-Win priority deduplication by lowercased skill name (`[D-203]` §3.1(3)).
/// - Zero ambient capability escalation: reading or listing skills never adds rights to any CSpace.
/// - Fail-closed capability matching against `cspace.allRights`.
class SkillRegistry {
  SkillRegistry({
    Iterable<SkillManifest> skills = const <SkillManifest>[],
    Iterable<SkillLoadSkip> skipped = const <SkillLoadSkip>[],
  })  : _skillsByLowerName = _buildSkillMap(skills),
        _skipped = List<SkillLoadSkip>.unmodifiable(skipped);

  /// Creates an empty [SkillRegistry] with no mounted skills.
  const SkillRegistry.empty()
      : _skillsByLowerName = const <String, SkillManifest>{},
        _skipped = const <SkillLoadSkip>[];

  /// Allowed skill identifier pattern (`[D-219]` §4.2).
  static final RegExp skillNamePattern =
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$');

  static Map<String, SkillManifest> _buildSkillMap(
    Iterable<SkillManifest> skills,
  ) {
    final map = <String, SkillManifest>{};
    for (final skill in skills) {
      final key = skill.name.toLowerCase();
      // First-Win by priority: never overwrite an earlier higher-priority manifest.
      map.putIfAbsent(key, () => skill);
    }
    return Map<String, SkillManifest>.unmodifiable(map);
  }

  /// Validates that [name] conforms to [skillNamePattern] without path traversal segments.
  static bool isValidSkillName(String name) {
    if (name.isEmpty || name == '.' || name == '..') {
      return false;
    }
    if (name.contains('/') || name.contains('\\') || name.contains('..')) {
      return false;
    }
    return skillNamePattern.hasMatch(name);
  }

  /// Resolves a `required_capabilities` string from `SKILL.md` to a [CapRight], or `null` if unknown.
  ///
  /// Unknown capability strings must be rejected fail-closed by the loader (`[D-219]` §4.2).
  static CapRight? parseCapabilityName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed == 'net:public_readonly') {
      return CapRight.netRead;
    }
    for (final right in CapRight.values) {
      if (right.name == trimmed) {
        return right;
      }
    }
    return null;
  }

  final Map<String, SkillManifest> _skillsByLowerName;
  final List<SkillLoadSkip> _skipped;

  /// All registered skills in deterministic insertion (priority) order.
  List<SkillManifest> get allSkills =>
      List<SkillManifest>.unmodifiable(_skillsByLowerName.values);

  /// Diagnostics for invalid/duplicate skills skipped during loading.
  List<SkillLoadSkip> get skipped => _skipped;

  bool get isEmpty => _skillsByLowerName.isEmpty;
  bool get isNotEmpty => _skillsByLowerName.isNotEmpty;
  int get length => _skillsByLowerName.length;

  /// Looks up a mounted skill by [skillName] (case-insensitive normalized key).
  SkillManifest? lookup(String skillName) =>
      _skillsByLowerName[skillName.trim().toLowerCase()];

  /// Returns `true` iff a process with [cspace] and [namespace] is permitted to view/read [skill] ([D-219]).
  ///
  /// Never mutates [cspace] (zero capability escalation).
  bool isAccessibleBy(
    CapabilityTable cspace,
    VfsNamespace namespace,
    SkillManifest skill,
  ) {
    return checkAccess(cspace, namespace, skill) == null;
  }

  /// Checks whether [cspace] and [namespace] satisfy all requirements for [skill],
  /// returning `null` when allowed or a structured [SyscallError] when denied.
  ///
  /// Never mutates [cspace] (zero capability escalation).
  SyscallError? checkAccess(
    CapabilityTable cspace,
    VfsNamespace namespace,
    SkillManifest skill,
  ) {
    if (!namespace.isSkillsMounted) {
      return SyscallError(
        code: SyscallErrorCode.eacces,
        reason: 'SKILLS_NOT_MOUNTED',
        message:
            '/skills is not mounted in this namespace; skill "${skill.name}" cannot be accessed.',
        recoverable: false,
      );
    }

    final granted = cspace.allRights;
    if (!granted.contains(CapRight.read)) {
      return SyscallError(
        code: SyscallErrorCode.eperm,
        reason: 'CAPABILITY_DENIED',
        message:
            'Process lacks CapRight.read required to access skill "${skill.name}".',
        recoverable: false,
      );
    }

    final missing = skill.requiredCapabilities.difference(granted);
    if (missing.isNotEmpty) {
      final missingNames = missing.map((r) => r.name).toList()..sort();
      return SyscallError(
        code: SyscallErrorCode.eperm,
        reason: 'SKILL_CAPABILITY_DENIED',
        message:
            'Process lacks required capabilities (${missingNames.join(', ')}) for skill "${skill.name}".',
        recoverable: false,
        details: <String, dynamic>{
          'skillName': skill.name,
          'missingCapabilities': missingNames,
        },
      );
    }

    return null;
  }

  /// Returns all mounted skills visible to a process with [cspace] and [namespace].
  List<SkillManifest> listAccessibleBy(
    CapabilityTable cspace,
    VfsNamespace namespace,
  ) {
    return _skillsByLowerName.values
        .where((skill) => isAccessibleBy(cspace, namespace, skill))
        .toList(growable: false);
  }
}
