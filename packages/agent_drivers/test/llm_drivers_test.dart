import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/llm_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('OllamaDriver URL normalization [D-008], OM-07', () {
    test('normalizes 0.0.0.0, [::], trailing slashes, and /v1 suffixes to /api/chat', () {
      expect(
        OllamaDriver.normalizeChatEndpoint('http://192.168.0.5:11434/v1')
            .toString(),
        equals('http://192.168.0.5:11434/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('http://192.168.0.5:11434/v1/')
            .toString(),
        equals('http://192.168.0.5:11434/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('http://localhost:11434/').toString(),
        equals('http://localhost:11434/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('0.0.0.0').toString(),
        equals('http://127.0.0.1:11434/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('0.0.0.0:11434').toString(),
        equals('http://127.0.0.1:11434/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('http://0.0.0.0:11434/v1').toString(),
        equals('http://127.0.0.1:11434/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('[::]').toString(),
        equals('http://127.0.0.1:11434/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('http://[::]:11434/v1/').toString(),
        equals('http://127.0.0.1:11434/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('https://ollama.com').toString(),
        equals('https://ollama.com/api/chat'),
      );
      expect(
        OllamaDriver.normalizeChatEndpoint('https://ollama.com/v1/').toString(),
        equals('https://ollama.com/api/chat'),
      );
    });
  });

  group('OllamaDriver local-ollama & ollama-cloud [D-008]', () {
    late HttpServer server;
    late String baseUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://${server.address.address}:${server.port}/v1';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('streams NDJSON thoughts, text, object-typed tool_calls, and prompt_eval_cached_count', () async {
      Map<String, dynamic>? capturedRequest;
      String? capturedPath;

      server.listen((req) async {
        capturedPath = req.uri.path;
        capturedRequest = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');
        req.response.write(
          '${jsonEncode(<String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'thinking': 'Checking ',
                  'content': '',
                },
                'done': false,
              })}\n',
        );
        req.response.write(
          '${jsonEncode(<String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'Hello ',
                },
                'done': false,
              })}\n',
        );
        req.response.write(
          '${jsonEncode(<String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'world',
                  'tool_calls': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'call_99',
                      'function': <String, dynamic>{
                        'name': 'sys_read_lines',
                        'arguments': <String, dynamic>{
                          'path': '/workspace/a.dart',
                          'startLine': 1,
                        },
                      },
                    },
                  ],
                },
                'done': false,
              })}\n',
        );
        req.response.write(
          '${jsonEncode(<String, dynamic>{
                'done': true,
                'done_reason': 'stop',
                'prompt_eval_count': 540,
                'prompt_eval_cached_count': 535,
                'eval_count': 24,
              })}\n',
        );
        await req.response.close();
      });

      final memory = _buildMemoryWithToolHistory();
      final projected = const CanonicalIrProjector().project(
        memory,
        targetProvider: 'local-ollama',
        targetModel: 'gemma4:12b',
      );

      final driver = OllamaDriver.local(baseUrl: baseUrl, keepAlive: '15m');
      addTearDown(driver.close);

      final events = await driver
          .chatStream(
            LlmChatRequest(
              sessionId: 'sess_1',
              sessionUuid: 'uuid_1',
              model: const ModelIdentifier(
                provider: LlmProviderId.localOllama,
                modelName: 'gemma4:12b',
              ),
              prompt: projected,
            ),
          )
          .toList();

      expect(capturedPath, equals('/api/chat'));
      expect(capturedRequest!['keep_alive'], equals('15m'));
      expect(capturedRequest!['stream'], isTrue);

      final wireMessages =
          (capturedRequest!['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      final assistantMsg =
          wireMessages.firstWhere((m) => m['role'] == 'assistant');
      final assistantTc = (assistantMsg['tool_calls'] as List<dynamic>).first
          as Map<String, dynamic>;
      // Native /api/chat requires arguments to be a JSON object, not a string.
      expect(assistantTc['function']['arguments'], isA<Map<String, dynamic>>());
      expect(
        assistantTc['id'],
        matches(RegExp(r'^[a-zA-Z0-9]{9}$')),
      );

      final toolMsg = wireMessages.firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['tool_name'], equals('sys_glob'));
      expect(toolMsg['tool_call_id'], equals(assistantTc['id']));

      expect(events.whereType<LlmThoughtDelta>().single.text, equals('Checking '));
      expect(
        events.whereType<LlmTextDelta>().map((e) => e.text).join(),
        equals('Hello world'),
      );
      final tcEvent = events.whereType<LlmToolCallEvent>().single;
      expect(tcEvent.toolCall.name, equals('sys_read_lines'));
      expect(tcEvent.toolCall.arguments['path'], equals('/workspace/a.dart'));

      final done = events.whereType<LlmDoneEvent>().single.response;
      expect(done.usage.promptTokens, equals(540));
      expect(done.usage.cachedTokens, equals(535));
      expect(done.usage.completionTokens, equals(24));
      expect(done.usage.cacheHitRate, equals(0.9907));
    });

    test('ollama-cloud rejects missing OLLAMA_API_KEY with EPROVIDER before HTTP call and sends Bearer when set', () async {
      var hitCount = 0;
      String? seenAuthHeader;
      server.listen((req) async {
        hitCount += 1;
        seenAuthHeader = req.headers.value(HttpHeaders.authorizationHeader);
        req.response.statusCode = 200;
        req.response.write(
          '${jsonEncode(<String, dynamic>{
                'message': <String, dynamic>{'role': 'assistant', 'content': 'cloud ok'},
                'done': true,
                'prompt_eval_count': 10,
                'eval_count': 2,
              })}\n',
        );
        await req.response.close();
      });

      final emptyEnv = LlmEnvLoader(
        processEnvironment: const <String, String>{},
        currentDirectoryPath: Directory.systemTemp.path,
      );
      final missingDriver = OllamaDriver.cloud(
        baseUrl: baseUrl,
        envLoader: emptyEnv,
      );
      addTearDown(missingDriver.close);

      await expectLater(
        missingDriver
            .chatStream(
              LlmChatRequest(
                sessionId: 's',
                sessionUuid: 'u',
                model: const ModelIdentifier(
                  provider: LlmProviderId.ollamaCloud,
                  modelName: 'gpt-oss:120b',
                ),
                prompt: _simplePrompt(),
              ),
            )
            .toList(),
        throwsA(
          isA<LlmDriverException>()
              .having((e) => e.error.code, 'code', SyscallErrorCode.eprovider)
              .having((e) => e.error.reason, 'reason', 'MISSING_API_KEY'),
        ),
      );
      expect(hitCount, equals(0));

      final validDriver = OllamaDriver.cloud(
        baseUrl: baseUrl,
        apiKey: 'ollama_secret_token_xyz',
      );
      addTearDown(validDriver.close);

      final events = await validDriver
          .chatStream(
            LlmChatRequest(
              sessionId: 's',
              sessionUuid: 'u',
              model: const ModelIdentifier(
                provider: LlmProviderId.ollamaCloud,
                modelName: 'gpt-oss:120b',
              ),
              prompt: _simplePrompt(),
            ),
          )
          .toList();
      expect(hitCount, equals(1));
      expect(seenAuthHeader, equals('Bearer ollama_secret_token_xyz'));
      final done = events.whereType<LlmDoneEvent>().single.response;
      expect(done.content, equals('cloud ok'));
      // When prompt_eval_cached_count is omitted by cloud, cachedTokens remains null.
      expect(done.usage.cachedTokens, isNull);
    });
  });

  group('OpenRouterDriver [D-009]', () {
    late HttpServer server;
    late String baseUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://${server.address.address}:${server.port}/api/v1';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('injects Sticky Routing headers/body and cache_control strictly for anthropic/ models, and joins split SSE tool_calls', () async {
      final capturedHeaders = <String, String?>{};
      final capturedBodies = <Map<String, dynamic>>[];

      server.listen((req) async {
        capturedHeaders['authorization'] =
            req.headers.value(HttpHeaders.authorizationHeader);
        capturedHeaders['x-session-id'] = req.headers.value('x-session-id');
        final body = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;
        capturedBodies.add(body);

        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write(': OPENROUTER PROCESSING\n\n');
        req.response.write(
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{
                      'reasoning': 'Thinking...',
                      'reasoning_details': <Map<String, dynamic>>[
                        <String, dynamic>{'type': 'thinking', 'sig': 'abc'},
                      ],
                    },
                  },
                ],
              })}\n\n',
        );
        req.response.write(
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{
                      'tool_calls': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'index': 0,
                          'id': 'toolu_01abc',
                          'function': <String, dynamic>{
                            'name': 'sys_grep',
                            'arguments': '{"pat',
                          },
                        },
                      ],
                    },
                  },
                ],
              })}\n\n',
        );
        req.response.write(
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'finish_reason': 'tool_calls',
                    'delta': <String, dynamic>{
                      'tool_calls': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'index': 0,
                          'function': <String, dynamic>{
                            'arguments': 'tern":"main"}',
                          },
                        },
                      ],
                    },
                  },
                ],
              })}\n\n',
        );
        req.response.write(
          'data: ${jsonEncode(<String, dynamic>{
                'choices': const <dynamic>[],
                'usage': <String, dynamic>{
                  'prompt_tokens': 2000,
                  'completion_tokens': 40,
                  'total_tokens': 2040,
                  'cost': 0.00412,
                  'cache_discount': -0.0015,
                  'prompt_tokens_details': <String, dynamic>{
                    'cached_tokens': 1500,
                    'cache_write_tokens': 250,
                  },
                },
              })}\n\n',
        );
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      final driver = OpenRouterDriver(
        baseUrl: baseUrl,
        apiKey: 'sk-or-v1-testsecret9999',
      );
      addTearDown(driver.close);

      final memory = _buildMemoryWithToolHistory();
      final anthropicPrompt = const CanonicalIrProjector().project(
        memory,
        targetProvider: 'openrouter',
        targetModel: 'anthropic/claude-sonnet-4',
      );

      final events = await driver
          .chatStream(
            LlmChatRequest(
              sessionId: 'sess_or',
              sessionUuid: 'sticky-uuid-42',
              model: const ModelIdentifier(
                provider: LlmProviderId.openRouter,
                modelName: 'anthropic/claude-sonnet-4',
              ),
              prompt: anthropicPrompt,
            ),
          )
          .toList();

      expect(capturedHeaders['x-session-id'], equals('sticky-uuid-42'));
      expect(
        capturedHeaders['authorization'],
        equals('Bearer sk-or-v1-testsecret9999'),
      );

      final claudeBody = capturedBodies.first;
      expect(claudeBody['session_id'], equals('sticky-uuid-42'));
      expect(
        claudeBody['cache_control'],
        equals(<String, dynamic>{'type': 'ephemeral'}),
      );
      final claudeMsgs =
          (claudeBody['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      // Top-level cache_control keeps all message contents as plain Strings.
      for (final m in claudeMsgs) {
        expect(m['content'], isA<String>());
      }

      // Non-anthropic model must NOT inject cache_control.
      final openaiPrompt = const CanonicalIrProjector().project(
        memory,
        targetProvider: 'openrouter',
        targetModel: 'openai/gpt-4o',
      );
      final openaiBody = driver.buildRequestBody(
        LlmChatRequest(
          sessionId: 'sess_or',
          sessionUuid: 'sticky-uuid-42',
          model: const ModelIdentifier(
            provider: LlmProviderId.openRouter,
            modelName: 'openai/gpt-4o',
          ),
          prompt: openaiPrompt,
        ),
      );
      expect(openaiBody.containsKey('cache_control'), isFalse);
      for (final m in openaiBody['messages'] as List<dynamic>) {
        expect((m as Map<String, dynamic>)['content'], isA<String>());
      }

      // Verify joined tool call and usage extraction.
      final tc = events.whereType<LlmToolCallEvent>().single.toolCall;
      expect(tc.id, equals('toolu_01abc'));
      expect(tc.name, equals('sys_grep'));
      expect(tc.arguments, equals(<String, dynamic>{'pattern': 'main'}));

      final done = events.whereType<LlmDoneEvent>().single.response;
      expect(done.usage.promptTokens, equals(2000));
      expect(done.usage.completionTokens, equals(40));
      expect(done.usage.cachedTokens, equals(1500));
      expect(done.usage.cacheWriteTokens, equals(250));
      expect(done.usage.costMicroUsd, equals(4120));
      expect(done.usage.cacheDiscountUsd, equals(-0.0015));
      expect(done.rawReasoningDetails, isNotNull);
    });

    test('returns EPROVIDER MISSING_API_KEY when OPENROUTER_API_KEY is unset and masks secrets on HTTP errors/timeout', () async {
      final redactor = SecretRedactor();
      final emptyEnv = LlmEnvLoader(
        processEnvironment: const <String, String>{},
        currentDirectoryPath: Directory.systemTemp.path,
        redactor: redactor,
      );
      final missingKeyDriver = OpenRouterDriver(
        baseUrl: baseUrl,
        envLoader: emptyEnv,
        redactor: redactor,
      );
      addTearDown(missingKeyDriver.close);

      await expectLater(
        missingKeyDriver
            .chatStream(
              LlmChatRequest(
                sessionId: 's',
                sessionUuid: 'u',
                model: const ModelIdentifier(
                  provider: LlmProviderId.openRouter,
                  modelName: 'openai/gpt-4o',
                ),
                prompt: _simplePrompt(),
              ),
            )
            .toList(),
        throwsA(
          isA<LlmDriverException>()
              .having((e) => e.error.code, 'code', SyscallErrorCode.eprovider)
              .having((e) => e.error.reason, 'reason', 'MISSING_API_KEY'),
        ),
      );

      // HTTP 401 reflecting leaked key in body -> masked to <REDACTED>.
      const secret = 'sk-or-v1-supersecret-leak-check';
      server.listen((req) async {
        final mode = req.headers.value('x-test-mode');
        if (mode == 'timeout') {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return;
        }
        req.response.statusCode = 401;
        req.response.write('Invalid key: Bearer $secret ($secret)');
        await req.response.close();
      });

      final errDriver = OpenRouterDriver(
        baseUrl: baseUrl,
        apiKey: secret,
        redactor: redactor,
        requestTimeout: const Duration(milliseconds: 80),
      );
      addTearDown(errDriver.close);

      try {
        await errDriver
            .chatStream(
              LlmChatRequest(
                sessionId: 's',
                sessionUuid: 'u',
                model: const ModelIdentifier(
                  provider: LlmProviderId.openRouter,
                  modelName: 'openai/gpt-4o',
                ),
                prompt: _simplePrompt(),
              ),
            )
            .toList();
        fail('Expected LlmDriverException for HTTP 401');
      } on LlmDriverException catch (e) {
        expect(e.error.code, equals(SyscallErrorCode.eprovider));
        expect(e.error.reason, equals('UNAUTHORIZED'));
        expect(e.error.message, isNot(contains(secret)));
        expect(e.error.message, contains(SecretRedactor.redactedToken));
      }
    });

    test('returns ETIMEDOUT when server exceeds requestTimeout', () async {
      server.listen((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        try {
          await req.response.close();
        } catch (_) {}
      });

      final driver = OpenRouterDriver(
        baseUrl: baseUrl,
        apiKey: 'sk-or-v1-timeout-test-key',
        requestTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(driver.close);

      await expectLater(
        driver
            .chatStream(
              LlmChatRequest(
                sessionId: 's',
                sessionUuid: 'u',
                model: const ModelIdentifier(
                  provider: LlmProviderId.openRouter,
                  modelName: 'openai/gpt-4o',
                ),
                prompt: _simplePrompt(),
              ),
            )
            .toList(),
        throwsA(
          isA<LlmDriverException>()
              .having((e) => e.error.code, 'code', SyscallErrorCode.etimedout),
        ),
      );
    });

    test('applies GatewayExplicitCachePolicy top-level cache_control and sessionUuid boundaries [D-602]', () {
      // Policy whitelist boundary checks
      const expectedTrue = <String>[
        'anthropic/claude-haiku-4.5',
        'anthropic/claude-sonnet-4',
        'qwen/qwen3-coder-flash',
        'qwen/qwen3-coder-flash:free',
        'qwen/qwen3.7-plus',
        'qwen/qwen3.5-plus',
        'qwen/qwen3-max',
        'qwen/qwen-plus',
        'qwen/qwen-turbo',
      ];
      for (final model in expectedTrue) {
        expect(
          GatewayExplicitCachePolicy.supportsTopLevelCacheControl(model),
          isTrue,
          reason: 'Expected top-level cache_control for $model',
        );
      }

      const expectedFalse = <String>[
        'qwen/qwen3-coder',
        'openai/gpt-4o-mini',
        'openai/gpt-5-mini',
        'deepseek/deepseek-v3.2',
        'google/gemini-2.5-flash',
        'google/gemini-2.5-pro',
        'z-ai/glm-4.7-flash',
        'moonshotai/kimi-k2.5',
        '',
        '   ',
      ];
      for (final model in expectedFalse) {
        expect(
          GatewayExplicitCachePolicy.supportsTopLevelCacheControl(model),
          isFalse,
          reason: 'Expected NO cache_control for $model',
        );
      }

      final driver = OpenRouterDriver(
        baseUrl: baseUrl,
        apiKey: 'sk-or-v1-policy-test',
      );
      addTearDown(driver.close);

      final memory = _buildMemoryWithToolHistory();

      // Explicit cache models get top-level cache_control and plain String content.
      for (final modelName in const <String>[
        'anthropic/claude-haiku-4.5',
        'qwen/qwen3-coder-flash',
        'qwen/qwen3.7-plus',
      ]) {
        final prompt = const CanonicalIrProjector().project(
          memory,
          targetProvider: 'openrouter',
          targetModel: modelName,
        );
        final req = LlmChatRequest(
          sessionId: 'sess_or',
          sessionUuid: 'sticky-uuid-100',
          model: ModelIdentifier(
            provider: LlmProviderId.openRouter,
            modelName: modelName,
          ),
          prompt: prompt,
        );
        final headers = driver.buildHeaders(req, apiKey: 'sk-or-v1-policy-test');
        final body = driver.buildRequestBody(req);
        expect(headers['x-session-id'], equals('sticky-uuid-100'));
        expect(body['session_id'], equals('sticky-uuid-100'));
        expect(
          body['cache_control'],
          equals(<String, dynamic>{'type': 'ephemeral'}),
        );
        for (final msg in body['messages'] as List<dynamic>) {
          expect((msg as Map<String, dynamic>)['content'], isA<String>());
        }
      }

      // Implicit / unsupported models do NOT get cache_control.
      for (final modelName in const <String>[
        'openai/gpt-4o-mini',
        'deepseek/deepseek-v3.2',
        'qwen/qwen3-coder',
        'google/gemini-2.5-flash',
        'z-ai/glm-4.7-flash',
      ]) {
        final req = LlmChatRequest(
          sessionId: 'sess_or',
          sessionUuid: 'sticky-uuid-100',
          model: ModelIdentifier(
            provider: LlmProviderId.openRouter,
            modelName: modelName,
          ),
          prompt: _simplePrompt(),
        );
        final body = driver.buildRequestBody(req);
        expect(body.containsKey('cache_control'), isFalse);
      }

      // Empty or whitespace-only sessionUuid omits x-session-id and session_id.
      for (final blankUuid in const <String>['', '   ']) {
        final req = LlmChatRequest(
          sessionId: 'sess_or',
          sessionUuid: blankUuid,
          model: const ModelIdentifier(
            provider: LlmProviderId.openRouter,
            modelName: 'anthropic/claude-haiku-4.5',
          ),
          prompt: _simplePrompt(),
        );
        final headers = driver.buildHeaders(req, apiKey: 'sk-or-v1-policy-test');
        final body = driver.buildRequestBody(req);
        expect(headers.containsKey('x-session-id'), isFalse);
        expect(body.containsKey('session_id'), isFalse);
        expect(
          body['cache_control'],
          equals(<String, dynamic>{'type': 'ephemeral'}),
        );
      }
    });
  });

  group('LlmEnvLoader & LlmRouter + sys_llm_chat audit integration [D-004], [D-010]', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('fm_wp4_env_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('resolves process env -> sessionCwd/.agent_os/.env -> Directory.current/.agent_os/.env and registers secrets', () {
      final sessionDir = Directory(p.join(tempRoot.path, 'session_ws'))
        ..createSync(recursive: true);
      final currentDir = Directory(p.join(tempRoot.path, 'current_ws'))
        ..createSync(recursive: true);

      Directory(p.join(sessionDir.path, '.agent_os')).createSync();
      Directory(p.join(currentDir.path, '.agent_os')).createSync();

      File(p.join(currentDir.path, '.agent_os', '.env')).writeAsStringSync('''
# fallback env
OPENROUTER_API_KEY="sk-or-v1-from-cwd-env"
OLLAMA_API_KEY=ollama-from-cwd-env
''');
      File(p.join(sessionDir.path, '.agent_os', '.env')).writeAsStringSync('''
export OPENROUTER_API_KEY='sk-or-v1-from-session-env'
''');

      final redactor = SecretRedactor();
      final loader = LlmEnvLoader(
        processEnvironment: const <String, String>{
          'OLLAMA_HOST': 'http://192.168.0.5:11434/v1',
          'CUSTOM_TOKEN': 'tok_process_override',
        },
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
        redactor: redactor,
      );

      expect(loader.get('OLLAMA_HOST'), equals('http://192.168.0.5:11434/v1'));
      // sessionCwd/.agent_os/.env overrides Directory.current/.agent_os/.env
      expect(
        loader.get('OPENROUTER_API_KEY'),
        equals('sk-or-v1-from-session-env'),
      );
      // Falls back to Directory.current/.agent_os/.env when absent in higher layers.
      expect(loader.get('OLLAMA_API_KEY'), equals('ollama-from-cwd-env'));
      expect(loader.isConfigured('OPENROUTER_API_KEY'), isTrue);
      expect(loader.toString(), isNot(contains('sk-or-v1')));

      // Registered secrets must be masked everywhere by SecretRedactor.
      expect(
        redactor.redactString('leaked ollama-from-cwd-env and tok_process_override'),
        equals('leaked <REDACTED> and <REDACTED>'),
      );
    });

    test('sys_llm_chat routes to mock Ollama server, forwards stream events, updates quota, and writes llm_io.jsonl', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.write(
          '${jsonEncode(<String, dynamic>{
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'Routed response',
                },
                'done': true,
                'prompt_eval_count': 120,
                'prompt_eval_cached_count': 80,
                'eval_count': 15,
              })}\n',
        );
        await req.response.close();
      });

      final redactor = SecretRedactor();
      final router = LlmRouter.withDefaults(
        localOllamaBaseUrl:
            'http://${server.address.address}:${server.port}/v1',
        redactor: redactor,
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{},
          sessionCwd: tempRoot.path,
          redactor: redactor,
        ),
      );
      final auditLogger = AuditLogger(
        workspaceHostRoot: tempRoot.path,
        sessionId: 'sess_router',
        redactor: redactor,
      );
      final processTable = KernelProcessTable();
      final pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: ResourceQuota.stage1Default,
        namespace: VfsNamespace(workspaceHostRoot: tempRoot.path),
        memory: VirtualContextMemory(
          sessionId: 'sess_router',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      )..memory.ephemeralSegment.currentUserInput = 'hi';
      processTable.registerProcess(pcb);

      final observed = <LlmStreamEvent>[];
      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(
          workspaceHostRoot: tempRoot.path,
          config: const IoCapConfig(),
        ),
        auditLogger: auditLogger,
        redactor: redactor,
      );
      gate.registerSyscall(
        buildLlmChatSyscallDefinition(
          router: router,
          auditLogger: auditLogger,
          onStreamEvent: (_, _, event) => observed.add(event),
        ),
      );

      final res = await gate.invoke(
        const SyscallContext(
          pid: 1,
          capHandle: CapHandle('cap_workspace_rw'),
          sessionId: 'sess_router',
        ),
        SyscallRequest(
          name: 'sys_llm_chat',
          args: const <String, dynamic>{
            'model': 'local-ollama/gemma4:12b',
            'turnIndex': 1,
          },
        ),
      );

      expect(res.ok, isTrue);
      expect(res.value!['content'], equals('Routed response'));
      expect(pcb.quotaUsage.totalTokensUsed, equals(135));
      expect(observed.whereType<LlmTextDelta>().single.text, equals('Routed response'));

      await auditLogger.flush();
      final llmIoLines =
          File(auditLogger.llmIoLogPath).readAsLinesSync();
      expect(llmIoLines, hasLength(1));
      final record = jsonDecode(llmIoLines.single) as Map<String, dynamic>;
      expect(record['provider'], equals('local-ollama'));
      expect(record['model'], equals('gemma4:12b'));
      expect(record['cachedTokens'], equals(80));
      expect(record['ok'], isTrue);
    });
  });
}

