import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// Callback invoked prior to workspace file mutation to isolate a CoW change ([D-015]).
typedef EnsureActiveTransactionCallback =
    Future<SyscallResult<Object?>> Function();

/// Callback invoked after workspace file mutation to synchronize `jj` snapshots ([D-014]).
typedef SyncWorkingCopySnapshotCallback =
    Future<SyscallResult<Object?>> Function();

/// Non-destructive provider returning the current `@` `commit_id` for VCS Clean Page metadata ([D-208]).
typedef CurrentCommitIdProvider = Future<String?> Function();

/// Host filesystem Read-Only & CAS Write driver scoped to a [VfsNamespace] ([D-011], [D-012], [D-013]).
///
/// Enforces real-path symlink/junction boundary checks, bidirectional protection
/// of `.jj`, `.git`, `.agent_os`, and `.env*`, automatic skipping during parent
/// scans, binary rejection/skipping, whole-file SHA-256 computation, and CAS
/// atomic writes integrated with Jujutsu CoW transactions.
class HostFsDriver {
  HostFsDriver({
    required this.namespace,
    EnsureActiveTransactionCallback? ensureActiveTransaction,
    SyncWorkingCopySnapshotCallback? syncWorkingCopySnapshot,
    CurrentCommitIdProvider? currentCommitIdProvider,
  })  : _ensureActiveTransaction = ensureActiveTransaction,
        _syncWorkingCopySnapshot = syncWorkingCopySnapshot,
        _currentCommitIdProvider = currentCommitIdProvider;

  factory HostFsDriver.forWorkspace(
    String workspaceHostRoot, {
    EnsureActiveTransactionCallback? ensureActiveTransaction,
    SyncWorkingCopySnapshotCallback? syncWorkingCopySnapshot,
    CurrentCommitIdProvider? currentCommitIdProvider,
  }) {
    return HostFsDriver(
      namespace: VfsNamespace(workspaceHostRoot: workspaceHostRoot),
      ensureActiveTransaction: ensureActiveTransaction,
      syncWorkingCopySnapshot: syncWorkingCopySnapshot,
      currentCommitIdProvider: currentCommitIdProvider,
    );
  }

  final VfsNamespace namespace;
  final EnsureActiveTransactionCallback? _ensureActiveTransaction;
  final SyncWorkingCopySnapshotCallback? _syncWorkingCopySnapshot;
  final CurrentCommitIdProvider? _currentCommitIdProvider;

  static final RegExp _drivePrefixPattern = RegExp(r'^[a-zA-Z]:');
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
  static int _tempFileCounter = 0;

