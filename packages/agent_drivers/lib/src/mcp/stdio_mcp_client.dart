import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:ffi/ffi.dart';

import '../exec/win32_job_exec_driver.dart';
import 'mcp_transport.dart';

const int _jobObjectExtendedLimitInformation = 9;
const int _processSetQuota = 0x0100;
const int _processTerminate = 0x0001;
const int _errorInvalidParameter = 87;
const int _errorAccessDenied = 5;

/// `stdio` implementation of [McpTransport] using NDJSON framing, sanitized env,
/// `runInShell: false`, and Win32 Job Object (`KILL_ON_JOB_CLOSE`) containment ([D-318]).
class StdioMcpTransport implements McpTransport {
  StdioMcpTransport({
    required this.spec,
    required this.workspaceHostRoot,
    SecretRedactor? redactor,
    Win32Kernel32? kernel32,
  })  : redactor = redactor ?? SecretRedactor(),
        _kernel32 = kernel32;

  final McpServerSpec spec;
  final String workspaceHostRoot;
  final SecretRedactor redactor;
  Win32Kernel32? _kernel32;

  Win32Kernel32 get _k32 => _kernel32 ??= Win32Kernel32();

  Process? _process;
  int _hJob = 0;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final StreamController<Map<String, dynamic>> _notificationController =
      StreamController<Map<String, dynamic>>.broadcast();

  final Map<int, Completer<Map<String, dynamic>>> _pendingRequests =
      <int, Completer<Map<String, dynamic>>>{};
  final ListQueue<String> _stderrRing = ListQueue<String>();
  static const int _maxStderrLines = 100;

  int _nextRequestId = 0;
  bool _started = false;
  bool _closed = false;
  Future<void> _stdinWriteChain = Future<void>.value();

  int? get osPid => _process?.pid;
  List<String> get recentStderr => List<String>.unmodifiable(_stderrRing);

  @override
  bool get isConnected => _started && !_closed && _process != null;

  @override
  Stream<Map<String, dynamic>> get incomingNotifications =>
      _notificationController.stream;

