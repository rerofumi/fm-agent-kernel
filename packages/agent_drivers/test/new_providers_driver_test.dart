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

ProjectedPrompt _simplePrompt({
  List<SyscallToolSchema> tools = const <SyscallToolSchema>[],
  List<ProjectedMessage>? extraMessages,
}) {
  return ProjectedPrompt(
    messages: <ProjectedMessage>[
      ProjectedMessage(
        role: ProjectedRole.system,
        content: 'You are a helpful kernel assistant.',
        segmentIndex: 0,
      ),
      ProjectedMessage(
        role: ProjectedRole.user,
        content: 'Hello',
        segmentIndex: 2,
      ),
      ...?extraMessages,
    ],
    tools: tools,
  );
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

void main() {
  group('OpenAiDriver [D-402], [D-403]', () {
    test('sends stream_options.include_usage and keeps max_tokens/temperature for non-reasoning model', () async {
      final client = _MockHttpClient((req, body) async {
        return _sseResponse(<String>[
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{'content': 'Hi '},
                  },
                ],
              })}',
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{'content': 'there!'},
                    'finish_reason': 'stop',
                  },
                ],
              })}',
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[],
                'usage': <String, dynamic>{
                  'prompt_tokens': 20,
                  'completion_tokens': 5,
                  'total_tokens': 25,
                  'prompt_tokens_details': <String, dynamic>{'cached_tokens': 12},
                },
              })}',
          'data: [DONE]',
        ]);
      });

      final driver = OpenAiDriver(
        apiKey: 'sk-openai-secret-123',
        httpClient: client,
      );
      final req = LlmChatRequest(
        sessionId: 's1',
        sessionUuid: 'u1',
        model: const ModelIdentifier(
          provider: LlmProviderId.openai,
          modelName: 'gpt-4o',
        ),
        prompt: _simplePrompt(),
        temperature: 0.3,
        maxTokens: 256,
        stream: true,
      );

      final done = await _collectDone(driver.chatStream(req));
      expect(done.content, equals('Hi there!'));
      expect(done.usage.promptTokens, equals(20));
      expect(done.usage.completionTokens, equals(5));
      expect(done.usage.cachedTokens, equals(12));

      final sent = client.requests.single;
      expect(sent.uri.toString(), equals('https://api.openai.com/v1/chat/completions'));
      expect(sent.headers['Authorization'], equals('Bearer sk-openai-secret-123'));
      expect(
        sent.jsonBody['stream_options'],
        equals(<String, dynamic>{'include_usage': true}),
      );
      expect(sent.jsonBody['max_tokens'], equals(256));
      expect(sent.jsonBody.containsKey('max_completion_tokens'), isFalse);
      expect(sent.jsonBody['temperature'], equals(0.3));
    });

    test('converts max_tokens to max_completion_tokens and omits temperature for reasoning models', () async {
      final client = _MockHttpClient((req, body) async {
        return _sseResponse(<String>[
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{
                      'tool_calls': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'index': 0,
                          'id': 'call_abc',
                          'function': <String, dynamic>{
                            'name': 'fs_read',
                            'arguments': '{"path":"README.md"}',
                          },
                        },
                      ],
                    },
                    'finish_reason': 'tool_calls',
                  },
                ],
              })}',
          'data: [DONE]',
        ]);
      });

      final driver = OpenAiDriver(apiKey: 'sk-test', httpClient: client);
      for (final modelName in const <String>['o3-mini', 'gpt-5', 'o1-preview', 'o4-mini']) {
        final req = LlmChatRequest(
          sessionId: 's1',
          sessionUuid: 'u1',
          model: ModelIdentifier(
            provider: LlmProviderId.openai,
            modelName: modelName,
          ),
          prompt: _simplePrompt(),
          temperature: 0.7,
          maxTokens: 1024,
          stream: true,
        );
        final done = await _collectDone(driver.chatStream(req));
        expect(done.toolCalls.single.name, equals('fs_read'));
        expect(done.toolCalls.single.arguments, equals(<String, dynamic>{'path': 'README.md'}));
      }

      expect(client.requests, hasLength(4));
      for (final sent in client.requests) {
        expect(sent.jsonBody.containsKey('max_tokens'), isFalse);
        expect(sent.jsonBody['max_completion_tokens'], equals(1024));
        expect(sent.jsonBody.containsKey('temperature'), isFalse);
      }
    });

    test('maps HTTP errors to EPROVIDER and redacts API key', () async {
      const secret = 'sk-openai-very-secret-999';
      final redactor = SecretRedactor();
      final client = _MockHttpClient((req, body) async {
        return _jsonResponse(
          <String, dynamic>{'error': 'Invalid key $secret'},
          statusCode: 401,
        );
      });

      final driver = OpenAiDriver(
        apiKey: secret,
        redactor: redactor,
        httpClient: client,
      );
      final req = LlmChatRequest(
        sessionId: 's1',
        sessionUuid: 'u1',
        model: const ModelIdentifier(
          provider: LlmProviderId.openai,
          modelName: 'gpt-4o',
        ),
        prompt: _simplePrompt(),
      );

      await expectLater(
        driver.chatStream(req).toList(),
        throwsA(
          isA<LlmDriverException>()
              .having((e) => e.error.code, 'code', SyscallErrorCode.eprovider)
              .having((e) => e.error.reason, 'reason', 'AUTH_FAILED')
              .having((e) => e.error.message, 'message', isNot(contains(secret))),
        ),
      );
    });
  });

  group('GeminiDriver [D-402], [D-404]', () {
    test('uses x-goog-api-key header without ?key=, strips unsupported schema keys, coalesces tool turns, and extracts cachedContentTokenCount', () async {
      final client = _MockHttpClient((req, body) async {
        return _sseResponse(<String>[
          'data: ${jsonEncode(<String, dynamic>{
                'candidates': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'content': <String, dynamic>{
                      'role': 'model',
                      'parts': <Map<String, dynamic>>[
                        <String, dynamic>{'thought': true, 'text': 'Planning...'},
                        <String, dynamic>{
                          'functionCall': <String, dynamic>{
                            'name': 'fs_read',
                            'args': <String, dynamic>{'path': 'pubspec.yaml'},
                          },
                          'thoughtSignature': 'sig_xyz_123',
                        },
                      ],
                    },
                    'finishReason': 'STOP',
                  },
                ],
                'usageMetadata': <String, dynamic>{
                  'promptTokenCount': 100,
                  'candidatesTokenCount': 15,
                  'totalTokenCount': 115,
                  'cachedContentTokenCount': 64,
                },
              })}',
        ]);
      });

      final envDir = Directory.systemTemp.createTempSync('gemini_env_');
      addTearDown(() => envDir.deleteSync(recursive: true));
      final agentOsDir = Directory('${envDir.path}${Platform.pathSeparator}.agent_os')
        ..createSync(recursive: true);
      File('${agentOsDir.path}${Platform.pathSeparator}.env')
          .writeAsStringSync('GOOGLE_API_KEY=goog-fallback-secret-777\n');
      final envLoader = LlmEnvLoader(
        sessionCwd: envDir.path,
        currentDirectoryPath: envDir.path,
        processEnvironment: const <String, String>{},
      );

      final driver = GeminiDriver(envLoader: envLoader, httpClient: client);
      final prompt = _simplePrompt(
        tools: <SyscallToolSchema>[
          SyscallToolSchema(
            name: 'fs_read',
            description: 'Read a file',
            parametersJsonSchema: <String, dynamic>{
              r'$schema': 'http://json-schema.org/draft-07/schema#',
              'type': 'object',
              'additionalProperties': false,
              'properties': <String, dynamic>{
                'path': <String, dynamic>{'type': 'string'},
              },
              'required': <String>['path'],
            },
          ),
        ],
        extraMessages: <ProjectedMessage>[
          ProjectedMessage(
            role: ProjectedRole.assistant,
            content: '',
            segmentIndex: 2,
            toolCalls: <ProjectedToolCall>[
              ProjectedToolCall(
                id: 'c1',
                name: 'tool_a',
                arguments: const <String, dynamic>{'x': 1},
              ),
              ProjectedToolCall(
                id: 'c2',
                name: 'tool_b',
                arguments: const <String, dynamic>{'y': 2},
              ),
            ],
          ),
          ProjectedMessage(
            role: ProjectedRole.tool,
            content: '{"ok":true}',
            segmentIndex: 2,
            toolCallId: 'c1',
            toolName: 'tool_a',
          ),
          ProjectedMessage(
            role: ProjectedRole.tool,
            content: 'plain text output',
            segmentIndex: 2,
            toolCallId: 'c2',
            toolName: 'tool_b',
          ),
        ],
      );

      final req = LlmChatRequest(
        sessionId: 's_gem',
        sessionUuid: 'u_gem',
        model: const ModelIdentifier(
          provider: LlmProviderId.gemini,
          modelName: 'gemini-2.5-flash',
        ),
        prompt: prompt,
        temperature: 0.2,
        maxTokens: 512,
      );

      final events = await driver.chatStream(req).toList();
      expect(events.whereType<LlmThoughtDelta>().single.text, equals('Planning...'));
      expect(events.whereType<LlmToolCallEvent>().single.toolCall.name, equals('fs_read'));
      final done = events.whereType<LlmDoneEvent>().single.response;
      expect(done.usage.cachedTokens, equals(64));
      expect(done.rawReasoningDetails, isA<List<dynamic>>());

      final sent = client.requests.single;
      expect(
        sent.uri.toString(),
        equals(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse',
        ),
      );
      expect(sent.uri.queryParameters.containsKey('key'), isFalse);
      expect(sent.headers['x-goog-api-key'], equals('goog-fallback-secret-777'));

      // Verify $schema and additionalProperties stripped.
      final tools = sent.jsonBody['tools'] as List;
      final decl = (tools.first as Map)['functionDeclarations'].first as Map;
      final params = decl['parameters'] as Map;
      expect(params.containsKey(r'$schema'), isFalse);
      expect(params.containsKey('additionalProperties'), isFalse);

      // Verify consecutive tool messages coalesced into a single user turn.
      final contents = sent.jsonBody['contents'] as List;
      final lastTurn = contents.last as Map;
      expect(lastTurn['role'], equals('user'));
      final toolParts = lastTurn['parts'] as List;
      expect(toolParts, hasLength(2));
      expect(toolParts[0]['functionResponse']['name'], equals('tool_a'));
      expect(toolParts[0]['functionResponse']['response'], equals(<String, dynamic>{'ok': true}));
      expect(toolParts[1]['functionResponse']['name'], equals('tool_b'));
      expect(
        toolParts[1]['functionResponse']['response'],
        equals(<String, dynamic>{'result': 'plain text output'}),
      );
    });

    test('preserves thoughtSignature on same-model turns and drops it when CanonicalIrProjector switches model', () async {
      final memory = VirtualContextMemory(
        sessionId: 's1',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'System',
          tools: const <SyscallToolSchema>[],
        ),
      );
      memory.historySegment.append(const CanonicalUserTurn(text: 'Read file'));
      memory.historySegment.append(
        CanonicalAssistantTurn(
          originProvider: LlmProviderId.gemini.id,
          originModel: 'gemini-2.5-pro',
          content: '',
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'gemini_call_1',
              name: 'fs_read',
              arguments: const <String, dynamic>{'path': 'a.txt'},
            ),
          ],
          rawReasoningDetails: <Map<String, dynamic>>[
            <String, dynamic>{'thought': true, 'text': 'secret thought'},
            <String, dynamic>{
              'functionCall': <String, dynamic>{
                'name': 'fs_read',
                'args': <String, dynamic>{'path': 'a.txt'},
              },
              'thoughtSignature': 'sig_keep_or_drop',
            },
          ],
        ),
      );

      const projector = CanonicalIrProjector();
      final client = _MockHttpClient((req, body) async {
        return _sseResponse(<String>[
          'data: ${jsonEncode(<String, dynamic>{
                'candidates': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'content': <String, dynamic>{
                      'parts': <Map<String, dynamic>>[
                        <String, dynamic>{'text': 'Done'},
                      ],
                    },
                    'finishReason': 'STOP',
                  },
                ],
              })}',
        ]);
      });

      final geminiDriver = GeminiDriver(apiKey: 'gem-key', httpClient: client);

      // 1) Same model (gemini / gemini-2.5-pro) -> echoes thoughtSignature.
      final sameModelPrompt = projector.project(
        memory,
        targetProvider: LlmProviderId.gemini.id,
        targetModel: 'gemini-2.5-pro',
      );
      await _collectDone(
        geminiDriver.chatStream(
          LlmChatRequest(
            sessionId: 's1',
            sessionUuid: 'u1',
            model: const ModelIdentifier(
              provider: LlmProviderId.gemini,
              modelName: 'gemini-2.5-pro',
            ),
            prompt: sameModelPrompt,
          ),
        ),
      );
      final sameModelBody = client.requests.last.jsonBody;
      final sameModelParts =
          ((sameModelBody['contents'] as List)[1] as Map)['parts'] as List;
      expect(sameModelParts[1]['thoughtSignature'], equals('sig_keep_or_drop'));

      // 2) Different Gemini model (gemini-2.5-flash) -> CanonicalIrProjector clears rawReasoningDetails.
      final diffModelPrompt = projector.project(
        memory,
        targetProvider: LlmProviderId.gemini.id,
        targetModel: 'gemini-2.5-flash',
      );
      await _collectDone(
        geminiDriver.chatStream(
          LlmChatRequest(
            sessionId: 's1',
            sessionUuid: 'u1',
            model: const ModelIdentifier(
              provider: LlmProviderId.gemini,
              modelName: 'gemini-2.5-flash',
            ),
            prompt: diffModelPrompt,
          ),
        ),
      );
      final diffModelBody = client.requests.last.jsonBody;
      final diffModelParts =
          ((diffModelBody['contents'] as List)[1] as Map)['parts'] as List;
      expect(
        diffModelParts.any((p) => (p as Map).containsKey('thoughtSignature')),
        isFalse,
      );
      expect(diffModelParts.first['functionCall']['name'], equals('fs_read'));
    });

    test('redacts GEMINI_API_KEY on 500 provider errors', () async {
      const secret = 'AIzaSySecretKeyForTest12345';
      final client = _MockHttpClient((req, body) async {
        return _jsonResponse(
          <String, dynamic>{'error': 'Server error for $secret'},
          statusCode: 500,
        );
      });

      final driver = GeminiDriver(apiKey: secret, httpClient: client);
      final req = LlmChatRequest(
        sessionId: 's1',
        sessionUuid: 'u1',
        model: const ModelIdentifier(
          provider: LlmProviderId.gemini,
          modelName: 'gemini-2.5-flash',
        ),
        prompt: _simplePrompt(),
      );

      await expectLater(
        driver.chatStream(req).toList(),
        throwsA(
          isA<LlmDriverException>()
              .having((e) => e.error.code, 'code', SyscallErrorCode.eprovider)
              .having((e) => e.error.reason, 'reason', 'PROVIDER_ERROR')
              .having((e) => e.error.message, 'message', isNot(contains(secret))),
        ),
      );
    });
  });

  group('NousPortalDriver [D-402], [D-403]', () {
    test('completes on SSE EOF without [DONE], extracts usage.cost and reasoning_content, and echoes back on same model', () async {
      final client = _MockHttpClient((req, body) async {
        return _sseResponse(<String>[
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{
                      'reasoning_content': 'Step 1. ',
                      'reasoning_details': <Map<String, dynamic>>[
                        <String, dynamic>{'type': 'reasoning', 'text': 'Step 1. '},
                      ],
                    },
                  },
                ],
              })}',
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{'content': 'Final answer'},
                    'finish_reason': 'stop',
                  },
                ],
                'usage': <String, dynamic>{
                  'prompt_tokens': 10,
                  'completion_tokens': 5,
                  'total_tokens': 15,
                  'cost': 0.00125,
                },
              })}',
          // Intentionally omit `data: [DONE]` to verify EOF completion.
        ]);
      });

      final driver = NousPortalDriver(
        apiKey: 'nous-secret-key',
        httpClient: client,
      );
      final req = LlmChatRequest(
        sessionId: 's_nous',
        sessionUuid: 'u_nous',
        model: const ModelIdentifier(
          provider: LlmProviderId.nousPortal,
          modelName: 'Hermes-4-70B',
        ),
        prompt: _simplePrompt(),
      );

      final done = await _collectDone(driver.chatStream(req));
      expect(done.content, equals('Final answer'));
      expect(done.thoughtText, equals('Step 1. '));
      expect(done.usage.costMicroUsd, equals(1250));
      expect(done.rawReasoningDetails, isA<Map<dynamic, dynamic>>());

      final firstSent = client.requests.single;
      expect(
        firstSent.uri.toString(),
        equals('https://inference-api.nousresearch.com/v1/chat/completions'),
      );
      expect(firstSent.headers['Authorization'], equals('Bearer nous-secret-key'));

      // Verify same-model echo-back via CanonicalIrProjector.
      final memory = VirtualContextMemory(
        sessionId: 's_nous',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'System',
          tools: const <SyscallToolSchema>[],
        ),
      );
      memory.historySegment.append(
        CanonicalAssistantTurn(
          originProvider: LlmProviderId.nousPortal.id,
          originModel: 'Hermes-4-70B',
          content: done.content,
          rawReasoningDetails: done.rawReasoningDetails,
        ),
      );

      final projectedSame = const CanonicalIrProjector().project(
        memory,
        targetProvider: LlmProviderId.nousPortal.id,
        targetModel: 'Hermes-4-70B',
      );
      await _collectDone(
        driver.chatStream(
          LlmChatRequest(
            sessionId: 's_nous',
            sessionUuid: 'u_nous',
            model: const ModelIdentifier(
              provider: LlmProviderId.nousPortal,
              modelName: 'Hermes-4-70B',
            ),
            prompt: projectedSame,
          ),
        ),
      );
      final echoMsgs = client.requests.last.jsonBody['messages'] as List;
      expect(echoMsgs.last['reasoning_content'], equals('Step 1. '));
      expect(echoMsgs.last['reasoning_details'], isA<List<dynamic>>());
    });
  });

  group('LocalOpenAiCompatDriver [D-402], [D-403]', () {
    test('normalizes /v1 URLs without /v1/v1 duplication and throws EINVAL when unset', () {
      expect(
        LocalOpenAiCompatDriver.normalizeChatEndpoint('http://127.0.0.1:8080')
            .toString(),
        equals('http://127.0.0.1:8080/v1/chat/completions'),
      );
      expect(
        LocalOpenAiCompatDriver.normalizeChatEndpoint('http://127.0.0.1:8080/v1')
            .toString(),
        equals('http://127.0.0.1:8080/v1/chat/completions'),
      );
      expect(
        LocalOpenAiCompatDriver.normalizeChatEndpoint('http://127.0.0.1:8080/v1/')
            .toString(),
        equals('http://127.0.0.1:8080/v1/chat/completions'),
      );
      expect(
        LocalOpenAiCompatDriver.normalizeChatEndpoint(
          'http://127.0.0.1:8080/v1/chat/completions',
        ).toString(),
        equals('http://127.0.0.1:8080/v1/chat/completions'),
      );

      final emptyDir = Directory.systemTemp.createTempSync('compat_empty_');
      addTearDown(() => emptyDir.deleteSync(recursive: true));
      final envLoader = LlmEnvLoader(
        sessionCwd: emptyDir.path,
        currentDirectoryPath: emptyDir.path,
        processEnvironment: const <String, String>{},
      );
      final unsetDriver = LocalOpenAiCompatDriver(envLoader: envLoader);
      expect(
        unsetDriver.resolveEndpoint,
        throwsA(
          isA<LlmDriverException>()
              .having((e) => e.error.code, 'code', SyscallErrorCode.einval)
              .having((e) => e.error.reason, 'reason', 'MISSING_BASE_URL'),
        ),
      );
    });

    test('connects without Authorization header when API key is unset and extracts timings.cache_n', () async {
      final client = _MockHttpClient((req, body) async {
        return _sseResponse(<String>[
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{'content': 'Local OK'},
                    'finish_reason': 'stop',
                  },
                ],
                'usage': <String, dynamic>{
                  'prompt_tokens': 50,
                  'completion_tokens': 2,
                  'total_tokens': 52,
                },
                'timings': <String, dynamic>{'cache_n': 42},
              })}',
          'data: [DONE]',
        ]);
      });

      final emptyDir = Directory.systemTemp.createTempSync('compat_noauth_');
      addTearDown(() => emptyDir.deleteSync(recursive: true));
      final envLoader = LlmEnvLoader(
        sessionCwd: emptyDir.path,
        currentDirectoryPath: emptyDir.path,
        processEnvironment: const <String, String>{},
      );
      final driver = LocalOpenAiCompatDriver(
        baseUrl: 'http://127.0.0.1:11838/v1',
        envLoader: envLoader,
        httpClient: client,
      );

      final done = await _collectDone(
        driver.chatStream(
          LlmChatRequest(
            sessionId: 's_local',
            sessionUuid: 'u_local',
            model: const ModelIdentifier(
              provider: LlmProviderId.openaiCompat,
              modelName: 'meta-llama/llama-3.3-70b',
            ),
            prompt: _simplePrompt(),
          ),
        ),
      );

      expect(done.content, equals('Local OK'));
      expect(done.usage.cachedTokens, equals(42));
      expect(client.requests.single.headers.containsKey('Authorization'), isFalse);
      expect(
        client.requests.single.uri.toString(),
        equals('http://127.0.0.1:11838/v1/chat/completions'),
      );
    });
  });

  group('LlmRouter.withDefaults [D-402]', () {
    test('registers all 7 providers and forwards baseUrl overrides', () {
      final router = LlmRouter.withDefaults(
        openAiBaseUrl: 'http://127.0.0.1:9001/v1',
        geminiBaseUrl: 'http://127.0.0.1:9002',
        nousPortalBaseUrl: 'http://127.0.0.1:9003/v1',
        openAiCompatBaseUrl: 'http://127.0.0.1:9004/v1',
      );

      for (final id in LlmProviderId.values) {
        expect(router.driverFor(id), isNotNull, reason: 'Missing driver for ${id.id}');
      }
      expect(router.driverFor(LlmProviderId.openai), isA<OpenAiDriver>());
      expect(router.driverFor(LlmProviderId.gemini), isA<GeminiDriver>());
      expect(router.driverFor(LlmProviderId.nousPortal), isA<NousPortalDriver>());
      expect(router.driverFor(LlmProviderId.openaiCompat), isA<LocalOpenAiCompatDriver>());
    });
  });

  group('ContextWindowResolver new 4 providers [D-405]', () {
    test('resolves Gemini /v1beta/models with x-goog-api-key, caches on success, and does not negative-cache on failure', () async {
      var shouldFail = true;
      var callCount = 0;
      final client = _MockHttpClient((req, body) async {
        callCount++;
        if (shouldFail) {
          return _jsonResponse(<String, dynamic>{'error': 'down'}, statusCode: 503);
        }
        return _jsonResponse(<String, dynamic>{
          'models': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'models/gemini-2.5-flash',
              'inputTokenLimit': 1048576,
              'outputTokenLimit': 65536,
            },
          ],
        });
      });

      final resolver = ContextWindowResolver(
        geminiBaseUrl: 'https://generativelanguage.googleapis.com',
        httpClient: client,
        processEnvironment: const <String, String>{
          'GEMINI_API_KEY': 'gem-ctx-secret',
        },
      );

      const model = ModelIdentifier(
        provider: LlmProviderId.gemini,
        modelName: 'gemini-2.5-flash',
      );

      // 1) Failure returns conservative fallback 131072 without negative caching.
      final fallbackSpec = await resolver.resolve(model);
      expect(fallbackSpec.contextWindowTokens, equals(131072));
      expect(fallbackSpec.isLoadedExact, isFalse);
      expect(fallbackSpec.source, equals('fallback:gemini'));

      // 2) Recovery probes again and caches exact inputTokenLimit.
      shouldFail = false;
      final exactSpec = await resolver.resolve(model);
      expect(exactSpec.contextWindowTokens, equals(1048576));
      expect(exactSpec.maxCompletionTokens, equals(65536));
      expect(exactSpec.isLoadedExact, isTrue);
      expect(exactSpec.source, equals('gemini:/v1beta/models'));

      // 3) Subsequent resolve uses cache without new HTTP call.
      await resolver.resolve(model);
      expect(callCount, equals(2));
      expect(client.requests.first.uri.queryParameters.containsKey('key'), isFalse);
      expect(client.requests.first.headers['x-goog-api-key'], equals('gem-ctx-secret'));
    });

    test('resolves Nous Portal /v1/models and falls back to 131072 on failure', () async {
      final client = _MockHttpClient((req, body) async {
        return _jsonResponse(<String, dynamic>{
          'data': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'Hermes-4-70B',
              'context_length': 131072,
              'top_provider': <String, dynamic>{
                'context_length': 262144,
                'max_completion_tokens': 16384,
              },
            },
          ],
        });
      });

      final resolver = ContextWindowResolver(
        nousPortalBaseUrl: 'https://inference-api.nousresearch.com/v1',
        httpClient: client,
        processEnvironment: const <String, String>{
          'NOUS_API_KEY': 'nous-ctx-key',
        },
      );

      final spec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.nousPortal,
          modelName: 'Hermes-4-70B',
        ),
      );
      expect(spec.contextWindowTokens, equals(262144));
      expect(spec.maxCompletionTokens, equals(16384));
      expect(spec.isLoadedExact, isTrue);
      expect(spec.source, equals('nous-portal:/models'));
    });

    test('resolves openai-compat in priority order: /props n_ctx > /v1/models meta.n_ctx_train > 32768 fallback', () async {
      var propsStatus = 200;
      var modelsStatus = 200;
      final client = _MockHttpClient((req, body) async {
        if (req.url.path == '/props') {
          if (propsStatus != 200) {
            return _jsonResponse(<String, dynamic>{}, statusCode: propsStatus);
          }
          return _jsonResponse(<String, dynamic>{
            'default_generation_settings': <String, dynamic>{'n_ctx': 65536},
          });
        }
        if (req.url.path == '/v1/models') {
          if (modelsStatus != 200) {
            return _jsonResponse(<String, dynamic>{}, statusCode: modelsStatus);
          }
          return _jsonResponse(<String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'local-qwen',
                'meta': <String, dynamic>{'n_ctx_train': 131072},
              },
            ],
          });
        }
        return _jsonResponse(<String, dynamic>{}, statusCode: 404);
      });

      const model = ModelIdentifier(
        provider: LlmProviderId.openaiCompat,
        modelName: 'local-qwen',
      );

      // Priority 1: /props
      final resolverProps = ContextWindowResolver(
        openAiCompatBaseUrl: 'http://127.0.0.1:8080/v1',
        httpClient: client,
        processEnvironment: const <String, String>{},
      );
      final propsSpec = await resolverProps.resolve(model);
      expect(propsSpec.contextWindowTokens, equals(65536));
      expect(propsSpec.isLoadedExact, isTrue);
      expect(propsSpec.source, equals('openai-compat:/props'));

      // Priority 2: /v1/models meta.n_ctx_train when /props fails
      propsStatus = 404;
      final resolverModels = ContextWindowResolver(
        openAiCompatBaseUrl: 'http://127.0.0.1:8080/v1',
        httpClient: client,
        processEnvironment: const <String, String>{},
      );
      final modelsSpec = await resolverModels.resolve(model);
      expect(modelsSpec.contextWindowTokens, equals(131072));
      expect(modelsSpec.isLoadedExact, isFalse);
      expect(modelsSpec.source, equals('openai-compat:/v1/models'));

      // Priority 3: 32768 fallback when both fail
      modelsStatus = 500;
      final resolverFallback = ContextWindowResolver(
        openAiCompatBaseUrl: 'http://127.0.0.1:8080/v1',
        httpClient: client,
        processEnvironment: const <String, String>{},
      );
      final fallbackSpec = await resolverFallback.resolve(model);
      expect(fallbackSpec.contextWindowTokens, equals(32768));
      expect(fallbackSpec.isLoadedExact, isFalse);
      expect(fallbackSpec.source, equals('fallback:openai-compat'));
    });

    test('resolves OpenAI known model families and falls back to 128000', () async {
      final resolver = ContextWindowResolver(
        processEnvironment: const <String, String>{},
      );
      final o3Spec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.openai,
          modelName: 'o3-mini',
        ),
      );
      expect(o3Spec.contextWindowTokens, equals(200000));
      expect(o3Spec.source, equals('openai:static'));

      final unknownSpec = await resolver.resolve(
        const ModelIdentifier(
          provider: LlmProviderId.openai,
          modelName: 'custom-openai-model',
        ),
      );
      expect(unknownSpec.contextWindowTokens, equals(128000));
      expect(unknownSpec.source, equals('fallback:openai'));
    });
  });
}
