import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Warning callback invoked when a malformed or shadowed skill entry is skipped.
typedef SkillLoaderWarningCallback = void Function(String message);

/// Scans external skill directories and builds a read-only [SkillRegistry] ([D-203], [D-204], [D-219]).
///
/// Priority order (First-Win by lowercased skill name, `[D-203]` §3.1(3)):
/// 1. CLI `--skills-dir <path>` arguments (in specification order)
/// 2. Environment variable `AGENT_OS_SKILLS_DIR` (`;` delimited on Windows, `:` on POSIX)
/// 3. Repository default `<workspaceHostRoot>/.agent_os/skills`
class SkillDirectoryLoader {
  const SkillDirectoryLoader({
    this.onWarning,
  });

  /// Environment variable name holding additional skill directories (`[D-203]`, `[D-219]`).
  static const String envVarName = 'AGENT_OS_SKILLS_DIR';

  /// Standard skill file name inside each skill subdirectory.
  static const String skillFileName = 'SKILL.md';

  final SkillLoaderWarningCallback? onWarning;

  /// Parses `AGENT_OS_SKILLS_DIR` into an ordered list of non-empty directory paths.
  static List<String> parseSkillsDirEnv(
    String? rawEnv, {
    bool? isWindows,
  }) {
    if (rawEnv == null || rawEnv.trim().isEmpty) {
      return const <String>[];
    }
    final useSemicolon = isWindows ?? Platform.isWindows;
    final delimiter = useSemicolon ? ';' : ':';
    final result = <String>[];
    for (final rawPart in rawEnv.split(delimiter)) {
      var trimmed = rawPart.trim();
      if (trimmed.length >= 2 &&
          ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
              (trimmed.startsWith("'") && trimmed.endsWith("'")))) {
        trimmed = trimmed.substring(1, trimmed.length - 1).trim();
      }
      if (trimmed.isNotEmpty) {
        result.add(trimmed);
      }
    }
    return List<String>.unmodifiable(result);
  }

  /// Resolves prioritized skill root directories following `[D-203]` §3.1(3).
  static List<String> resolveSearchRoots({
    List<String> cliSkillsDirs = const <String>[],
    String? envSkillsDir,
    Map<String, String>? environment,
    String? workspaceHostRoot,
    bool? isWindows,
  }) {
    final effectiveWindows = isWindows ?? Platform.isWindows;
    final rawCandidates = <String>[];

    // Priority 1: CLI --skills-dir (first specified wins).
    for (final dir in cliSkillsDirs) {
      final trimmed = dir.trim();
      if (trimmed.isNotEmpty) {
        rawCandidates.add(trimmed);
      }
    }

    // Priority 2: AGENT_OS_SKILLS_DIR environment variable.
    final effectiveEnvRaw =
        envSkillsDir ?? (environment ?? Platform.environment)[envVarName];
    rawCandidates.addAll(
      parseSkillsDirEnv(effectiveEnvRaw, isWindows: effectiveWindows),
    );

    // Priority 3: <workspaceHostRoot>/.agent_os/skills
    if (workspaceHostRoot != null && workspaceHostRoot.trim().isNotEmpty) {
      rawCandidates.add(
        p.join(workspaceHostRoot.trim(), '.agent_os', 'skills'),
      );
    }

    final seenKeys = <String>{};
    final ordered = <String>[];
    for (final candidate in rawCandidates) {
      final normalized = p.normalize(p.absolute(candidate));
      final key = effectiveWindows ? normalized.toLowerCase() : normalized;
      if (seenKeys.add(key)) {
        ordered.add(normalized);
      }
    }
    return List<String>.unmodifiable(ordered);
  }

  /// Scans all prioritized roots and returns an immutable [SkillRegistry].
  SkillRegistry load({
    List<String> cliSkillsDirs = const <String>[],
    String? envSkillsDir,
    Map<String, String>? environment,
    String? workspaceHostRoot,
    bool? isWindows,
  }) {
    final roots = resolveSearchRoots(
      cliSkillsDirs: cliSkillsDirs,
      envSkillsDir: envSkillsDir,
      environment: environment,
      workspaceHostRoot: workspaceHostRoot,
      isWindows: isWindows,
    );
    return loadFromRoots(roots);
  }

  /// Scans [rootDirectories] in priority order (First-Win) and builds a [SkillRegistry].
  SkillRegistry loadFromRoots(Iterable<String> rootDirectories) {
    final manifests = <SkillManifest>[];
    final skipped = <SkillLoadSkip>[];
    final seenLowerNames = <String>{};

    for (final rawRoot in rootDirectories) {
      final trimmedRoot = rawRoot.trim();
      if (trimmedRoot.isEmpty) {
        continue;
      }
      final rootDir = Directory(trimmedRoot);
      if (!rootDir.existsSync()) {
        continue;
      }

      final String canonicalRoot;
      try {
        canonicalRoot = p.normalize(rootDir.resolveSymbolicLinksSync());
      } on FileSystemException catch (e) {
        _recordSkip(
          skipped,
          sourcePath: trimmedRoot,
          reason: 'ROOT_RESOLUTION_FAILED',
          message: 'Failed to resolve skills root "$trimmedRoot": ${e.message}',
        );
        continue;
      }

      final List<FileSystemEntity> entries;
      try {
        entries = Directory(canonicalRoot).listSync(followLinks: false);
      } on FileSystemException catch (e) {
        _recordSkip(
          skipped,
          sourcePath: canonicalRoot,
          reason: 'ROOT_LIST_FAILED',
          message: 'Failed to list skills root "$canonicalRoot": ${e.message}',
        );
        continue;
      }

      // Deterministic scan order within the same root directory.
      entries.sort(
        (a, b) => p.basename(a.path).toLowerCase().compareTo(
              p.basename(b.path).toLowerCase(),
            ),
      );

      for (final entity in entries) {
        _scanCandidateEntry(
          entity: entity,
          canonicalRoot: canonicalRoot,
          manifests: manifests,
          skipped: skipped,
          seenLowerNames: seenLowerNames,
        );
      }
    }

    return SkillRegistry(skills: manifests, skipped: skipped);
  }

  void _scanCandidateEntry({
    required FileSystemEntity entity,
    required String canonicalRoot,
    required List<SkillManifest> manifests,
    required List<SkillLoadSkip> skipped,
    required Set<String> seenLowerNames,
  }) {
    final rawType = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (rawType != FileSystemEntityType.directory &&
        rawType != FileSystemEntityType.link) {
      return;
    }

    final dirName = p.basename(entity.path);
    final String canonicalSkillDir;
    try {
      final resolvedType =
          FileSystemEntity.typeSync(entity.path, followLinks: true);
      if (resolvedType != FileSystemEntityType.directory) {
        if (rawType == FileSystemEntityType.link) {
          _recordSkip(
            skipped,
            sourcePath: entity.path,
            reason: 'SYMLINK_OUT_OF_ROOT',
            message:
                'Skill entry "$dirName" is a dangling or non-directory symbolic link.',
          );
        }
        return;
      }
      canonicalSkillDir =
          p.normalize(Directory(entity.path).resolveSymbolicLinksSync());
    } on FileSystemException catch (e) {
      _recordSkip(
        skipped,
        sourcePath: entity.path,
        reason: 'SYMLINK_OUT_OF_ROOT',
        message:
            'Failed to verify symbolic link boundary for "$dirName": ${e.message}',
      );
      return;
    }

    if (!_isInsideRoot(canonicalSkillDir, canonicalRoot)) {
      _recordSkip(
        skipped,
        sourcePath: entity.path,
        reason: 'SYMLINK_OUT_OF_ROOT',
        message:
            'Skill directory "$dirName" resolves outside skills root "$canonicalRoot".',
      );
      return;
    }

    final skillMdPath = p.join(canonicalSkillDir, skillFileName);
    final skillFileRawType =
        FileSystemEntity.typeSync(skillMdPath, followLinks: false);
    if (skillFileRawType == FileSystemEntityType.notFound) {
      return;
    }

    final String canonicalSkillFile;
    try {
      final resolvedFileType =
          FileSystemEntity.typeSync(skillMdPath, followLinks: true);
      if (resolvedFileType != FileSystemEntityType.file) {
        _recordSkip(
          skipped,
          sourcePath: skillMdPath,
          reason: skillFileRawType == FileSystemEntityType.link
              ? 'SYMLINK_OUT_OF_ROOT'
              : 'NOT_A_REGULAR_FILE',
          message: '"$skillMdPath" is not a regular file.',
        );
        return;
      }
      canonicalSkillFile =
          p.normalize(File(skillMdPath).resolveSymbolicLinksSync());
    } on FileSystemException catch (e) {
      _recordSkip(
        skipped,
        sourcePath: skillMdPath,
        reason: 'SYMLINK_OUT_OF_ROOT',
        message:
            'Failed to verify symbolic link boundary for "$skillMdPath": ${e.message}',
      );
      return;
    }

    if (!_isInsideRoot(canonicalSkillFile, canonicalSkillDir) ||
        !_isInsideRoot(canonicalSkillFile, canonicalRoot)) {
      _recordSkip(
        skipped,
        sourcePath: skillMdPath,
        reason: 'SYMLINK_OUT_OF_ROOT',
        message:
            'SKILL.md "$skillMdPath" resolves outside skill directory "$canonicalSkillDir".',
      );
      return;
    }

    final List<int> bytes;
    try {
      bytes = File(canonicalSkillFile).readAsBytesSync();
    } on FileSystemException catch (e) {
      _recordSkip(
        skipped,
        sourcePath: canonicalSkillFile,
        reason: 'FILE_READ_FAILED',
        message: 'Failed to read "$canonicalSkillFile": ${e.message}',
      );
      return;
    }

    if (_containsNulByte(bytes)) {
      _recordSkip(
        skipped,
        sourcePath: canonicalSkillFile,
        reason: 'BINARY_FILE',
        message: 'SKILL.md "$canonicalSkillFile" contains NUL bytes (binary).',
      );
      return;
    }

    final String content;
    try {
      content = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      _recordSkip(
        skipped,
        sourcePath: canonicalSkillFile,
        reason: 'INVALID_UTF8',
        message: 'SKILL.md "$canonicalSkillFile" is not valid UTF-8 text.',
      );
      return;
    }

    final parsedFrontmatter = _parseFrontmatter(content);
    if (!parsedFrontmatter.ok) {
      _recordSkip(
        skipped,
        sourcePath: canonicalSkillFile,
        reason: 'INVALID_YAML_FRONTMATTER',
        message: parsedFrontmatter.errorMessage!,
      );
      return;
    }

    final metadata = parsedFrontmatter.metadata!;
    final rawName = metadata['name'];
    final String skillName;
    if (rawName == null) {
      skillName = dirName;
    } else if (rawName is String) {
      skillName = rawName.trim();
    } else {
      _recordSkip(
        skipped,
        sourcePath: canonicalSkillFile,
        reason: 'INVALID_SKILL_NAME',
        message: 'Frontmatter "name" must be a string.',
      );
      return;
    }

    if (!SkillRegistry.isValidSkillName(skillName)) {
      _recordSkip(
        skipped,
        sourcePath: canonicalSkillFile,
        reason: 'INVALID_SKILL_NAME',
        message:
            'Invalid skill name "$skillName" (must match ${SkillRegistry.skillNamePattern.pattern} without path traversal).',
      );
      return;
    }

    final rawDescription = metadata['description'];
    final description = rawDescription == null
        ? ''
        : (rawDescription is String
            ? rawDescription.trim()
            : rawDescription.toString().trim());

    final capsResult = _parseRequiredCapabilities(
      metadata['required_capabilities'],
    );
    if (!capsResult.ok) {
      _recordSkip(
        skipped,
        sourcePath: canonicalSkillFile,
        reason: capsResult.errorReason!,
        message: capsResult.errorMessage!,
      );
      return;
    }

    final lowerName = skillName.toLowerCase();
    if (!seenLowerNames.add(lowerName)) {
      _recordSkip(
        skipped,
        sourcePath: canonicalSkillFile,
        reason: 'DUPLICATE_SHADOWED',
        message:
            'Skill "$skillName" from "$canonicalSkillFile" is shadowed by a higher-priority definition.',
      );
      return;
    }

    manifests.add(
      SkillManifest(
        name: skillName,
        description: description,
        virtualPath: '${VfsNamespace.skillsVirtualRoot}/$skillName/$skillFileName',
        hostFilePath: canonicalSkillFile,
        hostDirectoryPath: canonicalSkillDir,
        sourceRootPath: canonicalRoot,
        requiredCapabilities: capsResult.capabilities!,
        metadata: metadata,
      ),
    );
  }

  void _recordSkip(
    List<SkillLoadSkip> skipped, {
    required String sourcePath,
    required String reason,
    required String message,
  }) {
    skipped.add(
      SkillLoadSkip(
        sourcePath: sourcePath,
        reason: reason,
        message: message,
      ),
    );
    final warningLine = '[skill_loader] Skipped ($reason) $sourcePath: $message';
    final callback = onWarning;
    if (callback != null) {
      callback(warningLine);
    } else {
      stderr.writeln(warningLine);
    }
  }

  static _FrontmatterParseResult _parseFrontmatter(String rawContent) {
    var text = rawContent;
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    }

    // Check if document starts with a YAML frontmatter fence `---`.
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty || lines.first.trimRight() != '---') {
      // Frontmatter is optional per [D-219] §4.2.
      return const _FrontmatterParseResult.success(<String, dynamic>{});
    }

    var closingIndex = -1;
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line == '---' || line == '...') {
        closingIndex = i;
        break;
      }
    }
    if (closingIndex < 0) {
      return const _FrontmatterParseResult.failure(
        'Unterminated YAML frontmatter block (missing closing "---").',
      );
    }

    final yamlSource = lines.sublist(1, closingIndex).join('\n');
    if (yamlSource.trim().isEmpty) {
      return const _FrontmatterParseResult.success(<String, dynamic>{});
    }

    final dynamic parsed;
    try {
      parsed = loadYaml(yamlSource);
    } on YamlException catch (e) {
      return _FrontmatterParseResult.failure(
        'Invalid YAML frontmatter: ${e.message}',
      );
    } on Object catch (e) {
      return _FrontmatterParseResult.failure(
        'Failed to parse YAML frontmatter: $e',
      );
    }

    if (parsed == null) {
      return const _FrontmatterParseResult.success(<String, dynamic>{});
    }

    final unwrapped = unwrapYamlValue(parsed);
    if (unwrapped is! Map<String, dynamic>) {
      return const _FrontmatterParseResult.failure(
        'YAML frontmatter root must be a mapping/object.',
      );
    }
    return _FrontmatterParseResult.success(unwrapped);
  }

  /// Recursively unwraps `package:yaml` [YamlMap] / [YamlList] nodes into plain
  /// Dart `Map<String, dynamic>` / `List<dynamic>` safe for JSON & Isolate transfer ([D-219]).
  static dynamic unwrapYamlValue(dynamic value) {
    if (value is YamlMap) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        out[entry.key.toString()] = unwrapYamlValue(entry.value);
      }
      return out;
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        out[entry.key.toString()] = unwrapYamlValue(entry.value);
      }
      return out;
    }
    if (value is YamlList) {
      return value.map<dynamic>(unwrapYamlValue).toList(growable: false);
    }
    if (value is List) {
      return value.map<dynamic>(unwrapYamlValue).toList(growable: false);
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    return value.toString();
  }

  static _CapabilitiesParseResult _parseRequiredCapabilities(dynamic raw) {
    if (raw == null) {
      // B-03 compatibility: omitted required_capabilities requires no extra rights.
      return const _CapabilitiesParseResult.success(<CapRight>{});
    }
    if (raw is! List) {
      return const _CapabilitiesParseResult.failure(
        reason: 'INVALID_REQUIRED_CAPABILITIES',
        message:
            'Frontmatter "required_capabilities" must be a list of capability names.',
      );
    }

    final caps = <CapRight>{};
    for (final item in raw) {
      if (item is! String) {
        return _CapabilitiesParseResult.failure(
          reason: 'INVALID_REQUIRED_CAPABILITIES',
          message:
              'Every entry in "required_capabilities" must be a string (got ${item.runtimeType}).',
        );
      }
      final parsed = SkillRegistry.parseCapabilityName(item);
      if (parsed == null) {
        return _CapabilitiesParseResult.failure(
          reason: 'UNKNOWN_CAPABILITY',
          message:
              'Unknown capability "$item" in "required_capabilities"; rejected fail-closed.',
        );
      }
      caps.add(parsed);
    }
    return _CapabilitiesParseResult.success(caps);
  }

  static bool _isInsideRoot(String candidatePath, String rootPath) {
    final normCandidate = p.normalize(candidatePath);
    final normRoot = p.normalize(rootPath);
    if (Platform.isWindows) {
      final lcCandidate = normCandidate.toLowerCase();
      final lcRoot = normRoot.toLowerCase();
      if (lcCandidate == lcRoot) {
        return true;
      }
      final prefix = lcRoot.endsWith(p.separator) ? lcRoot : '$lcRoot${p.separator}';
      return lcCandidate.startsWith(prefix);
    }
    if (normCandidate == normRoot) {
      return true;
    }
    final prefix =
        normRoot.endsWith(p.separator) ? normRoot : '$normRoot${p.separator}';
    return normCandidate.startsWith(prefix);
  }

  static bool _containsNulByte(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) {
        return true;
      }
    }
    return false;
  }
}

