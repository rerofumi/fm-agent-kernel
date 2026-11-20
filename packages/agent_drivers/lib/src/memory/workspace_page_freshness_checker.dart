import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';

import '../fs/host_fs_driver.dart';
import '../jj/jj_driver.dart';

/// Non-destructive Clean Page freshness checker using host `FileStat`/`SHA-256`
/// and `jj --ignore-working-copy` `@` `commit_id` ([D-204], [D-208]).
///
/// Guarantees:
/// - Never triggers a `jj` working-copy snapshot or advances `jj op log`.
/// - Detects unsnapshotted external edits via `FileStat` + `SHA-256` (zero false negatives).
/// - Keeps unaffected files `fresh` even when an unrelated file changes `@` `commit_id` (zero false positives).
class WorkspacePageFreshnessChecker
    implements ProcessAwarePageFreshnessChecker {
  WorkspacePageFreshnessChecker({
    required this.namespace,
    this.jjDriver,
    CurrentCommitIdProvider? currentCommitIdProvider,
    this.jjExecutable = 'jj',
  }) : _currentCommitIdProvider = currentCommitIdProvider;

  final VfsNamespace namespace;
  final JjDriver? jjDriver;
  final CurrentCommitIdProvider? _currentCommitIdProvider;
  final String jjExecutable;

  @override
  Future<Map<String, PageFreshnessStatus>> checkFreshness(
    Iterable<ContextPage> cleanPages,
  ) =>
      checkFreshnessForProcess(cleanPages);

  @override
  Future<Map<String, PageFreshnessStatus>> checkFreshnessForProcess(
    Iterable<ContextPage> cleanPages, {
    ProcessControlBlock? pcb,
  }) async {
    final pages = cleanPages.where((p) => p.isClean).toList(growable: false);
    if (pages.isEmpty) {
      return const <String, PageFreshnessStatus>{};
    }

    final effectiveNamespace = pcb?.namespace ?? namespace;
    String? cachedCommitId;
    var queriedCommitId = false;

    Future<String?> getCurrentCommitIdOnce() async {
      if (!queriedCommitId) {
        queriedCommitId = true;
        cachedCommitId = await _resolveCurrentCommitIdNonDestructive(pcb: pcb);
      }
      return cachedCommitId;
    }

    final result = <String, PageFreshnessStatus>{};
    for (final page in pages) {
      final meta = page.cleanSource!;
      switch (meta.sourceKind) {
        case CleanSourceKind.workspaceFile:
        case CleanSourceKind.skillFile:
          result[page.pageId] = await _checkFileFreshness(
            meta,
            effectiveNamespace: effectiveNamespace,
          );
        case CleanSourceKind.vcsSnapshot:
          final currentCommitId = await getCurrentCommitIdOnce();
          if (currentCommitId == null ||
              meta.readCommitId == null ||
              meta.readCommitId!.isEmpty) {
            result[page.pageId] = PageFreshnessStatus.stale;
          } else {
            result[page.pageId] = currentCommitId == meta.readCommitId
                ? PageFreshnessStatus.fresh
                : PageFreshnessStatus.stale;
          }
      }
    }
    return result;
  }

  Future<PageFreshnessStatus> _checkFileFreshness(
    CleanPageSourceMeta meta, {
    VfsNamespace? effectiveNamespace,
  }) async {
    final virtualPath = meta.virtualPath;
    if (virtualPath == null || virtualPath.trim().isEmpty) {
      return PageFreshnessStatus.stale;
    }

    final ns = effectiveNamespace ?? namespace;
    final resolvedRes = ns.resolveVirtualPath(
      virtualPath,
      allowRoot: false,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!resolvedRes.ok) {
      return PageFreshnessStatus.stale;
    }
    final hostPath = resolvedRes.value!.hostPath;

    final stat = await FileStat.stat(hostPath);
    if (stat.type == FileSystemEntityType.notFound) {
      return PageFreshnessStatus.deleted;
    }
    if (stat.type != FileSystemEntityType.file) {
      return PageFreshnessStatus.stale;
    }

    // Fast path: skip SHA-256 recomputation when both (modifiedUtc, size) match exactly ([D-204], [D-208]).
    if (meta.readModifiedUtc != null &&
        meta.readByteLength != null &&
        stat.size == meta.readByteLength &&
        stat.modified.toUtc().isAtSameMomentAs(meta.readModifiedUtc!.toUtc())) {
      return PageFreshnessStatus.fresh;
    }

    try {
      final bytes = await File(hostPath).readAsBytes();
      final currentSha = sha256.convert(bytes).toString();
      return currentSha == meta.readSha256
          ? PageFreshnessStatus.fresh
          : PageFreshnessStatus.stale;
    } on FileSystemException {
      return PageFreshnessStatus.deleted;
    }
  }

  Future<String?> _resolveCurrentCommitIdNonDestructive({
    ProcessControlBlock? pcb,
  }) async {
    if (pcb != null && pcb.hasIsolatedJjWorkspace) {
      if (jjDriver != null) {
        return jjDriver!.getCurrentCommitIdForPcb(pcb);
      }
      try {
        final result = await Process.run(
          jjExecutable,
          <String>[
            '--no-pager',
            '-R',
            pcb.jjWorkspaceRoot!,
            'log',
            '--no-graph',
            '-r',
            '@',
            '--ignore-working-copy',
            '-T',
            'commit_id',
          ],
          workingDirectory: namespace.workspaceHostRoot,
          runInShell: false,
          environment: JjDriver.buildNonInteractiveEnvironment(),
        );
        if (result.exitCode != 0) {
          return null;
        }
        final commitId = (result.stdout as String).trim();
        return commitId.isEmpty ? null : commitId;
      } catch (_) {
        return null;
      }
    }
    if (_currentCommitIdProvider != null) {
      try {
        final id = await _currentCommitIdProvider();
        final trimmed = id?.trim();
        return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
      } catch (_) {
        return null;
      }
    }
    if (jjDriver != null) {
      return jjDriver!.getCurrentCommitIdNonDestructive();
    }
    // Fallback direct non-destructive `jj` invocation always passing `--ignore-working-copy`.
    try {
      final result = await Process.run(
        jjExecutable,
        const <String>[
          'log',
          '--no-graph',
          '-r',
          '@',
          '--ignore-working-copy',
          '-T',
          'commit_id',
        ],
        workingDirectory: namespace.workspaceHostRoot,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
      );
      if (result.exitCode != 0) {
        return null;
      }
      final commitId = (result.stdout as String).trim();
      return commitId.isEmpty ? null : commitId;
    } catch (_) {
      return null;
    }
  }
}

