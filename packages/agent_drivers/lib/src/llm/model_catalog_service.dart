import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;

import 'models_config.dart';
import 'ollama_driver.dart';
import 'openrouter_driver.dart';

/// A single chat-capable model entry resolved by [ModelCatalogService] ([D-409]).
class ModelCatalogEntry {
  const ModelCatalogEntry({
    required this.id,
    required this.provider,
    required this.modelName,
    String? displayName,
    String? description,
    this.isManual = false,
  })  : displayName = displayName ?? id,
        description = description ?? id;

  /// Canonical `<providerId>/<modelName>` identifier.
  final String id;
  final LlmProviderId provider;
  final String modelName;
  final String displayName;
  final String description;
  final bool isManual;

  ModelIdentifier get identifier =>
      ModelIdentifier(provider: provider, modelName: modelName);

  @override
  bool operator ==(Object other) {
    return other is ModelCatalogEntry &&
        other.id == id &&
        other.provider == provider &&
        other.modelName == modelName &&
        other.displayName == displayName &&
        other.description == description &&
        other.isManual == isManual;
  }

  @override
  int get hashCode =>
      Object.hash(id, provider, modelName, displayName, description, isManual);
}

/// Fetches chat-capable models once at startup with in-memory caching,
/// single-flight deduplication, and per-provider fault isolation ([D-409]).
class ModelCatalogService {
  ModelCatalogService({
    http.Client? httpClient,
    SecretRedactor? redactor,
    this.localTimeout = const Duration(seconds: 3),
    this.cloudTimeout = const Duration(seconds: 5),
    void Function(String warning)? onWarning,
    this.localOllamaBaseUrl,
    this.ollamaCloudBaseUrl,
    this.openRouterBaseUrl,
    this.openAiBaseUrl,
    this.geminiBaseUrl,
    this.nousPortalBaseUrl,
    this.openAiCompatBaseUrl,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _redactor = redactor ?? SecretRedactor(),
        _onWarning = onWarning;

  static const String defaultOpenAiBaseUrl = 'https://api.openai.com/v1';
  static const String defaultGeminiBaseUrl =
      'https://generativelanguage.googleapis.com';
  static const String defaultNousPortalBaseUrl =
      'https://inference-api.nousresearch.com/v1';

  static const List<String> _openAiExcludedPrefixes = <String>[
    'whisper-',
    'tts-',
    'dall-e-',
    'text-embedding-',
    'embedding-',
    'omni-moderation-',
    'text-moderation-',
    'babbage-',
    'davinci-',
    'gpt-image-',
    'chatgpt-image-',
    'sora-',
    'gpt-audio',
    'gpt-live-',
  ];

  static const List<String> _openAiExcludedSubstrings = <String>[
    '-tts',
    '-realtime',
    '-transcribe',
  ];

  final http.Client _httpClient;
  final bool _ownsClient;
  final SecretRedactor _redactor;
  final Duration localTimeout;
  final Duration cloudTimeout;
  final void Function(String warning)? _onWarning;

  final String? localOllamaBaseUrl;
  final String? ollamaCloudBaseUrl;
  final String? openRouterBaseUrl;
  final String? openAiBaseUrl;
  final String? geminiBaseUrl;
  final String? nousPortalBaseUrl;
  final String? openAiCompatBaseUrl;

  final Map<LlmProviderId, List<ModelCatalogEntry>> _fetchedCache =
      <LlmProviderId, List<ModelCatalogEntry>>{};
  final Map<LlmProviderId, Future<List<ModelCatalogEntry>>> _inFlightFetches =
      <LlmProviderId, Future<List<ModelCatalogEntry>>>{};
  final Set<LlmProviderId> _attemptedProviders = <LlmProviderId>{};
  final List<String> _warnings = <String>[];

  /// Non-fatal warnings recorded during catalog fetches (secrets redacted).
  UnmodifiableListView<String> get warnings =>
      UnmodifiableListView<String>(_warnings);

  /// Whether [provider] has already been fetched (or attempted) in this process.
  bool hasAttemptedProvider(LlmProviderId provider) =>
      _attemptedProviders.contains(provider);

  /// Resolves the available chat models under [policy], fetching each enabled
  /// `autoFetch: true` provider at most once in parallel ([D-409], [D-407]).
  Future<List<ModelCatalogEntry>> resolveOptions(ModelPolicy policy) async {
    final fetchFutures = <Future<List<ModelCatalogEntry>>>[];
    for (final provider in LlmProviderId.values) {
      if (!policy.isProviderEnabled(provider) ||
          !policy.configFor(provider).autoFetch) {
        continue;
      }
      if (_attemptedProviders.contains(provider)) {
        continue;
      }
      final inFlight = _inFlightFetches[provider];
      if (inFlight != null) {
        fetchFutures.add(inFlight);
      } else {
        final future = _fetchProviderWithGuard(provider, policy);
        _inFlightFetches[provider] = future;
        fetchFutures.add(future);
      }
    }

    if (fetchFutures.isNotEmpty) {
      await Future.wait<List<ModelCatalogEntry>>(fetchFutures);
    }

    final resolved = <ModelCatalogEntry>[];
    for (final provider in LlmProviderId.values) {
      if (!policy.isProviderEnabled(provider)) {
        continue;
      }
      final cfg = policy.configFor(provider);
      final manualEntries = <ModelCatalogEntry>[
        for (final modelName in cfg.models)
          ModelCatalogEntry(
            id: '${provider.id}/$modelName',
            provider: provider,
            modelName: modelName,
            displayName: '${provider.id}/$modelName',
            description: 'Configured ${provider.id} model',
            isManual: true,
          ),
      ];
      final fetchedEntries = cfg.autoFetch
          ? (_fetchedCache[provider] ?? const <ModelCatalogEntry>[])
          : const <ModelCatalogEntry>[];
      resolved.addAll(
        policy.mergeCatalogEntries<ModelCatalogEntry>(
          provider: provider,
          manualEntries: manualEntries,
          fetchedEntries: fetchedEntries,
          canonicalIdOf: (entry) => entry.id,
        ),
      );
    }
    return resolved;
  }

  /// Releases the underlying HTTP client if owned by this service.
  void close() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }

  Future<List<ModelCatalogEntry>> _fetchProviderWithGuard(
    LlmProviderId provider,
    ModelPolicy policy,
  ) async {
    final timeout = _isLocalProvider(provider) ? localTimeout : cloudTimeout;
    try {
      final entries = await _fetchProvider(provider, policy).timeout(timeout);
      _fetchedCache[provider] = List<ModelCatalogEntry>.unmodifiable(entries);
      return entries;
    } catch (e) {
      final safeError = _redactText(e.toString(), policy);
      _recordWarning(
        'Model catalog fetch failed for ${provider.id}: $safeError',
      );
      _fetchedCache[provider] = const <ModelCatalogEntry>[];
      return const <ModelCatalogEntry>[];
    } finally {
      _attemptedProviders.add(provider);
      _inFlightFetches.remove(provider);
    }
  }

  Future<List<ModelCatalogEntry>> _fetchProvider(
    LlmProviderId provider,
    ModelPolicy policy,
  ) async {
    final endpoint = _resolveModelsUri(provider, policy);
    final headers = _buildHeaders(provider, policy);

    final response = await _httpClient.get(endpoint, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final safeBody = _redactText(response.body, policy);
      throw StateError(
        'HTTP ${response.statusCode} from $endpoint: $safeBody',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Expected JSON object from models endpoint.');
    }

    switch (provider) {
      case LlmProviderId.localOllama:
      case LlmProviderId.ollamaCloud:
        return _parseOllamaTags(provider, decoded);
      case LlmProviderId.openRouter:
        return _parseOpenRouterModels(decoded);
      case LlmProviderId.openai:
        return _parseOpenAiModels(decoded);
      case LlmProviderId.gemini:
        return _parseGeminiModels(decoded);
      case LlmProviderId.nousPortal:
        return _parseNousPortalModels(decoded);
      case LlmProviderId.openaiCompat:
        return _parseOpenAiCompatModels(decoded);
    }
  }

  List<ModelCatalogEntry> _parseOllamaTags(
    LlmProviderId provider,
    Map<dynamic, dynamic> decoded,
  ) {
    final rawModels = decoded['models'];
    if (rawModels is! List) {
      return const <ModelCatalogEntry>[];
    }
    final entries = <ModelCatalogEntry>[];
    for (final item in rawModels) {
      if (item is! Map) {
        continue;
      }
      final rawName = (item['name'] ?? item['model'])?.toString().trim() ?? '';
      if (rawName.isEmpty) {
        continue;
      }
      final capabilities = item['capabilities'];
      if (capabilities is List) {
        if (!capabilities.contains('completion')) {
          continue;
        }
      } else if (rawName.toLowerCase().contains('embed')) {
        continue;
      }
      entries.add(
        ModelCatalogEntry(
          id: '${provider.id}/$rawName',
          provider: provider,
          modelName: rawName,
          displayName: '${provider.id}/$rawName',
          description: 'Fetched from ${provider.id}',
        ),
      );
    }
    return entries;
  }

  List<ModelCatalogEntry> _parseOpenRouterModels(
    Map<dynamic, dynamic> decoded,
  ) {
    final rawData = decoded['data'];
    if (rawData is! List) {
      return const <ModelCatalogEntry>[];
    }
    final entries = <ModelCatalogEntry>[];
    for (final item in rawData) {
      if (item is! Map) {
        continue;
      }
      final id = item['id']?.toString().trim() ?? '';
      if (id.isEmpty) {
        continue;
      }
      final arch = item['architecture'];
      if (arch is Map && arch['output_modalities'] is List) {
        final modalities = arch['output_modalities'] as List;
        if (!modalities.contains('text')) {
          continue;
        }
      }
      final name = item['name']?.toString().trim();
      entries.add(
        ModelCatalogEntry(
          id: '${LlmProviderId.openRouter.id}/$id',
          provider: LlmProviderId.openRouter,
          modelName: id,
          displayName: (name != null && name.isNotEmpty)
              ? '${LlmProviderId.openRouter.id}/$id ($name)'
              : '${LlmProviderId.openRouter.id}/$id',
          description: 'Fetched from openrouter',
        ),
      );
    }
    return entries;
  }

  List<ModelCatalogEntry> _parseOpenAiModels(Map<dynamic, dynamic> decoded) {
    final rawData = decoded['data'];
    if (rawData is! List) {
      return const <ModelCatalogEntry>[];
    }
    final entries = <ModelCatalogEntry>[];
    for (final item in rawData) {
      if (item is! Map) {
        continue;
      }
      final id = item['id']?.toString().trim() ?? '';
      if (id.isEmpty || _isExcludedOpenAiModel(id)) {
        continue;
      }
      entries.add(
        ModelCatalogEntry(
          id: '${LlmProviderId.openai.id}/$id',
          provider: LlmProviderId.openai,
          modelName: id,
          displayName: '${LlmProviderId.openai.id}/$id',
          description: 'Fetched from openai',
        ),
      );
    }
    return entries;
  }

  static bool _isExcludedOpenAiModel(String id) {
    final lower = id.toLowerCase();
    for (final prefix in _openAiExcludedPrefixes) {
      if (lower.startsWith(prefix)) {
        return true;
      }
    }
    for (final substr in _openAiExcludedSubstrings) {
      if (lower.contains(substr)) {
        return true;
      }
    }
    return false;
  }

  List<ModelCatalogEntry> _parseGeminiModels(Map<dynamic, dynamic> decoded) {
    final rawModels = decoded['models'];
    if (rawModels is! List) {
      return const <ModelCatalogEntry>[];
    }
    final entries = <ModelCatalogEntry>[];
    for (final item in rawModels) {
      if (item is! Map) {
        continue;
      }
      final methods = item['supportedGenerationMethods'];
      if (methods is! List || !methods.contains('generateContent')) {
        continue;
      }
      var rawName = item['name']?.toString().trim() ?? '';
      if (rawName.startsWith('models/')) {
        rawName = rawName.substring('models/'.length).trim();
      }
      if (rawName.isEmpty) {
        continue;
      }
      final display = item['displayName']?.toString().trim();
      entries.add(
        ModelCatalogEntry(
          id: '${LlmProviderId.gemini.id}/$rawName',
          provider: LlmProviderId.gemini,
          modelName: rawName,
          displayName: (display != null && display.isNotEmpty)
              ? '${LlmProviderId.gemini.id}/$rawName ($display)'
              : '${LlmProviderId.gemini.id}/$rawName',
          description: 'Fetched from gemini',
        ),
      );
    }
    return entries;
  }

  List<ModelCatalogEntry> _parseNousPortalModels(
    Map<dynamic, dynamic> decoded,
  ) {
    final rawData = decoded['data'];
    if (rawData is! List) {
      return const <ModelCatalogEntry>[];
    }
    final entries = <ModelCatalogEntry>[];
    for (final item in rawData) {
      if (item is! Map) {
        continue;
      }
      final id = item['id']?.toString().trim() ?? '';
      if (id.isEmpty) {
        continue;
      }
      final lower = id.toLowerCase();
      if (lower.endsWith(':batch')) {
        continue;
      }
      final arch = item['architecture'];
      if (arch is Map && arch['output_modalities'] is List) {
        final modalities = arch['output_modalities'] as List;
        if (!modalities.contains('text')) {
          continue;
        }
      } else if (lower.contains('embed') || lower.contains('rerank')) {
        continue;
      }
      entries.add(
        ModelCatalogEntry(
          id: '${LlmProviderId.nousPortal.id}/$id',
          provider: LlmProviderId.nousPortal,
          modelName: id,
          displayName: '${LlmProviderId.nousPortal.id}/$id',
          description: 'Fetched from nous-portal',
        ),
      );
    }
    return entries;
  }

  List<ModelCatalogEntry> _parseOpenAiCompatModels(
    Map<dynamic, dynamic> decoded,
  ) {
    final rawData = decoded['data'];
    if (rawData is! List) {
      return const <ModelCatalogEntry>[];
    }
    final entries = <ModelCatalogEntry>[];
    for (final item in rawData) {
      if (item is! Map) {
        continue;
      }
      final id = item['id']?.toString().trim() ?? '';
      if (id.isEmpty) {
        continue;
      }
      final lower = id.toLowerCase();
      if (lower.contains('embed') || lower.contains('rerank')) {
        continue;
      }
      entries.add(
        ModelCatalogEntry(
          id: '${LlmProviderId.openaiCompat.id}/$id',
          provider: LlmProviderId.openaiCompat,
          modelName: id,
          displayName: '${LlmProviderId.openaiCompat.id}/$id',
          description: 'Fetched from openai-compat',
        ),
      );
    }
    return entries;
  }

  Uri _resolveModelsUri(LlmProviderId provider, ModelPolicy policy) {
    final cfgUrl = policy.configFor(provider).baseUrl;
    switch (provider) {
      case LlmProviderId.localOllama:
        final raw = localOllamaBaseUrl ??
            cfgUrl ??
            policy.envLoader.get('OLLAMA_HOST') ??
            OllamaDriver.defaultLocalBaseUrl;
        return _normalizeOllamaTagsUri(raw);
      case LlmProviderId.ollamaCloud:
        final raw = ollamaCloudBaseUrl ??
            cfgUrl ??
            policy.envLoader.get('OLLAMA_CLOUD_HOST') ??
            OllamaDriver.defaultCloudBaseUrl;
        return _normalizeOllamaTagsUri(raw);
      case LlmProviderId.openRouter:
        final raw = openRouterBaseUrl ??
            cfgUrl ??
            policy.envLoader.get('OPENROUTER_BASE_URL') ??
            OpenRouterDriver.defaultBaseUrl;
        return _normalizeV1ModelsUri(raw);
      case LlmProviderId.openai:
        final raw = openAiBaseUrl ??
            cfgUrl ??
            policy.envLoader.get('OPENAI_BASE_URL') ??
            defaultOpenAiBaseUrl;
        return _normalizeV1ModelsUri(raw);
      case LlmProviderId.gemini:
        final raw = geminiBaseUrl ??
            cfgUrl ??
            policy.envLoader.get('GEMINI_BASE_URL') ??
            defaultGeminiBaseUrl;
        return _normalizeGeminiModelsUri(raw);
      case LlmProviderId.nousPortal:
        final raw = nousPortalBaseUrl ??
            cfgUrl ??
            policy.envLoader.get('NOUS_BASE_URL') ??
            defaultNousPortalBaseUrl;
        return _normalizeV1ModelsUri(raw);
      case LlmProviderId.openaiCompat:
        final raw = openAiCompatBaseUrl ?? policy.resolveOpenAiCompatBaseUrl();
        if (raw == null || raw.trim().isEmpty) {
          throw StateError('openai-compat baseUrl is not configured.');
        }
        return _normalizeV1ModelsUri(raw);
    }
  }

  Map<String, String> _buildHeaders(
    LlmProviderId provider,
    ModelPolicy policy,
  ) {
    final headers = <String, String>{
      'Accept': 'application/json',
    };
    switch (provider) {
      case LlmProviderId.localOllama:
        break;
      case LlmProviderId.ollamaCloud:
        final key = policy.envLoader.get('OLLAMA_API_KEY') ??
            policy.envLoader.get('OLLAMA_CLOUD_API_KEY');
        if (key != null) {
          headers['Authorization'] = 'Bearer $key';
        }
      case LlmProviderId.openRouter:
        final key = policy.envLoader.get('OPENROUTER_API_KEY');
        if (key != null) {
          headers['Authorization'] = 'Bearer $key';
        }
      case LlmProviderId.openai:
        final key = policy.envLoader.get('OPENAI_API_KEY');
        if (key != null) {
          headers['Authorization'] = 'Bearer $key';
        }
      case LlmProviderId.gemini:
        final key = policy.envLoader.get('GEMINI_API_KEY') ??
            policy.envLoader.get('GOOGLE_API_KEY');
        if (key != null) {
          headers['x-goog-api-key'] = key;
        }
      case LlmProviderId.nousPortal:
        final key = policy.envLoader.get('NOUS_API_KEY');
        if (key != null) {
          headers['Authorization'] = 'Bearer $key';
        }
      case LlmProviderId.openaiCompat:
        final key = policy.envLoader.get('OPENAI_COMPAT_API_KEY');
        if (key != null) {
          headers['Authorization'] = 'Bearer $key';
        }
    }
    return headers;
  }

  static bool _isLocalProvider(LlmProviderId provider) {
    return provider == LlmProviderId.localOllama ||
        provider == LlmProviderId.openaiCompat;
  }

  static Uri _normalizeOllamaTagsUri(String rawBaseUrl) {
    final chatUri = OllamaDriver.normalizeChatEndpoint(rawBaseUrl);
    var path = chatUri.path;
    if (path.endsWith('/api/chat')) {
      path = path.substring(0, path.length - '/api/chat'.length);
    }
    return chatUri.replace(path: '$path/api/tags');
  }

  static Uri _normalizeV1ModelsUri(String rawBaseUrl) {
    var trimmed = rawBaseUrl.trim();
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed);
    if (!hasScheme) {
      trimmed = 'http://$trimmed';
    }
    final uri = Uri.parse(trimmed);
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.endsWith('/chat/completions')) {
      path = path.substring(0, path.length - '/chat/completions'.length);
    }
    if (path.endsWith('/models')) {
      return uri.replace(path: path);
    }
    if (!path.endsWith('/v1')) {
      path = '$path/v1';
    }
    return uri.replace(path: '$path/models');
  }

  static Uri _normalizeGeminiModelsUri(String rawBaseUrl) {
    var trimmed = rawBaseUrl.trim();
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed);
    if (!hasScheme) {
      trimmed = 'https://$trimmed';
    }
    final uri = Uri.parse(trimmed);
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.endsWith('/v1beta/models')) {
      return uri.replace(path: path);
    }
    if (!path.endsWith('/v1beta')) {
      path = '$path/v1beta';
    }
    return uri.replace(path: '$path/models');
  }

  String _redactText(String input, ModelPolicy policy) {
    var result = _redactor.redactString(input);
    result = policy.envLoader.redactor.redactString(result);
    return result;
  }

  void _recordWarning(String warning) {
    _warnings.add(warning);
    _onWarning?.call(warning);
  }
}
