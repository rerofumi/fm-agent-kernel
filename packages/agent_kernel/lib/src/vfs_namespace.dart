import 'dart:io';

import 'package:path/path.dart' as p;

import 'skill_registry.dart';
import 'syscall_error.dart';

/// Resolved virtual and host filesystem path within a [VfsNamespace] ([D-011], [D-219]).
class VfsPathResolution {
  const VfsPathResolution({
    required this.virtualPath,
    required this.hostPath,
    required this.relativeSegments,
    required this.isRoot,
    this.isReadOnly = false,
    this.isSkillsMount = false,
    this.skillName,
  });

  /// Normalized virtual path (`/workspace`, `/workspace/...`, `/skills`, or `/skills/...`, forward slashes).
  final String virtualPath;

  /// Resolved host filesystem path under `workspaceHostRoot` or the mounted skill directory.
  final String hostPath;

  /// Relative path segments beneath `/workspace` or `/skills`.
  final List<String> relativeSegments;

  /// Whether this resolution refers to the virtual mount root itself (`/workspace` or `/skills`).
  final bool isRoot;

  /// Whether this resolved path belongs to a read-only mount (e.g., `/skills`).
  final bool isReadOnly;

  /// Whether this resolved path belongs to the `/skills` virtual mount ([D-219]).
  final bool isSkillsMount;

  /// Matched skill name when [isSkillsMount] is true and a specific skill is addressed.
  final String? skillName;
}

/// Private virtual filesystem namespace isolating agent I/O to `/workspace` and read-only `/skills` ([D-011], [D-003], [D-213], [D-219]).
class VfsNamespace {
  VfsNamespace({
    required String workspaceHostRoot,
    Iterable<String>? allowedWorkspaceSubpaths,
    this.skillsMount,
  })  : workspaceHostRoot = _canonicalizeRoot(workspaceHostRoot),
        allowedWorkspaceSubpaths =
            _normalizeSubpathListOrThrow(allowedWorkspaceSubpaths);

  /// Creates an isolated sterile namespace with neither `/workspace` nor `/skills` mounted ([D-211], [D-213], [D-218]).
  const VfsNamespace.empty()
      : workspaceHostRoot = null,
        allowedWorkspaceSubpaths = null,
        skillsMount = null;

  VfsNamespace._internal({
    required this.workspaceHostRoot,
    required this.allowedWorkspaceSubpaths,
    required this.skillsMount,
  });

  static const String virtualRoot = '/workspace';
  static const String skillsVirtualRoot = '/skills';

  /// Canonical host directory mapped to `/workspace`, or `null` when unmounted (e.g., `WebResearcher`).
  final String? workspaceHostRoot;

  /// Optional list of normalized `/workspace/...` prefixes permitted in this namespace ([D-213]).
  ///
  /// When `null`, the entire mounted `/workspace` (minus protected internal paths) is accessible.
  final List<String>? allowedWorkspaceSubpaths;

  /// Optional read-only `/skills` mount backed by a [SkillRegistry] ([D-219]).
  ///
  /// Always `null` in sterile namespaces such as `WebResearcher` (`VfsNamespace.empty()`).
  final SkillRegistry? skillsMount;

  /// Whether `/workspace` is mounted in this namespace.
  bool get isWorkspaceMounted => workspaceHostRoot != null;

  /// Whether `/skills` is mounted in this namespace ([D-219]).
  bool get isSkillsMounted => skillsMount != null;

