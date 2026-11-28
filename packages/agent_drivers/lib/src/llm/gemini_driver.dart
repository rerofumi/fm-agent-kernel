import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'llm_env_loader.dart';

class _GeminiCachedContentEntry {
  _GeminiCachedContentEntry({
    required this.cacheKey,
    required this.resourceName,
    required this.expireTime,
    required this.lastUsedAt,
    this.totalTokenCount,
  });

  final String cacheKey;
  final String resourceName;
  DateTime expireTime;
  DateTime lastUsedAt;
  final int? totalTokenCount;
}

class _PreparedSegment0 {
  _PreparedSegment0({
    required this.cacheKey,
    required this.modelResourceName,
    required this.systemInstruction,
    required this.tools,
  });

  final String cacheKey;
  final String modelResourceName;
  final Map<String, dynamic>? systemInstruction;
  final List<Map<String, dynamic>>? tools;
}

/// Google AI Studio (`v1beta`) native REST driver for Gemini ([D-402], [D-404], [D-607]).
///
/// Implements:
/// - `POST .../v1beta/models/{model}:streamGenerateContent?alt=sse` (or `:generateContent`)
/// - Native explicit Context Caching via `v1beta/cachedContents` (`POST` / `PATCH` / `DELETE`)
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
    bool? enableExplicitCaching,
    Duration? explicitCacheTtl,
    Duration explicitCacheRenewWindow = const Duration(seconds: 60),
    int? explicitCacheMinTokensOverride,
    int maxCachedEntries = 4,
    DateTime Function()? clock,
  })  : _explicitBaseUrl = baseUrl,
        _explicitApiKey = apiKey,
        _envLoader = envLoader,
        _redactor = redactor ?? envLoader?.redactor ?? SecretRedactor(),
        _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _explicitEnableCaching = enableExplicitCaching,
        _explicitCacheTtl = explicitCacheTtl,
        _explicitCacheRenewWindow = explicitCacheRenewWindow,
        _explicitCacheMinTokensOverride = explicitCacheMinTokensOverride,
        _maxCachedEntries = maxCachedEntries < 1 ? 1 : maxCachedEntries,
        _clock = clock ?? (() => DateTime.now().toUtc()) {
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      _redactor.registerSecret(apiKey);
    }
  }

  static const String defaultBaseUrl =
      'https://generativelanguage.googleapis.com';

  static const Duration _defaultExplicitCacheTtl = Duration(seconds: 300);

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
  final bool? _explicitEnableCaching;
  final Duration? _explicitCacheTtl;
  final Duration _explicitCacheRenewWindow;
  final int? _explicitCacheMinTokensOverride;
  final int _maxCachedEntries;
  final DateTime Function() _clock;

  final Map<String, _GeminiCachedContentEntry> _cacheEntries =
      <String, _GeminiCachedContentEntry>{};
  final Map<String, Future<_GeminiCachedContentEntry?>> _inFlightCreates =
      <String, Future<_GeminiCachedContentEntry?>>{};
  final Map<String, DateTime> _rejectedKeys = <String, DateTime>{};

  @override
  LlmProviderId get providerId => LlmProviderId.gemini;

  DateTime _now() => _clock().toUtc();

  static String _cleanModelName(String modelName) {
    var clean = modelName.trim();
    if (clean.startsWith('models/')) {
      clean = clean.substring('models/'.length);
    }
    return clean;
  }

  /// Resolves the model-specific minimum token threshold for explicit Context Caching ([D-607]).
  static int resolveMinCacheTokens(String modelName) {
    final clean = _cleanModelName(modelName).toLowerCase();
    if (clean.contains('flash')) {
      return 1024;
    }
    if (clean.contains('pro')) {
      return 2048;
    }
    return 2048;
  }

  int _effectiveMinCacheTokens(String modelName) {
    return _explicitCacheMinTokensOverride ?? resolveMinCacheTokens(modelName);
  }

  bool _isExplicitCachingEnabled() {
    if (_explicitEnableCaching != null) {
      return _explicitEnableCaching;
    }
    final envValue = _resolveEnv('GEMINI_EXPLICIT_CACHE');
    if (envValue != null) {
      final normalized = envValue.trim().toLowerCase();
      if (normalized == '0' ||
          normalized == 'false' ||
          normalized == 'off' ||
          normalized == 'no') {
        return false;
      }
      return true;
    }
    return true;
  }

  Duration _resolveCacheTtl() {
    if (_explicitCacheTtl != null) {
      return _explicitCacheTtl;
    }
    final envValue = _resolveEnv('GEMINI_EXPLICIT_CACHE_TTL_SECONDS');
    if (envValue != null) {
      final parsed = int.tryParse(envValue.trim());
      if (parsed != null && parsed > 0) {
        return Duration(seconds: parsed.clamp(60, 3600));
      }
    }
    return _defaultExplicitCacheTtl;
  }

  Duration _resolveRenewWindow(Duration ttl) {
    if (ttl <= _explicitCacheRenewWindow) {
      return Duration(seconds: ttl.inSeconds ~/ 3);
    }
    return _explicitCacheRenewWindow;
  }

  Uri _resolveBaseUri() {
    final explicit = _explicitBaseUrl?.trim();
    var raw = (explicit != null && explicit.isNotEmpty)
        ? explicit
        : (_resolveEnv('GEMINI_BASE_URL') ?? defaultBaseUrl);
    if (raw.isEmpty) {
      raw = defaultBaseUrl;
    }
    return Uri.parse(raw);
  }

  static String _normalizedBasePath(Uri uri) {
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  static Uri _stripKeyQueryParam(Uri uri, String targetPath) {
    final mergedQuery = Map<String, String>.from(uri.queryParameters);
    mergedQuery.remove('key');
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: targetPath,
      queryParameters: mergedQuery.isEmpty ? null : mergedQuery,
    );
  }

  /// Resolves the `v1beta/cachedContents` collection endpoint URI without any `?key=` query parameter.
  Uri resolveCachedContentsEndpoint() {
    final uri = _resolveBaseUri();
    final path = _normalizedBasePath(uri);
    final targetPath = path.endsWith('/v1beta')
        ? '$path/cachedContents'
        : '$path/v1beta/cachedContents';
    return _stripKeyQueryParam(uri, targetPath);
  }

  /// Resolves the `v1beta/{resourceName}` cachedContent resource endpoint URI without any `?key=` query parameter.
  Uri resolveCachedContentResourceEndpoint(String resourceName) {
    final uri = _resolveBaseUri();
    final path = _normalizedBasePath(uri);
    var cleanName = resourceName.trim();
    while (cleanName.startsWith('/')) {
      cleanName = cleanName.substring(1);
    }
    final targetPath = path.endsWith('/v1beta')
        ? '$path/$cleanName'
        : '$path/v1beta/$cleanName';
    return _stripKeyQueryParam(uri, targetPath);
  }

  /// Resolves the `v1beta` generate endpoint URI without any `?key=` query parameter.
  Uri resolveEndpoint(String modelName, {required bool stream}) {
    final uri = _resolveBaseUri();
    final path = _normalizedBasePath(uri);
    final cleanModel = _cleanModelName(modelName);

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

    return _stripKeyQueryParam(uri, targetPath);
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

  Map<String, dynamic>? _extractSystemInstruction(LlmChatRequest request) {
    final systemTexts = <String>[];
    for (final msg in request.prompt.messages) {
      if (msg.role == ProjectedRole.system && msg.content.trim().isNotEmpty) {
        systemTexts.add(msg.content);
      }
    }
    if (systemTexts.isEmpty) {
      return null;
    }
    return <String, dynamic>{
      'parts': <Map<String, dynamic>>[
        <String, dynamic>{'text': systemTexts.join('\n\n')},
      ],
    };
  }

  List<Map<String, dynamic>>? _extractTools(LlmChatRequest request) {
    if (request.prompt.tools.isEmpty) {
      return null;
    }
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'functionDeclarations': request.prompt.tools
            .map(
              (t) => <String, dynamic>{
                'name': t.name,
                'description': t.description,
                'parameters': sanitizeSchemaForGemini(t.parametersJsonSchema),
              },
            )
            .toList(growable: false),
      },
    ];
  }

  _PreparedSegment0? _prepareSegment0(LlmChatRequest request) {
    final systemInstruction = _extractSystemInstruction(request);
    final tools = _extractTools(request);
    if (systemInstruction == null && tools == null) {
      return null;
    }

    final cleanModel = _cleanModelName(request.model.modelName);
    final minTokens = _effectiveMinCacheTokens(cleanModel);
    final segment0Payload = <String, dynamic>{
      'systemInstruction': ?systemInstruction,
      'tools': ?tools,
    };
    final segment0Json = jsonEncode(segment0Payload);
    final estimatedTokens = (utf8.encode(segment0Json).length + 3) ~/ 4;
    if (estimatedTokens < minTokens) {
      return null;
    }

    final modelResourceName = 'models/$cleanModel';
    final keyPayload = <String, dynamic>{
      'model': modelResourceName,
      'systemInstruction': ?systemInstruction,
      'tools': ?tools,
    };
    final cacheKey =
        sha256.convert(utf8.encode(jsonEncode(keyPayload))).toString();

    return _PreparedSegment0(
      cacheKey: cacheKey,
      modelResourceName: modelResourceName,
      systemInstruction: systemInstruction,
      tools: tools,
    );
  }

  /// Projects [LlmChatRequest] into Gemini `v1beta` JSON request payload ([D-404], [D-607]).
  ///
  /// When [cachedContentName] is provided and non-empty, sets `cachedContent` and omits
  /// `systemInstruction`, `tools`, and `toolConfig` as required by the Gemini API.
  Map<String, dynamic> buildRequestBody(
    LlmChatRequest request, {
    String? cachedContentName,
  }) {
    final useCachedContent =
        cachedContentName != null && cachedContentName.isNotEmpty;
    final systemInstruction =
        useCachedContent ? null : _extractSystemInstruction(request);
    final contents = <Map<String, dynamic>>[];

    final messages = request.prompt.messages;
    var i = 0;
    while (i < messages.length) {
      final msg = messages[i];
      switch (msg.role) {
        case ProjectedRole.system:
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
      if (useCachedContent) 'cachedContent': cachedContentName,
      if (!useCachedContent && systemInstruction != null)
        'systemInstruction': systemInstruction,
      'contents': contents,
    };

    if (!useCachedContent) {
      final tools = _extractTools(request);
      if (tools != null) {
        body['tools'] = tools;
      }
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

    final cacheEntry = await _resolveOrCreateCachedContent(
      request,
      apiKey: apiKey,
      cancelToken: cancelToken,
    );

    final endpoint = resolveEndpoint(
      request.model.modelName,
      stream: request.stream,
    );
    final endpointStr = endpoint.toString();

    final stopwatch = Stopwatch()..start();
    var response = await _sendGenerateRequest(
      endpoint: endpoint,
      endpointStr: endpointStr,
      apiKey: apiKey,
      request: request,
      cachedContentName: cacheEntry?.resourceName,
      cancelToken: cancelToken,
    );

    // Transparent 1-time fallback if the referenced cachedContent expired or was rejected (404 / 400).
    if (cacheEntry != null &&
        (response.statusCode == 404 || response.statusCode == 400)) {
      try {
        await response.stream
            .drain<void>()
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // Ignore drain errors on expired cache error response.
      }
      if (_cacheEntries[cacheEntry.cacheKey]?.resourceName ==
          cacheEntry.resourceName) {
        _cacheEntries.remove(cacheEntry.cacheKey);
      }
      response = await _sendGenerateRequest(
        endpoint: endpoint,
        endpointStr: endpointStr,
        apiKey: apiKey,
        request: request,
        cachedContentName: null,
        cancelToken: cancelToken,
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

  Future<http.StreamedResponse> _sendGenerateRequest({
    required Uri endpoint,
    required String endpointStr,
    required String apiKey,
    required LlmChatRequest request,
    required String? cachedContentName,
    CancellationToken? cancelToken,
  }) async {
    final httpRequest = http.Request('POST', endpoint)
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        'Accept': request.stream
            ? 'text/event-stream, application/json'
            : 'application/json',
        'x-goog-api-key': apiKey,
      })
      ..body = jsonEncode(
        buildRequestBody(request, cachedContentName: cachedContentName),
      );

    try {
      return await _sendWithCancellation(httpRequest, cancelToken)
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
  }

  Future<_GeminiCachedContentEntry?> _resolveOrCreateCachedContent(
    LlmChatRequest request, {
    required String apiKey,
    CancellationToken? cancelToken,
  }) async {
    if (!_isExplicitCachingEnabled()) {
      return null;
    }

    final prepared = _prepareSegment0(request);
    if (prepared == null) {
      return null;
    }

    final now = _now();
    final rejectedUntil = _rejectedKeys[prepared.cacheKey];
    if (rejectedUntil != null) {
      if (now.isBefore(rejectedUntil)) {
        return null;
      }
      _rejectedKeys.remove(prepared.cacheKey);
    }

    final existing = _cacheEntries[prepared.cacheKey];
    if (existing != null) {
      if (now.isBefore(existing.expireTime)) {
        existing.lastUsedAt = now;
        final ttl = _resolveCacheTtl();
        final renewWindow = _resolveRenewWindow(ttl);
        final renewThreshold = existing.expireTime.subtract(renewWindow);
        if (!now.isBefore(renewThreshold)) {
          await _renewCachedContent(
            entry: existing,
            apiKey: apiKey,
            ttl: ttl,
            cancelToken: cancelToken,
          );
        }
        return existing;
      }
      _cacheEntries.remove(prepared.cacheKey);
    }

    final inFlight = _inFlightCreates[prepared.cacheKey];
    if (inFlight != null) {
      return await inFlight;
    }

    final ttl = _resolveCacheTtl();
    final createFuture = _createCachedContent(
      prepared: prepared,
      apiKey: apiKey,
      ttl: ttl,
      cancelToken: cancelToken,
    );
    _inFlightCreates[prepared.cacheKey] = createFuture;
    try {
      return await createFuture;
    } finally {
      if (identical(_inFlightCreates[prepared.cacheKey], createFuture)) {
        _inFlightCreates.remove(prepared.cacheKey);
      }
    }
  }

  Future<_GeminiCachedContentEntry?> _createCachedContent({
    required _PreparedSegment0 prepared,
    required String apiKey,
    required Duration ttl,
    CancellationToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const LlmDriverException(
        SyscallError(
          code: SyscallErrorCode.ecancelled,
          reason: 'CANCELLED',
          message: 'LLM request cancelled before cachedContents creation.',
          recoverable: true,
        ),
      );
    }

    final endpoint = resolveCachedContentsEndpoint();
    final body = <String, dynamic>{
      'model': prepared.modelResourceName,
      if (prepared.systemInstruction != null)
        'systemInstruction': prepared.systemInstruction,
      if (prepared.tools != null) 'tools': prepared.tools,
      'ttl': '${ttl.inSeconds}s',
    };
    final httpRequest = http.Request('POST', endpoint)
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      })
      ..body = jsonEncode(body);

    try {
      final response = await _sendWithCancellation(httpRequest, cancelToken)
          .timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        try {
          await response.stream
              .drain<void>()
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          // Best-effort drain.
        }
        if (response.statusCode == 400) {
          _rejectedKeys[prepared.cacheKey] =
              _now().add(const Duration(minutes: 5));
        } else if (response.statusCode == 429) {
          _rejectedKeys[prepared.cacheKey] =
              _now().add(const Duration(seconds: 60));
        }
        return null;
      }

      final rawJson = await response.stream
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) {
        return null;
      }
      final name = decoded['name'];
      if (name is! String || name.trim().isEmpty) {
        return null;
      }
      final now = _now();
      final expireStr = decoded['expireTime'];
      final parsedExpire = expireStr is String
          ? DateTime.tryParse(expireStr)?.toUtc()
          : null;
      final expireTime = parsedExpire ?? now.add(ttl);
      int? totalTokenCount;
      final usage = decoded['usageMetadata'];
      if (usage is Map) {
        totalTokenCount = (usage['totalTokenCount'] as num?)?.toInt();
      }

      final entry = _GeminiCachedContentEntry(
        cacheKey: prepared.cacheKey,
        resourceName: name.trim(),
        expireTime: expireTime,
        lastUsedAt: now,
        totalTokenCount: totalTokenCount,
      );
      _cacheEntries[prepared.cacheKey] = entry;
      _evictLruIfNeeded(apiKey, keepKey: prepared.cacheKey);
      return entry;
    } on LlmDriverException catch (e) {
      if (e.error.code == SyscallErrorCode.ecancelled ||
          (cancelToken?.isCancelled ?? false)) {
        rethrow;
      }
      return null;
    } catch (_) {
      if (cancelToken?.isCancelled ?? false) {
        throw const LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'CANCELLED',
            message: 'LLM request cancelled during cachedContents creation.',
            recoverable: true,
          ),
        );
      }
      return null;
    }
  }

  Future<void> _renewCachedContent({
    required _GeminiCachedContentEntry entry,
    required String apiKey,
    required Duration ttl,
    CancellationToken? cancelToken,
  }) async {
    final endpoint = resolveCachedContentResourceEndpoint(entry.resourceName);
    final httpRequest = http.Request('PATCH', endpoint)
      ..headers.addAll(<String, String>{
        'Content-Type': 'application/json',
        'x-goog-api-key': apiKey,
      })
      ..body = jsonEncode(<String, dynamic>{
        'ttl': '${ttl.inSeconds}s',
      });

    final patchTimeout = requestTimeout < const Duration(seconds: 10)
        ? requestTimeout
        : const Duration(seconds: 10);

    try {
      final response = await _sendWithCancellation(httpRequest, cancelToken)
          .timeout(patchTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final rawJson = await response.stream
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5));
        final decoded = jsonDecode(rawJson);
        final now = _now();
        DateTime? parsedExpire;
        if (decoded is Map && decoded['expireTime'] is String) {
          parsedExpire =
              DateTime.tryParse(decoded['expireTime'] as String)?.toUtc();
        }
        entry.expireTime = parsedExpire ?? now.add(ttl);
      } else {
        try {
          await response.stream
              .drain<void>()
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          // Best-effort drain.
        }
      }
    } on LlmDriverException catch (e) {
      if (e.error.code == SyscallErrorCode.ecancelled ||
          (cancelToken?.isCancelled ?? false)) {
        rethrow;
      }
      // Best-effort renewal failure is swallowed; existing entry will be tried.
    } catch (_) {
      if (cancelToken?.isCancelled ?? false) {
        throw const LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'CANCELLED',
            message: 'LLM request cancelled during cachedContents renewal.',
            recoverable: true,
          ),
        );
      }
      // Best-effort renewal failure is swallowed; existing entry will be tried.
    }
  }

  void _evictLruIfNeeded(String apiKey, {required String keepKey}) {
    while (_cacheEntries.length > _maxCachedEntries) {
      _GeminiCachedContentEntry? oldest;
      for (final candidate in _cacheEntries.values) {
        if (candidate.cacheKey == keepKey && _cacheEntries.length > 1) {
          continue;
        }
        if (oldest == null ||
            candidate.lastUsedAt.isBefore(oldest.lastUsedAt)) {
          oldest = candidate;
        }
      }
      if (oldest == null) {
        break;
      }
      _cacheEntries.remove(oldest.cacheKey);
      unawaited(_deleteCachedContentBestEffort(oldest.resourceName, apiKey));
    }
  }

  Future<void> _deleteCachedContentBestEffort(
    String resourceName,
    String apiKey,
  ) async {
    try {
      final endpoint = resolveCachedContentResourceEndpoint(resourceName);
      final httpRequest = http.Request('DELETE', endpoint)
        ..headers['x-goog-api-key'] = apiKey;
      final response = await _httpClient
          .send(httpRequest)
          .timeout(const Duration(seconds: 3));
      try {
        await response.stream
            .drain<void>()
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        // Best-effort drain.
      }
    } catch (_) {
      // Best-effort cleanup ignores network/timeout errors.
    }
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

  /// Best-effort deletes all active explicit cache resources and closes the HTTP client if owned ([D-607]).
  Future<void> dispose() async {
    final entries = _cacheEntries.values.toList(growable: false);
    _cacheEntries.clear();
    _rejectedKeys.clear();

    final apiKey = _resolveApiKey();
    if (apiKey != null && entries.isNotEmpty) {
      await Future.wait<void>(
        entries.map(
          (entry) => _deleteCachedContentBestEffort(entry.resourceName, apiKey),
        ),
      );
    }

    if (_ownsClient) {
      _httpClient.close();
    }
  }

  /// Releases the internal HTTP client if owned by this driver.
  void close() {
    _cacheEntries.clear();
    _rejectedKeys.clear();
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}
