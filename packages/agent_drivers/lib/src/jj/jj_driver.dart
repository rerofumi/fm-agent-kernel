import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

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
  }) : txContext = txContext ?? JjTxContext();

  factory JjDriver.forWorkspace(
    String workspaceHostRoot, {
    JjTxContext? txContext,
    String jjExecutable = 'jj',
  }) {
    return JjDriver(
      namespace: VfsNamespace(workspaceHostRoot: workspaceHostRoot),
      txContext: txContext,
      jjExecutable: jjExecutable,
    );
  }

  final VfsNamespace namespace;
  final JjTxContext txContext;
  final String jjExecutable;
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
  Future<String?> getCurrentCommitIdNonDestructive() {
    return _mutex.synchronized(_readCurrentCommitIdLocked);
  }

  Future<String?> _readCurrentCommitIdLocked({String? atOp}) async {
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
    ]);
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

      final opRes = await _runJjRaw(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        ...baseFlags,
        '-T',
        'self.id()',
      ]);
      if (!opRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(opRes.error!);
      }
      final opId = (opRes.value!.stdout as String).trim();

      final wcRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        ...baseFlags,
        '-T',
        commitJsonTemplate,
      ]);
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
      final parentRes = await _runJjRaw(<String>[
        'log',
        '--no-graph',
        '-r',
        '@-',
        ...baseFlags,
        '-T',
        commitJsonTemplate,
      ]);
      if (parentRes.ok) {
        final parentParsed = _parseJsonLines(parentRes.value!.stdout as String);
        if (parentParsed.ok && parentParsed.value!.isNotEmpty) {
          parentCommit = parentParsed.value!.first;
        }
      }

      final diffRes = await _runJjRaw(<String>[
        'diff',
        '--summary',
        '-r',
        '@',
        ...baseFlags,
      ]);
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

      final res = await _runJjRaw(args);
      if (!res.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(res.error!);
      }

      final parsed = _parseJsonLines(res.value!.stdout as String);
      if (!parsed.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(parsed.error!);
      }

      final commits = parsed.value!;
      final commitId = await _readCurrentCommitIdLocked(atOp: atOp);
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

      final res = await _runJjRaw(args);
      if (!res.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(res.error!);
      }

      final commitId = await _readCurrentCommitIdLocked(atOp: atOp);
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
    return _mutex.synchronized(() async {
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

      return SyscallResult<({JjTxContext context, bool alreadyActive})>.success(
        (context: txContext, alreadyActive: false),
      );
    });
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

  /// Builds a strictly non-destructive Stage 4 approval preview for `sys_tx_squash` ([D-015], [D-020], RV-001).
  ///
  /// Uses ONLY `--ignore-working-copy` commands so neither `op_id` nor `commit_id`
  /// advances during approval prompting or upon user rejection.
  Future<ApprovalPreview?> buildSquashApprovalPreview(
    SyscallHookContext context,
  ) {
    return _mutex.synchronized(() async {
      if (txContext.state != TxState.active) {
        return null;
      }

      final diffRes = await _runJjRaw(<String>[
        'diff',
        '--git',
        '-r',
        '@',
        '--ignore-working-copy',
      ]);
      final gitDiff = diffRes.ok ? (diffRes.value!.stdout as String) : '';

      final summaryRes = await _runJjRaw(<String>[
        'diff',
        '--summary',
        '-r',
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
          oldText = await _readTextFileAtRevIgnoreWc('@-', oldRel);
          newText = '';
          if (oldText == null) {
            continue;
          }
        } else {
          oldText = await _readTextFileAtRevIgnoreWc('@-', oldRel);
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

  /// Non-interactively squashes `@` into `@-` (`sys_tx_squash`) and resets to [TxState.readOnly] ([D-015]).
  ///
  /// Always supplies `-m <message>` or `-u` (`--use-destination-message`) alongside
  /// non-interactive editor env vars so `jj squash` never blocks waiting for an editor.
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

      // Finalize working-copy snapshot prior to non-interactive squash.
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
        checkPreconditions: (pcb, _) async => _requireActiveTx(pcb),
        evaluatePolicy: (_, _) async => RingDecision.askUser,
        approvalPreviewBuilder: buildSquashApprovalPreview,
        handler: (exec) => txSquash(
          message: exec.args['message'] as String?,
        ),
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
          );
        },
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
    ];
  }

  /// Returns canonical tool schemas for `sys_jj_status`, `sys_jj_log`, and `sys_jj_diff` ([D-007], [D-014]).
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

  /// Runs `jj --no-pager <args>` with `runInShell: false` and checks `exitCode == 0`.
  Future<SyscallResult<ProcessResult>> _runJjRaw(List<String> args) async {
    final fullArgs = <String>['--no-pager', ...args];
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