/// Builds the Segment 0 [SyscallToolSchema] for `sys_mem_pagein` ([D-202], [D-208]).
SyscallToolSchema buildMemPageinToolSchema() {
  return SyscallToolSchema(
    name: 'sys_mem_pagein',
    description:
        'Reload the latest content of an evicted or stale Clean Page by its pageId '
        '(e.g. "pg_0003") without mutating earlier conversation history.',
    parametersJsonSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'pageId': <String, dynamic>{
          'type': 'string',
          'description':
              'The Clean Page identifier shown in a [PageOut ...] stub or [Context Page Directory] (e.g. "pg_0003").',
        },
      },
      'required': <String>['pageId'],
      'additionalProperties': false,
    },
  );
}

final RegExp _pageIdPattern = RegExp(r'^pg_[0-9]+$');

/// Builds the kernel `sys_mem_pagein` [SyscallDefinition] ([D-202], [D-208], [D-317]).
SyscallDefinition buildMemPageinSyscallDefinition({
  required HostFsDriver hostFsDriver,
  JjDriver? jjDriver,
  PageFreshnessChecker? freshnessChecker,
  DirtySwapBackend? dirtySwapBackend,
  SecretRedactor? redactor,
}) {
  return SyscallDefinition(
    name: 'sys_mem_pagein',
    requiredRight: CapRight.memManage,
    kind: 'read',
    applyIoCap: true,
    validateArgs: (args) {
      final rawPageId = args['pageId'];
      if (rawPageId is! String ||
          !_pageIdPattern.hasMatch(rawPageId.trim())) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_PAGE_ID',
          message:
              'Argument "pageId" must be a non-empty page identifier like "pg_0001".',
          recoverable: true,
        );
      }
      return null;
    },
    evaluatePolicy: (_, _) async => RingDecision.allow,
    resultSummaryBuilder: (args, result) {
      if (!result.ok || result.value == null) {
        return null;
      }
      final val = result.value!;
      return <String, dynamic>{
        'pageId': val['pageId'],
        'source': val['source'],
        'wasStale': val['wasStale'] ?? false,
      };
    },
    handler: (execContext) async {
      final pageId = (execContext.args['pageId'] as String).trim();
      final memory = execContext.pcb.memory;
      final page = memory.pageTable.lookup(pageId);
      if (page == null) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'PAGE_NOT_FOUND',
            message: 'Page "$pageId" was not found in this process PageTable.',
            recoverable: true,
          ),
        );
      }

      final swapMeta = page.swapMeta;
      if (swapMeta != null) {
        if (dirtySwapBackend == null) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'DIRTY_SWAP_BACKEND_UNAVAILABLE',
              message:
                  'DirtySwapBackend is not configured to restore swapped page "$pageId".',
              recoverable: false,
            ),
          );
        }
        final isSummary = pageId == swapMeta.summaryPageId;
        final readRes = await dirtySwapBackend.readSwappedPages(
          sessionId: execContext.context.sessionId,
          pid: execContext.pcb.pid,
          pcb: execContext.pcb,
          pageId: isSummary ? null : pageId,
          swapBatchId: isSummary ? swapMeta.swapBatchId : null,
        );
        if (!readRes.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(readRes.error!);
        }
        final records = readRes.value!;
        final formatted = _formatSwappedRecords(records, redactor: redactor);
        return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
          'pageId': pageId,
          'source': 'dirty_swap',
          'swapBatchId': swapMeta.swapBatchId,
          'summaryPageId': swapMeta.summaryPageId,
          'restoredPageIds':
              records.map((r) => r.pageId).toList(growable: false),
          'wasStale': false,
          'content': formatted,
        });
      }

      final meta = page.cleanSource;
      if (page.dirty || meta == null) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'NOT_CLEAN_PAGE',
            message:
                'Page "$pageId" is not a Clean Page and cannot be reloaded via sys_mem_pagein.',
            recoverable: true,
          ),
        );
      }

      // Re-verify process capability and VFS scope for the underlying Clean Page source ([D-208]).
      final requiredSourceRight = _requiredRightForSource(meta);
      if (!execContext.pcb.cspace.hasRight(
        execContext.context.capHandle,
        requiredSourceRight,
      )) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'MISSING_SOURCE_CAPABILITY',
            message:
                'Process ${execContext.pcb.pid} lacks ${requiredSourceRight.name} required to reload page "$pageId".',
            recoverable: false,
          ),
        );
      }

      if (meta.sourceKind == CleanSourceKind.workspaceFile ||
          meta.sourceKind == CleanSourceKind.skillFile) {
        final vPath = meta.virtualPath;
        if (vPath == null || vPath.trim().isEmpty) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'INVALID_SOURCE_META',
              message: 'Clean Page "$pageId" has no virtualPath recorded.',
              recoverable: true,
            ),
          );
        }
        final scopeCheck = execContext.pcb.namespace.resolveVirtualPath(
          vPath,
          allowRoot: false,
          checkProtected: true,
          checkSymlinks: true,
        );
        if (!scopeCheck.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(scopeCheck.error!);
        }
      }

      // Determine whether the page was stale prior to reloading.
      var wasStale = page.freshness != PageFreshnessStatus.fresh;
      if (freshnessChecker != null) {
        final freshMap = freshnessChecker is ProcessAwarePageFreshnessChecker
            ? await freshnessChecker.checkFreshnessForProcess(
                <ContextPage>[page],
                pcb: execContext.pcb,
              )
            : await freshnessChecker.checkFreshness(<ContextPage>[page]);
        final latestStatus = freshMap[pageId];
        if (latestStatus != null) {
          wasStale = latestStatus != PageFreshnessStatus.fresh;
        }
      }

      // Replay the read-only source syscall without mutating Segment 1 stubs ([D-208]).
      switch (meta.syscallName) {
        case 'sys_read_lines':
          final readRes = await hostFsDriver.readLines(
            path: meta.virtualPath ?? (meta.replayArgs['path'] as String),
            startLine:
                meta.startLine ?? (meta.replayArgs['startLine'] as num?)?.toInt(),
            endLine:
                meta.endLine ?? (meta.replayArgs['endLine'] as num?)?.toInt(),
            namespaceOverride: execContext.pcb.namespace,
            cspace: execContext.pcb.cspace,
          );
          if (!readRes.ok) {
            final err = readRes.error!;
            if (err.code == SyscallErrorCode.enoent) {
              page.freshness = PageFreshnessStatus.deleted;
              return SyscallResult<Map<String, dynamic>>.failure(
                SyscallError(
                  code: SyscallErrorCode.enoent,
                  reason: 'SOURCE_FILE_DELETED',
                  message:
                      'Source file "${meta.virtualPath}" for page "$pageId" no longer exists.',
                  recoverable: true,
                ),
              );
            }
            return SyscallResult<Map<String, dynamic>>.failure(err);
          }

          final data = readRes.value!;
          final newSha = data['sha256'] as String?;
          final newModified = data['modifiedUtc'] is String
              ? DateTime.tryParse(data['modifiedUtc'] as String)?.toUtc()
              : null;
          final newByteLength = (data['byteLength'] as num?)?.toInt();
          if (newSha != null && meta.readSha256 != null && newSha != meta.readSha256) {
            wasStale = true;
          }

          page.cleanSource = meta.copyWith(
            readSha256: newSha ?? meta.readSha256,
            readModifiedUtc: newModified ?? meta.readModifiedUtc,
            readByteLength: newByteLength ?? meta.readByteLength,
          );
          page.freshness = PageFreshnessStatus.fresh;
          memory.pageTable.touchPage(pageId, memory.currentTurnNumber);

          return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
            'pageId': pageId,
            'source': 'clean_workspace',
            'sourceTarget': meta.virtualPath ?? meta.syscallName,
            'syscallName': meta.syscallName,
            'wasStale': wasStale,
            'previousSha256': meta.readSha256,
            'currentSha256': newSha,
            'startLine': data['startLine'],
            'endLine': data['endLine'],
            'totalLines': data['totalLines'],
            'content': data['content'],
          });

        case 'sys_glob':
          final globRes = await hostFsDriver.glob(
            pattern: (meta.replayArgs['pattern'] as String?) ?? '*',
            subpath: meta.replayArgs['subpath'] as String?,
            namespaceOverride: execContext.pcb.namespace,
            callerPcb: execContext.pcb,
          );
          if (!globRes.ok) {
            return SyscallResult<Map<String, dynamic>>.failure(globRes.error!);
          }
          final data = globRes.value!;
          final newCommitId = data['commitId'] as String?;
          if (newCommitId != null &&
              meta.readCommitId != null &&
              newCommitId != meta.readCommitId) {
            wasStale = true;
          }
          page.cleanSource = meta.copyWith(
            readCommitId: newCommitId ?? meta.readCommitId,
          );
          page.freshness = PageFreshnessStatus.fresh;
          memory.pageTable.touchPage(pageId, memory.currentTurnNumber);

          return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
            'pageId': pageId,
            'source': 'clean_vcs',
            'sourceTarget': meta.syscallName,
            'syscallName': meta.syscallName,
            'wasStale': wasStale,
            'previousCommitId': meta.readCommitId,
            'currentCommitId': newCommitId ?? meta.readCommitId,
            'matches': data['matches'],
            'totalCount': data['totalCount'],
          });

        case 'sys_grep':
          final grepRes = await hostFsDriver.grep(
            pattern: (meta.replayArgs['pattern'] as String?) ?? '',
            subpath: meta.replayArgs['subpath'] as String?,
            isRegex: (meta.replayArgs['isRegex'] as bool?) ?? false,
            caseSensitive: (meta.replayArgs['caseSensitive'] as bool?) ?? true,
            includeGlob: meta.replayArgs['includeGlob'] as String?,
            namespaceOverride: execContext.pcb.namespace,
            callerPcb: execContext.pcb,
          );
          if (!grepRes.ok) {
            return SyscallResult<Map<String, dynamic>>.failure(grepRes.error!);
          }
          final data = grepRes.value!;
          final newCommitId = data['commitId'] as String?;
          if (newCommitId != null &&
              meta.readCommitId != null &&
              newCommitId != meta.readCommitId) {
            wasStale = true;
          }
          page.cleanSource = meta.copyWith(
            readCommitId: newCommitId ?? meta.readCommitId,
          );
          page.freshness = PageFreshnessStatus.fresh;
          memory.pageTable.touchPage(pageId, memory.currentTurnNumber);

          return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
            'pageId': pageId,
            'source': 'clean_vcs',
            'sourceTarget': meta.syscallName,
            'syscallName': meta.syscallName,
            'wasStale': wasStale,
            'previousCommitId': meta.readCommitId,
            'currentCommitId': newCommitId ?? meta.readCommitId,
            'matches': data['matches'],
            'totalMatches': data['totalMatches'],
          });

        case 'sys_jj_status':
        case 'sys_jj_log':
        case 'sys_jj_diff':
        case 'sys_jj_conflicts':
          if (jjDriver == null) {
            return const SyscallResult<Map<String, dynamic>>.failure(
              SyscallError(
                code: SyscallErrorCode.eio,
                reason: 'JJ_DRIVER_UNAVAILABLE',
                message: 'JjDriver is not configured for sys_mem_pagein.',
                recoverable: false,
              ),
            );
          }
          final SyscallResult<Map<String, dynamic>> vcsRes;
          if (meta.syscallName == 'sys_jj_status') {
            vcsRes = await jjDriver.status(
              atOp: meta.replayArgs['atOp'] as String?,
              forceIgnoreWorkingCopy: true,
              repositoryPath: execContext.pcb.jjWorkspaceRoot,
            );
          } else if (meta.syscallName == 'sys_jj_log') {
            vcsRes = await jjDriver.log(
              revset: (meta.replayArgs['revset'] as String?) ?? '::@ | @-',
              limit: (meta.replayArgs['limit'] as num?)?.toInt() ?? 20,
              atOp: meta.replayArgs['atOp'] as String?,
              forceIgnoreWorkingCopy: true,
              repositoryPath: execContext.pcb.jjWorkspaceRoot,
            );
          } else if (meta.syscallName == 'sys_jj_conflicts') {
            vcsRes = await jjDriver.inspectConflictsNonDestructive(
              rev: (meta.replayArgs['rev'] as String?) ?? '@',
              namespaceOverride: execContext.pcb.namespace,
              repositoryPath: execContext.pcb.jjWorkspaceRoot,
            );
          } else {
            final rawPaths = meta.replayArgs['paths'];
            final paths = rawPaths is List
                ? rawPaths.whereType<String>().toList(growable: false)
                : null;
            vcsRes = await jjDriver.diff(
              rev: (meta.replayArgs['rev'] as String?) ?? '@',
              paths: paths,
              atOp: meta.replayArgs['atOp'] as String?,
              forceIgnoreWorkingCopy: true,
              namespaceOverride: execContext.pcb.namespace,
              repositoryPath: execContext.pcb.jjWorkspaceRoot,
            );
          }
          if (!vcsRes.ok) {
            return SyscallResult<Map<String, dynamic>>.failure(vcsRes.error!);
          }
          final data = vcsRes.value!;
          final newCommitId = data['commitId'] as String?;
          if (newCommitId != null &&
              meta.readCommitId != null &&
              newCommitId != meta.readCommitId) {
            wasStale = true;
          }
          page.cleanSource = meta.copyWith(
            readCommitId: newCommitId ?? meta.readCommitId,
            readOpId: (data['opId'] as String?) ?? meta.readOpId,
          );
          page.freshness = PageFreshnessStatus.fresh;
          memory.pageTable.touchPage(pageId, memory.currentTurnNumber);

          return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
            'pageId': pageId,
            'source': 'clean_vcs',
            'sourceTarget': meta.syscallName,
            'syscallName': meta.syscallName,
            'wasStale': wasStale,
            'previousCommitId': meta.readCommitId,
            'currentCommitId': newCommitId ?? meta.readCommitId,
            ...data,
          });

        default:
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'UNSUPPORTED_PAGEIN_SOURCE',
              message:
                  'Clean Page "$pageId" source syscall "${meta.syscallName}" is not supported by sys_mem_pagein.',
              recoverable: true,
            ),
          );
      }
    },
  );
}