  /// Spawns the MCP child process, assigns it to a Win32 Job Object, and starts NDJSON listeners.
  Future<void> start() async {
    if (_started) {
      return;
    }
    if (_closed) {
      throw McpTransportException(
        code: SyscallErrorCode.eio,
        reason: 'MCP_SERVER_DISCONNECTED',
        message: 'MCP transport for "${spec.name}" is already closed.',
      );
    }

    // Register all spec.env values as secrets before spawning ([D-318] §3.2(1)).
    for (final envVar in spec.env) {
      redactor.registerSecret(envVar.value);
    }

    final mergedEnv = Win32JobExecDriver.buildSanitizedEnvironment();
    for (final envVar in spec.env) {
      mergedEnv[envVar.name] = envVar.value;
    }

    final workingDir =
        (spec.cwd != null && spec.cwd!.trim().isNotEmpty)
            ? spec.cwd!.trim()
            : workspaceHostRoot;

    if (Platform.isWindows) {
      final k32 = _k32;
      final extSize = Win32JobExecDriver.jobExtendedLimitInfoStructBytes;
      final infoPtr = calloc<Uint8>(extSize);
      try {
        final hJob = k32.createJobObjectW(nullptr, nullptr);
        if (hJob == 0) {
          throw McpTransportException(
            code: SyscallErrorCode.eio,
            reason: 'CREATE_JOB_OBJECT_FAILED',
            message:
                'CreateJobObjectW failed for MCP "${spec.name}" (err=${k32.getLastError()}).',
            recoverable: false,
          );
        }
        final byteView = infoPtr.asTypedList(extSize);
        ByteData.sublistView(byteView).setUint32(
          Win32JobExecDriver.jobLimitFlagsByteOffset,
          Win32JobExecDriver.killOnJobCloseFlag,
          Endian.little,
        );
        final setOk = k32.setInformationJobObject(
          hJob,
          _jobObjectExtendedLimitInformation,
          infoPtr.cast<Void>(),
          extSize,
        );
        if (setOk == 0) {
          k32.closeHandle(hJob);
          throw McpTransportException(
            code: SyscallErrorCode.eio,
            reason: 'SET_JOB_INFO_FAILED',
            message:
                'SetInformationJobObject failed for MCP "${spec.name}" (err=${k32.getLastError()}).',
            recoverable: false,
          );
        }
        _hJob = hJob;
      } finally {
        calloc.free(infoPtr);
      }
    }

    final Process proc;
    try {
      proc = await Process.start(
        spec.command,
        spec.args,
        workingDirectory: workingDir,
        environment: mergedEnv,
        includeParentEnvironment: false,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      _closeJobHandle();
      throw McpTransportException(
        code: SyscallErrorCode.enoent,
        reason: 'MCP_PROCESS_START_FAILED',
        message:
            'Failed to start MCP server "${spec.name}" (${spec.command}): ${e.message}',
      );
    }

    _process = proc;
    _started = true;

    if (Platform.isWindows && _hJob != 0) {
      final assignErr = await _assignProcessToJob(_k32, _hJob, proc);
      if (assignErr != null) {
        await close();
        throw assignErr;
      }
    }

    // Consume stdout/stderr strictly inside the driver; never forward to host stdout.
    _stdoutSub = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _handleStdoutLine,
          onError: (Object err) => _handleDisconnect('MCP stdout error: $err'),
          onDone: () => _handleDisconnect('MCP server "${spec.name}" closed stdout.'),
        );

    _stderrSub = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _handleStderrLine,
          onError: (_) {},
        );
  }

  Future<McpTransportException?> _assignProcessToJob(
    Win32Kernel32 k32,
    int hJob,
    Process proc,
  ) async {
    final hProc = k32.openProcess(
      _processSetQuota | _processTerminate,
      0,
      proc.pid,
    );
    if (hProc == 0) {
      final err = k32.getLastError();
      if (await _didProcessExitImmediately(proc, err)) {
        return McpTransportException(
          code: SyscallErrorCode.eio,
          reason: 'MCP_SERVER_EXITED_EARLY',
          message: 'MCP server "${spec.name}" exited immediately on startup.',
        );
      }
      proc.kill(ProcessSignal.sigkill);
      return McpTransportException(
        code: SyscallErrorCode.eio,
        reason: 'OPEN_PROCESS_FAILED',
        message: 'OpenProcess failed for MCP "${spec.name}" (err=$err).',
        recoverable: false,
      );
    }

    final ok = k32.assignProcessToJobObject(hJob, hProc);
    final assignErr = ok == 0 ? k32.getLastError() : 0;
    k32.closeHandle(hProc);
    if (ok == 0) {
      if (await _didProcessExitImmediately(proc, assignErr)) {
        return McpTransportException(
          code: SyscallErrorCode.eio,
          reason: 'MCP_SERVER_EXITED_EARLY',
          message: 'MCP server "${spec.name}" exited immediately on startup.',
        );
      }
      proc.kill(ProcessSignal.sigkill);
      return McpTransportException(
        code: SyscallErrorCode.eio,
        reason: 'ASSIGN_JOB_OBJECT_FAILED',
        message:
            'AssignProcessToJobObject failed for MCP "${spec.name}" (err=$assignErr).',
        recoverable: false,
      );
    }
    return null;
  }

  Future<bool> _didProcessExitImmediately(Process proc, int win32Error) async {
    if (win32Error != _errorInvalidParameter &&
        win32Error != _errorAccessDenied) {
      return false;
    }
    try {
      await proc.exitCode.timeout(const Duration(milliseconds: 50));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void _handleStdoutLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      return;
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! Map) {
      return;
    }
    final msg = Map<String, dynamic>.from(decoded);
    final rawId = msg['id'];
    if (rawId is int) {
      final completer = _pendingRequests.remove(rawId);
      if (completer == null || completer.isCompleted) {
        return;
      }
      final err = msg['error'];
      if (err is Map) {
        final code = (err['code'] as num?)?.toInt();
        final message = (err['message'] as String?) ?? 'MCP JSON-RPC error';
        completer.completeError(
          McpTransportException(
            code: SyscallErrorCode.eprovider,
            reason: 'MCP_JSONRPC_ERROR',
            message: redactor.redactString(message),
            jsonRpcCode: code,
            data: err['data'],
          ),
        );
        return;
      }
      final result = msg['result'];
      if (result is Map) {
        completer.complete(Map<String, dynamic>.from(result));
      } else {
        completer.complete(<String, dynamic>{'value': result});
      }
      return;
    }

    final method = msg['method'];
    if (method is String && method.isNotEmpty) {
      if (!_notificationController.isClosed) {
        _notificationController.add(msg);
      }
    }
  }

  void _handleStderrLine(String rawLine) {
    final safeLine = redactor.redactString(rawLine);
    if (_stderrRing.length >= _maxStderrLines) {
      _stderrRing.removeFirst();
    }
    _stderrRing.addLast(safeLine);
  }

  void _handleDisconnect(String reasonMessage) {
    _closed = true;
    final pending = Map<int, Completer<Map<String, dynamic>>>.from(
      _pendingRequests,
    );
    _pendingRequests.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          McpTransportException(
            code: SyscallErrorCode.eio,
            reason: 'MCP_SERVER_DISCONNECTED',
            message: redactor.redactString(reasonMessage),
          ),
        );
      }
    }
  }

  Future<void> _writeJsonLine(Map<String, dynamic> payload) {
    final proc = _process;
    if (!isConnected || proc == null) {
      return Future<void>.error(
        McpTransportException(
          code: SyscallErrorCode.eio,
          reason: 'MCP_SERVER_DISCONNECTED',
          message: 'MCP server "${spec.name}" is not connected.',
        ),
      );
    }
    final encoded = '${jsonEncode(payload)}\n';
    _stdinWriteChain = _stdinWriteChain.then((_) async {
      if (!isConnected) {
        throw McpTransportException(
          code: SyscallErrorCode.eio,
          reason: 'MCP_SERVER_DISCONNECTED',
          message: 'MCP server "${spec.name}" disconnected before write.',
        );
      }
      proc.stdin.write(encoded);
      await proc.stdin.flush();
    });
    return _stdinWriteChain;
  }

  @override
  Future<Map<String, dynamic>> sendRequest(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
    CancellationToken? cancelToken,
  }) async {
    if (!isConnected) {
      throw McpTransportException(
        code: SyscallErrorCode.eio,
        reason: 'MCP_SERVER_DISCONNECTED',
        message: 'MCP server "${spec.name}" is disconnected.',
      );
    }
    if (cancelToken != null && cancelToken.isCancelled) {
      throw McpTransportException(
        code: SyscallErrorCode.ecancelled,
        reason: 'CANCELLED',
        message: 'MCP request "$method" cancelled before dispatch.',
      );
    }

    final id = ++_nextRequestId;
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    if (cancelToken != null) {
      unawaited(
        cancelToken.onCancel.then((_) async {
          final pending = _pendingRequests.remove(id);
          if (pending != null && !pending.isCompleted) {
            if (isConnected) {
              try {
                await sendNotification(
                  'notifications/cancelled',
                  params: <String, dynamic>{
                    'requestId': id,
                    'reason': cancelToken.reason ?? 'Cancelled',
                  },
                );
              } catch (_) {}
            }
            if (!pending.isCompleted) {
              pending.completeError(
                McpTransportException(
                  code: SyscallErrorCode.ecancelled,
                  reason: 'CANCELLED',
                  message: 'MCP request "$method" cancelled.',
                ),
              );
            }
          }
        }),
      );
    }

    try {
      await _writeJsonLine(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      });
    } catch (e) {
      _pendingRequests.remove(id);
      if (e is McpTransportException) {
        rethrow;
      }
      throw McpTransportException(
        code: SyscallErrorCode.eio,
        reason: 'MCP_WRITE_FAILED',
        message: 'Failed to send "$method" to MCP "${spec.name}": $e',
      );
    }

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingRequests.remove(id);
          throw McpTransportException(
            code: SyscallErrorCode.etimedout,
            reason: 'MCP_REQUEST_TIMEOUT',
            message:
                'MCP server "${spec.name}" timed out on "$method" after ${timeout.inMilliseconds}ms.',
          );
        },
      );
    } catch (e) {
      _pendingRequests.remove(id);
      rethrow;
    }
  }

  @override
  Future<void> sendNotification(
    String method, {
    Map<String, dynamic>? params,
  }) async {
    await _writeJsonLine(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': ?params,
    });
  }

  @override
  Future<void> close() async {
    if (_closed && _process == null && _hJob == 0) {
      return;
    }
    _closed = true;
    final proc = _process;
    _process = null;

    _handleDisconnect('MCP server "${spec.name}" closed.');

    if (proc != null) {
      try {
        await proc.stdin.close();
      } catch (_) {}

      var exited = false;
      try {
        await proc.exitCode.timeout(const Duration(milliseconds: 1500));
        exited = true;
      } on TimeoutException {
        exited = false;
      } catch (_) {
        exited = true;
      }

      if (!exited) {
        if (Platform.isWindows && _hJob != 0) {
          _k32.terminateJobObject(_hJob, 137);
        } else {
          proc.kill(ProcessSignal.sigkill);
        }
        try {
          await proc.exitCode.timeout(const Duration(milliseconds: 500));
        } catch (_) {}
      }
    }

    _closeJobHandle();
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    if (!_notificationController.isClosed) {
      await _notificationController.close();
    }
  }

  void _closeJobHandle() {
    if (Platform.isWindows && _hJob != 0) {
      _k32.closeHandle(_hJob);
      _hJob = 0;
    }
  }
}