VirtualContextMemory _buildMemoryWithToolHistory() {
  final memory = VirtualContextMemory(
    sessionId: 'sess_1',
    systemInstruction: PinnedSystemInstruction(
      instruction: 'Pinned System Prompt',
      tools: <SyscallToolSchema>[
        SyscallToolSchema(
          name: 'sys_glob',
          description: 'Glob',
          parametersJsonSchema: const <String, dynamic>{'type': 'object'},
        ),
      ],
    ),
  );
  memory.appendUserTurn('Find dart files');
  memory.appendAssistantTurn(
    CanonicalAssistantTurn(
      originProvider: 'openrouter',
      originModel: 'anthropic/claude-sonnet-4',
      content: '',
      toolCalls: <CanonicalToolCall>[
        CanonicalToolCall(
          canonicalCallId: 'sc_0001',
          name: 'sys_glob',
          arguments: const <String, dynamic>{'pattern': '**/*.dart'},
        ),
      ],
    ),
  );
  memory.appendToolResultTurn(
    const CanonicalToolResultTurn(
      canonicalCallId: 'sc_0001',
      toolName: 'sys_glob',
      content: '{"matches":["lib/a.dart"]}',
    ),
  );
  memory.ephemeralSegment.currentUserInput = 'Now inspect a.dart';
  return memory;
}

ProjectedPrompt _simplePrompt() {
  final memory = VirtualContextMemory(
    sessionId: 's',
    systemInstruction: PinnedSystemInstruction(
      instruction: 'System',
      tools: const <SyscallToolSchema>[],
    ),
  )..ephemeralSegment.currentUserInput = 'Hello';
  return const CanonicalIrProjector().project(
    memory,
    targetProvider: 'openrouter',
    targetModel: 'openai/gpt-4o',
  );
}
