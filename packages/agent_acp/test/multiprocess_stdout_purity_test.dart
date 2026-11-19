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
  group('Multiprocess ACP pid==1 Isolation & AOT stdout Purity [D-210], [D-215]', () {
    late Directory repoDir;

    String findRepoRoot() {
      var dir = Directory.current;
      for (var i = 0; i < 6; i++) {
        if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
            Directory(p.join(dir.path, 'packages', 'agent_acp')).existsSync()) {
          return dir.path;
        }
        dir = dir.parent;
      }
      return Directory.current.path;
    }

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
      repoDir = Directory.systemTemp.createTempSync('fm_wp4_acp_purity_');
      expect(runJjSync(<String>['git', 'init', '--colocate']).exitCode, equals(0));
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP4 Tester']);
      runJjSync(<String>['config', 'set', '--repo', 'user.email', 'wp4@example.com']);
      File(p.join(repoDir.path, 'alpha.txt')).writeAsStringSync('alpha line 1\n');
      File(p.join(repoDir.path, 'beta.txt')).writeAsStringSync('beta line 1\n');
      expect(runJjSync(<String>['describe', '-m', 'seed']).exitCode, equals(0));
      expect(runJjSync(<String>['new', '-m', 'wip']).exitCode, equals(0));
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test('isolates parent ACP session/update and sys_wait tool_call_update from parallel child Isolates (pid == 1 filter)', () async {
      var parentStep = 0;
      final fakeLlm = _RoutingLlmDriver(
        onRequest: (req) {
          final isChild =
              req.prompt.messages.first.content.contains('Ring 3 Explorer');
          if (isChild) {
            final toolResults = req.prompt.messages
                .where((m) => m.role == ProjectedRole.tool)
                .toList();
            final userMsg = req.prompt.messages
                .firstWhere((m) => m.role == ProjectedRole.user)
                .content;
            final targetFile = userMsg.contains('alpha')
                ? '/workspace/alpha.txt'
                : '/workspace/beta.txt';
            if (toolResults.isEmpty) {
              return LlmChatResponse(
                thoughtText: 'CHILD_SECRET_THOUGHT_LEAK_CHECK',
                content: 'CHILD_SECRET_TEXT_LEAK_CHECK',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'cr1',
                    name: 'sys_read_lines',
                    arguments: <String, dynamic>{'path': targetFile},
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 111,
                  completionTokens: 22,
                  durationMs: 5,
                ),
              );
            }
            return LlmChatResponse(
              thoughtText: 'CHILD_SECRET_THOUGHT_LEAK_CHECK_2',
              content: 'Child finished $targetFile.',
              usage: const LlmUsageTelemetry(
                promptTokens: 133,
                completionTokens: 11,
                durationMs: 5,
              ),
            );
          }

          parentStep += 1;
          if (parentStep == 1) {
            return LlmChatResponse(
              thoughtText: 'PARENT_THOUGHT_STEP_1',
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'ps1',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'explorer',
                    'name': 'exp-alpha',
                    'taskPrompt': 'Inspect alpha',
                  },
                ),
                LlmToolCallSpec(
                  id: 'ps2',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'explorer',
                    'name': 'exp-beta',
                    'taskPrompt': 'Inspect beta',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 200,
                completionTokens: 30,
                durationMs: 10,
              ),
            );
          }
          if (parentStep == 2) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'pw1',
                  name: 'sys_wait',
                  arguments: const <String, dynamic>{'timeoutMs': 15000},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 240,
                completionTokens: 15,
                durationMs: 10,
              ),
            );
          }
          return LlmChatResponse(
            content: 'PARENT_FINAL_ANSWER',
            usage: const LlmUsageTelemetry(
              promptTokens: 300,
              completionTokens: 20,
              durationMs: 10,
            ),
          );
        },
      );

      final c2s = StreamController<List<int>>();
      final s2c = StreamController<List<int>>();
      final serverPeer = JsonRpcPeer(input: c2s.stream, output: s2c.sink);
      final server = AcpServer(
        peer: serverPeer,
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
      addTearDown(() async {
        await server.dispose();
        await c2s.close();
        await s2c.close();
      });

      final updates = <Map<String, dynamic>>[];
      final clientPeer = JsonRpcPeer(
        input: s2c.stream,
        output: c2s.sink,
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
          <String, dynamic>{'type': 'text', 'text': 'Inspect alpha and beta'},
        ],
      }) as Map<String, dynamic>;

      expect(promptRes['stopReason'], equals('end_turn'));

      // 1. Zero child thought/text chunks leaked into parent ACP stream.
      final serializedUpdates = jsonEncode(updates);
      expect(serializedUpdates, isNot(contains('CHILD_SECRET_THOUGHT_LEAK_CHECK')));
      expect(serializedUpdates, isNot(contains('CHILD_SECRET_TEXT_LEAK_CHECK')));
      expect(serializedUpdates, contains('PARENT_THOUGHT_STEP_1'));
      expect(serializedUpdates, contains('PARENT_FINAL_ANSWER'));

      // 2. Exactly 3 usage_update notifications (only parent's 3 LLM steps; children's 4 steps excluded).
      final usageUpdates =
          updates.where((u) => u['sessionUpdate'] == 'usage_update').toList();
      expect(usageUpdates.length, equals(3));

      // 3. Parent's sys_wait tool_call_update was NOT overwritten by child sys_read_lines.
      final waitStart = updates.firstWhere(
        (u) =>
            u['sessionUpdate'] == 'tool_call' &&
            (u['title'] as String).startsWith('Wait for children'),
      );
      final waitCallId = waitStart['toolCallId'] as String;
      final waitUpdate = updates.firstWhere(
        (u) =>
            u['sessionUpdate'] == 'tool_call_update' &&
            u['toolCallId'] == waitCallId,
      );
      final waitContentText = jsonEncode(waitUpdate['content']);
      expect(waitContentText, contains('exp-alpha'));
      expect(waitContentText, contains('exp-beta'));
      expect(waitContentText, isNot(contains('alpha line 1')));

      // 4. turnSummary and _fm_agent_os/status report multiprocess + paging metadata.
      final turnSummary =
          (promptRes['_meta'] as Map)['fm_agent_os/turnSummary']
              as Map<String, dynamic>;
      expect(turnSummary['activeChildProcesses'], equals(0));
      expect(turnSummary['spawnedChildrenCount'], equals(2));
      expect(turnSummary['effectiveContextWindow'], equals(32768));

      final statusRes = await clientPeer.sendRequest('_fm_agent_os/status', <String, dynamic>{
        'sessionId': sessionId,
      }) as Map<String, dynamic>;
      expect(statusRes['activeChildProcesses'], equals(0));
      expect(statusRes['spawnedChildrenCount'], equals(2));
    });

    test('compiled agent_os_daemon.exe maintains 100% valid JSON-RPC NDJSON stdout under 3 parallel real Isolates and starts without Dart SDK in PATH', () async {
      final root = findRepoRoot();
      final daemonExe = File(p.join(root, 'build', 'agent_os_daemon.exe'));
      final cliExe = File(p.join(root, 'build', 'acp_cli_client.exe'));

      expect(
        daemonExe.existsSync(),
        isTrue,
        reason:
            'build/agent_os_daemon.exe must be compiled via `dart compile exe` prior to running this test.',
      );
      expect(
        cliExe.existsSync(),
        isTrue,
        reason:
            'build/acp_cli_client.exe must be compiled via `dart compile exe` prior to running this test.',
      );

      // 1. Mock Ollama HTTP server driving 3 parallel Explorer Isolates inside real agent_os_daemon.exe.
      var leadCalls = 0;
      final mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => mockServer.close(force: true));

      unawaited(() async {
        await for (final req in mockServer) {
          req.response.persistentConnection = false;
          final path = req.uri.path;
          if (path.endsWith('/api/ps')) {
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode(<String, dynamic>{
              'models': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'gemma4:12b',
                  'context_length': 32768,
                },
              ],
            }));
            await req.response.close();
            continue;
          }
          if (path.endsWith('/api/chat')) {
            final bodyStr = await utf8.decoder.bind(req).join();
            final body = jsonDecode(bodyStr) as Map<String, dynamic>;
            final messages = (body['messages'] as List<dynamic>)
                .cast<Map<String, dynamic>>();
            final sysText = (messages.first['content'] as String?) ?? '';
            final isChild = sysText.contains('Ring 3 Explorer');

            Map<String, dynamic> msgObj;
            if (!isChild) {
              leadCalls += 1;
              if (leadCalls == 1) {
                msgObj = <String, dynamic>{
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'function': <String, dynamic>{
                        'name': 'sys_spawn',
                        'arguments': <String, dynamic>{
                          'profile': 'explorer',
                          'name': 'iso-1',
                          'taskPrompt': 'Read alpha.txt',
                        },
                      },
                    },
                    <String, dynamic>{
                      'function': <String, dynamic>{
                        'name': 'sys_spawn',
                        'arguments': <String, dynamic>{
                          'profile': 'explorer',
                          'name': 'iso-2',
                          'taskPrompt': 'Read beta.txt',
                        },
                      },
                    },
                    <String, dynamic>{
                      'function': <String, dynamic>{
                        'name': 'sys_spawn',
                        'arguments': <String, dynamic>{
                          'profile': 'explorer',
                          'name': 'iso-3',
                          'taskPrompt': 'Read alpha.txt again',
                        },
                      },
                    },
                  ],
                };
              } else if (leadCalls == 2) {
                msgObj = <String, dynamic>{
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'function': <String, dynamic>{
                        'name': 'sys_wait',
                        'arguments': <String, dynamic>{'timeoutMs': 15000},
                      },
                    },
                  ],
                };
              } else {
                msgObj = <String, dynamic>{
                  'role': 'assistant',
                  'content': 'AOT 3-Isolate run completed cleanly.',
                };
              }
            } else {
              final hasTool = messages.any((m) => m['role'] == 'tool');
              if (!hasTool) {
                msgObj = <String, dynamic>{
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'function': <String, dynamic>{
                        'name': 'sys_read_lines',
                        'arguments': <String, dynamic>{
                          'path': '/workspace/alpha.txt',
                        },
                      },
                    },
                  ],
                };
              } else {
                msgObj = <String, dynamic>{
                  'role': 'assistant',
                  'content': 'Child read alpha.txt successfully.',
                };
              }
            }

            req.response.headers.contentType = ContentType.json;
            req.response.writeln(jsonEncode(<String, dynamic>{
              'model': 'gemma4:12b',
              'message': msgObj,
              'done': true,
              'prompt_eval_count': 100,
              'eval_count': 20,
            }));
            await req.response.close();
            continue;
          }
          req.response.statusCode = 404;
          await req.response.close();
        }
      }());

      // Launch real agent_os_daemon.exe with Dart SDK & mise stripped from PATH!
      final cleanPath = _buildSdkFreePath();
      final proc = await Process.start(
        daemonExe.path,
        <String>[
          '--model',
          'local-ollama/gemma4:12b',
          '--ollama-url',
          'http://127.0.0.1:${mockServer.port}',
        ],
        includeParentEnvironment: false,
        environment: <String, String>{
          'PATH': cleanPath,
          'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'TEMP': Platform.environment['TEMP'] ?? Directory.systemTemp.path,
          'TMP': Platform.environment['TMP'] ?? Directory.systemTemp.path,
          'USERPROFILE': Platform.environment['USERPROFILE'] ?? '',
        },
      );
      addTearDown(() => proc.kill());

      final rawStdoutLines = <String>[];
      final rawStderr = StringBuffer();
      final stdoutDone = Completer<void>();
      final responseById = <int, Completer<Map<String, dynamic>>>{};

      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          rawStdoutLines.add(line);
          // Every single line on stdout MUST be 100% valid JSON-RPC 2.0 NDJSON!
          final decoded = jsonDecode(line) as Map<String, dynamic>;
          expect(decoded['jsonrpc'], equals('2.0'));
          final id = decoded['id'];
          if (id is int && responseById.containsKey(id)) {
            responseById[id]!.complete(decoded);
          }
        },
        onDone: () {
          if (!stdoutDone.isCompleted) {
            stdoutDone.complete();
          }
        },
      );
      proc.stderr.transform(utf8.decoder).listen(rawStderr.write);

      Future<Map<String, dynamic>> sendRpc(
        int id,
        String method,
        Map<String, dynamic> params,
      ) {
        final c = Completer<Map<String, dynamic>>();
        responseById[id] = c;
        proc.stdin.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }));
        return c.future.timeout(const Duration(seconds: 30));
      }

      final initResp = await sendRpc(1, 'initialize', const <String, dynamic>{
        'protocolVersion': 1,
      });
      expect(initResp['error'], isNull);

      final newResp = await sendRpc(2, 'session/new', <String, dynamic>{
        'cwd': repoDir.path,
        'mcpServers': const <Object>[],
      });
      expect(newResp['error'], isNull);
      final sid = (newResp['result'] as Map<String, dynamic>)['sessionId'] as String;

      final promptResp = await sendRpc(3, 'session/prompt', <String, dynamic>{
        'sessionId': sid,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'Spawn 3 isolates and wait'},
        ],
      });
      expect(promptResp['error'], isNull, reason: 'stderr=$rawStderr');
      final resultObj = promptResp['result'] as Map<String, dynamic>;
      expect(resultObj['stopReason'], equals('end_turn'));
      final summary =
          (resultObj['_meta'] as Map)['fm_agent_os/turnSummary']
              as Map<String, dynamic>;
      expect(summary['spawnedChildrenCount'], equals(3));
      expect(summary['activeChildProcesses'], equals(0));

      await proc.stdin.close();
      await stdoutDone.future.timeout(const Duration(seconds: 10));
      final code = await proc.exitCode.timeout(const Duration(seconds: 10));
      expect(code, equals(0), reason: 'stderr=$rawStderr');
      expect(rawStdoutLines, isNotEmpty);

      // Verify acp_cli_client.exe also runs standalone without Dart SDK in PATH.
      final cliHelp = await Process.run(
        cliExe.path,
        const <String>['--help'],
        includeParentEnvironment: false,
        environment: <String, String>{
          'PATH': cleanPath,
          'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'TEMP': Platform.environment['TEMP'] ?? Directory.systemTemp.path,
          'TMP': Platform.environment['TMP'] ?? Directory.systemTemp.path,
        },
      );
      expect(cliHelp.exitCode, equals(0), reason: '${cliHelp.stderr}');
    });

    test('production childIsolateEntryPoint redirects child print() to stderr and traps uncaught errors without polluting AOT stdout', () async {
      final root = findRepoRoot();
      final scratchDir = Directory(
        p.join(root, '.planworks', 'wp4_aot_purity_probe'),
      );
      if (scratchDir.existsSync()) {
        scratchDir.deleteSync(recursive: true);
      }
      scratchDir.createSync(recursive: true);
      addTearDown(() {
        if (scratchDir.existsSync()) {
          scratchDir.deleteSync(recursive: true);
        }
      });

      final probeDart = File(p.join(scratchDir.path, 'purity_probe.dart'));
      final probeExe = File(p.join(scratchDir.path, 'purity_probe.exe'));
      probeDart.writeAsStringSync('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_runtime/agent_runtime.dart';

Future<void> main() async {
  final hostPort = ReceivePort();
  final fatals = <int>[];
  final done = Completer<void>();

  hostPort.listen((dynamic msg) {
    if (msg is Map && msg['type'] == 'worker_fatal') {
      fatals.add(msg['pid'] as int);
      if (fatals.length == 2 && !done.isCompleted) {
        done.complete();
      }
    }
  });

  for (final pid in <int>[2, 3]) {
    await Isolate.spawn<Map<String, Object?>>(
      childIsolateEntryPoint,
      <String, Object?>{
        'hostPort': hostPort.sendPort,
        'pid': pid,
        'diagnosticMode': 'print_and_throw',
      },
    );
  }

  await done.future.timeout(const Duration(seconds: 10));
  hostPort.close();
  stdout.writeln(jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': 1,
    'result': <String, dynamic>{'capturedFatalPids': fatals..sort()},
  }));
  await stdout.flush();
  await stderr.flush();
}
''');

      final dartExe = Platform.resolvedExecutable;
      final compileRes = await Process.run(
        dartExe,
        <String>[
          'compile',
          'exe',
          probeDart.path,
          '-o',
          probeExe.path,
        ],
        workingDirectory: root,
      );
      expect(
        compileRes.exitCode,
        equals(0),
        reason: 'AOT compile failed: ${compileRes.stdout}\n${compileRes.stderr}',
      );

      final runRes = await Process.run(probeExe.path, const <String>[]);
      expect(runRes.exitCode, equals(0), reason: '${runRes.stderr}');

      final stdoutLines = const LineSplitter()
          .convert((runRes.stdout as String).trim())
          .where((l) => l.isNotEmpty)
          .toList();
      // Exactly ONE clean JSON-RPC line on stdout — 0 bytes of child print() or error text!
      expect(stdoutLines.length, equals(1), reason: 'stdout=${runRes.stdout}');
      final parsed = jsonDecode(stdoutLines.single) as Map<String, dynamic>;
      expect(parsed['jsonrpc'], equals('2.0'));
      expect(
        (parsed['result'] as Map)['capturedFatalPids'],
        equals(<int>[2, 3]),
      );

      // Both child print() lines and uncaught error traces must appear on stderr!
      final stderrStr = runRes.stderr as String;
      expect(stderrStr, contains('CHILD_ISOLATE_DIAGNOSTIC_PRINT_PID_2'));
      expect(stderrStr, contains('CHILD_ISOLATE_DIAGNOSTIC_PRINT_PID_3'));
      expect(stderrStr, contains('[agent_os_worker] Unhandled isolate error'));
    });
  });
}

String _buildSdkFreePath() {
  final parentPath = Platform.environment['PATH'] ??
      Platform.environment['Path'] ??
      '';
  final sep = Platform.isWindows ? ';' : ':';
  final kept = <String>[];
  for (final entry in parentPath.split(sep)) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final lower = trimmed.toLowerCase();
    // Strip Dart SDK, Flutter, and mise shims to prove standalone AOT execution.
    if (lower.contains('dart') ||
        lower.contains('flutter') ||
        lower.contains('mise')) {
      continue;
    }
    kept.add(trimmed);
  }
  // Ensure `jj` remains locatable if it was installed under a mise shim path.
  final jjWhich = Process.runSync(
    Platform.isWindows ? 'where' : 'which',
    const <String>['jj'],
  );
  if (jjWhich.exitCode == 0) {
    final firstLine = const LineSplitter()
        .convert((jjWhich.stdout as String).trim())
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    if (firstLine.isNotEmpty) {
      final jjDir = p.dirname(firstLine);
      if (!kept.any((e) => e.toLowerCase() == jjDir.toLowerCase())) {
        kept.add(jjDir);
      }
    }
  }
  return kept.join(sep);
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

class _RoutingLlmDriver implements LlmDriver {
  _RoutingLlmDriver({required this.onRequest});
  final LlmChatResponse Function(LlmChatRequest request) onRequest;

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final resp = onRequest(request);
    if (resp.thoughtText != null && resp.thoughtText!.isNotEmpty) {
      yield LlmThoughtDelta(resp.thoughtText!);
    }
    if (resp.content.isNotEmpty) {
      yield LlmTextDelta(resp.content);
    }
    for (final tc in resp.toolCalls) {
      yield LlmToolCallEvent(tc);
    }
    yield LlmDoneEvent(resp);
  }
}
