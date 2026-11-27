import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Isolate Multiprocess Execution & BoundedMailbox IPC [D-210]..[D-212], [D-215]', () {
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
      repoDir = Directory.systemTemp.createTempSync('fm_wp4_iso_ipc_');
      expect(runJjSync(<String>['git', 'init', '--colocate']).exitCode, equals(0));
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP4 Tester']);
      runJjSync(<String>['config', 'set', '--repo', 'user.email', 'wp4@example.com']);

      for (final pkg in <String>['pkg_a', 'pkg_b', 'pkg_c']) {
        final dir = Directory(p.join(repoDir.path, 'packages', pkg))
          ..createSync(recursive: true);
        File(p.join(dir.path, 'info.txt')).writeAsStringSync(
          'Package $pkg secret-free content line 1\nLine 2 of $pkg\n',
        );
      }
      expect(runJjSync(<String>['describe', '-m', 'seed']).exitCode, equals(0));
      expect(runJjSync(<String>['new', '-m', 'wip']).exitCode, equals(0));
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test('runs 3 parallel real Isolate Explorers with IPC roundtrip, sys_wait reaping, and audit attribution', () async {
      final opIdBefore = readHeadOpId();
      var leadStep = 0;

      final fakeLlm = _RoutingFakeLlmDriver(
        onRequest: (req) {
          final isChild = req.prompt.messages.first.content.contains('Ring 3 Explorer');
          if (!isChild) {
            leadStep += 1;
            if (leadStep == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'sp_1',
                    name: 'sys_spawn',
                    arguments: const <String, dynamic>{
                      'profile': 'explorer',
                      'name': 'exp-a',
                      'taskPrompt': 'Inspect pkg_a',
                      'allowedSubpaths': <String>['/workspace/packages/pkg_a'],
                    },
                  ),
                  LlmToolCallSpec(
                    id: 'sp_2',
                    name: 'sys_spawn',
                    arguments: const <String, dynamic>{
                      'profile': 'explorer',
                      'name': 'exp-b',
                      'taskPrompt': 'Inspect pkg_b',
                      'allowedSubpaths': <String>['/workspace/packages/pkg_b'],
                    },
                  ),
                  LlmToolCallSpec(
                    id: 'sp_3',
                    name: 'sys_spawn',
                    arguments: const <String, dynamic>{
                      'profile': 'explorer',
                      'name': 'exp-c',
                      'taskPrompt': 'Inspect pkg_c',
                      'allowedSubpaths': <String>['/workspace/packages/pkg_c'],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 200,
                  completionTokens: 40,
                  durationMs: 10,
                ),
              );
            }
            if (leadStep == 2) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'wt_1',
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
            if (leadStep == 3) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'rc_1',
                    name: 'sys_recv',
                    arguments: const <String, dynamic>{'maxMessages': 10},
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 280,
                  completionTokens: 15,
                  durationMs: 10,
                ),
              );
            }
            return LlmChatResponse(
              content: 'Integrated summary from 3 parallel Explorer Isolates.',
              usage: const LlmUsageTelemetry(
                promptTokens: 310,
                completionTokens: 20,
                durationMs: 10,
              ),
            );
          }

          // Child Explorer logic: step 1 reads file + jj status, step 2 sends IPC to parent, step 3 sys_exit.
          final userMsg = req.prompt.messages
              .firstWhere((m) => m.role == ProjectedRole.user)
              .content;
          final pkg = userMsg.contains('pkg_a')
              ? 'pkg_a'
              : (userMsg.contains('pkg_b') ? 'pkg_b' : 'pkg_c');
          final toolResults = req.prompt.messages
              .where((m) => m.role == ProjectedRole.tool)
              .toList();

          if (toolResults.isEmpty) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'r1',
                  name: 'sys_read_lines',
                  arguments: <String, dynamic>{
                    'path': '/workspace/packages/$pkg/info.txt',
                  },
                ),
                LlmToolCallSpec(
                  id: 'j1',
                  name: 'sys_jj_status',
                  arguments: const <String, dynamic>{},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 120,
                completionTokens: 20,
                durationMs: 10,
              ),
            );
          }
          if (toolResults.length == 2) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 's1',
                  name: 'sys_send',
                  arguments: <String, dynamic>{
                    'toPid': 1,
                    'schemaType': 'finding',
                    'payload': <String, dynamic>{'pkg': pkg, 'ok': true},
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 160,
                completionTokens: 15,
                durationMs: 10,
              ),
            );
          }
          return LlmChatResponse(
            content: '',
            toolCalls: <LlmToolCallSpec>[
              LlmToolCallSpec(
                id: 'e1',
                name: 'sys_exit',
                arguments: <String, dynamic>{
                  'exitCode': 0,
                  'summary': 'Summary for $pkg: verified info.txt cleanly.',
                },
              ),
            ],
            usage: const LlmUsageTelemetry(
              promptTokens: 180,
              completionTokens: 15,
              durationMs: 10,
            ),
          );
        },
      );

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          quota: ResourceQuota.stage2Default,
          enableStage2Multiprocess: true,
          childWorkerBackend: const IsolateChildWorkerBackend(),
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: fakeLlm,
          },
        ),
      );
      addTearDown(bootstrap.dispose);

      final turnRes = await bootstrap.processRunner.submitPrompt(
        userInput: 'Inspect pkg_a, pkg_b, and pkg_c in parallel.',
      );
      expect(turnRes.ok, isTrue, reason: '${turnRes.error}');
      expect(turnRes.finalText, contains('3 parallel Explorer Isolates'));
      expect(bootstrap.pcb.quotaUsage.activeChildProcesses, equals(0));
      expect(bootstrap.workerHost!.activeChildCount, equals(0));
      expect(bootstrap.workerHost!.spawnedChildrenCount, equals(3));

      // Verify jj op log remained strictly unchanged ([D-204]).
      expect(readHeadOpId(), equals(opIdBefore));

      await bootstrap.auditLogger.flush();

      // Verify syscalls.jsonl attribution & zero corruption.
      final syscallsLines = File(bootstrap.auditLogger.syscallsLogPath)
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      final childPids = syscallsLines
          .where((r) => r['parentPid'] == 1 && r['ring'] == 'ring3')
          .map((r) => r['pid'] as int)
          .toSet();
      expect(childPids.length, equals(3));

      // Verify llm_io.jsonl has pid/parentPid/processName/ring for both parent and 3 children.
      final llmLines = File(bootstrap.auditLogger.llmIoLogPath)
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      final llmChildPids = llmLines
          .where((r) => r['parentPid'] == 1 && r['ring'] == 'ring3')
          .map((r) => r['pid'] as int)
          .toSet();
      expect(llmChildPids, equals(childPids));

      // Verify parent received 3 IPC messages via sys_recv.
      final recvToolTurn = bootstrap.pcb.memory.historySegment.turns
          .whereType<CanonicalToolResultTurn>()
          .firstWhere((t) => t.toolName == 'sys_recv');
      final recvJson = jsonDecode(recvToolTurn.content) as Map<String, dynamic>;
      final sendRecords = syscallsLines
          .where((r) => r['syscallName'] == 'sys_send')
          .toList();
      expect(
        (recvJson['messages'] as List).length,
        equals(3),
        reason: 'sendRecords=$sendRecords, recvJson=$recvJson, childRecords=${syscallsLines.where((r) => r['parentPid'] == 1).map((r) => '${r['pid']}:${r['syscallName']}:${r['ok']}:${r['errorReason']}').toList()}',
      );
    });

    test(
      'releases process slots across repeated normal child exits (issue #2)',
      () async {
        final exits = _ChildExitObserver();
        var childRequests = 0;
        final bootstrap = KernelBootstrap.create(
          KernelBootstrapConfig(
            workspaceHostRoot: repoDir.path,
            startupModel: 'local-ollama/gemma4:12b',
            quota: ResourceQuota.stage2Default,
            enableStage2Multiprocess: true,
            childWorkerBackend: const IsolateChildWorkerBackend(),
            contextWindowSource: _StaticWindowSource(32768),
            hooks: <SyscallHook>[exits],
            llmDrivers: <LlmProviderId, LlmDriver>{
              LlmProviderId.localOllama: _RoutingFakeLlmDriver(
                onRequest: (_) {
                  childRequests += 1;
                  // Exercise both explicit sys_exit and the implicit sys_exit
                  // issued for a final text response.
                  final explicitExit = childRequests.isOdd;
                  return LlmChatResponse(
                    content: explicitExit ? '' : 'Finished normally.',
                    toolCalls: explicitExit
                        ? <LlmToolCallSpec>[
                            LlmToolCallSpec(
                              id: 'exit',
                              name: 'sys_exit',
                              arguments: const <String, dynamic>{
                                'exitCode': 0,
                                'summary': 'Finished normally.',
                              },
                            ),
                          ]
                        : const <LlmToolCallSpec>[],
                    usage: const LlmUsageTelemetry(
                      promptTokens: 10,
                      completionTokens: 5,
                      durationMs: 1,
                    ),
                  );
                },
              ),
            },
          ),
        );
        addTearDown(bootstrap.dispose);
        final parentCtx = SyscallContext(
          pid: 1,
          capHandle: bootstrap.capHandle,
          sessionId: bootstrap.sessionId,
        );

        // Exceed the process table's capacity cumulatively while keeping only
        // one child alive at a time. A leaked PCB used to reject child #16.
        final iterations = bootstrap.processTable.maxActiveProcesses + 4;
        for (var i = 0; i < iterations; i++) {
          final spawn = await bootstrap.syscallGate.invoke(
            parentCtx,
            SyscallRequest(
              name: 'sys_spawn',
              args: const <String, dynamic>{
                'profile': 'explorer',
                'taskPrompt': 'Finish immediately.',
              },
            ),
          );
          expect(spawn.ok, isTrue, reason: 'Child #${i + 1}: ${spawn.error}');
          final pid = spawn.value!['childPid'] as int;
          final wait = await bootstrap.syscallGate.invoke(
            parentCtx,
            SyscallRequest(
              name: 'sys_wait',
              args: <String, dynamic>{
                'pids': <int>[pid],
                'timeoutMs': 5000,
              },
            ),
          );
          expect(wait.ok, isTrue, reason: '${wait.error}');
          final status = (wait.value!['children'] as List).single as Map;
          expect(status['ok'], isTrue);
          expect(status['reason'], 'EXITED_NORMALLY');
          // sys_wait can observe completion before sys_exit unwinds through
          // SyscallGate. Synchronize on Stage 6 rather than a timing delay.
          await exits.observed(pid).timeout(const Duration(seconds: 5));
          expect(
            bootstrap.processTable.getProcess(pid)!.state,
            ProcessState.terminated,
          );
          expect(bootstrap.pcb.quotaUsage.activeChildProcesses, 0);
          expect(bootstrap.workerHost!.activeChildCount, 0);
          expect(bootstrap.processTable.activeChildrenOf(1), isEmpty);
          expect(
            bootstrap.processTable.processes.values
                .where((pcb) => pcb.state != ProcessState.terminated)
                .map((pcb) => pcb.pid),
            <int>[1],
          );
        }
        expect(bootstrap.workerHost!.spawnedChildrenCount, iterations);
        final reaped = await bootstrap.syscallGate.invoke(
          parentCtx,
          SyscallRequest(name: 'sys_wait'),
        );
        expect(reaped.ok, isTrue);
        expect(reaped.value!['children'], isEmpty);
      },
    );

    test('enforces BoundedMailbox limits (32 -> MAILBOX_FULL recoverable, >64KiB -> EINVAL, sibling -> EPERM, control priority)', () async {
      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          quota: ResourceQuota.stage2Default,
          enableStage2Multiprocess: true,
          childWorkerBackend: const GreenTaskChildWorkerBackend(),
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: _BlockingFakeLlmDriver(),
          },
        ),
      );
      addTearDown(bootstrap.dispose);

      final parentCtx = SyscallContext(
        pid: 1,
        capHandle: bootstrap.capHandle,
        sessionId: bootstrap.sessionId,
      );

      final sp1 = await bootstrap.syscallGate.invoke(
        parentCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Stay alive 1',
          },
        ),
      );
      final sp2 = await bootstrap.syscallGate.invoke(
        parentCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Stay alive 2',
          },
        ),
      );
      expect(sp1.ok, isTrue);
      expect(sp2.ok, isTrue);
      final child1Pid = sp1.value!['childPid'] as int;
      final child2Pid = sp2.value!['childPid'] as int;

      // 1. Sibling-to-sibling IPC must be denied with EPERM: IPC_TARGET_FORBIDDEN.
      final child1Ctx = SyscallContext(
        pid: child1Pid,
        capHandle: const CapHandle('cap_explorer'),
        sessionId: bootstrap.sessionId,
      );
      final siblingSend = await bootstrap.syscallGate.invoke(
        child1Ctx,
        SyscallRequest(
          name: 'sys_send',
          args: <String, dynamic>{
            'toPid': child2Pid,
            'payload': 'horizontal leak',
          },
        ),
      );
      expect(siblingSend.ok, isFalse);
      expect(siblingSend.error!.code, equals(SyscallErrorCode.eperm));
      expect(siblingSend.error!.reason, equals('IPC_TARGET_FORBIDDEN'));

      // 2. Payload > 64 KiB -> EINVAL: IPC_PAYLOAD_TOO_LARGE.
      final hugeSend = await bootstrap.syscallGate.invoke(
        parentCtx,
        SyscallRequest(
          name: 'sys_send',
          args: <String, dynamic>{
            'toPid': child1Pid,
            'payload': 'X' * 70000,
          },
        ),
      );
      expect(hugeSend.ok, isFalse);
      expect(hugeSend.error!.code, equals(SyscallErrorCode.einval));
      expect(hugeSend.error!.reason, equals('IPC_PAYLOAD_TOO_LARGE'));

      // 3. Fill child1 mailbox to 32 messages, then 33rd -> EDQUOT: MAILBOX_FULL (recoverable: true).
      for (var i = 0; i < 32; i++) {
        final r = await bootstrap.syscallGate.invoke(
          parentCtx,
          SyscallRequest(
            name: 'sys_send',
            args: <String, dynamic>{
              'toPid': child1Pid,
              'payload': 'msg_$i',
            },
          ),
        );
        expect(r.ok, isTrue, reason: 'msg $i failed: ${r.error}');
      }
      final overflow = await bootstrap.syscallGate.invoke(
        parentCtx,
        SyscallRequest(
          name: 'sys_send',
          args: <String, dynamic>{
            'toPid': child1Pid,
            'payload': 'msg_33',
          },
        ),
      );
      expect(overflow.ok, isFalse);
      expect(overflow.error!.code, equals(SyscallErrorCode.edquot));
      expect(overflow.error!.reason, equals('MAILBOX_FULL'));
      expect(overflow.error!.recoverable, isTrue);

      // 4. Control signal lane still delivers immediately even when data lane is full.
      final child1Pcb = bootstrap.processTable.getProcess(child1Pid)!;
      child1Pcb.mailbox.enqueueControl(
        ControlSignalMessage(kind: ControlSignalKind.cancel, fromPid: 1),
      );
      expect(child1Pcb.mailbox.hasControlSignals, isTrue);
      expect(
        child1Pcb.mailbox.dequeueControl()!.kind,
        equals(ControlSignalKind.cancel),
      );

      await bootstrap.workerHost!.terminateActiveChildrenForParent(1);
      expect(bootstrap.pcb.quotaUsage.activeChildProcesses, equals(0));
    });

    test('reaps crashed child Isolate, unreaped children via onTurnExitCleanup, and active children on cancelActiveTurn', () async {
      // Case A: Child Isolate throws uncaught exception -> host captures crash, parent survives.
      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          quota: ResourceQuota.stage2Default,
          enableStage2Multiprocess: true,
          childWorkerBackend: const IsolateChildWorkerBackend(),
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: _BlockingFakeLlmDriver(),
          },
        ),
      );
      addTearDown(bootstrap.dispose);

      final execCtx = SyscallExecutionContext(
        syscallSeq: 1,
        context: SyscallContext(
          pid: 1,
          capHandle: bootstrap.capHandle,
          sessionId: bootstrap.sessionId,
        ),
        pcb: bootstrap.pcb,
        syscallName: 'sys_spawn',
        args: const <String, dynamic>{},
      );

      final crashSpawn = await bootstrap.workerHost!.spawnChild(
        execCtx,
        SpawnSpec(
          profile: ProcessProfileId.explorer,
          taskPrompt: 'Crash test',
        ),
        diagnosticMode: 'print_and_throw',
      );
      expect(crashSpawn.ok, isTrue);
      final crashPid = crashSpawn.value!['childPid'] as int;

      final waitCrash = await bootstrap.workerHost!.waitForChildren(
        execCtx,
        pids: <int>[crashPid],
        timeoutMs: 10000,
      );
      expect(waitCrash.ok, isTrue);
      final crashChild = (waitCrash.value!['children'] as List).single
          as Map<String, dynamic>;
      expect(crashChild['ok'], isFalse);
      expect(crashChild['reason'], equals('WORKER_CRASHED'));
      expect(bootstrap.pcb.quotaUsage.activeChildProcesses, equals(0));

      // Case B: Parent finishes turn WITHOUT calling sys_wait -> onTurnExitCleanup kills & settles child.
      var leadStep = 0;
      final orphanBootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          quota: ResourceQuota.stage2Default,
          enableStage2Multiprocess: true,
          childWorkerBackend: const IsolateChildWorkerBackend(),
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: _RoutingFakeLlmDriver(
              onRequest: (req) {
                final isChild =
                    req.prompt.messages.first.content.contains('Ring 3 Explorer');
                if (isChild) {
                  // Child takes a while (blocked until killed).
                  return LlmChatResponse(
                    content: '',
                    toolCalls: <LlmToolCallSpec>[
                      LlmToolCallSpec(
                        id: 'c_wait',
                        name: 'sys_recv',
                        arguments: const <String, dynamic>{'waitTimeoutMs': 15000},
                      ),
                    ],
                    usage: const LlmUsageTelemetry(
                      promptTokens: 50,
                      completionTokens: 10,
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
                        id: 'sp_orphan',
                        name: 'sys_spawn',
                        arguments: const <String, dynamic>{
                          'profile': 'explorer',
                          'taskPrompt': 'Long running orphan',
                        },
                      ),
                    ],
                    usage: const LlmUsageTelemetry(
                      promptTokens: 50,
                      completionTokens: 10,
                      durationMs: 5,
                    ),
                  );
                }
                return LlmChatResponse(
                  content: 'Returning without sys_wait.',
                  usage: const LlmUsageTelemetry(
                    promptTokens: 60,
                    completionTokens: 10,
                    durationMs: 5,
                  ),
                );
              },
            ),
          },
        ),
      );
      addTearDown(orphanBootstrap.dispose);

      final orphanTurn = await orphanBootstrap.processRunner.submitPrompt(
        userInput: 'Spawn and forget',
      );
      expect(orphanTurn.ok, isTrue);
      expect(orphanBootstrap.pcb.quotaUsage.activeChildProcesses, equals(0));
      expect(orphanBootstrap.workerHost!.activeChildCount, equals(0));

      // Case C: cancelActiveTurn() while parent is blocked in sys_wait -> immediate kill & ECANCELLED.
      var cancelStep = 0;
      final cancelBootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          quota: ResourceQuota.stage2Default,
          enableStage2Multiprocess: true,
          childWorkerBackend: const IsolateChildWorkerBackend(),
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: _RoutingFakeLlmDriver(
              onRequest: (req) {
                final isChild =
                    req.prompt.messages.first.content.contains('Ring 3 Explorer');
                if (isChild) {
                  return LlmChatResponse(
                    content: '',
                    toolCalls: <LlmToolCallSpec>[
                      LlmToolCallSpec(
                        id: 'c_sleep',
                        name: 'sys_recv',
                        arguments: const <String, dynamic>{'waitTimeoutMs': 25000},
                      ),
                    ],
                    usage: const LlmUsageTelemetry(
                      promptTokens: 50,
                      completionTokens: 10,
                      durationMs: 5,
                    ),
                  );
                }
                cancelStep += 1;
                if (cancelStep == 1) {
                  return LlmChatResponse(
                    content: '',
                    toolCalls: <LlmToolCallSpec>[
                      LlmToolCallSpec(
                        id: 'sp_c',
                        name: 'sys_spawn',
                        arguments: const <String, dynamic>{
                          'profile': 'explorer',
                          'taskPrompt': 'Wait forever',
                        },
                      ),
                      LlmToolCallSpec(
                        id: 'wt_c',
                        name: 'sys_wait',
                        arguments: const <String, dynamic>{'timeoutMs': 25000},
                      ),
                    ],
                    usage: const LlmUsageTelemetry(
                      promptTokens: 50,
                      completionTokens: 10,
                      durationMs: 5,
                    ),
                  );
                }
                return LlmChatResponse(
                  content: 'Should not reach',
                  usage: const LlmUsageTelemetry(
                    promptTokens: 50,
                    completionTokens: 10,
                    durationMs: 5,
                  ),
                );
              },
            ),
          },
        ),
      );
      addTearDown(cancelBootstrap.dispose);

      final turnFuture = cancelBootstrap.processRunner.submitPrompt(
        userInput: 'Spawn and wait until cancelled',
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      cancelBootstrap.processRunner.cancelActiveTurn('User cancelled');
      final cancelRes = await turnFuture;
      expect(cancelRes.ok, isFalse);
      expect(cancelRes.error!.code, equals(SyscallErrorCode.ecancelled));
      expect(cancelBootstrap.pcb.quotaUsage.activeChildProcesses, equals(0));
      expect(cancelBootstrap.workerHost!.activeChildCount, equals(0));
    });
  });
}

