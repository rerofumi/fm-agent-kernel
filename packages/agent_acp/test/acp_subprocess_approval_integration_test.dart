import 'dart:async';
import 'dart:io';

import 'package:agent_acp/agent_acp.dart';
import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group(
    'ACP Server full-stack subprocess approval integration ([D-707]..[D-711])',
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
        repoDir = Directory.systemTemp.createTempSync('fm_wp4_acp_sub_');
        expect(
          runJjSync(<String>['git', 'init', '--colocate']).exitCode,
          equals(0),
        );
        runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP4 ACP']);
        runJjSync(
          <String>['config', 'set', '--repo', 'user.email', 'wp4@example.com'],
        );
        File(p.join(repoDir.path, '.gitignore'))
            .writeAsStringSync('.agent_os/\n');
        File(p.join(repoDir.path, 'hello.txt')).writeAsStringSync('hello\n');
        expect(
          runJjSync(<String>['describe', '-m', 'base']).exitCode,
          equals(0),
        );
        expect(runJjSync(<String>['new', '-m', 'wip']).exitCode, equals(0));
      });

      tearDown(() async {
        if (repoDir.existsSync()) {
          for (var i = 0; i < 4; i++) {
            try {
              repoDir.deleteSync(recursive: true);
              break;
            } on FileSystemException {
              await Future<void>.delayed(const Duration(milliseconds: 60));
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

      AcpServer createTestServer({
        required _StreamPair pair,
        required LlmDriver llmDriver,
      }) {
        return AcpServer(
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
                onLlmStreamEvent: cfg.onLlmStreamEvent,
                onProcessLlmStreamEvent: cfg.onProcessLlmStreamEvent,
                enableStage2Multiprocess: cfg.enableStage2Multiprocess,
                enableStage3Team: cfg.enableStage3Team,
                execPolicy: cfg.execPolicy,
                llmDrivers: <LlmProviderId, LlmDriver>{
                  LlmProviderId.localOllama: llmDriver,
                },
                childWorkerBackend: const GreenTaskChildWorkerBackend(),
              ),
            ),
          ),
        );
      }

      test(
        'REQ-06: parent sys_wait + child sys_request_approval -> sys_exec emits ACP-compliant _meta, isolates toolCallId, observes waitingApproval via _fm_agent_os/processes, and completes cleanly',
        () async {
          final pair = createStreamPair();
          final llmDriver = _ScriptedMultiProcessLlmDriver((req, callIndex) {
            final isChild = req.prompt.messages.first.content
                .contains('WorkspaceWorker');
            if (!isChild) {
              if (callIndex == 1) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'lead_spawn_1',
                      name: 'sys_spawn',
                      arguments: const <String, dynamic>{
                        'profile': 'workspace_worker',
                        'name': 'worker-acp',
                        'taskPrompt': 'Run where dart with approval',
                        'allowUserApproval': true,
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 20,
                    completionTokens: 10,
                    durationMs: 1,
                  ),
                );
              }
              if (callIndex == 2) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'lead_wait_1',
                      name: 'sys_wait',
                      arguments: const <String, dynamic>{},
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 20,
                    completionTokens: 10,
                    durationMs: 1,
                  ),
                );
              }
              return LlmChatResponse(
                content: 'Child finished with approved command.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 20,
                  completionTokens: 10,
                  durationMs: 1,
                ),
              );
            }

            if (callIndex == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'child_apr_1',
                    name: 'sys_request_approval',
                    arguments: const <String, dynamic>{
                      'syscall': 'sys_exec',
                      'args': <String, dynamic>{
                        'command': 'where',
                        'args': <String>['dart'],
                      },
                      'reason': 'Locate dart binary for verification',
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            if (callIndex == 2) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'child_exec_1',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'where',
                      'args': <String>['dart'],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'child_exit_1',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'Located dart via approved sys_exec',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          });

          final server = createTestServer(pair: pair, llmDriver: llmDriver);
          addTearDown(() async {
            await server.dispose();
            await pair.close();
          });

          final notifications = <Map<String, dynamic>>[];
          final permissionRequests = <Map<String, dynamic>>[];
          final permissionArrived = Completer<void>();
          final allowResponse = Completer<Map<String, dynamic>>();

          final clientPeer = JsonRpcPeer(
            input: pair.clientIn,
            output: pair.clientOut,
            onNotification: (method, params) {
              notifications.add(<String, dynamic>{
                'method': method,
                'params': params,
              });
            },
            onRequest: (method, params) async {
              if (method == 'session/request_permission') {
                permissionRequests
                    .add(Map<String, dynamic>.from(params as Map));
                if (!permissionArrived.isCompleted) {
                  permissionArrived.complete();
                }
                return allowResponse.future;
              }
              throw StateError('Unexpected request: $method');
            },
          );

          await clientPeer.sendRequest('initialize', <String, dynamic>{
            'protocolVersion': 1,
            'clientInfo': <String, dynamic>{
              'name': 'wp4-test',
              'version': '1.0',
            },
            'clientCapabilities': const <String, dynamic>{},
          });
          final newRes = await clientPeer.sendRequest(
            'session/new',
            <String, dynamic>{
              'cwd': repoDir.path,
              'mcpServers': const <Object>[],
            },
          ) as Map<String, dynamic>;
          final sessionId = newRes['sessionId'] as String;

          final promptFuture = clientPeer.sendRequest(
            'session/prompt',
            <String, dynamic>{
              'sessionId': sessionId,
              'prompt': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'text',
                  'text': 'delegate where dart',
                },
              ],
            },
          );

          await permissionArrived.future.timeout(const Duration(seconds: 10));

          // Verify _fm_agent_os/processes shows child in waitingApproval with heartbeat.isPaused == true
          final procsRes = await clientPeer.sendRequest(
            '_fm_agent_os/processes',
            <String, dynamic>{'sessionId': sessionId},
          ) as Map<String, dynamic>;
          final procs = procsRes['processes'] as List<dynamic>;
          expect(procs, hasLength(1));
          final childSnap = procs.first as Map<String, dynamic>;
          expect(childSnap['state'], equals('waitingApproval'));
          expect(
            (childSnap['heartbeat'] as Map<String, dynamic>)['isPaused'],
            isTrue,
          );

          // Verify ACP v1 root key purity & _meta schema
          expect(permissionRequests, hasLength(1));
          final perm = permissionRequests.single;
          expect(
            perm.keys.toSet(),
            equals(
              const <String>{'sessionId', 'toolCall', 'options', '_meta'},
            ),
          );
          final toolCall = perm['toolCall'] as Map<String, dynamic>;
          expect(
            toolCall.keys.toSet().every(
                  const <String>{
                    'toolCallId',
                    'title',
                    'kind',
                    'status',
                    'content',
                  }.contains,
                ),
            isTrue,
          );
          expect(toolCall['title'] as String, contains('Subprocess pid='));
          expect(toolCall['title'] as String, contains('worker-acp'));

          final options = (perm['options'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          expect(options, hasLength(3));
          for (final opt in options) {
            expect(
              opt.keys.toSet(),
              equals(const <String>{'optionId', 'name', 'kind'}),
            );
          }
          final allowAlwaysOpt = options.firstWhere(
            (o) => o['optionId'] == 'allow_always',
          );
          expect(allowAlwaysOpt['name'] as String, contains('pid='));

          final meta =
              (perm['_meta'] as Map<String, dynamic>)['fm_agent_os/approval']
                  as Map<String, dynamic>;
          expect(meta['pid'], isA<int>());
          expect(meta['pid'], isNot(equals(1)));
          expect(meta['profile'], equals('workspace_worker'));
          expect(meta['requestedVia'], equals('sys_request_approval'));
          expect(meta['allowAlwaysScope'], equals('pid'));
          expect(meta['reason'], equals('Locate dart binary for verification'));

          // Respond allow_once
          allowResponse.complete(const <String, dynamic>{
            'outcome': <String, dynamic>{
              'outcome': 'selected',
              'optionId': 'allow_once',
            },
          });

          final promptRes =
              await promptFuture.timeout(const Duration(seconds: 15))
                  as Map<String, dynamic>;
          expect(promptRes['stopReason'], equals('end_turn'));
          // Only 1 permission request (sys_exec consumed the 1-time ticket)
          expect(permissionRequests, hasLength(1));

          // Verify parent sys_wait toolCallId was NOT reused by child permission request
          final sysWaitStarts = notifications.where((n) {
            if (n['method'] != 'session/update') {
              return false;
            }
            final upd =
                (n['params'] as Map<String, dynamic>)['update']
                    as Map<String, dynamic>;
            return upd['sessionUpdate'] == 'tool_call' &&
                (upd['title'] as String).contains('Wait');
          }).toList();
          expect(sysWaitStarts, isNotEmpty);
          final sysWaitToolCallId =
              ((sysWaitStarts.first['params']
                      as Map<String, dynamic>)['update']
                  as Map<String, dynamic>)['toolCallId'] as String;
          expect(toolCall['toolCallId'], isNot(equals(sysWaitToolCallId)));
        },
      );

      test(
        'REQ-06: rejecting child approval (reject_once) does NOT contaminate parent sys_wait tool_call_update status',
        () async {
          final pair = createStreamPair();
          final llmDriver = _ScriptedMultiProcessLlmDriver((req, callIndex) {
            final isChild = req.prompt.messages.first.content
                .contains('WorkspaceWorker');
            if (!isChild) {
              if (callIndex == 1) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'lead_spawn_1',
                      name: 'sys_spawn',
                      arguments: const <String, dynamic>{
                        'profile': 'workspace_worker',
                        'name': 'worker-rej',
                        'taskPrompt': 'try command',
                        'allowUserApproval': true,
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 10,
                    completionTokens: 5,
                    durationMs: 1,
                  ),
                );
              }
              if (callIndex == 2) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'lead_wait_1',
                      name: 'sys_wait',
                      arguments: const <String, dynamic>{},
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 10,
                    completionTokens: 5,
                    durationMs: 1,
                  ),
                );
              }
              return LlmChatResponse(
                content: 'Handled child denial gracefully.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }

            if (callIndex == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'child_exec',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'where',
                      'args': <String>['dart'],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'child_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'user denied exec',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          });

          final server = createTestServer(pair: pair, llmDriver: llmDriver);
          addTearDown(() async {
            await server.dispose();
            await pair.close();
          });

          final notifications = <Map<String, dynamic>>[];
          final clientPeer = JsonRpcPeer(
            input: pair.clientIn,
            output: pair.clientOut,
            onNotification: (method, params) {
              notifications.add(<String, dynamic>{
                'method': method,
                'params': params,
              });
            },
            onRequest: (method, params) async {
              if (method == 'session/request_permission') {
                return const <String, dynamic>{
                  'outcome': <String, dynamic>{
                    'outcome': 'selected',
                    'optionId': 'reject_once',
                  },
                };
              }
              throw StateError('Unexpected request: $method');
            },
          );

          await clientPeer.sendRequest('initialize', <String, dynamic>{
            'protocolVersion': 1,
            'clientInfo': <String, dynamic>{
              'name': 'wp4-rej',
              'version': '1.0',
            },
            'clientCapabilities': const <String, dynamic>{},
          });
          final newRes = await clientPeer.sendRequest(
            'session/new',
            <String, dynamic>{
              'cwd': repoDir.path,
              'mcpServers': const <Object>[],
            },
          ) as Map<String, dynamic>;
          final sessionId = newRes['sessionId'] as String;

          final promptRes = await clientPeer.sendRequest(
            'session/prompt',
            <String, dynamic>{
              'sessionId': sessionId,
              'prompt': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': 'run and deny'},
              ],
            },
          ) as Map<String, dynamic>;
          expect(promptRes['stopReason'], equals('end_turn'));

          // Parent sys_wait tool_call_update MUST be status == 'completed' (NOT 'failed' / DENIED_BY_USER)
          final sysWaitStart = notifications.firstWhere((n) {
            if (n['method'] != 'session/update') {
              return false;
            }
            final upd =
                (n['params'] as Map<String, dynamic>)['update']
                    as Map<String, dynamic>;
            return upd['sessionUpdate'] == 'tool_call' &&
                (upd['title'] as String).contains('Wait');
          });
          final sysWaitId =
              ((sysWaitStart['params'] as Map<String, dynamic>)['update']
                  as Map<String, dynamic>)['toolCallId'] as String;

          final sysWaitEnd = notifications.firstWhere((n) {
            if (n['method'] != 'session/update') {
              return false;
            }
            final upd =
                (n['params'] as Map<String, dynamic>)['update']
                    as Map<String, dynamic>;
            return upd['sessionUpdate'] == 'tool_call_update' &&
                upd['toolCallId'] == sysWaitId;
          });
          final endUpd =
              (sysWaitEnd['params'] as Map<String, dynamic>)['update']
                  as Map<String, dynamic>;
          expect(endUpd['status'], equals('completed'));
        },
      );

      test(
        'REQ-05 & REQ-06: killing first of 2 queued subprocess approvals emits _fm_agent_os/permission_cancelled(pid=2) strictly before session/request_permission(pid=3)',
        () async {
          final pair = createStreamPair();
          final llmDriver = _ScriptedMultiProcessLlmDriver((req, callIndex) {
            final isChild = req.prompt.messages.first.content
                .contains('WorkspaceWorker');
            if (!isChild) {
              if (callIndex == 1) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'lead_sp_1',
                      name: 'sys_spawn',
                      arguments: const <String, dynamic>{
                        'profile': 'workspace_worker',
                        'name': 'worker-1',
                        'taskPrompt': 'first worker',
                        'allowUserApproval': true,
                      },
                    ),
                    LlmToolCallSpec(
                      id: 'lead_sp_2',
                      name: 'sys_spawn',
                      arguments: const <String, dynamic>{
                        'profile': 'workspace_worker',
                        'name': 'worker-2',
                        'taskPrompt': 'second worker',
                        'allowUserApproval': true,
                      },
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 10,
                    completionTokens: 5,
                    durationMs: 1,
                  ),
                );
              }
              if (callIndex == 2) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'lead_wait',
                      name: 'sys_wait',
                      arguments: const <String, dynamic>{},
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 10,
                    completionTokens: 5,
                    durationMs: 1,
                  ),
                );
              }
              return LlmChatResponse(
                content: 'Both workers settled.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }

            if (callIndex == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'c_exec',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'where',
                      'args': <String>['dart'],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'c_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'done',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          });

          final server = createTestServer(pair: pair, llmDriver: llmDriver);
          addTearDown(() async {
            await server.dispose();
            await pair.close();
          });

          final wireEvents = <String>[];
          final firstPermArrived = Completer<int>();
          final firstPermHold = Completer<Map<String, dynamic>>();

          final clientPeer = JsonRpcPeer(
            input: pair.clientIn,
            output: pair.clientOut,
            onNotification: (method, params) {
              if (method == '_fm_agent_os/permission_cancelled') {
                final pid = params['pid'];
                wireEvents.add('cancelled:$pid');
                if (!firstPermHold.isCompleted) {
                  firstPermHold.complete(const <String, dynamic>{
                    'outcome': <String, dynamic>{'outcome': 'cancelled'},
                  });
                }
              }
            },
            onRequest: (method, params) async {
              if (method == 'session/request_permission') {
                final meta = (params['_meta']
                    as Map<String, dynamic>)['fm_agent_os/approval']
                    as Map<String, dynamic>;
                final pid = meta['pid'] as int;
                wireEvents.add('request:$pid');
                if (!firstPermArrived.isCompleted) {
                  firstPermArrived.complete(pid);
                  return firstPermHold.future;
                }
                return const <String, dynamic>{
                  'outcome': <String, dynamic>{
                    'outcome': 'selected',
                    'optionId': 'allow_once',
                  },
                };
              }
              throw StateError('Unexpected request: $method');
            },
          );

          await clientPeer.sendRequest('initialize', <String, dynamic>{
            'protocolVersion': 1,
            'clientInfo': <String, dynamic>{
              'name': 'wp4-fifo',
              'version': '1.0',
            },
            'clientCapabilities': const <String, dynamic>{},
          });
          final newRes = await clientPeer.sendRequest(
            'session/new',
            <String, dynamic>{
              'cwd': repoDir.path,
              'mcpServers': const <Object>[],
            },
          ) as Map<String, dynamic>;
          final sessionId = newRes['sessionId'] as String;

          final promptFuture = clientPeer.sendRequest(
            'session/prompt',
            <String, dynamic>{
              'sessionId': sessionId,
              'prompt': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'text',
                  'text': 'parallel kill order',
                },
              ],
            },
          );

          final firstPid = await firstPermArrived.future
              .timeout(const Duration(seconds: 10));
          // Give the second worker a moment to enqueue behind firstPid
          await Future<void>.delayed(const Duration(milliseconds: 120));

          // Kill firstPid via _fm_agent_os/signal
          await clientPeer.sendRequest('_fm_agent_os/signal', <String, dynamic>{
            'sessionId': sessionId,
            'pid': firstPid,
            'signal': 'SIGKILL',
          });

          final promptRes =
              await promptFuture.timeout(const Duration(seconds: 15))
                  as Map<String, dynamic>;
          expect(promptRes['stopReason'], equals('end_turn'));

          final secondPid = firstPid == 2 ? 3 : 2;
          expect(
            wireEvents,
            equals(<String>[
              'request:$firstPid',
              'cancelled:$firstPid',
              'request:$secondPid',
            ]),
          );
        },
      );
    },
  );
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

class _ScriptedMultiProcessLlmDriver implements LlmDriver {
  _ScriptedMultiProcessLlmDriver(this._handler);

  final LlmChatResponse Function(LlmChatRequest request, int callIndex)
      _handler;
  final Map<String, int> _callsBySessionKey = <String, int>{};

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final key = request.sessionUuid;
    final idx = (_callsBySessionKey[key] ?? 0) + 1;
    _callsBySessionKey[key] = idx;
    final resp = _handler(request, idx);
    for (final tc in resp.toolCalls) {
      yield LlmToolCallEvent(tc);
    }
    if (resp.content.isNotEmpty) {
      yield LlmTextDelta(resp.content);
    }
    yield LlmDoneEvent(resp);
  }
}
