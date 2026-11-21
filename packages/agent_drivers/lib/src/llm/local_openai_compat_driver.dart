import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';

import 'open_ai_compat_driver.dart';

/// Local / self-hosted OpenAI-compatible Chat Completions driver (`openai-compat`) ([D-402], [D-403]).
///
/// Supports `llama.cpp` (`llama-server`), Strata, vLLM, and similar servers:
/// - Uses `OPENAI_COMPAT_BASE_URL` or constructor `baseUrl` (throws `EINVAL` when unset)
/// - Normalizes `/v1` and `/v1/chat/completions` without `/v1/v1` duplication
/// - Allows optional `OPENAI_COMPAT_API_KEY` (omits `Authorization` header when unset)
/// - Extracts `timings.cache_n` fallback via [OpenAiCompatDriver]
class LocalOpenAiCompatDriver extends OpenAiCompatDriver {
  LocalOpenAiCompatDriver({
    super.baseUrl,
    super.apiKey,
    super.envLoader,
    super.redactor,
    super.httpClient,
    super.requestTimeout,
  });

  @override
  LlmProviderId get providerId => LlmProviderId.openaiCompat;

  @override
  String get providerDisplayName => 'OpenAI-Compatible';

  @override
  String? get apiKeyEnvVarName => 'OPENAI_COMPAT_API_KEY';

  @override
  bool get requiresApiKey => false;

  /// Normalizes [rawBaseUrl] to `<normalized>/v1/chat/completions` without `/v1/v1` duplication.
  static Uri normalizeChatEndpoint(String rawBaseUrl) {
    var trimmed = rawBaseUrl.trim();
    if (trimmed.isEmpty) {
      throw const LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'MISSING_BASE_URL',
          message: 'OPENAI_COMPAT_BASE_URL is not configured for openai-compat.',
          recoverable: true,
          hint: 'Set OPENAI_COMPAT_BASE_URL or baseUrl in .agent_os/models.json.',
        ),
      );
    }
    if (!trimmed.contains('://')) {
      trimmed = 'http://$trimmed';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_BASE_URL',
          message: 'Invalid OPENAI_COMPAT_BASE_URL: "$rawBaseUrl".',
          recoverable: true,
        ),
      );
    }

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

  /// Derives the server root URI (without `/v1` or `/chat/completions`) for `/props` probing.
  static Uri deriveRootUri(String rawBaseUrl) {
    final chatUri = normalizeChatEndpoint(rawBaseUrl);
    var path = chatUri.path;
    if (path.endsWith('/chat/completions')) {
      path = path.substring(0, path.length - '/chat/completions'.length);
    }
    if (path.endsWith('/v1')) {
      path = path.substring(0, path.length - '/v1'.length);
    }
    return chatUri.replace(path: path);
  }

  @override
  Uri resolveEndpoint() {
    final raw = (explicitBaseUrl != null && explicitBaseUrl!.trim().isNotEmpty)
        ? explicitBaseUrl!.trim()
        : ((envLoader != null
                ? envLoader!.get('OPENAI_COMPAT_BASE_URL')
                : Platform.environment['OPENAI_COMPAT_BASE_URL']) ??
            '');

    if (raw.trim().isEmpty) {
      throw const LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'MISSING_BASE_URL',
          message: 'OPENAI_COMPAT_BASE_URL is not configured for openai-compat.',
          recoverable: true,
          hint: 'Set OPENAI_COMPAT_BASE_URL or baseUrl in .agent_os/models.json.',
        ),
      );
    }
    return normalizeChatEndpoint(raw);
  }

  @override
  String? resolveApiKey() {
    if (explicitApiKey != null && explicitApiKey!.trim().isNotEmpty) {
      final key = explicitApiKey!.trim();
      redactor.registerSecret(key);
      return key;
    }
    final fromEnv = envLoader != null
        ? envLoader!.get('OPENAI_COMPAT_API_KEY')
        : Platform.environment['OPENAI_COMPAT_API_KEY'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      final key = fromEnv.trim();
      redactor.registerSecret(key);
      return key;
    }
    return null;
  }
}
