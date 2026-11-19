import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Host filesystem Read-Only driver scoped to a [VfsNamespace] ([D-011], [D-012]).
///
/// Enforces real-path symlink/junction boundary checks, bidirectional protection
/// of `.jj`, `.git`, `.agent_os`, and `.env*`, automatic skipping during parent
/// scans, binary rejection/skipping, and whole-file SHA-256 computation.
class HostFsDriver {
  HostFsDriver({required this.namespace});

  factory HostFsDriver.forWorkspace(String workspaceHostRoot) {
    return HostFsDriver(
      namespace: VfsNamespace(workspaceHostRoot: workspaceHostRoot),
    );
  }

  final VfsNamespace namespace;

  static final RegExp _drivePrefixPattern = RegExp(r'^[a-zA-Z]:');

  /// Reads a 1-based closed line range from a UTF-8 text file in `/workspace` ([D-012]).
  Future<SyscallResult<Map<String, dynamic>>> readLines({
    required String path,
    int? startLine,
    int? endLine,
  }) async {
    final effectiveStart = startLine ?? 1;
    final effectiveRequestedEnd = endLine ?? (effectiveStart + 199);

    if (effectiveStart < 1) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_LINE_RANGE',
          message: 'startLine must be >= 1 (got $startLine).',
          recoverable: true,
        ),
      );
    }
    if (effectiveRequestedEnd < effectiveStart) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_LINE_RANGE',
          message:
              'endLine ($effectiveRequestedEnd) must be >= startLine ($effectiveStart).',
          recoverable: true,
        ),
      );
    }

    final resolvedResult = namespace.resolveVirtualPath(
      path,
      allowRoot: false,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!resolvedResult.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(resolvedResult.error!);
    }
    final resolved = resolvedResult.value!;

    final entityType = FileSystemEntity.typeSync(
      resolved.hostPath,
      followLinks: true,
    );
    if (entityType == FileSystemEntityType.notFound) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'FILE_NOT_FOUND',
          message: 'File "${resolved.virtualPath}" does not exist.',
          recoverable: true,
        ),
      );
    }
    if (entityType == FileSystemEntityType.directory) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'IS_DIRECTORY',
          message:
              'Path "${resolved.virtualPath}" is a directory; use sys_glob or specify a file path.',
          recoverable: true,
        ),
      );
    }
    if (entityType != FileSystemEntityType.file) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'NOT_A_REGULAR_FILE',
          message: 'Path "${resolved.virtualPath}" is not a regular file.',
          recoverable: true,
        ),
      );
    }

    final List<int> bytes;
    try {
      bytes = await File(resolved.hostPath).readAsBytes();
    } on FileSystemException catch (e) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'FILE_READ_FAILED',
          message: 'Failed to read "${resolved.virtualPath}": ${e.message}',
          recoverable: false,
        ),
      );
    }

    final fileSha256 = sha256.convert(bytes).toString();

    if (_containsNulByte(bytes)) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'BINARY_FILE',
          message:
              'File "${resolved.virtualPath}" appears to be binary (contains NUL byte).',
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
              'File "${resolved.virtualPath}" is not valid UTF-8 text and cannot be read as lines.',
          recoverable: true,
        ),
      );
    }

    final lineSpans = _computeLineSpans(decoded);
    final totalLines = lineSpans.length;

    final String content;
    final int clampedEnd;
    if (totalLines == 0 || effectiveStart > totalLines) {
      content = '';
      clampedEnd = math.min(effectiveRequestedEnd, totalLines);
    } else {
      clampedEnd = math.min(effectiveRequestedEnd, totalLines);
      final sliceStart = lineSpans[effectiveStart - 1].start;
      final sliceEnd = lineSpans[clampedEnd - 1].end;
      content = decoded.substring(sliceStart, sliceEnd);
    }

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'path': resolved.virtualPath,
      'sha256': fileSha256,
      'totalLines': totalLines,
      'startLine': effectiveStart,
      'endLine': clampedEnd,
      'content': content,
    });
  }

  /// Finds files matching [pattern] under [subpath] (default `/workspace`) ([D-011], [D-012]).
  Future<SyscallResult<Map<String, dynamic>>> glob({
    required String pattern,
    String? subpath,
  }) async {
    final patternError = _validatePatternSafety(pattern);
    if (patternError != null) {
      return SyscallResult<Map<String, dynamic>>.failure(patternError);
    }

    final baseResult = namespace.resolveVirtualPath(
      subpath ?? VfsNamespace.virtualRoot,
      allowRoot: true,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!baseResult.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(baseResult.error!);
    }
    final baseRes = baseResult.value!;

    final baseType = FileSystemEntity.typeSync(
      baseRes.hostPath,
      followLinks: true,
    );
    if (baseType == FileSystemEntityType.notFound) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'DIRECTORY_NOT_FOUND',
          message: 'Subpath "${baseRes.virtualPath}" does not exist.',
          recoverable: true,
        ),
      );
    }
    if (baseType != FileSystemEntityType.directory) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'NOT_A_DIRECTORY',
          message: 'Subpath "${baseRes.virtualPath}" is not a directory.',
          recoverable: true,
        ),
      );
    }

    final normalizedInput = pattern.trim().replaceAll('\\', '/');
    final bool matchFromWorkspaceRoot =
        normalizedInput == VfsNamespace.virtualRoot ||
            normalizedInput.startsWith('${VfsNamespace.virtualRoot}/');

    var effectivePattern = normalizedInput;
    if (matchFromWorkspaceRoot) {
      effectivePattern = normalizedInput == VfsNamespace.virtualRoot
          ? ''
          : normalizedInput.substring(VfsNamespace.virtualRoot.length + 1);
    } else if (effectivePattern.startsWith('./')) {
      effectivePattern = effectivePattern.substring(2);
    }

    if (effectivePattern.isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_GLOB_PATTERN',
          message: 'Glob pattern must not be empty.',
          recoverable: true,
        ),
      );
    }

    final Glob matcher;
    try {
      matcher = Glob(
        effectivePattern,
        context: p.posix,
        caseSensitive: !Platform.isWindows,
      );
    } on Object catch (e) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_GLOB_PATTERN',
          message: 'Invalid glob pattern "$pattern": $e',
          recoverable: true,
        ),
      );
    }

    final files = _collectWorkspaceFiles(baseRes);
    final matches = <String>[];
    for (final file in files) {
      final candidate = matchFromWorkspaceRoot
          ? file.relFromWorkspaceRoot
          : file.relFromBase;
      if (matcher.matches(candidate)) {
        matches.add(file.virtualPath);
      }
    }
    matches.sort();

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'basePath': baseRes.virtualPath,
      'matches': matches,
      'totalCount': matches.length,
    });
  }

  /// Searches UTF-8 text files under [subpath] for [pattern] ([D-011], [D-012]).
  Future<SyscallResult<Map<String, dynamic>>> grep({
    required String pattern,
    String? subpath,
    bool isRegex = false,
    bool caseSensitive = true,
    String? includeGlob,
  }) async {
    if (pattern.isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_GREP_PATTERN',
          message: 'Search pattern must not be empty.',
          recoverable: true,
        ),
      );
    }

    RegExp? regex;
    if (isRegex) {
      try {
        regex = RegExp(pattern, caseSensitive: caseSensitive);
      } on FormatException catch (e) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_REGEX',
            message: 'Invalid regular expression "$pattern": ${e.message}',
            recoverable: true,
          ),
        );
      }
    }

    Glob? includeMatcher;
    var includeBasenameOnly = false;
    if (includeGlob != null && includeGlob.trim().isNotEmpty) {
      final globErr = _validatePatternSafety(includeGlob);
      if (globErr != null) {
        return SyscallResult<Map<String, dynamic>>.failure(globErr);
      }
      var normInclude = includeGlob.trim().replaceAll('\\', '/');
      if (normInclude.startsWith('${VfsNamespace.virtualRoot}/')) {
        normInclude = normInclude.substring(VfsNamespace.virtualRoot.length + 1);
      } else if (normInclude.startsWith('./')) {
        normInclude = normInclude.substring(2);
      }
      includeBasenameOnly = !normInclude.contains('/');
      try {
        includeMatcher = Glob(
          normInclude,
          context: p.posix,
          caseSensitive: !Platform.isWindows,
        );
      } on Object catch (e) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_GLOB_PATTERN',
            message: 'Invalid includeGlob "$includeGlob": $e',
            recoverable: true,
          ),
        );
      }
    }

    final baseResult = namespace.resolveVirtualPath(
      subpath ?? VfsNamespace.virtualRoot,
      allowRoot: true,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!baseResult.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(baseResult.error!);
    }
    final baseRes = baseResult.value!;

    final baseType = FileSystemEntity.typeSync(
      baseRes.hostPath,
      followLinks: true,
    );
    if (baseType == FileSystemEntityType.notFound) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'PATH_NOT_FOUND',
          message: 'Subpath "${baseRes.virtualPath}" does not exist.',
          recoverable: true,
        ),
      );
    }

    final List<_CollectedFile> candidateFiles;
    if (baseType == FileSystemEntityType.file) {
      final relWs = baseRes.relativeSegments.join('/');
      candidateFiles = <_CollectedFile>[
        _CollectedFile(
          virtualPath: baseRes.virtualPath,
          hostPath: baseRes.hostPath,
          relFromWorkspaceRoot: relWs,
          relFromBase: p.posix.basename(relWs),
        ),
      ];
    } else if (baseType == FileSystemEntityType.directory) {
      candidateFiles = _collectWorkspaceFiles(baseRes);
    } else {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'UNSUPPORTED_FILE_TYPE',
          message: 'Subpath "${baseRes.virtualPath}" is not a file or directory.',
          recoverable: true,
        ),
      );
    }

    candidateFiles.sort((a, b) => a.virtualPath.compareTo(b.virtualPath));

    final needleLower = caseSensitive ? pattern : pattern.toLowerCase();
    final matches = <Map<String, dynamic>>[];

    for (final file in candidateFiles) {
      if (includeMatcher != null) {
        final matchedInclude = includeBasenameOnly
            ? (includeMatcher.matches(p.posix.basename(file.relFromWorkspaceRoot)) ||
                includeMatcher.matches(file.relFromBase))
            : (includeMatcher.matches(file.relFromBase) ||
                includeMatcher.matches(file.relFromWorkspaceRoot));
        if (!matchedInclude) {
          continue;
        }
      }

      final List<int> bytes;
      try {
        bytes = await File(file.hostPath).readAsBytes();
      } on FileSystemException {
        continue;
      }
      if (_containsNulByte(bytes)) {
        continue;
      }

      final String decoded;
      try {
        decoded = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        continue;
      }

      final lines = decoded.isEmpty
          ? const <String>[]
          : const LineSplitter().convert(decoded);
      for (var i = 0; i < lines.length; i++) {
        final lineText = lines[i];
        final isMatch = regex != null
            ? regex.hasMatch(lineText)
            : (caseSensitive
                ? lineText.contains(pattern)
                : lineText.toLowerCase().contains(needleLower));
        if (isMatch) {
          matches.add(<String, dynamic>{
            'path': file.virtualPath,
            'line': i + 1,
            'text': lineText,
          });
        }
      }
    }

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'matches': matches,
      'totalMatches': matches.length,
    });
  }

  /// Registers `sys_read_lines`, `sys_glob`, and `sys_grep` on [gate].
  void registerReadSyscalls(SyscallGate gate) {
    for (final def in buildReadSyscallDefinitions()) {
      gate.registerSyscall(def);
    }
  }

  /// Builds [SyscallDefinition] entries for Read-Only VFS syscalls ([D-002], [D-006], [D-012]).
  List<SyscallDefinition> buildReadSyscallDefinitions() {
    return <SyscallDefinition>[
      SyscallDefinition(
        name: 'sys_read_lines',
        requiredRight: CapRight.read,
        kind: 'read',
        applyIoCap: true,
        cappedTextFields: const <String>['content'],
        validateArgs: _validateReadLinesArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => readLines(
          path: exec.args['path'] as String,
          startLine: exec.args['startLine'] as int?,
          endLine: exec.args['endLine'] as int?,
        ),
      ),
      SyscallDefinition(
        name: 'sys_glob',
        requiredRight: CapRight.read,
        kind: 'read',
        applyIoCap: true,
        cappedTextFields: const <String>['matches'],
        validateArgs: _validateGlobArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => glob(
          pattern: exec.args['pattern'] as String,
          subpath: exec.args['subpath'] as String?,
        ),
      ),
      SyscallDefinition(
        name: 'sys_grep',
        requiredRight: CapRight.read,
        kind: 'read',
        applyIoCap: true,
        cappedTextFields: const <String>['matches'],
        validateArgs: _validateGrepArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => grep(
          pattern: exec.args['pattern'] as String,
          subpath: exec.args['subpath'] as String?,
          isRegex: exec.args['isRegex'] as bool? ?? false,
          caseSensitive: exec.args['caseSensitive'] as bool? ?? true,
          includeGlob: exec.args['includeGlob'] as String?,
        ),
      ),
    ];
  }

  /// Returns canonical tool schemas for `sys_read_lines`, `sys_glob`, and `sys_grep` ([D-007], [D-012]).
  static List<SyscallToolSchema> readToolSchemas() {
    return <SyscallToolSchema>[
      SyscallToolSchema(
        name: 'sys_read_lines',
        description:
            'Read a 1-based line slice of a UTF-8 file inside /workspace, returning exact text plus whole-file sha256 and totalLines.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'path': <String, dynamic>{
              'type': 'string',
              'description': 'Virtual path under /workspace (e.g. /workspace/lib/main.dart).',
            },
            'startLine': <String, dynamic>{
              'type': 'integer',
              'description': '1-based start line (default 1).',
            },
            'endLine': <String, dynamic>{
              'type': 'integer',
              'description': '1-based inclusive end line (default startLine + 199).',
            },
          },
          'required': <String>['path'],
        },
      ),
      SyscallToolSchema(
        name: 'sys_glob',
        description:
            'Find files matching a glob pattern inside /workspace. Protected paths (.jj, .git, .agent_os, .env*) are skipped.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'pattern': <String, dynamic>{
              'type': 'string',
              'description': 'Glob pattern such as "lib/**/*.dart".',
            },
            'subpath': <String, dynamic>{
              'type': 'string',
              'description': 'Base directory under /workspace (default /workspace).',
            },
          },
          'required': <String>['pattern'],
        },
      ),
      SyscallToolSchema(
        name: 'sys_grep',
        description:
            'Search UTF-8 text files under /workspace for a substring or regular expression.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'pattern': <String, dynamic>{
              'type': 'string',
              'description': 'Text or regex pattern to search for.',
            },
            'subpath': <String, dynamic>{
              'type': 'string',
              'description': 'Directory or file under /workspace (default /workspace).',
            },
            'isRegex': <String, dynamic>{
              'type': 'boolean',
              'description': 'Treat pattern as regular expression (default false).',
            },
            'caseSensitive': <String, dynamic>{
              'type': 'boolean',
              'description': 'Case-sensitive search (default true).',
            },
            'includeGlob': <String, dynamic>{
              'type': 'string',
              'description': 'Optional glob filter (e.g. "*.dart").',
            },
          },
          'required': <String>['pattern'],
        },
      ),
    ];
  }

  static SyscallError? _validateReadLinesArgs(Map<String, dynamic> args) {
    final path = args['path'];
    if (path is! String || path.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "path" must be a non-empty string.',
        recoverable: true,
      );
    }
    final start = args['startLine'];
    if (start != null && start is! int) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "startLine" must be an integer.',
        recoverable: true,
      );
    }
    final end = args['endLine'];
    if (end != null && end is! int) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "endLine" must be an integer.',
        recoverable: true,
      );
    }
    final effectiveStart = (start as int?) ?? 1;
    final effectiveEnd = (end as int?) ?? (effectiveStart + 199);
    if (effectiveStart < 1 || effectiveEnd < effectiveStart) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_LINE_RANGE',
        message:
            'Invalid line range: startLine=$effectiveStart, endLine=$effectiveEnd.',
        recoverable: true,
      );
    }
    return null;
  }

  static SyscallError? _validateGlobArgs(Map<String, dynamic> args) {
    final pattern = args['pattern'];
    if (pattern is! String || pattern.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "pattern" must be a non-empty string.',
        recoverable: true,
      );
    }
    final subpath = args['subpath'];
    if (subpath != null && subpath is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "subpath" must be a string.',
        recoverable: true,
      );
    }
    return null;
  }

  static SyscallError? _validateGrepArgs(Map<String, dynamic> args) {
    final pattern = args['pattern'];
    if (pattern is! String || pattern.isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "pattern" must be a non-empty string.',
        recoverable: true,
      );
    }
    final subpath = args['subpath'];
    if (subpath != null && subpath is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "subpath" must be a string.',
        recoverable: true,
      );
    }
    final isRegex = args['isRegex'];
    if (isRegex != null && isRegex is! bool) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "isRegex" must be a boolean.',
        recoverable: true,
      );
    }
    final caseSensitive = args['caseSensitive'];
    if (caseSensitive != null && caseSensitive is! bool) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "caseSensitive" must be a boolean.',
        recoverable: true,
      );
    }
    final includeGlob = args['includeGlob'];
    if (includeGlob != null && includeGlob is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "includeGlob" must be a string.',
        recoverable: true,
      );
    }
    return null;
  }

  SyscallError? _validatePatternSafety(String rawPattern) {
    if (rawPattern.contains('\x00')) {
      return const SyscallError(
        code: SyscallErrorCode.eacces,
        reason: 'OUT_OF_WORKSPACE_SCOPE',
        message: 'Pattern contains NUL byte and is rejected.',
        recoverable: true,
      );
    }
    final trimmed = rawPattern.trim();
    if (trimmed.isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_GLOB_PATTERN',
        message: 'Pattern must not be empty.',
        recoverable: true,
      );
    }
    if (trimmed.startsWith(r'\\') ||
        trimmed.startsWith('//') ||
        _drivePrefixPattern.hasMatch(trimmed)) {
      return SyscallError(
        code: SyscallErrorCode.eacces,
        reason: 'OUT_OF_WORKSPACE_SCOPE',
        message: 'Pattern "$rawPattern" targets outside /workspace.',
        recoverable: true,
      );
    }
    final forward = trimmed.replaceAll('\\', '/');
    if (forward.startsWith('/') &&
        forward != VfsNamespace.virtualRoot &&
        !forward.startsWith('${VfsNamespace.virtualRoot}/')) {
      return SyscallError(
        code: SyscallErrorCode.eacces,
        reason: 'OUT_OF_WORKSPACE_SCOPE',
        message: 'Pattern "$rawPattern" is outside /workspace.',
        recoverable: true,
      );
    }
    final rel = forward.startsWith('${VfsNamespace.virtualRoot}/')
        ? forward.substring(VfsNamespace.virtualRoot.length + 1)
        : (forward == VfsNamespace.virtualRoot ? '' : forward);
    var depth = 0;
    for (final seg in rel.split('/')) {
      if (seg.isEmpty || seg == '.') {
        continue;
      }
      if (seg == '..') {
        depth--;
        if (depth < 0) {
          return SyscallError(
            code: SyscallErrorCode.eacces,
            reason: 'OUT_OF_WORKSPACE_SCOPE',
            message: 'Pattern "$rawPattern" attempts to escape /workspace.',
            recoverable: true,
          );
        }
      } else {
        depth++;
      }
    }

    if (namespace.isProtectedPattern(rawPattern)) {
      return SyscallError(
        code: SyscallErrorCode.eacces,
        reason: 'PROTECTED_INTERNAL_PATH',
        message:
            'Pattern "$rawPattern" directly targets a protected internal path (.jj, .git, .agent_os, .env*).',
        recoverable: true,
      );
    }
    return null;
  }

  List<_CollectedFile> _collectWorkspaceFiles(VfsPathResolution baseRes) {
    final results = <_CollectedFile>[];
    final visitedCanonicalDirs = <String>{};
    final queue = <({String hostDir, String relFromBase})>[
      (hostDir: baseRes.hostPath, relFromBase: ''),
    ];

    try {
      final canonicalBase = Directory(baseRes.hostPath).resolveSymbolicLinksSync();
      visitedCanonicalDirs.add(_canonicalKey(canonicalBase));
    } on FileSystemException {
      return results;
    }

    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final List<FileSystemEntity> entries;
      try {
        entries = Directory(current.hostDir).listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }

      for (final entity in entries) {
        final name = p.basename(entity.path);
        final relFromBase =
            current.relFromBase.isEmpty ? name : '${current.relFromBase}/$name';
        final virtualPath = namespace.toVirtualPath(entity.path);

        if (namespace.shouldSkipEntry(virtualPath)) {
          continue;
        }

        // Verify real-path boundary to block symlinks/junctions escaping /workspace or pointing into protected dirs.
        final verified = namespace.resolveVirtualPath(
          virtualPath,
          allowRoot: false,
          checkProtected: true,
          checkSymlinks: true,
        );
        if (!verified.ok) {
          continue;
        }

        final rawType = FileSystemEntity.typeSync(
          entity.path,
          followLinks: false,
        );
        FileSystemEntityType effectiveType = rawType;
        if (rawType == FileSystemEntityType.link) {
          effectiveType = FileSystemEntity.typeSync(
            entity.path,
            followLinks: true,
          );
        }

        if (effectiveType == FileSystemEntityType.directory) {
          try {
            final canonical = Directory(entity.path).resolveSymbolicLinksSync();
            final key = _canonicalKey(canonical);
            if (visitedCanonicalDirs.add(key)) {
              queue.add((hostDir: entity.path, relFromBase: relFromBase));
            }
          } on FileSystemException {
            continue;
          }
        } else if (effectiveType == FileSystemEntityType.file) {
          final relFromRoot = verified.value!.relativeSegments.join('/');
          results.add(
            _CollectedFile(
              virtualPath: verified.value!.virtualPath,
              hostPath: verified.value!.hostPath,
              relFromWorkspaceRoot: relFromRoot,
              relFromBase: relFromBase,
            ),
          );
        }
      }
    }

    return results;
  }

  static String _canonicalKey(String pathStr) {
    final normalized = p.normalize(pathStr);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static bool _containsNulByte(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) {
        return true;
      }
    }
    return false;
  }

  static List<({int start, int end})> _computeLineSpans(String text) {
    if (text.isEmpty) {
      return const <({int start, int end})>[];
    }
    final spans = <({int start, int end})>[];
    var lineStart = 0;
    var i = 0;
    while (i < text.length) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x0D /* \r */) {
        spans.add((start: lineStart, end: i));
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A /* \n */) {
          i += 2;
        } else {
          i += 1;
        }
        lineStart = i;
      } else if (unit == 0x0A /* \n */) {
        spans.add((start: lineStart, end: i));
        i += 1;
        lineStart = i;
      } else {
        i += 1;
      }
    }
    if (lineStart < text.length) {
      spans.add((start: lineStart, end: text.length));
    }
    return spans;
  }
}

class _CollectedFile {
  const _CollectedFile({
    required this.virtualPath,
    required this.hostPath,
    required this.relFromWorkspaceRoot,
    required this.relFromBase,
  });

  final String virtualPath;
  final String hostPath;
  final String relFromWorkspaceRoot;
  final String relFromBase;
}
