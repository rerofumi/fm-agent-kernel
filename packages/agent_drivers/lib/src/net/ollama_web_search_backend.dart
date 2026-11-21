import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;

import '../llm/llm_env_loader.dart';

/// Enforces the `Workspace ⊕ Net` sterile isolation boundary ([D-204] §3.2(1), [D-216]).
///
/// Any process holding `/workspace` or `/skills` mounts, or `read` / `writeCow` / `exec`
/// rights (e.g., `LeadAgent` or `Explorer`), is forbidden from invoking network syscalls
/// directly and must delegate to an isolated `WebResearcher` child process.
SyscallError? checkWorkspaceXorNetPrecondition(ProcessControlBlock pcb) {
  final hasWorkspaceOrSkillsMount =
      pcb.namespace.isWorkspaceMounted || pcb.namespace.isSkillsMounted;
  final hasConflictingRights = pcb.cspace.hasAnyRight(CapRight.read) ||
      pcb.cspace.hasAnyRight(CapRight.writeCow) ||
      pcb.cspace.hasAnyRight(CapRight.exec);

  if (hasWorkspaceOrSkillsMount || hasConflictingRights) {
    return SyscallError(
      code: SyscallErrorCode.eperm,
      reason: 'NET_REQUIRES_ISOLATED_RESEARCHER',
      message:
          'Process ${pcb.pid} (${pcb.name}) holds workspace/skills/exec access '
          'and cannot invoke network syscalls directly (Workspace ⊕ Net isolation).',
      recoverable: true,
      hint:
          'Delegate external web research to an isolated WebResearcher child via '
          'sys_spawn(profile: "web_researcher").',
    );
  }
  return null;
}

/// Default `WebSearchBackend` backed by Ollama's official Web Search API ([D-203], [D-216]).
///
/// Endpoint: `POST https://ollama.com/api/web_search` (overridable via [baseUrl] or
/// `OLLAMA_WEB_SEARCH_URL` for tests).
/// API key precedence: [apiKey] > `OLLAMA_API_KEY` > `OLLAMA_CLOUD_API_KEY`.
class OllamaWebSearchBackend implements WebSearchBackend {
  OllamaWebSearchBackend({
    String? apiKey,
    String? baseUrl,
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
    this.requestTimeout = const Duration(milliseconds: 20000),
    this.maxSnippetChars = 800,
  })  : assert(maxSnippetChars > 0),
        _explicitApiKey = apiKey,
        _explicitBaseUrl = baseUrl,
        _envLoader = envLoader,
        _redactor = redactor ?? envLoader?.redactor ?? SecretRedactor(),
        _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null {
    final initialKey = _resolveApiKey();
    if (initialKey != null) {
      _redactor.registerSecret(initialKey);
    }
  }

  static const String defaultEndpointUrl = 'https://ollama.com/api/web_search';
  static const int minQueryLength = 1;
  static const int maxQueryLength = 500;
  static const int minMaxResults = 1;
  static const int maxMaxResults = 10;
  static const int defaultMaxResults = 5;

  final String? _explicitApiKey;
  final String? _explicitBaseUrl;
  final LlmEnvLoader? _envLoader;
  final SecretRedactor _redactor;
  final http.Client _httpClient;
  final bool _ownsClient;

  /// Timeout for a single web search HTTP request (default 20,000 ms).
  final Duration requestTimeout;

  /// Maximum character length of each search result's `content` snippet (default 800).
  final int maxSnippetChars;

  @override
  String get providerName => 'ollama-web-search';

