import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_kernel/agent_kernel.dart';
// ignore: depend_on_referenced_packages
import 'package:meta/meta.dart';

import 'html_markdown_extractor.dart';
import 'ollama_web_search_backend.dart';
import 'ssrf_guard.dart';

/// Raw HTTP response returned by a [WebFetchTransport] ([D-205], [D-217]).
class WebFetchRawResponse {
  WebFetchRawResponse({
    required this.requestedUrl,
    required this.finalUrl,
    required this.statusCode,
    required this.contentType,
    required Uint8List bodyBytes,
  }) : bodyBytes = Uint8List.fromList(bodyBytes);

  final String requestedUrl;
  final String finalUrl;
  final int statusCode;
  final String contentType;
  final Uint8List bodyBytes;
}

/// Low-level HTTP(S) transport abstraction for [WebFetchDriver] ([D-205]).
///
/// Production builds unconditionally use [PinnedHttpWebFetchTransport].
/// Tests may inject [FixtureOverlayWebFetchTransport] via `@visibleForTesting`
/// constructor DI without weakening production SSRF enforcement.
abstract interface class WebFetchTransport {
  Future<SyscallResult<WebFetchRawResponse>> fetch({
    required String url,
    Duration? timeout,
    int? maxRedirects,
    int? maxResponseBytes,
    CancellationToken? cancelToken,
  });
}

/// Test-only socket connector hook used exclusively inside unit tests to steer
/// a DNS-validated public IP connection to a local test server while exercising
/// the real [SsrfGuard], redirect loop, 2 MiB streaming cap, and TLS
/// `SecureSocket.secure(raw, host: uri.host)` code path.
typedef PinnedSocketConnector = Future<Socket> Function(
  InternetAddress pinnedPublicIp,
  int port, {
  Duration? timeout,
});

/// Production HTTP(S) transport enforcing full SSRF blocking, DNS-pinned sockets,
/// TLS SNI/X.509 hostname verification, manual redirect re-validation, and
/// streaming 2 MiB response size limiting ([D-205], [D-217]).
///
/// Contains zero SSRF bypass flags and reads zero SSRF-disabling environment variables.
class PinnedHttpWebFetchTransport implements WebFetchTransport {
  PinnedHttpWebFetchTransport({
    SsrfGuard? ssrfGuard,
    this.defaultTimeout = const Duration(seconds: 20),
    this.defaultMaxRedirects = 5,
    this.defaultMaxResponseBytes = 2 * 1024 * 1024,
    this.userAgent = 'FM-Agent-OS-WebFetch/0.1',
    @visibleForTesting PinnedSocketConnector? socketConnector,
  })  : _ssrfGuard = ssrfGuard ?? SsrfGuard(),
        _socketConnector = socketConnector;

  final SsrfGuard _ssrfGuard;
  final Duration defaultTimeout;
  final int defaultMaxRedirects;
  final int defaultMaxResponseBytes;
  final String userAgent;
  final PinnedSocketConnector? _socketConnector;

  static const Set<int> _redirectStatuses = <int>{301, 302, 303, 307, 308};

