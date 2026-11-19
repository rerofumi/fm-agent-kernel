import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';

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

  String get workspaceHostRoot => namespace.workspaceHostRoot;

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
  }) {
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

  /// Reads `@`, `@-`, changed files summary, and current `opId` (`sys_jj_status`) ([D-014]).
  Future<SyscallResult<Map<String, dynamic>>> status({String? atOp}) async {
    final opValidation = _validateOptionalAtOp(atOp);
    if (opValidation != null) {
      return SyscallResult<Map<String, dynamic>>.failure(opValidation);
    }

    return _mutex.synchronized(() async {
      final ignoreWc = shouldIgnoreWorkingCopy(rev: '@', atOp: atOp);
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

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'opId': opId,
        'workingCopy': workingCopy,
        'parent': parentCommit,
        'changedFiles': changedFiles,
        'summary': summaryText,
        'txState': txContext.state.name,
        'ignoredWorkingCopy': ignoreWc,
      });
    });
  }

  /// Reads commit history matching [revset] using the custom JSON Lines `-T` template (`sys_jj_log`) ([D-014]).
  Future<SyscallResult<Map<String, dynamic>>> log({
    String revset = '::@ | @-',
    int limit = 20,
    String? atOp,
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
      final ignoreWc = shouldIgnoreWorkingCopy(revset: trimmedRevset, atOp: atOp);
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
      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'revset': trimmedRevset,
        'limit': limit,
        'commits': commits,
        'count': commits.length,
        'ignoredWorkingCopy': ignoreWc,
      });
    });
  }

  /// Reads unified Git-format diff for [rev] (`sys_jj_diff`) ([D-014]).
  Future<SyscallResult<Map<String, dynamic>>> diff({
    String rev = '@',
    List<String>? paths,
    String? atOp,
  }) async {
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
        final vfsRes = namespace.resolveVirtualPath(
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
      final ignoreWc = shouldIgnoreWorkingCopy(rev: trimmedRev, atOp: atOp);
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

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'rev': trimmedRev,
        'diff': res.value!.stdout as String,
        'ignoredWorkingCopy': ignoreWc,
      });
    });
  }

  /// Registers `sys_jj_status`, `sys_jj_log`, and `sys_jj_diff` on [gate].
  void registerReadSyscalls(SyscallGate gate) {
    for (final def in buildReadSyscallDefinitions()) {
      gate.registerSyscall(def);
    }
  }

  /// Builds [SyscallDefinition] entries for Read-Only Jujutsu syscalls ([D-002], [D-006], [D-014]).
  List<SyscallDefinition> buildReadSyscallDefinitions() {
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
          );
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
