import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;

import 'llm_env_loader.dart';

/// Google AI Studio (`v1beta`) native REST driver for Gemini ([D-402], [D-404]).
///
/// Implements:
/// - `POST .../v1beta/models/{model}:streamGenerateContent?alt=sse` (or `:generateContent`)
/// - Authentication strictly via `x-goog-api-key` header (`?key=` query parameter is never used)
/// - `GEMINI_API_KEY` with fallback to `GOOGLE_API_KEY`
/// - `part.thoughtSignature` / `thought: true` preservation in `rawReasoningDetails` and
///   same-model echo-back (cleared automatically by [CanonicalIrProjector] on model switch)
/// - Coalescing consecutive `ProjectedRole.tool` messages into a single `user` turn
/// - Recursive stripping of unsupported JSON Schema keys (`$schema`, `additionalProperties`, etc.)
/// - `usageMetadata.cachedContentTokenCount` extraction and SSE EOF completion
class GeminiDriver implements LlmDriver {
  GeminiDriver({
    String? baseUrl,
    String? apiKey,
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
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

  static const String defaultBaseUrl =
      'https://generativelanguage.googleapis.com';

  static const Set<String> _unsupportedSchemaKeys = <String>{
    r'$schema',
    r'$id',
    r'$defs',
    'definitions',
    'additionalProperties',
    'default',
  };

  final String? _explicitBaseUrl;
  final String? _explicitApiKey;
  final LlmEnvLoader? _envLoader;
  final SecretRedactor _redactor;
  final http.Client _httpClient;
  final bool _ownsClient;
  final Duration requestTimeout;

  @override
  LlmProviderId get providerId => LlmProviderId.gemini;

  /// Resolves the `v1beta` generate endpoint URI without any `?key=` query parameter.
  Uri resolveEndpoint(String modelName, {required bool stream}) {
    final explicit = _explicitBaseUrl?.trim();
    var raw = (explicit != null && explicit.isNotEmpty)
        ? explicit
        : (_resolveEnv('GEMINI_BASE_URL') ?? defaultBaseUrl);
    if (raw.isEmpty) {
      raw = defaultBaseUrl;
    }

    final uri = Uri.parse(raw);
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    var cleanModel = modelName.trim();
    if (cleanModel.startsWith('models/')) {
      cleanModel = cleanModel.substring('models/'.length);
    }

    final action = stream ? 'streamGenerateContent' : 'generateContent';
    final targetPath = path.endsWith('/v1beta')
        ? '$path/models/$cleanModel:$action'
        : '$path/v1beta/models/$cleanModel:$action';

    if (stream) {
      final mergedQuery = Map<String, String>.from(uri.queryParameters);
      mergedQuery.remove('key');
      mergedQuery['alt'] = 'sse';
      return uri.replace(path: targetPath, queryParameters: mergedQuery);
    }

    if (uri.hasQuery) {
      final mergedQuery = Map<String, String>.from(uri.queryParameters);
      mergedQuery.remove('key');
      return uri.replace(
        path: targetPath,
        queryParameters: mergedQuery.isEmpty ? null : mergedQuery,
      );
    }
    return uri.replace(path: targetPath);
  }

  String? _resolveApiKey() {
    final explicit = _explicitApiKey?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      _redactor.registerSecret(explicit);
      return explicit;
    }
    final key =
        _resolveEnv('GEMINI_API_KEY') ?? _resolveEnv('GOOGLE_API_KEY');
    if (key != null && key.isNotEmpty) {
      _redactor.registerSecret(key);
      return key;
    }
    return null;
  }

  String? _resolveEnv(String key) {
    final fromLoader = _envLoader?.get(key);
    if (fromLoader != null && fromLoader.trim().isNotEmpty) {
      return fromLoader.trim();
    }
    final fromProc = Platform.environment[key];
    if (fromProc != null && fromProc.trim().isNotEmpty) {
      return fromProc.trim();
    }
    return null;
  }

  /// Projects [LlmChatRequest] into Gemini `v1beta` JSON request payload ([D-404]).
  Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
    final systemTexts = <String>[];
    final contents = <Map<String, dynamic>>[];

    final messages = request.prompt.messages;
    var i = 0;
    while (i < messages.length) {
      final msg = messages[i];
      switch (msg.role) {
        case ProjectedRole.system:
          if (msg.content.trim().isNotEmpty) {
            systemTexts.add(msg.content);
          }
          i++;
        case ProjectedRole.user:
          contents.add(<String, dynamic>{
            'role': 'user',
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{'text': msg.content},
            ],
          });
          i++;
        case ProjectedRole.assistant:
          final parts = _buildModelParts(msg);
          contents.add(<String, dynamic>{
            'role': 'model',
            'parts': parts,
          });
          i++;
        case ProjectedRole.tool:
          // Coalesce consecutive tool responses into a single `user` turn ([D-404]).
          final toolParts = <Map<String, dynamic>>[];
          while (i < messages.length && messages[i].role == ProjectedRole.tool) {
            final toolMsg = messages[i];
            final fnName = (toolMsg.toolName != null &&
                    toolMsg.toolName!.trim().isNotEmpty)
                ? toolMsg.toolName!.trim()
                : 'unknown';
            toolParts.add(<String, dynamic>{
              'functionResponse': <String, dynamic>{
                'name': fnName,
                'response': _decodeToolResponse(toolMsg.content),
              },
            });
            i++;
          }
          contents.add(<String, dynamic>{
            'role': 'user',
            'parts': toolParts,
          });
      }
    }