class _ChildExitObserver extends BaseSyscallHook {
  final Map<int, Completer<void>> _exits = <int, Completer<void>>{};

  @override
  String get name => 'child_exit_observer';

  Future<void> observed(int pid) =>
      _exits.putIfAbsent(pid, Completer<void>.new).future;

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    if (context.syscallName == 'sys_exit' && result.ok) {
      _exits.putIfAbsent(context.pid, Completer<void>.new).complete();
    }
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

class _RoutingFakeLlmDriver implements LlmDriver {
  _RoutingFakeLlmDriver({required this.onRequest});

  final LlmChatResponse Function(LlmChatRequest request) onRequest;

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final resp = onRequest(request);
    if (resp.content.isNotEmpty) {
      yield LlmTextDelta(resp.content);
    }
    for (final tc in resp.toolCalls) {
      yield LlmToolCallEvent(tc);
    }
    yield LlmDoneEvent(resp);
  }
}

class _BlockingFakeLlmDriver implements LlmDriver {
  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    if (cancelToken != null) {
      await cancelToken.onCancel;
    } else {
      await Future<void>.delayed(const Duration(seconds: 30));
    }
    throw const LlmDriverException(
      SyscallError(
        code: SyscallErrorCode.ecancelled,
        reason: 'CANCELLED',
        message: 'Cancelled',
        recoverable: true,
      ),
    );
  }
}
