import 'cancellation.dart';
import 'syscall_error.dart';

/// Single normalized web search result item returned by [WebSearchBackend] ([D-216]).
class WebSearchResultItem {
  const WebSearchResultItem({
    required this.title,
    required this.url,
    required this.content,
    this.contentTruncated = false,
    this.originalContentChars,
  });

  final String title;
  final String url;
  final String content;
  final bool contentTruncated;
  final int? originalContentChars;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'title': title,
      'url': url,
      'content': content,
      if (contentTruncated) 'contentTruncated': true,
      if (contentTruncated && originalContentChars != null)
        'originalContentChars': originalContentChars,
    };
  }
}

/// Aggregated response returned by [WebSearchBackend.search] ([D-216]).
class WebSearchResponse {
  WebSearchResponse({
    required this.query,
    required this.provider,
    required List<WebSearchResultItem> results,
  }) : results = List<WebSearchResultItem>.unmodifiable(results);

  final String query;
  final String provider;
  final List<WebSearchResultItem> results;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'query': query,
      'provider': provider,
      'results': results.map((item) => item.toJson()).toList(growable: false),
    };
  }
}

/// Abstract Ring 0 web search backend interface implemented in `agent_drivers` ([D-201], [D-216]).
abstract interface class WebSearchBackend {
  /// Stable identifier of the concrete backend (e.g., `ollama-web-search`).
  String get providerName;

  /// Executes a web search query and returns normalized results or a structured [SyscallError].
  Future<SyscallResult<WebSearchResponse>> search({
    required String query,
    int maxResults = 5,
    CancellationToken? cancelToken,
  });
}
