import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;

import 'llm_env_loader.dart';

/// OpenRouter `/api/v1/chat/completions` SSE streaming driver ([D-009]).
///
/// Implements:
/// - `x-session-id` / `session_id` Provider Sticky Routing
/// - Wire-only `cache_control: {"type": "ephemeral"}` injection (max 2 breakpoints) for `anthropic/` models
/// - Chunked SSE `delta.tool_calls[index].function.arguments` assembly
/// - `cached_tokens`, `cache_write_tokens`, `costMicroUsd`, and signed `cacheDiscountUsd` extraction
class OpenRouterDriver implements LlmDriver {
  OpenRouterDriver({
    String? baseUrl,
    String? apiKey,
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
    this.httpReferer,
    this.xTitle = 'FM Agent OS',
    this.requestTimeout = const Duration(seconds: 120),
  })  : _explicitBaseUrl = baseUrl,
        _explicitApiKey = apiKey,
        _envLoader = envLoader,
        _redactor = redactor ?? envLoader?.redactor ?? SecretRedactor(),
        _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null {
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      _redactor.registerSecret(apiKey);
    }
  }

  static const String defaultBaseUrl = 'https://openrouter.ai/api/v1';

  @override
  LlmProviderId get providerId => LlmProviderId.openRouter;

  final String? _explicitBaseUrl;
  final String? _explicitApiKey;
  final LlmEnvLoader? _envLoader;
  final SecretRedactor _redactor;
  final http.Client _httpClient;
  final bool _ownsClient;

  final String? httpReferer;
  final String? xTitle;
  final Duration requestTimeout;

  /// Resolves the `/chat/completions` endpoint URI.
  Uri resolveEndpoint() {
    var raw = (_explicitBaseUrl != null && _explicitBaseUrl.trim().isNotEmpty)
        ? _explicitBaseUrl.trim()
        : (_envLoader?.get('OPENROUTER_BASE_URL') ??
            Platform.environment['OPENROUTER_BASE_URL'] ??
            defaultBaseUrl);

    if (raw.isEmpty) {
      raw = defaultBaseUrl;
    }
    var uri = Uri.parse(raw);
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.endsWith('/chat/completions')) {
      return uri.replace(path: path);
    }
    if (path.endsWith('/api/v1') || path.endsWith('/v1')) {
      return uri.replace(path: '$path/chat/completions');
    }
    return uri.replace(path: '$path/api/v1/chat/completions');
  }

  String? _resolveApiKey() {
    if (_explicitApiKey != null && _explicitApiKey.trim().isNotEmpty) {
      final key = _explicitApiKey.trim();
      _redactor.registerSecret(key);
      return key;
    }
    final fromEnv = _envLoader?.get('OPENROUTER_API_KEY') ??
        Platform.environment['OPENROUTER_API_KEY'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      final key = fromEnv.trim();
      _redactor.registerSecret(key);
      return key;
    }
    return null;
  }

  /// Builds the OpenRouter request headers including Sticky Routing `x-session-id` ([D-009]).
  Map<String, String> buildHeaders(
    LlmChatRequest request, {
    required String apiKey,
  }) {
    return <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream, application/json',
      'Authorization': 'Bearer $apiKey',
      'x-session-id': request.sessionUuid,
      if (httpReferer != null && httpReferer!.isNotEmpty)
        'HTTP-Referer': httpReferer!,
      if (xTitle != null && xTitle!.isNotEmpty) 'X-Title': xTitle!,
    };
  }

  /// Builds the OpenRouter `/chat/completions` JSON payload ([D-009]).
  ///
  /// Injects `cache_control: {"type": "ephemeral"}` at most twice (Segment 0 and last
  /// non-empty Segment 1 message) strictly when `modelName` starts with `anthropic/`.
  Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
    final isAnthropic = request.model.modelName.startsWith('anthropic/');
    final msgs = request.prompt.messages;

    int? segment0TargetIdx;
    int? segment1TargetIdx;
    if (isAnthropic) {
      for (var i = 0; i < msgs.length; i++) {
        if (msgs[i].segmentIndex == 0 && msgs[i].content.isNotEmpty) {
          segment0TargetIdx ??= i;
        } else if (msgs[i].segmentIndex == 1 && msgs[i].content.isNotEmpty) {
          segment1TargetIdx = i;
        }
      }
    }

    final encodedMessages = <Map<String, dynamic>>[];
    for (var i = 0; i < msgs.length; i++) {
      final msg = msgs[i];
      final addCacheControl =
          isAnthropic && (i == segment0TargetIdx || i == segment1TargetIdx);
      final Object wireContent = addCacheControl
          ? <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'text': msg.content,
                'cache_control': <String, dynamic>{'type': 'ephemeral'},
              },
            ]
          : msg.content;

      switch (msg.role) {
        case ProjectedRole.system:
          encodedMessages.add(<String, dynamic>{
            'role': 'system',
            'content': wireContent,
          });
        case ProjectedRole.user:
          encodedMessages.add(<String, dynamic>{
            'role': 'user',
            'content': wireContent,
          });
        case ProjectedRole.assistant:
          final entry = <String, dynamic>{
            'role': 'assistant',
            'content': wireContent,
          };
          if (msg.toolCalls.isNotEmpty) {
            entry['tool_calls'] = msg.toolCalls
                .map(
                  (tc) => <String, dynamic>{
                    'id': tc.id,
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': tc.name,
                      'arguments': jsonEncode(tc.arguments),
                    },
                  },
                )
                .toList(growable: false);
          }
          if (msg.rawReasoningDetails != null) {
            entry['reasoning_details'] = msg.rawReasoningDetails;
          }
          encodedMessages.add(entry);
        case ProjectedRole.tool:
          encodedMessages.add(<String, dynamic>{
            'role': 'tool',
            'tool_call_id': msg.toolCallId ?? '',
            if (msg.toolName != null && msg.toolName!.isNotEmpty)
              'name': msg.toolName,
            'content': wireContent,
          });
      }
    }

    return <String, dynamic>{
      'model': request.model.modelName,
      'session_id': request.sessionUuid,
      'messages': encodedMessages,
      if (request.prompt.tools.isNotEmpty)
        'tools': request.prompt.tools
            .map((t) => t.toJson())
            .toList(growable: false),
      'stream': request.stream,
      if (request.stream)
        'stream_options': const <String, dynamic>{'include_usage': true},
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) 'max_tokens': request.maxTokens,
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
              'OpenRouterDriver received model for ${request.model.provider.id}.',
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

    final apiKey = _resolveApiKey();
    if (apiKey == null) {
      throw const LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'MISSING_API_KEY',
          message: 'OPENROUTER_API_KEY is not configured for openrouter.',
          recoverable: true,
          hint: 'Set OPENROUTER_API_KEY in environment or .agent_os/.env.',
        ),
      );
    }

    final endpoint = resolveEndpoint();
    final endpointStr = endpoint.toString();
    final httpRequest = http.Request('POST', endpoint)
      ..headers.addAll(buildHeaders(request, apiKey: apiKey))
      ..body = jsonEncode(buildRequestBody(request));

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
              'OpenRouter request to $endpointStr timed out after ${requestTimeout.inMilliseconds}ms.',
          recoverable: true,
        ),
      );
    } catch (e) {
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'CONNECTION_FAILED',
          message: _redactor.redactString(
            'Failed to connect to OpenRouter ($endpointStr): $e',
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
              ? 'OpenRouter HTTP ${response.statusCode} from $endpointStr.'
              : 'OpenRouter HTTP ${response.statusCode}: $redactedBody',
          recoverable: response.statusCode == 429 || response.statusCode >= 500,
          details: <String, dynamic>{'statusCode': response.statusCode},
        ),
      );
    }

    final contentBuffer = StringBuffer();
    final thoughtBuffer = StringBuffer();
    final pendingToolCalls = <int, _PendingToolCall>{};
    final collectedReasoningDetails = <dynamic>[];
    Object? singleReasoningDetails;

    int? ttftMs;
    var promptTokens = 0;
    var completionTokens = 0;
    int? totalTokens;
    int? cachedTokens;
    int? cacheWriteTokens;
    int? costMicroUsd;
    double? cacheDiscountUsd;
    String? finishReason;

    if (!request.stream) {
      final rawJson = await response.stream.transform(utf8.decoder).join();
      final Map<String, dynamic> decoded;
      try {
        final parsed = jsonDecode(rawJson);
        if (parsed is! Map<String, dynamic>) {
          throw const FormatException('Expected JSON object.');
        }
        decoded = parsed;
      } on FormatException catch (e) {
        throw LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.eprovider,
            reason: 'INVALID_RESPONSE_FORMAT',
            message: _redactor.redactString(
              'Invalid JSON response from OpenRouter: $e',
            ),
            recoverable: true,
          ),
        );
      }

      if (decoded['error'] != null) {
        throw LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.eprovider,
            reason: 'PROVIDER_ERROR',
            message: _redactor.redactString(decoded['error'].toString()),
            recoverable: true,
          ),
        );
      }

      ttftMs = stopwatch.elapsedMilliseconds;
      final choices = decoded['choices'];
      if (choices is List && choices.isNotEmpty && choices.first is Map) {
        final choice = Map<String, dynamic>.from(choices.first as Map);
        finishReason = choice['finish_reason'] as String?;
        final message = choice['message'];
        if (message is Map) {
          final msgMap = Map<String, dynamic>.from(message);
          final reasoning = _extractReasoningText(msgMap);
          if (reasoning != null && reasoning.isNotEmpty) {
            thoughtBuffer.write(reasoning);
            yield LlmThoughtDelta(reasoning);
          }
          if (msgMap['reasoning_details'] != null) {
            singleReasoningDetails = msgMap['reasoning_details'];
          }
          final content = msgMap['content'];
          if (content is String && content.isNotEmpty) {
            contentBuffer.write(content);
            yield LlmTextDelta(content);
          }
          final rawToolCalls = msgMap['tool_calls'];
          if (rawToolCalls is List) {
            _accumulateToolCalls(rawToolCalls, pendingToolCalls);
          }
        }
      }

      final usage = decoded['usage'];
      if (usage is Map) {
        final parsedUsage = _parseUsage(Map<String, dynamic>.from(usage));
        promptTokens = parsedUsage.promptTokens;
        completionTokens = parsedUsage.completionTokens;
        totalTokens = parsedUsage.totalTokens;
        cachedTokens = parsedUsage.cachedTokens;
        cacheWriteTokens = parsedUsage.cacheWriteTokens;
        costMicroUsd = parsedUsage.costMicroUsd;
        cacheDiscountUsd = parsedUsage.cacheDiscountUsd;
      }
    } else {
      final lineStream =
          response.stream.transform(utf8.decoder).transform(const LineSplitter());

      await for (final rawLine in _withStreamCancellation(lineStream, cancelToken)) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith(':')) {
          continue;
        }
        if (!line.startsWith('data:')) {
          continue;
        }
        final payload = line.substring('data:'.length).trim();
        if (payload == '[DONE]') {
          break;
        }

        final Map<String, dynamic> chunk;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('Expected JSON object SSE payload.');
          }
          chunk = decoded;
        } on FormatException catch (e) {
          throw LlmDriverException(
            SyscallError(
              code: SyscallErrorCode.eprovider,
              reason: 'INVALID_RESPONSE_FORMAT',
              message: _redactor.redactString(
                'Invalid SSE JSON chunk from OpenRouter: $e',
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

        final choices = chunk['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final choice = Map<String, dynamic>.from(choices.first as Map);
          final chunkFinish = choice['finish_reason'];
          if (chunkFinish is String && chunkFinish.isNotEmpty) {
            finishReason = chunkFinish;
          }

          final delta = choice['delta'];
          if (delta is Map) {
            final deltaMap = Map<String, dynamic>.from(delta);
            final reasoning = _extractReasoningText(deltaMap);
            if (reasoning != null && reasoning.isNotEmpty) {
              ttftMs ??= stopwatch.elapsedMilliseconds;
              thoughtBuffer.write(reasoning);
              yield LlmThoughtDelta(reasoning);
            }

            final rd = deltaMap['reasoning_details'];
            if (rd != null) {
              if (rd is List) {
                collectedReasoningDetails.addAll(rd);
              } else {
                singleReasoningDetails = rd;
              }
            }

            final content = deltaMap['content'];
            if (content is String && content.isNotEmpty) {
              ttftMs ??= stopwatch.elapsedMilliseconds;
              contentBuffer.write(content);
              yield LlmTextDelta(content);
            }

            final rawToolCalls = deltaMap['tool_calls'];
            if (rawToolCalls is List) {
              ttftMs ??= stopwatch.elapsedMilliseconds;
              _accumulateToolCalls(rawToolCalls, pendingToolCalls);
            }
          }
        }

        final usage = chunk['usage'];
        if (usage is Map) {
          final parsedUsage = _parseUsage(Map<String, dynamic>.from(usage));
          promptTokens = parsedUsage.promptTokens;
          completionTokens = parsedUsage.completionTokens;
          totalTokens = parsedUsage.totalTokens;
          cachedTokens = parsedUsage.cachedTokens;
          cacheWriteTokens = parsedUsage.cacheWriteTokens;
          costMicroUsd = parsedUsage.costMicroUsd;
          cacheDiscountUsd = parsedUsage.cacheDiscountUsd;
        }
      }
    }

    final assembledToolCalls = _finalizeToolCalls(pendingToolCalls);
    for (final spec in assembledToolCalls) {
      yield LlmToolCallEvent(spec);
    }

    stopwatch.stop();
    final rawReasoning = collectedReasoningDetails.isNotEmpty
        ? List<dynamic>.unmodifiable(collectedReasoningDetails)
        : singleReasoningDetails;
    final resolvedFinishReason = assembledToolCalls.isNotEmpty
        ? (finishReason ?? 'tool_calls')
        : (finishReason ?? 'stop');

    yield LlmDoneEvent(
      LlmChatResponse(
        content: contentBuffer.toString(),
        thoughtText: thoughtBuffer.isEmpty ? null : thoughtBuffer.toString(),
        rawReasoningDetails: rawReasoning,
        toolCalls: assembledToolCalls,
        finishReason: resolvedFinishReason,
        endpoint: endpointStr,
        usage: LlmUsageTelemetry(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: totalTokens,
          cachedTokens: cachedTokens,
          cacheWriteTokens: cacheWriteTokens,
          costMicroUsd: costMicroUsd,
          cacheDiscountUsd: cacheDiscountUsd,
          ttftMs: ttftMs ?? stopwatch.elapsedMilliseconds,
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

  static String? _extractReasoningText(Map<String, dynamic> map) {
    final reasoning = map['reasoning'];
    if (reasoning is String && reasoning.isNotEmpty) {
      return reasoning;
    }
    final reasoningContent = map['reasoning_content'];
    if (reasoningContent is String && reasoningContent.isNotEmpty) {
      return reasoningContent;
    }
    return null;
  }

  static void _accumulateToolCalls(
    List<dynamic> rawToolCalls,
    Map<int, _PendingToolCall> pendingToolCalls,
  ) {
    for (var i = 0; i < rawToolCalls.length; i++) {
      final raw = rawToolCalls[i];
      if (raw is! Map) {
        continue;
      }
      final tc = Map<String, dynamic>.from(raw);
      final idx = (tc['index'] as num?)?.toInt() ?? i;
      final pending = pendingToolCalls.putIfAbsent(idx, _PendingToolCall.new);

      final id = tc['id'];
      if (id is String && id.isNotEmpty) {
        pending.id = id;
      }

      final fn = tc['function'];
      if (fn is Map) {
        final fnMap = Map<String, dynamic>.from(fn);
        final name = fnMap['name'];
        if (name is String && name.isNotEmpty && pending.name.isEmpty) {
          pending.name = name;
        }
        final args = fnMap['arguments'];
        if (args is String) {
          pending.argumentsBuffer.write(args);
        } else if (args is Map) {
          pending.argumentsBuffer.clear();
          pending.argumentsBuffer.write(jsonEncode(args));
        }
      }
    }
  }

  List<LlmToolCallSpec> _finalizeToolCalls(
    Map<int, _PendingToolCall> pendingToolCalls,
  ) {
    if (pendingToolCalls.isEmpty) {
      return const <LlmToolCallSpec>[];
    }
    final sortedKeys = pendingToolCalls.keys.toList()..sort();
    final specs = <LlmToolCallSpec>[];
    for (final idx in sortedKeys) {
      final pending = pendingToolCalls[idx]!;
      final rawArgs = pending.argumentsBuffer.toString().trim();
      Map<String, dynamic> parsedArgs = const <String, dynamic>{};
      if (rawArgs.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawArgs);
          if (decoded is! Map) {
            throw const FormatException('Tool arguments JSON must be an object.');
          }
          parsedArgs = Map<String, dynamic>.from(decoded);
        } on FormatException catch (e) {
          throw LlmDriverException(
            SyscallError(
              code: SyscallErrorCode.eprovider,
              reason: 'INVALID_TOOL_ARGUMENTS',
              message: _redactor.redactString(
                'Invalid tool call JSON arguments for "${pending.name}": $e',
              ),
              recoverable: true,
            ),
          );
        }
      }
      final id = (pending.id != null && pending.id!.isNotEmpty)
          ? pending.id!
          : 'call_${specs.length + 1}';
      specs.add(
        LlmToolCallSpec(
          id: id,
          name: pending.name,
          arguments: parsedArgs,
        ),
      );
    }
    return specs;
  }

  static _ParsedUsage _parseUsage(Map<String, dynamic> usage) {
    final promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    final completionTokens = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
    final totalTokens = (usage['total_tokens'] as num?)?.toInt();

    final details = usage['prompt_tokens_details'];
    int? cachedTokens;
    int? cacheWriteTokens;
    if (details is Map) {
      cachedTokens = (details['cached_tokens'] as num?)?.toInt();
      cacheWriteTokens = (details['cache_write_tokens'] as num?)?.toInt();
    }

    final rawCost = usage['cost'];
    final int? costMicroUsd =
        rawCost is num ? (rawCost.toDouble() * 1000000).round() : null;
    final rawDiscount = usage['cache_discount'];
    final double? cacheDiscountUsd =
        rawDiscount is num ? rawDiscount.toDouble() : null;

    return _ParsedUsage(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      cachedTokens: cachedTokens,
      cacheWriteTokens: cacheWriteTokens,
      costMicroUsd: costMicroUsd,
      cacheDiscountUsd: cacheDiscountUsd,
    );
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
            message: 'OpenRouter request cancelled while awaiting response.',
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
                message: 'OpenRouter stream cancelled.',
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
                    message: _redactor
                        .redactString('OpenRouter stream error: $error'),
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
                  message: 'OpenRouter stream cancelled.',
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
}

class _PendingToolCall {
  String? id;
  String name = '';
  final StringBuffer argumentsBuffer = StringBuffer();
}

class _ParsedUsage {
  const _ParsedUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.cachedTokens,
    required this.cacheWriteTokens,
    required this.costMicroUsd,
    required this.cacheDiscountUsd,
  });

  final int promptTokens;
  final int completionTokens;
  final int? totalTokens;
  final int? cachedTokens;
  final int? cacheWriteTokens;
  final int? costMicroUsd;
  final double? cacheDiscountUsd;
}
