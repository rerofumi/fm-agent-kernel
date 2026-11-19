import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_acp/agent_acp.dart';
import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ACP v1 Server, EventMapper, and Ring 2 Approval Gate [D-018]..[D-020]',
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
      expect(res.exitCode, equals(0), reason: '${res.stderr}');
      return (res.stdout as String).trim();
    }

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('fm_wp8_acp_');
      final initRes = runJjSync(<String>['git', 'init', '--colocate']);
      expect(initRes.exitCode, equals(0), reason: '${initRes.stderr}');
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP8 Tester']);
      runJjSync(
          <String>['config', 'set', '--repo', 'user.email', 'wp8@example.com']);

      File(p.join(repoDir.path, 'hello.txt')).writeAsStringSync('hello v1\n');
      expect(runJjSync(<String>['describe', '-m', 'base']).exitCode, equals(0));
      expect(runJjSync(<String>['new', '-m', 'wip']).exitCode, equals(0));
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

    test('initialize, session/new validation, config options, and malformed JSON / unknown method handling',
        () async {
      final pair = createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final server = AcpServer(peer: serverPeer);
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      final clientNotifications = <Map<String, dynamic>>[];
      final clientPeer = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
        onNotification: (method, params) {
          clientNotifications.add(<String, dynamic>{
            'method': method,
            'params': params,
          });
        },
      );

      // 1. initialize
      final initRes = await clientPeer.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
        'clientInfo': <String, dynamic>{'name': 'test-client', 'version': '1.0'},
        'clientCapabilities': const <String, dynamic>{},
      }) as Map<String, dynamic>;
      expect(initRes['protocolVersion'], equals(1));
      expect(initRes['agentInfo'], isA<Map<String, dynamic>>());

      // 2. session/new rejects non-.jj directory with -32602
      final nonJjDir = Directory.systemTemp.createTempSync('fm_wp8_nojj_');
      addTearDown(() => nonJjDir.deleteSync(recursive: true));
      await expectLater(
        clientPeer.sendRequest('session/new', <String, dynamic>{
          'cwd': nonJjDir.path,
          'mcpServers': const <Object>[],
        }),
        throwsA(
          isA<JsonRpcException>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.invalidParams),
        ),
      );

      // 3. session/new succeeds on valid .jj repo and creates .agent_os/.gitignore
      final newRes = await clientPeer.sendRequest('session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>;
      final sessionId = newRes['sessionId'] as String;
      expect(sessionId, startsWith('sess_'));
      expect(
        File(p.join(repoDir.path, '.agent_os', '.gitignore')).existsSync(),
        isTrue,
      );

      // 4. session/set_config_option updates model & dynamically adds unknown model
      final cfgRes = await clientPeer.sendRequest(
        'session/set_config_option',
        <String, dynamic>{
          'sessionId': sessionId,
          'configId': 'model',
          'value': 'local-ollama/custom-test:7b',
        },
      ) as Map<String, dynamic>;
      final configOptions = cfgRes['configOptions'] as List<dynamic>;
      final modelOpt = configOptions.first as Map<String, dynamic>;
      expect(modelOpt['currentValue'], equals('local-ollama/custom-test:7b'));
      final optionValues = (modelOpt['options'] as List<dynamic>)
          .map((o) => (o as Map<String, dynamic>)['value'])
          .toList();
      expect(optionValues, contains('local-ollama/custom-test:7b'));

      // 5. session/set_mode returns {}
      final modeRes = await clientPeer.sendRequest('session/set_mode', <String, dynamic>{
        'sessionId': sessionId,
        'modeId': 'code',
      }) as Map<String, dynamic>;
      expect(modeRes, isEmpty);

      // 6. Unknown request returns -32601
      await expectLater(
        clientPeer.sendRequest('unknown/method', const <String, dynamic>{}),
        throwsA(
          isA<JsonRpcException>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.methodNotFound),
        ),
      );

      // 7. Unknown notification (e.g. _custom/ping) is ignored safely
      clientPeer.sendNotification('_custom/ping', const <String, dynamic>{'x': 1});

      // 8. Malformed JSON returns -32700 Parse error without crashing server
      pair.clientOut.add(utf8.encode('{bad json line\n'));
      // Verify server still responds to subsequent valid request!
      final statusRes = await clientPeer.sendRequest('_fm_agent_os/status', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
      expect(statusRes['model'], equals('local-ollama/custom-test:7b'));

      // Verify EOF shuts down server cleanly
      await clientPeer.close(closeOutput: true);
      await serverPeer.done.timeout(const Duration(seconds: 5));
    });

    test('raw malformed JSON line emits exact -32700 Parse error frame', () async {
      final pair = createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final server = AcpServer(peer: serverPeer);
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      final lines = <String>[];
      final lineCompleter = Completer<void>();
      final sub = pair.clientIn
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen((line) {
        lines.add(line);
        if (!lineCompleter.isCompleted) {
          lineCompleter.complete();
        }
      });
      addTearDown(sub.cancel);

      pair.clientOut.add(utf8.encode('not-valid-json\n'));
      await lineCompleter.future.timeout(const Duration(seconds: 3));

      expect(lines, hasLength(1));
      final frame = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(frame['jsonrpc'], equals('2.0'));
      expect(frame['id'], isNull);
      final err = frame['error'] as Map<String, dynamic>;
      expect(err['code'], equals(JsonRpcErrorCodes.parseError));
    });

    test('streaming updates, modelOverride precedence, ACP Extensibility compliance, and diff notifications',
        () async {
      final fakeLocal = _ScriptedLlmDriver(
        providerId: LlmProviderId.localOllama,
        handler: (req, step) {
          expect(req.model.canonicalId, equals('local-ollama/qwen3.8:27b'));
          if (step == 0) {
            return <LlmStreamEvent>[
              const LlmThoughtDelta('Checking hello.txt first. '),
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_1',
                  name: 'sys_read_lines',
                  arguments: const <String, dynamic>{
                    'path': '/workspace/hello.txt',
                  },
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  thoughtText: 'Checking hello.txt first. ',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_1',
                      name: 'sys_read_lines',
                      arguments: const <String, dynamic>{
                        'path': '/workspace/hello.txt',
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 100,
                    completionTokens: 20,
                    cachedTokens: 0,
                    durationMs: 50,
                  ),
                ),
              ),
            ];
          }
          if (step == 1) {
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_2',
                  name: 'sys_write_file',
                  arguments: const <String, dynamic>{
                    'path': '/workspace/added.txt',
                    'content': 'added by agent\n',
                  },
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_2',
                      name: 'sys_write_file',
                      arguments: const <String, dynamic>{
                        'path': '/workspace/added.txt',
                        'content': 'added by agent\n',
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 150,
                    completionTokens: 25,
                    cachedTokens: 80,
                    durationMs: 60,
                  ),
                ),
              ),
            ];
          }
          return <LlmStreamEvent>[
            const LlmTextDelta('Done writing added.txt.'),
            LlmDoneEvent(
              LlmChatResponse(
                content: 'Done writing added.txt.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 200,
                  completionTokens: 10,
                  cachedTokens: 140,
                  durationMs: 40,
                ),
              ),
            ),
          ];
        },
      );

      final fakeOpenRouter = _ScriptedLlmDriver(
        providerId: LlmProviderId.openRouter,
        handler: (req, step) {
          expect(req.model.canonicalId, equals('openrouter/anthropic/claude-sonnet-4'));
          return <LlmStreamEvent>[
            const LlmTextDelta('Override reply.'),
            LlmDoneEvent(
              LlmChatResponse(
                content: 'Override reply.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 220,
                  completionTokens: 8,
                  cachedTokens: 100,
                  costMicroUsd: 1200,
                  durationMs: 30,
                ),
              ),
            ),
          ];
        },
      );

      final pair = createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final server = AcpServer(
        peer: serverPeer,
        config: AcpServerConfig(
          startupModel: 'local-ollama/qwen3.8:27b',
          bootstrapFactory: (cfg) => KernelBootstrap.create(
            KernelBootstrapConfig(
              workspaceHostRoot: cfg.workspaceHostRoot,
              sessionId: cfg.sessionId,
              startupModel: cfg.startupModel,
              approvalHandler: cfg.approvalHandler,
              hooks: cfg.hooks,
              onLlmStreamEvent: cfg.onLlmStreamEvent,
              llmDrivers: <LlmProviderId, LlmDriver>{
                LlmProviderId.localOllama: fakeLocal,
                LlmProviderId.openRouter: fakeOpenRouter,
              },
            ),
          ),
        ),
      );
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      final updates = <Map<String, dynamic>>[];
      final clientPeer = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
        onNotification: (method, params) {
          if (method == 'session/update') {
            updates.add(Map<String, dynamic>.from(params['update'] as Map));
          }
        },
      );

      await clientPeer.sendRequest('initialize', const <String, dynamic>{
        'protocolVersion': 1,
      });
      final newRes = await clientPeer.sendRequest('session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>;
      final sessionId = newRes['sessionId'] as String;

      final promptRes = await clientPeer.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Read hello and create added.txt'},
        ],
      }) as Map<String, dynamic>;
      expect(promptRes['stopReason'], equals('end_turn'));

      // Verify stream updates emitted
      final updateKinds = updates.map((u) => u['sessionUpdate']).toList();
      expect(updateKinds, contains('agent_thought_chunk'));
      expect(updateKinds, contains('agent_message_chunk'));
      expect(updateKinds, contains('tool_call'));
      expect(updateKinds, contains('tool_call_update'));
      expect(updateKinds.where((k) => k == 'usage_update').length, equals(3));

      // Verify ACP Extensibility: no custom keys at root of any update object
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
          expect(
            allowedUpdateKeys.contains(key),
            isTrue,
            reason: 'Unexpected non-standard root key "$key" on update: $u',
          );
        }
      }

      // Verify sys_write_file tool_call_update carries ACP diff block & _meta["fm_agent_os/jj"]
      final writeUpdate = updates.firstWhere(
        (u) =>
            u['sessionUpdate'] == 'tool_call_update' &&
            u['toolCallId'] == 'sc_0002',
      );
      expect(writeUpdate['status'], equals('completed'));
      final diffBlocks = (writeUpdate['content'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(diffBlocks.first['type'], equals('diff'));
      expect(diffBlocks.first['oldText'], isNull);
      expect(diffBlocks.first['newText'], equals('added by agent\n'));
      final jjMeta =
          (writeUpdate['_meta'] as Map<String, dynamic>)['fm_agent_os/jj']
              as Map<String, dynamic>;
      expect(jjMeta['jjOpId'], isNotEmpty);
      expect(jjMeta['decision'], equals('ALLOWED'));

      // Verify usage_update omits `cost` when costMicroUsd is null (local-ollama)
      final localUsage = updates.firstWhere(
        (u) => u['sessionUpdate'] == 'usage_update',
      );
      expect(localUsage.containsKey('cost'), isFalse);
      final telemetry =
          (localUsage['_meta'] as Map<String, dynamic>)['fm_agent_os/llmTelemetry']
              as Map<String, dynamic>;
      expect(telemetry['provider'], equals('local-ollama'));
      expect(telemetry['cachedTokens'], equals(0));

      // Verify Priority 1 modelOverride applies for one turn only without overwriting session model
      updates.clear();
      final overrideRes = await clientPeer.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'One turn override'},
        ],
        '_meta': <String, dynamic>{
          'fm_agent_os/modelOverride': 'openrouter/anthropic/claude-sonnet-4',
        },
      }) as Map<String, dynamic>;
      expect(overrideRes['stopReason'], equals('end_turn'));
      final orUsage = updates.firstWhere((u) => u['sessionUpdate'] == 'usage_update');
      expect((orUsage['cost'] as Map<String, dynamic>)['currency'], equals('USD'));
      final statusAfter = await clientPeer.sendRequest('_fm_agent_os/status', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
      expect(statusAfter['model'], equals('local-ollama/qwen3.8:27b'));

      // Verify _fm_agent_os/tx_rollback restores files and resets TxState
      expect(File(p.join(repoDir.path, 'added.txt')).existsSync(), isTrue);
      final rbRes = await clientPeer.sendRequest('_fm_agent_os/tx_rollback', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
      expect(rbRes['restoredOpId'], isNotEmpty);
      expect(rbRes['currentOpId'], isNotEmpty);
      expect(File(p.join(repoDir.path, 'added.txt')).existsSync(), isFalse);
      expect(File(p.join(repoDir.path, 'hello.txt')).readAsStringSync(), equals('hello v1\n'));
    });

    test('Ring 2 approval gate: reject_once has zero side effects (DENIED_BY_USER / EACCES) & allow_once commits squash',
        () async {
      final fakeLocal = _ScriptedLlmDriver(
        providerId: LlmProviderId.localOllama,
        handler: (req, step) {
          if (step == 0) {
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_w',
                  name: 'sys_write_file',
                  arguments: const <String, dynamic>{
                    'path': '/workspace/feature.txt',
                    'content': 'new feature\n',
                  },
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_w',
                      name: 'sys_write_file',
                      arguments: const <String, dynamic>{
                        'path': '/workspace/feature.txt',
                        'content': 'new feature\n',
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 50,
                    completionTokens: 10,
                    durationMs: 10,
                  ),
                ),
              ),
            ];
          }
          if (step == 1) {
            // First squash attempt -> will be rejected by user
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_sq1',
                  name: 'sys_tx_squash',
                  arguments: const <String, dynamic>{'message': 'feat: v1'},
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_sq1',
                      name: 'sys_tx_squash',
                      arguments: const <String, dynamic>{'message': 'feat: v1'},
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 60,
                    completionTokens: 10,
                    durationMs: 10,
                  ),
                ),
              ),
            ];
          }
          if (step == 2) {
            // After EACCES DENIED_BY_USER, agent does NOT crash and tries again / asks user or retries
            return <LlmStreamEvent>[
              const LlmTextDelta('Squash was denied; keeping changes in @.'),
              LlmDoneEvent(
                LlmChatResponse(
                  content: 'Squash was denied; keeping changes in @.',
                  usage: const LlmUsageTelemetry(
                    promptTokens: 70,
                    completionTokens: 10,
                    durationMs: 10,
                  ),
                ),
              ),
            ];
          }
          // Turn 2: user approves squash!
          if (step == 3) {
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_sq2',
                  name: 'sys_tx_squash',
                  arguments: const <String, dynamic>{'message': 'feat: approved'},
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_sq2',
                      name: 'sys_tx_squash',
                      arguments: const <String, dynamic>{'message': 'feat: approved'},
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 80,
                    completionTokens: 10,
                    durationMs: 10,
                  ),
                ),
              ),
            ];
          }
          return <LlmStreamEvent>[
            const LlmTextDelta('Squash committed.'),
            LlmDoneEvent(
              LlmChatResponse(
                content: 'Squash committed.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 90,
                  completionTokens: 10,
                  durationMs: 10,
                ),
              ),
            ),
          ];
        },
      );

      final pair = createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final server = AcpServer(
        peer: serverPeer,
        config: AcpServerConfig(
          startupModel: 'local-ollama/qwen3.8:27b',
          bootstrapFactory: (cfg) => KernelBootstrap.create(
            KernelBootstrapConfig(
              workspaceHostRoot: cfg.workspaceHostRoot,
              sessionId: cfg.sessionId,
              startupModel: cfg.startupModel,
              approvalHandler: cfg.approvalHandler,
              hooks: cfg.hooks,
              onLlmStreamEvent: cfg.onLlmStreamEvent,
              llmDrivers: <LlmProviderId, LlmDriver>{
                LlmProviderId.localOllama: fakeLocal,
              },
            ),
          ),
        ),
      );
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      final permDecisions = <String>['reject_once', 'allow_once'];
      final permRequests = <Map<String, dynamic>>[];
      String? opIdBeforeReject;
      final updates = <Map<String, dynamic>>[];

      final clientPeer = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
        onNotification: (method, params) {
          if (method == 'session/update') {
            updates.add(Map<String, dynamic>.from(params['update'] as Map));
          }
        },
        onRequest: (method, params) async {
          if (method == 'session/request_permission') {
            opIdBeforeReject ??= readHeadOpId();
            permRequests.add(params);
            final choice = permDecisions.removeAt(0);
            return <String, dynamic>{
              'outcome': <String, dynamic>{
                'outcome': 'selected',
                'optionId': choice,
              },
            };
          }
          throw JsonRpcException(JsonRpcErrorCodes.methodNotFound, method);
        },
      );

      await clientPeer.sendRequest('initialize', const <String, dynamic>{
        'protocolVersion': 1,
      });
      final newRes = await clientPeer.sendRequest('session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>;
      final sessionId = newRes['sessionId'] as String;

      // Turn 1: write + squash (rejected)
      final res1 = await clientPeer.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Write feature and squash'},
        ],
      }) as Map<String, dynamic>;
      expect(res1['stopReason'], equals('end_turn'));
      expect(permRequests, hasLength(1));

      // Verify zero side effects from rejected squash: op_id did not advance and tx is still active
      final opIdAfterReject = readHeadOpId();
      expect(opIdAfterReject, equals(opIdBeforeReject));
      final statusMid = await clientPeer.sendRequest('_fm_agent_os/status', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
      expect(statusMid['txState'], equals('active'));

      // Verify tool_call_update recorded DENIED_BY_USER
      final rejectedUpdate = updates.firstWhere(
        (u) =>
            u['sessionUpdate'] == 'tool_call_update' &&
            u['toolCallId'] == 'sc_0002',
      );
      expect(rejectedUpdate['status'], equals('failed'));
      expect(
        ((rejectedUpdate['_meta'] as Map<String, dynamic>)['fm_agent_os/jj']
            as Map<String, dynamic>)['decision'],
        equals('DENIED_BY_USER'),
      );

      // Verify permission request carried ACP diff block for feature.txt
      final permToolCall = permRequests.first['toolCall'] as Map<String, dynamic>;
      expect(permToolCall['kind'], equals('edit'));
      final permContent = (permToolCall['content'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(permContent.any((b) => b['type'] == 'diff'), isTrue);

      // Turn 2: squash (approved)
      final res2 = await clientPeer.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Now squash again'},
        ],
      }) as Map<String, dynamic>;
      expect(res2['stopReason'], equals('end_turn'));
      expect(permRequests, hasLength(2));

      final statusEnd = await clientPeer.sendRequest('_fm_agent_os/status', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
      expect(statusEnd['txState'], equals('readOnly'));

      // Verify syscalls.jsonl recorded both DENIED_BY_USER (EACCES) and APPROVED_BY_USER
      final syscallsFile = File(
        p.join(repoDir.path, '.agent_os', 'logs', sessionId, 'syscalls.jsonl'),
      );
      final records = const LineSplitter()
          .convert(syscallsFile.readAsStringSync())
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      final squashRecords =
          records.where((r) => r['syscallName'] == 'sys_tx_squash').toList();
      expect(squashRecords, hasLength(2));
      expect(squashRecords[0]['decision'], equals('DENIED_BY_USER'));
      expect(squashRecords[0]['errorCode'], equals('EACCES'));
      expect(squashRecords[1]['decision'], equals('APPROVED_BY_USER'));
      expect(squashRecords[1]['ok'], isTrue);
    });

    test('concurrent prompt returns -32000 and session/cancel unlocks WAITING_APPROVAL with stopReason cancelled',
        () async {
      final fakeLocal = _ScriptedLlmDriver(
        providerId: LlmProviderId.localOllama,
        handler: (req, step) {
          return <LlmStreamEvent>[
            LlmToolCallEvent(
              LlmToolCallSpec(
                id: 'call_exec',
                name: 'sys_exec',
                arguments: const <String, dynamic>{
                  'command': 'dart',
                  'args': <String>['--version'],
                },
              ),
            ),
            LlmDoneEvent(
              LlmChatResponse(
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'call_exec',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'dart',
                      'args': <String>['--version'],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 40,
                  completionTokens: 10,
                  durationMs: 10,
                ),
              ),
            ),
          ];
        },
      );

      final pair = createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final server = AcpServer(
        peer: serverPeer,
        config: AcpServerConfig(
          startupModel: 'local-ollama/qwen3.8:27b',
          bootstrapFactory: (cfg) => KernelBootstrap.create(
            KernelBootstrapConfig(
              workspaceHostRoot: cfg.workspaceHostRoot,
              sessionId: cfg.sessionId,
              startupModel: cfg.startupModel,
              approvalHandler: cfg.approvalHandler,
              hooks: cfg.hooks,
              onLlmStreamEvent: cfg.onLlmStreamEvent,
              llmDrivers: <LlmProviderId, LlmDriver>{
                LlmProviderId.localOllama: fakeLocal,
              },
            ),
          ),
        ),
      );
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      final permArrived = Completer<void>();
      final neverRespondingPerm = Completer<Map<String, dynamic>>();

      final clientPeer = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
        onRequest: (method, params) {
          if (method == 'session/request_permission') {
            if (!permArrived.isCompleted) {
              permArrived.complete();
            }
            return neverRespondingPerm.future;
          }
          throw JsonRpcException(JsonRpcErrorCodes.methodNotFound, method);
        },
      );

      await clientPeer.sendRequest('initialize', const <String, dynamic>{
        'protocolVersion': 1,
      });
      final newRes = await clientPeer.sendRequest('session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>;
      final sessionId = newRes['sessionId'] as String;

      final promptFuture = clientPeer.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Run dart --version'},
        ],
      });

      await permArrived.future.timeout(const Duration(seconds: 5));

      // Concurrent session/prompt while active must fail with -32000
      await expectLater(
        clientPeer.sendRequest('session/prompt', <String, dynamic>{
          'sessionId': sessionId,
          'prompt': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'Concurrent'},
          ],
        }),
        throwsA(
          isA<JsonRpcException>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.serverError),
        ),
      );

      // Cancel via session/cancel notification -> prompt resolves with stopReason: "cancelled"
      clientPeer.sendNotification('session/cancel', <String, dynamic>{
        'sessionId': sessionId,
      });

      final promptRes = await promptFuture.timeout(const Duration(seconds: 5))
          as Map<String, dynamic>;
      expect(promptRes['stopReason'], equals('cancelled'));
    });

    test('allow_always remembers signature within session and sys_edit_block emits ACP diff',
        () async {
      final readSha = await HostFsDriver.forWorkspace(repoDir.path)
          .readLines(path: '/workspace/hello.txt')
          .then((r) => r.value!['sha256'] as String);

      final fakeLocal = _ScriptedLlmDriver(
        providerId: LlmProviderId.localOllama,
        handler: (req, step) {
          if (step == 0) {
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_edit',
                  name: 'sys_edit_block',
                  arguments: <String, dynamic>{
                    'path': '/workspace/hello.txt',
                    'expectedSha256': readSha,
                    'oldBlock': 'hello v1',
                    'newBlock': 'hello v2',
                  },
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_edit',
                      name: 'sys_edit_block',
                      arguments: <String, dynamic>{
                        'path': '/workspace/hello.txt',
                        'expectedSha256': readSha,
                        'oldBlock': 'hello v1',
                        'newBlock': 'hello v2',
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 30,
                    completionTokens: 10,
                    durationMs: 5,
                  ),
                ),
              ),
            ];
          }
          if (step == 1 || step == 2) {
            return <LlmStreamEvent>[
              LlmToolCallEvent(
                LlmToolCallSpec(
                  id: 'call_exec_$step',
                  name: 'sys_exec',
                  arguments: const <String, dynamic>{
                    'command': 'dart',
                    'args': <String>['--version'],
                  },
                ),
              ),
              LlmDoneEvent(
                LlmChatResponse(
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'call_exec_$step',
                      name: 'sys_exec',
                      arguments: const <String, dynamic>{
                        'command': 'dart',
                        'args': <String>['--version'],
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 30,
                    completionTokens: 10,
                    durationMs: 5,
                  ),
                ),
              ),
            ];
          }
          return <LlmStreamEvent>[
            const LlmTextDelta('All done.'),
            LlmDoneEvent(
              LlmChatResponse(
                content: 'All done.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 30,
                  completionTokens: 5,
                  durationMs: 5,
                ),
              ),
            ),
          ];
        },
      );

      final pair = createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final server = AcpServer(
        peer: serverPeer,
        config: AcpServerConfig(
          startupModel: 'local-ollama/qwen3.8:27b',
          bootstrapFactory: (cfg) => KernelBootstrap.create(
            KernelBootstrapConfig(
              workspaceHostRoot: cfg.workspaceHostRoot,
              sessionId: cfg.sessionId,
              startupModel: cfg.startupModel,
              approvalHandler: cfg.approvalHandler,
              hooks: cfg.hooks,
              onLlmStreamEvent: cfg.onLlmStreamEvent,
              llmDrivers: <LlmProviderId, LlmDriver>{
                LlmProviderId.localOllama: fakeLocal,
              },
            ),
          ),
        ),
      );
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      var permCount = 0;
      final updates = <Map<String, dynamic>>[];
      final clientPeer = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
        onNotification: (method, params) {
          if (method == 'session/update') {
            updates.add(Map<String, dynamic>.from(params['update'] as Map));
          }
        },
        onRequest: (method, params) async {
          if (method == 'session/request_permission') {
            permCount += 1;
            return <String, dynamic>{
              'outcome': <String, dynamic>{
                'outcome': 'selected',
                'optionId': 'allow_always',
              },
            };
          }
          throw JsonRpcException(JsonRpcErrorCodes.methodNotFound, method);
        },
      );

      await clientPeer.sendRequest('initialize', const <String, dynamic>{
        'protocolVersion': 1,
      });
      final newRes = await clientPeer.sendRequest('session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>;
      final sessionId = newRes['sessionId'] as String;

      final res = await clientPeer.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Edit and run twice'},
        ],
      }) as Map<String, dynamic>;
      expect(res['stopReason'], equals('end_turn'));
      // First `dart --version` prompts, second `dart --version` hits allow_always cache!
      expect(permCount, equals(1));

      final editUpdate = updates.firstWhere(
        (u) =>
            u['sessionUpdate'] == 'tool_call_update' &&
            u['toolCallId'] == 'sc_0001',
      );
      final diffBlock =
          (editUpdate['content'] as List<dynamic>).first as Map<String, dynamic>;
      expect(diffBlock['type'], equals('diff'));
      expect(diffBlock['oldText'], equals('hello v1'));
      expect(diffBlock['newText'], equals('hello v2'));
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
    required this.providerId,
    required this.handler,
  });

  @override
  final LlmProviderId providerId;
  final List<LlmStreamEvent> Function(LlmChatRequest req, int step) handler;
  int _step = 0;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final events = handler(request, _step++);
    for (final ev in events) {
      yield ev;
    }
  }
}
