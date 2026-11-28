import 'dart:async';
import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;

import 'llm_env_loader.dart';

/// Parsed token, cache, and cost telemetry from an OpenAI-compatible `usage` object ([D-403]).
class ParsedOpenAiUsage {
  const ParsedOpenAiUsage({
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

/// Shared OpenAI-compatible Chat Completions SSE base driver ([D-403]).
///
/// Centralizes:
/// - `buildMessages` / `buildRequestBody`
/// - `parseSseStream` with `[DONE]` and HTTP EOF completion guarantee (no double-emit)
/// - `delta.reasoning_content` / `delta.reasoning` / `delta.reasoning_details` extraction
/// - Chunked `delta.tool_calls[index]` buffering and finalization
/// - `extractUsage` (`prompt_tokens_details`, `cost`, `cache_discount`) and `timings.cache_n` fallback
/// - `mapHttpError` with [SecretRedactor] masking
abstract class OpenAiCompatDriver implements LlmDriver {
  OpenAiCompatDriver({
    String? baseUrl,
    String? apiKey,
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 120),
  })  : explicitBaseUrl = baseUrl,
        explicitApiKey = apiKey,
        envLoader = envLoader,
        redactor = redactor ?? envLoader?.redactor ?? SecretRedactor(),
        httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null {
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      this.redactor.registerSecret(apiKey);
    }
  }

  final String? explicitBaseUrl;
  final String? explicitApiKey;
  final LlmEnvLoader? envLoader;
  final SecretRedactor redactor;
  final http.Client httpClient;
  final bool _ownsClient;
  final Duration requestTimeout;

  /// Human-readable provider name for error messages (e.g. `OpenRouter`, `OpenAI`).
  String get providerDisplayName;

  /// Primary environment variable name for the API key, used in missing-key hints.
  String? get apiKeyEnvVarName;

  /// Whether an API key is required before dispatching requests.
  bool get requiresApiKey => true;

  /// Whether to include `stream_options: {"include_usage": true}` when streaming.
  bool get includeUsageInStream => true;

  /// Error reason emitted for HTTP 401/403 responses.
  String get unauthorizedReason => 'AUTH_FAILED';

  /// Resolves the target `/chat/completions` endpoint URI.
  Uri resolveEndpoint();

  /// Resolves the provider API key, or returns `null` if unconfigured.
  String? resolveApiKey();

  /// Builds HTTP headers for the Chat Completions request.
  Map<String, String> buildHeaders(
    LlmChatRequest request, {
    String? apiKey,
  }) {
    return <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream, application/json',
      if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
  }

  /// Converts [ProjectedPrompt.messages] to OpenAI Chat Completions `messages`.
  List<Map<String, dynamic>> buildMessages(LlmChatRequest request) {
    final encodedMessages = <Map<String, dynamic>>[];
    for (final msg in request.prompt.messages) {
      switch (msg.role) {
        case ProjectedRole.system:
          encodedMessages.add(<String, dynamic>{
            'role': 'system',
            'content': msg.content,
          });
        case ProjectedRole.user:
          encodedMessages.add(<String, dynamic>{
            'role': 'user',
            'content': msg.content,
          });
        case ProjectedRole.assistant:
          final entry = <String, dynamic>{
            'role': 'assistant',
            'content': msg.content,
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
          encodedMessages.add(entry);
        case ProjectedRole.tool:
          encodedMessages.add(<String, dynamic>{
            'role': 'tool',
            'tool_call_id': msg.toolCallId ?? '',
            if (msg.toolName != null && msg.toolName!.isNotEmpty)
              'name': msg.toolName,
            'content': msg.content,
          });
      }
    }
    return encodedMessages;
  }

  /// Builds the JSON payload for `/chat/completions`.
  Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
    return <String, dynamic>{
      'model': request.model.modelName,
      'messages': buildMessages(request),
      if (request.prompt.tools.isNotEmpty)
        'tools': request.prompt.tools
            .map((t) => t.toJson())
            .toList(growable: false),
      'stream': request.stream,
      if (request.stream && includeUsageInStream)
        'stream_options': const <String, dynamic>{'include_usage': true},
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) 'max_tokens': request.maxTokens,
    };
  }

