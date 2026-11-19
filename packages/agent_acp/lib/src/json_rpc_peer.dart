import 'dart:async';
import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';

/// Standard JSON-RPC 2.0 and ACP server error codes ([D-018]).
abstract final class JsonRpcErrorCodes {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  static const int serverError = -32000;
}

/// Structured JSON-RPC 2.0 error thrown by handlers or returned by remote peers ([D-018]).
class JsonRpcException implements Exception {
  const JsonRpcException(
    this.code,
    this.message, {
    this.data,
  });

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'JsonRpcException($code: $message)';
}

/// Exception thrown when a pending outgoing JSON-RPC request is aborted because the peer closed.
class JsonRpcPeerClosedException implements Exception {
  const JsonRpcPeerClosedException([
    this.message = 'JSON-RPC peer closed before response arrived.',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// Request handler signature for incoming JSON-RPC 2.0 requests.
typedef JsonRpcRequestHandler = Future<Object?> Function(
  String method,
  Map<String, dynamic> params,
);

/// Notification handler signature for incoming JSON-RPC 2.0 notifications.
typedef JsonRpcNotificationHandler = FutureOr<void> Function(
  String method,
  Map<String, dynamic> params,
);

/// Bidirectional UTF-8 NDJSON JSON-RPC 2.0 peer supporting multiplexed requests,
/// notifications, and responses over `stdio` or in-memory streams ([D-018]).
class JsonRpcPeer {
  JsonRpcPeer({
    required Stream<List<int>> input,
    required StreamSink<List<int>> output,
    SecretRedactor? redactor,
    this.onRequest,
    this.onNotification,
    this.onProtocolError,
  })  : _output = output,
        _redactor = redactor ?? SecretRedactor() {
    _subscription = input
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: (Object error, StackTrace stackTrace) {
            onProtocolError?.call(
              'Input stream error: ${_redactor.redactString(error.toString())}',
            );
            _handleEof();
          },
          onDone: _handleEof,
          cancelOnError: false,
        );
  }

  final StreamSink<List<int>> _output;
  final SecretRedactor _redactor;

  /// Handler invoked for incoming JSON-RPC Requests (messages with an `id`).
  JsonRpcRequestHandler? onRequest;

  /// Handler invoked for incoming JSON-RPC Notifications (messages without an `id`).
  JsonRpcNotificationHandler? onNotification;

  /// Optional diagnostic callback invoked on malformed frames or internal dispatch errors.
  void Function(String message)? onProtocolError;

  late final StreamSubscription<String> _subscription;
  final Map<Object, Completer<Object?>> _pendingRequests =
      <Object, Completer<Object?>>{};
  final Set<Future<void>> _inFlightHandlers = <Future<void>>{};
  final Completer<void> _doneCompleter = Completer<void>();

  int _nextRequestId = 0;
  bool _isFirstLine = true;
  bool _inputClosed = false;
  bool _closed = false;

  /// Completes when the input stream reaches EOF or [close] is called.
  Future<void> get done => _doneCompleter.future;

  /// Whether this peer has reached EOF or been closed.
  bool get isClosed => _closed;

  /// Sends a JSON-RPC 2.0 Request and awaits its `result` (or throws [JsonRpcException]).
  Future<Object?> sendRequest(
    String method, [
    Map<String, dynamic>? params,
    CancellationToken? cancelToken,
  ]) {
    if (_closed) {
      return Future<Object?>.error(const JsonRpcPeerClosedException());
    }
    if (cancelToken != null && cancelToken.isCancelled) {
      return Future<Object?>.error(
        const JsonRpcException(
          JsonRpcErrorCodes.serverError,
          'Request cancelled before sending.',
        ),
      );
    }

    final id = 'rpc_${++_nextRequestId}';
    final completer = Completer<Object?>();
    _pendingRequests[id] = completer;

    if (cancelToken != null) {
      cancelToken.onCancel.then((_) {
        final pending = _pendingRequests.remove(id);
        if (pending != null && !pending.isCompleted) {
          pending.completeError(
            const JsonRpcException(
              JsonRpcErrorCodes.serverError,
              'Request cancelled.',
            ),
          );
        }
      });
    }

    try {
      _sendFrame(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      });
    } catch (error) {
      _pendingRequests.remove(id);
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }

    return completer.future;
  }

  /// Sends a JSON-RPC 2.0 Notification (no `id`, no response expected).
  void sendNotification(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    if (_closed) {
      return;
    }
    _sendFrame(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': ?params,
    });
  }

  /// Waits for currently executing incoming request/notification handlers to settle.
  Future<void> waitForInFlightHandlers({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_inFlightHandlers.isEmpty) {
      return;
    }
    try {
      await Future.wait<void>(_inFlightHandlers.toList(growable: false))
          .timeout(timeout);
    } catch (_) {
      // Best-effort drain on shutdown.
    }
  }

  /// Closes the incoming stream subscription and aborts any pending outgoing requests.
  ///
  /// Set [closeOutput] to `true` when closing the write side (e.g., client shutting down
  /// a daemon's `stdin`). Leave `false` when responding to an incoming EOF so final
  /// writes can flush cleanly.
  Future<void> close({bool closeOutput = false}) async {
    if (!_closed) {
      _inputClosed = true;
      _closed = true;
      _failPendingRequests();
      await _subscription.cancel();
      if (closeOutput) {
        try {
          await _output.close();
        } catch (_) {
          // Best-effort sink close.
        }
      }
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    }
  }

  void _handleEof() {
    if (!_inputClosed) {
      _inputClosed = true;
      _failPendingRequests();
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    }
  }

