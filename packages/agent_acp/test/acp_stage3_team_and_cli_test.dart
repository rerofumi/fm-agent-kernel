import 'dart:async';
import 'dart:io';

import 'package:agent_acp/agent_acp.dart';
import 'package:agent_acp/src/wire/wire_command_splitter.dart';
import 'package:agent_acp/src/wire/wire_redactor.dart';
import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WP-7 Stage 3 ACP Team, Stacked, Signal, MCP, Swap & CLI Integration',
      () {
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

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('fm_wp7_acp_');
      expect(runJjSync(<String>['git', 'init', '--colocate']).exitCode, 0);
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP7 Tester']);
      runJjSync(
          <String>['config', 'set', '--repo', 'user.email', 'wp7@example.com']);

      File(p.join(repoDir.path, 'app.txt')).writeAsStringSync('base v1\n');
      expect(runJjSync(<String>['describe', '-m', 'base']).exitCode, 0);
      expect(runJjSync(<String>['new', '-m', 'wip']).exitCode, 0);
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    _StreamPair createStreamPair() {
      final c2s = StreamController<List<int>>();
      final s2c = StreamController<List<int>>();
      return _StreamPair(
        clientIn: s2c.stream,
        clientOut: c2s.sink,
        serverIn: c2s.stream,
        serverOut: s2c.sink,
      );
    }

    test(
        'session/new rejects unsupported mcpServers transport, duplicate names, and too-small maxContextTokens with -32602',
        () async {
      final pair = createStreamPair();
      final server = AcpServer(
        peer: JsonRpcPeer(input: pair.serverIn, output: pair.serverOut),
      );
      final client = JsonRpcPeer(input: pair.clientIn, output: pair.clientOut);
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      await client.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });

      // 1. Unsupported http transport
      await expectLater(
        () => client.sendRequest('session/new', <String, dynamic>{
          'cwd': repoDir.path,
          'mcpServers': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'http',
              'name': 'remote',
              'url': 'https://example.com/mcp',
            },
          ],
        }),
        throwsA(
          isA<JsonRpcException>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.invalidParams),
        ),
      );

      // 2. Duplicate MCP server name
      await expectLater(
        () => client.sendRequest('session/new', <String, dynamic>{
          'cwd': repoDir.path,
          'mcpServers': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'stdio',
              'name': 'dup',
              'command': 'dart',
            },
            <String, dynamic>{
              'type': 'stdio',
              'name': 'dup',
              'command': 'dart',
            },
          ],
        }),
        throwsA(
          isA<JsonRpcException>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.invalidParams)
              .having((e) => e.message, 'message',
                  contains('DUPLICATE_MCP_SERVER_NAME')),
        ),
      );

      // 3. maxContextTokens below minimum required window
      await expectLater(
        () => client.sendRequest('session/new', <String, dynamic>{
          'cwd': repoDir.path,
          'mcpServers': const <Object>[],
          '_meta': <String, dynamic>{
            'fm_agent_os/maxContextTokens': 128,
          },
        }),
        throwsA(
          isA<JsonRpcException>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.invalidParams)
              .having((e) => e.message, 'message',
                  contains('MAX_CONTEXT_TOKENS_TOO_SMALL')),
        ),
      );
    });

    test(
        'session/new connects pure-Dart stdio mcpServers, redacts env[].value, and disposes cleanly',
        () async {
      final fixturePath = p.normalize(p.join(
        Directory.current.path,
        'packages',
        'agent_drivers',
        'test',
        'fixtures',
        'mock_stdio_mcp_server.dart',
      ));
      expect(File(fixturePath).existsSync(), isTrue);

      final pair = createStreamPair();
      final mockDriver = _ScriptedLlmDriver(
        onChat: (req, turn) {
          if (turn == 0) {
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_mcp_1',
                  name: 'sys_mcp_call',
                  arguments: const <String, dynamic>{
                    'server': 'demo',
                    'tool': 'calc_sum',
                    'arguments': <String, dynamic>{'a': 21, 'b': 21},
                  },
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_mcp_1',
                      name: 'sys_mcp_call',
                      arguments: const <String, dynamic>{
                        'server': 'demo',
                        'tool': 'calc_sum',
                        'arguments': <String, dynamic>{'a': 21, 'b': 21},
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 50,
                    completionTokens: 10,
                    totalTokens: 60,
                    durationMs: 10,
                  ),
                  finishReason: 'tool_calls',
                ),
              ),
            ];
          }
          return const <LlmStreamEvent>[];
        },
        secondTurnText: 'MCP tool called successfully.',
      );

      late KernelBootstrap capturedBootstrap;
      final server = AcpServer(
        peer: JsonRpcPeer(input: pair.serverIn, output: pair.serverOut),
        config: AcpServerConfig(
          startupModel: 'local-ollama/gemma4:12b',
          bootstrapFactory: (cfg) {
            capturedBootstrap = KernelBootstrap.create(
              KernelBootstrapConfig(
                workspaceHostRoot: cfg.workspaceHostRoot,
                sessionId: cfg.sessionId,
                startupModel: cfg.startupModel,
                approvalHandler: cfg.approvalHandler,
                hooks: cfg.hooks,
                enableStage2Multiprocess: true,
                enableStage3Team: true,
                mcpServers: cfg.mcpServers,
                onPagingReport: cfg.onPagingReport,
                onLlmStreamEvent: cfg.onLlmStreamEvent,
                llmRouter: LlmRouter(
                  drivers: <LlmProviderId, LlmDriver>{
                    LlmProviderId.localOllama: mockDriver,
                  },
                ),
              ),
            );
            return capturedBootstrap;
          },
        ),
      );

      final permissionRequests = <Map<String, dynamic>>[];
      final client = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
        onRequest: (method, params) async {
          if (method == 'session/request_permission') {
            permissionRequests.add(params);
            return <String, dynamic>{
              'outcome': <String, dynamic>{
                'outcome': 'selected',
                'optionId': 'allow_once',
              },
            };
          }
          throw JsonRpcException(JsonRpcErrorCodes.methodNotFound, method);
        },
      );
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      await client.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });

      const secretVal = 'MCP_SUPER_SECRET_VALUE_999';
      final newRes = await client.sendRequest('session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'stdio',
            'name': 'demo',
            'command': Platform.resolvedExecutable,
            'args': <String>['run', fixturePath],
            'env': <Map<String, dynamic>>[
              <String, dynamic>{'name': 'DEMO_SECRET', 'value': secretVal},
            ],
          },
        ],
      }) as Map<String, dynamic>;

      final sessionId = newRes['sessionId'] as String;
      expect(
        capturedBootstrap.mcpServerManager!.clientFor('demo')?.isConnected,
        isTrue,
      );

      final promptRes =
          await client.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Call demo echo_env'},
        ],
      }) as Map<String, dynamic>;

      expect(promptRes['stopReason'], equals('end_turn'));
      expect(permissionRequests, hasLength(1));

      final auditFile = File(capturedBootstrap.auditLogger.syscallsLogPath);
      expect(auditFile.existsSync(), isTrue);
      expect(auditFile.readAsStringSync(), isNot(contains(secretVal)));

      await server.dispose();
      expect(capturedBootstrap.mcpServerManager!.clients, isEmpty);
    });

    test(
        'session/prompt taskId binds c_A, cascades update-stale to task B, and all 9 _fm_agent_os/* methods work with standard session/update keys',
        () async {
      final pair = createStreamPair();
      final mockDriver = _ScriptedLlmDriver(
        onChat: (req, turn) {
          if (turn == 0) {
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_write_a',
                  name: 'sys_write_file',
                  arguments: const <String, dynamic>{
                    'path': '/workspace/shared_a.txt',
                    'content': 'from task A v1\n',
                  },
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_write_a',
                      name: 'sys_write_file',
                      arguments: const <String, dynamic>{
                        'path': '/workspace/shared_a.txt',
                        'content': 'from task A v1\n',
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 40,
                    completionTokens: 10,
                    totalTokens: 50,
                    durationMs: 10,
                  ),
                  finishReason: 'tool_calls',
                ),
              ),
            ];
          }
          return <LlmStreamEvent>[
            LlmDoneEvent(
              LlmChatResponse(
                content: 'Task A completed.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 45,
                  completionTokens: 8,
                  totalTokens: 53,
                  durationMs: 10,
                ),
                finishReason: 'stop',
              ),
            ),
          ];
        },
        secondTurnText: 'Task A completed.',
      );

      final server = AcpServer(
        peer: JsonRpcPeer(input: pair.serverIn, output: pair.serverOut),
        config: AcpServerConfig(
          startupModel: 'local-ollama/gemma4:12b',
          bootstrapFactory: (cfg) {
            return KernelBootstrap.create(
              KernelBootstrapConfig(
                workspaceHostRoot: cfg.workspaceHostRoot,
                sessionId: cfg.sessionId,
                startupModel: cfg.startupModel,
                approvalHandler: cfg.approvalHandler,
                hooks: cfg.hooks,
                enableStage2Multiprocess: true,
                enableStage3Team: true,
                onPagingReport: cfg.onPagingReport,
                onLlmStreamEvent: cfg.onLlmStreamEvent,
                llmRouter: LlmRouter(
                  drivers: <LlmProviderId, LlmDriver>{
                    LlmProviderId.localOllama: mockDriver,
                  },
                ),
              ),
            );
          },
        ),
      );

      final updates = <Map<String, dynamic>>[];
      final client = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
        onNotification: (method, params) {
          if (method == 'session/update') {
            final u = params['update'];
            if (u is Map) {
              updates.add(Map<String, dynamic>.from(u));
            }
          }
        },
        onRequest: (method, params) async {
          if (method == 'session/request_permission') {
            return <String, dynamic>{
              'outcome': <String, dynamic>{
                'outcome': 'selected',
                'optionId': 'allow_once',
              },
            };
          }
          throw JsonRpcException(JsonRpcErrorCodes.methodNotFound, method);
        },
      );
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      await client.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });
      final newRes = await client.sendRequest('session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>;
      final sessionId = newRes['sessionId'] as String;

      // 1. Unknown taskId in session/prompt -> -32602
      await expectLater(
        () => client.sendRequest('session/prompt', <String, dynamic>{
          'sessionId': sessionId,
          'prompt': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'hi'},
          ],
          '_meta': <String, dynamic>{'fm_agent_os/taskId': 'no_such_task'},
        }),
        throwsA(
          isA<JsonRpcException>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.invalidParams),
        ),
      );

      // 2. stack_create: task_a -> task_b
      final createA =
          await client.sendRequest('_fm_agent_os/stack_create', <String, dynamic>{
        'sessionId': sessionId,
        'taskId': 'task_a',
        'title': 'Base Task A',
      }) as Map<String, dynamic>;
      final taskA = createA['task'] as Map<String, dynamic>;
      final wsARoot = taskA['workspaceRoot'] as String;

      final createB =
          await client.sendRequest('_fm_agent_os/stack_create', <String, dynamic>{
        'sessionId': sessionId,
        'taskId': 'task_b',
        'title': 'Child Task B',
        'parentTaskId': 'task_a',
      }) as Map<String, dynamic>;
      final taskB = createB['task'] as Map<String, dynamic>;
      final wsBRoot = taskB['workspaceRoot'] as String;

      // 3. stack_update
      final updateB =
          await client.sendRequest('_fm_agent_os/stack_update', <String, dynamic>{
        'sessionId': sessionId,
        'taskId': 'task_b',
        'model': 'local-ollama/gemma4:12b',
      }) as Map<String, dynamic>;
      expect((updateB['task'] as Map)['assignedModel'],
          equals('local-ollama/gemma4:12b'));

      // 4. session/prompt bound to task_a -> writes shared_a.txt in wsA and cascades to wsB!
      final promptRes =
          await client.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Write shared_a.txt'},
        ],
        '_meta': <String, dynamic>{
          'fm_agent_os/taskId': 'task_a',
          'fm_agent_os/executionMode': 'single',
        },
      }) as Map<String, dynamic>;
      expect(promptRes['stopReason'], equals('end_turn'));

      expect(File(p.join(wsARoot, 'shared_a.txt')).readAsStringSync(),
          equals('from task A v1\n'));
      expect(File(p.join(wsBRoot, 'shared_a.txt')).readAsStringSync(),
          equals('from task A v1\n'));

      // 5. stack_edit on task_a -> cascades update-stale to task_b!
      final editRes =
          await client.sendRequest('_fm_agent_os/stack_edit', <String, dynamic>{
        'sessionId': sessionId,
        'taskId': 'task_a',
        'relativePath': 'shared_a.txt',
        'content': 'from task A v2\n',
      }) as Map<String, dynamic>;
      expect((editRes['cascadedTasks'] as List).length, equals(1));
      expect(File(p.join(wsBRoot, 'shared_a.txt')).readAsStringSync(),
          equals('from task A v2\n'));

      // 6. stack_sync & stack_list & jj_diff & processes & signal
      final syncRes =
          await client.sendRequest('_fm_agent_os/stack_sync', <String, dynamic>{
        'sessionId': sessionId,
        'taskId': 'task_a',
      }) as Map<String, dynamic>;
      expect(syncRes['action'], equals('sync'));

      final listRes =
          await client.sendRequest('_fm_agent_os/stack_list', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
      expect((listRes['tasks'] as List).length, equals(2));

      final diffRes =
          await client.sendRequest('_fm_agent_os/jj_diff', <String, dynamic>{
        'sessionId': sessionId,
        'taskId': 'task_a',
      }) as Map<String, dynamic>;
      expect(diffRes['diff'] as String, contains('from task A v2'));

      final procsRes =
          await client.sendRequest('_fm_agent_os/processes', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
      expect((procsRes['lead'] as Map)['pid'], equals(1));

      final sigStop =
          await client.sendRequest('_fm_agent_os/signal', <String, dynamic>{
        'sessionId': sessionId,
        'signal': 'SIGSTOP',
      }) as Map<String, dynamic>;
      expect(sigStop['ok'], isTrue);

      final sigCont =
          await client.sendRequest('_fm_agent_os/signal', <String, dynamic>{
        'sessionId': sessionId,
        'signal': 'SIGCONT',
        'constraintMessage': 'keep v2',
      }) as Map<String, dynamic>;
      expect(sigCont['ok'], isTrue);

      // 7. tx_squash
      final squashRes =
          await client.sendRequest('_fm_agent_os/tx_squash', <String, dynamic>{
        'sessionId': sessionId,
        'taskId': 'task_a',
        'message': 'squash test',
      }) as Map<String, dynamic>;
      expect((squashRes['task'] as Map)['state'], equals('done'));

      // 8. Verify ACP session/update root standard keys purity
      const allowedUpdateKeys = <String>{
        'sessionUpdate',
        'content',
        'toolCallId',
        'title',
        'kind',
        'status',
        'locations',
        'used',
        'size',
        'cost',
        'configOptions',
        'entries',
        '_meta',
      };
      for (final u in updates) {
        for (final key in u.keys) {
          expect(allowedUpdateKeys.contains(key), isTrue,
              reason: 'Non-standard root key "$key" in $u');
        }
      }
    });

    test('mid-turn /pause -> /resume -> /kill via _fm_agent_os/signal',
        () async {
      final pair = createStreamPair();
      final step1Reached = Completer<void>();
      var stepCount = 0;

      final mockDriver = _ScriptedLlmDriver(
        onChat: (req, turn) {
          stepCount += 1;
          if (stepCount == 1) {
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_stat_1',
                  name: 'sys_jj_status',
                  arguments: const <String, dynamic>{},
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_stat_1',
                      name: 'sys_jj_status',
                      arguments: const <String, dynamic>{},
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 20,
                    completionTokens: 5,
                    totalTokens: 25,
                    durationMs: 10,
                  ),
                  finishReason: 'tool_calls',
                ),
              ),
            ];
          }
          // Verify injected constraint is present in messages
          final hasConstraint = req.prompt.messages.any(
            (m) => m.content.contains('TAG_CONSTRAINT_777'),
          );
          return <LlmStreamEvent>[
            LlmDoneEvent(
              LlmChatResponse(
                content: hasConstraint ? 'SAW_TAG_777' : 'MISSING_TAG',
                usage: const LlmUsageTelemetry(
                  promptTokens: 30,
                  completionTokens: 5,
                  totalTokens: 35,
                  durationMs: 10,
                ),
                finishReason: 'stop',
              ),
            ),
          ];
        },
        secondTurnText: 'SAW_TAG_777',
      );

      final server = AcpServer(
        peer: JsonRpcPeer(input: pair.serverIn, output: pair.serverOut),
        config: AcpServerConfig(
          startupModel: 'local-ollama/gemma4:12b',
          bootstrapFactory: (cfg) {
            return KernelBootstrap.create(
              KernelBootstrapConfig(
                workspaceHostRoot: cfg.workspaceHostRoot,
                sessionId: cfg.sessionId,
                startupModel: cfg.startupModel,
                approvalHandler: cfg.approvalHandler,
                hooks: cfg.hooks,
                enableStage2Multiprocess: true,
                enableStage3Team: true,
                onPagingReport: cfg.onPagingReport,
                onLlmStreamEvent: cfg.onLlmStreamEvent,
                llmRouter: LlmRouter(
                  drivers: <LlmProviderId, LlmDriver>{
                    LlmProviderId.localOllama: mockDriver,
                  },
                ),
              ),
            );
          },
        ),
      );

      final client = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
        onNotification: (method, params) {
          if (method == 'session/update') {
            final u = params['update'];
            if (u is Map &&
                u['sessionUpdate'] == 'tool_call' &&
                !step1Reached.isCompleted) {
              step1Reached.complete();
            }
          }
        },
      );
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      await client.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });
      final newRes = await client.sendRequest('session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>;
      final sessionId = newRes['sessionId'] as String;

      final promptFuture =
          client.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Check status'},
        ],
      });

      await step1Reached.future;
      final stopRes =
          await client.sendRequest('_fm_agent_os/signal', <String, dynamic>{
        'sessionId': sessionId,
        'signal': 'SIGSTOP',
      }) as Map<String, dynamic>;
      expect(stopRes['leadState'], equals('stopped'));

      final contRes =
          await client.sendRequest('_fm_agent_os/signal', <String, dynamic>{
        'sessionId': sessionId,
        'signal': 'SIGCONT',
        'constraintMessage': 'TAG_CONSTRAINT_777',
      }) as Map<String, dynamic>;
      expect(contRes['leadState'], equals('running'));

      final promptRes = await promptFuture as Map<String, dynamic>;
      expect(promptRes['stopReason'], equals('end_turn'));
    });

    test('--mcp-server parses both JSON and name=command [args...] notations',
        () {
      final redactor = WireSecretRedactor();
      final jsonSpec = parseWireMcpServerSpec(
        '{"name":"s1","command":"dart","args":["run","srv.dart"],"env":[{"name":"K","value":"SEC_123"}]}',
        redactor: redactor,
      );
      expect(jsonSpec.name, equals('s1'));
      expect(jsonSpec.command, equals('dart'));
      expect(jsonSpec.args, equals(<String>['run', 'srv.dart']));
      expect(redactor.redactString('SEC_123'), equals('<REDACTED>'));

      final shortSpec = parseWireMcpServerSpec(
        r'demo="C:\Program Files\tool\mcp.exe" --flag "hello world"',
      );
      expect(shortSpec.name, equals('demo'));
      expect(shortSpec.command, equals(r'C:\Program Files\tool\mcp.exe'));
      expect(shortSpec.args, equals(<String>['--flag', 'hello world']));
    });
  });
}