  /// Reads a 1-based closed line range from a UTF-8 text file in `/workspace` or read-only `/skills` ([D-012], [D-219]).
  Future<SyscallResult<Map<String, dynamic>>> readLines({
    required String path,
    int? startLine,
    int? endLine,
    VfsNamespace? namespaceOverride,
    CapabilityTable? cspace,
  }) async {
    final effectiveNamespace = namespaceOverride ?? namespace;
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

    final resolvedResult = effectiveNamespace.resolveVirtualPath(
      path,
      allowRoot: false,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!resolvedResult.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(resolvedResult.error!);
    }
    final resolved = resolvedResult.value!;

    // Enforce SkillRegistry CSpace capability check for /skills/<name>/... reads ([D-219]).
    if (resolved.isSkillsMount) {
      final skillErr = _checkSkillsReadAccess(
        resolved: resolved,
        effectiveNamespace: effectiveNamespace,
        cspace: cspace,
      );
      if (skillErr != null) {
        return SyscallResult<Map<String, dynamic>>.failure(skillErr);
      }
    }

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
    final FileStat stat;
    try {
      final file = File(resolved.hostPath);
      stat = await file.stat();
      bytes = await file.readAsBytes();
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
      'modifiedUtc': stat.modified.toUtc().toIso8601String(),
      'byteLength': bytes.length,
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
    VfsNamespace? namespaceOverride,
  }) async {
    final effectiveNamespace = namespaceOverride ?? namespace;
    final patternError = _validatePatternSafety(
      pattern,
      effectiveNamespace: effectiveNamespace,
    );
    if (patternError != null) {
      return SyscallResult<Map<String, dynamic>>.failure(patternError);
    }

    final effectiveSubpath = subpath ??
        (effectiveNamespace.allowedWorkspaceSubpaths != null &&
                effectiveNamespace.allowedWorkspaceSubpaths!.length == 1
            ? effectiveNamespace.allowedWorkspaceSubpaths!.first
            : VfsNamespace.virtualRoot);

    final baseResult = effectiveNamespace.resolveVirtualPath(
      effectiveSubpath,
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

    final files = _collectWorkspaceFiles(
      baseRes,
      effectiveNamespace: effectiveNamespace,
    );
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

    final commitId = await _readCurrentCommitIdSafe();

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'basePath': baseRes.virtualPath,
      'matches': matches,
      'totalCount': matches.length,
      'commitId': ?commitId,
    });
  }

  /// Searches UTF-8 text files under [subpath] for [pattern] ([D-011], [D-012]).
  Future<SyscallResult<Map<String, dynamic>>> grep({
    required String pattern,
    String? subpath,
    bool isRegex = false,
    bool caseSensitive = true,
    String? includeGlob,
    VfsNamespace? namespaceOverride,
  }) async {
    final effectiveNamespace = namespaceOverride ?? namespace;
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
      final globErr = _validatePatternSafety(
        includeGlob,
        effectiveNamespace: effectiveNamespace,
      );
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

    final effectiveSubpath = subpath ??
        (effectiveNamespace.allowedWorkspaceSubpaths != null &&
                effectiveNamespace.allowedWorkspaceSubpaths!.length == 1
            ? effectiveNamespace.allowedWorkspaceSubpaths!.first
            : VfsNamespace.virtualRoot);

    final baseResult = effectiveNamespace.resolveVirtualPath(
      effectiveSubpath,
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
      candidateFiles = _collectWorkspaceFiles(
        baseRes,
        effectiveNamespace: effectiveNamespace,
      );
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

    final commitId = await _readCurrentCommitIdSafe();

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'matches': matches,
      'totalMatches': matches.length,
      'commitId': ?commitId,
    });
  }

  Future<String?> _readCurrentCommitIdSafe() async {
    final provider = _currentCommitIdProvider;
    if (provider == null) {
      return null;
    }
    try {
      final id = await provider();
      if (id == null) {
        return null;
      }
      final trimmed = id.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  /// Atomically replaces a unique [oldBlock] in an existing file after CAS SHA-256 verification ([D-013]).
  ///
  /// Guarantees zero byte modification to the target file on any validation,
  /// boundary, CAS mismatch, or block-matching failure.
  Future<SyscallResult<Map<String, dynamic>>> editBlock({
    required String path,
    required String expectedSha256,
    required String oldBlock,
    required String newBlock,
    VfsNamespace? namespaceOverride,
  }) async {
    final effectiveNamespace = namespaceOverride ?? namespace;
    if (path.trim().isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message: 'Argument "path" must be a non-empty string.',
          recoverable: true,
        ),
      );
    }
    final normalizedExpected = expectedSha256.trim().toLowerCase();
    if (!_sha256Pattern.hasMatch(normalizedExpected)) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_SHA256',
          message: 'Argument "expectedSha256" must be a 64-character hex SHA-256 digest.',
          recoverable: true,
        ),
      );
    }
    if (oldBlock.isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'EMPTY_OLD_BLOCK',
          message: 'Argument "oldBlock" must not be empty.',
          recoverable: true,
        ),
      );
    }

    final resolvedResult = effectiveNamespace.resolveWriteVirtualPath(
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
          message: 'Path "${resolved.virtualPath}" is a directory and cannot be edited.',
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

    final actualSha256 = sha256.convert(bytes).toString();
    if (actualSha256 != normalizedExpected) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.econflict,
          reason: 'CAS_HASH_MISMATCH',
          message:
              'CAS SHA-256 mismatch for "${resolved.virtualPath}": expected $normalizedExpected, actual $actualSha256.',
          recoverable: true,
          hint:
              'Re-read "${resolved.virtualPath}" with sys_read_lines to obtain the latest sha256 and content.',
          details: <String, dynamic>{
            'path': resolved.virtualPath,
            'expectedSha256': normalizedExpected,
            'actualSha256': actualSha256,
          },
        ),
      );
    }

    if (_containsNulByte(bytes)) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'BINARY_FILE',
          message: 'File "${resolved.virtualPath}" is binary and cannot be block-edited.',
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
          message: 'File "${resolved.virtualPath}" is not valid UTF-8 text.',
          recoverable: true,
        ),
      );
    }

    var effectiveNewBlock = newBlock;
    var matchOffsets = _findAllMatchOffsets(decoded, oldBlock);
    var matchedNeedleLength = oldBlock.length;

    if (matchOffsets.isEmpty) {
      final dominantEol = _detectDominantEol(decoded);
      final normalizedOld = _normalizeEol(oldBlock, dominantEol);
      if (normalizedOld != oldBlock) {
        final normalizedMatches = _findAllMatchOffsets(decoded, normalizedOld);
        if (normalizedMatches.isNotEmpty) {
          matchOffsets = normalizedMatches;
          matchedNeedleLength = normalizedOld.length;
          effectiveNewBlock = _normalizeEol(newBlock, dominantEol);
        }
      }
    }

    if (matchOffsets.isEmpty) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.econflict,
          reason: 'TARGET_BLOCK_NOT_FOUND',
          message:
              'Target oldBlock was not found in "${resolved.virtualPath}".',
          recoverable: true,
          hint:
              'Inspect the file via sys_read_lines and supply an exact matching block.',
        ),
      );
    }

    if (matchOffsets.length > 1) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.econflict,
          reason: 'AMBIGUOUS_BLOCK_MATCH',
          message:
              'Target oldBlock matched ${matchOffsets.length} locations in "${resolved.virtualPath}"; block must match uniquely.',
          recoverable: true,
          hint:
              'Include additional surrounding context lines in oldBlock so it matches exactly once.',
          details: <String, dynamic>{
            'path': resolved.virtualPath,
            'matchCount': matchOffsets.length,
          },
        ),
      );
    }

    // All preconditions passed: ensure CoW transaction isolation before touching disk.
    if (_ensureActiveTransaction != null) {
      final txRes = await _ensureActiveTransaction();
      if (!txRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(txRes.error!);
      }
    }

    final matchStart = matchOffsets.first;
    final updatedText = decoded.replaceRange(
      matchStart,
      matchStart + matchedNeedleLength,
      effectiveNewBlock,
    );
    final newBytes = utf8.encode(updatedText);

    final writeErr = await _atomicWriteBytes(resolved.hostPath, newBytes);
    if (writeErr != null) {
      return SyscallResult<Map<String, dynamic>>.failure(writeErr);
    }

    final newSha256 = sha256.convert(newBytes).toString();

    if (_syncWorkingCopySnapshot != null) {
      final syncRes = await _syncWorkingCopySnapshot();
      if (!syncRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(syncRes.error!);
      }
    }

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'path': resolved.virtualPath,
      'previousSha256': actualSha256,
      'newSha256': newSha256,
      'bytesWritten': newBytes.length,
    });
  }

  /// Creates a new file or performs a CAS-verified whole-file overwrite ([D-013], OM-03).
  ///
  /// - Create mode (`createOnly == true` or `expectedSha256 == null`): returns `EEXIST`
  ///   (`FILE_ALREADY_EXISTS_READ_FIRST`) if the target already exists.
  /// - Update mode (`expectedSha256 != null && !createOnly`): returns `ENOENT` if missing
  ///   or `ECONFLICT` (`CAS_HASH_MISMATCH`) if the file's SHA-256 changed.
  Future<SyscallResult<Map<String, dynamic>>> writeFile({
    required String path,
    required String content,
    String? expectedSha256,
    bool createOnly = false,
    VfsNamespace? namespaceOverride,
  }) async {
    final effectiveNamespace = namespaceOverride ?? namespace;
    if (path.trim().isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message: 'Argument "path" must be a non-empty string.',
          recoverable: true,
        ),
      );
    }
    String? normalizedExpected;
    if (expectedSha256 != null) {
      normalizedExpected = expectedSha256.trim().toLowerCase();
      if (!_sha256Pattern.hasMatch(normalizedExpected)) {
        return const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_SHA256',
            message:
                'Argument "expectedSha256" must be a 64-character hex SHA-256 digest when provided.',
            recoverable: true,
          ),
        );
      }
    }

    final resolvedResult = effectiveNamespace.resolveWriteVirtualPath(
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
    if (entityType == FileSystemEntityType.directory) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'IS_DIRECTORY',
          message: 'Path "${resolved.virtualPath}" is a directory and cannot be overwritten.',
          recoverable: true,
        ),
      );
    }

    final bool isCreateMode = createOnly || normalizedExpected == null;
    String? previousSha256;

    if (isCreateMode) {
      if (entityType != FileSystemEntityType.notFound) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eexist,
            reason: 'FILE_ALREADY_EXISTS_READ_FIRST',
            message:
                'File "${resolved.virtualPath}" already exists. Read it with sys_read_lines and provide expectedSha256 to update.',
            recoverable: true,
            hint:
                'Call sys_read_lines("${resolved.virtualPath}") first to obtain sha256, then pass expectedSha256 (with createOnly: false) or use sys_edit_block.',
          ),
        );
      }
    } else {
      if (entityType == FileSystemEntityType.notFound) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'FILE_NOT_FOUND',
            message:
                'File "${resolved.virtualPath}" does not exist for CAS update.',
            recoverable: true,
            hint: 'Omit expectedSha256 to create a new file.',
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

      final List<int> existingBytes;
      try {
        existingBytes = await File(resolved.hostPath).readAsBytes();
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
      final actualSha256 = sha256.convert(existingBytes).toString();
      if (actualSha256 != normalizedExpected) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.econflict,
            reason: 'CAS_HASH_MISMATCH',
            message:
                'CAS SHA-256 mismatch for "${resolved.virtualPath}": expected $normalizedExpected, actual $actualSha256.',
            recoverable: true,
            hint:
                'Re-read "${resolved.virtualPath}" with sys_read_lines to obtain the latest sha256.',
            details: <String, dynamic>{
              'path': resolved.virtualPath,
              'expectedSha256': normalizedExpected,
              'actualSha256': actualSha256,
            },
          ),
        );
      }
      previousSha256 = actualSha256;
    }

    // All preconditions passed: ensure CoW transaction isolation before touching disk.
    if (_ensureActiveTransaction != null) {
      final txRes = await _ensureActiveTransaction();
      if (!txRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(txRes.error!);
      }
    }

    try {
      final parentDir = Directory(p.dirname(resolved.hostPath));
      if (!parentDir.existsSync()) {
        await parentDir.create(recursive: true);
      }
    } on FileSystemException catch (e) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'DIRECTORY_CREATE_FAILED',
          message:
              'Failed to create parent directory for "${resolved.virtualPath}": ${e.message}',
          recoverable: false,
        ),
      );
    }

    final newBytes = utf8.encode(content);
    final writeErr = await _atomicWriteBytes(resolved.hostPath, newBytes);
    if (writeErr != null) {
      return SyscallResult<Map<String, dynamic>>.failure(writeErr);
    }

    final newSha256 = sha256.convert(newBytes).toString();

    if (_syncWorkingCopySnapshot != null) {
      final syncRes = await _syncWorkingCopySnapshot();
      if (!syncRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(syncRes.error!);
      }
    }

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'path': resolved.virtualPath,
      'created': isCreateMode,
      'previousSha256': previousSha256,
      'newSha256': newSha256,
      'bytesWritten': newBytes.length,
    });
  }

  /// Registers `sys_read_lines`, `sys_glob`, and `sys_grep` on [gate].
  void registerReadSyscalls(SyscallGate gate) {
    for (final def in buildReadSyscallDefinitions()) {
      gate.registerSyscall(def);
    }
  }

  /// Registers `sys_edit_block` and `sys_write_file` on [gate].
  void registerWriteSyscalls(SyscallGate gate) {
    for (final def in buildWriteSyscallDefinitions()) {
      gate.registerSyscall(def);
    }
  }

  /// Registers both Read-Only and CAS Write VFS syscalls on [gate].
  void registerAllSyscalls(SyscallGate gate) {
    registerReadSyscalls(gate);
    registerWriteSyscalls(gate);
  }

  /// Builds all Read-Only and CAS Write VFS [SyscallDefinition] entries ([D-012], [D-013]).
  List<SyscallDefinition> buildAllSyscallDefinitions() {
    return <SyscallDefinition>[
      ...buildReadSyscallDefinitions(),
      ...buildWriteSyscallDefinitions(),
    ];
  }

  /// Builds [SyscallDefinition] entries for CAS Write VFS syscalls ([D-002], [D-003], [D-013]).
  List<SyscallDefinition> buildWriteSyscallDefinitions() {
    return <SyscallDefinition>[
      SyscallDefinition(
        name: 'sys_edit_block',
        requiredRight: CapRight.writeCow,
        kind: 'edit',
        applyIoCap: false,
        validateArgs: _validateEditBlockArgs,
        checkPreconditions: (pcb, args) async => _checkWritePathPrecondition(
          args['path'] as String,
          effectiveNamespace: pcb.namespace,
        ),
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => editBlock(
          path: exec.args['path'] as String,
          expectedSha256: exec.args['expectedSha256'] as String,
          oldBlock: exec.args['oldBlock'] as String,
          newBlock: exec.args['newBlock'] as String,
          namespaceOverride: exec.pcb.namespace,
        ),
      ),
      SyscallDefinition(
        name: 'sys_write_file',
        requiredRight: CapRight.writeCow,
        kind: 'edit',
        applyIoCap: false,
        validateArgs: _validateWriteFileArgs,
        checkPreconditions: (pcb, args) async => _checkWritePathPrecondition(
          args['path'] as String,
          effectiveNamespace: pcb.namespace,
        ),
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => writeFile(
          path: exec.args['path'] as String,
          content: exec.args['content'] as String,
          expectedSha256: exec.args['expectedSha256'] as String?,
          createOnly: exec.args['createOnly'] as bool? ?? false,
          namespaceOverride: exec.pcb.namespace,
        ),
      ),
    ];
  }

  /// Returns canonical tool schemas for all Read-Only and CAS Write VFS syscalls ([D-012], [D-013]).
  static List<SyscallToolSchema> allToolSchemas() {
    return <SyscallToolSchema>[
      ...readToolSchemas(),
      ...writeToolSchemas(),
    ];
  }

  /// Returns canonical tool schemas for `sys_edit_block` and `sys_write_file` ([D-007], [D-013]).
  static List<SyscallToolSchema> writeToolSchemas() {
    return <SyscallToolSchema>[
      SyscallToolSchema(
        name: 'sys_edit_block',
        description:
            'Replace a unique block of text in an existing file inside /workspace after verifying whole-file SHA-256 (CAS).',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'path': <String, dynamic>{
              'type': 'string',
              'description': 'Virtual path under /workspace.',
            },
            'expectedSha256': <String, dynamic>{
              'type': 'string',
              'description':
                  '64-character lowercase/uppercase hex SHA-256 digest from sys_read_lines or previous edit.',
            },
            'oldBlock': <String, dynamic>{
              'type': 'string',
              'description': 'Exact non-empty text block to replace (must match uniquely).',
            },
            'newBlock': <String, dynamic>{
              'type': 'string',
              'description': 'Replacement text block (may be empty to delete oldBlock).',
            },
          },
          'required': <String>['path', 'expectedSha256', 'oldBlock', 'newBlock'],
        },
      ),
      SyscallToolSchema(
        name: 'sys_write_file',
        description:
            'Create a new file or overwrite an existing file in /workspace with mandatory CAS SHA-256 verification for existing files.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'path': <String, dynamic>{
              'type': 'string',
              'description': 'Virtual path under /workspace.',
            },
            'content': <String, dynamic>{
              'type': 'string',
              'description': 'Complete UTF-8 text content to write.',
            },
            'expectedSha256': <String, dynamic>{
              'type': 'string',
              'description':
                  'Required 64-character hex SHA-256 when overwriting an existing file; omit when creating a new file.',
            },
            'createOnly': <String, dynamic>{
              'type': 'boolean',
              'description':
                  'When true, strictly requires the target file not to exist (default false).',
            },
          },
          'required': <String>['path', 'content'],
        },
      ),
    ];
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
        checkPreconditions: (pcb, args) async => _checkReadPathPrecondition(
          args['path'] as String,
          effectiveNamespace: pcb.namespace,
          cspace: pcb.cspace,
        ),
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => readLines(
          path: exec.args['path'] as String,
          startLine: exec.args['startLine'] as int?,
          endLine: exec.args['endLine'] as int?,
          namespaceOverride: exec.pcb.namespace,
          cspace: exec.pcb.cspace,
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
          namespaceOverride: exec.pcb.namespace,
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
          namespaceOverride: exec.pcb.namespace,
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

  SyscallError? _validatePatternSafety(
    String rawPattern, {
    VfsNamespace? effectiveNamespace,
  }) {
    final activeNs = effectiveNamespace ?? namespace;
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

    if (activeNs.isProtectedPattern(rawPattern)) {
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

  List<_CollectedFile> _collectWorkspaceFiles(
    VfsPathResolution baseRes, {
    VfsNamespace? effectiveNamespace,
  }) {
    final activeNs = effectiveNamespace ?? namespace;
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
        final virtualPath = activeNs.toVirtualPath(entity.path);

        if (activeNs.shouldSkipEntry(virtualPath)) {
          continue;
        }

        // Verify real-path boundary to block symlinks/junctions escaping /workspace or pointing into protected dirs.
        final verified = activeNs.resolveVirtualPath(
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

  SyscallError? _checkReadPathPrecondition(
    String rawPath, {
    VfsNamespace? effectiveNamespace,
    CapabilityTable? cspace,
  }) {
    final activeNs = effectiveNamespace ?? namespace;
    final resolved = activeNs.resolveVirtualPath(
      rawPath,
      allowRoot: false,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!resolved.ok) {
      return resolved.error;
    }
    if (resolved.value!.isSkillsMount) {
      return _checkSkillsReadAccess(
        resolved: resolved.value!,
        effectiveNamespace: activeNs,
        cspace: cspace,
      );
    }
    return null;
  }

  SyscallError? _checkSkillsReadAccess({
    required VfsPathResolution resolved,
    required VfsNamespace effectiveNamespace,
    CapabilityTable? cspace,
  }) {
    final registry = effectiveNamespace.skillsMount;
    final skillName = resolved.skillName;
    if (registry == null || skillName == null) {
      return const SyscallError(
        code: SyscallErrorCode.eacces,
        reason: 'SKILLS_NOT_MOUNTED',
        message: '/skills is not mounted in this namespace.',
        recoverable: false,
      );
    }
    final manifest = registry.lookup(skillName);
    if (manifest == null) {
      return SyscallError(
        code: SyscallErrorCode.enoent,
        reason: 'SKILL_NOT_FOUND',
        message: 'Skill "$skillName" is not mounted under /skills.',
        recoverable: true,
      );
    }
    if (cspace != null) {
      return registry.checkAccess(cspace, effectiveNamespace, manifest);
    }
    return null;
  }

  SyscallError? _checkWritePathPrecondition(
    String rawPath, {
    VfsNamespace? effectiveNamespace,
  }) {
    final activeNs = effectiveNamespace ?? namespace;
    final resolved = activeNs.resolveWriteVirtualPath(
      rawPath,
      allowRoot: false,
      checkProtected: true,
      checkSymlinks: true,
    );
    return resolved.ok ? null : resolved.error;
  }

  static SyscallError? _validateEditBlockArgs(Map<String, dynamic> args) {
    final path = args['path'];
    if (path is! String || path.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "path" must be a non-empty string.',
        recoverable: true,
      );
    }
    final expectedSha256 = args['expectedSha256'];
    if (expectedSha256 is! String ||
        !_sha256Pattern.hasMatch(expectedSha256.trim())) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_SHA256',
        message:
            'Argument "expectedSha256" must be a 64-character hex SHA-256 digest.',
        recoverable: true,
      );
    }
    final oldBlock = args['oldBlock'];
    if (oldBlock is! String || oldBlock.isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'EMPTY_OLD_BLOCK',
        message: 'Argument "oldBlock" must be a non-empty string.',
        recoverable: true,
      );
    }
    final newBlock = args['newBlock'];
    if (newBlock is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "newBlock" must be a string.',
        recoverable: true,
      );
    }
    return null;
  }

  static SyscallError? _validateWriteFileArgs(Map<String, dynamic> args) {
    final path = args['path'];
    if (path is! String || path.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "path" must be a non-empty string.',
        recoverable: true,
      );
    }
    final content = args['content'];
    if (content is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "content" must be a string.',
        recoverable: true,
      );
    }
    final expectedSha256 = args['expectedSha256'];
    if (expectedSha256 != null &&
        (expectedSha256 is! String ||
            !_sha256Pattern.hasMatch(expectedSha256.trim()))) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_SHA256',
        message:
            'Argument "expectedSha256" must be a 64-character hex SHA-256 digest when provided.',
        recoverable: true,
      );
    }
    final createOnly = args['createOnly'];
    if (createOnly != null && createOnly is! bool) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "createOnly" must be a boolean.',
        recoverable: true,
      );
    }
    return null;
  }

  static List<int> _findAllMatchOffsets(String haystack, String needle) {
    if (needle.isEmpty) {
      return const <int>[];
    }
    final offsets = <int>[];
    var start = 0;
    while (start <= haystack.length - needle.length) {
      final idx = haystack.indexOf(needle, start);
      if (idx < 0) {
        break;
      }
      offsets.add(idx);
      start = idx + 1;
    }
    return offsets;
  }

  static String _detectDominantEol(String text) {
    var crlfCount = 0;
    var lfOnlyCount = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x0D /* \r */) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A /* \n */) {
          crlfCount++;
          i++;
        }
      } else if (unit == 0x0A /* \n */) {
        lfOnlyCount++;
      }
    }
    if (crlfCount > 0 && crlfCount >= lfOnlyCount) {
      return '\r\n';
    }
    return '\n';
  }

  static String _normalizeEol(String input, String targetEol) {
    final unified = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (targetEol == '\r\n') {
      return unified.replaceAll('\n', '\r\n');
    }
    return unified;
  }

  Future<SyscallError?> _atomicWriteBytes(String hostPath, List<int> bytes) async {
    final parentDir = p.dirname(hostPath);
    final baseName = p.basename(hostPath);
    final seq = _tempFileCounter++;
    final tempPath = p.join(
      parentDir,
      '.agent_os_tmp_${pid}_${DateTime.now().microsecondsSinceEpoch}_${seq}_$baseName',
    );
    final tempFile = File(tempPath);
    try {
      await tempFile.writeAsBytes(bytes, flush: true);
      await tempFile.rename(hostPath);
      return null;
    } on FileSystemException catch (e) {
      try {
        if (tempFile.existsSync()) {
          tempFile.deleteSync();
        }
      } catch (_) {
        // Best-effort cleanup of temp file.
      }
      return SyscallError(
        code: SyscallErrorCode.eio,
        reason: 'FILE_WRITE_FAILED',
        message: 'Failed to atomically write "$hostPath": ${e.message}',
        recoverable: false,
      );
    }
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
