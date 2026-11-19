import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;

import 'llm_env_loader.dart';
import 'ollama_driver.dart';
import 'openrouter_driver.dart';

/// Configuration and explicit overrides for [ContextWindowResolver] ([D-203], [D-209]).
class ContextWindowConfig {
  const ContextWindowConfig({
    this.modelOverrides = const <String, int>{},
    this.defaultLocalUnloadedCap = 32768,
    this.defaultLocalFallback = 32768,
    this.defaultCloudFallback = 131072,
    this.defaultOpenRouterFallback = 128000,
    this.localProbeTimeout = const Duration(seconds: 3),
    this.remoteProbeTimeout = const Duration(seconds: 5),
  });

  /// Explicit context window overrides keyed by canonical model ID (`<providerId>/<modelName>`).
  final Map<String, int> modelOverrides;

  /// Conservative cap applied to unloaded `local-ollama` models when `OLLAMA_CONTEXT_LENGTH` is unset.
  final int defaultLocalUnloadedCap;

  /// Conservative fallback for `local-ollama` when probing fails.
  final int defaultLocalFallback;

  /// Conservative fallback for `ollama-cloud` when probing fails.
  final int defaultCloudFallback;

  /// Conservative fallback for `openrouter` when catalog lookup fails.
  final int defaultOpenRouterFallback;

  final Duration localProbeTimeout;
  final Duration remoteProbeTimeout;
}

class _OpenRouterModelMeta {
  const _OpenRouterModelMeta({
    required this.contextLength,
    this.maxCompletionTokens,
  });

  final int contextLength;
  final int? maxCompletionTokens;
}

/// 3-provider effective context window resolver with session caching and safe fallbacks ([D-203], [D-204], [D-209]).
class ContextWindowResolver implements ContextWindowSource {
  ContextWindowResolver({
    this.config = const ContextWindowConfig(),
    String? localOllamaBaseUrl,
    String? ollamaCloudBaseUrl,
    String? openRouterBaseUrl,
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
    Map<String, String>? processEnvironment,
  })  : _explicitLocalBaseUrl = localOllamaBaseUrl,
        _explicitCloudBaseUrl = ollamaCloudBaseUrl,
        _explicitOpenRouterBaseUrl = openRouterBaseUrl,
        _envLoader = envLoader,
        _redactor = redactor ?? envLoader?.redactor ?? SecretRedactor(),
        _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _processEnvironment = processEnvironment;

  final ContextWindowConfig config;
  final String? _explicitLocalBaseUrl;
  final String? _explicitCloudBaseUrl;
  final String? _explicitOpenRouterBaseUrl;
  final LlmEnvLoader? _envLoader;
  final SecretRedactor _redactor;
  final http.Client _httpClient;
  final bool _ownsClient;
  final Map<String, String>? _processEnvironment;

  final Map<String, ContextWindowSpec> _localPsCache =
      <String, ContextWindowSpec>{};
  final Map<String, Map<String, dynamic>> _localShowCache =
      <String, Map<String, dynamic>>{};
  final Map<String, ContextWindowSpec> _cloudShowCache =
      <String, ContextWindowSpec>{};
  Map<String, _OpenRouterModelMeta>? _openRouterCatalogCache;

  static final RegExp _numCtxPattern = RegExp(
    r'^\s*num_ctx\s+(\d+)',
    multiLine: true,
    caseSensitive: false,
  );

  @override
  Future<ContextWindowSpec> resolve(
    ModelIdentifier model, {
    bool forceRefreshPs = false,
  }) async {
    // Priority 1: Explicit configuration / test override ([D-203] §3.1(2)).
    final override = config.modelOverrides[model.canonicalId];
    if (override != null && override > 0) {
      return ContextWindowSpec(
        contextWindowTokens: override,
        isLoadedExact: true,
        source: 'override',
      );
    }

    switch (model.provider) {
      case LlmProviderId.localOllama:
        return _resolveLocalOllama(model, forceRefreshPs: forceRefreshPs);
      case LlmProviderId.ollamaCloud:
        return _resolveOllamaCloud(model);
      case LlmProviderId.openRouter:
        return _resolveOpenRouter(model);
    }
  }