  /// Constructs `rawReasoningDetails` for [LlmChatResponse] at stream completion.
  Object? buildRawReasoningDetails({
    required List<dynamic> collectedReasoningDetails,
    required Object? singleReasoningDetails,
    required StringBuffer thoughtBuffer,
  }) {
    if (collectedReasoningDetails.isNotEmpty) {
      return List<dynamic>.unmodifiable(collectedReasoningDetails);
    }
    return singleReasoningDetails;
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
              '$providerDisplayName received model for ${request.model.provider.id}.',
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

    final apiKey = resolveApiKey();
    if (requiresApiKey && apiKey == null) {
      final envName = apiKeyEnvVarName ?? 'API_KEY';
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'MISSING_API_KEY',
          message: '$envName is not configured for ${providerId.id}.',
          recoverable: true,
          hint: 'Set $envName in environment or .agent_os/.env.',
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
              '$providerDisplayName request to $endpointStr timed out after ${requestTimeout.inMilliseconds}ms.',
          recoverable: true,
        ),
      );
    } catch (e) {
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'PROVIDER_UNREACHABLE',
          message: redactor.redactString(
            'Failed to connect to $providerDisplayName ($endpointStr): $e',
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
      throw mapHttpError(
        statusCode: response.statusCode,
        errorBody: errorBody,
        endpointStr: endpointStr,
      );
    }

    if (!request.stream) {
      yield* _parseNonStreamingResponse(
        response.stream,
        stopwatch: stopwatch,
        endpointStr: endpointStr,
      );
      return;
    }

    yield* parseSseStream(
      response.stream,
      stopwatch: stopwatch,
      endpointStr: endpointStr,
      cancelToken: cancelToken,
    );
  }

  /// Parses an OpenAI-compatible SSE byte stream and guarantees [LlmToolCallEvent]
  /// and [LlmDoneEvent] emission on either `data: [DONE]` or HTTP EOF ([D-403]).
  Stream<LlmStreamEvent> parseSseStream(
    Stream<List<int>> byteStream, {
    required Stopwatch stopwatch,
    required String endpointStr,
    CancellationToken? cancelToken,
  }) async* {
    final contentBuffer = StringBuffer();
    final thoughtBuffer = StringBuffer();
    final pendingToolCalls = <int, _PendingToolCall>{};
    final reasoningDetailsAccumulator = _ReasoningDetailsAccumulator();
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
    var completed = false;

    final lineStream =
        byteStream.transform(utf8.decoder).transform(const LineSplitter());

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
            message: redactor.redactString(
              'Invalid SSE JSON chunk from $providerDisplayName: $e',
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
            message: redactor.redactString(chunk['error'].toString()),
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
          final reasoning = extractReasoningText(deltaMap);
          if (reasoning != null && reasoning.isNotEmpty) {
            ttftMs ??= stopwatch.elapsedMilliseconds;
            thoughtBuffer.write(reasoning);
            yield LlmThoughtDelta(reasoning);
          }

          final rd = deltaMap['reasoning_details'];
          if (rd != null) {
            if (rd is List) {
              reasoningDetailsAccumulator.addAll(rd);
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
        final parsedUsage = extractUsage(Map<String, dynamic>.from(usage));
        promptTokens = parsedUsage.promptTokens;
        completionTokens = parsedUsage.completionTokens;
        totalTokens = parsedUsage.totalTokens;
        cachedTokens = parsedUsage.cachedTokens;
        cacheWriteTokens = parsedUsage.cacheWriteTokens;
        costMicroUsd = parsedUsage.costMicroUsd;
        cacheDiscountUsd = parsedUsage.cacheDiscountUsd;
      }

      final timings = chunk['timings'];
      if (timings is Map && (cachedTokens == null || cachedTokens == 0)) {
        final cacheN = (timings['cache_n'] as num?)?.toInt();
        if (cacheN != null && cacheN > 0) {
          cachedTokens = cacheN;
        }
      }
    }

    if (!completed) {
      completed = true;
      final assembledToolCalls = _finalizeToolCalls(pendingToolCalls);
      for (final spec in assembledToolCalls) {
        yield LlmToolCallEvent(spec);
      }

      stopwatch.stop();
      final rawReasoning = buildRawReasoningDetails(
        collectedReasoningDetails: reasoningDetailsAccumulator.toList(),
        singleReasoningDetails: singleReasoningDetails,
        thoughtBuffer: thoughtBuffer,
      );
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
  }

  Stream<LlmStreamEvent> _parseNonStreamingResponse(
    Stream<List<int>> byteStream, {
    required Stopwatch stopwatch,
    required String endpointStr,
  }) async* {
    final contentBuffer = StringBuffer();
    final thoughtBuffer = StringBuffer();
    final pendingToolCalls = <int, _PendingToolCall>{};
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

    final rawJson = await byteStream.transform(utf8.decoder).join();
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
          message: redactor.redactString(
            'Invalid JSON response from $providerDisplayName: $e',
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
          message: redactor.redactString(decoded['error'].toString()),
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
        final reasoning = extractReasoningText(msgMap);
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
      final parsedUsage = extractUsage(Map<String, dynamic>.from(usage));
      promptTokens = parsedUsage.promptTokens;
      completionTokens = parsedUsage.completionTokens;
      totalTokens = parsedUsage.totalTokens;
      cachedTokens = parsedUsage.cachedTokens;
      cacheWriteTokens = parsedUsage.cacheWriteTokens;
      costMicroUsd = parsedUsage.costMicroUsd;
      cacheDiscountUsd = parsedUsage.cacheDiscountUsd;
    }

    final timings = decoded['timings'];
    if (timings is Map && (cachedTokens == null || cachedTokens == 0)) {
      final cacheN = (timings['cache_n'] as num?)?.toInt();
      if (cacheN != null && cacheN > 0) {
        cachedTokens = cacheN;
      }
    }

    final assembledToolCalls = _finalizeToolCalls(pendingToolCalls);
    for (final spec in assembledToolCalls) {
      yield LlmToolCallEvent(spec);
    }

    stopwatch.stop();
    final rawReasoning = buildRawReasoningDetails(
      collectedReasoningDetails: const <dynamic>[],
      singleReasoningDetails: singleReasoningDetails,
      thoughtBuffer: thoughtBuffer,
    );
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
          ttftMs: ttftMs,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      ),
    );
  }

  /// Maps non-2xx HTTP responses to structured [LlmDriverException] with secret redaction ([D-403]).
  LlmDriverException mapHttpError({
    required int statusCode,
    required String errorBody,
    required String endpointStr,
  }) {
    final reason = switch (statusCode) {
      401 || 403 => unauthorizedReason,
      429 => 'RATE_LIMITED',
      400 || 404 || 422 => 'PROVIDER_BAD_REQUEST',
      >= 500 => 'PROVIDER_ERROR',
      _ => 'HTTP_$statusCode',
    };
    final redactedBody = redactor.redactString(errorBody).trim();
    return LlmDriverException(
      SyscallError(
        code: SyscallErrorCode.eprovider,
        reason: reason,
        message: redactedBody.isEmpty
            ? '$providerDisplayName HTTP $statusCode from $endpointStr.'
            : '$providerDisplayName HTTP $statusCode: $redactedBody',
        recoverable: statusCode == 429 || statusCode >= 500,
        details: <String, dynamic>{'statusCode': statusCode},
      ),
    );
  }

  /// Normalizes and merges chunked SSE `delta.reasoning_details` lists ([D-604]).
  static List<dynamic> mergeReasoningDetailsChunks(
    List<List<dynamic>> chunks,
  ) {
    final accumulator = _ReasoningDetailsAccumulator();
    for (final chunk in chunks) {
      accumulator.addAll(chunk);
    }
    return accumulator.toList();
  }

  /// Extracts reasoning text from `reasoning_content`, `reasoning`, or `reasoning_details`.
  static String? extractReasoningText(Map<String, dynamic> map) {
    final reasoningContent = map['reasoning_content'];
    if (reasoningContent is String && reasoningContent.isNotEmpty) {
      return reasoningContent;
    }
    final reasoning = map['reasoning'];
    if (reasoning is String && reasoning.isNotEmpty) {
      return reasoning;
    }
    final Object? details = map['reasoning_details'];
    if (details != null) {
      final extracted = _extractTextFromReasoningDetails(details);
      if (extracted != null && extracted.isNotEmpty) {
        return extracted;
      }
    }
    return null;
  }

  static String? _extractTextFromReasoningDetails(Object details) {
    if (details is String) {
      return details.isEmpty ? null : details;
    }
    if (details is Map) {
      for (final key in const <String>['text', 'thinking', 'reasoning', 'summary']) {
        final val = details[key];
        if (val is String && val.isNotEmpty) {
          return val;
        }
      }
      return null;
    }
    if (details is List) {
      final buf = StringBuffer();
      for (final Object? item in details) {
        if (item == null) continue;
        final part = _extractTextFromReasoningDetails(item);
        if (part != null && part.isNotEmpty) {
          buf.write(part);
        }
      }
      return buf.isEmpty ? null : buf.toString();
    }
    return null;
  }

  /// Extracts token, cache, and cost fields from an OpenAI-compatible `usage` map.
  static ParsedOpenAiUsage extractUsage(Map<String, dynamic> usage) {
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

    return ParsedOpenAiUsage(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      cachedTokens: cachedTokens,
      cacheWriteTokens: cacheWriteTokens,
      costMicroUsd: costMicroUsd,
      cacheDiscountUsd: cacheDiscountUsd,
    );
  }

  /// Releases the internal HTTP client if owned by this driver.
  void close() {
    if (_ownsClient) {
      httpClient.close();
    }
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
              message: redactor.redactString(
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

  Future<http.StreamedResponse> _sendWithCancellation(
    http.Request request,
    CancellationToken? cancelToken,
  ) {
    final sendFuture = httpClient.send(request);
    if (cancelToken == null) {
      return sendFuture;
    }
    return Future.any<http.StreamedResponse>(<Future<http.StreamedResponse>>[
      sendFuture,
      cancelToken.onCancel.then<http.StreamedResponse>((_) {
        throw LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'CANCELLED',
            message:
                '$providerDisplayName request cancelled while awaiting response.',
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
            LlmDriverException(
              SyscallError(
                code: SyscallErrorCode.ecancelled,
                reason: 'CANCELLED',
                message: '$providerDisplayName stream cancelled.',
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
                    message: redactor
                        .redactString('$providerDisplayName stream error: $error'),
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
              LlmDriverException(
                SyscallError(
                  code: SyscallErrorCode.ecancelled,
                  reason: 'CANCELLED',
                  message: '$providerDisplayName stream cancelled.',
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

class _ReasoningDetailKey {
  const _ReasoningDetailKey({
    required this.index,
    required this.type,
    required this.id,
    required this.format,
  });

  final int? index;
  final String? type;
  final String? id;
  final String? format;

  bool get isIdentifiable =>
      index != null || type != null || id != null || format != null;

  @override
  bool operator ==(Object other) {
    return other is _ReasoningDetailKey &&
        other.index == index &&
        other.type == type &&
        other.id == id &&
        other.format == format;
  }

  @override
  int get hashCode => Object.hash(index, type, id, format);
}

class _ReasoningDetailsAccumulator {
  final List<dynamic> _items = <dynamic>[];
  final Map<_ReasoningDetailKey, int> _keyToIndex = <_ReasoningDetailKey, int>{};

  void addAll(List<dynamic> chunk) {
    for (final Object? item in chunk) {
      if (item is! Map) {
        _items.add(item);
        continue;
      }
      final map = item is Map<String, dynamic>
          ? Map<String, dynamic>.from(item)
          : <String, dynamic>{
              for (final entry in item.entries)
                entry.key.toString(): entry.value,
            };

      final rawIndex = map['index'];
      final index = rawIndex is num ? rawIndex.toInt() : null;
      final rawType = map['type'];
      final type = rawType is String ? rawType : null;
      final rawId = map['id'];
      final id = rawId is String ? rawId : null;
      final rawFormat = map['format'];
      final format = rawFormat is String ? rawFormat : null;

      final key = _ReasoningDetailKey(
        index: index,
        type: type,
        id: id,
        format: format,
      );
      if (!key.isIdentifiable) {
        _items.add(map);
        continue;
      }

      final existingIdx = _keyToIndex[key];
      if (existingIdx == null) {
        _items.add(map);
        _keyToIndex[key] = _items.length - 1;
        continue;
      }

      final existing = _items[existingIdx] as Map<String, dynamic>;
      _mergeInto(existing, map, type);
    }
  }

  static void _mergeInto(
    Map<String, dynamic> existing,
    Map<String, dynamic> incoming,
    String? type,
  ) {
    for (final entry in incoming.entries) {
      final k = entry.key;
      final v = entry.value;
      if (k == 'index' || k == 'type' || k == 'id' || k == 'format') {
        continue;
      }
      if (type == 'reasoning.text') {
        if (k == 'text' && v is String) {
          final prev = existing['text'];
          existing['text'] = prev is String ? '$prev$v' : v;
          continue;
        }
        if (k == 'signature' && v is String) {
          if (v.isNotEmpty) {
            existing['signature'] = v;
          }
          continue;
        }
      } else if (type == 'reasoning.summary') {
        if (k == 'summary' && v is String) {
          final prev = existing['summary'];
          existing['summary'] = prev is String ? '$prev$v' : v;
          continue;
        }
      } else if (type == 'reasoning.encrypted') {
        if (k == 'data' && v is String) {
          final prev = existing['data'];
          existing['data'] = prev is String ? '$prev$v' : v;
          continue;
        }
      }
      if (v != null) {
        existing[k] = v;
      }
    }
  }

  List<dynamic> toList() => List<dynamic>.unmodifiable(_items);
}