  @override
  Future<SyscallResult<WebFetchRawResponse>> fetch({
    required String url,
    Duration? timeout,
    int? maxRedirects,
    int? maxResponseBytes,
    CancellationToken? cancelToken,
  }) async {
    final effectiveTimeout = timeout ?? defaultTimeout;
    final effectiveMaxRedirects = maxRedirects ?? defaultMaxRedirects;
    final effectiveMaxBytes = maxResponseBytes ?? defaultMaxResponseBytes;

    var currentUrl = url.trim();

    for (var hop = 0; hop <= effectiveMaxRedirects; hop++) {
      if (cancelToken?.isCancelled ?? false) {
        return const SyscallResult<WebFetchRawResponse>.failure(
          SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'FETCH_CANCELLED',
            message: 'Web fetch was cancelled.',
            recoverable: true,
          ),
        );
      }

      final targetRes = await _ssrfGuard.resolveAndValidate(
        currentUrl,
        isRedirect: hop > 0,
      );
      if (!targetRes.ok) {
        return SyscallResult<WebFetchRawResponse>.failure(targetRes.error!);
      }
      final target = targetRes.value!;
      final pinnedPublicIp = target.pinnedAddress;

      final client = HttpClient()
        ..connectionTimeout = effectiveTimeout
        ..findProxy = (_) => 'DIRECT';

      client.connectionFactory =
          (Uri uri, String? proxyHost, int? proxyPort) async {
        final isSecure = uri.scheme.toLowerCase() == 'https';
        final port = uri.hasPort ? uri.port : (isSecure ? 443 : 80);

        if (!isSecure) {
          if (_socketConnector == null) {
            return Socket.startConnect(pinnedPublicIp, port);
          }
          var cancelled = false;
          Socket? rawRef;
          final futureSocket = _socketConnector(
            pinnedPublicIp,
            port,
            timeout: effectiveTimeout,
          ).then((raw) {
            rawRef = raw;
            if (cancelled) {
              raw.destroy();
              throw const SocketException('Connection cancelled');
            }
            return raw;
          });
          return ConnectionTask.fromSocket(futureSocket, () {
            cancelled = true;
            rawRef?.destroy();
          });
        }

        var cancelled = false;
        Socket? rawRef;
        final connectFuture = _socketConnector != null
            ? _socketConnector(
                pinnedPublicIp,
                port,
                timeout: effectiveTimeout,
              )
            : Socket.connect(
                pinnedPublicIp,
                port,
                timeout: effectiveTimeout,
              );

        final futureSecure = connectFuture.then((raw) async {
          rawRef = raw;
          if (cancelled) {
            raw.destroy();
            throw const SocketException('Connection cancelled');
          }
          // Pin TCP to verified public IP while enforcing TLS SNI & X.509 hostname check.
          return SecureSocket.secure(raw, host: uri.host);
        });

        return ConnectionTask.fromSocket(futureSecure, () {
          cancelled = true;
          rawRef?.destroy();
        });
      };

      try {
        final request =
            await client.getUrl(target.uri).timeout(effectiveTimeout);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        request.headers.set(
          HttpHeaders.acceptHeader,
          'text/html, application/xhtml+xml, text/markdown, text/plain, '
          'application/json, application/xml;q=0.9, */*;q=0.1',
        );

        final response = await request.close().timeout(effectiveTimeout);
        final status = response.statusCode;

        if (_redirectStatuses.contains(status)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          // Drain/discard redirect response body without unbounded buffering.
          await _discardResponse(response);

          if (location == null || location.trim().isEmpty) {
            return SyscallResult<WebFetchRawResponse>.failure(
              SyscallError(
                code: SyscallErrorCode.eio,
                reason: 'INVALID_REDIRECT',
                message:
                    'HTTP $status redirect response is missing a Location header.',
                recoverable: true,
                details: <String, dynamic>{'statusCode': status},
              ),
            );
          }

          if (hop >= effectiveMaxRedirects) {
            return SyscallResult<WebFetchRawResponse>.failure(
              SyscallError(
                code: SyscallErrorCode.eio,
                reason: 'TOO_MANY_REDIRECTS',
                message:
                    'Exceeded maximum redirect limit ($effectiveMaxRedirects).',
                recoverable: true,
                details: <String, dynamic>{
                  'maxRedirects': effectiveMaxRedirects,
                },
              ),
            );
          }

          currentUrl = target.uri.resolve(location.trim()).toString();
          continue;
        }

        final readRes = await _readBoundedBody(
          response: response,
          client: client,
          maxBytes: effectiveMaxBytes,
          timeout: effectiveTimeout,
          cancelToken: cancelToken,
        );
        if (!readRes.ok) {
          return SyscallResult<WebFetchRawResponse>.failure(readRes.error!);
        }

        final contentType =
            response.headers.value(HttpHeaders.contentTypeHeader) ?? '';
        return SyscallResult<WebFetchRawResponse>.success(
          WebFetchRawResponse(
            requestedUrl: url.trim(),
            finalUrl: target.uri.toString(),
            statusCode: status,
            contentType: contentType,
            bodyBytes: readRes.value!,
          ),
        );
      } on HandshakeException catch (e) {
        return SyscallResult<WebFetchRawResponse>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'TLS_HANDSHAKE_FAILED',
            message: 'TLS handshake/certificate verification failed: ${e.message}',
            recoverable: false,
            details: <String, dynamic>{'url': target.uri.toString()},
          ),
        );
      } on TlsException catch (e) {
        return SyscallResult<WebFetchRawResponse>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'TLS_HANDSHAKE_FAILED',
            message: 'TLS error during fetch: ${e.message}',
            recoverable: false,
            details: <String, dynamic>{'url': target.uri.toString()},
          ),
        );
      } on TimeoutException {
        return SyscallResult<WebFetchRawResponse>.failure(
          SyscallError(
            code: SyscallErrorCode.etimedout,
            reason: 'FETCH_TIMEOUT',
            message:
                'Web fetch timed out after ${effectiveTimeout.inMilliseconds} ms.',
            recoverable: true,
          ),
        );
      } on HttpException catch (e) {
        return SyscallResult<WebFetchRawResponse>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'FETCH_NETWORK_ERROR',
            message: 'HTTP error during web fetch: ${e.message}',
            recoverable: true,
          ),
        );
      } on SocketException catch (e) {
        return SyscallResult<WebFetchRawResponse>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'FETCH_NETWORK_ERROR',
            message: 'Network error during web fetch: ${e.message}',
            recoverable: true,
          ),
        );
      } finally {
        client.close(force: true);
      }
    }

    return SyscallResult<WebFetchRawResponse>.failure(
      SyscallError(
        code: SyscallErrorCode.eio,
        reason: 'TOO_MANY_REDIRECTS',
        message: 'Exceeded maximum redirect limit ($effectiveMaxRedirects).',
        recoverable: true,
      ),
    );
  }

  static Future<void> _discardResponse(HttpClientResponse response) async {
    try {
      final sub = response.listen((_) {});
      await sub.cancel();
    } catch (_) {
      // Ignore socket teardown errors on redirect discard.
    }
  }

  static Future<SyscallResult<Uint8List>> _readBoundedBody({
    required HttpClientResponse response,
    required HttpClient client,
    required int maxBytes,
    required Duration timeout,
    CancellationToken? cancelToken,
  }) async {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<SyscallResult<Uint8List>>();
    var totalBytes = 0;

    late final StreamSubscription<List<int>> sub;
    sub = response.listen(
      (chunk) {
        if (completer.isCompleted) {
          return;
        }
        if (cancelToken?.isCancelled ?? false) {
          sub.cancel();
          client.close(force: true);
          completer.complete(
            const SyscallResult<Uint8List>.failure(
              SyscallError(
                code: SyscallErrorCode.ecancelled,
                reason: 'FETCH_CANCELLED',
                message: 'Web fetch was cancelled during response streaming.',
                recoverable: true,
              ),
            ),
          );
          return;
        }

        totalBytes += chunk.length;
        if (totalBytes > maxBytes) {
          sub.cancel();
          client.close(force: true);
          completer.complete(
            SyscallResult<Uint8List>.failure(
              SyscallError(
                code: SyscallErrorCode.eio,
                reason: 'RESPONSE_TOO_LARGE',
                message:
                    'Response exceeded maximum allowed size of $maxBytes bytes; connection terminated.',
                recoverable: true,
                details: <String, dynamic>{'maxResponseBytes': maxBytes},
              ),
            ),
          );
          return;
        }
        builder.add(chunk);
      },
      onError: (Object error, StackTrace _) {
        if (!completer.isCompleted) {
          completer.complete(
            SyscallResult<Uint8List>.failure(
              SyscallError(
                code: SyscallErrorCode.eio,
                reason: 'FETCH_NETWORK_ERROR',
                message: 'Error reading web response stream: $error',
                recoverable: true,
              ),
            ),
          );
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
            SyscallResult<Uint8List>.success(builder.takeBytes()),
          );
        }
      },
      cancelOnError: true,
    );

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      await sub.cancel();
      client.close(force: true);
      return SyscallResult<Uint8List>.failure(
        SyscallError(
          code: SyscallErrorCode.etimedout,
          reason: 'FETCH_TIMEOUT',
          message:
              'Timed out reading response body after ${timeout.inMilliseconds} ms.',
          recoverable: true,
        ),
      );
    }
  }
}