/// Kernel syscall driver for `sys_skill_list` (#23) and `sys_skill_read` (#24) ([D-202], [D-204], [D-219]).
class SkillSyscallDriver {
  const SkillSyscallDriver();

  /// Lists mounted skills visible to the calling process's [CapabilityTable] and [VfsNamespace].
  Future<SyscallResult<Map<String, dynamic>>> listSkills({
    required CapabilityTable cspace,
    required VfsNamespace namespace,
  }) async {
    final registry = namespace.skillsMount;
    if (registry == null) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'SKILLS_NOT_MOUNTED',
          message: '/skills is not mounted in this namespace.',
          recoverable: false,
        ),
      );
    }

    final accessible = registry.listAccessibleBy(cspace, namespace);
    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'skills': accessible.map((s) => s.toSummaryJson()).toList(growable: false),
      'totalCount': accessible.length,
    });
  }

  /// Reads the full UTF-8 content of a mounted skill after CSpace & real-path validation ([D-204], [D-219]).
  Future<SyscallResult<Map<String, dynamic>>> readSkill({
    required String name,
    required CapabilityTable cspace,
    required VfsNamespace namespace,
  }) async {
    final registry = namespace.skillsMount;
    if (registry == null) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'SKILLS_NOT_MOUNTED',
          message: '/skills is not mounted in this namespace.',
          recoverable: false,
        ),
      );
    }

    final trimmedName = name.trim();
    if (!SkillRegistry.isValidSkillName(trimmedName)) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_SKILL_NAME',
          message: 'Invalid skill name "$name".',
          recoverable: true,
        ),
      );
    }

    final manifest = registry.lookup(trimmedName);
    if (manifest == null) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'SKILL_NOT_FOUND',
          message: 'Skill "$trimmedName" is not mounted under /skills.',
          recoverable: true,
          hint: 'Call sys_skill_list to inspect available skills.',
        ),
      );
    }

    // Enforce CSpace matching without ever escalating caller capabilities.
    final accessErr = registry.checkAccess(cspace, namespace, manifest);
    if (accessErr != null) {
      return SyscallResult<Map<String, dynamic>>.failure(accessErr);
    }

    // Re-verify real-path & symlink boundary at read time ([D-204] §3.2(2)).
    final resolvedResult = namespace.resolveVirtualPath(
      manifest.virtualPath,
      allowRoot: false,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!resolvedResult.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(resolvedResult.error!);
    }
    final resolved = resolvedResult.value!;

    final entityType =
        FileSystemEntity.typeSync(resolved.hostPath, followLinks: true);
    if (entityType == FileSystemEntityType.notFound) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'SKILL_FILE_NOT_FOUND',
          message:
              'Skill file "${manifest.virtualPath}" no longer exists on host.',
          recoverable: true,
        ),
      );
    }
    if (entityType != FileSystemEntityType.file) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'NOT_A_REGULAR_FILE',
          message: 'Skill path "${manifest.virtualPath}" is not a regular file.',
          recoverable: true,
        ),
      );
    }

    final List<int> bytes;
    final FileStat stat;
    try {
      final file = File(resolved.hostPath);
      stat = await file.stat();
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'SKILL_READ_FAILED',
          message: 'Failed to read skill "${manifest.name}": ${e.message}',
          recoverable: false,
        ),
      );
    }

    if (SkillDirectoryLoader._containsNulByte(bytes)) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'BINARY_FILE',
          message: 'Skill file "${manifest.virtualPath}" appears to be binary.',
          recoverable: true,
        ),
      );
    }

    final String decoded;
    try {
      decoded = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'BINARY_FILE',
          message:
              'Skill file "${manifest.virtualPath}" is not valid UTF-8 text.',
          recoverable: true,
        ),
      );
    }

    final fileSha256 = sha256.convert(bytes).toString();
    final sortedCaps = manifest.requiredCapabilities.map((r) => r.name).toList()
      ..sort();

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'name': manifest.name,
      'description': manifest.description,
      'virtualPath': manifest.virtualPath,
      'sha256': fileSha256,
      'modifiedUtc': stat.modified.toUtc().toIso8601String(),
      'byteLength': bytes.length,
      'requiredCapabilities': sortedCaps,
      'content': decoded,
    });
  }

  /// Registers `sys_skill_list` and `sys_skill_read` on [gate].
  void registerSyscalls(SyscallGate gate) {
    for (final def in buildSyscallDefinitions()) {
      gate.registerSyscall(def);
    }
  }

  /// Builds [SyscallDefinition] entries for `sys_skill_list` and `sys_skill_read` ([D-202], [D-219]).
  List<SyscallDefinition> buildSyscallDefinitions() {
    return <SyscallDefinition>[
      SyscallDefinition(
        name: 'sys_skill_list',
        requiredRight: CapRight.read,
        kind: 'read',
        applyIoCap: false,
        checkPreconditions: (pcb, _) async {
          if (!pcb.namespace.isSkillsMounted) {
            return const SyscallError(
              code: SyscallErrorCode.eacces,
              reason: 'SKILLS_NOT_MOUNTED',
              message: '/skills is not mounted in this namespace.',
              recoverable: false,
            );
          }
          return null;
        },
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => listSkills(
          cspace: exec.pcb.cspace,
          namespace: exec.pcb.namespace,
        ),
      ),
      SyscallDefinition(
        name: 'sys_skill_read',
        requiredRight: CapRight.read,
        kind: 'read',
        applyIoCap: true,
        cappedTextFields: const <String>['content'],
        validateArgs: _validateSkillReadArgs,
        checkPreconditions: (pcb, args) async {
          if (!pcb.namespace.isSkillsMounted) {
            return const SyscallError(
              code: SyscallErrorCode.eacces,
              reason: 'SKILLS_NOT_MOUNTED',
              message: '/skills is not mounted in this namespace.',
              recoverable: false,
            );
          }
          final rawName = (args['name'] as String).trim();
          if (!SkillRegistry.isValidSkillName(rawName)) {
            return SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'INVALID_SKILL_NAME',
              message: 'Invalid skill name "$rawName".',
              recoverable: true,
            );
          }
          final manifest = pcb.namespace.skillsMount!.lookup(rawName);
          if (manifest != null) {
            final accessErr = pcb.namespace.skillsMount!.checkAccess(
              pcb.cspace,
              pcb.namespace,
              manifest,
            );
            if (accessErr != null) {
              return accessErr;
            }
          }
          return null;
        },
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => readSkill(
          name: exec.args['name'] as String,
          cspace: exec.pcb.cspace,
          namespace: exec.pcb.namespace,
        ),
      ),
    ];
  }

  /// Returns canonical tool schemas for `sys_skill_list` and `sys_skill_read` ([D-202], [D-219]).
  static List<SyscallToolSchema> toolSchemas() {
    return <SyscallToolSchema>[
      SyscallToolSchema(
        name: 'sys_skill_list',
        description:
            'List read-only external SKILL.md packages mounted under /skills that are permitted for this process.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
      ),
      SyscallToolSchema(
        name: 'sys_skill_read',
        description:
            'Read the full UTF-8 Markdown content of a mounted skill under /skills/<name>/SKILL.md on demand.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'name': <String, dynamic>{
              'type': 'string',
              'description':
                  'Skill identifier returned by sys_skill_list (e.g. "jj-stacked-workflow").',
            },
          },
          'required': <String>['name'],
        },
      ),
    ];
  }

  static SyscallError? _validateSkillReadArgs(Map<String, dynamic> args) {
    final name = args['name'];
    if (name is! String || name.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "name" must be a non-empty skill identifier string.',
        recoverable: true,
      );
    }
    return null;
  }
}

class _FrontmatterParseResult {
  const _FrontmatterParseResult.success(Map<String, dynamic> this.metadata)
      : ok = true,
        errorMessage = null;

  const _FrontmatterParseResult.failure(String this.errorMessage)
      : ok = false,
        metadata = null;

  final bool ok;
  final Map<String, dynamic>? metadata;
  final String? errorMessage;
}

class _CapabilitiesParseResult {
  const _CapabilitiesParseResult.success(Set<CapRight> this.capabilities)
      : ok = true,
        errorReason = null,
        errorMessage = null;

  const _CapabilitiesParseResult.failure({
    required String reason,
    required String message,
  })  : ok = false,
        capabilities = null,
        errorReason = reason,
        errorMessage = message;

  final bool ok;
  final Set<CapRight>? capabilities;
  final String? errorReason;
  final String? errorMessage;
}