class _StreamPair {
  _StreamPair({
    required this.clientIn,
    required this.clientOut,
    required this.serverIn,
    required this.serverOut,
  });

  final Stream<List<int>> clientIn;
  final StreamSink<List<int>> clientOut;
  final Stream<List<int>> serverIn;
  final StreamSink<List<int>> serverOut;

  Future<void> close() async {
    await clientOut.close();
    await serverOut.close();
  }
}

class _ScriptedLlmDriver implements LlmDriver {
  _ScriptedLlmDriver({
    required this.onChat,
    required this.secondTurnText,
  });

  final List<LlmStreamEvent> Function(LlmChatRequest req, int turn) onChat;
  final String secondTurnText;
  int _callCount = 0;

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final idx = _callCount++;
    if (idx == 0) {
      for (final ev in onChat(request, idx)) {
        yield ev;
      }
      return;
    }
    final events = onChat(request, idx);
    if (events.isNotEmpty) {
      for (final ev in events) {
        yield ev;
      }
      return;
    }
    yield LlmTextDelta(secondTurnText);
    yield LlmDoneEvent(
      LlmChatResponse(
        content: secondTurnText,
        usage: const LlmUsageTelemetry(
          promptTokens: 30,
          completionTokens: 5,
          totalTokens: 35,
          durationMs: 10,
        ),
        finishReason: 'stop',
      ),
    );
  }
}
