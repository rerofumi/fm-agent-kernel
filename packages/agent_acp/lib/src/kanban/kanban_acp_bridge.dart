import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../wire/wire_command_splitter.dart';
import '../wire/wire_json_rpc_peer.dart';
import '../wire/wire_redactor.dart';

/// A queued `session/prompt` execution item in [KanbanAcpBridge]'s FIFO queue ([D-323] §4.3).
class KanbanQueuedRun {
  KanbanQueuedRun({
    required this.taskId,
    required this.prompt,
    this.model,
    this.executionMode = 'single',
    DateTime? queuedAt,
  }) : queuedAt = queuedAt ?? DateTime.now().toUtc();

  final String taskId;
  final String prompt;
  final String? model;
  final String executionMode;
  final DateTime queuedAt;
  final Completer<Map<String, dynamic>> completer =
      Completer<Map<String, dynamic>>();

  Map<String, dynamic> toJson(int queuePosition) {
    return <String, dynamic>{
      'taskId': taskId,
      'prompt': prompt,
      'model': ?model,
      'executionMode': executionMode,
      'queuedAt': queuedAt.toIso8601String(),
      'queuePosition': queuePosition,
    };
  }
}

/// Pending `session/request_permission` prompt awaiting user decision in the Kanban UI ([D-709]).
class KanbanPendingPermission {
  KanbanPendingPermission({
    required this.requestId,
    required this.sessionId,
    required this.toolCall,
    required this.options,
    this.taskId,
    this.daemonRequestId,
    this.toolCallId,
    this.approvalMeta,
  }) : completer = Completer<Map<String, dynamic>>();

  final String requestId;
  final String sessionId;
  final Map<String, dynamic> toolCall;
  final List<Map<String, dynamic>> options;
  final String? taskId;
  final String? daemonRequestId;
  final String? toolCallId;
  final Map<String, dynamic>? approvalMeta;
  final Completer<Map<String, dynamic>> completer;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'requestId': requestId,
      'sessionId': sessionId,
      if (taskId != null) 'taskId': taskId,
      'toolCall': toolCall,
      'options': options,
      'approvalMeta': ?approvalMeta,
    };
  }
}