  /// Closes the underlying HTTP client when owned by this backend.
  void close() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }

  String? _resolveApiKey() {
    final explicit = _explicitApiKey?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    final primary = _envLoader?.get('OLLAMA_API_KEY');
    if (primary != null && primary.isNotEmpty) {
      return primary;
    }
    final fallback = _envLoader?.get('OLLAMA_CLOUD_API_KEY');
    if (fallback != null && fallback.isNotEmpty) {
      return fallback;
    }
    return null;
  }

  Uri _resolveEndpointUri() {
    final raw = (_explicitBaseUrl?.trim().isNotEmpty ?? false)
        ? _explicitBaseUrl!.trim()
        : (_envLoader?.get('OLLAMA_WEB_SEARCH_URL') ?? defaultEndpointUrl);
    final parsed = Uri.parse(raw);
    if (parsed.path.isEmpty || parsed.path == '/') {
      return parsed.replace(path: '/api/web_search');
    }
    return parsed;
  }

  @override
  Future<SyscallResult<WebSearchResponse>> search({
    required String query,
    int maxResults = defaultMaxResults,
    CancellationToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      return const SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.ecancelled,
          reason: 'SEARCH_CANCELLED',
          message: 'Web search was cancelled before execution.',
          recoverable: true,
        ),
      );
    }

    final trimmedQuery = query.trim();
    if (trimmedQuery.length < minQueryLength ||
        trimmedQuery.length > maxQueryLength) {
      return const SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_QUERY',
          message:
              'Argument "query" must be a non-empty string between 1 and 500 characters.',
          recoverable: true,
        ),
      );
    }

    if (maxResults < minMaxResults || maxResults > maxMaxResults) {
      return const SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_MAX_RESULTS',
          message: 'Argument "maxResults" must be an integer between 1 and 10.',
          recoverable: true,
        ),
      );
    }

    final apiKey = _resolveApiKey();
    if (apiKey == null) {
      return const SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'MISSING_API_KEY',
          message: 'OLLAMA_API_KEY is not configured for sys_web_search.',
          recoverable: false,
          hint: 'Set OLLAMA_API_KEY in environment or .agent_os/.env.',
        ),
      );
    }
    _redactor.registerSecret(apiKey);

    final endpoint = _resolveEndpointUri();
    final bodyJson = jsonEncode(<String, dynamic>{
      'query': trimmedQuery,
      'max_results': maxResults,
    });

    http.Response response;
    try {
      final future = _httpClient.post(
        endpoint,
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer $apiKey',
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          HttpHeaders.acceptHeader: 'application/json',
        },
        body: bodyJson,
      );
      response = await future.timeout(requestTimeout);
    } on TimeoutException {
      return SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.etimedout,
          reason: 'SEARCH_TIMEOUT',
          message: _redactor.redactString(
            'Web search request timed out after ${requestTimeout.inMilliseconds} ms.',
          ),
          recoverable: true,
        ),
      );
    } catch (e) {
      return SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'SEARCH_BACKEND_ERROR',
          message: _redactor.redactString('Web search request failed: $e'),
          recoverable: true,
        ),
      );
    }

    if (cancelToken?.isCancelled ?? false) {
      return const SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.ecancelled,
          reason: 'SEARCH_CANCELLED',
          message: 'Web search was cancelled.',
          recoverable: true,
        ),
      );
    }

    final status = response.statusCode;
    if (status == 401 || status == 403) {
      return SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'UNAUTHORIZED',
          message: _redactor.redactString(
            'Web search API rejected credentials with HTTP $status.',
          ),
          recoverable: false,
          details: <String, dynamic>{'statusCode': status},
        ),
      );
    }

    if (status == 429) {
      return SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'RATE_LIMITED',
          message: _redactor.redactString(
            'Web search API rate limit exceeded (HTTP 429).',
          ),
          recoverable: false,
          hint:
              'Search API rate limit reached; summarize available findings without retrying in a loop.',
          details: <String, dynamic>{'statusCode': status},
        ),
      );
    }

    if (status < 200 || status >= 300) {
      final snippet = _truncateSnippet(response.body);
      return SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'SEARCH_BACKEND_ERROR',
          message: _redactor.redactString(
            'Web search API returned HTTP $status${snippet.isEmpty ? '' : ': $snippet'}',
          ),
          recoverable: status >= 500,
          details: <String, dynamic>{'statusCode': status},
        ),
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } catch (e) {
      return SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'SEARCH_BACKEND_ERROR',
          message: _redactor.redactString('Failed to decode web search response JSON: $e'),
          recoverable: true,
        ),
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return const SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'SEARCH_BACKEND_ERROR',
          message: 'Web search response JSON root must be an object.',
          recoverable: true,
        ),
      );
    }

    final rawResults = decoded['results'];
    if (rawResults != null && rawResults is! List<dynamic>) {
      return const SyscallResult<WebSearchResponse>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'SEARCH_BACKEND_ERROR',
          message: 'Web search response field "results" must be a list.',
          recoverable: true,
        ),
      );
    }

    final items = <WebSearchResultItem>[];
    if (rawResults is List<dynamic>) {
      for (final entry in rawResults) {
        if (entry is! Map<dynamic, dynamic>) {
          continue;
        }
        final title = _redactor.redactString((entry['title']?.toString() ?? '').trim());
        final url = _redactor.redactString((entry['url']?.toString() ?? '').trim());
        final rawContent =
            _redactor.redactString((entry['content']?.toString() ?? '').trim());
        if (url.isEmpty && title.isEmpty && rawContent.isEmpty) {
          continue;
        }
        final bool contentTruncated;
        final int? originalContentChars;
        final String content;
        if (rawContent.length > maxSnippetChars) {
          content = '${rawContent.substring(0, maxSnippetChars)}...';
          contentTruncated = true;
          originalContentChars = rawContent.length;
        } else {
          content = rawContent;
          contentTruncated = false;
          originalContentChars = null;
        }
        items.add(
          WebSearchResultItem(
            title: title,
            url: url,
            content: content,
            contentTruncated: contentTruncated,
            originalContentChars: originalContentChars,
          ),
        );
      }
    }

    return SyscallResult<WebSearchResponse>.success(
      WebSearchResponse(
        query: trimmedQuery,
        provider: providerName,
        results: items,
      ),
    );
  }

  static String _truncateSnippet(String body, {int maxChars = 240}) {
    final trimmed = body.trim();
    if (trimmed.length <= maxChars) {
      return trimmed;
    }
    return '${trimmed.substring(0, maxChars)}...';
  }
}