/// Test-only overlay transport returning synthetic responses exclusively for
/// explicitly registered fixture URLs while delegating ALL other URLs
/// (including `127.0.0.1` / `192.168.*` SSRF attempts) to the real
/// [PinnedHttpWebFetchTransport] ([D-205] / `OM-201`).
@visibleForTesting
class FixtureOverlayWebFetchTransport implements WebFetchTransport {
  FixtureOverlayWebFetchTransport({
    required Map<String, WebFetchRawResponse> fixtures,
    WebFetchTransport? fallback,
  })  : _fixtures = Map<String, WebFetchRawResponse>.unmodifiable(fixtures),
        _fallback = fallback ?? PinnedHttpWebFetchTransport();

  final Map<String, WebFetchRawResponse> _fixtures;
  final WebFetchTransport _fallback;

  @override
  Future<SyscallResult<WebFetchRawResponse>> fetch({
    required String url,
    Duration? timeout,
    int? maxRedirects,
    int? maxResponseBytes,
    CancellationToken? cancelToken,
  }) async {
    final trimmed = url.trim();
    final fixture = _fixtures[trimmed];
    if (fixture != null) {
      return SyscallResult<WebFetchRawResponse>.success(fixture);
    }
    return _fallback.fetch(
      url: trimmed,
      timeout: timeout,
      maxRedirects: maxRedirects,
      maxResponseBytes: maxResponseBytes,
      cancelToken: cancelToken,
    );
  }
}

