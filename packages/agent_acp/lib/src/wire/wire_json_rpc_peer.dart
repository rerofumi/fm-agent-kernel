import 'dart:async';
import 'dart:convert';

import 'wire_redactor.dart';

/// Standard JSON-RPC 2.0 and ACP server error codes ([D-018], [D-322]).
abstract final class WireJsonRpcErrorCodes {
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
  static const int serverError = -32000;
}

/// Structured JSON-RPC 2.0 error thrown by handlers or returned by remote peers ([D-322]).
class WireJsonRpcException implements Exception {
  const WireJsonRpcException(
    this.code,
    this.message, {
    this.data,
  });

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'WireJsonRpcException($code: $message)';
}

/// Exception thrown when a pending outgoing JSON-RPC request is aborted because the peer closed.
class WireJsonRpcPeerClosedException implements Exception {
  const WireJsonRpcPeerClosedException([
    this.message = 'JSON-RPC peer closed before response arrived.',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// Request handler signature for incoming JSON-RPC 2.0 requests.
typedef WireJsonRpcRequestHandler = Future<Object?> Function(
  String method,
  Map<String, dynamic> params,
);

/// Notification handler signature for incoming JSON-RPC 2.0 notifications.
typedef WireJsonRpcNotificationHandler = FutureOr<void> Function(
  String method,
  Map<String, dynamic> params,
);

/// Pure-Dart bidirectional UTF-8 NDJSON JSON-RPC 2.0 peer supporting multiplexed
/// requests, notifications, and responses over `stdio` or in-memory streams ([D-322]).
class WireJsonRpcPeer {
  WireJsonRpcPeer({
    required Stream<List<int>> input,
    required StreamSink<List<int>> output,
    WireRedactor? redactor,
    this.onRequest,
    this.onNotification,
    this.onProtocolError,
  })  : _output = output,
        _redactor = redactor ?? WireSecretRedactor() {
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
  final WireRedactor _redactor;

  /// Handler invoked for incoming JSON-RPC Requests (messages with an `id`).
  WireJsonRpcRequestHandler? onRequest;

  /// Handler invoked for incoming JSON-RPC Notifications (messages without an `id`).
  WireJsonRpcNotificationHandler? onNotification;

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

  /// Sends a JSON-RPC 2.0 Request and awaits its `result` (or throws [WireJsonRpcException]).
  Future<Object?> sendRequest(
    String method, [
    Map<String, dynamic>? params,
    Future<void>? onCancel,
    bool Function()? isCancelled,
  ]) {
    if (_closed) {
      return Future<Object?>.error(const WireJsonRpcPeerClosedException());
    }
    if (isCancelled != null && isCancelled()) {
      return Future<Object?>.error(
        const WireJsonRpcException(
          WireJsonRpcErrorCodes.serverError,
          'Request cancelled before sending.',
        ),
      );
    }

    final id = 'rpc_${++_nextRequestId}';
    final completer = Completer<Object?>();
    _pendingRequests[id] = completer;

    if (onCancel != null) {
      onCancel.then((_) {
        final pending = _pendingRequests.remove(id);
        if (pending != null && !pending.isCompleted) {
          pending.completeError(
            const WireJsonRpcException(
              WireJsonRpcErrorCodes.serverError,
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
        completer.completeError(const WireJsonRpcPeerClosedException());
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
      _sendError(null, WireJsonRpcErrorCodes.parseError, 'Parse error');
      return;
    }

    if (decoded is! Map) {
      _sendError(null, WireJsonRpcErrorCodes.parseError, 'Parse error');
      return;
    }

    final msg = Map<String, dynamic>.from(decoded);
    if (msg['jsonrpc'] != '2.0') {
      final hasId = msg.containsKey('id');
      _sendError(
        hasId ? msg['id'] : null,
        WireJsonRpcErrorCodes.invalidRequest,
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
          WireJsonRpcErrorCodes.invalidRequest,
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
        WireJsonRpcErrorCodes.invalidRequest,
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
          WireJsonRpcErrorCodes.invalidParams,
          'Invalid params: params must be an object.',
        );
      }
      return;
    }

    if (hasId && msg['id'] != null) {
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
            WireJsonRpcErrorCodes.internalError;
        final message =
            (errMap['message'] as String?) ?? 'Remote JSON-RPC error';
        completer.completeError(
          WireJsonRpcException(code, message, data: errMap['data']),
        );
      } else {
        completer.completeError(
          WireJsonRpcException(
            WireJsonRpcErrorCodes.internalError,
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
      _sendError(
          id, WireJsonRpcErrorCodes.methodNotFound, 'Method not found');
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
    } on WireJsonRpcException catch (e) {
      if (!_closed) {
        _sendError(id, e.code, e.message, data: e.data);
      }
    } catch (e) {
      final redacted = _redactor.redactString(e.toString());
      onProtocolError?.call('Unhandled request error for $method: $redacted');
      if (!_closed) {
        _sendError(
          id,
          WireJsonRpcErrorCodes.internalError,
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
