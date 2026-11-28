import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/llm_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

typedef _MockHandler = Future<http.StreamedResponse> Function(
  http.BaseRequest request,
  String bodyText,
);

class _CapturedRequest {
  _CapturedRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.bodyText,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String bodyText;

  Map<String, dynamic> get jsonBody =>
      jsonDecode(bodyText) as Map<String, dynamic>;
}

class _MockHttpClient extends http.BaseClient {
  _MockHttpClient(this._handler);

  final _MockHandler _handler;
  final List<_CapturedRequest> requests = <_CapturedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    final bodyText = utf8.decode(bytes);
    requests.add(
      _CapturedRequest(
        method: request.method,
        uri: request.url,
        headers: Map<String, String>.from(request.headers),
        bodyText: bodyText,
      ),
    );
    return _handler(request, bodyText);
  }
}

http.StreamedResponse _sseResponse(
  List<String> lines, {
  int statusCode = 200,
}) {
  final payload = '${lines.join('\n')}\n';
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(payload)),
    statusCode,
    headers: const <String, String>{'content-type': 'text/event-stream'},
  );
}

http.StreamedResponse _jsonResponse(
  Object body, {
  int statusCode = 200,
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
    statusCode,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

http.StreamedResponse _okGenerateSse({
  String text = 'ok',
  int promptTokens = 1200,
  int cachedTokens = 1100,
  List<Map<String, dynamic>>? customParts,
}) {
  final parts = customParts ??
      <Map<String, dynamic>>[
        <String, dynamic>{'text': text},
      ];
  return _sseResponse(<String>[
    'data: ${jsonEncode(<String, dynamic>{
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'content': <String, dynamic>{
                'role': 'model',
                'parts': parts,
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': <String, dynamic>{
            'promptTokenCount': promptTokens,
            'candidatesTokenCount': 10,
            'totalTokenCount': promptTokens + 10,
            'cachedContentTokenCount': cachedTokens,
          },
        })}',
  ]);
}

Future<LlmChatResponse> _collectDone(Stream<LlmStreamEvent> stream) async {
  LlmChatResponse? done;
  await for (final event in stream) {
    if (event is LlmDoneEvent) {
      done = event.response;
    }
  }
  return done!;
}