/// High-level `sys_web_fetch` driver applying SSRF-pinned transport,
/// MIME filtering, binary rejection, and HTML-to-Markdown extraction ([D-205], [D-217]).
class WebFetchDriver {
  WebFetchDriver({
    @visibleForTesting WebFetchTransport? transport,
    HtmlMarkdownExtractor? extractor,
    this.defaultTimeout = const Duration(seconds: 20),
    this.maxRedirects = 5,
    this.maxResponseBytes = 2 * 1024 * 1024,
  })  : _transport = transport ??
            PinnedHttpWebFetchTransport(
              defaultTimeout: defaultTimeout,
              defaultMaxRedirects: maxRedirects,
              defaultMaxResponseBytes: maxResponseBytes,
            ),
        _extractor = extractor ?? const HtmlMarkdownExtractor();

  final WebFetchTransport _transport;
  final HtmlMarkdownExtractor _extractor;
  final Duration defaultTimeout;
  final int maxRedirects;
  final int maxResponseBytes;

  static const Set<String> _htmlMimeTypes = <String>{
    'text/html',
    'application/xhtml+xml',
  };

  static const Set<String> _plainTextMimeTypes = <String>{
    'text/markdown',
    'text/plain',
    'application/json',
    'application/xml',
    'text/xml',
  };

