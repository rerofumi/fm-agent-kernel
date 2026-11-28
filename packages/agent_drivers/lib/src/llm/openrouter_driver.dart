import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';

import 'gateway_cache_policy.dart';
import 'open_ai_compat_driver.dart';

/// OpenRouter `/api/v1/chat/completions` SSE streaming driver ([D-009], [D-403], [D-602]).
///
/// Implements:
/// - `x-session-id` / `session_id` Provider Sticky Routing
/// - Wire-only top-level `cache_control: {"type": "ephemeral"}` injection via [GatewayExplicitCachePolicy]
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

  /// Builds the OpenRouter request headers including Sticky Routing `x-session-id` ([D-009], [D-602]).
  @override
  Map<String, String> buildHeaders(
    LlmChatRequest request, {
    String? apiKey,
  }) {
    return <String, String>{
      ...super.buildHeaders(request, apiKey: apiKey),
      if (request.sessionUuid.trim().isNotEmpty)
        'x-session-id': request.sessionUuid,
      if (httpReferer != null && httpReferer!.isNotEmpty)
        'HTTP-Referer': httpReferer!,
      if (xTitle != null && xTitle!.isNotEmpty) 'X-Title': xTitle!,
    };
  }

  /// Builds the OpenRouter `messages` array with `reasoning_details` echo-back ([D-602]).
  ///
  /// Keeps `content` as a plain `String` across all roles; prompt caching is controlled
  /// via top-level `cache_control` in [buildRequestBody].
  @override
  List<Map<String, dynamic>> buildMessages(LlmChatRequest request) {
    final encoded = super.buildMessages(request);
    final msgs = request.prompt.messages;
    for (var i = 0; i < msgs.length && i < encoded.length; i++) {
      final msg = msgs[i];
      if (msg.role == ProjectedRole.assistant &&
          msg.rawReasoningDetails != null) {
        encoded[i]['reasoning_details'] = msg.rawReasoningDetails;
      }
    }
    return encoded;
  }

  /// Builds the OpenRouter `/chat/completions` JSON payload ([D-009], [D-602]).
  ///
  /// Injects `session_id` when `sessionUuid` is non-empty and top-level
  /// `cache_control: {"type": "ephemeral"}` for models matched by [GatewayExplicitCachePolicy].
  @override
  Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
    final body = super.buildRequestBody(request);
    if (request.sessionUuid.trim().isNotEmpty) {
      body['session_id'] = request.sessionUuid;
    }
    if (GatewayExplicitCachePolicy.supportsTopLevelCacheControl(
      request.model.modelName,
    )) {
      body['cache_control'] = GatewayExplicitCachePolicy.ephemeralCacheControl;
    }
    return body;
  }
}