/// Pure-wire ACP v1 `stdio` bridge connecting `acp_kanban_app` to `agent_os_daemon`
/// without importing any engine packages ([D-320], [D-322], [D-323]).
class KanbanAcpBridge {
  KanbanAcpBridge._({
    required Process? daemonProcess,
    required WireJsonRpcPeer peer,
    required this.cwd,
    required this.redactor,
    this.permissionPolicy = 'interactive',
    this.mcpServers = const <WireMcpServerSpec>[],
    this.maxContextTokens,
    void Function(String line)? onDaemonStderr,
  })  : _daemonProcess = daemonProcess,
        _peer = peer {
    _peer.onRequest = _handleIncomingRequest;
    _peer.onNotification = _handleIncomingNotification;
    if (daemonProcess != null) {
      _stderrSub = daemonProcess.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        final safe = redactor.redactString(line);
        onDaemonStderr?.call(safe);
      });
      daemonProcess.exitCode.then((code) {
        if (!_unexpectedExitCompleter.isCompleted) {
          _unexpectedExitCompleter.complete(code);
        }
      });
    }
  }

  /// Spawns `agent_os_daemon` via `Process.start(..., runInShell: false)` and attaches [WireJsonRpcPeer].
  static Future<KanbanAcpBridge> spawn({
    required String executable,
    required List<String> arguments,
    required String cwd,
    Map<String, String>? environment,
    WireSecretRedactor? redactor,
    String permissionPolicy = 'interactive',
    List<WireMcpServerSpec> mcpServers = const <WireMcpServerSpec>[],
    int? maxContextTokens,
    void Function(String line)? onDaemonStderr,
  }) async {
    final effectiveRedactor = redactor ?? WireSecretRedactor()
      ..registerFromEnvironment(Platform.environment);
    if (environment != null) {
      effectiveRedactor.registerFromEnvironment(environment);
    }
    for (final mcp in mcpServers) {
      for (final envVar in mcp.env) {
        effectiveRedactor.registerSecret(envVar.value);
      }
    }

    final proc = await Process.start(
      executable,
      arguments,
      workingDirectory: cwd,
      runInShell: false,
      environment: environment,
    );

    final peer = WireJsonRpcPeer(
      input: proc.stdout,
      output: proc.stdin,
      redactor: effectiveRedactor,
    );

    return KanbanAcpBridge._(
      daemonProcess: proc,
      peer: peer,
      cwd: cwd,
      redactor: effectiveRedactor,
      permissionPolicy: permissionPolicy,
      mcpServers: mcpServers,
      maxContextTokens: maxContextTokens,
      onDaemonStderr: onDaemonStderr,
    );
  }

  final Process? _daemonProcess;
  final WireJsonRpcPeer _peer;
  final String cwd;
  final WireSecretRedactor redactor;
  final String permissionPolicy;
  final List<WireMcpServerSpec> mcpServers;
  final int? maxContextTokens;

  StreamSubscription<String>? _stderrSub;
  final Completer<int> _unexpectedExitCompleter = Completer<int>();
  final StreamController<Map<String, dynamic>> _eventsController =
      StreamController<Map<String, dynamic>>.broadcast();

  String? _sessionId;
  String? _currentModel;
  List<Map<String, dynamic>> _availableModels = <Map<String, dynamic>>[];
  String? _jjChangeId;
  String? _jjOpId;
  int _swappedDirtyPagesTotal = 0;

  final Queue<KanbanQueuedRun> _queuedRuns = Queue<KanbanQueuedRun>();
  KanbanQueuedRun? _activeRun;
  bool _drainingQueue = false;
  bool _disposed = false;

  int _permSeq = 0;
  final Map<String, KanbanPendingPermission> _pendingPermissions =
      <String, KanbanPendingPermission>{};

  String? get sessionId => _sessionId;
  bool get isDisposed => _disposed;
  bool get hasActiveRun => _activeRun != null;
  int get queuedRunCount => _queuedRuns.length;

  /// Broadcast stream of UI-facing events (`session_update`, `permission_requested`, `queue_changed`).
  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  /// Completes if the child daemon process exits.
  Future<int> get daemonExitCode => _unexpectedExitCompleter.future;

  /// Performs ACP `initialize` and `session/new` handshake.
  Future<void> connect() async {
    await _peer.sendRequest('initialize', <String, dynamic>{
      'protocolVersion': 1,
      'clientInfo': <String, dynamic>{
        'name': 'acp_kanban_app',
        'version': '0.1.0',
      },
      'capabilities': <String, dynamic>{
        'fs': <String, dynamic>{'readTextFile': true, 'writeTextFile': true},
      },
    });

    final meta = <String, dynamic>{
      if (maxContextTokens != null)
        'fm_agent_os/maxContextTokens': maxContextTokens,
    };

    final rawSession = await _peer.sendRequest('session/new', <String, dynamic>{
      'cwd': cwd,
      'mcpServers': mcpServers.map((s) => s.toJson()).toList(growable: false),
      if (meta.isNotEmpty) '_meta': meta,
    });

    if (rawSession is Map) {
      final sessionMap = Map<String, dynamic>.from(rawSession);
      _sessionId = sessionMap['sessionId'] as String?;
      _applyConfigOptions(sessionMap['configOptions']);
    }

    if (_sessionId == null || _sessionId!.isEmpty) {
      throw const WireJsonRpcException(
        WireJsonRpcErrorCodes.internalError,
        'Daemon session/new did not return a valid sessionId.',
      );
    }
  }

  /// Fetches current Kanban state (`session`, `cards`, `processes`, `pendingPermissions`, `queuedRuns`).
  Future<Map<String, dynamic>> getState() async {
    final sid = _requireSessionId();
    List<Map<String, dynamic>> cards = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> processes = <Map<String, dynamic>>[];

    try {
      final rawStack = await _peer.sendRequest(
        '_fm_agent_os/stack_list',
        <String, dynamic>{'sessionId': sid},
      );
      if (rawStack is Map && rawStack['tasks'] is List) {
        cards = (rawStack['tasks'] as List)
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
      } else if (rawStack is List) {
        cards = rawStack
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
      }
    } on WireJsonRpcException catch (e) {
      if (e.code != WireJsonRpcErrorCodes.methodNotFound) {
        rethrow;
      }
    }

    try {
      final rawProcs = await _peer.sendRequest(
        '_fm_agent_os/processes',
        <String, dynamic>{'sessionId': sid},
      );
      if (rawProcs is Map) {
        if (rawProcs['lead'] is Map) {
          final lead = Map<String, dynamic>.from(rawProcs['lead'] as Map);
          _jjChangeId = (lead['jjChangeId'] as String?) ?? _jjChangeId;
          _jjOpId = (lead['jjOpId'] as String?) ?? _jjOpId;
        }
        if (rawProcs['processes'] is List) {
          processes = (rawProcs['processes'] as List)
              .whereType<Map<dynamic, dynamic>>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList(growable: false);
        }
      }
    } on WireJsonRpcException catch (e) {
      if (e.code != WireJsonRpcErrorCodes.methodNotFound) {
        rethrow;
      }
    }

    final queuedMap = <String, int>{};
    var pos = 1;
    for (final item in _queuedRuns) {
      queuedMap[item.taskId] = pos++;
    }

    final enrichedCards = cards.map((c) {
      final taskId = c['taskId'] as String? ?? '';
      final qPos = queuedMap[taskId];
      if (qPos != null) {
        return <String, dynamic>{
          ...c,
          'queued': true,
          'queuePosition': qPos,
        };
      }
      return c;
    }).toList(growable: false);

    return <String, dynamic>{
      'type': 'snapshot',
      'session': <String, dynamic>{
        'sessionId': sid,
        'cwd': cwd,
        'currentModel': _currentModel,
        'availableModels': _availableModels,
        'jjChangeId': _jjChangeId,
        'jjOpId': _jjOpId,
        'swappedDirtyPagesTotal': _swappedDirtyPagesTotal,
        'activeTaskId': _activeRun?.taskId,
      },
      'cards': enrichedCards,
      'processes': processes,
      'queuedRuns': _queuedRuns
          .toList(growable: false)
          .asMap()
          .entries
          .map((e) => e.value.toJson(e.key + 1))
          .toList(growable: false),
      'pendingPermissions': _pendingPermissions.values
          .map((p) => p.toJson())
          .toList(growable: false),
    };
  }

  /// Creates a Kanban card via `_fm_agent_os/stack_create` and optionally enqueues execution.
  Future<Map<String, dynamic>> createCard({
    String? taskId,
    required String title,
    String? description,
    String? parentTaskId,
    String? baseChangeId,
    String? model,
    String executionMode = 'single',
    bool autoStart = false,
    String? prompt,
  }) async {
    final sid = _requireSessionId();
    final raw = await _peer.sendRequest(
      '_fm_agent_os/stack_create',
      <String, dynamic>{
        'sessionId': sid,
        if (taskId != null && taskId.isNotEmpty) 'taskId': taskId,
        'title': title,
        'description': ?description,
        if (parentTaskId != null && parentTaskId.isNotEmpty)
          'parentTaskId': parentTaskId,
        if (baseChangeId != null && baseChangeId.isNotEmpty)
          'baseChangeId': baseChangeId,
        if (model != null && model.isNotEmpty) 'model': model,
      },
    );

    final result = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'task': raw};
    final createdTask = result['task'] is Map
        ? Map<String, dynamic>.from(result['task'] as Map)
        : result;
    final createdId =
        (createdTask['taskId'] as String?) ?? taskId ?? '';

    if (autoStart && createdId.isNotEmpty) {
      final runFuture = enqueueRun(
        taskId: createdId,
        prompt: (prompt != null && prompt.trim().isNotEmpty)
            ? prompt.trim()
            : (description != null && description.trim().isNotEmpty
                ? description.trim()
                : title),
        model: model,
        executionMode: executionMode,
      );
      unawaited(runFuture.catchError((_) => <String, dynamic>{}));
    }

    _emitEvent(<String, dynamic>{'type': 'card_created', 'taskId': createdId});
    return result;
  }

  /// Enqueues a card prompt into the FIFO queue so concurrent `session/prompt` (-32000)
  /// is never sent to the daemon ([D-323] §4.3).
  Future<Map<String, dynamic>> enqueueRun({
    required String taskId,
    String? prompt,
    String? model,
    String executionMode = 'single',
  }) {
    _requireSessionId();
    if (_disposed) {
      return Future<Map<String, dynamic>>.error(
        const WireJsonRpcPeerClosedException(),
      );
    }

    final item = KanbanQueuedRun(
      taskId: taskId,
      prompt: (prompt != null && prompt.trim().isNotEmpty)
          ? prompt.trim()
          : 'Execute task $taskId',
      model: model,
      executionMode: executionMode,
    );
    _queuedRuns.addLast(item);
    _emitEvent(<String, dynamic>{
      'type': 'queue_changed',
      'taskId': taskId,
      'queuedCount': _queuedRuns.length,
    });
    _drainQueue();
    return item.completer.future;
  }

  void _drainQueue() {
    if (_drainingQueue || _disposed) {
      return;
    }
    _drainingQueue = true;
    unawaited(_drainLoop());
  }

  Future<void> _drainLoop() async {
    try {
      while (!_disposed && _activeRun == null && _queuedRuns.isNotEmpty) {
        final next = _queuedRuns.removeFirst();
        _activeRun = next;
        _emitEvent(<String, dynamic>{
          'type': 'run_started',
          'taskId': next.taskId,
        });

        try {
          final meta = <String, dynamic>{
            'fm_agent_os/taskId': next.taskId,
            'fm_agent_os/executionMode': next.executionMode,
            if (next.model != null && next.model!.isNotEmpty)
              'fm_agent_os/modelOverride': next.model,
          };
          final raw = await _peer.sendRequest(
            'session/prompt',
            <String, dynamic>{
              'sessionId': _requireSessionId(),
              'prompt': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': next.prompt},
              ],
              '_meta': meta,
            },
          );
          final res = raw is Map
              ? Map<String, dynamic>.from(raw)
              : <String, dynamic>{'result': raw};
          if (!next.completer.isCompleted) {
            next.completer.complete(res);
          }
        } catch (e, st) {
          if (!next.completer.isCompleted) {
            next.completer.completeError(e, st);
          }
        } finally {
          _cancelAllPendingPermissions();
          _activeRun = null;
          _emitEvent(<String, dynamic>{
            'type': 'run_finished',
            'taskId': next.taskId,
          });
        }
      }
    } finally {
      _drainingQueue = false;
    }
  }

  /// Edits a file inside a card's workspace and cascades `update-stale` via `_fm_agent_os/stack_edit`.
  Future<Map<String, dynamic>> editCard({
    required String taskId,
    required String relativePath,
    required String content,
  }) async {
    final sid = _requireSessionId();
    final raw = await _peer.sendRequest(
      '_fm_agent_os/stack_edit',
      <String, dynamic>{
        'sessionId': sid,
        'taskId': taskId,
        'relativePath': relativePath,
        'content': content,
      },
    );
    _emitEvent(<String, dynamic>{'type': 'card_edited', 'taskId': taskId});
    return raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'result': raw};
  }

  /// Changes the session or card model.
  Future<Map<String, dynamic>> setModel({
    String? taskId,
    required String model,
  }) async {
    final sid = _requireSessionId();
    if (taskId != null && taskId.isNotEmpty) {
      final raw = await _peer.sendRequest(
        '_fm_agent_os/stack_update',
        <String, dynamic>{
          'sessionId': sid,
          'taskId': taskId,
          'model': model,
        },
      );
      _emitEvent(<String, dynamic>{'type': 'model_updated', 'taskId': taskId});
      return raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{'result': raw};
    }

    final raw = await _peer.sendRequest(
      'session/set_config_option',
      <String, dynamic>{
        'sessionId': sid,
        'configId': 'model',
        'value': model,
      },
    );
    _currentModel = model;
    if (raw is Map) {
      _applyConfigOptions(raw['configOptions']);
    }
    _emitEvent(<String, dynamic>{'type': 'model_updated', 'model': _currentModel ?? model});
    return raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'ok': true, 'model': _currentModel ?? model};
  }

  void _applyConfigOptions(Object? configOptions) {
    if (configOptions is! List) {
      return;
    }
    for (final opt in configOptions) {
      if (opt is Map && opt['id'] == 'model') {
        final current = opt['currentValue'];
        if (current is String && current.isNotEmpty) {
          _currentModel = current;
        }
        final rawOpts = opt['options'];
        if (rawOpts is List) {
          _availableModels = rawOpts
              .whereType<Map<dynamic, dynamic>>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList(growable: false);
        }
      }
    }
  }

  /// Sends a signal (`SIGSTOP`/`SIGCONT`/`SIGKILL`). If `SIGKILL` targets a card
  /// currently waiting in the FIFO queue, removes it immediately without hitting the daemon.
  Future<Map<String, dynamic>> sendSignal({
    required String signal,
    int? pid,
    String? taskId,
    String? constraintMessage,
    bool cascadeChildren = true,
  }) async {
    final sid = _requireSessionId();
    if (signal == 'SIGKILL' && taskId != null && taskId.isNotEmpty) {
      KanbanQueuedRun? removed;
      final remaining = Queue<KanbanQueuedRun>();
      while (_queuedRuns.isNotEmpty) {
        final item = _queuedRuns.removeFirst();
        if (removed == null && item.taskId == taskId) {
          removed = item;
        } else {
          remaining.addLast(item);
        }
      }
      _queuedRuns.addAll(remaining);
      if (removed != null) {
        if (!removed.completer.isCompleted) {
          removed.completer.complete(<String, dynamic>{
            'stopReason': 'cancelled',
            'removedFromQueue': true,
          });
        }
        _emitEvent(<String, dynamic>{
          'type': 'queue_changed',
          'taskId': taskId,
          'removedFromQueue': true,
        });
        return <String, dynamic>{
          'ok': true,
          'signal': 'SIGKILL',
          'taskId': taskId,
          'removedFromQueue': true,
          'affectedPids': const <int>[],
        };
      }
    }

    final raw = await _peer.sendRequest(
      '_fm_agent_os/signal',
      <String, dynamic>{
        'sessionId': sid,
        'signal': signal,
        'pid': ?pid,
        if (taskId != null && taskId.isNotEmpty) 'taskId': taskId,
        if (constraintMessage != null && constraintMessage.isNotEmpty)
          'constraintMessage': constraintMessage,
        'cascadeChildren': cascadeChildren,
      },
    );
    _emitEvent(<String, dynamic>{
      'type': 'signal_sent',
      'signal': signal,
      'taskId': ?taskId,
    });
    return raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'result': raw};
  }

  /// Fetches non-destructive `jj diff` and `conflictedFiles` via `_fm_agent_os/jj_diff`.
  Future<Map<String, dynamic>> getDiff({String? rev, String? taskId}) async {
    final sid = _requireSessionId();
    final raw = await _peer.sendRequest(
      '_fm_agent_os/jj_diff',
      <String, dynamic>{
        'sessionId': sid,
        if (rev != null && rev.isNotEmpty) 'rev': rev,
        if (taskId != null && taskId.isNotEmpty) 'taskId': taskId,
      },
    );
    return raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'diff': ''};
  }

  /// Responds to a pending `session/request_permission` prompt ([D-709]).
  Future<Map<String, dynamic>> respondPermission({
    required String requestId,
    required String optionId,
  }) async {
    const validOptions = <String>{'allow_once', 'allow_always', 'reject_once'};
    if (!validOptions.contains(optionId)) {
      throw WireJsonRpcException(
        WireJsonRpcErrorCodes.invalidParams,
        'Invalid permission optionId "$optionId". Expected allow_once, allow_always, or reject_once.',
      );
    }
    final pending = _pendingPermissions.remove(requestId);
    if (pending == null) {
      throw WireJsonRpcException(
        WireJsonRpcErrorCodes.invalidParams,
        'Unknown or already resolved permission requestId: $requestId',
      );
    }
    if (!pending.completer.isCompleted) {
      pending.completer.complete(<String, dynamic>{
        'outcome': <String, dynamic>{
          'outcome': 'selected',
          'optionId': optionId,
        },
      });
    }
    _emitEvent(<String, dynamic>{
      'type': 'permission_resolved',
      'requestId': requestId,
      'optionId': optionId,
    });
    return <String, dynamic>{
      'ok': true,
      'requestId': requestId,
      'optionId': optionId,
    };
  }

  /// Triggers `_fm_agent_os/tx_squash` for the session or a specific card.
  Future<Map<String, dynamic>> squash({String? taskId, String? message}) async {
    final sid = _requireSessionId();
    final raw = await _peer.sendRequest(
      '_fm_agent_os/tx_squash',
      <String, dynamic>{
        'sessionId': sid,
        if (taskId != null && taskId.isNotEmpty) 'taskId': taskId,
        if (message != null && message.isNotEmpty) 'message': message,
      },
    );
    _emitEvent(<String, dynamic>{
      'type': 'squash_completed',
      'taskId': ?taskId,
    });
    return raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'result': raw};
  }

  /// Triggers `_fm_agent_os/stack_sync`.
  Future<Map<String, dynamic>> syncStack({String? taskId}) async {
    final sid = _requireSessionId();
    final raw = await _peer.sendRequest(
      '_fm_agent_os/stack_sync',
      <String, dynamic>{
        'sessionId': sid,
        if (taskId != null && taskId.isNotEmpty) 'taskId': taskId,
      },
    );
    _emitEvent(<String, dynamic>{'type': 'stack_synced'});
    return raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'result': raw};
  }

  /// Cleanly shuts down the daemon: cancels active turn, closes `stdin` EOF,
  /// waits up to 5 seconds, and falls back to `SIGKILL` ([D-322] §3.4).
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    while (_queuedRuns.isNotEmpty) {
      final item = _queuedRuns.removeFirst();
      if (!item.completer.isCompleted) {
        item.completer.completeError(const WireJsonRpcPeerClosedException());
      }
    }

    for (final pending in _pendingPermissions.values.toList(growable: false)) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(<String, dynamic>{
          'outcome': <String, dynamic>{'outcome': 'cancelled'},
        });
      }
    }
    _pendingPermissions.clear();

    if (_activeRun != null && _sessionId != null && !_peer.isClosed) {
      try {
        _peer.sendNotification('session/cancel', <String, dynamic>{
          'sessionId': _sessionId,
        });
      } catch (_) {}
    }

    final proc = _daemonProcess;
    if (proc != null) {
      try {
        await proc.stdin.close();
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        proc.kill(ProcessSignal.sigkill);
        try {
          await proc.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      await _peer.close(closeOutput: false);
    } else {
      await _peer.close(closeOutput: true);
    }

    await _stderrSub?.cancel();
    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
  }

  Future<Object?> _handleIncomingRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'session/request_permission') {
      final policy = permissionPolicy.trim().toLowerCase();
      if (policy == 'allow_once' ||
          policy == 'allow_always' ||
          policy == 'reject_once') {
        return <String, dynamic>{
          'outcome': <String, dynamic>{
            'outcome': 'selected',
            'optionId': policy,
          },
        };
      }

      final reqId = 'perm_${++_permSeq}';
      final sid = (params['sessionId'] as String?) ?? _sessionId ?? '';
      final toolCall = params['toolCall'] is Map
          ? Map<String, dynamic>.from(params['toolCall'] as Map)
          : <String, dynamic>{};
      final rawOpts = params['options'];
      final options = rawOpts is List
          ? rawOpts
              .whereType<Map<dynamic, dynamic>>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList(growable: false)
          : <Map<String, dynamic>>[];

      Map<String, dynamic>? approvalMeta;
      final rawMeta = params['_meta'];
      if (rawMeta is Map && rawMeta['fm_agent_os/approval'] is Map) {
        approvalMeta = Map<String, dynamic>.from(
          rawMeta['fm_agent_os/approval'] as Map,
        );
      }
      final daemonRequestId = approvalMeta?['requestId'] as String?;
      final toolCallId = toolCall['toolCallId'] as String?;

      final pending = KanbanPendingPermission(
        requestId: reqId,
        sessionId: sid,
        toolCall: toolCall,
        options: options,
        taskId: _activeRun?.taskId,
        daemonRequestId: daemonRequestId,
        toolCallId: toolCallId,
        approvalMeta: approvalMeta,
      );
      _pendingPermissions[reqId] = pending;
      _emitEvent(<String, dynamic>{
        'type': 'permission_requested',
        'permission': pending.toJson(),
      });
      return pending.completer.future;
    }

    throw WireJsonRpcException(
      WireJsonRpcErrorCodes.methodNotFound,
      'Unsupported client method: $method',
    );
  }

  void _cancelAllPendingPermissions() {
    if (_pendingPermissions.isEmpty) {
      return;
    }
    final entries = _pendingPermissions.values.toList(growable: false);
    _pendingPermissions.clear();
    for (final pending in entries) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(<String, dynamic>{
          'outcome': <String, dynamic>{'outcome': 'cancelled'},
        });
      }
      _emitEvent(<String, dynamic>{
        'type': 'permission_cancelled',
        'requestId': pending.requestId,
      });
    }
  }

  void _handleIncomingNotification(
    String method,
    Map<String, dynamic> params,
  ) {
    if (method == '_fm_agent_os/permission_cancelled') {
      final targetReqId = params['requestId'] as String?;
      final targetToolCallId = params['toolCallId'] as String?;
      final matchedKeys = <String>[];
      for (final entry in _pendingPermissions.entries) {
        final pending = entry.value;
        final matchesReq = targetReqId != null &&
            targetReqId.isNotEmpty &&
            pending.daemonRequestId == targetReqId;
        final matchesTc = targetToolCallId != null &&
            targetToolCallId.isNotEmpty &&
            pending.toolCallId == targetToolCallId;
        if (matchesReq || matchesTc) {
          matchedKeys.add(entry.key);
        }
      }
      for (final key in matchedKeys) {
        final removed = _pendingPermissions.remove(key);
        if (removed != null) {
          if (!removed.completer.isCompleted) {
            removed.completer.complete(<String, dynamic>{
              'outcome': <String, dynamic>{'outcome': 'cancelled'},
            });
          }
          _emitEvent(<String, dynamic>{
            'type': 'permission_cancelled',
            'requestId': removed.requestId,
          });
        }
      }
      return;
    }

    if (method == 'session/update') {
      final update = params['update'];
      if (update is Map) {
        final meta = update['_meta'];
        if (meta is Map) {
          final telemetry = meta['fm_agent_os/llmTelemetry'];
          if (telemetry is Map) {
            final swapped = telemetry['swappedDirtyPagesTotal'];
            if (swapped is int) {
              _swappedDirtyPagesTotal = swapped;
            }
          }
        }
      }
    }
    _emitEvent(<String, dynamic>{
      'type': 'session_update',
      'method': method,
      'params': params,
      if (_activeRun != null) 'taskId': _activeRun!.taskId,
    });
  }

  void _emitEvent(Map<String, dynamic> event) {
    if (!_disposed && !_eventsController.isClosed) {
      _eventsController.add(redactor.redactJson(event) as Map<String, dynamic>);
    }
  }

  String _requireSessionId() {
    final sid = _sessionId;
    if (sid == null || sid.isEmpty) {
      throw const WireJsonRpcException(
        WireJsonRpcErrorCodes.internalError,
        'ACP session is not initialized.',
      );
    }
    return sid;
  }
}