  /// Fetches [url], verifies HTTP status and MIME type, and returns structured Markdown output.
  Future<SyscallResult<Map<String, dynamic>>> fetch({
    required String url,
    CancellationToken? cancelToken,
  }) async {
    final rawRes = await _transport.fetch(
      url: url,
      timeout: defaultTimeout,
      maxRedirects: maxRedirects,
      maxResponseBytes: maxResponseBytes,
      cancelToken: cancelToken,
    );
    if (!rawRes.ok) {
      return SyscallResult<Map<String, dynamic>>.failure(rawRes.error!);
    }

    final raw = rawRes.value!;
    final status = raw.statusCode;

    // Never attempt to bypass anti-bot / CAPTCHA / rate-limit challenges ([D-217]).
    if (status == 429) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'RATE_LIMITED',
          message:
              'Remote server returned HTTP 429 Too Many Requests; no automated bypass attempted.',
          recoverable: false,
          details: <String, dynamic>{
            'statusCode': status,
            'finalUrl': raw.finalUrl,
          },
        ),
      );
    }

    if (status == 403 || status == 503) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'HTTP_ACCESS_DENIED',
          message:
              'Remote server returned HTTP $status (possible access control or anti-bot gate); '
              'no automated bypass attempted.',
          recoverable: false,
          details: <String, dynamic>{
            'statusCode': status,
            'finalUrl': raw.finalUrl,
          },
        ),
      );
    }

    if (status < 200 || status >= 300) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'HTTP_ERROR',
          message: 'Remote server returned HTTP $status for "${raw.finalUrl}".',
          recoverable: status >= 500,
          details: <String, dynamic>{
            'statusCode': status,
            'finalUrl': raw.finalUrl,
          },
        ),
      );
    }

    final mime = _normalizeMimeType(raw.contentType);
    final isHtml = _htmlMimeTypes.contains(mime);
    final isPlainText = _plainTextMimeTypes.contains(mime);

    if (!isHtml && !isPlainText) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'UNSUPPORTED_CONTENT_TYPE',
          message:
              'Content-Type "${mime.isEmpty ? '(missing)' : mime}" is not supported by sys_web_fetch.',
          recoverable: true,
          details: <String, dynamic>{
            'contentType': mime,
            'finalUrl': raw.finalUrl,
          },
        ),
      );
    }

    // Reject binary payloads containing NUL bytes even if disguised with a text MIME header.
    if (_containsNulByte(raw.bodyBytes)) {
      return SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'UNSUPPORTED_CONTENT_TYPE',
          message:
              'Response body contains binary NUL bytes and cannot be processed as text.',
          recoverable: true,
          details: <String, dynamic>{
            'contentType': mime,
            'finalUrl': raw.finalUrl,
          },
        ),
      );
    }

    final decodedText = utf8.decode(raw.bodyBytes, allowMalformed: true);
    String title;
    String markdown;

    if (isHtml) {
      final extracted = _extractor.extract(
        decodedText,
        baseUri: Uri.tryParse(raw.finalUrl),
      );
      title = extracted.title;
      markdown = extracted.markdown;
    } else {
      title = '';
      markdown = decodedText;
    }

    return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
      'url': raw.requestedUrl,
      'finalUrl': raw.finalUrl,
      'statusCode': raw.statusCode,
      'contentType': mime,
      'title': title,
      'markdown': markdown,
    });
  }

  static String _normalizeMimeType(String rawHeader) {
    final semicolon = rawHeader.indexOf(';');
    final core = semicolon >= 0 ? rawHeader.substring(0, semicolon) : rawHeader;
    return core.trim().toLowerCase();
  }

  static bool _containsNulByte(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) {
        return true;
      }
    }
    return false;
  }
}

/// Builds the Segment 0 [SyscallToolSchema] for `sys_web_fetch` ([D-202], [D-217]).
SyscallToolSchema buildWebFetchToolSchema() {
  return SyscallToolSchema(
    name: 'sys_web_fetch',
    description:
        'Fetch a public http:// or https:// web page with strict SSRF protection '
        'and extract clean Markdown text.',
    parametersJsonSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'url': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute public http:// or https:// URL to fetch.',
        },
      },
      'required': <String>['url'],
      'additionalProperties': false,
    },
  );
}

/// Builds the kernel `sys_web_fetch` [SyscallDefinition] ([D-202], [D-204], [D-217]).
SyscallDefinition buildWebFetchSyscallDefinition({
  required WebFetchDriver driver,
}) {
  return SyscallDefinition(
    name: 'sys_web_fetch',
    requiredRight: CapRight.netRead,
    kind: 'net_read',
    applyIoCap: true,
    cappedTextFields: const <String>['markdown'],
    validateArgs: (args) {
      final rawUrl = args['url'];
      if (rawUrl is! String || rawUrl.trim().isEmpty) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_URL',
          message: 'Argument "url" must be a non-empty http:// or https:// URL.',
          recoverable: true,
        );
      }
      return null;
    },
    checkPreconditions: (pcb, _) async => checkWorkspaceXorNetPrecondition(pcb),
    evaluatePolicy: (_, _) async => RingDecision.allow,
    handler: (execContext) async {
      final url = (execContext.args['url'] as String).trim();
      return driver.fetch(
        url: url,
        cancelToken: execContext.context.cancelToken,
      );
    },
  );
}
