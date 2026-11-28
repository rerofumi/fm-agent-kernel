import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/src/llm/llm_env_loader.dart';
import 'package:agent_drivers/src/llm/open_ai_compat_driver.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

class _TestOpenAiCompatDriver extends OpenAiCompatDriver {
  _TestOpenAiCompatDriver({
    required this.endpointUri,
    super.apiKey,
    super.envLoader,
    super.redactor,
  });

  final Uri endpointUri;

  @override
  LlmProviderId get providerId => LlmProviderId.openai;

  @override
  String get providerDisplayName => 'TestOpenAiCompat';

  @override
  String? get apiKeyEnvVarName => 'OPENAI_API_KEY';

  @override
  Uri resolveEndpoint() => endpointUri;

  @override
  String? resolveApiKey() => explicitApiKey;
}

ProjectedPrompt _buildPrompt() {
  return ProjectedPrompt(
    messages: <ProjectedMessage>[
      ProjectedMessage(
        role: ProjectedRole.system,
        content: 'You are concise.',
        segmentIndex: 0,
      ),
      ProjectedMessage(
        role: ProjectedRole.user,
        content: 'Ping',
        segmentIndex: 2,
      ),
    ],
    tools: const [],
  );
}

LlmChatRequest _buildRequest({bool stream = true}) {
  return LlmChatRequest(
    sessionId: 'sess_base',
    sessionUuid: 'uuid_base',
    model: const ModelIdentifier(
      provider: LlmProviderId.openai,
      modelName: 'gpt-4o',
    ),
    prompt: _buildPrompt(),
    stream: stream,
  );
}

