import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../wire/wire_json_rpc_peer.dart';
import 'kanban_acp_bridge.dart';
import 'kanban_csrf.dart';
import 'kanban_ui_assets.dart';

/// Local loopback-only HTTP + WebSocket server for `acp_kanban_app` ([D-322], [D-323]).
class KanbanServer {
  KanbanServer._({
    required HttpServer httpServer,
    required KanbanAcpBridge bridge,
    required KanbanCsrfGuard csrf,
    required StringSink err,
  })  : _httpServer = httpServer,
        _bridge = bridge,
        _csrf = csrf,
        _err = err;

  final HttpServer _httpServer;
  final KanbanAcpBridge _bridge;
  final KanbanCsrfGuard _csrf;
  final StringSink _err;

  final Set<WebSocket> _wsClients = <WebSocket>{};
  final Completer<void> _doneCompleter = Completer<void>();

  StreamSubscription<HttpRequest>? _httpSub;
  StreamSubscription<Map<String, dynamic>>? _bridgeEventSub;
  StreamSubscription<List<int>>? _stdinSub;
  final List<StreamSubscription<ProcessSignal>> _signalSubs =
      <StreamSubscription<ProcessSignal>>[];

  bool _shuttingDown = false;

  int get port => _httpServer.port;
  String get url => 'http://127.0.0.1:${_httpServer.port}/';
  String get csrfToken => _csrf.token;
  Future<void> get done => _doneCompleter.future;

  /// Binds exclusively to `InternetAddress.loopbackIPv4` (`127.0.0.1`), emits `KANBAN_READY`,
  /// and wires HTTP/WS routes and chained shutdown triggers ([D-322] §3.2–3.4).
  static Future<KanbanServer> start({
    required KanbanAcpBridge bridge,
    int port = 8765,
    KanbanCsrfGuard? csrfGuard,
    StringSink? out,
    StringSink? err,
    Stream<List<int>>? stdinEofStream,
    bool watchStdinEof = false,
    bool watchProcessSignals = false,
  }) async {
    final csrf = csrfGuard ?? KanbanCsrfGuard();
    final effectiveOut = out ?? stdout;
    final effectiveErr = err ?? stderr;

    // Security invariant ([D-322] §3.2): strictly bind loopback IPv4 only.
    final httpServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );

    final server = KanbanServer._(
      httpServer: httpServer,
      bridge: bridge,
      csrf: csrf,
      err: effectiveErr,
    );

    server._startListening(
      stdinEofStream: stdinEofStream,
      watchStdinEof: watchStdinEof,
      watchProcessSignals: watchProcessSignals,
    );

    // Emit readiness line without exposing any CSRF token or secret ([D-322] §3.2).
    effectiveOut.writeln('KANBAN_READY url=http://127.0.0.1:${httpServer.port}/');
    if (effectiveOut is IOSink) {
      await effectiveOut.flush();
    }