/// High-level MCP client managing `2025-11-25` handshake, `tools/list` pagination,
/// `notifications/tools/list_changed` cache invalidation, and `tools/call` ([D-318], [D-319]).
class StdioMcpClient {
  StdioMcpClient({
    required this.spec,
    required McpTransport transport,
    SecretRedactor? redactor,
  })  : _transport = transport,
        redactor = redactor ?? SecretRedactor() {
    for (final envVar in spec.env) {
      this.redactor.registerSecret(envVar.value);
    }
    _notifSub = _transport.incomingNotifications.listen((msg) {
      if (msg['method'] == 'notifications/tools/list_changed') {
        _toolsCatalogStale = true;
      }
    });
  }

  factory StdioMcpClient.stdio({
    required McpServerSpec spec,
    required String workspaceHostRoot,
    SecretRedactor? redactor,
    Win32Kernel32? kernel32,
  }) {
    final effectiveRedactor = redactor ?? SecretRedactor();
    final transport = StdioMcpTransport(
      spec: spec,
      workspaceHostRoot: workspaceHostRoot,
      redactor: effectiveRedactor,
      kernel32: kernel32,
    );
    return StdioMcpClient(
      spec: spec,
      transport: transport,
      redactor: effectiveRedactor,
    );
  }

  static const Set<String> supportedProtocolVersions = <String>{
    '2025-11-25',
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  };
  static const int maxToolPages = 32;

