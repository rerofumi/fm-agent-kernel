import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// CSRF token generator, Origin/Token validator, and security header helper
/// for the local loopback Kanban HTTP/WebSocket server ([D-322] §3.3).
class KanbanCsrfGuard {
  KanbanCsrfGuard({Random? random}) : _token = _generateToken(random);

  static const String tokenPlaceholder = '__CSRF_TOKEN__';

  final String _token;

  /// Cryptographically random 64-character hex CSRF token.
  /// Never log or print this value to stdout/stderr.
  String get token => _token;

  static String _generateToken(Random? random) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Injects the CSRF token into the `<meta name="csrf-token">` placeholder.
  String injectIntoHtml(String htmlTemplate) {
    return htmlTemplate.replaceAll(tokenPlaceholder, _token);
  }

  /// Applies strict same-origin security headers to `GET /` HTML responses ([D-322] §3.3).
  void applyHtmlSecurityHeaders(HttpResponse response, int actualPort) {
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('X-Frame-Options', 'DENY');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'self'; "
          "script-src 'self' 'unsafe-inline'; "
          "style-src 'self' 'unsafe-inline'; "
          "connect-src 'self' ws://127.0.0.1:$actualPort; "
          "img-src 'self' data:;",
    );
  }

  /// Constant-time string comparison to prevent timing side-channels.
  bool constantTimeEquals(String a, String b) {
    final bytesA = utf8.encode(a);
    final bytesB = utf8.encode(b);
    if (bytesA.length != bytesB.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < bytesA.length; i++) {
      diff |= bytesA[i] ^ bytesB[i];
    }
    return diff == 0;
  }

  /// Validates `Origin` (when present) and `X-CSRF-Token` on HTTP API requests.
  bool validateHttpRequest(
    HttpRequest request,
    int actualPort, {
    required bool requireToken,
  }) {
    if (!_validateOrigin(request.headers.value('origin'), actualPort)) {
      return false;
    }
    if (!requireToken) {
      return true;
    }
    final headerToken = request.headers.value('x-csrf-token');
    if (headerToken == null || headerToken.isEmpty) {
      return false;
    }
    return constantTimeEquals(headerToken, _token);
  }

  /// Validates `Origin` (when present) and `?token=` / `X-CSRF-Token` on WebSocket upgrades.
  bool validateWebSocketUpgrade(HttpRequest request, int actualPort) {
    if (!_validateOrigin(request.headers.value('origin'), actualPort)) {
      return false;
    }
    final queryToken = request.uri.queryParameters['token'];
    final headerToken = request.headers.value('x-csrf-token');
    final candidate = (queryToken != null && queryToken.isNotEmpty)
        ? queryToken
        : headerToken;
    if (candidate == null || candidate.isEmpty) {
      return false;
    }
    return constantTimeEquals(candidate, _token);
  }

  bool _validateOrigin(String? origin, int actualPort) {
    if (origin == null || origin.trim().isEmpty) {
      return true;
    }
    final expected = 'http://127.0.0.1:$actualPort';
    return origin.trim() == expected;
  }
}
