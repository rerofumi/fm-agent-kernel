import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

import 'jj_workspace_ops.dart';

/// Strict FIFO asynchronous mutex serializing Jujutsu operations ([D-014]).
class AsyncMutex {
  bool _locked = false;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// Whether the mutex is currently held by an active operation.
  bool get isLocked => _locked;

  /// Executes [action] exclusively in strict FIFO arrival order.
  Future<T> synchronized<T>(Future<T> Function() action) async {
    if (_locked) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _locked = true;
    }
    try {
      return await action();
    } finally {
      if (_waiters.isNotEmpty) {
        final next = _waiters.removeAt(0);
        next.complete();
      } else {
        _locked = false;
      }
    }
  }
}

/// Jujutsu (`jj 0.46.0`) CLI driver providing serialized, non-destructive reads ([D-003], [D-014]).
///
/// All commands run with `runInShell: false` and non-interactive editor/pager
/// environment variables, decide success strictly by `exitCode == 0`, inject
/// `--ignore-working-copy` when [txContext] is `readOnly` or reading past/op
/// snapshots, and parse custom JSON Lines `-T` templates including `conflict`
/// and `empty`.
class JjDriver {
  JjDriver({
    required this.namespace,
    JjTxContext? txContext,
    this.jjExecutable = 'jj',
    this.stackedTaskRegistry,
  }) : txContext = txContext ?? JjTxContext();

  factory JjDriver.forWorkspace(
    String workspaceHostRoot, {
    JjTxContext? txContext,
    String jjExecutable = 'jj',
    StackedTaskRegistry? stackedTaskRegistry,
  }) {
    return JjDriver(
      namespace: VfsNamespace(workspaceHostRoot: workspaceHostRoot),
      txContext: txContext,
      jjExecutable: jjExecutable,
      stackedTaskRegistry: stackedTaskRegistry,
    );
  }

  final VfsNamespace namespace;
  final JjTxContext txContext;
  final String jjExecutable;
  StackedTaskRegistry? stackedTaskRegistry;
  final AsyncMutex _mutex = AsyncMutex();

  String get workspaceHostRoot => namespace.workspaceHostRoot!;

  /// Custom JSON Lines `-T` template exposing `conflict` and `empty` omitted by `json(self)` ([D-014]).
  static const String commitJsonTemplate =
      r'"{\"change_id\":" ++ json(change_id.short(12)) ++ '
      r'",\"change_id_full\":" ++ json(change_id) ++ '
      r'",\"commit_id\":" ++ json(commit_id) ++ '
      r'",\"parents\":" ++ json(parents.map(|c| c.commit_id())) ++ '
      r'",\"conflict\":" ++ json(conflict) ++ '
      r'",\"empty\":" ++ json(empty) ++ '
      r'",\"description\":" ++ json(description) ++ '
      r'"}\n"';

  static final RegExp _opIdPattern = RegExp(r'^[0-9a-fA-F]{4,128}$');

  /// Non-interactive environment injected into every `jj` child process ([D-014]).
  static Map<String, String> buildNonInteractiveEnvironment() {
    final nonInteractiveEditor =
        Platform.isWindows ? 'cmd /c exit 1' : 'false';
    return <String, String>{
      'JJ_EDITOR': nonInteractiveEditor,
      'GIT_EDITOR': nonInteractiveEditor,
      'EDITOR': nonInteractiveEditor,
      'VISUAL': nonInteractiveEditor,
      'GIT_TERMINAL_PROMPT': '0',
      'PAGER': '',
      'JJ_PAGER': '',
      'NO_COLOR': '1',
    };
  }

  /// Executes [action] on the driver's single FIFO [AsyncMutex].
  Future<T> runSerialized<T>(Future<T> Function() action) =>
      _mutex.synchronized(action);

  /// Determines whether `--ignore-working-copy` must be passed for a read operation ([D-003], [D-014]).
  bool shouldIgnoreWorkingCopy({
    String? rev,
    String? revset,
    String? atOp,
    bool forceIgnoreWorkingCopy = false,
  }) {
    if (forceIgnoreWorkingCopy) {
      return true;
    }
    if (txContext.state == TxState.readOnly) {
      return true;
    }
    if (atOp != null && atOp.trim().isNotEmpty) {
      return true;
    }
    if (rev != null && rev.trim() != '@') {
      return true;
    }
    if (revset != null && revset.trim() != '@') {
      return true;
    }
    return false;
  }

  /// Non-destructively reads the current `@` `commit_id` using `--ignore-working-copy` ([D-204], [D-208]).
  ///
  /// Never triggers a working-copy snapshot or advances `jj op log`.
  Future<String?> getCurrentCommitIdNonDestructive({String? repositoryPath}) {
    return _mutex.synchronized(
      () => _readCurrentCommitIdLocked(repositoryPath: repositoryPath),
    );
  }

  /// Non-destructively reads the current `@` `commit_id` for [pcb] ([D-308]).
  Future<String?> getCurrentCommitIdForPcb(ProcessControlBlock pcb) =>
      getCurrentCommitIdNonDestructive(repositoryPath: pcb.jjWorkspaceRoot);

  Future<String?> _readCurrentCommitIdLocked({
    String? atOp,
    String? repositoryPath,
  }) async {
    final res = await _runJjRaw(<String>[
      'log',
      '--no-graph',
      '-r',
      '@',
      '--ignore-working-copy',
      if (atOp != null && atOp.trim().isNotEmpty) ...<String>[
        '--at-op',
        atOp.trim(),
      ],
      '-T',
      'commit_id',
    ], repositoryPath: repositoryPath);
    if (!res.ok) {
      return null;
    }
    final commitId = (res.value!.stdout as String).trim();
    return commitId.isEmpty ? null : commitId;
  }