  final McpServerSpec spec;
  final McpTransport _transport;
  final SecretRedactor redactor;
  StreamSubscription<Map<String, dynamic>>? _notifSub;

  bool _initialized = false;
  bool _toolsCatalogStale = false;
  String? _negotiatedProtocolVersion;
  List<McpToolDescriptor> _cachedTools = const <McpToolDescriptor>[];

  bool get isConnected => _initialized && _transport.isConnected;
  String? get negotiatedProtocolVersion => _negotiatedProtocolVersion;
  McpTransport get transport => _transport;
  List<McpToolDescriptor> get cachedTools => _cachedTools;

  /// Performs `initialize` -> `notifications/initialized` -> initial `tools/list` ([D-318]).
  Future<SyscallResult<void>> connect({
    Duration initializeTimeout = const Duration(seconds: 15),
  }) async {
    try {
      final t = _transport;
      if (t is StdioMcpTransport) {
        await t.start();
      }
      final initResult = await _transport.sendRequest(
        'initialize',
        params: const <String, dynamic>{
          'protocolVersion': '2025-11-25',
          'capabilities': <String, dynamic>{},
          'clientInfo': <String, dynamic>{
            'name': 'fm-agent-os',
            'version': '0.1.0',
          },
        },
        timeout: initializeTimeout,
      );

      final serverVersion = initResult['protocolVersion'] as String?;
      if (serverVersion != null &&
          !supportedProtocolVersions.contains(serverVersion)) {
        // Still allow forward-compatible dual-era servers if they responded to initialize,
        // unless version is completely missing.
        _negotiatedProtocolVersion = serverVersion;
      } else {
        _negotiatedProtocolVersion = serverVersion ?? '2025-11-25';
      }

      await _transport.sendNotification('notifications/initialized');
      _initialized = true;
      await refreshTools();
      return const SyscallResult<void>.success(null);
    } on McpTransportException catch (e) {
      return SyscallResult<void>.failure(e.toSyscallError(redactor: redactor));
    } catch (e) {
      return SyscallResult<void>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'MCP_CONNECT_FAILED',
          message: redactor.redactString(
            'Failed to initialize MCP server "${spec.name}": $e',
          ),
          recoverable: true,
        ),
      );
    }
  }

  /// Refreshes the tool catalog from the server using `nextCursor` pagination (max 32 pages).
  Future<List<McpToolDescriptor>> refreshTools() async {
    final collected = <McpToolDescriptor>[];
    String? cursor;
    for (var page = 0; page < maxToolPages; page++) {
      final res = await _transport.sendRequest(
        'tools/list',
        params: cursor == null
            ? const <String, dynamic>{}
            : <String, dynamic>{'cursor': cursor},
      );
      final rawTools = res['tools'];
      if (rawTools is List) {
        for (final item in rawTools) {
          if (item is! Map) {
            continue;
          }
          final name = item['name'];
          if (name is! String || name.trim().isEmpty) {
            continue;
          }
          final rawSchema = item['inputSchema'];
          final inputSchema = rawSchema is Map
              ? Map<String, dynamic>.from(rawSchema)
              : const <String, dynamic>{'type': 'object'};
          collected.add(
            McpToolDescriptor(
              serverName: spec.name,
              name: name.trim(),
              title: item['title'] as String?,
              description: item['description'] as String?,
              inputSchema: inputSchema,
            ),
          );
        }
      }
      final nextCursor = res['nextCursor'];
      if (nextCursor is String && nextCursor.isNotEmpty) {
        cursor = nextCursor;
      } else {
        break;
      }
    }
    _cachedTools = List<McpToolDescriptor>.unmodifiable(collected);
    _toolsCatalogStale = false;
    return _cachedTools;
  }

  /// Returns cached tools, refreshing if [refresh] is true or `tools/list_changed` arrived.
  Future<SyscallResult<List<McpToolDescriptor>>> listTools({
    bool refresh = false,
  }) async {
    if (!isConnected) {
      return SyscallResult<List<McpToolDescriptor>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'MCP_SERVER_DISCONNECTED',
          message: 'MCP server "${spec.name}" is disconnected.',
          recoverable: true,
        ),
      );
    }
    try {
      if (refresh || _toolsCatalogStale) {
        await refreshTools();
      }
      return SyscallResult<List<McpToolDescriptor>>.success(_cachedTools);
    } on McpTransportException catch (e) {
      return SyscallResult<List<McpToolDescriptor>>.failure(
        e.toSyscallError(redactor: redactor),
      );
    }
  }

  bool hasTool(String toolName) =>
      _cachedTools.any((t) => t.name == toolName);

  /// Invokes `tools/call` on [toolName] and returns a structured [McpCallOutcome].
  Future<SyscallResult<McpCallOutcome>> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    CancellationToken? cancelToken,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!isConnected) {
      return SyscallResult<McpCallOutcome>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'MCP_SERVER_DISCONNECTED',
          message: 'MCP server "${spec.name}" is disconnected.',
          recoverable: true,
        ),
      );
    }

    try {
      if (_toolsCatalogStale) {
        await refreshTools();
      }
      if (!hasTool(toolName)) {
        return SyscallResult<McpCallOutcome>.failure(
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'MCP_TOOL_NOT_FOUND',
            message:
                'Tool "$toolName" was not found on MCP server "${spec.name}".',
            recoverable: true,
          ),
        );
      }

      final result = await _transport.sendRequest(
        'tools/call',
        params: <String, dynamic>{
          'name': toolName,
          'arguments': arguments,
        },
        timeout: timeout,
        cancelToken: cancelToken,
      );

      final isError = (result['isError'] as bool?) ?? false;
      final rawContentList = <Map<String, dynamic>>[];
      final textParts = <String>[];

      final rawContent = result['content'];
      if (rawContent is List) {
        for (final item in rawContent) {
          if (item is Map) {
            final redactedBlock =
                redactor.redactJson(Map<String, dynamic>.from(item))
                    as Map<String, dynamic>;
            rawContentList.add(redactedBlock);
            final text = redactedBlock['text'];
            if (text is String && text.isNotEmpty) {
              textParts.add(text);
            } else if (redactedBlock.isNotEmpty) {
              textParts.add(jsonEncode(redactedBlock));
            }
          }
        }
      }

      final rawStructured = result['structuredContent'];
      final structured = rawStructured is Map
          ? redactor.redactJson(Map<String, dynamic>.from(rawStructured))
              as Map<String, dynamic>
          : null;

      final combinedText = textParts.isNotEmpty
          ? redactor.redactString(textParts.join('\n'))
          : (structured != null ? jsonEncode(structured) : '');

      return SyscallResult<McpCallOutcome>.success(
        McpCallOutcome(
          serverName: spec.name,
          toolName: toolName,
          isError: isError,
          contentText: combinedText,
          rawContent: rawContentList,
          structuredContent: structured,
        ),
      );
    } on McpTransportException catch (e) {
      return SyscallResult<McpCallOutcome>.failure(
        e.toSyscallError(redactor: redactor),
      );
    } catch (e) {
      return SyscallResult<McpCallOutcome>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'MCP_CALL_FAILED',
          message: redactor.redactString(
            'MCP call "${spec.name}:$toolName" failed: $e',
          ),
          recoverable: true,
        ),
      );
    }
  }

  Future<void> dispose() async {
    await _notifSub?.cancel();
    _notifSub = null;
    await _transport.close();
  }
}

