import 'dart:async';

import 'package:agent_kernel/agent_kernel.dart';

/// Exception thrown by [McpTransport] on protocol, timeout, or connection failures ([D-318]).
class McpTransportException implements Exception {
  McpTransportException({
    required this.code,
    required this.reason,
    required this.message,
    this.jsonRpcCode,
    this.data,
    this.recoverable = true,
  });

  final SyscallErrorCode code;
  final String reason;
  final String message;
  final int? jsonRpcCode;
  final Object? data;
  final bool recoverable;

  SyscallError toSyscallError({SecretRedactor? redactor}) {
    final safeMessage =
        redactor == null ? message : redactor.redactString(message);
    return SyscallError(
      code: code,
      reason: reason,
      message: safeMessage,
      recoverable: recoverable,
      details: <String, dynamic>{
        if (jsonRpcCode != null) 'jsonRpcCode': jsonRpcCode,
        if (data != null) 'data': redactor == null ? data : redactor.redactJson(data),
      },
    );
  }

  @override
  String toString() => 'McpTransportException($reason: $message)';
}

/// Transport abstraction for MCP JSON-RPC 2.0 communication ([D-318]).
///
/// Standard implementation is [StdioMcpTransport]; additional transports such as
/// `StreamableHttpMcpTransport` can implement this interface without changing [StdioMcpClient]
/// or the fixed `sys_mcp_*` syscall boundary.
abstract interface class McpTransport {
  /// Sends a JSON-RPC 2.0 request and awaits its response `result` map.
  Future<Map<String, dynamic>> sendRequest(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
    CancellationToken? cancelToken,
  });

  /// Sends a JSON-RPC 2.0 notification (no `id`, no response expected).
  Future<void> sendNotification(
    String method, {
    Map<String, dynamic>? params,
  });

  /// Broadcast stream of server-initiated JSON-RPC notifications.
  Stream<Map<String, dynamic>> get incomingNotifications;

  /// Whether the transport is currently open and usable.
  bool get isConnected;

  /// Closes the transport and releases underlying OS resources.
  Future<void> close();
}
