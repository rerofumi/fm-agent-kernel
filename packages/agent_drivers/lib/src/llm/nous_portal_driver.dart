import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';

import 'gateway_cache_policy.dart';
import 'open_ai_compat_driver.dart';

/// Nous Portal (`inference-api.nousresearch.com/v1`) SSE streaming driver ([D-402], [D-403], [D-603]).
///
/// Implements:
/// - `NOUS_API_KEY` Bearer authentication
/// - `x-session-id` / `session_id` Sticky Session routing and top-level `cache_control` via [GatewayExplicitCachePolicy]
/// - `stream_options: {"include_usage": true}` with EOF completion when `[DONE]` is omitted
/// - Extraction & same-model echo-back of `reasoning_content` / `reasoning_details`
/// - `usage.cost` to `costMicroUsd` conversion via [OpenAiCompatDriver]
class NousPortalDriver extends OpenAiCompatDriver {
  NousPortalDriver({
    super.baseUrl,
    super.apiKey,
    super.envLoader,
    super.redactor,
    super.httpClient,
    super.requestTimeout,
  });

  static const String defaultBaseUrl =
      'https://inference-api.nousresearch.com/v1';

  @override
  LlmProviderId get providerId => LlmProviderId.nousPortal;

  @override
  String get providerDisplayName => 'Nous Portal';

  @override
  String get apiKeyEnvVarName => 'NOUS_API_KEY';

  @override
  Uri resolveEndpoint() {
    var raw = (explicitBaseUrl != null && explicitBaseUrl!.trim().isNotEmpty)
        ? explicitBaseUrl!.trim()
        : ((envLoader != null
                ? envLoader!.get('NOUS_BASE_URL')
                : Platform.environment['NOUS_BASE_URL']) ??
            defaultBaseUrl);

    if (raw.isEmpty) {
      raw = defaultBaseUrl;
    }
    final uri = Uri.parse(raw);
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.endsWith('/chat/completions')) {
      return uri.replace(path: path);
    }
    if (path.endsWith('/v1')) {
      return uri.replace(path: '$path/chat/completions');
    }
    return uri.replace(path: '$path/v1/chat/completions');
  }

  @override
  String? resolveApiKey() {
    if (explicitApiKey != null && explicitApiKey!.trim().isNotEmpty) {
      final key = explicitApiKey!.trim();
      redactor.registerSecret(key);
      return key;
    }
    final fromEnv = envLoader != null
        ? envLoader!.get('NOUS_API_KEY')
        : Platform.environment['NOUS_API_KEY'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      final key = fromEnv.trim();
      redactor.registerSecret(key);
      return key;
    }
    return null;
  }

  @override
  Map<String, String> buildHeaders(
    LlmChatRequest request, {
    String? apiKey,
  }) {
    return <String, String>{
      ...super.buildHeaders(request, apiKey: apiKey),
      if (request.sessionUuid.trim().isNotEmpty)
        'x-session-id': request.sessionUuid,
    };
  }

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

  @override
  Object? buildRawReasoningDetails({
    required List<dynamic> collectedReasoningDetails,
    required Object? singleReasoningDetails,
    required StringBuffer thoughtBuffer,
  }) {
    final hasThought = thoughtBuffer.isNotEmpty;
    final hasDetails =
        collectedReasoningDetails.isNotEmpty || singleReasoningDetails != null;
    if (!hasThought && !hasDetails) {
      return null;
    }
    return Map<String, dynamic>.unmodifiable(<String, dynamic>{
      if (hasThought) 'reasoning_content': thoughtBuffer.toString(),
      if (collectedReasoningDetails.isNotEmpty)
        'reasoning_details':
            List<dynamic>.unmodifiable(collectedReasoningDetails)
      else
        'reasoning_details': ?singleReasoningDetails,
    });
  }

  @override
  List<Map<String, dynamic>> buildMessages(LlmChatRequest request) {
    final encoded = super.buildMessages(request);
    final msgs = request.prompt.messages;
    for (var i = 0; i < msgs.length && i < encoded.length; i++) {
      final msg = msgs[i];
      if (msg.role != ProjectedRole.assistant ||
          msg.rawReasoningDetails == null) {
        continue;
      }
      final raw = msg.rawReasoningDetails;
      if (raw is Map) {
        final reasoningContent = raw['reasoning_content'];
        if (reasoningContent is String && reasoningContent.isNotEmpty) {
          encoded[i]['reasoning_content'] = reasoningContent;
        }
        final reasoningDetails = raw['reasoning_details'];
        if (reasoningDetails != null) {
          encoded[i]['reasoning_details'] = reasoningDetails;
        }
      } else if (raw is String && raw.isNotEmpty) {
        encoded[i]['reasoning_content'] = raw;
      } else if (raw is List) {
        encoded[i]['reasoning_details'] = raw;
      }
    }
    return encoded;
  }
}