/// Session-level manager owning all connected MCP server clients ([D-318], [D-319]).
class McpServerManager {
  McpServerManager({
    required this.workspaceHostRoot,
    SecretRedactor? redactor,
    Win32Kernel32? kernel32,
  })  : redactor = redactor ?? SecretRedactor(),
        _kernel32 = kernel32;

  final String workspaceHostRoot;
  final SecretRedactor redactor;
  final Win32Kernel32? _kernel32;

  final Map<String, StdioMcpClient> _clients = <String, StdioMcpClient>{};

  List<StdioMcpClient> get clients =>
      List<StdioMcpClient>.unmodifiable(_clients.values);

  StdioMcpClient? clientFor(String serverName) => _clients[serverName.trim()];

  /// Registers and connects all [specs] in order.
  ///
  /// Rejects non-`stdio` transports with `EINVAL: UNSUPPORTED_MCP_TRANSPORT`.
  Future<SyscallResult<void>> registerAndConnectAll(
    List<McpServerSpec> specs, {
    Duration initializeTimeout = const Duration(seconds: 15),
  }) async {
    for (final spec in specs) {
      for (final envVar in spec.env) {
        redactor.registerSecret(envVar.value);
      }
      if (spec.transportType.trim().toLowerCase() != 'stdio') {
        return SyscallResult<void>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'UNSUPPORTED_MCP_TRANSPORT',
            message:
                'MCP server "${spec.name}" uses unsupported transport "${spec.transportType}"; only "stdio" is supported.',
            recoverable: false,
          ),
        );
      }
    }

    for (final spec in specs) {
      final name = spec.name.trim();
      final existing = _clients.remove(name);
      if (existing != null) {
        await existing.dispose();
      }
      final client = StdioMcpClient.stdio(
        spec: spec,
        workspaceHostRoot: workspaceHostRoot,
        redactor: redactor,
        kernel32: _kernel32,
      );
      final connRes = await client.connect(
        initializeTimeout: initializeTimeout,
      );
      if (!connRes.ok) {
        await client.dispose();
        return connRes;
      }
      _clients[name] = client;
    }
    return const SyscallResult<void>.success(null);
  }

  /// Registers a pre-built [StdioMcpClient] (useful for custom [McpTransport] tests).
  void registerClientForTesting(StdioMcpClient client) {
    _clients[client.spec.name.trim()] = client;
  }

  /// Renders a lightweight Segment 2 summary line without mutating Segment 0 ([D-319]).
  String renderDynamicContextSummary() {
    final active = _clients.values.where((c) => c.isConnected).toList();
    if (active.isEmpty) {
      return '';
    }
    final parts = active
        .map((c) => '${c.spec.name} (${c.cachedTools.length} tools)')
        .join(', ');
    return '[MCP Servers connected: $parts — use sys_mcp_list_tools / sys_mcp_call]';
  }

  /// Cleanly shuts down all connected MCP servers and ensures 0 lingering subprocesses.
  Future<void> dispose() async {
    final toDispose = _clients.values.toList(growable: false);
    _clients.clear();
    await Future.wait(toDispose.map((c) => c.dispose()));
  }
}