  /// Non-destructively reads the current `jjChangeId` and `jjOpId` for Stage 8 audit logs ([D-010], [D-014]).
  ///
  /// Always supplies `--ignore-working-copy` so audit attribution never triggers
  /// working-copy snapshots or advances `op_id`.
  Future<JjAuditInfo> getAuditInfo() {
    return _mutex.synchronized(() async {
      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      if (!opRes.ok) {
        return JjAuditInfo(
          jjChangeId: txContext.workingChangeId,
          jjOpId: txContext.currentOpId,
        );
      }
      final opId = (opRes.value!.stdout as String).trim();

      final logRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '--ignore-working-copy',
        '-T',
        'change_id.short(12)',
      ]);
      final changeId = logRes.ok
          ? (logRes.value!.stdout as String).trim()
          : txContext.workingChangeId;

      if (opId.isNotEmpty) {
        txContext.currentOpId = opId;
      }
      if (changeId != null && changeId.isNotEmpty) {
        txContext.workingChangeId = changeId;
      }

      return JjAuditInfo(
        jjChangeId: (changeId == null || changeId.isEmpty) ? null : changeId,
        jjOpId: opId.isEmpty ? null : opId,
      );
    });
  }

  /// Non-destructively reads process-specific `jjChangeId` and `jjOpId` for Stage 8 audit logs ([D-305]).
  Future<JjAuditInfo> getAuditInfoForProcess(ProcessControlBlock? pcb) {
    if (pcb == null || !pcb.hasIsolatedJjWorkspace) {
      return getAuditInfo();
    }
    return _mutex.synchronized(() async {
      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      final opId = opRes.ok
          ? (opRes.value!.stdout as String).trim()
          : (pcb.jjContext.currentOpId ?? '');

      String? changeId = pcb.jjContext.workingChangeId;
      final wsRoot = pcb.jjWorkspaceRoot;
      if (wsRoot != null && Directory(wsRoot).existsSync()) {
        final logRes = await _runJjRaw(<String>[
          'log',
          '--no-graph',
          '-r',
          '@',
          '--ignore-working-copy',
          '-T',
          'change_id.short(12)',
        ], repositoryPath: wsRoot);
        if (logRes.ok) {
          final parsed = (logRes.value!.stdout as String).trim();
          if (parsed.isNotEmpty) {
            changeId = parsed;
            pcb.jjContext.workingChangeId = parsed;
          }
        }
      }
      if (opId.isNotEmpty) {
        pcb.jjContext.currentOpId = opId;
      }

      return JjAuditInfo(
        jjChangeId: (changeId == null || changeId.isEmpty) ? null : changeId,
        jjOpId: opId.isEmpty ? null : opId,
      );
    });
  }

  /// Explicitly triggers a working-copy snapshot for [pcb] inside the single [AsyncMutex] ([D-308]).
  Future<SyscallResult<JjAuditInfo>> syncWorkingCopySnapshotForPcb(
    ProcessControlBlock pcb,
  ) {
    final targetRoot = pcb.jjWorkspaceRoot;
    return _mutex.synchronized(() async {
      final opRes = await _runJjWithAutoUpdateStale(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '-T',
        'self.id()',
      ], repositoryPath: targetRoot);
      if (!opRes.ok) {
        return SyscallResult<JjAuditInfo>.failure(opRes.error!);
      }
      final opId = (opRes.value!.stdout as String).trim();

      final logRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '--ignore-working-copy',
        '-T',
        'change_id.short(12)',
      ], repositoryPath: targetRoot);
      if (!logRes.ok) {
        return SyscallResult<JjAuditInfo>.failure(logRes.error!);
      }
      final changeId = (logRes.value!.stdout as String).trim();

      pcb.jjContext.updateSnapshot(
        currentOpId: opId.isEmpty ? null : opId,
        workingChangeId: changeId.isEmpty ? null : changeId,
      );
      if (!pcb.hasIsolatedJjWorkspace) {
        txContext.updateSnapshot(
          currentOpId: opId.isEmpty ? null : opId,
          workingChangeId: changeId.isEmpty ? null : changeId,
        );
      }

      if (stackedTaskRegistry != null && changeId.isNotEmpty) {
        final taskNode = stackedTaskRegistry!.findByWorkingChangeId(changeId);
        if (taskNode != null) {
          final descendants = stackedTaskRegistry!
              .descendantsInTopologicalOrder(taskNode.taskId);
          await _syncTaskNodeAndCascadeLocked(
            taskNode: taskNode,
            descendants: descendants,
            alreadySnapshottedOpId: opId,
          );
        }
      }

      return SyscallResult<JjAuditInfo>.success(
        JjAuditInfo(
          jjChangeId: changeId.isEmpty ? null : changeId,
          jjOpId: opId.isEmpty ? null : opId,
        ),
      );
    });
  }

  /// Ensures an isolated transaction for [pcb] ([D-308]).
  ///
  /// Isolated worker workspaces already have their own `@` change and return immediately.
  Future<SyscallResult<JjTxContext>> ensureActiveTransactionForPcb(
    ProcessControlBlock pcb, {
    String? description,
  }) {
    if (pcb.hasIsolatedJjWorkspace) {
      return Future<SyscallResult<JjTxContext>>.value(
        SyscallResult<JjTxContext>.success(pcb.jjContext),
      );
    }
    return ensureActiveTransaction(description: description);
  }

  /// Explicitly triggers a working-copy snapshot and updates [txContext] ([D-003], [D-014]).
  ///
  /// Runs WITHOUT `--ignore-working-copy` inside the single [AsyncMutex] so
  /// post-edit state is synchronized for subsequent `sys_jj_status`/`diff` and audit logs.
  Future<SyscallResult<JjAuditInfo>> syncWorkingCopySnapshot() {
    return _mutex.synchronized(() async {
      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '-T',
        'self.id()',
      ]);
      if (!opRes.ok) {
        return SyscallResult<JjAuditInfo>.failure(opRes.error!);
      }
      final opId = (opRes.value!.stdout as String).trim();

      final logRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '--ignore-working-copy',
        '-T',
        'change_id.short(12)',
      ]);
      if (!logRes.ok) {
        return SyscallResult<JjAuditInfo>.failure(logRes.error!);
      }
      final changeId = (logRes.value!.stdout as String).trim();

      txContext.updateSnapshot(
        currentOpId: opId.isEmpty ? null : opId,
        workingChangeId: changeId.isEmpty ? null : changeId,
      );

      return SyscallResult<JjAuditInfo>.success(
        JjAuditInfo(
          jjChangeId: changeId.isEmpty ? null : changeId,
          jjOpId: opId.isEmpty ? null : opId,
        ),
      );
    });
  }

  /// Reads `@`, `@-`, changed files summary, and current `opId` (`sys_jj_status`) ([D-014], [D-208]).
  Future<SyscallResult<Map<String, dynamic>>> status({
    String? atOp,
    bool forceIgnoreWorkingCopy = false,
    String? repositoryPath,
  }) async {
    final opValidation = _validateOptionalAtOp(atOp);
    if (opValidation != null) {
      return SyscallResult<Map<String, dynamic>>.failure(opValidation);
    }

    return _mutex.synchronized(() async {
      final ignoreWc = shouldIgnoreWorkingCopy(
        rev: '@',
        atOp: atOp,
        forceIgnoreWorkingCopy: forceIgnoreWorkingCopy,
      );
      final baseFlags = <String>[
        if (ignoreWc) '--ignore-working-copy',
        if (atOp != null && atOp.trim().isNotEmpty) ...<String>[
          '--at-op',
          atOp.trim(),
        ],
      ];

      final opRes = await _runJjWithAutoUpdateStale(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        ...baseFlags,
        '-T',
        'self.id()',
      ], repositoryPath: repositoryPath);
      if (!opRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(opRes.error!);
      }
      final opId = (opRes.value!.stdout as String).trim();

      final wcRes = await _runJjWithAutoUpdateStale(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        ...baseFlags,
        '-T',
        commitJsonTemplate,
      ], repositoryPath: repositoryPath);
      if (!wcRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(wcRes.error!);
      }
      final wcParsed = _parseJsonLines(wcRes.value!.stdout as String);
      if (!wcParsed.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(wcParsed.error!);
      }
      if (wcParsed.value!.isEmpty) {
        return const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'JJ_EMPTY_STATUS',
            message: 'jj log -r @ returned no commit metadata.',
            recoverable: false,
          ),
        );
      }
      final workingCopy = wcParsed.value!.first;

      Map<String, dynamic>? parentCommit;
      final parentRes = await _runJjWithAutoUpdateStale(<String>[
        'log',
        '--no-graph',
        '-r',
        '@-',
        ...baseFlags,
        '-T',
        commitJsonTemplate,
      ], repositoryPath: repositoryPath);
      if (parentRes.ok) {
        final parentParsed = _parseJsonLines(parentRes.value!.stdout as String);
        if (parentParsed.ok && parentParsed.value!.isNotEmpty) {
          parentCommit = parentParsed.value!.first;
        }
      }

      final diffRes = await _runJjWithAutoUpdateStale(<String>[
        'diff',
        '--summary',
        '-r',
        '@',
        ...baseFlags,
      ], repositoryPath: repositoryPath);
      if (!diffRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(diffRes.error!);
      }
      final summaryText = (diffRes.value!.stdout as String).trimRight();
      final changedFiles = _parseDiffSummary(summaryText);

      final commitId = workingCopy['commit_id'] as String?;

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'opId': opId,
        if (commitId != null && commitId.isNotEmpty) 'commitId': commitId,
        'workingCopy': workingCopy,
        'parent': parentCommit,
        'changedFiles': changedFiles,
        'summary': summaryText,
        'txState': txContext.state.name,
        'ignoredWorkingCopy': ignoreWc,
      });
    });
  }

  /// Reads commit history matching [revset] using the custom JSON Lines `-T` template (`sys_jj_log`) ([D-014], [D-208]).
  Future<SyscallResult<Map<String, dynamic>>> log({
    String revset = '::@ | @-',
    int limit = 20,
    String? atOp,
    bool forceIgnoreWorkingCopy = false,
    String? repositoryPath,
  }) async {
    final trimmedRevset = revset.trim();
    if (trimmedRevset.isEmpty || trimmedRevset.startsWith('-')) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_REVSET',
          message: 'Argument "revset" must be a valid non-flag revset string.',
          recoverable: true,
        ),
      );
    }
    if (limit < 1 || limit > 500) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_LIMIT',
          message: 'Argument "limit" must be between 1 and 500 (got $limit).',
          recoverable: true,
        ),
      );
    }
    final opValidation = _validateOptionalAtOp(atOp);
    if (opValidation != null) {
      return SyscallResult<Map<String, dynamic>>.failure(opValidation);
    }

    return _mutex.synchronized(() async {
      final ignoreWc = shouldIgnoreWorkingCopy(
        revset: trimmedRevset,
        atOp: atOp,
        forceIgnoreWorkingCopy: forceIgnoreWorkingCopy,
      );
      final args = <String>[
        'log',
        '--no-graph',
        '--limit',
        '$limit',
        '-r',
        trimmedRevset,
        if (ignoreWc) '--ignore-working-copy',
        if (atOp != null && atOp.trim().isNotEmpty) ...<String>[
          '--at-op',
          atOp.trim(),
        ],
        '-T',
        commitJsonTemplate,
      ];

      final res = await _runJjWithAutoUpdateStale(
        args,
        repositoryPath: repositoryPath,
      );
      if (!res.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(res.error!);
      }

      final parsed = _parseJsonLines(res.value!.stdout as String);
      if (!parsed.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(parsed.error!);
      }

      final commits = parsed.value!;
      final commitId = await _readCurrentCommitIdLocked(
        atOp: atOp,
        repositoryPath: repositoryPath,
      );
      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'revset': trimmedRevset,
        'limit': limit,
        'commits': commits,
        'count': commits.length,
        'commitId': ?commitId,
        'ignoredWorkingCopy': ignoreWc,
      });
    });
  }

  /// Reads unified Git-format diff for [rev] (`sys_jj_diff`) ([D-014], [D-208]).
  Future<SyscallResult<Map<String, dynamic>>> diff({
    String rev = '@',
    List<String>? paths,
    String? atOp,
    bool forceIgnoreWorkingCopy = false,
    VfsNamespace? namespaceOverride,
    String? repositoryPath,
  }) async {
    final effectiveNamespace = namespaceOverride ?? namespace;
    final trimmedRev = rev.trim();
    if (trimmedRev.isEmpty || trimmedRev.startsWith('-')) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_REVISION',
          message: 'Argument "rev" must be a valid non-flag revision string.',
          recoverable: true,
        ),
      );
    }
    final opValidation = _validateOptionalAtOp(atOp);
    if (opValidation != null) {
      return SyscallResult<Map<String, dynamic>>.failure(opValidation);
    }

    final resolvedRelPaths = <String>[];
    if (paths != null) {
      for (final rawPath in paths) {
        final vfsRes = effectiveNamespace.resolveVirtualPath(
          rawPath,
          allowRoot: true,
          checkProtected: true,
          checkSymlinks: true,
        );
        if (!vfsRes.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(vfsRes.error!);
        }
        final resolved = vfsRes.value!;
        resolvedRelPaths.add(
          resolved.isRoot ? '.' : resolved.relativeSegments.join('/'),
        );
      }
    }

    return _mutex.synchronized(() async {
      final ignoreWc = shouldIgnoreWorkingCopy(
        rev: trimmedRev,
        atOp: atOp,
        forceIgnoreWorkingCopy: forceIgnoreWorkingCopy,
      );
      final args = <String>[
        'diff',
        '--git',
        '-r',
        trimmedRev,
        if (ignoreWc) '--ignore-working-copy',
        if (atOp != null && atOp.trim().isNotEmpty) ...<String>[
          '--at-op',
          atOp.trim(),
        ],
        if (resolvedRelPaths.isNotEmpty) ...<String>[
          '--',
          ...resolvedRelPaths,
        ],
      ];

      final res = await _runJjWithAutoUpdateStale(
        args,
        repositoryPath: repositoryPath,
      );
      if (!res.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(res.error!);
      }

      final commitId = await _readCurrentCommitIdLocked(
        atOp: atOp,
        repositoryPath: repositoryPath,
      );
      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'rev': trimmedRev,
        'diff': res.value!.stdout as String,
        'commitId': ?commitId,
        'ignoredWorkingCopy': ignoreWc,
      });
    });
  }

  /// Atomically ensures an isolated working-copy transaction (`TxState.active`) ([D-003], [D-015]).
  ///
  /// When [txContext] is [TxState.readOnly], inside the single [AsyncMutex] this:
  /// 1. Ensures `/workspace/.agent_os/.gitignore` exists (`*\n`).
  /// 2. Snapshots the user's unsnapshotted working copy (without `--ignore-working-copy`)
  ///    and records the resulting `op_id` as `baseOpId` in the session allowlist.
  /// 3. Captures `@`'s `change_id` as `parentChangeId` (`@-`) and runs `jj new -m ...`
  ///    to isolate agent edits into a fresh child `@` without touching `@-`.
  ///
  /// Idempotent when already [TxState.active].
  Future<SyscallResult<JjTxContext>> ensureActiveTransaction({
    String? description,
  }) async {
    final res = await _ensureActiveTransactionInternal(description: description);
    if (!res.ok) {
      return SyscallResult<JjTxContext>.failure(res.error!);
    }
    return SyscallResult<JjTxContext>.success(res.value!.context);
  }

  /// Syscall handler for `sys_tx_begin` ([D-015]).
  Future<SyscallResult<Map<String, dynamic>>> txBegin({
    String? description,
  }) async {
    final res = await _ensureActiveTransactionInternal(description: description);
    if (!res.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(res.error!);
    }
    final info = res.value!;
    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'state': info.context.state.name,
      'alreadyActive': info.alreadyActive,
      'baseOpId': info.context.baseOpId,
      'parentChangeId': info.context.parentChangeId,
      'workingChangeId': info.context.workingChangeId,
      'currentOpId': info.context.currentOpId,
    });
  }

  Future<SyscallResult<({JjTxContext context, bool alreadyActive})>>
      _ensureActiveTransactionInternal({String? description}) {
    return _mutex.synchronized(
      () => _ensureActiveTransactionLocked(description: description),
    );
  }

  Future<SyscallResult<({JjTxContext context, bool alreadyActive})>>
      _ensureActiveTransactionLocked({String? description}) async {
    if (txContext.state == TxState.active) {
      return SyscallResult<({JjTxContext context, bool alreadyActive})>.success(
        (context: txContext, alreadyActive: true),
      );
    }

    ensureAgentOsGitignoreSync(workspaceHostRoot);

    // 1. Snapshot user's current working copy WITHOUT --ignore-working-copy and record baseOpId.
    final snapOpRes = await _runJjRaw(<String>[
      'op',
      'log',
      '--no-graph',
      '--limit',
      '1',
      '-T',
      'self.id()',
    ]);
    if (!snapOpRes.ok) {
      return SyscallResult<
          ({JjTxContext context, bool alreadyActive})>.failure(
        snapOpRes.error!,
      );
    }
    final baseOpId = (snapOpRes.value!.stdout as String).trim();
    if (baseOpId.isEmpty) {
      return const SyscallResult<
          ({JjTxContext context, bool alreadyActive})>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'JJ_EMPTY_OP_ID',
          message: 'jj op log returned an empty operation ID during tx begin.',
          recoverable: false,
        ),
      );
    }

    // 2. Capture the user's current change ID (which will become immutable parent @-).
    final parentChangeRes = await _runJjRaw(<String>[
      'log',
      '--no-graph',
      '-r',
      '@',
      '--ignore-working-copy',
      '-T',
      'change_id.short(12)',
    ]);
    if (!parentChangeRes.ok) {
      return SyscallResult<
          ({JjTxContext context, bool alreadyActive})>.failure(
        parentChangeRes.error!,
      );
    }
    final parentChangeId = (parentChangeRes.value!.stdout as String).trim();

    // 3. Split a fresh child working change `@` with `jj new`.
    final effectiveMessage =
        (description != null && description.trim().isNotEmpty)
            ? description.trim()
            : 'agent-os: working change';
    final newRes = await _runJjRaw(<String>[
      'new',
      '-m',
      effectiveMessage,
    ]);
    if (!newRes.ok) {
      return SyscallResult<
          ({JjTxContext context, bool alreadyActive})>.failure(
        newRes.error!,
      );
    }

    // 4. Read new `@` change_id and head op_id non-destructively.
    final workChangeRes = await _runJjRaw(<String>[
      'log',
      '--no-graph',
      '-r',
      '@',
      '--ignore-working-copy',
      '-T',
      'change_id.short(12)',
    ]);
    if (!workChangeRes.ok) {
      return SyscallResult<
          ({JjTxContext context, bool alreadyActive})>.failure(
        workChangeRes.error!,
      );
    }
    final workingChangeId = (workChangeRes.value!.stdout as String).trim();

    final newOpRes = await _runJjRaw(<String>[
      'op',
      'log',
      '--no-graph',
      '--limit',
      '1',
      '--ignore-working-copy',
      '-T',
      'self.id()',
    ]);
    if (!newOpRes.ok) {
      return SyscallResult<
          ({JjTxContext context, bool alreadyActive})>.failure(
        newOpRes.error!,
      );
    }
    final currentOpId = (newOpRes.value!.stdout as String).trim();

    txContext.enterActive(
      baseOpId: baseOpId,
      parentChangeId: parentChangeId,
      workingChangeId: workingChangeId,
      currentOpId: currentOpId.isEmpty ? baseOpId : currentOpId,
    );
    txContext.anchorWorkingChangeId = workingChangeId;
    txContext.pendingWorkerChangeIds.clear();

    return SyscallResult<({JjTxContext context, bool alreadyActive})>.success(
      (context: txContext, alreadyActive: false),
    );
  }

  /// Allocates an isolated `--no-colocate` `jj workspace` at `.agent_os/ws/<pid>` ([D-307]).
  Future<SyscallResult<AllocatedWorkspace>> allocateWorkerWorkspace({
    required Pid pid,
    String? baseChangeId,
    String? description,
  }) {
    return _mutex.synchronized(() async {
      ensureAgentOsGitignoreSync(workspaceHostRoot);

      late final String effectiveBase;
      if (baseChangeId != null && baseChangeId.trim().isNotEmpty) {
        final trimmed = baseChangeId.trim();
        if (trimmed.startsWith('-')) {
          return const SyscallResult<AllocatedWorkspace>.failure(
            SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'INVALID_REVISION',
              message: 'baseChangeId must not start with "-".',
              recoverable: true,
            ),
          );
        }
        final verifyRes = await _runJjRaw(<String>[
          'log',
          '--no-graph',
          '-r',
          trimmed,
          '--ignore-working-copy',
          '-T',
          'change_id.short(12)',
        ]);
        if (!verifyRes.ok) {
          return SyscallResult<AllocatedWorkspace>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'JJ_TARGET_NOT_FOUND',
              message:
                  'Target baseChangeId "$trimmed" was not found: ${verifyRes.error!.message}',
              recoverable: true,
            ),
          );
        }
        final resolved = (verifyRes.value!.stdout as String).trim();
        if (resolved.isEmpty) {
          return SyscallResult<AllocatedWorkspace>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'JJ_TARGET_NOT_FOUND',
              message: 'Target baseChangeId "$trimmed" resolved to empty.',
              recoverable: true,
            ),
          );
        }
        effectiveBase = resolved;
      } else {
        if (txContext.state == TxState.readOnly) {
          final txRes = await _ensureActiveTransactionLocked(
            description: description,
          );
          if (!txRes.ok) {
            return SyscallResult<AllocatedWorkspace>.failure(txRes.error!);
          }
        }
        effectiveBase = txContext.workingChangeId!;
      }

      final wsName = JjWorkspaceOps.workspaceNameForPid(pid);
      final wsRoot = JjWorkspaceOps.workspaceRootForPid(workspaceHostRoot, pid);
      final wsParent = Directory(p.dirname(wsRoot));
      if (!wsParent.existsSync()) {
        wsParent.createSync(recursive: true);
      }
      final existingDir = Directory(wsRoot);
      if (existingDir.existsSync()) {
        await _deleteDirectoryWithRetry(existingDir);
      }

      final addRes = await _runJjRaw(
        JjWorkspaceOps.buildWorkspaceAddArgs(
          workspaceRoot: wsRoot,
          workspaceName: wsName,
          baseChangeId: effectiveBase,
          description: description,
        ),
      );
      if (!addRes.ok) {
        return SyscallResult<AllocatedWorkspace>.failure(addRes.error!);
      }

      final wcRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '--ignore-working-copy',
        '-T',
        commitJsonTemplate,
      ], repositoryPath: wsRoot);
      if (!wcRes.ok) {
        return SyscallResult<AllocatedWorkspace>.failure(wcRes.error!);
      }
      final parsed = _parseJsonLines(wcRes.value!.stdout as String);
      if (!parsed.ok || parsed.value!.isEmpty) {
        return const SyscallResult<AllocatedWorkspace>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'JJ_EMPTY_WORKSPACE_STATUS',
            message: 'Allocated workspace returned no @ commit metadata.',
            recoverable: false,
          ),
        );
      }
      final wc = parsed.value!.first;
      final workingChangeId = (wc['change_id'] as String?)?.trim() ?? '';
      final commitId = (wc['commit_id'] as String?)?.trim() ?? '';

      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ], repositoryPath: wsRoot);
      final currentOpId = opRes.ok ? (opRes.value!.stdout as String).trim() : '';

      return SyscallResult<AllocatedWorkspace>.success(
        AllocatedWorkspace(
          workspaceName: wsName,
          workspaceRoot: wsRoot,
          baseChangeId: effectiveBase,
          workingChangeId: workingChangeId,
          commitId: commitId,
          currentOpId: currentOpId,
        ),
      );
    });
  }

  /// Cleans up a child worker's `jj workspace` (`forget`, optional `abandon`, and directory deletion) ([D-307]).
  Future<WorkspaceCleanupResult> cleanupWorkerWorkspace({
    required String workspaceName,
    required String workspaceRoot,
    String? workingChangeId,
    String? baseChangeId,
    required bool abandonChange,
  }) async {
    String? finalChangeId = workingChangeId;
    String? finalCommitId;

    await _mutex.synchronized(() async {
      if (!abandonChange && Directory(workspaceRoot).existsSync()) {
        final wcRes = await _runJjWithAutoUpdateStale(<String>[
          'log',
          '--no-graph',
          '-r',
          '@',
          '-T',
          commitJsonTemplate,
        ], repositoryPath: workspaceRoot);
        if (wcRes.ok) {
          final parsed = _parseJsonLines(wcRes.value!.stdout as String);
          if (parsed.ok && parsed.value!.isNotEmpty) {
            final wc = parsed.value!.first;
            final cId = (wc['change_id'] as String?)?.trim();
            final comId = (wc['commit_id'] as String?)?.trim();
            if (cId != null && cId.isNotEmpty) {
              finalChangeId = cId;
            }
            if (comId != null && comId.isNotEmpty) {
              finalCommitId = comId;
            }
          }
        }
      }

      await _runJjRaw(JjWorkspaceOps.buildWorkspaceForgetArgs(workspaceName));

      if (abandonChange &&
          finalChangeId != null &&
          finalChangeId!.isNotEmpty &&
          finalChangeId != baseChangeId) {
        await _runJjRaw(<String>['abandon', finalChangeId!]);
      }
    });

    final dir = Directory(workspaceRoot);
    final cleanedUp = await _deleteDirectoryWithRetry(dir);
    return WorkspaceCleanupResult(
      finalChangeId: finalChangeId,
      finalCommitId: abandonChange ? null : finalCommitId,
      cleanedUp: cleanedUp,
    );
  }

  /// Lists registered Jujutsu workspaces non-destructively inside the single mutex ([D-307]).
  Future<SyscallResult<List<Map<String, dynamic>>>> listWorkspaces() {
    return _mutex.synchronized(() async {
      final res = await _runJjRaw(JjWorkspaceOps.buildWorkspaceListArgs());
      if (!res.ok) {
        return SyscallResult<List<Map<String, dynamic>>>.failure(res.error!);
      }
      return SyscallResult<List<Map<String, dynamic>>>.success(
        JjWorkspaceOps.parseWorkspaceListJsonLines(res.value!.stdout as String),
      );
    });
  }

  /// Allocates an isolated `--no-colocate` `jj workspace` for a Stacked Changes task ([D-311]).
  Future<SyscallResult<AllocatedWorkspace>> allocateTaskWorkspace({
    required String taskId,
    String? baseChangeId,
    String? description,
  }) {
    return _mutex.synchronized(() async {
      ensureAgentOsGitignoreSync(workspaceHostRoot);

      late final String effectiveBase;
      if (baseChangeId != null && baseChangeId.trim().isNotEmpty) {
        final trimmed = baseChangeId.trim();
        if (trimmed.startsWith('-')) {
          return const SyscallResult<AllocatedWorkspace>.failure(
            SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'INVALID_REVISION',
              message: 'baseChangeId must not start with "-".',
              recoverable: true,
            ),
          );
        }
        final verifyRes = await _runJjRaw(<String>[
          'log',
          '--no-graph',
          '-r',
          trimmed,
          '--ignore-working-copy',
          '-T',
          'change_id.short(12)',
        ]);
        if (!verifyRes.ok) {
          return SyscallResult<AllocatedWorkspace>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'JJ_TARGET_NOT_FOUND',
              message:
                  'Target baseChangeId "$trimmed" was not found: ${verifyRes.error!.message}',
              recoverable: true,
            ),
          );
        }
        final resolved = (verifyRes.value!.stdout as String).trim();
        if (resolved.isEmpty) {
          return SyscallResult<AllocatedWorkspace>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'JJ_TARGET_NOT_FOUND',
              message: 'Target baseChangeId "$trimmed" resolved to empty.',
              recoverable: true,
            ),
          );
        }
        effectiveBase = resolved;
      } else {
        if (txContext.state == TxState.readOnly) {
          final txRes = await _ensureActiveTransactionLocked(
            description: description,
          );
          if (!txRes.ok) {
            return SyscallResult<AllocatedWorkspace>.failure(txRes.error!);
          }
        }
        effectiveBase = txContext.workingChangeId!;
      }

      final wsName = JjWorkspaceOps.taskWorkspaceName(taskId);
      final wsRoot = JjWorkspaceOps.taskWorkspaceRoot(workspaceHostRoot, taskId);
      final wsParent = Directory(p.dirname(wsRoot));
      if (!wsParent.existsSync()) {
        wsParent.createSync(recursive: true);
      }
      final existingDir = Directory(wsRoot);
      if (existingDir.existsSync()) {
        await _deleteDirectoryWithRetry(existingDir);
      }

      final addRes = await _runJjRaw(
        JjWorkspaceOps.buildWorkspaceAddArgs(
          workspaceRoot: wsRoot,
          workspaceName: wsName,
          baseChangeId: effectiveBase,
          description: description ?? 'task($taskId)',
        ),
      );
      if (!addRes.ok) {
        return SyscallResult<AllocatedWorkspace>.failure(addRes.error!);
      }

      final wcRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '--ignore-working-copy',
        '-T',
        commitJsonTemplate,
      ], repositoryPath: wsRoot);
      if (!wcRes.ok) {
        return SyscallResult<AllocatedWorkspace>.failure(wcRes.error!);
      }
      final parsed = _parseJsonLines(wcRes.value!.stdout as String);
      if (!parsed.ok || parsed.value!.isEmpty) {
        return const SyscallResult<AllocatedWorkspace>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'JJ_EMPTY_WORKSPACE_STATUS',
            message: 'Allocated task workspace returned no @ commit metadata.',
            recoverable: false,
          ),
        );
      }
      final wc = parsed.value!.first;
      final workingChangeId = (wc['change_id'] as String?)?.trim() ?? '';
      final commitId = (wc['commit_id'] as String?)?.trim() ?? '';

      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ], repositoryPath: wsRoot);
      final currentOpId = opRes.ok ? (opRes.value!.stdout as String).trim() : '';

      return SyscallResult<AllocatedWorkspace>.success(
        AllocatedWorkspace(
          workspaceName: wsName,
          workspaceRoot: wsRoot,
          baseChangeId: effectiveBase,
          workingChangeId: workingChangeId,
          commitId: commitId,
          currentOpId: currentOpId,
        ),
      );
    });
  }

  /// Removes a Stacked Changes task workspace (`forget`, optional `abandon`, and directory deletion) ([D-311]).
  Future<({bool cleanedUp, String opId})> removeTaskWorkspace({
    required String workspaceName,
    required String workspaceRoot,
    String? workingChangeId,
    bool abandonChange = false,
  }) async {
    var opId = '';
    await _mutex.synchronized(() async {
      await _runJjRaw(JjWorkspaceOps.buildWorkspaceForgetArgs(workspaceName));
      if (abandonChange &&
          workingChangeId != null &&
          workingChangeId.trim().isNotEmpty) {
        await _runJjRaw(<String>['abandon', workingChangeId.trim()]);
      }
      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      if (opRes.ok) {
        opId = (opRes.value!.stdout as String).trim();
      }
    });
    final cleanedUp = await _deleteDirectoryWithRetry(Directory(workspaceRoot));
    return (cleanedUp: cleanedUp, opId: opId);
  }

  /// Snapshots [taskNode]'s workspace and cascades `workspace update-stale` in topological order ([D-311]).
  Future<SyscallResult<({List<StackedCascadeTaskResult> cascaded, String opId})>>
      syncTaskWorkspaceAndCascade({
    required StackedTaskNode taskNode,
    required List<StackedTaskNode> descendants,
  }) {
    return _mutex.synchronized(
      () => _syncTaskNodeAndCascadeLocked(
        taskNode: taskNode,
        descendants: descendants,
      ),
    );
  }

  Future<SyscallResult<({List<StackedCascadeTaskResult> cascaded, String opId})>>
      _syncTaskNodeAndCascadeLocked({
    required StackedTaskNode taskNode,
    required List<StackedTaskNode> descendants,
    String? alreadySnapshottedOpId,
  }) async {
    var opId = alreadySnapshottedOpId ?? '';
    if (alreadySnapshottedOpId == null) {
      final snapRes = await _runJjWithAutoUpdateStale(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '-T',
        'self.id()',
      ], repositoryPath: taskNode.workspaceRoot);
      if (!snapRes.ok) {
        return SyscallResult<
            ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
          snapRes.error!,
        );
      }
      opId = (snapRes.value!.stdout as String).trim();
    }

    final selfSyncErr = await _refreshTaskNodeMetadataLocked(
      taskNode,
      opId: opId,
    );
    if (selfSyncErr != null) {
      return SyscallResult<
          ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
        selfSyncErr,
      );
    }

    final cascadeRes = await _cascadeUpdateStaleLocked(
      descendants: descendants,
      initialOpId: opId,
    );
    if (!cascadeRes.ok) {
      return SyscallResult<
          ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
        cascadeRes.error!,
      );
    }
    return SyscallResult<
        ({List<StackedCascadeTaskResult> cascaded, String opId})>.success(
      cascadeRes.value!,
    );
  }

  /// Integrates one or more worker changes into [taskNode]'s change and cascades `update-stale` ([D-311]).
  Future<SyscallResult<({List<StackedCascadeTaskResult> cascaded, String opId})>>
      integrateWorkerChangesIntoTask({
    required StackedTaskNode taskNode,
    required List<String> workerChangeIds,
    bool abandonWorkerChanges = true,
    List<StackedTaskNode> descendants = const <StackedTaskNode>[],
  }) {
    if (workerChangeIds.isEmpty) {
      return Future<
          SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>>.value(
        const SyscallResult<
            ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_ARGS',
            message: 'workerChangeIds must contain at least one Change ID.',
            recoverable: true,
          ),
        ),
      );
    }
    for (final id in workerChangeIds) {
      final trimmed = id.trim();
      if (trimmed.isEmpty || trimmed.startsWith('-')) {
        return Future<
            SyscallResult<
                ({List<StackedCascadeTaskResult> cascaded, String opId})>>.value(
          const SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
            SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'INVALID_REVISION',
              message:
                  'Each entry in workerChangeIds must be a non-empty non-flag revision string.',
              recoverable: true,
            ),
          ),
        );
      }
    }

    return _mutex.synchronized(() async {
      // 1. Validate worker Change IDs exist.
      final resolvedWorkers = <String>[];
      final seen = <String>{};
      for (final raw in workerChangeIds) {
        final trimmed = raw.trim();
        final verifyRes = await _runJjRaw(<String>[
          'log',
          '--no-graph',
          '-r',
          trimmed,
          '--ignore-working-copy',
          '-T',
          'change_id.short(12)',
        ]);
        if (!verifyRes.ok) {
          return SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'JJ_TARGET_NOT_FOUND',
              message:
                  'Worker revision "$trimmed" was not found: ${verifyRes.error!.message}',
              recoverable: true,
            ),
          );
        }
        final resolved = (verifyRes.value!.stdout as String).trim();
        if (resolved.isEmpty) {
          return SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'JJ_TARGET_NOT_FOUND',
              message: 'Worker revision "$trimmed" resolved to empty.',
              recoverable: true,
            ),
          );
        }
        if (resolved != taskNode.workingChangeId && seen.add(resolved)) {
          resolvedWorkers.add(resolved);
        }
      }

      // 2. Snapshot task workspace first so any prior local edits are committed.
      final snapRes = await _runJjWithAutoUpdateStale(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '-T',
        'self.id()',
      ], repositoryPath: taskNode.workspaceRoot);
      if (!snapRes.ok) {
        return SyscallResult<
            ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
          snapRes.error!,
        );
      }

      if (resolvedWorkers.isNotEmpty) {
        // Record main @ change_id so we can restore main working copy if needed.
        final mainWcRes = await _runJjRaw(<String>[
          'log',
          '--no-graph',
          '-r',
          '@',
          '--ignore-working-copy',
          '-T',
          'change_id.short(12)',
        ]);
        final prevMainChangeId =
            mainWcRes.ok ? (mainWcRes.value!.stdout as String).trim() : '';

        // Create temporary merge change combining taskNode.workingChangeId + worker changes.
        final newRes = await _runJjRaw(<String>[
          'new',
          taskNode.workingChangeId,
          ...resolvedWorkers,
          '-m',
          'agent-os: integrate workers into ${taskNode.taskId}',
        ]);
        if (!newRes.ok) {
          return SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
            newRes.error!,
          );
        }

        final mergeIdRes = await _runJjRaw(<String>[
          'log',
          '--no-graph',
          '-r',
          '@',
          '--ignore-working-copy',
          '-T',
          'change_id.short(12)',
        ]);
        if (!mergeIdRes.ok) {
          return SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
            mergeIdRes.error!,
          );
        }
        final mergeChangeId = (mergeIdRes.value!.stdout as String).trim();

        // Transfer merged tree (including any First-Class Conflicts) into taskNode.workingChangeId.
        final restoreRes = await _runJjRaw(<String>[
          'restore',
          '--from',
          mergeChangeId,
          '--into',
          taskNode.workingChangeId,
        ]);
        if (!restoreRes.ok) {
          return SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
            restoreRes.error!,
          );
        }

        if (prevMainChangeId.isNotEmpty && prevMainChangeId != mergeChangeId) {
          await _runJjRaw(<String>['edit', prevMainChangeId]);
        }

        final toAbandon = <String>[
          if (mergeChangeId.isNotEmpty &&
              mergeChangeId != taskNode.workingChangeId)
            mergeChangeId,
          if (abandonWorkerChanges)
            ...resolvedWorkers.where(
              (id) =>
                  id != taskNode.workingChangeId &&
                  id != prevMainChangeId &&
                  id != txContext.parentChangeId &&
                  id != txContext.anchorWorkingChangeId,
            ),
        ];
        if (toAbandon.isNotEmpty) {
          await _runJjRaw(<String>['abandon', ...toAbandon]);
        }

        // Update task workspace working copy to match updated c_A.
        final updateTaskWsRes = await _runJjRaw(
          JjWorkspaceOps.buildWorkspaceUpdateStaleArgs(),
          repositoryPath: taskNode.workspaceRoot,
        );
        if (!updateTaskWsRes.ok &&
            !JjWorkspaceOps.isStaleWorkingCopyError(
              updateTaskWsRes.error!.message,
            )) {
          // If workspace wasn't stale (or update-stale is no-op), continue unless fatal.
          // Note: jj workspace update-stale exits 0 even when already up-to-date.
          return SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
            updateTaskWsRes.error!,
          );
        }
      }

      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      final opId = opRes.ok ? (opRes.value!.stdout as String).trim() : '';

      final selfSyncErr = await _refreshTaskNodeMetadataLocked(
        taskNode,
        opId: opId,
      );
      if (selfSyncErr != null) {
        return SyscallResult<
            ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
          selfSyncErr,
        );
      }

      return _cascadeUpdateStaleLocked(
        descendants: descendants,
        initialOpId: opId,
      );
    });
  }

  /// Non-destructively refreshes [taskNode]'s `commitId`, `hasConflicts`, and `conflictedFiles` ([D-311]).
  Future<SyscallResult<void>> inspectTaskNodeMetadata({
    required StackedTaskNode taskNode,
  }) {
    return _mutex.synchronized(() async {
      final err = await _refreshTaskNodeMetadataLocked(taskNode);
      if (err != null) {
        return SyscallResult<void>.failure(err);
      }
      return const SyscallResult<void>.success(null);
    });
  }

  /// Reads non-destructive Git-format diff for [taskNode]'s workspace (`focus`) ([D-311]).
  Future<SyscallResult<String>> diffForTask({
    required StackedTaskNode taskNode,
  }) async {
    final res = await diff(
      rev: '@',
      forceIgnoreWorkingCopy: true,
      repositoryPath: taskNode.workspaceRoot,
    );
    if (!res.ok) {
      return SyscallResult<String>.failure(res.error!);
    }
    return SyscallResult<String>.success((res.value!['diff'] as String?) ?? '');
  }

  Future<SyscallError?> _refreshTaskNodeMetadataLocked(
    StackedTaskNode node, {
    String? opId,
  }) async {
    final conflictRes = await _inspectConflictsNonDestructiveLocked(
      rev: node.workingChangeId,
      namespaceOverride: VfsNamespace(workspaceHostRoot: node.workspaceRoot),
    );
    if (!conflictRes.ok) {
      return conflictRes.error!;
    }
    final info = conflictRes.value!;
    final commitId = (info['commitId'] as String?)?.trim() ?? '';
    final hasConflicts = info['hasConflicts'] == true;
    final files = (info['files'] as List<dynamic>).cast<String>();

    if (commitId.isNotEmpty) {
      node.commitId = commitId;
    }
    node.hasConflicts = hasConflicts;
    node.conflictedFiles = List<String>.from(files);
    if (opId != null && opId.isNotEmpty) {
      node.lastSyncedOpId = opId;
    }
    if (hasConflicts) {
      node.state = StackedTaskState.conflict;
    } else if (node.state == StackedTaskState.conflict) {
      node.state = StackedTaskState.todo;
    }
    return null;
  }

  Future<SyscallResult<({List<StackedCascadeTaskResult> cascaded, String opId})>>
      _cascadeUpdateStaleLocked({
    required List<StackedTaskNode> descendants,
    required String initialOpId,
  }) async {
    final cascaded = <StackedCascadeTaskResult>[];
    var latestOpId = initialOpId;

    for (final childNode in descendants) {
      if (Directory(childNode.workspaceRoot).existsSync()) {
        final updateRes = await _runJjRaw(
          JjWorkspaceOps.buildWorkspaceUpdateStaleArgs(),
          repositoryPath: childNode.workspaceRoot,
        );
        if (!updateRes.ok) {
          return SyscallResult<
              ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
            updateRes.error!,
          );
        }
      }

      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      if (opRes.ok) {
        final op = (opRes.value!.stdout as String).trim();
        if (op.isNotEmpty) {
          latestOpId = op;
        }
      }

      final metaErr = await _refreshTaskNodeMetadataLocked(
        childNode,
        opId: latestOpId,
      );
      if (metaErr != null) {
        return SyscallResult<
            ({List<StackedCascadeTaskResult> cascaded, String opId})>.failure(
          metaErr,
        );
      }

      cascaded.add(
        StackedCascadeTaskResult(
          taskId: childNode.taskId,
          workingChangeId: childNode.workingChangeId,
          commitId: childNode.commitId,
          hasConflicts: childNode.hasConflicts,
          conflictedFiles: List<String>.from(childNode.conflictedFiles),
          state: childNode.state.wireValue,
        ),
      );
    }

    return SyscallResult<
        ({List<StackedCascadeTaskResult> cascaded, String opId})>.success(
      (cascaded: cascaded, opId: latestOpId),
    );
  }

  static Future<bool> _deleteDirectoryWithRetry(Directory dir) async {
    if (!dir.existsSync()) {
      return true;
    }
    const delaysMs = <int>[50, 100, 150, 250, 400];
    for (var attempt = 0; attempt <= delaysMs.length; attempt++) {
      try {
        await dir.delete(recursive: true);
        if (!dir.existsSync()) {
          return true;
        }
      } on FileSystemException {
        if (attempt < delaysMs.length) {
          await Future<void>.delayed(Duration(milliseconds: delaysMs[attempt]));
        }
      }
    }
    return !dir.existsSync();
  }

  /// Updates the description of the active isolated working change (`sys_tx_describe`) ([D-015]).
  Future<SyscallResult<Map<String, dynamic>>> txDescribe({
    required String message,
  }) async {
    if (message.trim().isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message: 'Argument "message" must be a non-empty string.',
          recoverable: true,
        ),
      );
    }

    return _mutex.synchronized(() async {
      if (txContext.state != TxState.active) {
        return const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.econflict,
            reason: 'NO_ACTIVE_TRANSACTION',
            message:
                'Cannot describe change: no active isolated transaction (TxState != active).',
            recoverable: true,
            hint:
                'Call sys_tx_begin or edit a file in /workspace before calling sys_tx_describe.',
          ),
        );
      }

      final descRes = await _runJjRaw(<String>['describe', '-m', message]);
      if (!descRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(descRes.error!);
      }

      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      if (opRes.ok) {
        final opId = (opRes.value!.stdout as String).trim();
        txContext.updateSnapshot(currentOpId: opId.isEmpty ? null : opId);
      }

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'state': txContext.state.name,
        'workingChangeId': txContext.workingChangeId,
        'parentChangeId': txContext.parentChangeId,
        'currentOpId': txContext.currentOpId,
        'description': message,
      });
    });
  }

  /// Non-destructively inspects First-Class Conflicts on [rev] (`sys_jj_conflicts`) ([D-310]).
  ///
  /// Uses `conflicted_files` JSON template with `--ignore-working-copy` so it
  /// always exits `0` regardless of whether conflicts exist (avoiding `jj resolve --list` exit=2).
  Future<SyscallResult<Map<String, dynamic>>> inspectConflictsNonDestructive({
    String rev = '@',
    VfsNamespace? namespaceOverride,
    String? repositoryPath,
  }) {
    final trimmedRev = rev.trim();
    if (trimmedRev.isEmpty || trimmedRev.startsWith('-')) {
      return Future<SyscallResult<Map<String, dynamic>>>.value(
        const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_ARGS',
            message:
                'Argument "rev" must be a non-empty revision expression not starting with "-".',
            recoverable: true,
          ),
        ),
      );
    }
    return _mutex.synchronized(
      () => _inspectConflictsNonDestructiveLocked(
        rev: trimmedRev,
        namespaceOverride: namespaceOverride,
        repositoryPath: repositoryPath,
      ),
    );
  }

  Future<SyscallResult<Map<String, dynamic>>>
      _inspectConflictsNonDestructiveLocked({
    String rev = '@',
    VfsNamespace? namespaceOverride,
    String? repositoryPath,
  }) async {
    final opRes = await _runJjRaw(
      <String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ],
      repositoryPath: repositoryPath,
    );
    final opId = opRes.ok ? (opRes.value!.stdout as String).trim() : '';

    final res = await _runJjWithAutoUpdateStale(
      <String>[
        'log',
        '--no-graph',
        '-r',
        rev,
        '--ignore-working-copy',
        '-T',
        JjWorkspaceOps.conflictsJsonTemplate,
      ],
      repositoryPath: repositoryPath,
    );
    if (!res.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'JJ_TARGET_NOT_FOUND',
          message:
              'Revision "$rev" could not be resolved for conflict inspection: ${res.error!.message}',
          recoverable: true,
        ),
      );
    }

    final parsedRes = _parseJsonLines(res.value!.stdout as String);
    if (!parsedRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(parsedRes.error!);
    }
    final rows = parsedRes.value!;
    if (rows.isEmpty) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'JJ_TARGET_NOT_FOUND',
          message: 'Revision "$rev" matched 0 commits.',
          recoverable: true,
        ),
      );
    }
    if (rows.length > 1) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'AMBIGUOUS_REVISION',
          message:
              'Revision "$rev" matched ${rows.length} commits; specify a single revision.',
          recoverable: true,
        ),
      );
    }

    final row = rows.first;
    final changeId = (row['change_id'] as String?)?.trim() ?? '';
    final commitId = (row['commit_id'] as String?)?.trim() ?? '';
    final hasConflicts = row['conflict'] == true;
    final rawFiles = row['files'] is List ? row['files'] as List : const <dynamic>[];
    final files = JjWorkspaceOps.normalizeConflictedVirtualPaths(
      rawFiles,
      namespace: namespaceOverride,
    );

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'rev': rev,
      'changeId': changeId,
      'commitId': commitId,
      'hasConflicts': hasConflicts,
      'files': files,
      'opId': ?(opId.isNotEmpty ? opId : null),
    });
  }

  /// Creates a multi-parent merge commit over [changeIds] (`sys_jj_merge`) ([D-309]).
  ///
  /// Never aborts on First-Class Conflicts: records `hasConflicts` and `conflictedFiles`
  /// in the returned payload so the caller or `ConflictResolver` can resolve them.
  Future<SyscallResult<Map<String, dynamic>>> mergeChanges({
    required List<String> changeIds,
    String? message,
    VfsNamespace? namespaceOverride,
  }) {
    final validation = _validateMergeArgs(<String, dynamic>{
      'changeIds': changeIds,
      'message': ?message,
    });
    if (validation != null) {
      return Future<SyscallResult<Map<String, dynamic>>>.value(
        SyscallResult<Map<String, dynamic>>.failure(validation),
      );
    }

    return _mutex.synchronized(() async {
      ensureAgentOsGitignoreSync(workspaceHostRoot);

      if (txContext.state == TxState.readOnly) {
        final txRes = await _ensureActiveTransactionLocked(
          description: 'agent-os: working change',
        );
        if (!txRes.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(txRes.error!);
        }
      }
      txContext.anchorWorkingChangeId ??= txContext.workingChangeId;

      final resolvedParents = <String>[];
      final seenParents = <String>{};
      for (final rawId in changeIds) {
        final target = rawId.trim();
        final verifyRes = await _runJjRaw(<String>[
          'log',
          '--no-graph',
          '-r',
          target,
          '--ignore-working-copy',
          '-T',
          r'change_id.short(12) ++ "\n"',
        ]);
        if (!verifyRes.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'JJ_TARGET_NOT_FOUND',
              message:
                  'Merge parent revision "$target" was not found: ${verifyRes.error!.message}',
              recoverable: true,
            ),
          );
        }
        final lines = const LineSplitter()
            .convert(verifyRes.value!.stdout as String)
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList(growable: false);
        if (lines.isEmpty) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'JJ_TARGET_NOT_FOUND',
              message: 'Merge parent revision "$target" resolved to 0 commits.',
              recoverable: true,
            ),
          );
        }
        if (lines.length > 1) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'AMBIGUOUS_REVISION',
              message:
                  'Merge parent "$target" resolved to ${lines.length} commits.',
              recoverable: true,
            ),
          );
        }
        final resolved = lines.first;
        if (seenParents.add(resolved)) {
          resolvedParents.add(resolved);
        }
      }

      if (resolvedParents.length < 2) {
        return const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_MERGE_PARENTS',
            message:
                'sys_jj_merge requires at least 2 distinct parent Change IDs.',
            recoverable: true,
          ),
        );
      }

      final effectiveMessage =
          (message != null && message.trim().isNotEmpty)
              ? message.trim()
              : 'agent-os: merge worker changes';
      final newRes = await _runJjRaw(<String>[
        'new',
        ...resolvedParents,
        '-m',
        effectiveMessage,
      ]);
      if (!newRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(newRes.error!);
      }

      final conflictRes = await _inspectConflictsNonDestructiveLocked(
        rev: '@',
        namespaceOverride: namespaceOverride,
      );
      if (!conflictRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(conflictRes.error!);
      }
      final info = conflictRes.value!;
      final mergeChangeId = info['changeId'] as String;
      final mergeCommitId = info['commitId'] as String;
      final hasConflicts = info['hasConflicts'] == true;
      final files = (info['files'] as List<dynamic>).cast<String>();
      final opId = (info['opId'] as String?) ?? txContext.currentOpId ?? '';

      txContext.updateSnapshot(
        currentOpId: opId,
        workingChangeId: mergeChangeId,
      );
      txContext.pendingWorkerChangeIds.addAll(resolvedParents);

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'mergeChangeId': mergeChangeId,
        'mergeCommitId': mergeCommitId,
        'parentChangeIds': resolvedParents,
        'anchorWorkingChangeId': txContext.anchorWorkingChangeId,
        'hasConflicts': hasConflicts,
        'conflictedFiles': files,
        'jjOpId': opId,
      });
    });
  }

  /// Flattens a resolved merge (or worker) change onto the single-parent anchor
  /// working change `W_lead` (`sys_jj_integrate`) ([D-309]).
  Future<SyscallResult<Map<String, dynamic>>> integrateIntoWorkingChange({
    String sourceRev = '@',
    List<String>? abandonChangeIds,
    Set<String> protectedChangeIds = const <String>{},
    VfsNamespace? namespaceOverride,
  }) {
    final validation = _validateIntegrateArgs(<String, dynamic>{
      'sourceRev': sourceRev,
      'abandonChangeIds': ?abandonChangeIds,
    });
    if (validation != null) {
      return Future<SyscallResult<Map<String, dynamic>>>.value(
        SyscallResult<Map<String, dynamic>>.failure(validation),
      );
    }
    return _mutex.synchronized(
      () => _integrateIntoWorkingChangeLocked(
        sourceRev: sourceRev.trim(),
        abandonChangeIds: abandonChangeIds,
        protectedChangeIds: protectedChangeIds,
        namespaceOverride: namespaceOverride,
      ),
    );
  }

  Future<SyscallResult<Map<String, dynamic>>> _integrateIntoWorkingChangeLocked({
    String sourceRev = '@',
    List<String>? abandonChangeIds,
    Set<String> protectedChangeIds = const <String>{},
    VfsNamespace? namespaceOverride,
  }) async {
    if (txContext.state != TxState.active) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.econflict,
          reason: 'NO_ACTIVE_TRANSACTION',
          message:
              'Cannot integrate: no active isolated transaction (TxState != active).',
          recoverable: true,
        ),
      );
    }

    ensureAgentOsGitignoreSync(workspaceHostRoot);

    // Finalize main working copy snapshot prior to conflict check.
    final snapRes = await _runJjRaw(<String>[
      'op',
      'log',
      '--no-graph',
      '--limit',
      '1',
      '-T',
      'self.id()',
    ]);
    if (!snapRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(snapRes.error!);
    }

    final conflictRes = await _inspectConflictsNonDestructiveLocked(
      rev: sourceRev,
      namespaceOverride: namespaceOverride,
    );
    if (!conflictRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(conflictRes.error!);
    }
    final info = conflictRes.value!;
    final sourceChangeId = info['changeId'] as String;
    final hasConflicts = info['hasConflicts'] == true;
    final files = (info['files'] as List<dynamic>).cast<String>();
    if (hasConflicts) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.econflict,
          reason: 'UNRESOLVED_CONFLICTS',
          message:
              'Cannot integrate "$sourceRev": unresolved First-Class Conflicts remain.',
          recoverable: true,
          hint:
              'Inspect conflicted files via sys_jj_conflicts / sys_read_lines, resolve all conflict markers with sys_edit_block or a conflict_resolver worker, verify tests, then retry.',
          details: <String, dynamic>{
            'conflictedFiles': files,
            'workingChangeId': sourceChangeId,
          },
        ),
      );
    }

    final anchorId = txContext.anchorWorkingChangeId ?? txContext.workingChangeId;
    if (anchorId == null || anchorId.isEmpty) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.econflict,
          reason: 'NO_ANCHOR_WORKING_CHANGE',
          message: 'No single-parent anchor working change is recorded.',
          recoverable: false,
        ),
      );
    }

    if (sourceChangeId != anchorId) {
      final restoreRes = await _runJjRaw(<String>[
        'restore',
        '--from',
        sourceChangeId,
        '--into',
        anchorId,
      ]);
      if (!restoreRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(restoreRes.error!);
      }

      final editRes = await _runJjRaw(<String>[
        'edit',
        anchorId,
      ]);
      if (!editRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(editRes.error!);
      }
    }

    final candidateAbandon = <String>[
      ...(abandonChangeIds ?? txContext.pendingWorkerChangeIds),
      if (sourceChangeId != anchorId) sourceChangeId,
    ];
    final toAbandon = <String>[];
    final seenAbandon = <String>{};
    for (final raw in candidateAbandon) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('-')) {
        continue;
      }
      final resolveRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        trimmed,
        '--ignore-working-copy',
        '-T',
        'change_id.short(12)',
      ]);
      if (!resolveRes.ok) {
        continue;
      }
      final resolved = (resolveRes.value!.stdout as String).trim();
      if (resolved.isEmpty ||
          resolved == anchorId ||
          resolved == txContext.parentChangeId ||
          protectedChangeIds.contains(resolved)) {
        continue;
      }
      if (seenAbandon.add(resolved)) {
        toAbandon.add(resolved);
      }
    }

    if (toAbandon.isNotEmpty) {
      final abandonRes = await _runJjRaw(<String>[
        'abandon',
        ...toAbandon,
      ]);
      if (!abandonRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(abandonRes.error!);
      }
    }

    final opRes = await _runJjRaw(<String>[
      'op',
      'log',
      '--no-graph',
      '--limit',
      '1',
      '--ignore-working-copy',
      '-T',
      'self.id()',
    ]);
    if (!opRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(opRes.error!);
    }
    final newOpId = (opRes.value!.stdout as String).trim();

    txContext.anchorWorkingChangeId = anchorId;
    txContext.pendingWorkerChangeIds.clear();
    txContext.updateSnapshot(
      currentOpId: newOpId,
      workingChangeId: anchorId,
    );

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'integratedChangeId': anchorId,
      'abandonedChangeIds': toAbandon,
      'jjOpId': newOpId,
    });
  }

  /// Builds a strictly non-destructive Stage 4 approval preview for `sys_tx_squash` ([D-015], [D-020], [D-309], RV-001).
  ///
  /// Uses ONLY `--ignore-working-copy` commands against `baseRev` (`txContext.parentChangeId ?? '@-'`)
  /// so neither `op_id` nor `commit_id` advances and multi-parent merges produce complete Diff blocks.
  Future<ApprovalPreview?> buildSquashApprovalPreview(
    SyscallHookContext context,
  ) {
    return _mutex.synchronized(() async {
      if (txContext.state != TxState.active) {
        return null;
      }

      final baseRev = txContext.parentChangeId ?? '@-';
      final diffRes = await _runJjRaw(<String>[
        'diff',
        '--git',
        '--from',
        baseRev,
        '--to',
        '@',
        '--ignore-working-copy',
      ]);
      final gitDiff = diffRes.ok ? (diffRes.value!.stdout as String) : '';

      final summaryRes = await _runJjRaw(<String>[
        'diff',
        '--summary',
        '--from',
        baseRev,
        '--to',
        '@',
        '--ignore-working-copy',
      ]);
      final summaryText =
          summaryRes.ok ? (summaryRes.value!.stdout as String).trimRight() : '';
      final changedFiles = _parseDiffSummary(summaryText);

      final contentBlocks = <Map<String, dynamic>>[];
      const maxDetailedDiffFiles = 20;
      for (final entry in changedFiles.take(maxDetailedDiffFiles)) {
        final statusCode = entry['status'] ?? '';
        final rawPath = entry['path'] ?? '';
        if (rawPath.isEmpty) {
          continue;
        }
        final renamed = _parseSummaryRename(rawPath);
        final oldRel = renamed.oldPath;
        final newRel = renamed.newPath;

        String? oldText;
        String? newText;

        if (statusCode == 'A') {
          oldText = null;
          newText = await _readTextFileAtRevIgnoreWc('@', newRel);
          if (newText == null) {
            continue;
          }
        } else if (statusCode == 'D') {
          oldText = await _readTextFileAtRevIgnoreWc(baseRev, oldRel);
          newText = '';
          if (oldText == null) {
            continue;
          }
        } else {
          oldText = await _readTextFileAtRevIgnoreWc(baseRev, oldRel);
          newText = await _readTextFileAtRevIgnoreWc('@', newRel);
          if (newText == null) {
            continue;
          }
        }

        final displayRel = newRel.isNotEmpty ? newRel : oldRel;
        final hostAbsForward =
            p.join(workspaceHostRoot, displayRel).replaceAll('\\', '/');
        contentBlocks.add(<String, dynamic>{
          'type': 'diff',
          'path': hostAbsForward,
          'oldText': oldText,
          'newText': newText,
        });
      }

      if (gitDiff.trim().isNotEmpty) {
        contentBlocks.add(<String, dynamic>{
          'type': 'content',
          'content': <String, dynamic>{
            'type': 'text',
            'text': gitDiff,
          },
        });
      }

      return ApprovalPreview(
        title: 'Squash working change into @- (${changedFiles.length} files)',
        kind: 'edit',
        content: contentBlocks,
        metadata: <String, dynamic>{
          'changedFiles': changedFiles,
          'gitDiff': gitDiff,
          'workingChangeId': txContext.workingChangeId,
          'parentChangeId': txContext.parentChangeId,
          'ignoredWorkingCopy': true,
        },
      );
    });
  }

  /// Non-interactively squashes `@` into `@-` (`sys_tx_squash`) and resets to [TxState.readOnly] ([D-015], [D-309]).
  ///
  /// Always supplies `-m <message>` or `-u` (`--use-destination-message`) alongside
  /// non-interactive editor env vars so `jj squash` never blocks waiting for an editor.
  /// When `@` is a multi-parent merge (or diverges from `anchorWorkingChangeId`), automatically
  /// flattens onto the single-parent anchor change before squashing ([D-309] §4.2-2).
  Future<SyscallResult<Map<String, dynamic>>> txSquash({
    String? message,
  }) async {
    if (txContext.state != TxState.active) {
      return const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.econflict,
          reason: 'NO_ACTIVE_TRANSACTION',
          message:
              'Cannot squash: no active isolated transaction (TxState != active).',
          recoverable: true,
          hint:
              'Call sys_tx_begin or edit a file in /workspace before calling sys_tx_squash.',
        ),
      );
    }

    return _mutex.synchronized(() async {
      if (txContext.state != TxState.active) {
        return const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.econflict,
            reason: 'NO_ACTIVE_TRANSACTION',
            message:
                'Cannot squash: no active isolated transaction (TxState != active).',
            recoverable: true,
          ),
        );
      }

      ensureAgentOsGitignoreSync(workspaceHostRoot);

      // Finalize working-copy snapshot prior to conflict/parent check and squash.
      final snapRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '-T',
        'self.id()',
      ]);
      if (!snapRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(snapRes.error!);
      }

      // Check whether @ is multi-parent or diverges from anchorWorkingChangeId; flatten if so ([D-309]).
      final metaRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '--ignore-working-copy',
        '-T',
        r'change_id.short(12) ++ "\t" ++ parents.len() ++ "\n"',
      ]);
      if (metaRes.ok) {
        final parts = (metaRes.value!.stdout as String).trim().split('\t');
        final currentChangeId = parts.isNotEmpty ? parts[0].trim() : '';
        final parentCount =
            parts.length >= 2 ? (int.tryParse(parts[1].trim()) ?? 1) : 1;
        final anchorId = txContext.anchorWorkingChangeId;
        if (parentCount >= 2 ||
            (anchorId != null &&
                anchorId.isNotEmpty &&
                currentChangeId.isNotEmpty &&
                currentChangeId != anchorId)) {
          final flattenRes = await _integrateIntoWorkingChangeLocked(
            sourceRev: '@',
          );
          if (!flattenRes.ok) {
            return SyscallResult<Map<String, dynamic>>.failure(
              flattenRes.error!,
            );
          }
        }
      }

      final trimmedMessage = message?.trim();
      final effectiveMessage =
          (trimmedMessage != null && trimmedMessage.isNotEmpty)
              ? message!
              : null;

      final squashArgs = effectiveMessage != null
          ? <String>['squash', '-m', effectiveMessage]
          : <String>['squash', '-u'];

      final squashRes = await _runJjRaw(squashArgs);
      if (!squashRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(squashRes.error!);
      }

      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      if (!opRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(opRes.error!);
      }
      final newOpId = (opRes.value!.stdout as String).trim();

      final changeRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '--ignore-working-copy',
        '-T',
        'change_id.short(12)',
      ]);
      final newWorkingChangeId = changeRes.ok
          ? (changeRes.value!.stdout as String).trim()
          : txContext.workingChangeId;

      final previousBaseOpId = txContext.baseOpId;
      txContext.anchorWorkingChangeId = null;
      txContext.pendingWorkerChangeIds.clear();
      txContext.resetToReadOnly(
        currentOpId: newOpId.isEmpty ? null : newOpId,
        workingChangeId:
            (newWorkingChangeId == null || newWorkingChangeId.isEmpty)
                ? null
                : newWorkingChangeId,
      );

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'state': txContext.state.name,
        'squashed': true,
        'jjOpId': newOpId,
        'workingChangeId': txContext.workingChangeId,
        'previousBaseOpId': previousBaseOpId,
        'usedMessage': effectiveMessage,
        'usedDestinationMessage': effectiveMessage == null,
      });
    });
  }

  /// Restores the repository to a session-recorded checkpoint `op_id` (`sys_tx_rollback`) ([D-015]).
  ///
  /// Rejects malformed `targetOpId` with `EINVAL` and any `op_id` not recorded
  /// in the current session's checkpoint allowlist (or pre-session `op_id`) with
  /// `EACCES` (`INVALID_OR_PRE_SESSION_OP_ID`).
  Future<SyscallResult<Map<String, dynamic>>> txRollback({
    String? targetOpId,
  }) async {
    final opValidation = _validateOptionalAtOp(targetOpId);
    if (opValidation != null) {
      return SyscallResult<Map<String, dynamic>>.failure(opValidation);
    }

    return _mutex.synchronized(() async {
      final resolution = _resolveAllowedRollbackOpId(
        txContext,
        targetOpId: targetOpId,
      );
      if (!resolution.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(resolution.error!);
      }
      final resolvedOpId = resolution.value!;

      ensureAgentOsGitignoreSync(workspaceHostRoot);

      final restoreRes = await _runJjRaw(<String>[
        'op',
        'restore',
        resolvedOpId,
      ]);
      if (!restoreRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(restoreRes.error!);
      }

      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      if (!opRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(opRes.error!);
      }
      final newOpId = (opRes.value!.stdout as String).trim();

      final changeRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '--ignore-working-copy',
        '-T',
        'change_id.short(12)',
      ]);
      final restoredChangeId = changeRes.ok
          ? (changeRes.value!.stdout as String).trim()
          : null;

      txContext.anchorWorkingChangeId = null;
      txContext.pendingWorkerChangeIds.clear();
      txContext.resetToReadOnly(
        currentOpId: newOpId.isEmpty ? null : newOpId,
        workingChangeId:
            (restoredChangeId == null || restoredChangeId.isEmpty)
                ? null
                : restoredChangeId,
      );

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'state': txContext.state.name,
        'rolledBack': true,
        'restoredToOpId': resolvedOpId,
        'jjOpId': newOpId,
        'workingChangeId': txContext.workingChangeId,
      });
    });
  }

  /// Registers `sys_jj_status`, `sys_jj_log`, and `sys_jj_diff` on [gate].
  void registerReadSyscalls(SyscallGate gate) {
    for (final def in buildReadSyscallDefinitions()) {
      gate.registerSyscall(def);
    }
  }

  /// Registers `sys_tx_begin`, `sys_tx_describe`, `sys_tx_squash`, and `sys_tx_rollback` on [gate].
  void registerTxSyscalls(SyscallGate gate) {
    for (final def in buildTxSyscallDefinitions()) {
      gate.registerSyscall(def);
    }
  }

  /// Registers both Read-Only and CoW transaction Jujutsu syscalls on [gate].
  void registerAllSyscalls(SyscallGate gate) {
    registerReadSyscalls(gate);
    registerTxSyscalls(gate);
  }

  /// Builds all Read-Only and CoW transaction [SyscallDefinition] entries ([D-014], [D-015]).
  List<SyscallDefinition> buildAllSyscallDefinitions() {
    return <SyscallDefinition>[
      ...buildReadSyscallDefinitions(),
      ...buildTxSyscallDefinitions(),
    ];
  }

  /// Builds [SyscallDefinition] entries for CoW transaction syscalls ([D-002], [D-003], [D-015], [D-020]).
  List<SyscallDefinition> buildTxSyscallDefinitions() {
    return <SyscallDefinition>[
      SyscallDefinition(
        name: 'sys_tx_begin',
        requiredRight: CapRight.vcsTx,
        kind: 'edit',
        applyIoCap: false,
        validateArgs: _validateTxBeginArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => txBegin(
          description: exec.args['description'] as String?,
        ),
      ),
      SyscallDefinition(
        name: 'sys_tx_describe',
        requiredRight: CapRight.vcsTx,
        kind: 'edit',
        applyIoCap: false,
        validateArgs: _validateTxDescribeArgs,
        checkPreconditions: (pcb, _) async => _requireActiveTx(pcb),
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => txDescribe(
          message: exec.args['message'] as String,
        ),
      ),
      SyscallDefinition(
        name: 'sys_tx_squash',
        requiredRight: CapRight.vcsTx,
        kind: 'edit',
        applyIoCap: false,
        validateArgs: _validateTxSquashArgs,
        checkPreconditions: (pcb, _) async {
          final activeErr = _requireActiveTx(pcb);
          if (activeErr != null) {
            return activeErr;
          }
          final conflictRes = await inspectConflictsNonDestructive(rev: '@');
          if (!conflictRes.ok) {
            return conflictRes.error;
          }
          final info = conflictRes.value!;
          if (info['hasConflicts'] == true) {
            return SyscallError(
              code: SyscallErrorCode.econflict,
              reason: 'UNRESOLVED_CONFLICTS',
              message:
                  'Unresolved First-Class Conflicts remain in @. Resolve conflicts before calling sys_tx_squash.',
              recoverable: true,
              hint:
                  'Unresolved First-Class Conflicts remain in @. Inspect conflicted files via sys_jj_conflicts / sys_read_lines, resolve all <<<<<<< ... >>>>>>> markers with sys_edit_block or a conflict_resolver worker, verify tests, then retry sys_tx_squash.',
              details: <String, dynamic>{
                'conflictedFiles': info['files'],
                'workingChangeId': info['changeId'],
              },
            );
          }
          return null;
        },
        evaluatePolicy: (_, _) async => RingDecision.askUser,
        approvalPreviewBuilder: buildSquashApprovalPreview,
        handler: (exec) => txSquash(
          message: exec.args['message'] as String?,
        ),
      ),
      SyscallDefinition(
        name: 'sys_jj_merge',
        requiredRight: CapRight.vcsTx,
        kind: 'edit',
        applyIoCap: false,
        validateArgs: _validateMergeArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        resultSummaryBuilder: (_, result) {
          if (!result.ok || result.value == null) {
            return null;
          }
          final v = result.value!;
          final files = v['conflictedFiles'];
          return <String, dynamic>{
            'mergeChangeId': v['mergeChangeId'],
            'mergeCommitId': v['mergeCommitId'],
            'hasConflicts': v['hasConflicts'],
            'conflictedFilesCount': files is List ? files.length : 0,
          };
        },
        handler: (exec) {
          final rawIds = exec.args['changeIds'] as List<dynamic>;
          return mergeChanges(
            changeIds: rawIds.cast<String>(),
            message: exec.args['message'] as String?,
            namespaceOverride: exec.pcb.namespace,
          );
        },
      ),
      SyscallDefinition(
        name: 'sys_jj_integrate',
        requiredRight: CapRight.vcsTx,
        kind: 'edit',
        applyIoCap: false,
        validateArgs: _validateIntegrateArgs,
        checkPreconditions: (pcb, _) async => _requireActiveTx(pcb),
        evaluatePolicy: (_, _) async => RingDecision.allow,
        resultSummaryBuilder: (_, result) {
          if (!result.ok || result.value == null) {
            return null;
          }
          final v = result.value!;
          return <String, dynamic>{
            'targetChangeId': v['integratedChangeId'],
            'abandonedChangeIds': v['abandonedChangeIds'],
          };
        },
        handler: (exec) {
          final rawAbandon = exec.args['abandonChangeIds'] as List<dynamic>?;
          return integrateIntoWorkingChange(
            sourceRev: (exec.args['sourceRev'] as String?) ?? '@',
            abandonChangeIds: rawAbandon?.cast<String>(),
            namespaceOverride: exec.pcb.namespace,
          );
        },
      ),
      SyscallDefinition(
        name: 'sys_tx_rollback',
        requiredRight: CapRight.vcsTx,
        kind: 'edit',
        applyIoCap: false,
        validateArgs: _validateTxRollbackArgs,
        checkPreconditions: (pcb, args) async {
          final targetOpId = args['targetOpId'] as String?;
          final check = _resolveAllowedRollbackOpId(
            pcb.jjContext,
            targetOpId: targetOpId,
          );
          return check.ok ? null : check.error;
        },
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => txRollback(
          targetOpId: exec.args['targetOpId'] as String?,
        ),
      ),
    ];
  }

  /// Builds [SyscallDefinition] entries for Read-Only Jujutsu syscalls ([D-002], [D-006], [D-014], [D-204]).
  List<SyscallDefinition> buildReadSyscallDefinitions() {
    bool shouldForceIgnoreWc(ProcessControlBlock pcb) =>
        pcb.ring == ProtectionRing.ring3 ||
        (pcb.profile?.forcesVcsIgnoreWorkingCopy ?? false);

    return <SyscallDefinition>[
      SyscallDefinition(
        name: 'sys_jj_status',
        requiredRight: CapRight.vcsRead,
        kind: 'read',
        applyIoCap: true,
        cappedTextFields: const <String>['summary'],
        validateArgs: _validateStatusArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => status(
          atOp: exec.args['atOp'] as String?,
          forceIgnoreWorkingCopy: shouldForceIgnoreWc(exec.pcb),
          repositoryPath: exec.pcb.jjWorkspaceRoot,
        ),
      ),
      SyscallDefinition(
        name: 'sys_jj_log',
        requiredRight: CapRight.vcsRead,
        kind: 'read',
        applyIoCap: true,
        cappedTextFields: const <String>['commits'],
        validateArgs: _validateLogArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) => log(
          revset: exec.args['revset'] as String? ?? '::@ | @-',
          limit: exec.args['limit'] as int? ?? 20,
          atOp: exec.args['atOp'] as String?,
          forceIgnoreWorkingCopy: shouldForceIgnoreWc(exec.pcb),
          repositoryPath: exec.pcb.jjWorkspaceRoot,
        ),
      ),
      SyscallDefinition(
        name: 'sys_jj_diff',
        requiredRight: CapRight.vcsRead,
        kind: 'read',
        applyIoCap: true,
        cappedTextFields: const <String>['diff'],
        validateArgs: _validateDiffArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        handler: (exec) {
          final rawPaths = exec.args['paths'] as List<dynamic>?;
          return diff(
            rev: exec.args['rev'] as String? ?? '@',
            paths: rawPaths?.cast<String>(),
            atOp: exec.args['atOp'] as String?,
            forceIgnoreWorkingCopy: shouldForceIgnoreWc(exec.pcb),
            namespaceOverride: exec.pcb.namespace,
            repositoryPath: exec.pcb.jjWorkspaceRoot,
          );
        },
      ),
      SyscallDefinition(
        name: 'sys_jj_conflicts',
        requiredRight: CapRight.vcsRead,
        kind: 'read',
        applyIoCap: false,
        validateArgs: _validateConflictsArgs,
        evaluatePolicy: (_, _) async => RingDecision.allow,
        resultSummaryBuilder: (_, result) {
          if (!result.ok || result.value == null) {
            return null;
          }
          final v = result.value!;
          final files = v['files'];
          return <String, dynamic>{
            'rev': v['rev'],
            'hasConflicts': v['hasConflicts'],
            'filesCount': files is List ? files.length : 0,
          };
        },
        handler: (exec) => inspectConflictsNonDestructive(
          rev: (exec.args['rev'] as String?) ?? '@',
          namespaceOverride: exec.pcb.namespace,
          repositoryPath: exec.pcb.jjWorkspaceRoot,
        ),
      ),
    ];
  }

  /// Returns canonical tool schemas for all Read-Only and CoW transaction Jujutsu syscalls ([D-014], [D-015]).
  static List<SyscallToolSchema> allToolSchemas() {
    return <SyscallToolSchema>[
      ...readToolSchemas(),
      ...txToolSchemas(),
    ];
  }

  /// Returns canonical tool schemas for `sys_tx_begin`, `sys_tx_describe`, `sys_tx_squash`, and `sys_tx_rollback` ([D-007], [D-015]).
  static List<SyscallToolSchema> txToolSchemas() {
    return <SyscallToolSchema>[
      SyscallToolSchema(
        name: 'sys_tx_begin',
        description:
            'Snapshot the current working copy and split a fresh isolated child working change (@) so @- remains untouched.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'description': <String, dynamic>{
              'type': 'string',
              'description': 'Optional commit message for the isolated working change.',
            },
          },
        },
      ),
      SyscallToolSchema(
        name: 'sys_tx_describe',
        description:
            'Set or update the description of the currently active isolated working change (@). Requires an active transaction.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'message': <String, dynamic>{
              'type': 'string',
              'description': 'Non-empty commit description for the active working change.',
            },
          },
          'required': <String>['message'],
        },
      ),
      SyscallToolSchema(
        name: 'sys_tx_squash',
        description:
            'Squash the active working change (@) into its parent (@-) after explicit user approval.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'message': <String, dynamic>{
              'type': 'string',
              'description':
                  'Optional squash description. When omitted, preserves the parent (@-) description.',
            },
          },
        },
      ),
      SyscallToolSchema(
        name: 'sys_tx_rollback',
        description:
            'Restore the workspace to a session-recorded checkpoint operation ID (defaults to transaction baseOpId).',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'targetOpId': <String, dynamic>{
              'type': 'string',
              'description':
                  'Optional hexadecimal operation ID recorded during this session. Defaults to the session baseOpId.',
            },
          },
        },
      ),
      SyscallToolSchema(
        name: 'sys_jj_merge',
        description:
            'Create a multi-parent merge commit combining 2..16 completed worker Change IDs (`jj new c1 c2 ...`). Never aborts on First-Class Conflicts; returns `hasConflicts` and `conflictedFiles`.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'changeIds': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'minItems': 2,
              'maxItems': 16,
              'description':
                  'List of 2 to 16 distinct Jujutsu Change IDs or revisions to merge.',
            },
            'message': <String, dynamic>{
              'type': 'string',
              'description': 'Optional merge commit description.',
            },
          },
          'required': <String>['changeIds'],
        },
      ),
      SyscallToolSchema(
        name: 'sys_jj_integrate',
        description:
            'Flatten a conflict-free resolved merge or worker change into the single-parent anchor working change (`W_lead`) and abandon temporary worker/merge changes so `sys_tx_squash` can proceed.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'sourceRev': <String, dynamic>{
              'type': 'string',
              'description':
                  'Revision of the resolved merge or worker change to integrate (default "@").',
            },
            'abandonChangeIds': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description':
                  'Optional list of temporary worker/merge Change IDs to abandon after flattening.',
            },
          },
        },
      ),
    ];
  }

  /// Returns canonical tool schemas for `sys_jj_status`, `sys_jj_log`, `sys_jj_diff`, and `sys_jj_conflicts` ([D-007], [D-014], [D-310]).
  static List<SyscallToolSchema> readToolSchemas() {
    return <SyscallToolSchema>[
      SyscallToolSchema(
        name: 'sys_jj_status',
        description:
            'Inspect current Jujutsu working copy (@), parent (@-), changed files summary, and current opId without mutating the repository.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'atOp': <String, dynamic>{
              'type': 'string',
              'description': 'Optional historical operation ID to inspect.',
            },
          },
        },
      ),
      SyscallToolSchema(
        name: 'sys_jj_log',
        description:
            'List Jujutsu commits matching a revset with change_id, commit_id, parents, conflict, empty, and description.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'revset': <String, dynamic>{
              'type': 'string',
              'description': 'Jujutsu revset expression (default "::@ | @-").',
            },
            'limit': <String, dynamic>{
              'type': 'integer',
              'description': 'Maximum number of commits to return (default 20).',
            },
            'atOp': <String, dynamic>{
              'type': 'string',
              'description': 'Optional historical operation ID.',
            },
          },
        },
      ),
      SyscallToolSchema(
        name: 'sys_jj_diff',
        description:
            'Show unified Git-format diff for a Jujutsu revision (default @).',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'rev': <String, dynamic>{
              'type': 'string',
              'description': 'Revision or revset to diff (default "@").',
            },
            'paths': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description': 'Optional virtual paths under /workspace to filter diff.',
            },
            'atOp': <String, dynamic>{
              'type': 'string',
              'description': 'Optional historical operation ID.',
            },
          },
        },
      ),
      SyscallToolSchema(
        name: 'sys_jj_conflicts',
        description:
            'Non-destructively inspect First-Class Conflicts on a revision (default "@"). Always succeeds whether conflicts exist or not, returning `hasConflicts` and normalized `/workspace/...` `files`.',
        parametersJsonSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'rev': <String, dynamic>{
              'type': 'string',
              'description': 'Revision to inspect (default "@").',
            },
          },
        },
      ),
    ];
  }

  /// Reads a UTF-8 text file at [rev] using `--ignore-working-copy` (returns `null` if missing or binary).
  Future<String?> _readTextFileAtRevIgnoreWc(String rev, String relPath) async {
    final fullArgs = <String>[
      '--no-pager',
      'file',
      'show',
      '-r',
      rev,
      '--ignore-working-copy',
      relPath,
    ];
    try {
      final res = await Process.run(
        jjExecutable,
        fullArgs,
        workingDirectory: workspaceHostRoot,
        runInShell: false,
        environment: buildNonInteractiveEnvironment(),
        stdoutEncoding: null,
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      if (res.exitCode != 0) {
        return null;
      }
      final bytes = res.stdout as List<int>;
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] == 0) {
          return null;
        }
      }
      return utf8.decode(bytes, allowMalformed: false);
    } on Object {
      return null;
    }
  }

  /// Runs `jj --no-pager [-R <repositoryPath>] <args>` with `runInShell: false` and auto-retries once on stale workspace ([D-308]).
  Future<SyscallResult<ProcessResult>> _runJjWithAutoUpdateStale(
    List<String> args, {
    String? repositoryPath,
  }) async {
    final res = await _runJjRaw(args, repositoryPath: repositoryPath);
    if (!res.ok &&
        repositoryPath != null &&
        repositoryPath.trim().isNotEmpty &&
        JjWorkspaceOps.isStaleWorkingCopyError(res.error!.message)) {
      final updateRes = await _runJjRaw(
        JjWorkspaceOps.buildWorkspaceUpdateStaleArgs(),
        repositoryPath: repositoryPath,
      );
      if (updateRes.ok) {
        return _runJjRaw(args, repositoryPath: repositoryPath);
      }
    }
    return res;
  }

  /// Runs `jj --no-pager [-R <repositoryPath>] <args>` with `runInShell: false` and checks `exitCode == 0`.
  Future<SyscallResult<ProcessResult>> _runJjRaw(
    List<String> args, {
    String? repositoryPath,
  }) async {
    final fullArgs = <String>[
      '--no-pager',
      if (repositoryPath != null && repositoryPath.trim().isNotEmpty) ...<String>[
        '-R',
        p.normalize(p.absolute(repositoryPath)),
      ],
      ...args,
    ];
    final ProcessResult procResult;
    try {
      procResult = await Process.run(
        jjExecutable,
        fullArgs,
        workingDirectory: workspaceHostRoot,
        runInShell: false,
        environment: buildNonInteractiveEnvironment(),
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
    } on ProcessException catch (e) {
      return SyscallResult<ProcessResult>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'JJ_EXECUTABLE_ERROR',
          message: 'Failed to execute "$jjExecutable": ${e.message}',
          recoverable: false,
        ),
      );
    } on Object catch (e) {
      return SyscallResult<ProcessResult>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'JJ_PROCESS_ERROR',
          message: 'Unexpected error running "$jjExecutable": $e',
          recoverable: false,
        ),
      );
    }

    if (procResult.exitCode != 0) {
      return SyscallResult<ProcessResult>.failure(
        _mapNonZeroExit(
          args: fullArgs,
          exitCode: procResult.exitCode,
          stderrText: (procResult.stderr as String).trim(),
        ),
      );
    }

    return SyscallResult<ProcessResult>.success(procResult);
  }

  static SyscallError _mapNonZeroExit({
    required List<String> args,
    required int exitCode,
    required String stderrText,
  }) {
    final lower = stderrText.toLowerCase();
    if (lower.contains('there is no jj repo in')) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'NOT_A_JJ_REPO',
        message: stderrText,
        recoverable: false,
      );
    }
    if (lower.contains("doesn't exist") ||
        lower.contains('no such operation') ||
        lower.contains('failed to resolve') ||
        lower.contains('not found')) {
      return SyscallError(
        code: SyscallErrorCode.enoent,
        reason: 'JJ_TARGET_NOT_FOUND',
        message: stderrText.isEmpty
            ? 'jj ${args.join(' ')} exited with $exitCode.'
            : stderrText,
        recoverable: true,
      );
    }
    if (lower.contains('failed to parse') ||
        lower.contains('invalid') ||
        lower.contains('ambiguous')) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'JJ_INVALID_QUERY',
        message: stderrText.isEmpty
            ? 'jj ${args.join(' ')} failed with exit code $exitCode.'
            : stderrText,
        recoverable: true,
      );
    }
    return SyscallError(
      code: SyscallErrorCode.eio,
      reason: 'JJ_COMMAND_FAILED',
      message: stderrText.isEmpty
          ? 'jj ${args.join(' ')} exited with code $exitCode.'
          : stderrText,
      recoverable: true,
    );
  }

  static SyscallError? _validateOptionalAtOp(String? atOp) {
    if (atOp == null) {
      return null;
    }
    final trimmed = atOp.trim();
    if (trimmed.isEmpty || !_opIdPattern.hasMatch(trimmed)) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_OP_ID',
        message: 'Argument "atOp" ("$atOp") must be a hexadecimal operation ID.',
        recoverable: true,
      );
    }
    return null;
  }

  static SyscallError? _validateStatusArgs(Map<String, dynamic> args) {
    final atOp = args['atOp'];
    if (atOp != null && atOp is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "atOp" must be a string.',
        recoverable: true,
      );
    }
    return _validateOptionalAtOp(atOp as String?);
  }

  static SyscallError? _validateLogArgs(Map<String, dynamic> args) {
    final revset = args['revset'];
    if (revset != null && (revset is! String || revset.trim().isEmpty)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "revset" must be a non-empty string.',
        recoverable: true,
      );
    }
    final limit = args['limit'];
    if (limit != null && (limit is! int || limit < 1 || limit > 500)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "limit" must be an integer between 1 and 500.',
        recoverable: true,
      );
    }
    final atOp = args['atOp'];
    if (atOp != null && atOp is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "atOp" must be a string.',
        recoverable: true,
      );
    }
    return _validateOptionalAtOp(atOp as String?);
  }

  static SyscallError? _validateDiffArgs(Map<String, dynamic> args) {
    final rev = args['rev'];
    if (rev != null && (rev is! String || rev.trim().isEmpty)) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "rev" must be a non-empty string.',
        recoverable: true,
      );
    }
    final paths = args['paths'];
    if (paths != null) {
      if (paths is! List<dynamic> || paths.any((e) => e is! String)) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message: 'Argument "paths" must be a list of strings.',
          recoverable: true,
        );
      }
    }
    final atOp = args['atOp'];
    if (atOp != null && atOp is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "atOp" must be a string.',
        recoverable: true,
      );
    }
    return _validateOptionalAtOp(atOp as String?);
  }

  static SyscallError? _validateTxBeginArgs(Map<String, dynamic> args) {
    final description = args['description'];
    if (description != null && description is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "description" must be a string.',
        recoverable: true,
      );
    }
    return null;
  }

  static SyscallError? _validateTxDescribeArgs(Map<String, dynamic> args) {
    final message = args['message'];
    if (message is! String || message.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "message" must be a non-empty string.',
        recoverable: true,
      );
    }
    return null;
  }

  static SyscallError? _validateTxSquashArgs(Map<String, dynamic> args) {
    final message = args['message'];
    if (message != null && message is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "message" must be a string.',
        recoverable: true,
      );
    }
    return null;
  }

  static SyscallError? _validateTxRollbackArgs(Map<String, dynamic> args) {
    final targetOpId = args['targetOpId'];
    if (targetOpId != null && targetOpId is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "targetOpId" must be a string.',
        recoverable: true,
      );
    }
    if (targetOpId != null) {
      final trimmed = (targetOpId as String).trim();
      if (trimmed.isEmpty || !_opIdPattern.hasMatch(trimmed)) {
        return SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_OP_ID',
          message:
              'Argument "targetOpId" ("$targetOpId") must be a hexadecimal operation ID.',
          recoverable: true,
        );
      }
    }
    return null;
  }

  static SyscallError? _validateMergeArgs(Map<String, dynamic> args) {
    final rawIds = args['changeIds'];
    if (rawIds is! List<dynamic>) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_MERGE_PARENTS',
        message: 'Argument "changeIds" must be a list of 2 to 16 revision strings.',
        recoverable: true,
      );
    }
    if (rawIds.length < 2 || rawIds.length > 16) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_MERGE_PARENTS',
        message: 'Argument "changeIds" must contain between 2 and 16 Change IDs.',
        recoverable: true,
      );
    }
    final distinct = <String>{};
    for (final item in rawIds) {
      if (item is! String) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_MERGE_PARENTS',
          message: 'Each element of "changeIds" must be a string.',
          recoverable: true,
        );
      }
      final trimmed = item.trim();
      if (trimmed.isEmpty || trimmed.startsWith('-')) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_MERGE_PARENTS',
          message:
              'Each Change ID in "changeIds" must be non-empty and must not start with "-".',
          recoverable: true,
        );
      }
      distinct.add(trimmed);
    }
    if (distinct.length < 2) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_MERGE_PARENTS',
        message: 'Argument "changeIds" must contain at least 2 distinct Change IDs.',
        recoverable: true,
      );
    }
    final message = args['message'];
    if (message != null && message is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Argument "message" must be a string.',
        recoverable: true,
      );
    }
    return null;
  }

  static SyscallError? _validateConflictsArgs(Map<String, dynamic> args) {
    final rev = args['rev'];
    if (rev != null) {
      if (rev is! String || rev.trim().isEmpty || rev.trim().startsWith('-')) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message:
              'Argument "rev" must be a non-empty string not starting with "-".',
          recoverable: true,
        );
      }
    }
    return null;
  }

  static SyscallError? _validateIntegrateArgs(Map<String, dynamic> args) {
    final sourceRev = args['sourceRev'];
    if (sourceRev != null) {
      if (sourceRev is! String ||
          sourceRev.trim().isEmpty ||
          sourceRev.trim().startsWith('-')) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message:
              'Argument "sourceRev" must be a non-empty string not starting with "-".',
          recoverable: true,
        );
      }
    }
    final abandonIds = args['abandonChangeIds'];
    if (abandonIds != null) {
      if (abandonIds is! List<dynamic>) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_ARGS',
          message: 'Argument "abandonChangeIds" must be a list of strings.',
          recoverable: true,
        );
      }
      for (final item in abandonIds) {
        if (item is! String ||
            item.trim().isEmpty ||
            item.trim().startsWith('-')) {
          return const SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_ARGS',
            message:
                'Each element of "abandonChangeIds" must be a non-empty string not starting with "-".',
            recoverable: true,
          );
        }
      }
    }
    return null;
  }

  static SyscallError? _requireActiveTx(ProcessControlBlock pcb) {
    if (pcb.jjContext.state != TxState.active) {
      return const SyscallError(
        code: SyscallErrorCode.econflict,
        reason: 'NO_ACTIVE_TRANSACTION',
        message:
            'No active isolated working-change transaction (TxState != active). Call sys_tx_begin or edit a file first.',
        recoverable: true,
        hint: 'Call sys_tx_begin before calling sys_tx_describe or sys_tx_squash.',
      );
    }
    return null;
  }

  static SyscallResult<String> _resolveAllowedRollbackOpId(
    JjTxContext txCtx, {
    String? targetOpId,
  }) {
    if (targetOpId == null) {
      final base = txCtx.baseOpId;
      if (base == null ||
          base.isEmpty ||
          !txCtx.allowedCheckpointOpIds.contains(base)) {
        return const SyscallResult<String>.failure(
          SyscallError(
            code: SyscallErrorCode.eacces,
            reason: 'INVALID_OR_PRE_SESSION_OP_ID',
            message:
                'No session checkpoint op_id has been recorded yet; rollback is denied.',
            recoverable: true,
            hint: 'Start a transaction or perform an edit before rolling back.',
          ),
        );
      }
      return SyscallResult<String>.success(base);
    }

    final normalized = targetOpId.trim().toLowerCase();
    for (final allowed in txCtx.allowedCheckpointOpIds) {
      if (allowed.toLowerCase() == normalized) {
        return SyscallResult<String>.success(allowed);
      }
    }
    if (normalized.length >= 12) {
      final prefixMatches = txCtx.allowedCheckpointOpIds
          .where((id) => id.toLowerCase().startsWith(normalized))
          .toList(growable: false);
      if (prefixMatches.length == 1) {
        return SyscallResult<String>.success(prefixMatches.first);
      }
    }

    return SyscallResult<String>.failure(
      SyscallError(
        code: SyscallErrorCode.eacces,
        reason: 'INVALID_OR_PRE_SESSION_OP_ID',
        message:
            'Operation ID "$targetOpId" is not a checkpoint recorded during this session and cannot be restored.',
        recoverable: true,
        hint:
            'Omit targetOpId to restore to the session baseOpId, or pass an op_id recorded in this session.',
      ),
    );
  }

  static ({String oldPath, String newPath}) _parseSummaryRename(String raw) {
    final arrowIdx = raw.indexOf(' => ');
    if (arrowIdx < 0) {
      return (oldPath: raw, newPath: raw);
    }
    final openBrace = raw.indexOf('{');
    final closeBrace = raw.indexOf('}', arrowIdx);
    if (openBrace >= 0 && openBrace < arrowIdx && closeBrace > arrowIdx) {
      final prefix = raw.substring(0, openBrace);
      final suffix = raw.substring(closeBrace + 1);
      final inner = raw.substring(openBrace + 1, closeBrace);
      final parts = inner.split(' => ');
      if (parts.length == 2) {
        return (
          oldPath: '$prefix${parts[0]}$suffix',
          newPath: '$prefix${parts[1]}$suffix',
        );
      }
    }
    final oldPart = raw.substring(0, arrowIdx).trim();
    final newPart = raw.substring(arrowIdx + 4).trim();
    return (oldPath: oldPart, newPath: newPart);
  }

  static SyscallResult<List<Map<String, dynamic>>> _parseJsonLines(
    String rawStdout,
  ) {
    final commits = <Map<String, dynamic>>[];
    if (rawStdout.trim().isEmpty) {
      return SyscallResult<List<Map<String, dynamic>>>.success(commits);
    }

    for (final line in const LineSplitter().convert(rawStdout)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map<String, dynamic>) {
          return const SyscallResult<List<Map<String, dynamic>>>.failure(
            SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'JJ_JSON_PARSE_ERROR',
              message: 'Expected JSON object line from jj template output.',
              recoverable: false,
            ),
          );
        }
        commits.add(decoded);
      } on FormatException catch (e) {
        return SyscallResult<List<Map<String, dynamic>>>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'JJ_JSON_PARSE_ERROR',
            message: 'Failed to parse jj JSON Lines output: ${e.message}',
            recoverable: false,
          ),
        );
      }
    }
    return SyscallResult<List<Map<String, dynamic>>>.success(commits);
  }

  static List<Map<String, String>> _parseDiffSummary(String summaryText) {
    if (summaryText.trim().isEmpty) {
      return const <Map<String, String>>[];
    }
    final files = <Map<String, String>>[];
    for (final line in const LineSplitter().convert(summaryText)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final spaceIdx = trimmed.indexOf(RegExp(r'\s+'));
      if (spaceIdx <= 0) {
        files.add(<String, String>{'status': '?', 'path': trimmed});
      } else {
        files.add(<String, String>{
          'status': trimmed.substring(0, spaceIdx),
          'path': trimmed.substring(spaceIdx).trim(),
        });
      }
    }
    return files;
  }
}
