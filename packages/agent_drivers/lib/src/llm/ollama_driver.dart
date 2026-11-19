import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;

import 'llm_env_loader.dart';

/// Native `/api/chat` NDJSON streaming driver for `local-ollama` and `ollama-cloud` ([D-008], OM-07).
class OllamaDriver implements LlmDriver {
  OllamaDriver({
    required this.providerId,
    String? baseUrl,
    String? apiKey,
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
    this.keepAlive = '15m',
    this.requestTimeout = const Duration(seconds: 120),
  })  : assert(
          providerId == LlmProviderId.localOllama ||
              providerId == LlmProviderId.ollamaCloud,
          'OllamaDriver supports only local-ollama and ollama-cloud.',
        ),
        _explicitBaseUrl = baseUrl,
        _explicitApiKey = apiKey,
        _envLoader = envLoader,
        _redactor = redactor ?? envLoader?.redactor ?? SecretRedactor(),
        _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null {
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      _redactor.registerSecret(apiKey);
    }
  }

  /// Creates a driver targeting `local-ollama`.
  factory OllamaDriver.local({
    String? baseUrl,
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
    String keepAlive = '15m',
    Duration requestTimeout = const Duration(seconds: 120),
  }) {
    return OllamaDriver(
      providerId: LlmProviderId.localOllama,
      baseUrl: baseUrl,
      envLoader: envLoader,
      redactor: redactor,
      httpClient: httpClient,
      keepAlive: keepAlive,
      requestTimeout: requestTimeout,
    );
  }

  /// Creates a driver targeting `ollama-cloud`.
  factory OllamaDriver.cloud({
    String? baseUrl,
    String? apiKey,
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
    String keepAlive = '15m',
    Duration requestTimeout = const Duration(seconds: 120),
  }) {
    return OllamaDriver(
      providerId: LlmProviderId.ollamaCloud,
      baseUrl: baseUrl,
      apiKey: apiKey,
      envLoader: envLoader,
      redactor: redactor,
      httpClient: httpClient,
      keepAlive: keepAlive,
      requestTimeout: requestTimeout,
    );
  }

  static const String defaultLocalBaseUrl = 'http://localhost:11434';
  static const String defaultCloudBaseUrl = 'https://ollama.com';

  @override
  final LlmProviderId providerId;

  final String? _explicitBaseUrl;
  final String? _explicitApiKey;
  final LlmEnvLoader? _envLoader;
  final SecretRedactor _redactor;
  final http.Client _httpClient;
  final bool _ownsClient;

  /// Keep-alive duration sent to Ollama to prevent premature VRAM KV-cache eviction.
  final String keepAlive;

  /// Timeout waiting for HTTP response headers / connection.
  final Duration requestTimeout;

  /// Normalizes an Ollama base URL (e.g. `OLLAMA_HOST=http://192.168.0.5:11434/v1` or `0.0.0.0` / `[::]`)
  /// into the native `/api/chat` endpoint URI ([D-008], OM-07).
  static Uri normalizeChatEndpoint(String rawBaseUrl) {
    var trimmed = rawBaseUrl.trim();
    if (trimmed.isEmpty) {
      trimmed = defaultLocalBaseUrl;
    }

    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed);
    if (!hasScheme) {
      if (trimmed == '::') {
        trimmed = '[::]';
      }
      trimmed = 'http://$trimmed';
    }

    var uri = Uri.parse(trimmed);
    final hostLower = uri.host.toLowerCase();
    if (hostLower == '0.0.0.0' || hostLower == '::' || hostLower == '[::]') {
      uri = uri.replace(
        host: '127.0.0.1',
        port: (!hasScheme && !uri.hasPort) ? 11434 : uri.port,
      );
    }

    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.endsWith('/v1')) {
      path = path.substring(0, path.length - '/v1'.length);
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.endsWith('/api/chat')) {
      path = '$path/api/chat';
    }

    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    );
  }

  /// Resolves the target `/api/chat` endpoint URI for this driver.
  Uri resolveEndpoint() {
    if (_explicitBaseUrl != null && _explicitBaseUrl.trim().isNotEmpty) {
      return normalizeChatEndpoint(_explicitBaseUrl);
    }
    if (providerId == LlmProviderId.ollamaCloud) {
      final envCloudUrl = _envLoader?.get('OLLAMA_CLOUD_HOST') ??
          Platform.environment['OLLAMA_CLOUD_HOST'];
      return normalizeChatEndpoint(
        (envCloudUrl != null && envCloudUrl.trim().isNotEmpty)
            ? envCloudUrl
            : defaultCloudBaseUrl,
      );
    }
    final envHost =
        _envLoader?.get('OLLAMA_HOST') ?? Platform.environment['OLLAMA_HOST'];
    return normalizeChatEndpoint(
      (envHost != null && envHost.trim().isNotEmpty)
          ? envHost
          : defaultLocalBaseUrl,
    );
  }

  String? _resolveApiKey() {
    if (_explicitApiKey != null && _explicitApiKey.trim().isNotEmpty) {
      final key = _explicitApiKey.trim();
      _redactor.registerSecret(key);
      return key;
    }
    final fromEnv = _envLoader != null
        ? (_envLoader.get('OLLAMA_API_KEY') ??
            _envLoader.get('OLLAMA_CLOUD_API_KEY'))
        : (Platform.environment['OLLAMA_API_KEY'] ??
            Platform.environment['OLLAMA_CLOUD_API_KEY']);
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      final key = fromEnv.trim();
      _redactor.registerSecret(key);
      return key;
    }
    return null;
  }

  /// Builds the native Ollama `/api/chat` JSON payload from a canonical [LlmChatRequest].
  ///
  /// Intentionally never emits per-turn dynamic `options.num_ctx` ([D-209] §4.2) so Ollama
  /// does not reload the model or evict its VRAM KV cache between turns.
  Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
    final messages = <Map<String, dynamic>>[];
    for (final msg in request.prompt.messages) {
      switch (msg.role) {
        case ProjectedRole.system:
          messages.add(<String, dynamic>{
            'role': 'system',
            'content': msg.content,
          });
        case ProjectedRole.user:
          messages.add(<String, dynamic>{
            'role': 'user',
            'content': msg.content,
          });
        case ProjectedRole.assistant:
          final entry = <String, dynamic>{
            'role': 'assistant',
            'content': msg.content,
          };
          if (msg.thoughtText != null && msg.thoughtText!.isNotEmpty) {
            entry['thinking'] = msg.thoughtText;
          }
          if (msg.toolCalls.isNotEmpty) {
            entry['tool_calls'] = msg.toolCalls
                .map(
                  (tc) => <String, dynamic>{
                    'id': tc.id,
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': tc.name,
                      'arguments': tc.arguments,
                    },
                  },
                )
                .toList(growable: false);
          }
          messages.add(entry);
        case ProjectedRole.tool:
          messages.add(<String, dynamic>{
            'role': 'tool',
            'content': msg.content,
            'tool_name': msg.toolName ?? '',
            if (msg.toolCallId != null) 'tool_call_id': msg.toolCallId,
          });
      }
    }

    final options = <String, dynamic>{
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) 'num_predict': request.maxTokens,
    };

    return <String, dynamic>{
      'model': request.model.modelName,
      'messages': messages,
      if (request.prompt.tools.isNotEmpty)
        'tools': request.prompt.tools
            .map((t) => t.toJson())
            .toList(growable: false),
      'stream': request.stream,
      if (keepAlive.trim().isNotEmpty) 'keep_alive': keepAlive,
      if (options.isNotEmpty) 'options': options,
    };
  }

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    if (request.model.provider != providerId) {
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'PROVIDER_MISMATCH',
          message:
              'OllamaDriver(${providerId.id}) received model for ${request.model.provider.id}.',
        ),
      );
    }

    if (cancelToken?.isCancelled ?? false) {
      throw const LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.ecancelled,
          reason: 'CANCELLED',
          message: 'LLM request cancelled before dispatch.',
          recoverable: true,
        ),
      );
    }

    String? apiKey;
    if (providerId == LlmProviderId.ollamaCloud) {
      apiKey = _resolveApiKey();
      if (apiKey == null) {
        throw const LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.eprovider,
            reason: 'MISSING_API_KEY',
            message: 'OLLAMA_API_KEY is not configured for ollama-cloud.',
            recoverable: true,
            hint: 'Set OLLAMA_API_KEY in environment or .agent_os/.env.',
          ),
        );
      }
    }

    final endpoint = resolveEndpoint();
    final endpointStr = endpoint.toString();
    final bodyJson = jsonEncode(buildRequestBody(request));
    final httpRequest = http.Request('POST', endpoint)
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'application/x-ndjson, application/json'
      ..body = bodyJson;

    if (apiKey != null) {
      httpRequest.headers['Authorization'] = 'Bearer $apiKey';
    }

    final stopwatch = Stopwatch()..start();
    final http.StreamedResponse response;
    try {
      response = await _sendWithCancellation(httpRequest, cancelToken)
          .timeout(requestTimeout);
    } on LlmDriverException {
      rethrow;
    } on TimeoutException {
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.etimedout,
          reason: 'PROVIDER_TIMEOUT',
          message:
              'Ollama request to $endpointStr timed out after ${requestTimeout.inMilliseconds}ms.',
          recoverable: true,
        ),
      );
    } catch (e) {
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'CONNECTION_FAILED',
          message: _redactor.redactString(
            'Failed to connect to Ollama ($endpointStr): $e',
          ),
          recoverable: true,
        ),
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String errorBody = '';
      try {
        errorBody = await response.stream
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        errorBody = '';
      }
      final reason = switch (response.statusCode) {
        401 || 403 => 'UNAUTHORIZED',
        429 => 'RATE_LIMITED',
        _ => 'HTTP_${response.statusCode}',
      };
      final redactedBody = _redactor.redactString(errorBody).trim();
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: reason,
          message: redactedBody.isEmpty
              ? 'Ollama HTTP ${response.statusCode} from $endpointStr.'
              : 'Ollama HTTP ${response.statusCode}: $redactedBody',
          recoverable: response.statusCode == 429 || response.statusCode >= 500,
          details: <String, dynamic>{'statusCode': response.statusCode},
        ),
      );
    }

    final contentBuffer = StringBuffer();
    final thoughtBuffer = StringBuffer();
    final collectedToolCalls = <LlmToolCallSpec>[];
    int? ttftMs;
    var promptTokens = 0;
    var completionTokens = 0;
    int? cachedTokens;
    String? finishReason;
    var sawDone = false;

    final lineStream =
        response.stream.transform(utf8.decoder).transform(const LineSplitter());

    await for (final rawLine in _withStreamCancellation(lineStream, cancelToken)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }

      final Map<String, dynamic> chunk;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Expected JSON object chunk.');
        }
        chunk = decoded;
      } on FormatException catch (e) {
        throw LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.eprovider,
            reason: 'INVALID_RESPONSE_FORMAT',
            message: _redactor.redactString(
              'Invalid NDJSON chunk from Ollama: $e',
            ),
            recoverable: true,
          ),
        );
      }

      if (chunk['error'] != null) {
        throw LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.eprovider,
            reason: 'PROVIDER_ERROR',
            message: _redactor.redactString(chunk['error'].toString()),
            recoverable: true,
          ),
        );
      }

      final message = chunk['message'];
      if (message is Map<String, dynamic>) {
        final thinking = message['thinking'];
        if (thinking is String && thinking.isNotEmpty) {
          ttftMs ??= stopwatch.elapsedMilliseconds;
          thoughtBuffer.write(thinking);
          yield LlmThoughtDelta(thinking);
        }

        final content = message['content'];
        if (content is String && content.isNotEmpty) {
          ttftMs ??= stopwatch.elapsedMilliseconds;
          contentBuffer.write(content);
          yield LlmTextDelta(content);
        }

        final rawToolCalls = message['tool_calls'];
        if (rawToolCalls is List) {
          for (final item in rawToolCalls) {
            if (item is! Map) {
              continue;
            }
            ttftMs ??= stopwatch.elapsedMilliseconds;
            final tcMap = Map<String, dynamic>.from(item);
            final fnRaw = tcMap['function'];
            final fnMap = fnRaw is Map
                ? Map<String, dynamic>.from(fnRaw)
                : const <String, dynamic>{};
            final name = (fnMap['name'] as String?) ?? '';
            final args = _decodeArguments(fnMap['arguments']);
            final rawId = (tcMap['id'] as String?)?.trim();
            final id = (rawId != null && rawId.isNotEmpty)
                ? rawId
                : 'call_${collectedToolCalls.length + 1}';

            final spec = LlmToolCallSpec(
              id: id,
              name: name,
              arguments: args,
            );
            collectedToolCalls.add(spec);
            yield LlmToolCallEvent(spec);
          }
        }
      }

      if (chunk['done'] == true) {
        sawDone = true;
        ttftMs ??= stopwatch.elapsedMilliseconds;
        promptTokens = (chunk['prompt_eval_count'] as num?)?.toInt() ?? 0;
        completionTokens = (chunk['eval_count'] as num?)?.toInt() ?? 0;
        final cached = chunk['prompt_eval_cached_count'];
        if (cached is num) {
          cachedTokens = cached.toInt();
        }
        final doneReason = chunk['done_reason'];
        if (doneReason is String && doneReason.isNotEmpty) {
          finishReason = doneReason;
        }
      }
    }

    if (!sawDone) {
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'INCOMPLETE_STREAM',
          message: 'Ollama stream from $endpointStr ended before done=true.',
          recoverable: true,
        ),
      );
    }

    stopwatch.stop();
    final resolvedFinishReason = collectedToolCalls.isNotEmpty
        ? 'tool_calls'
        : (finishReason ?? 'stop');

    yield LlmDoneEvent(
      LlmChatResponse(
        content: contentBuffer.toString(),
        thoughtText: thoughtBuffer.isEmpty ? null : thoughtBuffer.toString(),
        toolCalls: collectedToolCalls,
        finishReason: resolvedFinishReason,
        endpoint: endpointStr,
        usage: LlmUsageTelemetry(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          cachedTokens: cachedTokens,
          ttftMs: ttftMs,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      ),
    );
  }

  /// Releases the internal HTTP client if owned by this driver.
  void close() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }

  Future<http.StreamedResponse> _sendWithCancellation(
    http.Request request,
    CancellationToken? cancelToken,
  ) {
    final sendFuture = _httpClient.send(request);
    if (cancelToken == null) {
      return sendFuture;
    }
    return Future.any<http.StreamedResponse>(<Future<http.StreamedResponse>>[
      sendFuture,
      cancelToken.onCancel.then<http.StreamedResponse>((_) {
        throw const LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'CANCELLED',
            message: 'Ollama request cancelled while awaiting response.',
            recoverable: true,
          ),
        );
      }),
    ]);
  }

  Stream<String> _withStreamCancellation(
    Stream<String> source,
    CancellationToken? cancelToken,
  ) {
    if (cancelToken == null) {
      return source;
    }
    late final StreamController<String> controller;
    StreamSubscription<String>? sub;
    var cancelledByToken = false;

    controller = StreamController<String>(
      onListen: () {
        if (cancelToken.isCancelled) {
          controller.addError(
            const LlmDriverException(
              SyscallError(
                code: SyscallErrorCode.ecancelled,
                reason: 'CANCELLED',
                message: 'Ollama stream cancelled.',
                recoverable: true,
              ),
            ),
          );
          controller.close();
          return;
        }
        sub = source.listen(
          controller.add,
          onError: (Object error, StackTrace stack) {
            if (!controller.isClosed) {
              controller.addError(
                LlmDriverException(
                  SyscallError(
                    code: SyscallErrorCode.eprovider,
                    reason: 'STREAM_READ_ERROR',
                    message:
                        _redactor.redactString('Ollama stream error: $error'),
                    recoverable: true,
                  ),
                ),
                stack,
              );
            }
          },
          onDone: () {
            if (!cancelledByToken && !controller.isClosed) {
              controller.close();
            }
          },
          cancelOnError: true,
        );
        cancelToken.onCancel.then((_) async {
          cancelledByToken = true;
          await sub?.cancel();
          if (!controller.isClosed) {
            controller.addError(
              const LlmDriverException(
                SyscallError(
                  code: SyscallErrorCode.ecancelled,
                  reason: 'CANCELLED',
                  message: 'Ollama stream cancelled.',
                  recoverable: true,
                ),
              ),
            );
            await controller.close();
          }
        });
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );

    return controller.stream;
  }

  Map<String, dynamic> _decodeArguments(Object? raw) {
    if (raw == null) {
      return const <String, dynamic>{};
    }
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return const <String, dynamic>{};
      }
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    }
    throw const FormatException('Tool arguments must be a JSON object.');
  }
}