/// Builds the fixed Segment 0 [SyscallToolSchema] for `sys_mcp_list_tools` ([D-319]).
SyscallToolSchema buildMcpListToolsToolSchema() {
  return SyscallToolSchema(
    name: 'sys_mcp_list_tools',
    description:
        'List available tools from connected stdio MCP servers. '
        'Returns server names, tool names, descriptions, and inputSchema.',
    parametersJsonSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'server': <String, dynamic>{
          'type': 'string',
          'description': 'Optional MCP server name to filter by.',
        },
        'refresh': <String, dynamic>{
          'type': 'boolean',
          'description': 'Whether to re-fetch tools/list from the server.',
        },
      },
      'additionalProperties': false,
    },
  );
}

/// Builds the fixed Segment 0 [SyscallToolSchema] for `sys_mcp_call` ([D-319]).
SyscallToolSchema buildMcpCallToolSchema() {
  return SyscallToolSchema(
    name: 'sys_mcp_call',
    description:
        'Invoke a tool exposed by a connected stdio MCP server (requires Ring 2 user approval).',
    parametersJsonSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'server': <String, dynamic>{
          'type': 'string',
          'description': 'Connected MCP server name.',
        },
        'tool': <String, dynamic>{
          'type': 'string',
          'description': 'Tool name exposed by the MCP server.',
        },
        'arguments': <String, dynamic>{
          'type': 'object',
          'description': 'JSON object arguments to pass to the MCP tool.',
        },
      },
      'required': <String>['server', 'tool'],
      'additionalProperties': false,
    },
  );
}

