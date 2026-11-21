import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';

import 'open_ai_compat_driver.dart';

/// OpenAI `/v1/chat/completions` SSE streaming driver ([D-402], [D-403]).
///
/// Implements:
/// - `OPENAI_API_KEY` Bearer authentication
/// - `stream_options: {"include_usage": true}` during streaming
/// - Reasoning model (`o1`, `o3`, `o4`, `gpt-5` families) parameter constraints:
///   converts `max_tokens` to `max_completion_tokens` and omits `temperature`
class OpenAiDriver extends OpenAiCompatDriver {
  OpenAiDriver({
    super.baseUrl,
    super.apiKey,
    super.envLoader,
    super.redactor,
    super.httpClient,
    super.requestTimeout,
  });

  static const String defaultBaseUrl = 'https://api.openai.com/v1';

  static final RegExp _reasoningModelPattern = RegExp(
    r'^(o1|o3|o4|gpt-5)(?:$|[-._])',
    caseSensitive: false,
  );

  /// Returns `true` when [modelName] belongs to an OpenAI reasoning model family
  /// (`o1`, `o3`, `o4`, `gpt-5` prefixes, case-insensitive).
  static bool isReasoningModel(String modelName) {
    return _reasoningModelPattern.hasMatch(modelName.trim());
  }

  @override
  LlmProviderId get providerId => LlmProviderId.openai;

  @override
  String get providerDisplayName => 'OpenAI';

  @override
  String get apiKeyEnvVarName => 'OPENAI_API_KEY';

  @override
  Uri resolveEndpoint() {
    var raw = (explicitBaseUrl != null && explicitBaseUrl!.trim().isNotEmpty)
        ? explicitBaseUrl!.trim()
        : ((envLoader != null
                ? envLoader!.get('OPENAI_BASE_URL')
                : Platform.environment['OPENAI_BASE_URL']) ??
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
        ? envLoader!.get('OPENAI_API_KEY')
        : Platform.environment['OPENAI_API_KEY'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      final key = fromEnv.trim();
      redactor.registerSecret(key);
      return key;
    }
    return null;
  }

  @override
  Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
    final body = super.buildRequestBody(request);
    if (isReasoningModel(request.model.modelName)) {
      body.remove('temperature');
      final maxTokens = body.remove('max_tokens');
      if (maxTokens != null) {
        body['max_completion_tokens'] = maxTokens;
      }
    }
    return body;
  }
}