SyscallToolSchema _sampleTool({String name = 'fs_read'}) {
  return SyscallToolSchema(
    name: name,
    description: 'Reads a workspace file.',
    parametersJsonSchema: const <String, dynamic>{
      'type': 'object',
      r'$schema': 'https://json-schema.org/draft/2020-12/schema',
      'additionalProperties': false,
      'properties': <String, dynamic>{
        'path': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['path'],
    },
  );
}

LlmChatRequest _buildRequest({
  String modelName = 'gemini-2.5-flash',
  required String systemText,
  String userText = 'Hello',
  List<SyscallToolSchema>? tools,
  List<ProjectedMessage>? extraMessages,
  bool stream = true,
}) {
  return LlmChatRequest(
    sessionId: 'sess-gemini',
    sessionUuid: 'uuid-gemini',
    model: ModelIdentifier(
      provider: LlmProviderId.gemini,
      modelName: modelName,
    ),
    prompt: ProjectedPrompt(
      messages: <ProjectedMessage>[
        if (systemText.isNotEmpty)
          ProjectedMessage(
            role: ProjectedRole.system,
            content: systemText,
            segmentIndex: 0,
          ),
        ProjectedMessage(
          role: ProjectedRole.user,
          content: userText,
          segmentIndex: 2,
        ),
        ...?extraMessages,
      ],
      tools: tools ?? <SyscallToolSchema>[_sampleTool()],
    ),
    stream: stream,
  );
}

/// Generates a deterministic system prompt whose UTF-8 byte length is roughly [approxTokens] * 4.
String _largeSystemPrompt(int approxTokens, {String seed = 'A'}) {
  final unit = 'Instruction block ($seed) for explicit context caching. ';
  final targetBytes = approxTokens * 4;
  final repeats = (targetBytes / unit.length).ceil() + 2;
  return List<String>.filled(repeats, unit).join();
}

void main() {
  group('GeminiDriver explicit Context Caching [D-607]', () {
    test('1. creates cachedContent on first request and reuses it on subsequent request without systemInstruction/tools/toolConfig', () async {
      final baseTime = DateTime.utc(2026, 11, 28, 12, 0, 0);
      var createCalls = 0;

      final client = _MockHttpClient((req, body) async {
        if (req.method == 'POST' && req.url.path.endsWith('/v1beta/cachedContents')) {
          createCalls++;
          return _jsonResponse(<String, dynamic>{
            'name': 'cachedContents/cache_001',
            'expireTime': baseTime.add(const Duration(seconds: 300)).toIso8601String(),
            'usageMetadata': <String, dynamic>{'totalTokenCount': 1250},
          });
        }
        return _okGenerateSse(text: 'Reply $createCalls', cachedTokens: 1200);
      });

      final driver = GeminiDriver(
        apiKey: 'AIza-test-key-1',
        httpClient: client,
        clock: () => baseTime,
      );

      final sys = _largeSystemPrompt(1150);
      final done1 = await _collectDone(
        driver.chatStream(_buildRequest(systemText: sys, userText: 'Step 1')),
      );
      final done2 = await _collectDone(
        driver.chatStream(_buildRequest(systemText: sys, userText: 'Step 2')),
      );

      expect(done1.content, equals('Reply 1'));
      expect(done2.content, equals('Reply 1'));
      expect(done2.usage.cachedTokens, equals(1200));
      expect(createCalls, equals(1));
      expect(client.requests, hasLength(3));

      final createReq = client.requests[0];
      expect(createReq.method, equals('POST'));
      expect(createReq.uri.path, equals('/v1beta/cachedContents'));
      expect(createReq.jsonBody['model'], equals('models/gemini-2.5-flash'));
      expect(createReq.jsonBody['ttl'], equals('300s'));
      expect(createReq.jsonBody.containsKey('contents'), isFalse);
      expect(createReq.jsonBody.containsKey('systemInstruction'), isTrue);
      expect(createReq.jsonBody.containsKey('tools'), isTrue);

      final gen1 = client.requests[1];
      expect(gen1.uri.path, equals('/v1beta/models/gemini-2.5-flash:streamGenerateContent'));
      expect(gen1.uri.queryParameters['alt'], equals('sse'));
      expect(gen1.jsonBody['cachedContent'], equals('cachedContents/cache_001'));
      expect(gen1.jsonBody.containsKey('systemInstruction'), isFalse);
      expect(gen1.jsonBody.containsKey('tools'), isFalse);
      expect(gen1.jsonBody.containsKey('toolConfig'), isFalse);
      expect(gen1.jsonBody['contents'], isA<List<dynamic>>());

      final gen2 = client.requests[2];
      expect(gen2.uri.path, equals('/v1beta/models/gemini-2.5-flash:streamGenerateContent'));
      expect(gen2.jsonBody['cachedContent'], equals('cachedContents/cache_001'));
      expect(gen2.jsonBody.containsKey('systemInstruction'), isFalse);
      expect(gen2.jsonBody.containsKey('tools'), isFalse);
      expect(gen2.jsonBody.containsKey('toolConfig'), isFalse);
    });

    test('2. enforces model-specific min token thresholds (Flash 1024, Pro 2048) and skips cachedContents below threshold or empty Segment 0', () async {
      expect(GeminiDriver.resolveMinCacheTokens('gemini-2.5-flash'), equals(1024));
      expect(GeminiDriver.resolveMinCacheTokens('models/gemini-3-flash-preview'), equals(1024));
      expect(GeminiDriver.resolveMinCacheTokens('gemini-2.5-pro'), equals(2048));
      expect(GeminiDriver.resolveMinCacheTokens('gemini-experimental'), equals(2048));

      final client = _MockHttpClient((req, body) async {
        if (req.url.path.contains('cachedContents')) {
          fail('cachedContents API should not be called below threshold');
        }
        return _okGenerateSse(text: 'normal', cachedTokens: 0);
      });

      final driver = GeminiDriver(
        apiKey: 'AIza-test-key-2',
        httpClient: client,
      );

      // Flash below 1024 tokens
      await _collectDone(
        driver.chatStream(
          _buildRequest(
            modelName: 'gemini-2.5-flash',
            systemText: 'Short system prompt.',
          ),
        ),
      );

      // Pro with ~1500 tokens (above 1024, below 2048)
      await _collectDone(
        driver.chatStream(
          _buildRequest(
            modelName: 'gemini-2.5-pro',
            systemText: _largeSystemPrompt(1400),
          ),
        ),
      );

      // Empty Segment 0 (no systemInstruction and no tools)
      await _collectDone(
        driver.chatStream(
          _buildRequest(
            modelName: 'gemini-2.5-flash',
            systemText: '',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );

      expect(client.requests, hasLength(3));
      for (final req in client.requests) {
        expect(req.uri.path, isNot(contains('cachedContents')));
        expect(req.jsonBody.containsKey('cachedContent'), isFalse);
      }
      expect(client.requests[0].jsonBody.containsKey('systemInstruction'), isTrue);
      expect(client.requests[1].jsonBody.containsKey('systemInstruction'), isTrue);
    });

    test('3. respects disable switches and priority (constructor > GEMINI_EXPLICIT_CACHE env > default true) and TTL env', () async {
      final envDir = Directory.systemTemp.createTempSync('gemini_cache_env_');
      try {
        final agentOsDir =
            Directory('${envDir.path}${Platform.pathSeparator}.agent_os')
              ..createSync(recursive: true);
        File('${agentOsDir.path}${Platform.pathSeparator}.env')
            .writeAsStringSync(
          'GEMINI_API_KEY=AIza-env-key\n'
          'GEMINI_EXPLICIT_CACHE=false\n'
          'GEMINI_EXPLICIT_CACHE_TTL_SECONDS=600\n',
        );
        final envLoader = LlmEnvLoader(
          sessionCwd: envDir.path,
          processEnvironment: const <String, String>{},
        );
        final largeSys = _largeSystemPrompt(1200);

        // (a) Constructor enableExplicitCaching: false disables caching
        final clientA = _MockHttpClient((req, body) async => _okGenerateSse());
        final driverA = GeminiDriver(
          apiKey: 'AIza-explicit',
          httpClient: clientA,
          enableExplicitCaching: false,
        );
        await _collectDone(driverA.chatStream(_buildRequest(systemText: largeSys)));
        expect(clientA.requests, hasLength(1));
        expect(clientA.requests.single.jsonBody.containsKey('cachedContent'), isFalse);

        // (b) Env GEMINI_EXPLICIT_CACHE=false disables caching when constructor arg is null
        final clientB = _MockHttpClient((req, body) async => _okGenerateSse());
        final driverB = GeminiDriver(
          envLoader: envLoader,
          httpClient: clientB,
        );
        await _collectDone(driverB.chatStream(_buildRequest(systemText: largeSys)));
        expect(clientB.requests, hasLength(1));
        expect(clientB.requests.single.jsonBody.containsKey('cachedContent'), isFalse);

        // (c) Constructor enableExplicitCaching: true overrides env GEMINI_EXPLICIT_CACHE=false
        //     and picks up GEMINI_EXPLICIT_CACHE_TTL_SECONDS=600
        final clientC = _MockHttpClient((req, body) async {
          if (req.url.path.endsWith('/v1beta/cachedContents')) {
            return _jsonResponse(<String, dynamic>{
              'name': 'cachedContents/override_ok',
            });
          }
          return _okGenerateSse();
        });
        final driverC = GeminiDriver(
          envLoader: envLoader,
          httpClient: clientC,
          enableExplicitCaching: true,
        );
        await _collectDone(driverC.chatStream(_buildRequest(systemText: largeSys)));
        expect(clientC.requests, hasLength(2));
        expect(clientC.requests[0].uri.path, equals('/v1beta/cachedContents'));
        expect(clientC.requests[0].jsonBody['ttl'], equals('600s'));
        expect(
          clientC.requests[1].jsonBody['cachedContent'],
          equals('cachedContents/override_ok'),
        );
      } finally {
        envDir.deleteSync(recursive: true);
      }
    });

    test('4. recreates cache on model/Segment0 change and evicts LRU entry with DELETE when maxCachedEntries exceeded', () async {
      var now = DateTime.utc(2026, 11, 28, 12, 0, 0);
      var counter = 0;
      final deletedPaths = <String>[];
      final deleteDone = Completer<void>();

      final client = _MockHttpClient((req, body) async {
        if (req.method == 'POST' && req.url.path.endsWith('/v1beta/cachedContents')) {
          counter++;
          return _jsonResponse(<String, dynamic>{
            'name': 'cachedContents/lru_$counter',
            'expireTime': now.add(const Duration(seconds: 300)).toIso8601String(),
          });
        }
        if (req.method == 'DELETE') {
          deletedPaths.add(req.url.path);
          if (!deleteDone.isCompleted) {
            deleteDone.complete();
          }
          return _jsonResponse(<String, dynamic>{});
        }
        return _okGenerateSse();
      });

      final driver = GeminiDriver(
        apiKey: 'AIza-lru-key',
        httpClient: client,
        maxCachedEntries: 2,
        clock: () => now,
      );

      final sysA = _largeSystemPrompt(1150, seed: 'A');
      final sysB = _largeSystemPrompt(1150, seed: 'B');

      // Create A (t=0)
      await _collectDone(driver.chatStream(_buildRequest(systemText: sysA)));
      // Create B (t=10s)
      now = now.add(const Duration(seconds: 10));
      await _collectDone(driver.chatStream(_buildRequest(systemText: sysB)));
      // Touch A so B becomes least-recently-used (t=20s)
      now = now.add(const Duration(seconds: 10));
      await _collectDone(driver.chatStream(_buildRequest(systemText: sysA)));
      // Create C by changing model (t=30s) -> exceeds maxCachedEntries(2) -> evicts B (lru_2)
      now = now.add(const Duration(seconds: 10));
      await _collectDone(
        driver.chatStream(
          _buildRequest(
            modelName: 'gemini-3-flash-preview',
            systemText: sysA,
          ),
        ),
      );

      await deleteDone.future.timeout(const Duration(seconds: 2));
      expect(counter, equals(3));
      expect(deletedPaths, equals(<String>['/v1beta/cachedContents/lru_2']));
    });

    test('5. renews TTL via PATCH when within renewWindow and recreates via POST after expiration', () async {
      var now = DateTime.utc(2026, 11, 28, 12, 0, 0);
      var postCount = 0;
      var patchCount = 0;

      final client = _MockHttpClient((req, body) async {
        if (req.method == 'POST' && req.url.path.endsWith('/v1beta/cachedContents')) {
          postCount++;
          return _jsonResponse(<String, dynamic>{
            'name': 'cachedContents/ttl_$postCount',
            'expireTime': now.add(const Duration(seconds: 300)).toIso8601String(),
          });
        }
        if (req.method == 'PATCH' &&
            req.url.path.startsWith('/v1beta/cachedContents/')) {
          patchCount++;
          return _jsonResponse(<String, dynamic>{
            'name': 'cachedContents/ttl_$postCount',
            'expireTime': now.add(const Duration(seconds: 300)).toIso8601String(),
          });
        }
        return _okGenerateSse();
      });

      final driver = GeminiDriver(
        apiKey: 'AIza-ttl-key',
        httpClient: client,
        explicitCacheTtl: const Duration(seconds: 300),
        explicitCacheRenewWindow: const Duration(seconds: 60),
        clock: () => now,
      );

      final sys = _largeSystemPrompt(1150);

      // t=0: POST create (expires at t=300)
      await _collectDone(driver.chatStream(_buildRequest(systemText: sys)));
      expect(postCount, equals(1));
      expect(patchCount, equals(0));

      // t=250 (remaining 50s < 60s): triggers PATCH (extends expireTime to t=550)
      now = now.add(const Duration(seconds: 250));
      await _collectDone(driver.chatStream(_buildRequest(systemText: sys)));
      expect(postCount, equals(1));
      expect(patchCount, equals(1));
      final patchReq = client.requests.firstWhere((r) => r.method == 'PATCH');
      expect(patchReq.uri.path, equals('/v1beta/cachedContents/ttl_1'));
      expect(patchReq.jsonBody, equals(<String, dynamic>{'ttl': '300s'}));

      // t=600 (past extended expireTime 550): triggers new POST create
      now = now.add(const Duration(seconds: 350));
      await _collectDone(driver.chatStream(_buildRequest(systemText: sys)));
      expect(postCount, equals(2));
      final lastGen = client.requests.last;
      expect(lastGen.jsonBody['cachedContent'], equals('cachedContents/ttl_2'));
    });

    test('6. transparently falls back on cachedContents POST failure (400/429/500/network) and applies negative cache for 400 and 429', () async {
      final sys = _largeSystemPrompt(1150);

      // (a) HTTP 400 -> fallback + 5 min negative cache
      var now400 = DateTime.utc(2026, 11, 28, 12, 0, 0);
      var post400Count = 0;
      final client400 = _MockHttpClient((req, body) async {
        if (req.url.path.endsWith('/v1beta/cachedContents')) {
          post400Count++;
          return _jsonResponse(<String, dynamic>{'error': 'too small'}, statusCode: 400);
        }
        return _okGenerateSse(text: 'fallback-400', cachedTokens: 0);
      });
      final driver400 = GeminiDriver(
        apiKey: 'AIza-fb-400',
        httpClient: client400,
        clock: () => now400,
      );
      final r1 = await _collectDone(driver400.chatStream(_buildRequest(systemText: sys)));
      expect(r1.content, equals('fallback-400'));
      expect(post400Count, equals(1));
      expect(client400.requests.last.jsonBody.containsKey('cachedContent'), isFalse);
      expect(client400.requests.last.jsonBody.containsKey('systemInstruction'), isTrue);
      expect(client400.requests.last.jsonBody.containsKey('tools'), isTrue);

      // Second call within 5 min should skip POST due to negative cache
      now400 = now400.add(const Duration(minutes: 2));
      await _collectDone(driver400.chatStream(_buildRequest(systemText: sys)));
      expect(post400Count, equals(1));

      // After 5 min negative cache expires, POST is retried
      now400 = now400.add(const Duration(minutes: 4));
      await _collectDone(driver400.chatStream(_buildRequest(systemText: sys)));
      expect(post400Count, equals(2));

      // (b) HTTP 429 -> fallback + 60s negative cache
      var now429 = DateTime.utc(2026, 11, 28, 12, 0, 0);
      var post429Count = 0;
      final client429 = _MockHttpClient((req, body) async {
        if (req.url.path.endsWith('/v1beta/cachedContents')) {
          post429Count++;
          return _jsonResponse(<String, dynamic>{'error': 'quota'}, statusCode: 429);
        }
        return _okGenerateSse(text: 'fallback-429', cachedTokens: 0);
      });
      final driver429 = GeminiDriver(
        apiKey: 'AIza-fb-429',
        httpClient: client429,
        clock: () => now429,
      );
      final r429 = await _collectDone(driver429.chatStream(_buildRequest(systemText: sys)));
      expect(r429.content, equals('fallback-429'));
      expect(post429Count, equals(1));

      now429 = now429.add(const Duration(seconds: 30));
      await _collectDone(driver429.chatStream(_buildRequest(systemText: sys)));
      expect(post429Count, equals(1));

      now429 = now429.add(const Duration(seconds: 35));
      await _collectDone(driver429.chatStream(_buildRequest(systemText: sys)));
      expect(post429Count, equals(2));

      // (c) HTTP 500 -> fallback without negative caching
      var post500Count = 0;
      final client500 = _MockHttpClient((req, body) async {
        if (req.url.path.endsWith('/v1beta/cachedContents')) {
          post500Count++;
          return _jsonResponse(<String, dynamic>{'error': 'internal'}, statusCode: 500);
        }
        return _okGenerateSse(text: 'fallback-500', cachedTokens: 0);
      });
      final driver500 = GeminiDriver(apiKey: 'AIza-fb-500', httpClient: client500);
      final r500 = await _collectDone(driver500.chatStream(_buildRequest(systemText: sys)));
      expect(r500.content, equals('fallback-500'));
      await _collectDone(driver500.chatStream(_buildRequest(systemText: sys)));
      expect(post500Count, equals(2));

      // (d) Network exception during POST -> fallback
      final clientNet = _MockHttpClient((req, body) async {
        if (req.url.path.endsWith('/v1beta/cachedContents')) {
          throw const SocketException('Temporary DNS failure');
        }
        return _okGenerateSse(text: 'fallback-net', cachedTokens: 0);
      });
      final driverNet = GeminiDriver(apiKey: 'AIza-fb-net', httpClient: clientNet);
      final rNet = await _collectDone(driverNet.chatStream(_buildRequest(systemText: sys)));
      expect(rNet.content, equals('fallback-net'));
    });

    test('7. retries once with normal payload when cached generate returns 404 or 400 and evicts stale entry', () async {
      final sys = _largeSystemPrompt(1150);

      for (final status in const <int>[404, 400]) {
        var postCount = 0;
        var genCount = 0;
        final client = _MockHttpClient((req, body) async {
          if (req.url.path.endsWith('/v1beta/cachedContents')) {
            postCount++;
            return _jsonResponse(<String, dynamic>{
              'name': 'cachedContents/stale_$postCount',
            });
          }
          genCount++;
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          if (decoded.containsKey('cachedContent') && genCount == 1) {
            return _jsonResponse(
              <String, dynamic>{'error': 'cachedContent expired'},
              statusCode: status,
            );
          }
          return _okGenerateSse(text: 'recovered-$status');
        });

        final driver = GeminiDriver(apiKey: 'AIza-retry-$status', httpClient: client);
        final done = await _collectDone(driver.chatStream(_buildRequest(systemText: sys)));
        expect(done.content, equals('recovered-$status'));
        expect(postCount, equals(1));
        expect(genCount, equals(2));

        final firstGen = client.requests[1];
        expect(firstGen.jsonBody['cachedContent'], equals('cachedContents/stale_1'));
        expect(firstGen.jsonBody.containsKey('systemInstruction'), isFalse);

        final retryGen = client.requests[2];
        expect(retryGen.jsonBody.containsKey('cachedContent'), isFalse);
        expect(retryGen.jsonBody.containsKey('systemInstruction'), isTrue);
        expect(retryGen.jsonBody.containsKey('tools'), isTrue);

        // Next request should recreate cache because stale entry was evicted
        await _collectDone(driver.chatStream(_buildRequest(systemText: sys)));
        expect(postCount, equals(2));
      }
    });

    test('8. coalesces concurrent cachedContents creation for identical cacheKey into a single POST', () async {
      final createGate = Completer<void>();
      var postCount = 0;

      final client = _MockHttpClient((req, body) async {
        if (req.url.path.endsWith('/v1beta/cachedContents')) {
          postCount++;
          await createGate.future;
          return _jsonResponse(<String, dynamic>{
            'name': 'cachedContents/shared_001',
          });
        }
        return _okGenerateSse(text: 'concurrent-ok');
      });

      final driver = GeminiDriver(apiKey: 'AIza-conc-key', httpClient: client);
      final sys = _largeSystemPrompt(1150);

      final f1 = _collectDone(
        driver.chatStream(_buildRequest(systemText: sys, userText: 'Req 1')),
      );
      final f2 = _collectDone(
        driver.chatStream(_buildRequest(systemText: sys, userText: 'Req 2')),
      );

      // Allow both calls to reach _inFlightCreates before completing POST
      await Future<void>.delayed(const Duration(milliseconds: 20));
      createGate.complete();

      final results = await Future.wait<LlmChatResponse>(<Future<LlmChatResponse>>[f1, f2]);
      expect(results[0].content, equals('concurrent-ok'));
      expect(results[1].content, equals('concurrent-ok'));
      expect(postCount, equals(1));

      final genReqs = client.requests
          .where((r) => r.uri.path.contains(':streamGenerateContent'))
          .toList();
      expect(genReqs, hasLength(2));
      for (final gen in genReqs) {
        expect(gen.jsonBody['cachedContent'], equals('cachedContents/shared_001'));
      }
    });

    test('9. dispose() cleans up cachedContents, enforces x-goog-api-key without ?key=, redacts secrets, and preserves thoughtSignature/functionResponse/cachedContentTokenCount', () async {
      const secretKey = 'AIza-super-secret-gemini-999';
      var now = DateTime.utc(2026, 11, 28, 12, 0, 0);
      final redactor = SecretRedactor();

      final client = _MockHttpClient((req, body) async {
        if (req.method == 'POST' && req.url.path.endsWith('/v1beta/cachedContents')) {
          return _jsonResponse(<String, dynamic>{
            'name': 'cachedContents/sec_001',
            'expireTime': now.add(const Duration(seconds: 300)).toIso8601String(),
          });
        }
        if (req.method == 'PATCH') {
          return _jsonResponse(<String, dynamic>{
            'name': 'cachedContents/sec_001',
            'expireTime': now.add(const Duration(seconds: 300)).toIso8601String(),
          });
        }
        if (req.method == 'DELETE') {
          return _jsonResponse(<String, dynamic>{});
        }
        return _okGenerateSse(
          cachedTokens: 1088,
          customParts: <Map<String, dynamic>>[
            <String, dynamic>{'thought': true, 'text': 'Checking file...'},
            <String, dynamic>{
              'functionCall': <String, dynamic>{
                'name': 'fs_read',
                'args': <String, dynamic>{'path': 'pubspec.yaml'},
              },
              'thoughtSignature': 'sig_cached_777',
            },
          ],
        );
      });

      // Intentionally pass baseUrl with /v1beta and ?key=leaked to verify stripping
      final driver = GeminiDriver(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta?key=leaked_param',
        apiKey: secretKey,
        redactor: redactor,
        httpClient: client,
        clock: () => now,
      );

      final sys = _largeSystemPrompt(1150);

      // Step 1: POST create + generate with thoughtSignature & functionCall
      final step1 = await _collectDone(
        driver.chatStream(_buildRequest(systemText: sys, userText: 'Inspect')),
      );
      expect(step1.usage.cachedTokens, equals(1088));
      expect(step1.toolCalls.single.name, equals('fs_read'));
      expect(step1.rawReasoningDetails, isNotNull);

      // Step 2 (within renew window): PATCH + generate echoing thoughtSignature & coalesced functionResponse
      now = now.add(const Duration(seconds: 260));
      await _collectDone(
        driver.chatStream(
          _buildRequest(
            systemText: sys,
            userText: 'Inspect',
            extraMessages: <ProjectedMessage>[
              ProjectedMessage(
                role: ProjectedRole.assistant,
                content: '',
                toolCalls: step1.toolCalls
                    .map(
                      (tc) => ProjectedToolCall(
                        id: tc.id,
                        name: tc.name,
                        arguments: tc.arguments,
                      ),
                    )
                    .toList(growable: false),
                rawReasoningDetails: step1.rawReasoningDetails,
                segmentIndex: 1,
              ),
              ProjectedMessage(
                role: ProjectedRole.tool,
                content: '{"ok":true}',
                toolName: 'fs_read',
                segmentIndex: 1,
              ),
              ProjectedMessage(
                role: ProjectedRole.tool,
                content: 'plain text result',
                toolName: 'fs_read',
                segmentIndex: 1,
              ),
            ],
          ),
        ),
      );

      // Step 3: dispose() triggers DELETE /v1beta/cachedContents/sec_001
      await driver.dispose();

      final methods = client.requests.map((r) => r.method).toList();
      expect(methods, containsAll(<String>['POST', 'PATCH', 'DELETE']));

      // Verify every single HTTP request uses x-goog-api-key and NEVER ?key=
      for (final req in client.requests) {
        expect(req.uri.queryParameters.containsKey('key'), isFalse);
        expect(req.uri.toString(), isNot(contains('key=')));
        expect(req.headers['x-goog-api-key'], equals(secretKey));
      }

      final deleteReq = client.requests.singleWhere((r) => r.method == 'DELETE');
      expect(deleteReq.uri.path, equals('/v1beta/cachedContents/sec_001'));

      // Verify thoughtSignature echo-back and coalesced functionResponse in Step 2 generate body
      final gen2 = client.requests
          .where((r) => r.uri.path.contains(':streamGenerateContent'))
          .last;
      expect(gen2.jsonBody['cachedContent'], equals('cachedContents/sec_001'));
      final contents = gen2.jsonBody['contents'] as List<dynamic>;
      final modelTurn = contents[1] as Map<String, dynamic>;
      final modelParts = modelTurn['parts'] as List<dynamic>;
      expect(
        (modelParts[1] as Map<String, dynamic>)['thoughtSignature'],
        equals('sig_cached_777'),
      );
      final toolTurn = contents[2] as Map<String, dynamic>;
      expect(toolTurn['role'], equals('user'));
      expect((toolTurn['parts'] as List<dynamic>), hasLength(2));

      // Verify SecretRedactor masks raw API key on error response
      final errClient = _MockHttpClient((req, body) async {
        return _jsonResponse(
          <String, dynamic>{'error': 'Invalid API key $secretKey'},
          statusCode: 403,
        );
      });
      final errDriver = GeminiDriver(
        apiKey: secretKey,
        redactor: redactor,
        httpClient: errClient,
        enableExplicitCaching: false,
      );
      await expectLater(
        errDriver.chatStream(_buildRequest(systemText: 'hi')).toList(),
        throwsA(
          isA<LlmDriverException>()
              .having((e) => e.error.reason, 'reason', 'AUTH_FAILED')
              .having((e) => e.error.message, 'message', isNot(contains(secretKey))),
        ),
      );
    });
  });
}