void main() {
  group('OpenAiCompatDriver [D-403]', () {
    late HttpServer server;
    late Uri endpointUri;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      endpointUri =
          Uri.parse('http://${server.address.address}:${server.port}/v1/chat/completions');
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('emits LlmToolCallEvent and single LlmDoneEvent when [DONE] is present', () async {
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write(': keep-alive\n\n');
        req.response.write(
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{
                      'reasoning_content': 'step1 ',
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
                      'reasoning': 'step2 ',
                      'content': 'Hello ',
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
                      'reasoning_details': <Map<String, dynamic>>[
                        <String, dynamic>{'type': 'text', 'text': 'step3'},
                      ],
                      'content': 'world!',
                      'tool_calls': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'index': 0,
                          'id': 'call_1',
                          'function': <String, dynamic>{
                            'name': 'read_file',
                            'arguments': '{"path":',
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
                            'arguments': '"README.md"}',
                          },
                        },
                      ],
                    },
                  },
                ],
                'usage': <String, dynamic>{
                  'prompt_tokens': 100,
                  'completion_tokens': 25,
                  'total_tokens': 125,
                  'cost': 0.0025,
                  'cache_discount': -0.0005,
                  'prompt_tokens_details': <String, dynamic>{
                    'cached_tokens': 80,
                    'cache_write_tokens': 10,
                  },
                },
              })}\n\n',
        );
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      final driver = _TestOpenAiCompatDriver(
        endpointUri: endpointUri,
        apiKey: 'sk-test-done',
      );
      addTearDown(driver.close);

      final events = await driver.chatStream(_buildRequest()).toList();
      final thoughts = events.whereType<LlmThoughtDelta>().map((e) => e.text).join();
      final texts = events.whereType<LlmTextDelta>().map((e) => e.text).join();
      final toolCalls = events.whereType<LlmToolCallEvent>().toList();
      final doneEvents = events.whereType<LlmDoneEvent>().toList();

      expect(thoughts, equals('step1 step2 step3'));
      expect(texts, equals('Hello world!'));
      expect(toolCalls, hasLength(1));
      expect(toolCalls.single.toolCall.id, equals('call_1'));
      expect(toolCalls.single.toolCall.name, equals('read_file'));
      expect(
        toolCalls.single.toolCall.arguments,
        equals(<String, dynamic>{'path': 'README.md'}),
      );
      expect(doneEvents, hasLength(1));
      final resp = doneEvents.single.response;
      expect(resp.content, equals('Hello world!'));
      expect(resp.thoughtText, equals('step1 step2 step3'));
      expect(resp.finishReason, equals('tool_calls'));
      expect(resp.usage.promptTokens, equals(100));
      expect(resp.usage.completionTokens, equals(25));
      expect(resp.usage.totalTokens, equals(125));
      expect(resp.usage.cachedTokens, equals(80));
      expect(resp.usage.cacheWriteTokens, equals(10));
      expect(resp.usage.costMicroUsd, equals(2500));
      expect(resp.usage.cacheDiscountUsd, equals(-0.0005));
    });

    test('emits LlmToolCallEvent and LlmDoneEvent on HTTP EOF without [DONE]', () async {
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.write(
          'data: ${jsonEncode(<String, dynamic>{
                'choices': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'delta': <String, dynamic>{
                      'reasoning_content': 'thinking...',
                      'content': 'EOF ok',
                      'tool_calls': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'index': 0,
                          'id': 'call_eof',
                          'function': <String, dynamic>{
                            'name': 'ping',
                            'arguments': '{"n":1}',
                          },
                        },
                      ],
                    },
                    'finish_reason': 'tool_calls',
                  },
                ],
                'usage': <String, dynamic>{
                  'prompt_tokens': 50,
                  'completion_tokens': 10,
                  'cost': 0.001,
                },
                'timings': <String, dynamic>{
                  'cache_n': 42,
                },
              })}\n\n',
        );
        // Intentionally close without `data: [DONE]` to test EOF completion.
        await req.response.close();
      });

      final driver = _TestOpenAiCompatDriver(
        endpointUri: endpointUri,
        apiKey: 'sk-test-eof',
      );
      addTearDown(driver.close);

      final events = await driver.chatStream(_buildRequest()).toList();
      final toolCalls = events.whereType<LlmToolCallEvent>().toList();
      final doneEvents = events.whereType<LlmDoneEvent>().toList();

      expect(toolCalls, hasLength(1));
      expect(toolCalls.single.toolCall.id, equals('call_eof'));
      expect(toolCalls.single.toolCall.arguments, equals(<String, dynamic>{'n': 1}));
      expect(doneEvents, hasLength(1));
      final resp = doneEvents.single.response;
      expect(resp.content, equals('EOF ok'));
      expect(resp.thoughtText, equals('thinking...'));
      expect(resp.usage.promptTokens, equals(50));
      expect(resp.usage.completionTokens, equals(10));
      expect(resp.usage.cachedTokens, equals(42));
      expect(resp.usage.costMicroUsd, equals(1000));
    });

    test('maps 4xx/5xx HTTP errors and redacts secrets', () async {
      const secret = 'sk-super-secret-compat-key';
      var nextStatus = 401;
      server.listen((req) async {
        req.response.statusCode = nextStatus;
        req.response.write('Error with key $secret');
        await req.response.close();
      });

      final redactor = SecretRedactor();
      final driver = _TestOpenAiCompatDriver(
        endpointUri: endpointUri,
        apiKey: secret,
        redactor: redactor,
      );
      addTearDown(driver.close);

      final cases = <(int, String, bool)>[
        (401, 'AUTH_FAILED', false),
        (403, 'AUTH_FAILED', false),
        (429, 'RATE_LIMITED', true),
        (400, 'PROVIDER_BAD_REQUEST', false),
        (404, 'PROVIDER_BAD_REQUEST', false),
        (422, 'PROVIDER_BAD_REQUEST', false),
        (502, 'PROVIDER_ERROR', true),
      ];

      for (final (status, expectedReason, expectedRecoverable) in cases) {
        nextStatus = status;
        try {
          await driver.chatStream(_buildRequest()).toList();
          fail('Expected LlmDriverException for HTTP $status');
        } on LlmDriverException catch (e) {
          expect(e.error.code, equals(SyscallErrorCode.eprovider));
          expect(e.error.reason, equals(expectedReason));
          expect(e.error.recoverable, equals(expectedRecoverable));
          expect(e.error.message, isNot(contains(secret)));
          expect(e.error.message, contains(SecretRedactor.redactedToken));
        }
      }
    });

    test('buildMessages formats system, user, assistant tool_calls, and tool messages', () {
      final driver = _TestOpenAiCompatDriver(
        endpointUri: endpointUri,
        apiKey: 'sk-msg-test',
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{},
          currentDirectoryPath: Directory.systemTemp.path,
        ),
      );
      addTearDown(driver.close);

      final prompt = ProjectedPrompt(
        messages: <ProjectedMessage>[
          ProjectedMessage(
            role: ProjectedRole.system,
            content: 'sys',
            segmentIndex: 0,
          ),
          ProjectedMessage(
            role: ProjectedRole.user,
            content: 'hi',
            segmentIndex: 1,
          ),
          ProjectedMessage(
            role: ProjectedRole.assistant,
            content: '',
            segmentIndex: 1,
            toolCalls: const <ProjectedToolCall>[
              ProjectedToolCall(
                id: 'call_abc',
                name: 'get_time',
                arguments: <String, dynamic>{'tz': 'UTC'},
              ),
            ],
          ),
          ProjectedMessage(
            role: ProjectedRole.tool,
            content: '{"time":"12:00"}',
            segmentIndex: 1,
            toolCallId: 'call_abc',
            toolName: 'get_time',
          ),
        ],
        tools: const [],
      );

      final messages = driver.buildMessages(
        LlmChatRequest(
          sessionId: 's',
          sessionUuid: 'u',
          model: const ModelIdentifier(
            provider: LlmProviderId.openai,
            modelName: 'gpt-4o',
          ),
          prompt: prompt,
        ),
      );

      expect(messages, hasLength(4));
      expect(messages[0], equals(<String, dynamic>{'role': 'system', 'content': 'sys'}));
      expect(messages[1], equals(<String, dynamic>{'role': 'user', 'content': 'hi'}));
      expect(messages[2]['role'], equals('assistant'));
      expect(messages[2]['content'], equals(''));
      expect((messages[2]['tool_calls'] as List).single['id'], equals('call_abc'));
      expect(
        messages[3],
        equals(<String, dynamic>{
          'role': 'tool',
          'tool_call_id': 'call_abc',
          'name': 'get_time',
          'content': '{"time":"12:00"}',
        }),
      );
    });
  });

  group('OpenAiCompatDriver SSE reasoning_details normalization [D-604]', () {
    late HttpServer server;
    late Uri endpointUri;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      endpointUri = Uri.parse(
        'http://${server.address.address}:${server.port}/v1/chat/completions',
      );
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('merges reasoning.summary, reasoning.text+signature, and preserves reasoning.encrypted and order in SSE', () async {
      server.listen((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        final chunks = <Map<String, dynamic>>[
          <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'delta': <String, dynamic>{
                  'reasoning_details': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'index': 0,
                      'type': 'reasoning.summary',
                      'format': 'openai-responses-v1',
                      'summary': 'Checking ',
                    },
                  ],
                },
              },
            ],
          },
          <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'delta': <String, dynamic>{
                  'reasoning_details': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'index': 0,
                      'type': 'reasoning.summary',
                      'format': 'openai-responses-v1',
                      'summary': 'files.',
                    },
                  ],
                },
              },
            ],
          },
          <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'delta': <String, dynamic>{
                  'reasoning_details': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'index': 1,
                      'type': 'reasoning.encrypted',
                      'id': 'rs_1',
                      'format': 'openai-responses-v1',
                      'data': 'gAAAA_part1',
                    },
                  ],
                },
              },
            ],
          },
          <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'delta': <String, dynamic>{
                  'reasoning_details': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'index': 1,
                      'type': 'reasoning.encrypted',
                      'id': 'rs_1',
                      'format': 'openai-responses-v1',
                      'data': '_part2==',
                    },
                    <String, dynamic>{
                      'index': 2,
                      'type': 'reasoning.text',
                      'id': 'rt_1',
                      'text': 'Step A. ',
                    },
                  ],
                },
              },
            ],
          },
          <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'delta': <String, dynamic>{
                  'reasoning_details': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'index': 2,
                      'type': 'reasoning.text',
                      'id': 'rt_1',
                      'text': 'Step B.',
                    },
                  ],
                },
              },
            ],
          },
          <String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'delta': <String, dynamic>{
                  'reasoning_details': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'index': 2,
                      'type': 'reasoning.text',
                      'id': 'rt_1',
                      'signature': 'sig_xyz',
                    },
                  ],
                  'content': 'Done',
                },
                'finish_reason': 'stop',
              },
            ],
          },
        ];
        for (final c in chunks) {
          req.response.write('data: ${jsonEncode(c)}\n\n');
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      final driver = _TestOpenAiCompatDriver(
        endpointUri: endpointUri,
        apiKey: 'sk-test-merge',
      );
      addTearDown(driver.close);

      final events = await driver.chatStream(_buildRequest()).toList();
      final resp = events.whereType<LlmDoneEvent>().single.response;
      final details = resp.rawReasoningDetails as List<dynamic>;

      expect(details, hasLength(3));
      expect(
        details[0],
        equals(<String, dynamic>{
          'index': 0,
          'type': 'reasoning.summary',
          'format': 'openai-responses-v1',
          'summary': 'Checking files.',
        }),
      );
      expect(
        details[1],
        equals(<String, dynamic>{
          'index': 1,
          'type': 'reasoning.encrypted',
          'id': 'rs_1',
          'format': 'openai-responses-v1',
          'data': 'gAAAA_part1_part2==',
        }),
      );
      expect(
        details[2],
        equals(<String, dynamic>{
          'index': 2,
          'type': 'reasoning.text',
          'id': 'rt_1',
          'text': 'Step A. Step B.',
          'signature': 'sig_xyz',
        }),
      );
    });

    test('preserves unknown fields, distinct encrypted ids, unidentifiable maps, and non-map elements without throwing', () {
      final merged = OpenAiCompatDriver.mergeReasoningDetailsChunks(
        <List<dynamic>>[
          <dynamic>[
            <String, dynamic>{
              'index': 0,
              'type': 'reasoning.text',
              'text': 'Hello ',
              'custom_meta': 'keep_me',
            },
            <String, dynamic>{'opaque_only': 'first'},
            'raw_string_entry',
            42,
          ],
          <dynamic>[
            <String, dynamic>{
              'index': 0,
              'type': 'reasoning.text',
              'text': 'world',
              'custom_meta': null,
              'extra_flag': true,
            },
            <String, dynamic>{'opaque_only': 'second'},
            <String, dynamic>{
              'index': 1,
              'type': 'reasoning.encrypted',
              'id': 'rs_1',
              'data': 'AAA',
            },
            <String, dynamic>{
              'index': 2,
              'type': 'reasoning.encrypted',
              'id': 'rs_2',
              'data': 'BBB',
            },
          ],
        ],
      );

      expect(merged, hasLength(7));
      expect(
        merged[0],
        equals(<String, dynamic>{
          'index': 0,
          'type': 'reasoning.text',
          'text': 'Hello world',
          'custom_meta': 'keep_me',
          'extra_flag': true,
        }),
      );
      expect(merged[1], equals(<String, dynamic>{'opaque_only': 'first'}));
      expect(merged[2], equals('raw_string_entry'));
      expect(merged[3], equals(42));
      expect(merged[4], equals(<String, dynamic>{'opaque_only': 'second'}));
      expect(merged[5]['id'], equals('rs_1'));
      expect(merged[6]['id'], equals('rs_2'));
    });

    test('does not emit empty rawReasoningDetails for empty [] chunks and keeps non-streaming and single-object behavior', () async {
      var mode = 'empty_chunks';
      server.listen((req) async {
        req.response.statusCode = 200;
        if (mode == 'empty_chunks') {
          req.response.headers.contentType = ContentType('text', 'event-stream');
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
                  'choices': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'delta': <String, dynamic>{
                        'reasoning_details': const <dynamic>[],
                        'content': 'OK',
                      },
                      'finish_reason': 'stop',
                    },
                  ],
                })}\n\n',
          );
          req.response.write('data: [DONE]\n\n');
        } else if (mode == 'single_object') {
          req.response.headers.contentType = ContentType('text', 'event-stream');
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
                  'choices': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'delta': <String, dynamic>{
                        'reasoning_details': <String, dynamic>{
                          'type': 'reasoning.summary',
                          'summary': 'Single obj',
                        },
                        'content': 'Single',
                      },
                      'finish_reason': 'stop',
                    },
                  ],
                })}\n\n',
          );
          req.response.write('data: [DONE]\n\n');
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'choices': <Map<String, dynamic>>[
                <String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'Non-stream',
                    'reasoning_details': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'type': 'reasoning.summary',
                        'summary': 'Full summary',
                      },
                    ],
                  },
                  'finish_reason': 'stop',
                },
              ],
            }),
          );
        }
        await req.response.close();
      });

      final driver = _TestOpenAiCompatDriver(
        endpointUri: endpointUri,
        apiKey: 'sk-test-compat',
      );
      addTearDown(driver.close);

      final emptyResp = (await driver.chatStream(_buildRequest()).toList())
          .whereType<LlmDoneEvent>()
          .single
          .response;
      expect(emptyResp.rawReasoningDetails, isNull);

      mode = 'single_object';
      final singleResp = (await driver.chatStream(_buildRequest()).toList())
          .whereType<LlmDoneEvent>()
          .single
          .response;
      expect(
        singleResp.rawReasoningDetails,
        equals(<String, dynamic>{
          'type': 'reasoning.summary',
          'summary': 'Single obj',
        }),
      );

      mode = 'non_streaming';
      final nonStreamResp =
          (await driver.chatStream(_buildRequest(stream: false)).toList())
              .whereType<LlmDoneEvent>()
              .single
              .response;
      expect(nonStreamResp.content, equals('Non-stream'));
      expect(
        nonStreamResp.rawReasoningDetails,
        equals(<Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'reasoning.summary',
            'summary': 'Full summary',
          },
        ]),
      );
    });
  });
}
