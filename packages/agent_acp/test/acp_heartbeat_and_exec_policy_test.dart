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
  group('REQ-03 / REQ-05: ACP _fm_agent_os/processes heartbeat, CLI /ps, and session exec_policy', () {
    late Directory repoDir;

    ProcessResult runJjSync(List<String> args, {String? cwd}) {
      return Process.runSync(
        'jj',
        <String>['--no-pager', ...args],
        workingDirectory: cwd ?? repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
      );
    }

    Directory createTempJjRepo(String prefix) {
      final dir = Directory.systemTemp.createTempSync(prefix);
      final initRes = runJjSync(<String>['git', 'init', '--colocate'], cwd: dir.path);
      expect(initRes.exitCode, equals(0), reason: '${initRes.stderr}');
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP3'], cwd: dir.path);
      runJjSync(
        <String>['config', 'set', '--repo', 'user.email', 'wp3@example.com'],
        cwd: dir.path,
      );
      File(p.join(dir.path, '.gitignore')).writeAsStringSync('.agent_os/\n');
      File(p.join(dir.path, 'README.md')).writeAsStringSync('# sample\n');
      expect(runJjSync(<String>['describe', '-m', 'seed'], cwd: dir.path).exitCode, equals(0));
      expect(runJjSync(<String>['new', '-m', 'wip'], cwd: dir.path).exitCode, equals(0));
      return dir;
    }

    setUp(() {
      repoDir = createTempJjRepo('fm_wp3_acp_hb_');
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        for (var i = 0; i < 4; i++) {
          try {
            repoDir.deleteSync(recursive: true);
            break;
          } on FileSystemException {
            sleep(const Duration(milliseconds: 50));
          }
        }
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
        'ACP _fm_agent_os/processes exposes processes[].heartbeat during non-destructive sys_wait and CLI /ps formats step/idle [D-504]',
        () async {
      final pair = createStreamPair();
      final childGate = Completer<void>();
      final childInStep2 = Completer<void>();
      var leadStep = 0;
      var childStep = 0;

      final fakeLlm = _AsyncRoutingLlmDriver(
        onRequest: (req) async {
          final sysText = req.prompt.messages.first.content;
          if (sysText.contains('Ring 3 Explorer')) {
            childStep += 1;
            if (childStep == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'exp_r1',
                    name: 'sys_read_lines',
                    arguments: const <String, dynamic>{
                      'path': '/workspace/README.md',
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 20,
                  completionTokens: 5,
                  durationMs: 5,
                ),
              );
            }
            if (!childInStep2.isCompleted) {
              childInStep2.complete();
            }
            await childGate.future;
            return LlmChatResponse(
              content: 'Explorer done after gate.',
              usage: const LlmUsageTelemetry(
                promptTokens: 30,
                completionTokens: 5,
                durationMs: 5,
              ),
            );
          }

          leadStep += 1;
          if (leadStep == 1) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'lead_sp',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'explorer',
                    'name': 'slow-exp',
                    'taskPrompt': 'Inspect README',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 20,
                completionTokens: 5,
                durationMs: 5,
              ),
            );
          }
          if (leadStep == 2) {
            // Wait for child to reach step 2 so heartbeat has non-zero steps/syscalls
            await childInStep2.future;
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'lead_wait1',
                  name: 'sys_wait',
                  arguments: const <String, dynamic>{'timeoutMs': 80},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 25,
                completionTokens: 5,
                durationMs: 5,
              ),
            );
          }
          if (leadStep == 3) {
            // Verify first sys_wait timed out non-destructively while child is still active
            final lastTool = req.prompt.messages
                .lastWhere((m) => m.role == ProjectedRole.tool)
                .content;
            final wait1Json = jsonDecode(lastTool) as Map<String, dynamic>;
            expect(wait1Json['timedOut'], isTrue);
            expect((wait1Json['running'] as List), hasLength(1));

            // Allow child to finish only after ACP client inspects _fm_agent_os/processes
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'lead_wait2',
                  name: 'sys_wait',
                  arguments: const <String, dynamic>{'timeoutMs': 15000},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 30,
                completionTokens: 5,
                durationMs: 5,
              ),
            );
          }
          return LlmChatResponse(
            content: 'Collected child cleanly.',
            usage: const LlmUsageTelemetry(
              promptTokens: 35,
              completionTokens: 5,
              durationMs: 5,
            ),
          );
        },
      );

      final server = AcpServer(
        peer: JsonRpcPeer(input: pair.serverIn, output: pair.serverOut),
        config: AcpServerConfig(
          startupModel: 'local-ollama/gemma4:12b',
          bootstrapFactory: (cfg) => KernelBootstrap.create(
            KernelBootstrapConfig(
              workspaceHostRoot: cfg.workspaceHostRoot,
              sessionId: cfg.sessionId,
              startupModel: cfg.startupModel,
              approvalHandler: cfg.approvalHandler,
              hooks: cfg.hooks,
              quota: cfg.quota,
              enableStage2Multiprocess: cfg.enableStage2Multiprocess,
              enableStage3Team: cfg.enableStage3Team,
              execPolicy: cfg.execPolicy,
              onPagingReport: cfg.onPagingReport,
              onLlmStreamEvent: cfg.onLlmStreamEvent,
              contextWindowSource: _StaticWindowSource(32768),
              childWorkerBackend: const IsolateChildWorkerBackend(),
              llmDrivers: <LlmProviderId, LlmDriver>{
                LlmProviderId.localOllama: fakeLlm,
              },
            ),
          ),
        ),
      );
      final client = JsonRpcPeer(input: pair.clientIn, output: pair.clientOut);
      addTearDown(() async {
        if (!childGate.isCompleted) {
          childGate.complete();
        }
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

      final promptFuture = client.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Spawn slow explorer'},
        ],
      });

      await childInStep2.future;
      // Wait slightly so idleMs > 0 and step >= 2
      await Future<void>.delayed(const Duration(milliseconds: 25));

      final procsRes =
          await client.sendRequest('_fm_agent_os/processes', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;

      final processes =
          (procsRes['processes'] as List).cast<Map<String, dynamic>>();
      expect(processes, hasLength(1));
      final proc = processes.single;
      expect(proc['name'], equals('slow-exp'));
      final hb = proc['heartbeat'] as Map<String, dynamic>;
      expect(hb['currentStep'], greaterThanOrEqualTo(2));
      expect(hb['maxSteps'], equals(SpawnSpec.defaultMaxSteps));
      expect(hb['totalSyscalls'], greaterThanOrEqualTo(1));
      expect(hb['idleMs'], isA<int>());
      expect(hb['elapsedMs'], isA<int>());
      expect(hb['heartbeatTimeoutMs'], equals(SpawnSpec.defaultHeartbeatTimeoutMs));
      expect(hb['lastHeartbeatAt'], isA<String>());
      expect(hb['isPaused'], isFalse);
      expect(hb['consecutiveErrors'], equals(0));

      // Verify CLI /ps formatter renders step=X/Y idle=Zms when heartbeat is present
      final cliOut = StringBuffer();
      final cliRunner = AcpCliRunner(
        out: cliOut,
        err: StringBuffer(),
        useAnsiColor: false,
        stdinHasTerminal: false,
      );
      cliRunner.writeProcessesSnapshot(procsRes);
      final psOutput = cliOut.toString();
      expect(
        psOutput,
        contains('step=${hb['currentStep']}/${hb['maxSteps']} idle=${hb['idleMs']}ms'),
      );

      // Verify CLI /ps omits step/idle cleanly when heartbeat is absent
      final noHbOut = StringBuffer();
      AcpCliRunner(
        out: noHbOut,
        err: StringBuffer(),
        useAnsiColor: false,
        stdinHasTerminal: false,
      ).writeProcessesSnapshot(<String, dynamic>{
        'lead': procsRes['lead'],
        'processes': <Map<String, dynamic>>[
          <String, dynamic>{
            'pid': 9,
            'profile': 'explorer',
            'state': 'pending',
            'model': 'local-ollama/gemma4:12b',
          },
        ],
      });
      expect(noHbOut.toString(), isNot(contains('step=')));

      // Release child gate and verify second sys_wait completes the turn
      childGate.complete();
      final promptRes = await promptFuture as Map<String, dynamic>;
      expect(promptRes['stopReason'], equals('end_turn'));
    });

    test(
        'AcpServer loads <sessionCwd>/.agent_os/exec_policy.json per session/new, preserves session immutability, and honors AcpServerConfig.execPolicy DI [D-510]',
        () async {
      final repoA = createTempJjRepo('fm_wp3_acp_pol_a_');
      final repoB = createTempJjRepo('fm_wp3_acp_pol_b_');
      addTearDown(() {
        if (repoA.existsSync()) repoA.deleteSync(recursive: true);
        if (repoB.existsSync()) repoB.deleteSync(recursive: true);
      });

      Directory(p.join(repoA.path, '.agent_os')).createSync(recursive: true);
      File(p.join(repoA.path, '.agent_os', 'exec_policy.json'))
          .writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'allow': <Map<String, dynamic>>[
            <String, dynamic>{'command': 'hostname', 'maxTimeoutMs': 20000},
          ],
        }),
      );

      final capturedBootstraps = <String, KernelBootstrap>{};
      final pair = createStreamPair();
      final server = AcpServer(
        peer: JsonRpcPeer(input: pair.serverIn, output: pair.serverOut),
        config: AcpServerConfig(
          startupModel: 'local-ollama/gemma4:12b',
          bootstrapFactory: (cfg) {
            final b = KernelBootstrap.create(
              KernelBootstrapConfig(
                workspaceHostRoot: cfg.workspaceHostRoot,
                sessionId: cfg.sessionId,
                startupModel: cfg.startupModel,
                approvalHandler: cfg.approvalHandler,
                hooks: cfg.hooks,
                quota: cfg.quota,
                enableStage2Multiprocess: cfg.enableStage2Multiprocess,
                enableStage3Team: cfg.enableStage3Team,
                execPolicy: cfg.execPolicy,
                contextWindowSource: _StaticWindowSource(32768),
                llmDrivers: <LlmProviderId, LlmDriver>{
                  LlmProviderId.localOllama: _AsyncRoutingLlmDriver(
                    onRequest: (_) async => LlmChatResponse(
                      content: 'ok',
                      usage: const LlmUsageTelemetry(
                        promptTokens: 1,
                        completionTokens: 1,
                        durationMs: 1,
                      ),
                    ),
                  ),
                },
              ),
            );
            capturedBootstraps[cfg.sessionId!] = b;
            return b;
          },
        ),
      );
      final client = JsonRpcPeer(input: pair.clientIn, output: pair.clientOut);
      addTearDown(() async {
        await server.dispose();
        await pair.close();
      });

      await client.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });

      final sessA = (await client.sendRequest('session/new', <String, dynamic>{
        'cwd': repoA.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>)['sessionId'] as String;
      final sessB = (await client.sendRequest('session/new', <String, dynamic>{
        'cwd': repoB.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>)['sessionId'] as String;

      expect(
        capturedBootstraps[sessA]!.execPolicy.allow.map((r) => r.normalizedCommand),
        equals(<String>['hostname']),
      );
      expect(capturedBootstraps[sessB]!.execPolicy.allow, isEmpty);

      // Modify repoA/.agent_os/exec_policy.json on disk:
      // Existing session A stays immutable; a fresh session/new reloads the updated policy.
      File(p.join(repoA.path, '.agent_os', 'exec_policy.json'))
          .writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'allow': <Map<String, dynamic>>[
            <String, dynamic>{'command': 'where', 'maxTimeoutMs': 25000},
          ],
        }),
      );
      expect(
        capturedBootstraps[sessA]!.execPolicy.allow.map((r) => r.normalizedCommand),
        equals(<String>['hostname']),
      );

      final sessA2 = (await client.sendRequest('session/new', <String, dynamic>{
        'cwd': repoA.path,
        'mcpServers': const <Object>[],
      }) as Map<String, dynamic>)['sessionId'] as String;
      expect(
        capturedBootstraps[sessA2]!.execPolicy.allow.map((r) => r.normalizedCommand),
        equals(<String>['where']),
      );

      // Explicit AcpServerConfig.execPolicy DI overrides disk config
      final pairDi = createStreamPair();
      final diBootstraps = <KernelBootstrap>[];
      final diPolicy = ExecPolicyConfig(
        allow: <ExecAllowRule>[
          ExecAllowRule(command: 'injected_tool', maxTimeoutMs: 15000),
        ],
      );
      final diServer = AcpServer(
        peer: JsonRpcPeer(input: pairDi.serverIn, output: pairDi.serverOut),
        config: AcpServerConfig(
          startupModel: 'local-ollama/gemma4:12b',
          execPolicy: diPolicy,
          bootstrapFactory: (cfg) {
            final b = KernelBootstrap.create(
              KernelBootstrapConfig(
                workspaceHostRoot: cfg.workspaceHostRoot,
                sessionId: cfg.sessionId,
                startupModel: cfg.startupModel,
                approvalHandler: cfg.approvalHandler,
                hooks: cfg.hooks,
                quota: cfg.quota,
                enableStage2Multiprocess: cfg.enableStage2Multiprocess,
                enableStage3Team: cfg.enableStage3Team,
                execPolicy: cfg.execPolicy,
                contextWindowSource: _StaticWindowSource(32768),
                llmDrivers: <LlmProviderId, LlmDriver>{
                  LlmProviderId.localOllama: _AsyncRoutingLlmDriver(
                    onRequest: (_) async => LlmChatResponse(
                      content: 'ok',
                      usage: const LlmUsageTelemetry(
                        promptTokens: 1,
                        completionTokens: 1,
                        durationMs: 1,
                      ),
                    ),
                  ),
                },
              ),
            );
            diBootstraps.add(b);
            return b;
          },
        ),
      );
      final diClient =
          JsonRpcPeer(input: pairDi.clientIn, output: pairDi.clientOut);
      addTearDown(() async {
        await diServer.dispose();
        await pairDi.close();
      });

      await diClient.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });
      await diClient.sendRequest('session/new', <String, dynamic>{
        'cwd': repoA.path,
        'mcpServers': const <Object>[],
      });
      expect(
        diBootstraps.single.execPolicy.allow.map((r) => r.normalizedCommand),
        equals(<String>['injected_tool']),
      );
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

class _StaticWindowSource implements ContextWindowSource {
  _StaticWindowSource(this.windowTokens);
  final int windowTokens;

  @override
  Future<ContextWindowSpec> resolve(
    ModelIdentifier model, {
    bool forceRefreshPs = false,
  }) async {
    return ContextWindowSpec(
      contextWindowTokens: windowTokens,
      source: 'test_static',
      isLoadedExact: true,
    );
  }
}

class _AsyncRoutingLlmDriver implements LlmDriver {
  _AsyncRoutingLlmDriver({required this.onRequest});
  final Future<LlmChatResponse> Function(LlmChatRequest request) onRequest;

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final resp = await onRequest(request);
    if (resp.content.isNotEmpty) {
      yield LlmTextDelta(resp.content);
    }
    for (final tc in resp.toolCalls) {
      yield LlmToolCallEvent(tc);
    }
    yield LlmDoneEvent(resp);
  }
}
