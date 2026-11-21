import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_drivers/llm_drivers.dart';
import 'package:agent_drivers/web_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Generates an ephemeral in-memory self-signed certificate & PKCS#8 private key
/// for `CN=valid-host.example` using .NET built into PowerShell (no files written).
Future<({Uint8List certPem, Uint8List keyPem})> _generateEphemeralSelfSignedPem() async {
  const script = r'''
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
  "CN=valid-host.example",
  $rsa,
  [System.Security.Cryptography.HashAlgorithmName]::SHA256,
  [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)
$cert = $req.CreateSelfSigned(
  [DateTimeOffset]::UtcNow.AddDays(-1),
  [DateTimeOffset]::UtcNow.AddDays(1)
)
[Console]::Out.Write($cert.ExportCertificatePem())
[Console]::Out.Write("<<<SPLIT>>>")
[Console]::Out.Write($rsa.ExportPkcs8PrivateKeyPem())
''';

  final res = await Process.run(
    'pwsh',
    <String>['-NoProfile', '-NonInteractive', '-Command', script],
    runInShell: false,
  );
  if (res.exitCode != 0) {
    throw StateError('Failed to generate test cert: ${res.stderr}');
  }
  final parts = (res.stdout as String).split('<<<SPLIT>>>');
  if (parts.length != 2) {
    throw StateError('Unexpected cert generator output.');
  }
  return (
    certPem: Uint8List.fromList(utf8.encode(parts[0])),
    keyPem: Uint8List.fromList(utf8.encode(parts[1])),
  );
}

