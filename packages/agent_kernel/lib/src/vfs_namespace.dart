import 'dart:io';

import 'package:path/path.dart' as p;

import 'syscall_error.dart';

/// Resolved virtual and host filesystem path within a [VfsNamespace] ([D-011]).
class VfsPathResolution {
  const VfsPathResolution({
    required this.virtualPath,
    required this.hostPath,
    required this.relativeSegments,
    required this.isRoot,
  });

  /// Normalized virtual path (`/workspace` or `/workspace/...`, forward slashes).
  final String virtualPath;

  /// Resolved host filesystem path under `workspaceHostRoot`.
  final String hostPath;

  /// Relative path segments beneath `/workspace`.
  final List<String> relativeSegments;

  /// Whether this resolution refers to `/workspace` itself.
  final bool isRoot;
}

/// Private virtual filesystem namespace isolating agent I/O to `/workspace` ([D-011], [D-003]).
class VfsNamespace {
  VfsNamespace({required String workspaceHostRoot})
      : workspaceHostRoot = _canonicalizeRoot(workspaceHostRoot);

  static const String virtualRoot = '/workspace';

  /// Canonical host directory mapped to `/workspace`.
  final String workspaceHostRoot;

  static String _canonicalizeRoot(String root) {
    final dir = Directory(root);
    if (dir.existsSync()) {
      return p.normalize(dir.resolveSymbolicLinksSync());
    }
    return p.normalize(p.absolute(root));
  }

  static final RegExp _drivePrefixPattern = RegExp(r'^[a-zA-Z]:');
  static const Set<String> _protectedDirs = <String>{
    '.jj',
    '.git',
    '.agent_os',
  };

  /// Returns true if [segment] matches a protected internal directory or `.env` file.
  static bool isProtectedSegment(String segment) {
    final lower = segment.toLowerCase();
    if (_protectedDirs.contains(lower)) {
      return true;
    }
    if (lower == '.env' || lower.startsWith('.env.')) {
      return true;
    }
    return false;
  }

  /// Returns true if any segment of [relativeSegments] is protected.
  static bool hasProtectedSegment(Iterable<String> relativeSegments) {
    for (final seg in relativeSegments) {
      if (isProtectedSegment(seg)) {
        return true;
      }
    }
    return false;
  }

  /// Returns true if a normalized [virtualPath] targets a protected internal path.
  bool isProtectedVirtualPath(String virtualPath) {
    final normalized = virtualPath.replaceAll('\\', '/');
    if (normalized == virtualRoot) {
      return false;
    }
    final rel = normalized.startsWith('$virtualRoot/')
        ? normalized.substring(virtualRoot.length + 1)
        : normalized;
    final segments = rel.split('/').where((s) => s.isNotEmpty);
    return hasProtectedSegment(segments);
  }

  /// Returns true if a directory entry at [virtualPath] must be auto-skipped during parent scans (`sys_glob` / `sys_grep`).
  bool shouldSkipEntry(String virtualPath) => isProtectedVirtualPath(virtualPath);