  /// Returns a copy of this namespace with [skillsMount] replaced.
  VfsNamespace withSkillsMount(SkillRegistry? skills) {
    return VfsNamespace._internal(
      workspaceHostRoot: workspaceHostRoot,
      allowedWorkspaceSubpaths: allowedWorkspaceSubpaths,
      skillsMount: skills,
    );
  }

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
    final root = workspaceHostRoot;
    if (root == null) {
      throw StateError('Workspace is not mounted in this VfsNamespace.');
    }
    final normalizedHost = p.normalize(p.absolute(hostPath));
    final rel = p.relative(normalizedHost, from: root);
    if (rel == '.' || rel.isEmpty) {
      return virtualRoot;
    }
    final posixRel = rel.replaceAll('\\', '/');
    return '$virtualRoot/$posixRel';
  }

  /// Derives a child [VfsNamespace] enforcing monotonic subpath attenuation ([D-213]).
  ///
  /// - When this parent has [allowedWorkspaceSubpaths], every requested child subpath
  ///   must lie within at least one parent subpath; otherwise returns
  ///   `EPERM: SUBPATH_ATTENUATION_VIOLATION`.
  /// - When this parent is unmounted (`workspaceHostRoot == null`), requesting any
  ///   non-empty [allowedSubpaths] returns `EPERM: SUBPATH_ATTENUATION_VIOLATION`.
  SyscallResult<VfsNamespace> deriveForChild({
    Iterable<String>? allowedSubpaths,
    bool inheritSkillsMount = true,
  }) {
    final childSkills = inheritSkillsMount ? skillsMount : null;
    final root = workspaceHostRoot;
    if (root == null) {
      if (allowedSubpaths == null || allowedSubpaths.isEmpty) {
        if (childSkills == null) {
          return const SyscallResult<VfsNamespace>.success(VfsNamespace.empty());
        }
        return SyscallResult<VfsNamespace>.success(
          VfsNamespace._internal(
            workspaceHostRoot: null,
            allowedWorkspaceSubpaths: null,
            skillsMount: childSkills,
          ),
        );
      }
      return const SyscallResult<VfsNamespace>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'SUBPATH_ATTENUATION_VIOLATION',
          message:
              'Cannot grant workspace subpaths from an unmounted parent VfsNamespace.',
          recoverable: false,
        ),
      );
    }

    if (allowedSubpaths == null) {
      return SyscallResult<VfsNamespace>.success(
        VfsNamespace._internal(
          workspaceHostRoot: root,
          allowedWorkspaceSubpaths: allowedWorkspaceSubpaths,
          skillsMount: childSkills,
        ),
      );
    }

    final rawList = allowedSubpaths.toList(growable: false);
    if (rawList.isEmpty) {
      return const SyscallResult<VfsNamespace>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'EMPTY_ALLOWED_SUBPATHS',
          message: 'allowedSubpaths must be null or a non-empty list of paths.',
          recoverable: true,
        ),
      );
    }

    final normalized = <String>[];
    for (final raw in rawList) {
      final normResult = _normalizeVirtualSubpath(raw);
      if (!normResult.ok) {
        return SyscallResult<VfsNamespace>.failure(normResult.error!);
      }
      final candidate = normResult.value!;
      if (allowedWorkspaceSubpaths != null &&
          !_isPathWithinSubpaths(candidate, allowedWorkspaceSubpaths!)) {
        return SyscallResult<VfsNamespace>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'SUBPATH_ATTENUATION_VIOLATION',
            message:
                'Requested child subpath "$raw" ($candidate) exceeds parent allowed subpaths (${allowedWorkspaceSubpaths!.join(', ')}).',
            recoverable: false,
            details: <String, dynamic>{
              'requestedSubpath': candidate,
              'parentAllowedSubpaths': allowedWorkspaceSubpaths,
            },
          ),
        );
      }
      if (!normalized.contains(candidate)) {
        normalized.add(candidate);
      }
    }

    return SyscallResult<VfsNamespace>.success(
      VfsNamespace._internal(
        workspaceHostRoot: root,
        allowedWorkspaceSubpaths: List<String>.unmodifiable(normalized),
        skillsMount: childSkills,
      ),
    );
  }

  /// Convenience wrapper resolving a path for write operations (always denies read-only mounts such as `/skills`).
  SyscallResult<VfsPathResolution> resolveWriteVirtualPath(
    String rawPath, {
    bool allowRoot = false,
    bool checkProtected = true,
    bool checkSymlinks = true,
  }) {
    return resolveVirtualPath(
      rawPath,
      allowRoot: allowRoot,
      checkProtected: checkProtected,
      checkSymlinks: checkSymlinks,
      forWrite: true,
    );
  }

  /// Resolves and validates an agent-supplied virtual or workspace-relative path ([D-011], [D-213], [D-219]).
  SyscallResult<VfsPathResolution> resolveVirtualPath(
    String rawPath, {
    bool allowRoot = true,
    bool checkProtected = true,
    bool checkSymlinks = true,
    bool forWrite = false,
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
    if (forward == skillsVirtualRoot ||
        forward.startsWith('$skillsVirtualRoot/')) {
      return _resolveSkillsPath(
        rawPath: rawPath,
        forward: forward,
        allowRoot: allowRoot,
        checkProtected: checkProtected,
        checkSymlinks: checkSymlinks,
        forWrite: forWrite,
      );
    }

    final hostRoot = workspaceHostRoot;
    if (hostRoot == null) {
      return const SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'WORKSPACE_NOT_MOUNTED',
          message:
              'Workspace is not mounted in this isolated namespace; /workspace paths cannot be accessed.',
          recoverable: false,
        ),
      );
    }

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

    if (allowedWorkspaceSubpaths != null &&
        !_isPathWithinSubpaths(virtualPath, allowedWorkspaceSubpaths!)) {
      return SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'OUT_OF_ALLOWED_SUBPATH',
          message:
              'Path "$rawPath" ($virtualPath) is outside allowed workspace subpaths (${allowedWorkspaceSubpaths!.join(', ')}).',
          recoverable: true,
          details: <String, dynamic>{
            'virtualPath': virtualPath,
            'allowedSubpaths': allowedWorkspaceSubpaths,
          },
        ),
      );
    }

    final hostPath = stack.isEmpty
        ? hostRoot
        : p.normalize(p.joinAll(<String>[hostRoot, ...stack]));

    if (checkSymlinks) {
      final symlinkCheck = _verifyRealPathBoundary(
        hostRoot: hostRoot,
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

  SyscallResult<VfsPathResolution> _resolveSkillsPath({
    required String rawPath,
    required String forward,
    required bool allowRoot,
    required bool checkProtected,
    required bool checkSymlinks,
    required bool forWrite,
  }) {
    if (forWrite) {
      return SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'READ_ONLY_SKILL_MOUNT',
          message:
              'Mount /skills is read-only; write operations to "$rawPath" are denied.',
          recoverable: true,
          hint: 'Use /workspace for writable files; /skills is read-only.',
        ),
      );
    }

    final registry = skillsMount;
    if (registry == null) {
      return const SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'SKILLS_NOT_MOUNTED',
          message:
              '/skills is not mounted in this isolated namespace; skill paths cannot be accessed.',
          recoverable: false,
        ),
      );
    }

    final relativePart =
        forward == skillsVirtualRoot || forward == '$skillsVirtualRoot/'
            ? ''
            : forward.substring(skillsVirtualRoot.length + 1);

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
              reason: 'OUT_OF_SKILLS_SCOPE',
              message: 'Path "$rawPath" attempts to escape /skills.',
              recoverable: true,
              hint: 'Paths must remain within /skills/<skillName>.',
            ),
          );
        }
        stack.removeLast();
        continue;
      }
      stack.add(segment);
    }

    if (stack.isEmpty) {
      if (!allowRoot) {
        return const SyscallResult<VfsPathResolution>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'ROOT_NOT_ALLOWED',
            message: 'Operation requires a skill file path inside /skills.',
            recoverable: true,
          ),
        );
      }
      return const SyscallResult<VfsPathResolution>.success(
        VfsPathResolution(
          virtualPath: skillsVirtualRoot,
          hostPath: '',
          relativeSegments: <String>[],
          isRoot: true,
          isReadOnly: true,
          isSkillsMount: true,
        ),
      );
    }

    final requestedSkill = stack.first;
    final manifest = registry.lookup(requestedSkill);
    if (manifest == null) {
      return SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'SKILL_NOT_FOUND',
          message: 'Skill "$requestedSkill" is not mounted under /skills.',
          recoverable: true,
          hint: 'Call sys_skill_list to inspect mounted skills.',
        ),
      );
    }

    final subSegments = stack.sublist(1);
    if (checkProtected && hasProtectedSegment(subSegments)) {
      return SyscallResult<VfsPathResolution>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: 'PROTECTED_INTERNAL_PATH',
          message: 'Access to protected internal path "$rawPath" is denied.',
          recoverable: true,
        ),
      );
    }

    final hostSkillRoot = _canonicalizeRoot(manifest.hostDirectoryPath);
    final hostPath = subSegments.isEmpty
        ? hostSkillRoot
        : p.normalize(p.joinAll(<String>[hostSkillRoot, ...subSegments]));

    if (checkSymlinks) {
      final symlinkCheck = _verifyRealPathBoundary(
        hostRoot: hostSkillRoot,
        hostPath: hostPath,
        rawPath: rawPath,
        checkProtected: checkProtected,
        checkSubpaths: false,
        outOfScopeReason: 'OUT_OF_SKILLS_SCOPE',
        scopeLabel: '$skillsVirtualRoot/${manifest.name}',
      );
      if (symlinkCheck != null) {
        return SyscallResult<VfsPathResolution>.failure(symlinkCheck);
      }
    }

    final normalizedVirtualPath = subSegments.isEmpty
        ? '$skillsVirtualRoot/${manifest.name}'
        : '$skillsVirtualRoot/${manifest.name}/${subSegments.join('/')}';

    return SyscallResult<VfsPathResolution>.success(
      VfsPathResolution(
        virtualPath: normalizedVirtualPath,
        hostPath: hostPath,
        relativeSegments: List<String>.unmodifiable(stack),
        isRoot: false,
        isReadOnly: true,
        isSkillsMount: true,
        skillName: manifest.name,
      ),
    );
  }

  SyscallError? _verifyRealPathBoundary({
    required String hostRoot,
    required String hostPath,
    required String rawPath,
    required bool checkProtected,
    bool checkSubpaths = true,
    String outOfScopeReason = 'OUT_OF_WORKSPACE_SCOPE',
    String scopeLabel = '/workspace',
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
            reason: outOfScopeReason,
            message:
                'Symbolic link or junction for "$rawPath" could not be verified within $scopeLabel.',
            recoverable: true,
          );
        }

        if (!_isInsideRoot(resolved, hostRoot)) {
          return SyscallError(
            code: SyscallErrorCode.eacces,
            reason: outOfScopeReason,
            message:
                'Resolved real path for "$rawPath" escapes $scopeLabel boundary.',
            recoverable: true,
          );
        }

        if (checkProtected) {
          final resolvedRel = p.relative(resolved, from: hostRoot);
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

        if (checkSubpaths &&
            allowedWorkspaceSubpaths != null &&
            probe == hostPath) {
          final resolvedVirtual = toVirtualPath(resolved);
          if (!_isPathWithinSubpaths(
            resolvedVirtual,
            allowedWorkspaceSubpaths!,
          )) {
            return SyscallError(
              code: SyscallErrorCode.eacces,
              reason: 'OUT_OF_ALLOWED_SUBPATH',
              message:
                  'Resolved target of "$rawPath" ($resolvedVirtual) escapes allowed workspace subpaths.',
              recoverable: true,
            );
          }
        }
        return null;
      }

      final parent = p.dirname(probe);
      if (parent == probe || !_isInsideRoot(parent, hostRoot)) {
        break;
      }
      probe = parent;
    }
    return null;
  }

  static List<String>? _normalizeSubpathListOrThrow(Iterable<String>? rawList) {
    if (rawList == null) {
      return null;
    }
    final normalized = <String>[];
    for (final raw in rawList) {
      final res = _normalizeVirtualSubpath(raw);
      if (!res.ok) {
        throw ArgumentError.value(
          raw,
          'allowedWorkspaceSubpaths',
          res.error!.message,
        );
      }
      if (!normalized.contains(res.value!)) {
        normalized.add(res.value!);
      }
    }
    return List<String>.unmodifiable(normalized);
  }

  static SyscallResult<String> _normalizeVirtualSubpath(String raw) {
    if (raw.contains('\x00')) {
      return const SyscallResult<String>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'SUBPATH_ATTENUATION_VIOLATION',
          message: 'Allowed subpath contains NUL byte.',
          recoverable: false,
        ),
      );
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const SyscallResult<String>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'SUBPATH_ATTENUATION_VIOLATION',
          message: 'Allowed subpath must not be empty.',
          recoverable: false,
        ),
      );
    }
    if (trimmed.startsWith(r'\\') ||
        trimmed.startsWith('//') ||
        _drivePrefixPattern.hasMatch(trimmed)) {
      return SyscallResult<String>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'SUBPATH_ATTENUATION_VIOLATION',
          message: 'Allowed subpath "$raw" must be a virtual path under /workspace.',
          recoverable: false,
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
        return SyscallResult<String>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'SUBPATH_ATTENUATION_VIOLATION',
            message: 'Allowed subpath "$raw" is outside /workspace.',
            recoverable: false,
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
          return SyscallResult<String>.failure(
            SyscallError(
              code: SyscallErrorCode.eperm,
              reason: 'SUBPATH_ATTENUATION_VIOLATION',
              message: 'Allowed subpath "$raw" attempts to escape /workspace.',
              recoverable: false,
            ),
          );
        }
        stack.removeLast();
        continue;
      }
      stack.add(segment);
    }

    if (hasProtectedSegment(stack)) {
      return SyscallResult<String>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'SUBPATH_ATTENUATION_VIOLATION',
          message: 'Allowed subpath "$raw" targets a protected internal path.',
          recoverable: false,
        ),
      );
    }

    final normalized =
        stack.isEmpty ? virtualRoot : '$virtualRoot/${stack.join('/')}';
    return SyscallResult<String>.success(normalized);
  }

  static bool _isPathWithinSubpaths(
    String virtualPath,
    List<String> allowedSubpaths,
  ) {
    final candidate =
        Platform.isWindows ? virtualPath.toLowerCase() : virtualPath;
    for (final allowed in allowedSubpaths) {
      final normAllowed =
          Platform.isWindows ? allowed.toLowerCase() : allowed;
      if (normAllowed == virtualRoot) {
        return true;
      }
      if (candidate == normAllowed || candidate.startsWith('$normAllowed/')) {
        return true;
      }
    }
    return false;
  }

  static bool _isInsideRoot(String candidatePath, String normRoot) {
    final normCandidate = p.normalize(candidatePath);
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
