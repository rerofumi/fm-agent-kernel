import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';

import 'open_ai_compat_driver.dart';

/// OpenRouter `/api/v1/chat/completions` SSE streaming driver ([D-009], [D-403]).
///
/// Implements:
/// - `x-session-id` / `session_id` Provider Sticky Routing
/// - Wire-only `cache_control: {"type": "ephemeral"}` injection (max 2 breakpoints) for `anthropic/` models
/// - Chunked SSE `delta.tool_calls[index].function.arguments` assembly via [OpenAiCompatDriver]
/// - `cached_tokens`, `cache_write_tokens`, `costMicroUsd`, and signed `cacheDiscountUsd` extraction
class OpenRouterDriver extends OpenAiCompatDriver {
  OpenRouterDriver({
    super.baseUrl,
    super.apiKey,
    super.envLoader,
    super.redactor,
    super.httpClient,
    this.httpReferer,
    this.xTitle = 'FM Agent OS',
    super.requestTimeout,
  });

  static const String defaultBaseUrl = 'https://openrouter.ai/api/v1';

  final String? httpReferer;
  final String? xTitle;

  @override
  LlmProviderId get providerId => LlmProviderId.openRouter;

  @override
  String get providerDisplayName => 'OpenRouter';

  @override
  String get apiKeyEnvVarName => 'OPENROUTER_API_KEY';

  @override
  String get unauthorizedReason => 'UNAUTHORIZED';

  /// Resolves the `/chat/completions` endpoint URI.
  @override
  Uri resolveEndpoint() {
    var raw = (explicitBaseUrl != null && explicitBaseUrl!.trim().isNotEmpty)
        ? explicitBaseUrl!.trim()
        : ((envLoader != null
                ? envLoader!.get('OPENROUTER_BASE_URL')
                : Platform.environment['OPENROUTER_BASE_URL']) ??
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

  @override
  String? resolveApiKey() {
    if (explicitApiKey != null && explicitApiKey!.trim().isNotEmpty) {
      final key = explicitApiKey!.trim();
      redactor.registerSecret(key);
      return key;
    }
    final fromEnv = envLoader != null
        ? envLoader!.get('OPENROUTER_API_KEY')
        : Platform.environment['OPENROUTER_API_KEY'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      final key = fromEnv.trim();
      redactor.registerSecret(key);
      return key;
    }
    return null;
  }

  /// Builds the OpenRouter request headers including Sticky Routing `x-session-id` ([D-009]).
  @override
  Map<String, String> buildHeaders(
    LlmChatRequest request, {
    String? apiKey,
  }) {
    return <String, String>{
      ...super.buildHeaders(request, apiKey: apiKey),
      'x-session-id': request.sessionUuid,
      if (httpReferer != null && httpReferer!.isNotEmpty)
        'HTTP-Referer': httpReferer!,
      if (xTitle != null && xTitle!.isNotEmpty) 'X-Title': xTitle!,
    };
  }

  /// Builds the OpenRouter `messages` array with `anthropic/` cache_control and `reasoning_details`.
  @override
  List<Map<String, dynamic>> buildMessages(LlmChatRequest request) {
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
    return encodedMessages;
  }

  /// Builds the OpenRouter `/chat/completions` JSON payload ([D-009]).
  ///
  /// Injects `cache_control: {"type": "ephemeral"}` at most twice (Segment 0 and last
  /// non-empty Segment 1 message) strictly when `modelName` starts with `anthropic/`.
  @override
  Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
    final body = super.buildRequestBody(request);
    body['session_id'] = request.sessionUuid;
    return body;
  }
}