  void _failPendingRequests() {
    if (_pendingRequests.isEmpty) {
      return;
    }
    final entries = _pendingRequests.values.toList(growable: false);
    _pendingRequests.clear();
    for (final completer in entries) {
      if (!completer.isCompleted) {
        completer.completeError(const JsonRpcPeerClosedException());
      }
    }
  }

  void _onLine(String rawLine) {
    if (_closed) {
      return;
    }

    var line = rawLine;
    if (_isFirstLine) {
      _isFirstLine = false;
      if (line.startsWith('\uFEFF')) {
        line = line.substring(1);
      }
    }
    line = line.trim();
    if (line.isEmpty) {
      return;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _sendError(null, JsonRpcErrorCodes.parseError, 'Parse error');
      return;
    }

    if (decoded is! Map) {
      _sendError(null, JsonRpcErrorCodes.parseError, 'Parse error');
      return;
    }

    final msg = Map<String, dynamic>.from(decoded);
    if (msg['jsonrpc'] != '2.0') {
      final hasId = msg.containsKey('id');
      _sendError(
        hasId ? msg['id'] : null,
        JsonRpcErrorCodes.invalidRequest,
        'Invalid Request: jsonrpc must be "2.0".',
      );
      return;
    }

    final hasMethod = msg.containsKey('method');
    final hasId = msg.containsKey('id');

    if (!hasMethod) {
      if (!hasId) {
        _sendError(
          null,
          JsonRpcErrorCodes.invalidRequest,
          'Invalid Request: missing method or response fields.',
        );
        return;
      }
      _handleResponse(msg);
      return;
    }

    final rawMethod = msg['method'];
    if (rawMethod is! String || rawMethod.isEmpty) {
      _sendError(
        hasId ? msg['id'] : null,
        JsonRpcErrorCodes.invalidRequest,
        'Invalid Request: method must be a non-empty string.',
      );
      return;
    }

    final rawParams = msg['params'];
    final Map<String, dynamic> params;
    if (rawParams == null) {
      params = const <String, dynamic>{};
    } else if (rawParams is Map) {
      params = Map<String, dynamic>.from(rawParams);
    } else {
      if (hasId) {
        _sendError(
          msg['id'],
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: params must be an object.',
        );
      }
      return;
    }

    if (hasId && msg['id'] != null) {
      // Dispatch asynchronously so the NDJSON reader loop stays non-blocking
      // for concurrent `session/request_permission` responses and `session/cancel`.
      _trackHandler(_handleIncomingRequest(msg['id']!, rawMethod, params));
    } else if (hasId && msg['id'] == null) {
      _trackHandler(_handleIncomingRequest(null, rawMethod, params));
    } else {
      _trackHandler(_handleIncomingNotification(rawMethod, params));
    }
  }

  void _trackHandler(Future<void> future) {
    _inFlightHandlers.add(future);
    future.whenComplete(() => _inFlightHandlers.remove(future));
  }

  void _handleResponse(Map<String, dynamic> msg) {
    final id = msg['id'];
    if (id == null) {
      return;
    }
    final completer = _pendingRequests.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }

    if (msg.containsKey('error') && msg['error'] != null) {
      final rawErr = msg['error'];
      if (rawErr is Map) {
        final errMap = Map<String, dynamic>.from(rawErr);
        final code = (errMap['code'] as num?)?.toInt() ??
            JsonRpcErrorCodes.internalError;
        final message =
            (errMap['message'] as String?) ?? 'Remote JSON-RPC error';
        completer.completeError(
          JsonRpcException(code, message, data: errMap['data']),
        );
      } else {
        completer.completeError(
          JsonRpcException(
            JsonRpcErrorCodes.internalError,
            'Malformed error response: $rawErr',
          ),
        );
      }
      return;
    }

    completer.complete(msg['result']);
  }

  Future<void> _handleIncomingRequest(
    Object? id,
    String method,
    Map<String, dynamic> params,
  ) async {
    final handler = onRequest;
    if (handler == null) {
      _sendError(id, JsonRpcErrorCodes.methodNotFound, 'Method not found');
      return;
    }

    try {
      final result = await handler(method, params);
      if (!_closed) {
        _sendFrame(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        });
      }
    } on JsonRpcException catch (e) {
      if (!_closed) {
        _sendError(id, e.code, e.message, data: e.data);
      }
    } catch (e) {
      final redacted = _redactor.redactString(e.toString());
      onProtocolError?.call('Unhandled request error for $method: $redacted');
      if (!_closed) {
        _sendError(
          id,
          JsonRpcErrorCodes.internalError,
          'Internal error: $redacted',
        );
      }
    }
  }

  Future<void> _handleIncomingNotification(
    String method,
    Map<String, dynamic> params,
  ) async {
    final handler = onNotification;
    if (handler == null) {
      return;
    }
    try {
      await handler(method, params);
    } catch (e) {
      onProtocolError?.call(
        'Notification handler error for $method: ${_redactor.redactString(e.toString())}',
      );
    }
  }

  void _sendError(
    Object? id,
    int code,
    String message, {
    Object? data,
  }) {
    if (_closed) {
      return;
    }
    final safeMessage = _redactor.redactString(message);
    final safeData = data == null ? null : _redactor.redactJson(data);
    _sendFrame(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, dynamic>{
        'code': code,
        'message': safeMessage,
        'data': ?safeData,
      },
    });
  }

  void _sendFrame(Map<String, dynamic> payload) {
    final redacted = _redactor.redactJson(payload);
    final jsonLine = jsonEncode(redacted);
    // `jsonEncode` escapes all `\n` and `\r`, guaranteeing strict 1-line NDJSON.
    _output.add(utf8.encode('$jsonLine\n'));
  }
}