/// Builds fixed Segment 0 [SyscallToolSchema] entries for MCP ([D-319]).
List<SyscallToolSchema> buildMcpToolSchemas() => <SyscallToolSchema>[
  buildMcpListToolsToolSchema(),
  buildMcpCallToolSchema(),
];

/// Builds `sys_mcp_list_tools` and `sys_mcp_call` [SyscallDefinition]s ([D-319]).
List<SyscallDefinition> buildMcpSyscallDefinitions({
  required McpServerManager manager,
  SecretRedactor? redactor,
}) {
  final effectiveRedactor = redactor ?? manager.redactor;

  final listToolsDef = SyscallDefinition(
    name: 'sys_mcp_list_tools',
    requiredRight: CapRight.mcpCall,
    kind: 'read',
    applyIoCap: true,
    validateArgs: (args) {
      final server = args['server'];
      if (server != null && (server is! String || server.trim().isEmpty)) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_SERVER_NAME',
          message: 'Argument "server" must be a non-empty string if provided.',
          recoverable: true,
        );
      }
      final refresh = args['refresh'];
      if (refresh != null && refresh is! bool) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_REFRESH_FLAG',
          message: 'Argument "refresh" must be a boolean if provided.',
          recoverable: true,
        );
      }
      return null;
    },
    evaluatePolicy: (_, _) async => RingDecision.allow,
    handler: (execContext) async {
      final serverFilter = (execContext.args['server'] as String?)?.trim();
      final refresh = (execContext.args['refresh'] as bool?) ?? false;

      if (serverFilter != null) {
        final client = manager.clientFor(serverFilter);
        if (client == null) {
          return SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.enoent,
              reason: 'MCP_SERVER_NOT_FOUND',
              message: 'MCP server "$serverFilter" is not registered.',
              recoverable: true,
            ),
          );
        }
        final toolsRes = await client.listTools(refresh: refresh);
        if (!toolsRes.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(toolsRes.error!);
        }
        final toolsJson = toolsRes.value!
            .map((t) => t.toJson())
            .toList(growable: false);
        return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
          'servers': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': client.spec.name,
              'connected': client.isConnected,
              'protocolVersion': client.negotiatedProtocolVersion,
              'toolCount': toolsJson.length,
            },
          ],
          'tools': toolsJson,
        });
      }

      final servers = <Map<String, dynamic>>[];
      final allTools = <Map<String, dynamic>>[];
      for (final client in manager.clients) {
        final toolsRes = await client.listTools(refresh: refresh);
        if (!toolsRes.ok) {
          return SyscallResult<Map<String, dynamic>>.failure(toolsRes.error!);
        }
        final tools = toolsRes.value!;
        servers.add(<String, dynamic>{
          'name': client.spec.name,
          'connected': client.isConnected,
          'protocolVersion': client.negotiatedProtocolVersion,
          'toolCount': tools.length,
        });
        for (final tool in tools) {
          allTools.add(tool.toJson());
        }
      }

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'servers': servers,
        'tools': allTools,
      });
    },
  );

  final callToolDef = SyscallDefinition(
    name: 'sys_mcp_call',
    requiredRight: CapRight.mcpCall,
    kind: 'other',
    applyIoCap: true,
    cappedTextFields: const <String>['content'],
    validateArgs: (args) {
      final server = args['server'];
      if (server is! String || server.trim().isEmpty) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'MISSING_MCP_SERVER',
          message: 'sys_mcp_call requires a non-empty "server" string.',
          recoverable: true,
        );
      }
      final tool = args['tool'];
      if (tool is! String || tool.trim().isEmpty) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'MISSING_MCP_TOOL',
          message: 'sys_mcp_call requires a non-empty "tool" string.',
          recoverable: true,
        );
      }
      final arguments = args['arguments'];
      if (arguments != null && arguments is! Map) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_MCP_ARGUMENTS',
          message: 'sys_mcp_call "arguments" must be a JSON object.',
          recoverable: true,
        );
      }
      return null;
    },
    checkPreconditions: (pcb, args) async {
      final serverName = (args['server'] as String).trim();
      final toolName = (args['tool'] as String).trim();
      final client = manager.clientFor(serverName);
      if (client == null) {
        return SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'MCP_SERVER_NOT_FOUND',
          message: 'MCP server "$serverName" is not registered.',
          recoverable: true,
        );
      }
      if (!client.isConnected) {
        return SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'MCP_SERVER_DISCONNECTED',
          message: 'MCP server "$serverName" is disconnected.',
          recoverable: true,
        );
      }
      final toolsRes = await client.listTools();
      if (!toolsRes.ok) {
        return toolsRes.error;
      }
      if (!client.hasTool(toolName)) {
        return SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'MCP_TOOL_NOT_FOUND',
          message:
              'Tool "$toolName" was not found on MCP server "$serverName".',
          recoverable: true,
        );
      }
      return null;
    },
    evaluatePolicy: (_, _) async => RingDecision.askUser,
    approvalSignatureBuilder: (args) {
      final server = (args['server'] as String).trim();
      final tool = (args['tool'] as String).trim();
      return 'mcp:$server:$tool';
    },
    approvalPreviewBuilder: (hookCtx) async {
      final server = (hookCtx.args['server'] as String).trim();
      final tool = (hookCtx.args['tool'] as String).trim();
      final rawArgs = hookCtx.args['arguments'];
      final redactedArgs = rawArgs is Map
          ? effectiveRedactor.redactJson(Map<String, dynamic>.from(rawArgs))
          : const <String, dynamic>{};
      return ApprovalPreview(
        title: 'Invoke MCP tool $server:$tool',
        kind: 'mcp_call',
        content: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'json',
            'server': server,
            'tool': tool,
            'arguments': redactedArgs,
          },
        ],
        metadata: <String, dynamic>{
          'server': server,
          'tool': tool,
        },
      );
    },
    resultSummaryBuilder: (args, result) {
      if (!result.ok || result.value == null) {
        return null;
      }
      final val = result.value!;
      return <String, dynamic>{
        'server': val['server'],
        'tool': val['tool'],
        'isToolError': val['isError'] ?? false,
      };
    },
    handler: (execContext) async {
      final serverName = (execContext.args['server'] as String).trim();
      final toolName = (execContext.args['tool'] as String).trim();
      final rawArgs = execContext.args['arguments'];
      final arguments = rawArgs is Map
          ? Map<String, dynamic>.from(rawArgs)
          : const <String, dynamic>{};

      final client = manager.clientFor(serverName);
      if (client == null) {
        return SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'MCP_SERVER_NOT_FOUND',
            message: 'MCP server "$serverName" is not registered.',
            recoverable: true,
          ),
        );
      }

      final outcomeRes = await client.callTool(
        toolName,
        arguments,
        cancelToken: execContext.context.cancelToken,
      );
      if (!outcomeRes.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(outcomeRes.error!);
      }

      return SyscallResult<Map<String, dynamic>>.success(
        outcomeRes.value!.toJson(),
      );
    },
  );

  return <SyscallDefinition>[listToolsDef, callToolDef];
}