    final body = <String, dynamic>{
      if (systemTexts.isNotEmpty)
        'systemInstruction': <String, dynamic>{
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{'text': systemTexts.join('\n\n')},
          ],
        },
      'contents': contents,
    };

    if (request.prompt.tools.isNotEmpty) {
      body['tools'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'functionDeclarations': request.prompt.tools
              .map(
                (t) => <String, dynamic>{
                  'name': t.name,
                  'description': t.description,
                  'parameters':
                      sanitizeSchemaForGemini(t.parametersJsonSchema),
                },
              )
              .toList(growable: false),
        },
      ];
    }

    if (request.temperature != null || request.maxTokens != null) {
      body['generationConfig'] = <String, dynamic>{
        if (request.temperature != null) 'temperature': request.temperature,
        if (request.maxTokens != null) 'maxOutputTokens': request.maxTokens,
      };
    }

    return body;
  }

  List<Map<String, dynamic>> _buildModelParts(ProjectedMessage msg) {
    final rawDetails = msg.rawReasoningDetails;
    if (rawDetails is List && rawDetails.isNotEmpty) {
      final restored = <Map<String, dynamic>>[];
      for (final item in rawDetails) {
        if (item is Map) {
          restored.add(Map<String, dynamic>.from(item));
        }
      }
      if (restored.isNotEmpty) {
        return restored;
      }
    }

    final parts = <Map<String, dynamic>>[];
    if (msg.content.isNotEmpty) {
      parts.add(<String, dynamic>{'text': msg.content});
    }
    for (final tc in msg.toolCalls) {
      parts.add(<String, dynamic>{
        'functionCall': <String, dynamic>{
          'name': tc.name,
          'args': tc.arguments,
        },
      });
    }
    if (parts.isEmpty) {
      parts.add(<String, dynamic>{'text': ''});
    }
    return parts;
  }

  /// Recursively strips JSON Schema keys unsupported by Gemini `functionDeclarations` ([D-404]).
  static Object? sanitizeSchemaForGemini(Object? schema) {
    if (schema is Map) {
      final result = <String, dynamic>{};
      for (final entry in schema.entries) {
        final key = entry.key.toString();
        if (_unsupportedSchemaKeys.contains(key)) {
          continue;
        }
        result[key] = sanitizeSchemaForGemini(entry.value);
      }
      return result;
    }
    if (schema is List) {
      return schema.map(sanitizeSchemaForGemini).toList(growable: false);
    }
    return schema;
  }

  static Map<String, dynamic> _decodeToolResponse(String content) {
    final trimmed = content.trim();
    if (trimmed.isNotEmpty) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } on FormatException {
        // Non-JSON string falls back to wrapped object below.
      }
    }
    return <String, dynamic>{'result': content};
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
          message: 'GeminiDriver received model for ${request.model.provider.id}.',
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
          message: 'GEMINI_API_KEY (or GOOGLE_API_KEY) is not configured for gemini.',
          recoverable: true,
          hint: 'Set GEMINI_API_KEY or GOOGLE_API_KEY in environment or .agent_os/.env.',
        ),
      );
    }

    final endpoint = resolveEndpoint(
      request.model.modelName,
      stream: request.stream,
    );
    final endpointStr = endpoint.toString();
    final httpRequest = http.Request('POST', endpoint)
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        'Accept': request.stream
            ? 'text/event-stream, application/json'
            : 'application/json',
        'x-goog-api-key': apiKey,
      })
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
              'Gemini request to $endpointStr timed out after ${requestTimeout.inMilliseconds}ms.',
          recoverable: true,
        ),
      );
    } catch (e) {
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'PROVIDER_UNREACHABLE',
          message: _redactor.redactString(
            'Failed to connect to Gemini ($endpointStr): $e',
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
      throw _mapHttpError(
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

    yield* _parseSseStream(
      response.stream,
      stopwatch: stopwatch,
      endpointStr: endpointStr,
      cancelToken: cancelToken,
    );
  }

  Stream<LlmStreamEvent> _parseSseStream(
    Stream<List<int>> byteStream, {
    required Stopwatch stopwatch,
    required String endpointStr,
    CancellationToken? cancelToken,
  }) async* {
    final contentBuffer = StringBuffer();
    final thoughtBuffer = StringBuffer();
    final collectedToolCalls = <LlmToolCallSpec>[];
    final collectedModelParts = <Map<String, dynamic>>[];
    var hasThoughtOrSignature = false;

    int? ttftMs;
    var promptTokens = 0;
    var completionTokens = 0;
    int? totalTokens;
    int? cachedTokens;
    String? finishReason;
    var toolCallCounter = 0;

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
            message: _redactor.redactString(
              'Invalid SSE JSON chunk from Gemini: $e',
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

      final candidates = chunk['candidates'];
      if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
        final candidate = Map<String, dynamic>.from(candidates.first as Map);
        final chunkFinish = candidate['finishReason'];
        if (chunkFinish is String && chunkFinish.isNotEmpty) {
          finishReason = chunkFinish;
        }
        final content = candidate['content'];
        if (content is Map) {
          final parts = content['parts'];
          if (parts is List) {
            for (final rawPart in parts) {
              if (rawPart is! Map) {
                continue;
              }
              final part = Map<String, dynamic>.from(rawPart);
              _appendCollectedPart(collectedModelParts, part);
              if (part['thought'] == true || part['thoughtSignature'] != null) {
                hasThoughtOrSignature = true;
              }

              final text = part['text'];
              if (text is String && text.isNotEmpty) {
                ttftMs ??= stopwatch.elapsedMilliseconds;
                if (part['thought'] == true) {
                  thoughtBuffer.write(text);
                  yield LlmThoughtDelta(text);
                } else {
                  contentBuffer.write(text);
                  yield LlmTextDelta(text);
                }
              }

              final fc = part['functionCall'];
              if (fc is Map) {
                ttftMs ??= stopwatch.elapsedMilliseconds;
                final fcMap = Map<String, dynamic>.from(fc);
                final name = (fcMap['name'] as String?) ?? '';
                final args = fcMap['args'] is Map
                    ? Map<String, dynamic>.from(fcMap['args'] as Map)
                    : <String, dynamic>{};
                toolCallCounter++;
                collectedToolCalls.add(
                  LlmToolCallSpec(
                    id: 'gemini_call_$toolCallCounter',
                    name: name,
                    arguments: args,
                  ),
                );
              }
            }
          }
        }
      }

      final usage = chunk['usageMetadata'];
      if (usage is Map) {
        final usageMap = Map<String, dynamic>.from(usage);
        promptTokens =
            (usageMap['promptTokenCount'] as num?)?.toInt() ?? promptTokens;
        completionTokens =
            (usageMap['candidatesTokenCount'] as num?)?.toInt() ??
                completionTokens;
        totalTokens =
            (usageMap['totalTokenCount'] as num?)?.toInt() ?? totalTokens;
        final cached = (usageMap['cachedContentTokenCount'] as num?)?.toInt();
        if (cached != null) {
          cachedTokens = cached;
        }
      }
    }

    for (final spec in collectedToolCalls) {
      yield LlmToolCallEvent(spec);
    }

    stopwatch.stop();
    final resolvedFinishReason = collectedToolCalls.isNotEmpty
        ? (finishReason ?? 'tool_calls')
        : (finishReason ?? 'stop');

    yield LlmDoneEvent(
      LlmChatResponse(
        content: contentBuffer.toString(),
        thoughtText: thoughtBuffer.isEmpty ? null : thoughtBuffer.toString(),
        rawReasoningDetails: hasThoughtOrSignature
            ? List<Map<String, dynamic>>.unmodifiable(collectedModelParts)
            : null,
        toolCalls: collectedToolCalls,
        finishReason: resolvedFinishReason,
        endpoint: endpointStr,
        usage: LlmUsageTelemetry(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: totalTokens,
          cachedTokens: cachedTokens,
          ttftMs: ttftMs ?? stopwatch.elapsedMilliseconds,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      ),
    );
  }

  Stream<LlmStreamEvent> _parseNonStreamingResponse(
    Stream<List<int>> byteStream, {
    required Stopwatch stopwatch,
    required String endpointStr,
  }) async* {
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
          message: _redactor.redactString(
            'Invalid JSON response from Gemini: $e',
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

    final ttftMs = stopwatch.elapsedMilliseconds;
    final contentBuffer = StringBuffer();
    final thoughtBuffer = StringBuffer();
    final collectedToolCalls = <LlmToolCallSpec>[];
    final collectedModelParts = <Map<String, dynamic>>[];
    var hasThoughtOrSignature = false;
    var toolCallCounter = 0;
    String? finishReason;

    final candidates = decoded['candidates'];
    if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
      final candidate = Map<String, dynamic>.from(candidates.first as Map);
      finishReason = candidate['finishReason'] as String?;
      final content = candidate['content'];
      if (content is Map) {
        final parts = content['parts'];
        if (parts is List) {
          for (final rawPart in parts) {
            if (rawPart is! Map) {
              continue;
            }
            final part = Map<String, dynamic>.from(rawPart);
            _appendCollectedPart(collectedModelParts, part);
            if (part['thought'] == true || part['thoughtSignature'] != null) {
              hasThoughtOrSignature = true;
            }

            final text = part['text'];
            if (text is String && text.isNotEmpty) {
              if (part['thought'] == true) {
                thoughtBuffer.write(text);
                yield LlmThoughtDelta(text);
              } else {
                contentBuffer.write(text);
                yield LlmTextDelta(text);
              }
            }

            final fc = part['functionCall'];
            if (fc is Map) {
              final fcMap = Map<String, dynamic>.from(fc);
              final name = (fcMap['name'] as String?) ?? '';
              final args = fcMap['args'] is Map
                  ? Map<String, dynamic>.from(fcMap['args'] as Map)
                  : <String, dynamic>{};
              toolCallCounter++;
              collectedToolCalls.add(
                LlmToolCallSpec(
                  id: 'gemini_call_$toolCallCounter',
                  name: name,
                  arguments: args,
                ),
              );
            }
          }
        }
      }
    }

    var promptTokens = 0;
    var completionTokens = 0;
    int? totalTokens;
    int? cachedTokens;
    final usage = decoded['usageMetadata'];
    if (usage is Map) {
      final usageMap = Map<String, dynamic>.from(usage);
      promptTokens = (usageMap['promptTokenCount'] as num?)?.toInt() ?? 0;
      completionTokens =
          (usageMap['candidatesTokenCount'] as num?)?.toInt() ?? 0;
      totalTokens = (usageMap['totalTokenCount'] as num?)?.toInt();
      cachedTokens = (usageMap['cachedContentTokenCount'] as num?)?.toInt();
    }

    for (final spec in collectedToolCalls) {
      yield LlmToolCallEvent(spec);
    }

    stopwatch.stop();
    final resolvedFinishReason = collectedToolCalls.isNotEmpty
        ? (finishReason ?? 'tool_calls')
        : (finishReason ?? 'stop');

    yield LlmDoneEvent(
      LlmChatResponse(
        content: contentBuffer.toString(),
        thoughtText: thoughtBuffer.isEmpty ? null : thoughtBuffer.toString(),
        rawReasoningDetails: hasThoughtOrSignature
            ? List<Map<String, dynamic>>.unmodifiable(collectedModelParts)
            : null,
        toolCalls: collectedToolCalls,
        finishReason: resolvedFinishReason,
        endpoint: endpointStr,
        usage: LlmUsageTelemetry(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          totalTokens: totalTokens,
          cachedTokens: cachedTokens,
          ttftMs: ttftMs,
          durationMs: stopwatch.elapsedMilliseconds,
        ),
      ),
    );
  }

  static void _appendCollectedPart(
    List<Map<String, dynamic>> target,
    Map<String, dynamic> part,
  ) {
    final isMergeableText = part['text'] is String &&
        part['functionCall'] == null &&
        part['thoughtSignature'] == null &&
        part.keys.every((k) => k == 'text' || k == 'thought');

    if (isMergeableText && target.isNotEmpty) {
      final last = target.last;
      final lastIsMergeable = last['text'] is String &&
          last['functionCall'] == null &&
          last['thoughtSignature'] == null &&
          last.keys.every((k) => k == 'text' || k == 'thought') &&
          (last['thought'] == true) == (part['thought'] == true);
      if (lastIsMergeable) {
        last['text'] = '${last['text']}${part['text']}';
        return;
      }
    }
    target.add(part);
  }

  LlmDriverException _mapHttpError({
    required int statusCode,
    required String errorBody,
    required String endpointStr,
  }) {
    final reason = switch (statusCode) {
      401 || 403 => 'AUTH_FAILED',
      429 => 'RATE_LIMITED',
      400 || 404 || 422 => 'PROVIDER_BAD_REQUEST',
      >= 500 => 'PROVIDER_ERROR',
      _ => 'HTTP_$statusCode',
    };
    final redactedBody = _redactor.redactString(errorBody).trim();
    return LlmDriverException(
      SyscallError(
        code: SyscallErrorCode.eprovider,
        reason: reason,
        message: redactedBody.isEmpty
            ? 'Gemini HTTP $statusCode from $endpointStr.'
            : 'Gemini HTTP $statusCode: $redactedBody',
        recoverable: statusCode == 429 || statusCode >= 500,
        details: <String, dynamic>{'statusCode': statusCode},
      ),
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
            message: 'Gemini request cancelled while awaiting response.',
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
                message: 'Gemini stream cancelled.',
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
                    message: _redactor.redactString('Gemini stream error: $error'),
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
                  message: 'Gemini stream cancelled.',
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

  /// Releases the internal HTTP client if owned by this driver.
  void close() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}