  /// Releases the internal HTTP client if owned by this resolver.
  void close() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }

  Future<ContextWindowSpec> _resolveLocalOllama(
    ModelIdentifier model, {
    required bool forceRefreshPs,
  }) async {
    final modelKey = model.modelName;

    if (!forceRefreshPs) {
      final cachedExact = _localPsCache[modelKey];
      if (cachedExact != null && cachedExact.isLoadedExact) {
        return cachedExact;
      }
    }

    final rootUri = _resolveOllamaRootUri(isCloud: false);

    // Step A: Probe GET /api/ps for the exact VRAM-allocated context_length ([D-209] §4.2).
    final psLength = await _probeLocalOllamaPs(rootUri, modelKey);
    if (psLength != null && psLength > 0) {
      final spec = ContextWindowSpec(
        contextWindowTokens: psLength,
        isLoadedExact: true,
        source: 'local-ollama:/api/ps',
      );
      _localPsCache[modelKey] = spec;
      return spec;
    }

    // If previously cached as loaded but no longer reported by /api/ps on refresh, drop stale ps cache.
    if (forceRefreshPs) {
      _localPsCache.remove(modelKey);
    }

    // Step B: Probe POST /api/show (cached per model on success; never negatively cached [D-204]).
    var showPayload = _localShowCache[modelKey];
    if (showPayload == null) {
      showPayload = await _probeOllamaShow(
        rootUri,
        modelKey,
        timeout: config.localProbeTimeout,
      );
      if (showPayload != null) {
        _localShowCache[modelKey] = showPayload;
      }
    }

    if (showPayload != null) {
      // B-1: Explicit `num_ctx` in Modelfile `parameters` string.
      final numCtx = _extractNumCtxFromParameters(showPayload['parameters']);
      if (numCtx != null && numCtx > 0) {
        return ContextWindowSpec(
          contextWindowTokens: numCtx,
          isLoadedExact: false,
          source: 'local-ollama:/api/show:num_ctx',
        );
      }

      // B-2: `min(model_info["*.context_length"], OLLAMA_CONTEXT_LENGTH ?? defaultLocalUnloadedCap)`.
      final archMax = _extractArchContextLength(showPayload['model_info']);
      if (archMax != null && archMax > 0) {
        final envCap = _resolveLocalUnloadedCap();
        return ContextWindowSpec(
          contextWindowTokens: math.min(archMax, envCap),
          isLoadedExact: false,
          source: 'local-ollama:/api/show:capped',
        );
      }
    }

    // Step C: Conservative fallback.
    return ContextWindowSpec(
      contextWindowTokens: config.defaultLocalFallback,
      isLoadedExact: false,
      source: 'fallback:local-ollama',
    );
  }

  Future<ContextWindowSpec> _resolveOllamaCloud(ModelIdentifier model) async {
    final modelKey = model.modelName;
    final cached = _cloudShowCache[modelKey];
    if (cached != null) {
      return cached;
    }

    final rootUri = _resolveOllamaRootUri(isCloud: true);
    final apiKey = _resolveOllamaCloudApiKey();

    final showPayload = await _probeOllamaShow(
      rootUri,
      modelKey,
      apiKey: apiKey,
      timeout: config.remoteProbeTimeout,
    );
    if (showPayload != null) {
      final archMax = _extractArchContextLength(showPayload['model_info']);
      if (archMax != null && archMax > 0) {
        final spec = ContextWindowSpec(
          contextWindowTokens: archMax,
          isLoadedExact: true,
          source: 'ollama-cloud:/api/show',
        );
        _cloudShowCache[modelKey] = spec;
        return spec;
      }
    }

    return ContextWindowSpec(
      contextWindowTokens: config.defaultCloudFallback,
      isLoadedExact: false,
      source: 'fallback:ollama-cloud',
    );
  }

  Future<ContextWindowSpec> _resolveOpenRouter(ModelIdentifier model) async {
    var catalog = _openRouterCatalogCache;
    if (catalog == null) {
      catalog = await _fetchOpenRouterCatalog();
      if (catalog != null) {
        _openRouterCatalogCache = catalog;
      }
    }

    if (catalog != null) {
      final meta = catalog[model.modelName];
      if (meta != null && meta.contextLength > 0) {
        return ContextWindowSpec(
          contextWindowTokens: meta.contextLength,
          maxCompletionTokens: meta.maxCompletionTokens,
          isLoadedExact: true,
          source: 'openrouter:/models',
        );
      }
    }

    return ContextWindowSpec(
      contextWindowTokens: config.defaultOpenRouterFallback,
      isLoadedExact: false,
      source: 'fallback:openrouter',
    );
  }

  Future<int?> _probeLocalOllamaPs(Uri rootUri, String modelName) async {
    final uri = _appendPath(rootUri, '/api/ps');
    try {
      final response = await _httpClient
          .get(uri, headers: const <String, String>{'Accept': 'application/json'})
          .timeout(config.localProbeTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return null;
      }
      final models = decoded['models'];
      if (models is! List) {
        return null;
      }
      for (final item in models) {
        if (item is! Map) {
          continue;
        }
        final entryName = (item['name'] as String?) ?? (item['model'] as String?);
        if (entryName == null) {
          continue;
        }
        if (_ollamaModelNamesMatch(entryName, modelName)) {
          final ctx = (item['context_length'] as num?)?.toInt();
          if (ctx != null && ctx > 0) {
            return ctx;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _probeOllamaShow(
    Uri rootUri,
    String modelName, {
    String? apiKey,
    required Duration timeout,
  }) async {
    final uri = _appendPath(rootUri, '/api/show');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
    try {
      final response = await _httpClient
          .post(
            uri,
            headers: headers,
            body: jsonEncode(<String, dynamic>{'model': modelName}),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, _OpenRouterModelMeta>?> _fetchOpenRouterCatalog() async {
    final uri = _resolveOpenRouterModelsUri();
    final apiKey = _resolveEnv('OPENROUTER_API_KEY');
    if (apiKey != null) {
      _redactor.registerSecret(apiKey);
    }
    final headers = <String, String>{
      'Accept': 'application/json',
      if (apiKey != null) 'Authorization': 'Bearer $apiKey',
    };
    try {
      final response = await _httpClient
          .get(uri, headers: headers)
          .timeout(config.remoteProbeTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return null;
      }
      final data = decoded['data'];
      if (data is! List) {
        return null;
      }
      final map = <String, _OpenRouterModelMeta>{};
      for (final item in data) {
        if (item is! Map) {
          continue;
        }
        final id = item['id'];
        if (id is! String || id.trim().isEmpty) {
          continue;
        }
        final topProvider = item['top_provider'];
        int? topCtx;
        int? topMaxComp;
        if (topProvider is Map) {
          topCtx = (topProvider['context_length'] as num?)?.toInt();
          topMaxComp = (topProvider['max_completion_tokens'] as num?)?.toInt();
        }
        final rootCtx = (item['context_length'] as num?)?.toInt();
        final resolvedCtx =
            (topCtx != null && topCtx > 0) ? topCtx : rootCtx;
        if (resolvedCtx != null && resolvedCtx > 0) {
          map[id.trim()] = _OpenRouterModelMeta(
            contextLength: resolvedCtx,
            maxCompletionTokens:
                (topMaxComp != null && topMaxComp > 0) ? topMaxComp : null,
          );
        }
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  Uri _resolveOllamaRootUri({required bool isCloud}) {
    final String raw;
    if (isCloud) {
      raw = _nonEmpty(_explicitCloudBaseUrl) ??
          _resolveEnv('OLLAMA_CLOUD_HOST') ??
          OllamaDriver.defaultCloudBaseUrl;
    } else {
      raw = _nonEmpty(_explicitLocalBaseUrl) ??
          _resolveEnv('OLLAMA_HOST') ??
          OllamaDriver.defaultLocalBaseUrl;
    }
    final chatUri = OllamaDriver.normalizeChatEndpoint(raw);
    var path = chatUri.path;
    if (path.endsWith('/api/chat')) {
      path = path.substring(0, path.length - '/api/chat'.length);
    }
    return chatUri.replace(path: path);
  }

  Uri _resolveOpenRouterModelsUri() {
    var raw = _nonEmpty(_explicitOpenRouterBaseUrl) ??
        _resolveEnv('OPENROUTER_BASE_URL') ??
        OpenRouterDriver.defaultBaseUrl;
    if (raw.isEmpty) {
      raw = OpenRouterDriver.defaultBaseUrl;
    }
    final uri = Uri.parse(raw);
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
    if (path.endsWith('/api/v1') || path.endsWith('/v1')) {
      return uri.replace(path: '$path/models');
    }
    return uri.replace(path: '$path/api/v1/models');
  }

  String? _resolveOllamaCloudApiKey() {
    final key =
        _resolveEnv('OLLAMA_API_KEY') ?? _resolveEnv('OLLAMA_CLOUD_API_KEY');
    if (key != null) {
      _redactor.registerSecret(key);
    }
    return key;
  }

  int _resolveLocalUnloadedCap() {
    final raw = _resolveEnv('OLLAMA_CONTEXT_LENGTH');
    if (raw != null) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }
    return config.defaultLocalUnloadedCap;
  }

  String? _resolveEnv(String key) {
    final fromLoader = _envLoader?.get(key);
    if (fromLoader != null && fromLoader.trim().isNotEmpty) {
      return fromLoader.trim();
    }
    final envMap = _processEnvironment ?? Platform.environment;
    final fromProc = envMap[key];
    if (fromProc != null && fromProc.trim().isNotEmpty) {
      return fromProc.trim();
    }
    return null;
  }

  static Uri _appendPath(Uri root, String suffix) {
    var base = root.path;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return root.replace(path: '$base$suffix');
  }

  static String? _nonEmpty(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static bool _ollamaModelNamesMatch(String psEntryName, String requestedName) {
    final a = psEntryName.trim();
    final b = requestedName.trim();
    if (a == b) {
      return true;
    }
    final aNorm = a.contains(':') ? a : '$a:latest';
    final bNorm = b.contains(':') ? b : '$b:latest';
    return aNorm == bNorm;
  }

  static int? _extractNumCtxFromParameters(Object? rawParameters) {
    if (rawParameters is! String || rawParameters.isEmpty) {
      return null;
    }
    final match = _numCtxPattern.firstMatch(rawParameters);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1)!);
  }

  static int? _extractArchContextLength(Object? rawModelInfo) {
    if (rawModelInfo is! Map) {
      return null;
    }
    int? maxVal;
    for (final entry in rawModelInfo.entries) {
      final key = entry.key.toString();
      if (key == 'context_length' || key.endsWith('.context_length')) {
        final val = (entry.value as num?)?.toInt();
        if (val != null && val > 0) {
          if (maxVal == null || val > maxVal) {
            maxVal = val;
          }
        }
      }
    }
    return maxVal;
  }
}