  /// Returns true if a `glob` or `grep` pattern directly targets protected paths (`.jj`, `.git`, `.agent_os`, `.env*`).
  bool isProtectedPattern(String rawPattern) {
    final trimmed = rawPattern.trim().replaceAll('\\', '/');
    if (trimmed.isEmpty) {
      return false;
    }
    var rel = trimmed;
    if (rel == virtualRoot || rel.startsWith('$virtualRoot/')) {
      rel = rel.length == virtualRoot.length
          ? ''
          : rel.substring(virtualRoot.length + 1);
    } else if (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    final segments = rel.split('/').where((s) => s.isNotEmpty && s != '.');
    for (final seg in segments) {
      final lower = seg.toLowerCase();
      if (_protectedDirs.contains(lower)) {
        return true;
      }
      if (lower == '.env' || lower.startsWith('.env.')) {
        return true;
      }
      if (lower == '.env*' || lower.startsWith('.env*')) {
        return true;
      }
    }
    return false;
  }

  /// Converts a host path inside [workspaceHostRoot] into a normalized `/workspace/...` virtual path.
  String toVirtualPath(String hostPath) {
    final normalizedHost = p.normalize(p.absolute(hostPath));
    final rel = p.relative(normalizedHost, from: workspaceHostRoot);
    if (rel == '.' || rel.isEmpty) {
      return virtualRoot;
    }
    final posixRel = rel.replaceAll('\\', '/');
    return '$virtualRoot/$posixRel';
  }

  /// Resolves and validates an agent-supplied virtual or workspace-relative path ([D-011]).
  SyscallResult<VfsPathResolution> resolveVirtualPath(
    String rawPath, {
    bool allowRoot = true,
    bool checkProtected = true,
    bool checkSymlinks = true,
  }) {
    if (rawPath.contains('\x00')) {
      return const SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'OUT_OF_WORKSPACE_SCOPE',
          message: 'Path contains NUL byte and is rejected.',
          recoverable: true,
        ),
      );
    }

    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      return const SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_PATH',
          message: 'Path must not be empty.',
          recoverable: true,
        ),
      );
    }

    // Reject UNC paths (`\\server\share` or `//server/share`) and Windows drive letters (`C:\...`).
    if (trimmed.startsWith(r'\\') ||
        trimmed.startsWith('//') ||
        _drivePrefixPattern.hasMatch(trimmed)) {
      return SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'OUT_OF_WORKSPACE_SCOPE',
          message: 'Absolute host or UNC path "$rawPath" is outside /workspace.',
          recoverable: true,
          hint: 'Use a virtual path under /workspace (e.g., /workspace/lib/main.dart).',
        ),
      );
    }

    final forward = trimmed.replaceAll('\\', '/');
    String relativePart;
    if (forward.startsWith('/')) {
      if (forward == virtualRoot || forward == '$virtualRoot/') {
        relativePart = '';
      } else if (forward.startsWith('$virtualRoot/')) {
        relativePart = forward.substring(virtualRoot.length + 1);
      } else {
        return SyscallResult<VfsPathResolution>.failure(
          SyscallError(
            code: SyscallErrorCode.eacces,
            reason: 'OUT_OF_WORKSPACE_SCOPE',
            message: 'Path "$rawPath" is outside /workspace.',
            recoverable: true,
            hint: 'Use a virtual path under /workspace.',
          ),
        );
      }
    } else {
      relativePart = forward;
    }

    final stack = <String>[];
    for (final segment in relativePart.split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..') {
        if (stack.isEmpty) {
          return SyscallResult<VfsPathResolution>.failure(
            SyscallError(
              code: SyscallErrorCode.eacces,
              reason: 'OUT_OF_WORKSPACE_SCOPE',
              message: 'Path "$rawPath" attempts to escape /workspace.',
              recoverable: true,
              hint: 'Paths must remain within /workspace.',
            ),
          );
        }
        stack.removeLast();
        continue;
      }
      stack.add(segment);
    }

    if (stack.isEmpty && !allowRoot) {
      return const SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'ROOT_NOT_ALLOWED',
          message: 'Operation requires a file or subdirectory path inside /workspace.',
          recoverable: true,
        ),
      );
    }

    if (checkProtected && hasProtectedSegment(stack)) {
      return SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'PROTECTED_INTERNAL_PATH',
          message: 'Access to protected internal path "$rawPath" is denied.',
          recoverable: true,
          hint:
              'Internal VCS (.jj, .git), kernel (.agent_os), and secret (.env*) paths are protected.',
        ),
      );
    }

    final virtualPath =
        stack.isEmpty ? virtualRoot : '$virtualRoot/${stack.join('/')}';
    final hostPath = stack.isEmpty
        ? workspaceHostRoot
        : p.normalize(p.joinAll(<String>[workspaceHostRoot, ...stack]));

    if (checkSymlinks) {
      final symlinkCheck = _verifyRealPathBoundary(
        hostPath: hostPath,
        rawPath: rawPath,
        checkProtected: checkProtected,
      );
      if (symlinkCheck != null) {
        return SyscallResult<VfsPathResolution>.failure(symlinkCheck);
      }
    }

    return SyscallResult<VfsPathResolution>.success(
      VfsPathResolution(
        virtualPath: virtualPath,
        hostPath: hostPath,
        relativeSegments: List<String>.unmodifiable(stack),
        isRoot: stack.isEmpty,
      ),
    );
  }

  SyscallError? _verifyRealPathBoundary({
    required String hostPath,
    required String rawPath,
    required bool checkProtected,
  }) {
    // Walk up until the deepest existing entity (following non-link ancestors, catching links).
    var probe = hostPath;
    while (true) {
      final entityType = FileSystemEntity.typeSync(probe, followLinks: false);
      if (entityType != FileSystemEntityType.notFound) {
        String resolved;
        try {
          if (entityType == FileSystemEntityType.link) {
            final linkTarget = Link(probe).targetSync();
            final candidate = p.isAbsolute(linkTarget)
                ? p.normalize(linkTarget)
                : p.normalize(p.join(p.dirname(probe), linkTarget));
            // If target itself exists, resolve it fully; otherwise validate candidate boundary.
            if (FileSystemEntity.typeSync(candidate, followLinks: true) !=
                FileSystemEntityType.notFound) {
              resolved = p.normalize(
                File(candidate).existsSync()
                    ? File(candidate).resolveSymbolicLinksSync()
                    : Directory(candidate).resolveSymbolicLinksSync(),
              );
            } else {
              resolved = candidate;
            }
          } else if (entityType == FileSystemEntityType.directory) {
            resolved = p.normalize(Directory(probe).resolveSymbolicLinksSync());
          } else {
            resolved = p.normalize(File(probe).resolveSymbolicLinksSync());
          }
        } on FileSystemException {
          return SyscallError(
            code: SyscallErrorCode.eacces,
            reason: 'OUT_OF_WORKSPACE_SCOPE',
            message:
                'Symbolic link or junction for "$rawPath" could not be verified within /workspace.',
            recoverable: true,
          );
        }

        if (!_isInsideWorkspaceRoot(resolved)) {
          return SyscallError(
            code: SyscallErrorCode.eacces,
            reason: 'OUT_OF_WORKSPACE_SCOPE',
            message:
                'Resolved real path for "$rawPath" escapes /workspace boundary.',
            recoverable: true,
          );
        }

        if (checkProtected) {
          final resolvedRel = p.relative(resolved, from: workspaceHostRoot);
          if (resolvedRel != '.' && resolvedRel.isNotEmpty) {
            final relSegs = resolvedRel
                .replaceAll('\\', '/')
                .split('/')
                .where((s) => s.isNotEmpty);
            if (hasProtectedSegment(relSegs)) {
              return SyscallError(
                code: SyscallErrorCode.eacces,
                reason: 'PROTECTED_INTERNAL_PATH',
                message:
                    'Resolved target of "$rawPath" points to a protected internal path.',
                recoverable: true,
              );
            }
          }
        }
        return null;
      }

      final parent = p.dirname(probe);
      if (parent == probe || !_isInsideWorkspaceRoot(parent)) {
        break;
      }
      probe = parent;
    }
    return null;
  }

  bool _isInsideWorkspaceRoot(String candidatePath) {
    final normCandidate = p.normalize(candidatePath);
    final normRoot = workspaceHostRoot;
    if (Platform.isWindows) {
      final cLower = normCandidate.toLowerCase();
      final rLower = normRoot.toLowerCase();
      if (cLower == rLower) {
        return true;
      }
      final sep = Platform.pathSeparator;
      final prefix = rLower.endsWith(sep) ? rLower : '$rLower$sep';
      return cLower.startsWith(prefix);
    } else {
      if (normCandidate == normRoot) {
        return true;
      }
      final prefix = normRoot.endsWith('/') ? normRoot : '$normRoot/';
      return normCandidate.startsWith(prefix);
    }
  }
}