void main() {
  group('SsrfGuard ([D-217])', () {
    test('blocks 30+ non-public IPv4, IPv6, embedded IPv4, localhost, scheme, and userInfo patterns', () async {
      final guard = SsrfGuard();

      // 1. Direct IPv4 / IPv6 address byte-level checks (25+ non-public addresses)
      final blockedAddresses = <String>[
        '0.0.0.0',
        '0.1.2.3',
        '10.0.0.1',
        '10.255.255.254',
        '100.64.0.1',
        '100.127.255.254',
        '127.0.0.1',
        '127.255.255.254',
        '169.254.169.254',
        '172.16.0.1',
        '172.31.255.254',
        '192.0.0.1',
        '192.0.2.1',
        '192.88.99.1',
        '192.168.0.5',
        '192.168.255.254',
        '198.18.0.1',
        '198.19.255.254',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '240.0.0.1',
        '255.255.255.255',
        '::',
        '::1',
        '::ffff:127.0.0.1',
        '::ffff:192.168.0.5',
        '::ffff:169.254.169.254',
        '::127.0.0.1',
        '64:ff9b::127.0.0.1',
        '64:ff9b:1::192.168.0.5',
        '2002:7f00:0001::1',
        '2002:c0a8:0005::1',
        '2001:0000:4136:e378:8000:63bf:3fff:fdd2',
        'fc00::1',
        'fd12:3456:789a::1',
        'fe80::1',
        'ff02::1',
        '2001:db8::1',
      ];

      for (final ip in blockedAddresses) {
        final addr = InternetAddress(ip);
        expect(
          SsrfGuard.isPublicGlobalAddress(addr),
          isFalse,
          reason: 'Address $ip must be blocked by SsrfGuard',
        );
      }

      // 2. Public global addresses are allowed
      final allowedAddresses = <String>[
        '1.1.1.1',
        '8.8.8.8',
        '93.184.216.34',
        '199.36.158.100',
        '2606:2800:220:1:248:1893:25c8:1946',
        '::ffff:93.184.216.34',
        '64:ff9b::93.184.216.34',
        '2002:5db8:d822::1',
      ];

      for (final ip in allowedAddresses) {
        final addr = InternetAddress(ip);
        expect(
          SsrfGuard.isPublicGlobalAddress(addr),
          isTrue,
          reason: 'Public address $ip must be permitted by SsrfGuard',
        );
      }

      // 3. URL-level blocking (schemes, userinfo, localhost/.local/.internal, IP literals)
      final blockedUrls = <({String url, SyscallErrorCode code, String reason})>[
        (url: '', code: SyscallErrorCode.einval, reason: 'INVALID_URL'),
        (url: '/relative/path', code: SyscallErrorCode.einval, reason: 'INVALID_URL'),
        (url: 'file:///C:/Windows/win.ini', code: SyscallErrorCode.eacces, reason: 'DISALLOWED_URL_SCHEME'),
        (url: 'ftp://example.com/file.txt', code: SyscallErrorCode.eacces, reason: 'DISALLOWED_URL_SCHEME'),
        (url: 'data:text/html,<h1>hi</h1>', code: SyscallErrorCode.eacces, reason: 'DISALLOWED_URL_SCHEME'),
        (url: 'javascript:alert(1)', code: SyscallErrorCode.eacces, reason: 'DISALLOWED_URL_SCHEME'),
        (url: 'gopher://example.com/1', code: SyscallErrorCode.eacces, reason: 'DISALLOWED_URL_SCHEME'),
        (url: 'ws://example.com/socket', code: SyscallErrorCode.eacces, reason: 'DISALLOWED_URL_SCHEME'),
        (url: 'http://user:pass@example.com/', code: SyscallErrorCode.eacces, reason: 'DISALLOWED_URL_USERINFO'),
        (url: 'http://localhost:11434/api/tags', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_HOST'),
        (url: 'http://sub.localhost/api', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_HOST'),
        (url: 'http://printer.local/', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_HOST'),
        (url: 'http://metadata.google.internal/', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_HOST'),
        (url: 'http://127.0.0.1:11434/api/tags', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_ADDRESS'),
        (url: 'http://192.168.0.5:11434/api/tags', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_ADDRESS'),
        (url: 'http://169.254.169.254/latest/meta-data/', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_ADDRESS'),
        (url: 'http://[::1]:11434/api/tags', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_ADDRESS'),
        (url: 'http://[::ffff:127.0.0.1]:11434/api/tags', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_ADDRESS'),
        (url: 'http://[::ffff:192.168.0.5]:11434/api/tags', code: SyscallErrorCode.eacces, reason: 'SSRF_BLOCKED_ADDRESS'),
      ];

      for (final c in blockedUrls) {
        final res = await guard.resolveAndValidate(c.url);
        expect(res.ok, isFalse, reason: 'URL ${c.url} must be rejected');
        expect(res.error!.code, c.code, reason: 'URL ${c.url} error code');
        expect(res.error!.reason, c.reason, reason: 'URL ${c.url} error reason');
      }
    });

    test('rejects DNS responses containing any non-public IP alongside a public IP', () async {
      final guard = SsrfGuard(
        dnsLookup: (_) async => <InternetAddress>[
          InternetAddress('93.184.216.34'),
          InternetAddress('127.0.0.1'),
        ],
      );

      final res = await guard.resolveAndValidate('https://dual-homed.example/doc');
      expect(res.ok, isFalse);
      expect(res.error!.code, SyscallErrorCode.eacces);
      expect(res.error!.reason, 'SSRF_BLOCKED_ADDRESS');
    });
  });

  group('PinnedHttpWebFetchTransport ([D-205], [D-217])', () {
    test('blocks 302 redirect SSRF to 127.0.0.1 and 192.168.0.5 before connecting', () async {
      var internalHits = 0;
      final internalServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      internalServer.listen((req) {
        internalHits++;
        req.response
          ..statusCode = 200
          ..write('SECRET_INTERNAL_DATA');
        req.response.close();
      });

      final publicRedirectServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      publicRedirectServer.listen((req) {
        if (req.uri.path == '/to-loopback') {
          req.response
            ..statusCode = 302
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://127.0.0.1:${internalServer.port}/api/tags',
            );
          req.response.close();
        } else if (req.uri.path == '/to-lan') {
          req.response
            ..statusCode = 302
            ..headers.set(
              HttpHeaders.locationHeader,
              'http://192.168.0.5:11434/api/tags',
            );
          req.response.close();
        } else {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><body><p>OK</p></body></html>');
          req.response.close();
        }
      });

      addTearDown(() async {
        await internalServer.close(force: true);
        await publicRedirectServer.close(force: true);
      });

      final transport = PinnedHttpWebFetchTransport(
        ssrfGuard: SsrfGuard(
          dnsLookup: (host) async {
            if (host == 'public.example') {
              return <InternetAddress>[InternetAddress('93.184.216.34')];
            }
            return InternetAddress.lookup(host);
          },
        ),
        socketConnector: (pinnedIp, port, {timeout}) {
          expect(pinnedIp.address, '93.184.216.34');
          return Socket.connect(
            InternetAddress.loopbackIPv4,
            publicRedirectServer.port,
            timeout: timeout,
          );
        },
      );

      final res1 = await transport.fetch(url: 'http://public.example/to-loopback');
      expect(res1.ok, isFalse);
      expect(res1.error!.code, SyscallErrorCode.eacces);
      expect(res1.error!.reason, 'SSRF_BLOCKED_REDIRECT');
      expect(internalHits, 0);

      final res2 = await transport.fetch(url: 'http://public.example/to-lan');
      expect(res2.ok, isFalse);
      expect(res2.error!.code, SyscallErrorCode.eacces);
      expect(res2.error!.reason, 'SSRF_BLOCKED_REDIRECT');
    });

    test('follows valid public redirects up to maxRedirects and rejects excess hops', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        if (req.uri.path == '/hop1') {
          req.response
            ..statusCode = 302
            ..headers.set(HttpHeaders.locationHeader, '/final');
          req.response.close();
        } else if (req.uri.path == '/loop') {
          req.response
            ..statusCode = 302
            ..headers.set(HttpHeaders.locationHeader, '/loop');
          req.response.close();
        } else {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.text
            ..write('arrived');
          req.response.close();
        }
      });
      addTearDown(() => server.close(force: true));

      final transport = PinnedHttpWebFetchTransport(
        ssrfGuard: SsrfGuard(
          dnsLookup: (_) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        ),
        socketConnector: (_, _, {timeout}) => Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
          timeout: timeout,
        ),
      );

      final okRes = await transport.fetch(url: 'http://public.example/hop1');
      expect(okRes.ok, isTrue);
      expect(okRes.value!.finalUrl, 'http://public.example/final');
      expect(utf8.decode(okRes.value!.bodyBytes), 'arrived');

      final tooMany = await transport.fetch(
        url: 'http://public.example/loop',
        maxRedirects: 2,
      );
      expect(tooMany.ok, isFalse);
      expect(tooMany.error!.code, SyscallErrorCode.eio);
      expect(tooMany.error!.reason, 'TOO_MANY_REDIRECTS');
    });

    test('aborts immediately with RESPONSE_TOO_LARGE when stream exceeds 2 MiB', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.text;
        final chunk = Uint8List(64 * 1024)..fillRange(0, 64 * 1024, 65); // 'A'
        try {
          // Stream 3 MiB total (48 * 64 KiB) to trigger 2 MiB streaming cutoff.
          for (var i = 0; i < 48; i++) {
            req.response.add(chunk);
            await req.response.flush();
          }
          await req.response.close();
        } catch (_) {
          // Expected when client abruptly destroys the socket on size overflow.
        }
      });
      addTearDown(() => server.close(force: true));

      final transport = PinnedHttpWebFetchTransport(
        ssrfGuard: SsrfGuard(
          dnsLookup: (_) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        ),
        socketConnector: (_, _, {timeout}) => Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
          timeout: timeout,
        ),
      );

      final res = await transport.fetch(url: 'http://public.example/large');
      expect(res.ok, isFalse);
      expect(res.error!.code, SyscallErrorCode.eio);
      expect(res.error!.reason, 'RESPONSE_TOO_LARGE');
    });

    test('rejects mismatched TLS certificate hostname with HandshakeException -> EIO', () async {
      final pem = await _generateEphemeralSelfSignedPem();
      final serverContext = SecurityContext()
        ..useCertificateChainBytes(pem.certPem)
        ..usePrivateKeyBytes(pem.keyPem);

      final tlsServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      tlsServer.listen((req) {
        req.response
          ..statusCode = 200
          ..write('should never be read');
        req.response.close();
      });
      addTearDown(() => tlsServer.close(force: true));

      final transport = PinnedHttpWebFetchTransport(
        ssrfGuard: SsrfGuard(
          dnsLookup: (_) async => <InternetAddress>[
            InternetAddress('93.184.216.34'),
          ],
        ),
        socketConnector: (pinnedIp, port, {timeout}) {
          expect(pinnedIp.address, '93.184.216.34');
          return Socket.connect(
            InternetAddress.loopbackIPv4,
            tlsServer.port,
            timeout: timeout,
          );
        },
      );

      final res = await transport.fetch(
        url: 'https://wrong-hostname.invalid/secret',
      );
      expect(res.ok, isFalse);
      expect(res.error!.code, SyscallErrorCode.eio);
      expect(res.error!.reason, 'TLS_HANDSHAKE_FAILED');
    });
  });

  group('HtmlMarkdownExtractor & WebFetchDriver ([D-205], [D-217])', () {
    test('strips noise elements and extracts ATX headings, code blocks, links, lists, and tables', () {
      const html = '''
<!doctype html>
<html>
  <head>
    <title>  FM Agent   Spec  </title>
    <style>body { color: red; }</style>
    <script>alert("xss-noise");</script>
  </head>
  <body>
    <header><nav><a href="/home">NavNoise</a></nav></header>
    <aside>SidebarNoise</aside>
    <main>
      <h1>Kernel Architecture</h1>
      <p>Read the <a href="/docs/guide">official guide</a> and <code>sys_web_fetch</code>.</p>
      <script>console.log("inline-script-noise");</script>
      <noscript>NoScriptNoise</noscript>
      <template><p>TemplateNoise</p></template>
      <svg><text>SvgNoise</text></svg>
      <canvas>CanvasNoise</canvas>
      <iframe src="https://evil.example">IframeNoise</iframe>
      <form><input name="q" value="FormNoise"/></form>
      <h2>Features</h2>
      <ul>
        <li>SSRF <strong>blocking</strong></li>
        <li>Markdown extraction</li>
      </ul>
      <pre><code class="language-dart">void main() {
  print('ok');
}</code></pre>
      <table>
        <tr><th>ColA</th><th>ColB</th></tr>
        <tr><td>Val1</td><td>Val2</td></tr>
      </table>
    </main>
    <footer>FooterNoise</footer>
  </body>
</html>
''';

      const extractor = HtmlMarkdownExtractor();
      final doc = extractor.extract(
        html,
        baseUri: Uri.parse('https://example.org/spec/index.html'),
      );

      expect(doc.title, 'FM Agent Spec');
      expect(doc.markdown, contains('# Kernel Architecture'));
      expect(doc.markdown, contains('## Features'));
      expect(
        doc.markdown,
        contains('[official guide](https://example.org/docs/guide)'),
      );
      expect(doc.markdown, contains('`sys_web_fetch`'));
      expect(doc.markdown, contains('- SSRF **blocking**'));
      expect(doc.markdown, contains('```dart\nvoid main() {\n  print(\'ok\');\n}\n```'));
      expect(doc.markdown, contains('| ColA | ColB |'));
      expect(doc.markdown, contains('| --- | --- |'));
      expect(doc.markdown, contains('| Val1 | Val2 |'));

      for (final forbidden in const <String>[
        'xss-noise',
        'color: red',
        'NavNoise',
        'SidebarNoise',
        'inline-script-noise',
        'NoScriptNoise',
        'TemplateNoise',
        'SvgNoise',
        'CanvasNoise',
        'IframeNoise',
        'FormNoise',
        'FooterNoise',
      ]) {
        expect(
          doc.markdown,
          isNot(contains(forbidden)),
          reason: 'Noise token "$forbidden" must be completely stripped',
        );
      }
    });

    test('rejects binary MIME types, NUL-containing bodies, and anti-bot 403/429 without bypass', () async {
      final overlay = FixtureOverlayWebFetchTransport(
        fixtures: <String, WebFetchRawResponse>{
          'https://fixture.invalid/doc.pdf': WebFetchRawResponse(
            requestedUrl: 'https://fixture.invalid/doc.pdf',
            finalUrl: 'https://fixture.invalid/doc.pdf',
            statusCode: 200,
            contentType: 'application/pdf',
            bodyBytes: Uint8List.fromList(utf8.encode('%PDF-1.7')),
          ),
          'https://fixture.invalid/nul.txt': WebFetchRawResponse(
            requestedUrl: 'https://fixture.invalid/nul.txt',
            finalUrl: 'https://fixture.invalid/nul.txt',
            statusCode: 200,
            contentType: 'text/plain; charset=utf-8',
            bodyBytes: Uint8List.fromList(<int>[65, 66, 0, 67]),
          ),
          'https://fixture.invalid/plain.md': WebFetchRawResponse(
            requestedUrl: 'https://fixture.invalid/plain.md',
            finalUrl: 'https://fixture.invalid/plain.md',
            statusCode: 200,
            contentType: 'text/markdown; charset=utf-8',
            bodyBytes: Uint8List.fromList(utf8.encode('# Direct MD')),
          ),
          'https://fixture.invalid/challenge': WebFetchRawResponse(
            requestedUrl: 'https://fixture.invalid/challenge',
            finalUrl: 'https://fixture.invalid/challenge',
            statusCode: 403,
            contentType: 'text/html',
            bodyBytes: Uint8List.fromList(utf8.encode('<html>Captcha</html>')),
          ),
          'https://fixture.invalid/limited': WebFetchRawResponse(
            requestedUrl: 'https://fixture.invalid/limited',
            finalUrl: 'https://fixture.invalid/limited',
            statusCode: 429,
            contentType: 'text/plain',
            bodyBytes: Uint8List.fromList(utf8.encode('Too many requests')),
          ),
        },
      );

      final driver = WebFetchDriver(transport: overlay);

      final pdfRes = await driver.fetch(url: 'https://fixture.invalid/doc.pdf');
      expect(pdfRes.ok, isFalse);
      expect(pdfRes.error!.code, SyscallErrorCode.einval);
      expect(pdfRes.error!.reason, 'UNSUPPORTED_CONTENT_TYPE');

      final nulRes = await driver.fetch(url: 'https://fixture.invalid/nul.txt');
      expect(nulRes.ok, isFalse);
      expect(nulRes.error!.code, SyscallErrorCode.einval);
      expect(nulRes.error!.reason, 'UNSUPPORTED_CONTENT_TYPE');

      final mdRes = await driver.fetch(url: 'https://fixture.invalid/plain.md');
      expect(mdRes.ok, isTrue);
      expect(mdRes.value!['markdown'], '# Direct MD');
      expect(mdRes.value!['contentType'], 'text/markdown');

      final challengeRes =
          await driver.fetch(url: 'https://fixture.invalid/challenge');
      expect(challengeRes.ok, isFalse);
      expect(challengeRes.error!.code, SyscallErrorCode.eprovider);
      expect(challengeRes.error!.reason, 'HTTP_ACCESS_DENIED');

      final limitedRes =
          await driver.fetch(url: 'https://fixture.invalid/limited');
      expect(limitedRes.ok, isFalse);
      expect(limitedRes.error!.code, SyscallErrorCode.eprovider);
      expect(limitedRes.error!.reason, 'RATE_LIMITED');

      // Non-fixture URLs MUST fall through to real PinnedHttpWebFetchTransport & SsrfGuard.
      final ssrfRes = await driver.fetch(url: 'http://127.0.0.1:11434/api/tags');
      expect(ssrfRes.ok, isFalse);
      expect(ssrfRes.error!.code, SyscallErrorCode.eacces);
      expect(ssrfRes.error!.reason, 'SSRF_BLOCKED_ADDRESS');
    });

    test('WebFetchDriver supports startLine/endLine paging, in-memory LRU+TTL cache, and EINVAL validation', () async {
      final lines500 = List<String>.generate(500, (i) => 'Line ${i + 1}: body').join('\n');
      var transportCalls = 0;
      var currentNow = DateTime.utc(2026, 11, 21, 12, 0, 0);

      final countingTransport = _CountingWebFetchTransport(
        onFetch: (url) {
          transportCalls++;
          return SyscallResult<WebFetchRawResponse>.success(
            WebFetchRawResponse(
              requestedUrl: url,
              finalUrl: url,
              statusCode: 200,
              contentType: 'text/markdown',
              bodyBytes: Uint8List.fromList(utf8.encode(lines500)),
            ),
          );
        },
      );

      final driver = WebFetchDriver(
        transport: countingTransport,
        clock: () => currentNow,
      );

      // 1. Default fetch returns lines 1..200 with paging metadata.
      final page1 = await driver.fetch(url: 'https://example.org/long.md');
      expect(page1.ok, isTrue);
      expect(transportCalls, 1);
      expect(page1.value!['totalLines'], 500);
      expect(page1.value!['startLine'], 1);
      expect(page1.value!['endLine'], 200);
      expect(page1.value!['hasMore'], isTrue);
      expect(page1.value!['nextStartLine'], 201);
      expect(page1.value!['markdown'], contains('Line 1: body'));
      expect(page1.value!['markdown'], contains('Line 200: body'));
      expect(page1.value!['markdown'], isNot(contains('Line 201: body')));

      // 2. Subsequent range hits in-memory cache without re-fetching.
      final page2 = await driver.fetch(
        url: 'https://example.org/long.md',
        startLine: 201,
        endLine: 400,
      );
      expect(page2.ok, isTrue);
      expect(transportCalls, 1);
      expect(page2.value!['startLine'], 201);
      expect(page2.value!['endLine'], 400);
      expect(page2.value!['hasMore'], isTrue);
      expect(page2.value!['nextStartLine'], 401);
      expect(page2.value!['markdown'], contains('Line 201: body'));
      expect(page2.value!['markdown'], contains('Line 400: body'));

      // 3. Final partial chunk.
      final page3 = await driver.fetch(
        url: 'https://example.org/long.md',
        startLine: 401,
      );
      expect(page3.ok, isTrue);
      expect(transportCalls, 1);
      expect(page3.value!['startLine'], 401);
      expect(page3.value!['endLine'], 500);
      expect(page3.value!['hasMore'], isFalse);
      expect(page3.value!['nextStartLine'], isNull);

      // 4. Out-of-range startLine > totalLines returns empty markdown without crashing.
      final pastEnd = await driver.fetch(
        url: 'https://example.org/long.md',
        startLine: 600,
      );
      expect(pastEnd.ok, isTrue);
      expect(pastEnd.value!['markdown'], isEmpty);
      expect(pastEnd.value!['hasMore'], isFalse);
      expect(pastEnd.value!['nextStartLine'], isNull);

      // 5. TTL expiration (> 5 minutes) triggers a fresh transport fetch.
      currentNow = currentNow.add(const Duration(minutes: 6));
      final afterTtl = await driver.fetch(url: 'https://example.org/long.md');
      expect(afterTtl.ok, isTrue);
      expect(transportCalls, 2);

      // 6. Invalid startLine / endLine return EINVAL (recoverable).
      final badStart = await driver.fetch(
        url: 'https://example.org/long.md',
        startLine: 0,
      );
      expect(badStart.ok, isFalse);
      expect(badStart.error!.code, SyscallErrorCode.einval);
      expect(badStart.error!.reason, 'INVALID_LINE_RANGE');
      expect(badStart.error!.recoverable, isTrue);

      final badEnd = await driver.fetch(
        url: 'https://example.org/long.md',
        startLine: 50,
        endLine: 10,
      );
      expect(badEnd.ok, isFalse);
      expect(badEnd.error!.code, SyscallErrorCode.einval);
      expect(badEnd.error!.reason, 'INVALID_LINE_RANGE');

      // 7. SyscallDefinition validateArgs also rejects invalid line ranges.
      final def = buildWebFetchSyscallDefinition(driver: driver);
      final schemaErr = def.validateArgs!(<String, dynamic>{
        'url': 'https://example.org/long.md',
        'startLine': 10,
        'endLine': 5,
      });
      expect(schemaErr, isNotNull);
      expect(schemaErr!.code, SyscallErrorCode.einval);
      expect(schemaErr.reason, 'INVALID_LINE_RANGE');
    });
  });

  group('OllamaWebSearchBackend ([D-203], [D-216])', () {
    test('returns MISSING_API_KEY without issuing HTTP calls when key is unset', () async {
      var httpCalls = 0;
      final client = MockClient((_) async {
        httpCalls++;
        return http.Response('{}', 200);
      });

      final emptyEnv = LlmEnvLoader(
        processEnvironment: const <String, String>{},
        currentDirectoryPath: Directory.systemTemp.path,
      );
      final backend = OllamaWebSearchBackend(
        envLoader: emptyEnv,
        httpClient: client,
      );

      final res = await backend.search(query: 'Dart Isolate');
      expect(res.ok, isFalse);
      expect(res.error!.code, SyscallErrorCode.eprovider);
      expect(res.error!.reason, 'MISSING_API_KEY');
      expect(httpCalls, 0);
    });

    test('parses valid response, applies OLLAMA_API_KEY > OLLAMA_CLOUD_API_KEY precedence', () async {
      String? seenAuth;
      Map<String, dynamic>? seenBody;
      Uri? seenUrl;

      final client = MockClient((request) async {
        seenUrl = request.url;
        seenAuth = request.headers[HttpHeaders.authorizationHeader];
        seenBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'results': <Map<String, dynamic>>[
              <String, dynamic>{
                'title': 'Dart Isolate.spawn',
                'url': 'https://api.dart.dev/dart-isolate/Isolate/spawn.html',
                'content': 'Spawns an isolate that shares the same code.',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final env = LlmEnvLoader(
        processEnvironment: const <String, String>{
          'OLLAMA_API_KEY': 'primary-secret-key-1234',
          'OLLAMA_CLOUD_API_KEY': 'fallback-secret-key-5678',
        },
        currentDirectoryPath: Directory.systemTemp.path,
      );

      final backend = OllamaWebSearchBackend(
        envLoader: env,
        httpClient: client,
      );

      final res = await backend.search(query: 'Dart Isolate.spawn', maxResults: 3);
      expect(res.ok, isTrue);
      expect(seenUrl.toString(), 'https://ollama.com/api/web_search');
      expect(seenAuth, 'Bearer primary-secret-key-1234');
      expect(seenBody, <String, dynamic>{
        'query': 'Dart Isolate.spawn',
        'max_results': 3,
      });
      expect(res.value!.provider, 'ollama-web-search');
      expect(res.value!.results, hasLength(1));
      expect(res.value!.results.first.title, 'Dart Isolate.spawn');
      expect(
        res.value!.results.first.url,
        'https://api.dart.dev/dart-isolate/Isolate/spawn.html',
      );
      expect(res.value!.results.first.contentTruncated, isFalse);
      expect(res.value!.results.first.toJson().containsKey('contentTruncated'), isFalse);
    });

    test('truncates oversized result content to maxSnippetChars (800) with contentTruncated metadata', () async {
      final hugeContent = 'A' * 2000;
      final client = MockClient((_) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'results': <Map<String, dynamic>>[
              <String, dynamic>{
                'title': 'Huge Page',
                'url': 'https://example.org/huge',
                'content': hugeContent,
              },
              <String, dynamic>{
                'title': 'Short Page',
                'url': 'https://example.org/short',
                'content': 'Short snippet',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });

      final backend = OllamaWebSearchBackend(
        apiKey: 'test-key',
        httpClient: client,
      );

      final res = await backend.search(query: 'huge');
      expect(res.ok, isTrue);
      expect(res.value!.results, hasLength(2));

      final first = res.value!.results[0];
      expect(first.content, equals('${'A' * 800}...'));
      expect(first.contentTruncated, isTrue);
      expect(first.originalContentChars, 2000);
      expect(first.toJson()['contentTruncated'], isTrue);
      expect(first.toJson()['originalContentChars'], 2000);

      final second = res.value!.results[1];
      expect(second.content, equals('Short snippet'));
      expect(second.contentTruncated, isFalse);
      expect(second.toJson().containsKey('contentTruncated'), isFalse);
      expect(second.toJson().containsKey('originalContentChars'), isFalse);
    });

    test('normalizes 401/429 and redacts API key to <REDACTED> in error messages', () async {
      const secretKey = 'oll_live_super_secret_token_987654';
      final redactor = SecretRedactor();

      final client429 = MockClient((_) async {
        return http.Response('Rate limit for $secretKey', 429);
      });
      final backend429 = OllamaWebSearchBackend(
        apiKey: secretKey,
        redactor: redactor,
        httpClient: client429,
      );
      final res429 = await backend429.search(query: 'rate test');
      expect(res429.ok, isFalse);
      expect(res429.error!.code, SyscallErrorCode.eprovider);
      expect(res429.error!.reason, 'RATE_LIMITED');
      expect(res429.error!.recoverable, isFalse);
      expect(res429.error!.message, isNot(contains(secretKey)));

      final client500 = MockClient((_) async {
        return http.Response(
          'Upstream failure echoing Bearer $secretKey and raw $secretKey',
          500,
        );
      });
      final backend500 = OllamaWebSearchBackend(
        apiKey: secretKey,
        redactor: redactor,
        httpClient: client500,
      );
      final res500 = await backend500.search(query: 'error leak test');
      expect(res500.ok, isFalse);
      expect(res500.error!.code, SyscallErrorCode.eprovider);
      expect(res500.error!.reason, 'SEARCH_BACKEND_ERROR');
      expect(res500.error!.message, isNot(contains(secretKey)));
      expect(res500.error!.message, contains('<REDACTED>'));

      final client401 = MockClient((_) async => http.Response('Unauthorized', 401));
      final backend401 = OllamaWebSearchBackend(
        apiKey: secretKey,
        redactor: redactor,
        httpClient: client401,
      );
      final res401 = await backend401.search(query: 'auth test');
      expect(res401.ok, isFalse);
      expect(res401.error!.code, SyscallErrorCode.eprovider);
      expect(res401.error!.reason, 'UNAUTHORIZED');
    });
  });

  group('Workspace ⊕ Net isolation & SyscallGate integration ([D-204], [D-216], [D-217])', () {
    test('blocks LeadAgent and Explorer with EPERM: NET_REQUIRES_ISOLATED_RESEARCHER while allowing sterile WebResearcher', () async {
      final tempDir = await Directory.systemTemp.createTemp('wp6_gate_test_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final redactor = SecretRedactor();
      final auditLogger = AuditLogger(
        workspaceHostRoot: tempDir.path,
        sessionId: 'sess_wp6',
        redactor: redactor,
      );
      final processTable = KernelProcessTable.stage2();

      // PID 1: LeadAgent with /workspace + netRead (delegation source only).
      final leadPcb = processTable.registerProcess(
        ProcessControlBlock(
          pid: 1,
          name: 'lead_agent',
          ring: ProtectionRing.ring2,
          cspace: CapabilityTable.stage2LeadAgent(),
          quota: ResourceQuota.stage2Default,
          namespace: VfsNamespace(workspaceHostRoot: tempDir.path),
          memory: VirtualContextMemory(
            sessionId: 'sess_wp6',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'lead',
              tools: const <SyscallToolSchema>[],
            ),
          ),
        ),
      );
      expect(leadPcb.ok, isTrue);

      // PID 2: Explorer with /workspace + read (and even if netRead were present, W⊕N blocks).
      final explorerPcb = processTable.registerProcess(
        ProcessControlBlock(
          pid: 2,
          parentPid: 1,
          name: 'explorer',
          ring: ProtectionRing.ring3,
          profile: ProcessProfileId.explorer,
          cspace: CapabilityTable(
            initialEntries: <CapabilityEntry>[
              CapabilityEntry(
                handle: const CapHandle('cap_explorer'),
                resourceScope: '/workspace',
                rights: const <CapRight>{
                  CapRight.read,
                  CapRight.netRead,
                  CapRight.llmInfer,
                  CapRight.ipc,
                  CapRight.procSelf,
                },
              ),
            ],
          ),
          quota: ResourceQuota.stage2Default,
          namespace: VfsNamespace(workspaceHostRoot: tempDir.path),
          memory: VirtualContextMemory(
            sessionId: 'sess_wp6',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'explorer',
              tools: const <SyscallToolSchema>[],
            ),
          ),
        ),
      );
      expect(explorerPcb.ok, isTrue);

      // PID 3: Sterile WebResearcher (VfsNamespace.empty(), netRead only).
      final webPcb = processTable.registerProcess(
        ProcessControlBlock(
          pid: 3,
          parentPid: 1,
          name: 'web_researcher',
          ring: ProtectionRing.ring3,
          profile: ProcessProfileId.webResearcher,
          cspace: CapabilityTable(
            initialEntries: <CapabilityEntry>[
              CapabilityEntry(
                handle: const CapHandle('cap_net_only'),
                resourceScope: 'net:public_readonly',
                rights: const <CapRight>{
                  CapRight.netRead,
                  CapRight.llmInfer,
                  CapRight.ipc,
                  CapRight.procSelf,
                },
              ),
            ],
          ),
          quota: ResourceQuota.stage2Default,
          namespace: const VfsNamespace.empty(),
          memory: VirtualContextMemory(
            sessionId: 'sess_wp6',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'web_researcher',
              tools: <SyscallToolSchema>[
                buildWebSearchToolSchema(),
                buildWebFetchToolSchema(),
              ],
            ),
          ),
        ),
      );
      expect(webPcb.ok, isTrue);

      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(
          handler: PolicyApprovalHandler.alwaysReject(),
        ),
        ioCapper: IoPayloadCapper(
          config: const IoCapConfig(maxLines: 10, maxUtf8Bytes: 512),
          workspaceHostRoot: tempDir.path,
        ),
        auditLogger: auditLogger,
        redactor: redactor,
      );

      const secretKey = 'oll_gate_audit_secret_777777';
      final searchBackend = OllamaWebSearchBackend(
        apiKey: secretKey,
        redactor: redactor,
        httpClient: MockClient((_) async {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'results': <Map<String, dynamic>>[
                <String, dynamic>{
                  'title': 'Result 1',
                  'url': 'https://example.org/1',
                  'content': 'Snippet with $secretKey leaked by upstream',
                },
              ],
            }),
            200,
          );
        }),
      );

      final longMarkdown = List<String>.generate(50, (i) => 'Line $i: content').join('\n');
      final fetchDriver = WebFetchDriver(
        transport: FixtureOverlayWebFetchTransport(
          fixtures: <String, WebFetchRawResponse>{
            'https://fixture.invalid/page': WebFetchRawResponse(
              requestedUrl: 'https://fixture.invalid/page',
              finalUrl: 'https://fixture.invalid/page',
              statusCode: 200,
              contentType: 'text/markdown',
              bodyBytes: Uint8List.fromList(utf8.encode(longMarkdown)),
            ),
          },
        ),
      );

      gate.registerSyscall(buildWebSearchSyscallDefinition(backend: searchBackend));
      gate.registerSyscall(buildWebFetchSyscallDefinition(driver: fetchDriver));

      // 1. LeadAgent (holds /workspace + read/writeCow/exec) MUST be denied by W⊕N.
      final leadSearch = await gate.invoke(
        SyscallContext(
          pid: leadPcb.value!.pid,
          capHandle: const CapHandle('cap_workspace_rw'),
          sessionId: 'sess_wp6',
        ),
        SyscallRequest(
          name: 'sys_web_search',
          args: const <String, dynamic>{'query': 'test'},
        ),
      );
      expect(leadSearch.ok, isFalse);
      expect(leadSearch.error!.code, SyscallErrorCode.eperm);
      expect(leadSearch.error!.reason, 'NET_REQUIRES_ISOLATED_RESEARCHER');

      final leadFetch = await gate.invoke(
        SyscallContext(
          pid: leadPcb.value!.pid,
          capHandle: const CapHandle('cap_net_public'),
          sessionId: 'sess_wp6',
        ),
        SyscallRequest(
          name: 'sys_web_fetch',
          args: const <String, dynamic>{'url': 'https://fixture.invalid/page'},
        ),
      );
      expect(leadFetch.ok, isFalse);
      expect(leadFetch.error!.code, SyscallErrorCode.eperm);
      expect(leadFetch.error!.reason, 'NET_REQUIRES_ISOLATED_RESEARCHER');

      // 2. Explorer (holds /workspace + read) MUST also be denied by W⊕N.
      final explorerFetch = await gate.invoke(
        SyscallContext(
          pid: explorerPcb.value!.pid,
          capHandle: const CapHandle('cap_explorer'),
          sessionId: 'sess_wp6',
        ),
        SyscallRequest(
          name: 'sys_web_fetch',
          args: const <String, dynamic>{'url': 'https://fixture.invalid/page'},
        ),
      );
      expect(explorerFetch.ok, isFalse);
      expect(explorerFetch.error!.code, SyscallErrorCode.eperm);
      expect(explorerFetch.error!.reason, 'NET_REQUIRES_ISOLATED_RESEARCHER');

      // 3. Sterile WebResearcher MUST succeed and receive capped & redacted outputs.
      final webSearch = await gate.invoke(
        SyscallContext(
          pid: webPcb.value!.pid,
          capHandle: const CapHandle('cap_net_only'),
          sessionId: 'sess_wp6',
        ),
        SyscallRequest(
          name: 'sys_web_search',
          args: const <String, dynamic>{'query': 'test', 'maxResults': 2},
        ),
      );
      expect(webSearch.ok, isTrue);
      final encodedSearch = jsonEncode(webSearch.value);
      expect(encodedSearch, isNot(contains(secretKey)));
      expect(encodedSearch, contains('<REDACTED>'));

      final webFetch = await gate.invoke(
        SyscallContext(
          pid: webPcb.value!.pid,
          capHandle: const CapHandle('cap_net_only'),
          sessionId: 'sess_wp6',
        ),
        SyscallRequest(
          name: 'sys_web_fetch',
          args: const <String, dynamic>{'url': 'https://fixture.invalid/page'},
        ),
      );
      expect(webFetch.ok, isTrue);
      expect(webFetch.value!['truncated'], isTrue);
      expect(
        webFetch.value!['markdown'] as String,
        contains('KERNEL I/O CAP'),
      );

      // Verify audit log never contains the raw secret key.
      final auditFile = File(auditLogger.syscallsLogPath);
      expect(auditFile.existsSync(), isTrue);
      final auditText = await auditFile.readAsString();
      expect(auditText, isNot(contains(secretKey)));
    });
  });

  group('E3 structural verification ([D-205], [D-217])', () {
    test('PinnedHttpWebFetchTransport enforces DIRECT proxy, connectionFactory pinning, SecureSocket host check, and zero SSRF bypass env vars', () {
      final file = File('lib/src/net/web_fetch_driver.dart');
      final source = file.existsSync()
          ? file.readAsStringSync()
          : File('packages/agent_drivers/lib/src/net/web_fetch_driver.dart')
              .readAsStringSync();

      expect(source, contains("findProxy = (_) => 'DIRECT'"));
      expect(source, contains('client.connectionFactory ='));
      expect(source, contains('SecureSocket.secure(raw, host: uri.host)'));
      expect(source, isNot(contains('Platform.environment')));
      expect(source, isNot(contains('ALLOW_PRIVATE')));
      expect(source, isNot(contains('DISABLE_SSRF')));
    });
  });
}

class _CountingWebFetchTransport implements WebFetchTransport {
  _CountingWebFetchTransport({required this.onFetch});

  final SyscallResult<WebFetchRawResponse> Function(String url) onFetch;

  @override
  Future<SyscallResult<WebFetchRawResponse>> fetch({
    required String url,
    Duration? timeout,
    int? maxRedirects,
    int? maxResponseBytes,
    CancellationToken? cancelToken,
  }) async {
    return onFetch(url);
  }
}