/// Builds the Segment 0 [SyscallToolSchema] for `sys_web_search` ([D-202], [D-216]).
SyscallToolSchema buildWebSearchToolSchema() {
  return SyscallToolSchema(
    name: 'sys_web_search',
    description:
        'Search the public web for relevant pages and snippets using the isolated network driver.',
    parametersJsonSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'query': <String, dynamic>{
          'type': 'string',
          'minLength': 1,
          'maxLength': 500,
          'description': 'Search query string (1..500 characters).',
        },
        'maxResults': <String, dynamic>{
          'type': 'integer',
          'minimum': 1,
          'maximum': 10,
          'description': 'Maximum number of results to return (default 5, range 1..10).',
        },
      },
      'required': <String>['query'],
      'additionalProperties': false,
    },
  );
}

/// Builds the kernel `sys_web_search` [SyscallDefinition] ([D-202], [D-204], [D-216]).
SyscallDefinition buildWebSearchSyscallDefinition({
  required WebSearchBackend backend,
}) {
  return SyscallDefinition(
    name: 'sys_web_search',
    requiredRight: CapRight.netRead,
    kind: 'net_read',
    applyIoCap: true,
    cappedTextFields: const <String>['results'],
    validateArgs: (args) {
      final rawQuery = args['query'];
      if (rawQuery is! String) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_QUERY',
          message: 'Argument "query" must be a non-empty string.',
          recoverable: true,
        );
      }
      final trimmed = rawQuery.trim();
      if (trimmed.isEmpty ||
          trimmed.length > OllamaWebSearchBackend.maxQueryLength) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_QUERY',
          message:
              'Argument "query" must be between 1 and 500 non-whitespace characters.',
          recoverable: true,
        );
      }

      final rawMax = args['maxResults'];
      if (rawMax != null) {
        if (rawMax is! int ||
            rawMax < OllamaWebSearchBackend.minMaxResults ||
            rawMax > OllamaWebSearchBackend.maxMaxResults) {
          return const SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'INVALID_MAX_RESULTS',
            message: 'Argument "maxResults" must be an integer between 1 and 10.',
            recoverable: true,
          );
        }
      }
      return null;
    },
    checkPreconditions: (pcb, _) async => checkWorkspaceXorNetPrecondition(pcb),
    evaluatePolicy: (_, _) async => RingDecision.allow,
    handler: (execContext) async {
      final query = (execContext.args['query'] as String).trim();
      final maxResults = (execContext.args['maxResults'] as int?) ??
          OllamaWebSearchBackend.defaultMaxResults;

      final res = await backend.search(
        query: query,
        maxResults: maxResults,
        cancelToken: execContext.context.cancelToken,
      );
      if (!res.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(res.error!);
      }
      return SyscallResult<Map<String, dynamic>>.success(res.value!.toJson());
    },
  );
}
