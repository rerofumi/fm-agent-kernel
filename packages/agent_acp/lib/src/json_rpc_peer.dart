import 'dart:async';

import 'package:agent_kernel/agent_kernel.dart';

import 'wire/wire_json_rpc_peer.dart';
import 'wire/wire_redactor.dart';

/// Standard JSON-RPC 2.0 and ACP server error codes ([D-018]).
abstract final class JsonRpcErrorCodes {
  static const int parseError = WireJsonRpcErrorCodes.parseError;
  static const int invalidRequest = WireJsonRpcErrorCodes.invalidRequest;
  static const int methodNotFound = WireJsonRpcErrorCodes.methodNotFound;
  static const int invalidParams = WireJsonRpcErrorCodes.invalidParams;
  static const int internalError = WireJsonRpcErrorCodes.internalError;
  static const int serverError = WireJsonRpcErrorCodes.serverError;
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

class _KernelRedactorAdapter implements WireRedactor {
  _KernelRedactorAdapter(this._inner);

  final SecretRedactor _inner;

  @override
  String redactString(String input) => _inner.redactString(input);

  @override
  dynamic redactJson(dynamic value, {String? keyName}) =>
      _inner.redactJson(value, keyName: keyName);
}

/// Backward-compatible adapter wrapping [WireJsonRpcPeer] with [SecretRedactor]
/// and [CancellationToken] support ([D-018], [D-322]).
class JsonRpcPeer {
  JsonRpcPeer({
    required Stream<List<int>> input,
    required StreamSink<List<int>> output,
    SecretRedactor? redactor,
    this.onRequest,
    this.onNotification,
    this.onProtocolError,
  }) {
    _wire = WireJsonRpcPeer(
      input: input,
      output: output,
      redactor: _KernelRedactorAdapter(redactor ?? SecretRedactor()),
      onRequest: (method, params) async {
        final handler = onRequest;
        if (handler == null) {
          throw const WireJsonRpcException(
            WireJsonRpcErrorCodes.methodNotFound,
            'Method not found',
          );
        }
        try {
          return await handler(method, params);
        } on JsonRpcException catch (e) {
          throw WireJsonRpcException(e.code, e.message, data: e.data);
        }
      },
      onNotification: (method, params) => onNotification?.call(method, params),
      onProtocolError: (message) => onProtocolError?.call(message),
    );
  }

  late final WireJsonRpcPeer _wire;
  JsonRpcRequestHandler? onRequest;
  JsonRpcNotificationHandler? onNotification;
  void Function(String message)? onProtocolError;

  /// Completes when the input stream reaches EOF or [close] is called.
  Future<void> get done => _wire.done;

  /// Whether this peer has reached EOF or been closed.
  bool get isClosed => _wire.isClosed;

  /// Sends a JSON-RPC 2.0 Request and awaits its `result` (or throws [JsonRpcException]).
  Future<Object?> sendRequest(
    String method, [
    Map<String, dynamic>? params,
    CancellationToken? cancelToken,
  ]) async {
    try {
      return await _wire.sendRequest(
        method,
        params,
        cancelToken?.onCancel,
        cancelToken == null ? null : () => cancelToken.isCancelled,
      );
    } on WireJsonRpcException catch (e) {
      throw JsonRpcException(e.code, e.message, data: e.data);
    } on WireJsonRpcPeerClosedException catch (e) {
      throw JsonRpcPeerClosedException(e.message);
    }
  }

  /// Sends a JSON-RPC 2.0 Notification (no `id`, no response expected).
  void sendNotification(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    _wire.sendNotification(method, params);
  }

  /// Waits for currently executing incoming request/notification handlers to settle.
  Future<void> waitForInFlightHandlers({
    Duration timeout = const Duration(seconds: 5),
  }) {
    return _wire.waitForInFlightHandlers(timeout: timeout);
  }

  /// Closes the incoming stream subscription and aborts any pending outgoing requests.
  Future<void> close({bool closeOutput = false}) {
    return _wire.close(closeOutput: closeOutput);
  }
}