    return server;
  }

  void _startListening({
    Stream<List<int>>? stdinEofStream,
    required bool watchStdinEof,
    required bool watchProcessSignals,
  }) {
    _httpSub = _httpServer.listen(
      _handleHttpRequest,
      onError: (Object e) {
        _err.writeln('[acp_kanban_app] HTTP error: ${_bridge.redactor.redactString(e.toString())}');
      },
    );

    _bridgeEventSub = _bridge.events.listen((event) {
      _broadcastWs(event);
    });

    unawaited(_bridge.daemonExitCode.then((_) {
      if (!_shuttingDown) {
        unawaited(shutdown());
      }
    }));

    if (watchStdinEof || stdinEofStream != null) {
      final stream = stdinEofStream ?? stdin;
      _stdinSub = stream.listen(
        (_) {},
        onDone: () => unawaited(shutdown()),
        onError: (_) => unawaited(shutdown()),
        cancelOnError: true,
      );
    }

    if (watchProcessSignals) {
      try {
        _signalSubs.add(
          ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown())),
        );
      } catch (_) {}
      if (!Platform.isWindows) {
        try {
          _signalSubs.add(
            ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown())),
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method.toUpperCase();

    try {
      if (method == 'GET' && (path == '/' || path == '/index.html')) {
        _csrf.applyHtmlSecurityHeaders(request.response, port);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.write(_csrf.injectIntoHtml(kanbanIndexHtml));
        await request.response.close();
        return;
      }

      if (method == 'GET' && path == '/ws') {
        if (!_csrf.validateWebSocketUpgrade(request, port)) {
          await _sendForbidden(request.response);
          return;
        }
        final ws = await WebSocketTransformer.upgrade(request);
        _wsClients.add(ws);
        ws.listen(
          (_) {},
          onDone: () => _wsClients.remove(ws),
          onError: (_) => _wsClients.remove(ws),
          cancelOnError: true,
        );
        try {
          final snapshot = await _bridge.getState();
          if (ws.readyState == WebSocket.open) {
            ws.add(jsonEncode(snapshot));
          }
        } catch (e) {
          if (ws.readyState == WebSocket.open) {
            ws.add(jsonEncode(<String, dynamic>{
              'type': 'error',
              'message': _bridge.redactor.redactString(e.toString()),
            }));
          }
        }
        return;
      }

      if (method == 'GET' && path == '/api/state') {
        if (!_csrf.validateHttpRequest(request, port, requireToken: true)) {
          await _sendForbidden(request.response);
          return;
        }
        final state = await _bridge.getState();
        await _sendJson(request.response, HttpStatus.ok, state);
        return;
      }

      if (method == 'POST' || method == 'PUT' || method == 'DELETE') {
        if (!_csrf.validateHttpRequest(request, port, requireToken: true)) {
          await _sendForbidden(request.response);
          return;
        }
        final body = await _readJsonBody(request);
        await _handleMutatingApi(method, path, body, request.response);
        return;
      }

      await _sendJson(request.response, HttpStatus.notFound, <String, dynamic>{
        'error': 'Not found: $method $path',
      });
    } on WireJsonRpcException catch (e) {
      await _sendJson(
        request.response,
        HttpStatus.badRequest,
        <String, dynamic>{
          'error': _bridge.redactor.redactString(e.message),
          'code': e.code,
          if (e.data != null) 'data': _bridge.redactor.redactJson(e.data),
        },
      );
    } on FormatException catch (e) {
      await _sendJson(
        request.response,
        HttpStatus.badRequest,
        <String, dynamic>{'error': _bridge.redactor.redactString(e.message)},
      );
    } catch (e) {
      await _sendJson(
        request.response,
        HttpStatus.internalServerError,
        <String, dynamic>{'error': _bridge.redactor.redactString(e.toString())},
      );
    }
  }

  Future<void> _handleMutatingApi(
    String method,
    String path,
    Map<String, dynamic> body,
    HttpResponse response,
  ) async {
    if (method != 'POST') {
      await _sendJson(response, HttpStatus.methodNotAllowed, <String, dynamic>{
        'error': 'Method not allowed',
      });
      return;
    }

    switch (path) {
      case '/api/cards':
        final title = (body['title'] as String?)?.trim() ?? '';
        if (title.isEmpty) {
          throw const FormatException('Missing required "title".');
        }
        final res = await _bridge.createCard(
          taskId: body['taskId'] as String?,
          title: title,
          description: body['description'] as String?,
          parentTaskId: body['parentTaskId'] as String?,
          baseChangeId: body['baseChangeId'] as String?,
          model: body['model'] as String?,
          executionMode: (body['executionMode'] as String?) ?? 'single',
          autoStart: body['autoStart'] == true,
          prompt: body['prompt'] as String?,
        );
        await _sendJson(response, HttpStatus.ok, res);
        return;

      case '/api/cards/run':
        final taskId = (body['taskId'] as String?)?.trim() ?? '';
        if (taskId.isEmpty) {
          throw const FormatException('Missing required "taskId".');
        }
        final runFuture = _bridge.enqueueRun(
          taskId: taskId,
          prompt: body['prompt'] as String?,
          model: body['model'] as String?,
          executionMode: (body['executionMode'] as String?) ?? 'single',
        );
        unawaited(runFuture.catchError((_) => <String, dynamic>{}));
        await _sendJson(response, HttpStatus.ok, <String, dynamic>{
          'ok': true,
          'queued': true,
          'taskId': taskId,
          'queuedRuns': _bridge.queuedRunCount,
        });
        return;

      case '/api/cards/edit':
        final taskId = (body['taskId'] as String?)?.trim() ?? '';
        final relativePath = (body['relativePath'] as String?)?.trim() ?? '';
        final content = body['content'];
        if (taskId.isEmpty || relativePath.isEmpty || content is! String) {
          throw const FormatException(
            'Requires "taskId", "relativePath", and string "content".',
          );
        }
        final res = await _bridge.editCard(
          taskId: taskId,
          relativePath: relativePath,
          content: content,
        );
        await _sendJson(response, HttpStatus.ok, res);
        return;

      case '/api/model':
        final model = (body['model'] as String?)?.trim() ?? '';
        if (model.isEmpty) {
          throw const FormatException('Missing required "model".');
        }
        final res = await _bridge.setModel(
          taskId: body['taskId'] as String?,
          model: model,
        );
        await _sendJson(response, HttpStatus.ok, res);
        return;

      case '/api/signal':
        final signal = (body['signal'] as String?)?.trim() ?? '';
        if (signal.isEmpty) {
          throw const FormatException('Missing required "signal".');
        }
        final pidRaw = body['pid'];
        final pid = pidRaw is num ? pidRaw.toInt() : null;
        final res = await _bridge.sendSignal(
          signal: signal,
          pid: pid,
          taskId: body['taskId'] as String?,
          constraintMessage: body['constraintMessage'] as String?,
          cascadeChildren: body['cascadeChildren'] != false,
        );
        await _sendJson(response, HttpStatus.ok, res);
        return;

      case '/api/diff':
        final res = await _bridge.getDiff(
          rev: body['rev'] as String?,
          taskId: body['taskId'] as String?,
        );
        await _sendJson(response, HttpStatus.ok, res);
        return;

      case '/api/permissions/respond':
        final requestId = (body['requestId'] as String?)?.trim() ?? '';
        final optionId = (body['optionId'] as String?)?.trim() ?? '';
        if (requestId.isEmpty || optionId.isEmpty) {
          throw const FormatException(
            'Requires "requestId" and "optionId".',
          );
        }
        final res = await _bridge.respondPermission(
          requestId: requestId,
          optionId: optionId,
        );
        await _sendJson(response, HttpStatus.ok, res);
        return;

      case '/api/squash':
        final res = await _bridge.squash(
          taskId: body['taskId'] as String?,
          message: body['message'] as String?,
        );
        await _sendJson(response, HttpStatus.ok, res);
        return;

      case '/api/shutdown':
        await _sendJson(
          response,
          HttpStatus.ok,
          <String, dynamic>{'ok': true, 'shuttingDown': true},
        );
        unawaited(shutdown());
        return;

      default:
        await _sendJson(response, HttpStatus.notFound, <String, dynamic>{
          'error': 'Not found: $path',
        });
    }
  }

  void _broadcastWs(Map<String, dynamic> event) {
    if (_wsClients.isEmpty) {
      return;
    }
    final payload = jsonEncode(event);
    for (final ws in _wsClients.toList(growable: false)) {
      try {
        if (ws.readyState == WebSocket.open) {
          ws.add(payload);
        } else {
          _wsClients.remove(ws);
        }
      } catch (_) {
        _wsClients.remove(ws);
      }
    }
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Request body must be a JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _sendForbidden(HttpResponse response) async {
    await _sendJson(
      response,
      HttpStatus.forbidden,
      <String, dynamic>{'error': 'Forbidden: invalid Origin or CSRF token.'},
    );
  }

  Future<void> _sendJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> body,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(jsonEncode(_bridge.redactor.redactJson(body)));
    await response.close();
  }

  /// Chained clean shutdown: close WS clients -> close HttpServer -> dispose daemon bridge ([D-322] §3.4).
  Future<void> shutdown() async {
    if (_shuttingDown) {
      return _doneCompleter.future;
    }
    _shuttingDown = true;

    for (final sub in _signalSubs) {
      await sub.cancel();
    }
    _signalSubs.clear();
    await _stdinSub?.cancel();
    await _bridgeEventSub?.cancel();

    for (final ws in _wsClients.toList(growable: false)) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _wsClients.clear();

    await _httpSub?.cancel();
    try {
      await _httpServer.close(force: true);
    } catch (_) {}

    await _bridge.dispose();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}
