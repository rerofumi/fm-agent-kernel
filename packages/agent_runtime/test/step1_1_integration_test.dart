import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WP-5 Step 1-1 Integration Gate [D-001]..[D-010], [D-022]', () {
    late Directory repoDir;

    ProcessResult runJjSync(List<String> args) {
      return Process.runSync(
        'jj',
        <String>['--no-pager', ...args],
        workingDirectory: repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
      );
    }

    String readHeadOpId() {
      final res = runJjSync(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      expect(res.exitCode, equals(0), reason: 'jj op log failed: ${res.stderr}');
      return (res.stdout as String).trim();
    }

    Set<String> readAllOpIds() {
      final res = runJjSync(<String>[
        'op',
        'log',
        '--no-graph',
        '--ignore-working-copy',
        '-T',
        r'self.id() ++ "\n"',
      ]);
      expect(res.exitCode, equals(0), reason: 'jj op log failed: ${res.stderr}');
      return const LineSplitter()
          .convert(res.stdout as String)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
    }

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('fm_wp5_it_');
      final initRes = runJjSync(<String>['git', 'init', '--colocate']);
      expect(
        initRes.exitCode,
        equals(0),
        reason: 'jj git init failed: ${initRes.stderr}',
      );
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP5 Tester']);
      runJjSync(<String>['config', 'set', '--repo', 'user.email', 'wp5@example.com']);

      Directory(p.join(repoDir.path, 'lib')).createSync(recursive: true);
      File(p.join(repoDir.path, 'README.md'))
          .writeAsStringSync('# Sample Repo\nInitial doc\n');
      File(p.join(repoDir.path, 'lib', 'app.dart'))
          .writeAsStringSync('String greet() => "hello";\n');

      expect(
        runJjSync(<String>['describe', '-m', 'initial commit']).exitCode,
        equals(0),
      );
      expect(
        runJjSync(<String>['new', '-m', 'feat: update greeting']).exitCode,
        equals(0),
      );
      File(p.join(repoDir.path, 'lib', 'app.dart'))
          .writeAsStringSync('String greet() => "hello world";\n');
      expect(runJjSync(<String>['status']).exitCode, equals(0));
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test('3-provider wire-mock switching (local-ollama <-> openrouter <-> ollama-cloud) preserves history without State Spill', () async {
      const openRouterKey = 'sk-or-v1-wp5-secret-openrouter-987654321';
      const ollamaCloudKey = 'ollama-cloud-secret-token-abcdef123456';

      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final openRouterServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cloudServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await localServer.close(force: true);
        await openRouterServer.close(force: true);
        await cloudServer.close(force: true);
      });

      final capturedLocalBodies = <Map<String, dynamic>>[];
      final capturedOpenRouterBodies = <Map<String, dynamic>>[];
      final capturedOpenRouterHeaders = <HttpHeaders>[];
      final capturedCloudBodies = <Map<String, dynamic>>[];
      final capturedCloudAuth = <String?>[];

      var localStep = 0;
      localServer.listen((req) async {
        expect(req.uri.path, equals('/api/chat'));
        final body = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;
        capturedLocalBodies.add(body);
        localStep += 1;

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (localStep == 1) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'thinking': 'Discovering dart files',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'ollama_call_long_id_1',
                        'function': <String, dynamic>{
                          'name': 'sys_glob',
                          'arguments': <String, dynamic>{'pattern': '**/*.dart'},
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
                  'prompt_eval_count': 420,
                  'eval_count': 24,
                  'prompt_eval_cached_count': 0,
                })}\n',
          );
        } else if (localStep == 2) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'Turn 1 complete: found /workspace/lib/app.dart.',
                  },
                  'done': true,
                  'prompt_eval_count': 490,
                  'eval_count': 18,
                  'prompt_eval_cached_count': 380,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content':
                        'Back on local-ollama after OpenRouter and Ollama Cloud.',
                  },
                  'done': true,
                  'prompt_eval_count': 900,
                  'eval_count': 16,
                  'prompt_eval_cached_count': 420,
                })}\n',
          );
        }
        await req.response.close();
      });

      var openRouterStep = 0;
      openRouterServer.listen((req) async {
        expect(req.uri.path, equals('/api/v1/chat/completions'));
        capturedOpenRouterHeaders.add(req.headers);
        final body = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;
        capturedOpenRouterBodies.add(body);
        openRouterStep += 1;

        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'event-stream');

        if (openRouterStep == 1) {
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
                  'choices': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'delta': <String, dynamic>{
                        'reasoning': 'Checking jj log and diff',
                        'reasoning_details': <Map<String, dynamic>>[
                          <String, dynamic>{'type': 'encrypted', 'data': 'sig_or_1'},
                        ],
                        'tool_calls': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'index': 0,
                            'id': 'toolu_01_openrouter',
                            'function': <String, dynamic>{
                              'name': 'sys_jj_log',
                              'arguments': '{"limit":',
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
                      'delta': <String, dynamic>{
                        'tool_calls': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'index': 0,
                            'function': <String, dynamic>{'arguments': '5}'},
                          },
                        ],
                      },
                      'finish_reason': 'tool_calls',
                    },
                  ],
                  'usage': <String, dynamic>{
                    'prompt_tokens': 610,
                    'completion_tokens': 20,
                    'total_tokens': 630,
                    'cost': 0.0012,
                    'prompt_tokens_details': <String, dynamic>{
                      'cached_tokens': 0,
                      'cache_write_tokens': 400,
                    },
                  },
                })}\n\n',
          );
        } else if (openRouterStep == 2) {
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
                  'choices': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'delta': <String, dynamic>{
                        'content':
                            'OpenRouter verified jj history (feat: update greeting).',
                      },
                      'finish_reason': 'stop',
                    },
                  ],
                  'usage': <String, dynamic>{
                    'prompt_tokens': 700,
                    'completion_tokens': 14,
                    'total_tokens': 714,
                    'cost': 0.0005,
                    'prompt_tokens_details': <String, dynamic>{
                      'cached_tokens': 550,
                      'cache_write_tokens': 0,
                    },
                  },
                })}\n\n',
          );
        } else {
          req.response.write(
            'data: ${jsonEncode(<String, dynamic>{
                  'choices': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'delta': <String, dynamic>{
                        'content': 'Turn 4 stayed on session OpenRouter model.',
                      },
                      'finish_reason': 'stop',
                    },
                  ],
                  'usage': <String, dynamic>{
                    'prompt_tokens': 850,
                    'completion_tokens': 12,
                    'total_tokens': 862,
                    'cost': 0.0004,
                    'prompt_tokens_details': <String, dynamic>{
                      'cached_tokens': 720,
                    },
                  },
                })}\n\n',
          );
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      var cloudStep = 0;
      cloudServer.listen((req) async {
        expect(req.uri.path, equals('/api/chat'));
        capturedCloudAuth.add(req.headers.value('authorization'));
        final body = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;
        capturedCloudBodies.add(body);
        cloudStep += 1;

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (cloudStep == 1) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'cloud_call_1',
                        'function': <String, dynamic>{
                          'name': 'sys_read_lines',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/lib/app.dart',
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 750,
                  'eval_count': 19,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'Ollama Cloud read greet() -> hello world.',
                  },
                  'done': true,
                  'prompt_eval_count': 810,
                  'eval_count': 15,
                  'prompt_eval_cached_count': 600,
                })}\n',
          );
        }
        await req.response.close();
      });

      final redactor = SecretRedactor();
      final envLoader = LlmEnvLoader(
        processEnvironment: <String, String>{
          'OPENROUTER_API_KEY': openRouterKey,
          'OLLAMA_API_KEY': ollamaCloudKey,
        },
        sessionCwd: repoDir.path,
        redactor: redactor,
      );

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          sessionId: 'wp5_3prov',
          startupModel: 'local-ollama/gemma4:12b',
          localOllamaBaseUrl: 'http://127.0.0.1:${localServer.port}/v1',
          openRouterBaseUrl:
              'http://127.0.0.1:${openRouterServer.port}/api/v1',
          ollamaCloudBaseUrl: 'http://127.0.0.1:${cloudServer.port}',
          envLoader: envLoader,
          redactor: redactor,
        ),
      );
      addTearDown(bootstrap.dispose);

      // Turn 1: Local Ollama
      final t1 = await bootstrap.processRunner.submitPrompt(
        userInput: 'Find all dart files.',
      );
      expect(t1.ok, isTrue);
      expect(t1.model!.canonicalId, equals('local-ollama/gemma4:12b'));
      expect(t1.toolCallsExecuted, equals(1));
      expect(capturedLocalBodies.first['keep_alive'], equals('15m'));

      // Turn 2: Switch session model to OpenRouter Anthropic
      final setOr = bootstrap.processRunner
          .setSessionModel('openrouter/anthropic/claude-sonnet-4');
      expect(setOr.ok, isTrue);
      final t2 = await bootstrap.processRunner.submitPrompt(
        userInput: 'Check recent jj log.',
      );
      expect(t2.ok, isTrue);
      expect(
        t2.model!.canonicalId,
        equals('openrouter/anthropic/claude-sonnet-4'),
      );
      expect(t2.toolCallsExecuted, equals(1));
      expect(t2.usage?.cachedTokens, equals(550));

      // Verify Sticky Routing & cache_control & 9-char Base62 tool_call_id pairing.
      expect(
        capturedOpenRouterHeaders.first.value('x-session-id'),
        equals(bootstrap.leadAgent.sessionUuid),
      );
      expect(
        capturedOpenRouterBodies.first['session_id'],
        equals(bootstrap.leadAgent.sessionUuid),
      );
      final orMsgs =
          capturedOpenRouterBodies.first['messages'] as List<dynamic>;
      final sysMsg = orMsgs.first as Map<String, dynamic>;
      expect(sysMsg['role'], equals('system'));
      expect(sysMsg['content'], isA<List<dynamic>>());
      expect(
        ((sysMsg['content'] as List<dynamic>).first
            as Map<String, dynamic>)['cache_control'],
        equals(<String, dynamic>{'type': 'ephemeral'}),
      );
      final assistantWithTool = orMsgs.firstWhere(
        (m) => m is Map && m['role'] == 'assistant' && m['tool_calls'] != null,
      ) as Map<String, dynamic>;
      final toolResultMsg = orMsgs.firstWhere(
        (m) => m is Map && m['role'] == 'tool',
      ) as Map<String, dynamic>;
      final projectedId =
          ((assistantWithTool['tool_calls'] as List<dynamic>).first
              as Map<String, dynamic>)['id'] as String;
      expect(projectedId, matches(RegExp(r'^[a-zA-Z0-9]{9}$')));
      expect(toolResultMsg['tool_call_id'], equals(projectedId));

      // Turn 3: Priority 1 per-turn override to Ollama Cloud (must NOT overwrite Priority 2).
      final t3 = await bootstrap.processRunner.submitPrompt(
        userInput: 'Read lib/app.dart.',
        modelOverride: 'ollama-cloud/gpt-oss:120b',
      );
      expect(t3.ok, isTrue);
      expect(t3.model!.canonicalId, equals('ollama-cloud/gpt-oss:120b'));
      expect(capturedCloudAuth.first, equals('Bearer $ollamaCloudKey'));

      // Verify OpenRouter encrypted reasoning_details was stripped when switching to Ollama Cloud!
      final cloudMsgs = capturedCloudBodies.first['messages'] as List<dynamic>;
      for (final m in cloudMsgs) {
        final msg = m as Map<String, dynamic>;
        expect(msg.containsKey('reasoning_details'), isFalse);
        if (msg['role'] == 'assistant') {
          expect(msg.containsKey('thinking'), isFalse);
        }
      }

      // Turn 4: Without override, Priority 2 remains openrouter/anthropic/claude-sonnet-4.
      final t4 = await bootstrap.processRunner.submitPrompt(
        userInput: 'Confirm current session model.',
      );
      expect(t4.ok, isTrue);
      expect(
        t4.model!.canonicalId,
        equals('openrouter/anthropic/claude-sonnet-4'),
      );

      // Turn 5: Switch back to Local Ollama.
      expect(
        bootstrap.processRunner.setSessionModel('local-ollama/gemma4:12b').ok,
        isTrue,
      );
      final t5 = await bootstrap.processRunner.submitPrompt(
        userInput: 'Summarize across all 3 providers.',
      );
      expect(t5.ok, isTrue);
      expect(t5.model!.canonicalId, equals('local-ollama/gemma4:12b'));

      await bootstrap.auditLogger.flush();
      final syscallsContent =
          File(bootstrap.auditLogger.syscallsLogPath).readAsStringSync();
      final llmIoContent =
          File(bootstrap.auditLogger.llmIoLogPath).readAsStringSync();
      expect(syscallsContent, isNot(contains(openRouterKey)));
      expect(syscallsContent, isNot(contains(ollamaCloudKey)));
      expect(llmIoContent, isNot(contains(openRouterKey)));
      expect(llmIoContent, isNot(contains(ollamaCloudKey)));

      final llmRecords = const LineSplitter()
          .convert(llmIoContent)
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(
        llmRecords.map((r) => r['provider']).toSet(),
        containsAll(<String>['local-ollama', 'openrouter', 'ollama-cloud']),
      );
    });

    test('10,500-line read and 3,000-hit grep trigger IoPayloadCapper spill & allow narrowed follow-up read', () async {
      final bigLines = List<String>.generate(10500, (idx) {
        final lineNo = idx + 1;
        if (lineNo == 5250) {
          return 'line $lineNo: SECRET_NEEDLE_5250_FOUND';
        }
        if (lineNo <= 3000) {
          return 'line $lineNo: GREP_BULK_HIT_TOKEN';
        }
        return 'line $lineNo: normal filler content';
      });
      File(p.join(repoDir.path, 'big_data.txt'))
          .writeAsStringSync('${bigLines.join('\n')}\n');

      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => localServer.close(force: true));

      final capturedRequests = <Map<String, dynamic>>[];
      var step = 0;

      localServer.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;
        capturedRequests.add(body);
        step += 1;

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (step == 1) {
          // Request full 10,500 lines AND bulk grep in a single turn.
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'cap_read_1',
                        'function': <String, dynamic>{
                          'name': 'sys_read_lines',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/big_data.txt',
                            'startLine': 1,
                            'endLine': 10500,
                          },
                        },
                      },
                      <String, dynamic>{
                        'id': 'cap_grep_1',
                        'function': <String, dynamic>{
                          'name': 'sys_grep',
                          'arguments': <String, dynamic>{
                            'pattern': 'GREP_BULK_HIT_TOKEN',
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 300,
                  'eval_count': 30,
                })}\n',
          );
        } else if (step == 2) {
          // Verify previous tool outputs were capped and follow up with narrowed range read.
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'narrow_read_2',
                        'function': <String, dynamic>{
                          'name': 'sys_read_lines',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/big_data.txt',
                            'startLine': 5248,
                            'endLine': 5252,
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 1200,
                  'eval_count': 20,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'Confirmed line 5250: SECRET_NEEDLE_5250_FOUND',
                  },
                  'done': true,
                  'prompt_eval_count': 1400,
                  'eval_count': 15,
                })}\n',
          );
        }
        await req.response.close();
      });

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          sessionId: 'wp5_iocap',
          startupModel: 'local-ollama/gemma4:12b',
          localOllamaBaseUrl: 'http://127.0.0.1:${localServer.port}',
        ),
      );
      addTearDown(bootstrap.dispose);

      final result = await bootstrap.processRunner.submitPrompt(
        userInput: 'Inspect big_data.txt and find line 5250.',
      );

      expect(result.ok, isTrue);
      expect(result.finalText, contains('SECRET_NEEDLE_5250_FOUND'));
      expect(result.toolCallsExecuted, equals(3));

      // Inspect step 2 tool results seen by LLM.
      final step2Messages =
          capturedRequests[1]['messages'] as List<dynamic>;
      final toolMsgs = step2Messages
          .cast<Map<String, dynamic>>()
          .where((m) => m['role'] == 'tool')
          .toList();
      expect(toolMsgs, hasLength(2));

      final readPayload =
          jsonDecode(toolMsgs[0]['content'] as String) as Map<String, dynamic>;
      expect(readPayload['truncated'], isTrue);
      expect(readPayload['totalLines'], equals(10500));
      expect(readPayload['sha256'], isA<String>());
      expect((readPayload['sha256'] as String).length, equals(64));
      expect(readPayload['content'], contains('KERNEL I/O CAP'));
      expect(
        readPayload['spillPath'],
        startsWith('/workspace/.agent_os/io_spill/wp5_iocap/'),
      );

      final grepPayload =
          jsonDecode(toolMsgs[1]['content'] as String) as Map<String, dynamic>;
      expect(grepPayload['truncated'], isTrue);
      expect(grepPayload['totalMatches'], equals(3000));
      expect(grepPayload['originalCount'], equals(3000));
      expect((grepPayload['matches'] as List<dynamic>).length, equals(200));

      // Inspect step 3 narrowed read result seen by LLM.
      final step3Messages =
          capturedRequests[2]['messages'] as List<dynamic>;
      final narrowToolMsg = step3Messages
          .cast<Map<String, dynamic>>()
          .lastWhere((m) => m['role'] == 'tool');
      final narrowPayload =
          jsonDecode(narrowToolMsg['content'] as String) as Map<String, dynamic>;
      expect(narrowPayload['truncated'], isFalse);
      expect(narrowPayload['content'], contains('SECRET_NEEDLE_5250_FOUND'));

      // Verify spill file was actually persisted under .agent_os/io_spill/.
      final spillDir = Directory(
        p.join(repoDir.path, '.agent_os', 'io_spill', 'wp5_iocap'),
      );
      expect(spillDir.existsSync(), isTrue);
      expect(spillDir.listSync().length, greaterThanOrEqualTo(2));
    });

    test('Read-Only exploration under unsnapshotted edits keeps jj op_id invariant and matches syscalls.jsonl jjOpId', () async {
      // Add unsnapshotted edits, an untracked file, and a protected .env file.
      File(p.join(repoDir.path, 'lib', 'app.dart'))
          .writeAsStringSync('String greet() => "unsnapshotted edit";\n');
      File(p.join(repoDir.path, 'notes.txt'))
          .writeAsStringSync('untracked local note\n');
      File(p.join(repoDir.path, '.env'))
          .writeAsStringSync('SECRET_TOKEN=must_not_be_read\n');

      final opBefore = readHeadOpId();
      final validOpIds = readAllOpIds();

      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => localServer.close(force: true));

      var step = 0;
      localServer.listen((req) async {
        await utf8.decoder.bind(req).drain<void>();
        step += 1;

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (step == 1) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'ro_1',
                        'function': <String, dynamic>{
                          'name': 'sys_glob',
                          'arguments': <String, dynamic>{'pattern': '**/*'},
                        },
                      },
                      <String, dynamic>{
                        'id': 'ro_2',
                        'function': <String, dynamic>{
                          'name': 'sys_grep',
                          'arguments': <String, dynamic>{'pattern': 'greet'},
                        },
                      },
                      <String, dynamic>{
                        'id': 'ro_3',
                        'function': <String, dynamic>{
                          'name': 'sys_read_lines',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/lib/app.dart',
                          },
                        },
                      },
                      <String, dynamic>{
                        'id': 'ro_4',
                        'function': <String, dynamic>{
                          'name': 'sys_read_lines',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/.env',
                          },
                        },
                      },
                      <String, dynamic>{
                        'id': 'ro_5',
                        'function': <String, dynamic>{
                          'name': 'sys_jj_status',
                          'arguments': <String, dynamic>{},
                        },
                      },
                      <String, dynamic>{
                        'id': 'ro_6',
                        'function': <String, dynamic>{
                          'name': 'sys_jj_log',
                          'arguments': <String, dynamic>{'limit': 5},
                        },
                      },
                      <String, dynamic>{
                        'id': 'ro_7',
                        'function': <String, dynamic>{
                          'name': 'sys_jj_diff',
                          'arguments': <String, dynamic>{'rev': '@'},
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 450,
                  'eval_count': 40,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'Explored repo safely without mutating jj op log.',
                  },
                  'done': true,
                  'prompt_eval_count': 900,
                  'eval_count': 20,
                  'prompt_eval_cached_count': 400,
                })}\n',
          );
        }
        await req.response.close();
      });

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          sessionId: 'wp5_readonly',
          startupModel: 'local-ollama/gemma4:12b',
          localOllamaBaseUrl: 'http://127.0.0.1:${localServer.port}',
        ),
      );
      addTearDown(bootstrap.dispose);

      final result = await bootstrap.processRunner.submitPrompt(
        userInput: 'Summarize repo and recent jj changes.',
      );
      expect(result.ok, isTrue);
      expect(result.toolCallsExecuted, equals(7));

      await bootstrap.auditLogger.flush();

      // Verify head op_id is 100% invariant despite unsnapshotted edits and .agent_os log writes!
      final opAfter = readHeadOpId();
      expect(opAfter, equals(opBefore));

      // Verify .agent_os/.gitignore isolates logs from jj status.
      final gitignoreFile = File(p.join(repoDir.path, '.agent_os', '.gitignore'));
      expect(gitignoreFile.existsSync(), isTrue);
      expect(gitignoreFile.readAsStringSync(), equals('*\n'));
      final statusCheck = runJjSync(<String>['status', '--ignore-working-copy']);
      expect(statusCheck.stdout as String, isNot(contains('.agent_os')));

      // Verify every syscalls.jsonl record has a real jjOpId matching opBefore.
      final syscallRecords = const LineSplitter()
          .convert(File(bootstrap.auditLogger.syscallsLogPath).readAsStringSync())
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(syscallRecords.length, equals(9)); // 2 sys_llm_chat + 7 tool calls

      for (final rec in syscallRecords) {
        expect(rec['jjOpId'], equals(opBefore));
        expect(validOpIds, contains(rec['jjOpId']));
        expect(rec['jjChangeId'], isA<String>());
        expect((rec['jjChangeId'] as String).isNotEmpty, isTrue);
      }

      // Verify protected .env read was denied with EACCES and logged.
      final deniedEnv = syscallRecords.firstWhere(
        (r) =>
            r['syscallName'] == 'sys_read_lines' &&
            (r['argsSummary'] as Map)['path'] == '/workspace/.env',
      );
      expect(deniedEnv['ok'], isFalse);
      expect(deniedEnv['errorCode'], equals('EACCES'));
      expect(deniedEnv['errorReason'], equals('PROTECTED_INTERNAL_PATH'));
    });

    test('Same-model consecutive turns preserve Segment 0+1 prefix and record rising cachedTokens / cacheHitRate in llm_io.jsonl', () async {
      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => localServer.close(force: true));

      final capturedBodies = <Map<String, dynamic>>[];
      var turn = 0;

      localServer.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;
        capturedBodies.add(body);
        turn += 1;

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (turn == 1) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'Acknowledged fixed prefix.',
                  },
                  'done': true,
                  'prompt_eval_count': 2200,
                  'eval_count': 12,
                  'prompt_eval_cached_count': 0,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'Second turn hit KV cache.',
                  },
                  'done': true,
                  'prompt_eval_count': 2300,
                  'eval_count': 14,
                  'prompt_eval_cached_count': 2180,
                })}\n',
          );
        }
        await req.response.close();
      });

      final paddedSystem =
          '${KernelBootstrap.defaultStep1Instruction}\n${List<String>.filled(400, 'STATIC_RULE_BLOCK_FOR_PREFIX_CACHE').join(' ')}';

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          sessionId: 'wp5_cache_prefix',
          startupModel: 'local-ollama/gemma4:12b',
          systemInstruction: paddedSystem,
          localOllamaBaseUrl: 'http://127.0.0.1:${localServer.port}',
        ),
      );
      addTearDown(bootstrap.dispose);

      final t1 = await bootstrap.processRunner.submitPrompt(userInput: 'Turn 1');
      final t2 = await bootstrap.processRunner.submitPrompt(userInput: 'Turn 2');

      expect(t1.ok, isTrue);
      expect(t2.ok, isTrue);

      // Verify exact prefix match on Segment 0 + Turn 1 history.
      final m1 = capturedBodies[0]['messages'] as List<dynamic>;
      final m2 = capturedBodies[1]['messages'] as List<dynamic>;
      expect(m1.length, equals(2)); // system + user(Turn 1)
      expect(m2.length, equals(4)); // system + user(Turn 1) + assistant + user(Turn 2)
      expect(jsonEncode(m2[0]), equals(jsonEncode(m1[0])));
      expect(jsonEncode(m2[1]), equals(jsonEncode(m1[1])));

      await bootstrap.auditLogger.flush();
      final llmRecords = const LineSplitter()
          .convert(File(bootstrap.auditLogger.llmIoLogPath).readAsStringSync())
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();

      expect(llmRecords, hasLength(2));
      expect(llmRecords[0]['cachedTokens'], equals(0));
      expect(llmRecords[0]['cacheHitRate'], equals(0.0));
      expect(llmRecords[1]['cachedTokens'], equals(2180));
      expect(
        (llmRecords[1]['cacheHitRate'] as num).toDouble(),
        greaterThan(0.9),
      );
    });
  });
}