CapRight _requiredRightForSource(CleanPageSourceMeta meta) {
  switch (meta.sourceKind) {
    case CleanSourceKind.workspaceFile:
    case CleanSourceKind.skillFile:
      return CapRight.read;
    case CleanSourceKind.vcsSnapshot:
      if (meta.syscallName == 'sys_glob' || meta.syscallName == 'sys_grep') {
        return CapRight.read;
      }
      return CapRight.vcsRead;
  }
}

String _formatSwappedRecords(
  List<DirtySwapRecord> records, {
  SecretRedactor? redactor,
}) {
  String redact(String s) => redactor == null ? s : redactor.redactString(s);
  final buf = StringBuffer();
  for (var i = 0; i < records.length; i++) {
    final r = records[i];
    if (i > 0) {
      buf.writeln();
    }
    buf.write('[${r.pageId} | role=${r.turnType}');
    if (r.toolName != null) {
      buf.write(' | tool=${r.toolName}');
    }
    if (r.canonicalCallId != null) {
      buf.write(' | callId=${r.canonicalCallId}');
    }
    if (r.isError) {
      buf.write(' | isError=true');
    }
    buf.writeln(']');
    if (r.thoughtText != null && r.thoughtText!.trim().isNotEmpty) {
      buf.writeln('thought: ${redact(r.thoughtText!)}');
    }
    if (r.toolCalls.isNotEmpty) {
      final redactedCalls = redactor == null
          ? r.toolCalls
          : redactor.redactJson(r.toolCalls);
      buf.writeln('toolCalls: ${jsonEncode(redactedCalls)}');
    }
    if (r.content.isNotEmpty) {
      buf.writeln(redact(r.content));
    }
  }
  return buf.toString().trimRight();
}
