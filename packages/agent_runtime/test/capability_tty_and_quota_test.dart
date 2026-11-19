import 'dart:async';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Capability Attenuation, Tool Schema Hiding, TTY Monopoly, and Quota Donation [D-213], [D-214]', () {
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
      repoDir = Directory.systemTemp.createTempSync('fm_wp4_cap_quota_');
      expect(runJjSync(<String>['git', 'init', '--colocate']).exitCode, equals(0));
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP4 Tester']);
      runJjSync(<String>['config', 'set', '--repo', 'user.email', 'wp4@example.com']);

      Directory(p.join(repoDir.path, 'allowed')).createSync(recursive: true);
      Directory(p.join(repoDir.path, 'secret_area')).createSync(recursive: true);
      File(p.join(repoDir.path, 'allowed', 'ok.txt')).writeAsStringSync('allowed content\n');
      File(p.join(repoDir.path, 'secret_area', 'nope.txt')).writeAsStringSync('forbidden content\n');
      expect(runJjSync(<String>['describe', '-m', 'seed']).exitCode, equals(0));
      expect(runJjSync(<String>['new', '-m', 'wip']).exitCode, equals(0));
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test('blocks capability escalation, enforces allowedSubpaths, hides unauthorized Tool Schemas, and keeps ApprovalHandler calls at 0 for Ring 3', () async {
      final opIdBefore = readHeadOpId();
      var approvalCallCount = 0;
      final countingApproval = _CountingApprovalHandler(
        onRequest: (_) {
          approvalCallCount += 1;
          return const ApprovalDecision.allowOnce();
        },
      );

      final observedToolsByProfile = <String, List<String>>{};

      final fakeLlm = _CallbackLlmDriver(
        onRequest: (req) {
          final sys = req.prompt.messages.first.content;
          final toolNames = req.prompt.tools.map((t) => t.name).toList()..sort();
          if (sys.contains('Ring 3 Explorer')) {
            observedToolsByProfile['explorer'] = toolNames;
          } else if (sys.contains('Ring 3 WebResearcher')) {
            observedToolsByProfile['web_researcher'] = toolNames;
          } else {
            observedToolsByProfile['lead'] = toolNames;
          }
          return LlmChatResponse(
            content: 'Done.',
            usage: const LlmUsageTelemetry(
              promptTokens: 50,
              completionTokens: 10,
              durationMs: 5,
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
          approvalHandler: countingApproval,
          childWorkerBackend: const GreenTaskChildWorkerBackend(),
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: fakeLlm,
          },
        ),
      );
      addTearDown(bootstrap.dispose);

      final parentCtx = SyscallContext(
        pid: 1,
        capHandle: bootstrap.capHandle,
        sessionId: bootstrap.sessionId,
      );

      // 1. Escalation attempts on sys_spawn must be rejected with EPERM: STAGE2_READONLY_CHILD_LOCK.
      for (final badRight in <String>['writeCow', 'exec', 'procSpawn', 'vcsTx']) {
        final res = await bootstrap.syscallGate.invoke(
          parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'explorer',
              'taskPrompt': 'Escalate $badRight',
              'requestedRights': <String>['read', badRight],
            },
          ),
        );
        expect(res.ok, isFalse);
        expect(res.error!.code, equals(SyscallErrorCode.eperm));
        expect(res.error!.reason, equals('STAGE2_READONLY_CHILD_LOCK'));
      }

      // 2. Spawn Explorer scoped to /workspace/allowed and WebResearcher (sterile).
      final expSpawn = await bootstrap.syscallGate.invoke(
        parentCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Inspect allowed',
            'allowedSubpaths': <String>['/workspace/allowed'],
          },
        ),
      );
      expect(expSpawn.ok, isTrue, reason: '${expSpawn.error}');
      final expPid = expSpawn.value!['childPid'] as int;

      final webSpawn = await bootstrap.syscallGate.invoke(
        parentCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'web_researcher',
            'taskPrompt': 'Search web',
          },
        ),
      );
      expect(webSpawn.ok, isTrue, reason: '${webSpawn.error}');
      final webPid = webSpawn.value!['childPid'] as int;

      // Wait for both children to finish so ProjectedPrompt.tools are captured.
      final waitRes = await bootstrap.syscallGate.invoke(
        parentCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[expPid, webPid]},
        ),
      );
      expect(waitRes.ok, isTrue);

      // 3. Verify CSpace-driven Tool Schema hiding ([D-213] §4.2).
      final expTools = observedToolsByProfile['explorer']!;
      expect(expTools, contains('sys_read_lines'));
      expect(expTools, contains('sys_jj_status'));
      expect(expTools, contains('sys_exit'));
      for (final forbidden in <String>[
        'sys_write_file',
        'sys_edit_block',
        'sys_exec',
        'sys_tx_begin',
        'sys_tx_squash',
        'sys_spawn',
        'sys_wait',
      ]) {
        expect(expTools, isNot(contains(forbidden)));
      }

      final webTools = observedToolsByProfile['web_researcher']!;
      expect(webTools, contains('sys_exit'));
      expect(webTools, contains('sys_send'));
      expect(webTools, contains('sys_recv'));
      for (final forbidden in <String>[
        'sys_read_lines',
        'sys_glob',
        'sys_grep',
        'sys_write_file',
        'sys_edit_block',
        'sys_exec',
        'sys_jj_status',
        'sys_tx_squash',
        'sys_mem_pagein',
        'sys_spawn',
        'sys_wait',
      ]) {
        expect(webTools, isNot(contains(forbidden)));
      }

      // 4. Direct syscall invocation from Ring 3 Explorer:
      //    - allowed subpath read succeeds
      //    - outside subpath read fails with EACCES: OUT_OF_ALLOWED_SUBPATH
      //    - sys_jj_status forces --ignore-working-copy (even if parent has active tx)
      //    - sys_write_file / sys_exec / sys_tx_squash fail with EPERM and 0 ApprovalHandler calls!
      final expCtx = SyscallContext(
        pid: expPid,
        capHandle: const CapHandle('cap_explorer'),
        sessionId: bootstrap.sessionId,
      );
      // Re-open state to running solely to test direct Gate enforcement on the child PCB.
      final expPcb = bootstrap.processTable.getProcess(expPid)!;
      expPcb.state = ProcessState.running;

      final okRead = await bootstrap.syscallGate.invoke(
        expCtx,
        SyscallRequest(
          name: 'sys_read_lines',
          args: const <String, dynamic>{'path': '/workspace/allowed/ok.txt'},
        ),
      );
      expect(okRead.ok, isTrue);

      final deniedSubpath = await bootstrap.syscallGate.invoke(
        expCtx,
        SyscallRequest(
          name: 'sys_read_lines',
          args: const <String, dynamic>{'path': '/workspace/secret_area/nope.txt'},
        ),
      );
      expect(deniedSubpath.ok, isFalse);
      expect(deniedSubpath.error!.code, equals(SyscallErrorCode.eacces));
      expect(deniedSubpath.error!.reason, equals('OUT_OF_ALLOWED_SUBPATH'));

      // Even if parent txContext were active, Ring 3 jj read forces --ignore-working-copy.
      bootstrap.pcb.jjContext.state = TxState.active;
      final jjRes = await bootstrap.syscallGate.invoke(
        expCtx,
        SyscallRequest(name: 'sys_jj_status'),
      );
      expect(jjRes.ok, isTrue);
      expect(jjRes.value!['ignoredWorkingCopy'], isTrue);
      expect(readHeadOpId(), equals(opIdBefore));

      for (final req in <SyscallRequest>[
        SyscallRequest(
          name: 'sys_write_file',
          args: const <String, dynamic>{
            'path': '/workspace/allowed/hack.txt',
            'content': 'x',
          },
        ),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'cmd',
            'args': <String>['/c', 'echo', 'hi'],
          },
        ),
        SyscallRequest(name: 'sys_tx_squash'),
      ]) {
        final denied = await bootstrap.syscallGate.invoke(expCtx, req);
        expect(denied.ok, isFalse);
        expect(denied.error!.code, equals(SyscallErrorCode.eperm));
      }

      // Also verify TTY monopoly directly when a Ring 3 process holds a custom askUser syscall.
      bootstrap.syscallGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_test_ask_user',
          requiredRight: CapRight.read,
          kind: 'other',
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{}),
        ),
      );
      final ttyDenied = await bootstrap.syscallGate.invoke(
        expCtx,
        SyscallRequest(name: 'sys_test_ask_user'),
      );
      expect(ttyDenied.ok, isFalse);
      expect(ttyDenied.error!.code, equals(SyscallErrorCode.eperm));
      expect(ttyDenied.error!.reason, equals('TTY_MONOPOLY_DENIED'));
      expect(approvalCallCount, equals(0));
    });

    test('enforces hierarchical quota conservation, blocks parallel double-spend (recoverable), and isolates child EDQUOT (token / wall-time / syscall) while parent finishes end_turn', () async {
      // Part A: Parallel donation conservation law & double-spend prevention.
      final releaseChildren = Completer<void>();
      final conservationBootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          quota: const ResourceQuota(
            maxChildProcesses: 2,
            maxSyscallCountPerTurn: 64,
            maxTotalTokens: 10000,
          ),
          enableStage2Multiprocess: true,
          childWorkerBackend: const GreenTaskChildWorkerBackend(),
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: _CallbackLlmDriver(
              onRequest: (_) => LlmChatResponse(
                content: 'Consumed 1200 tokens.',
                usage: const LlmUsageTelemetry(
                  promptTokens: 1000,
                  completionTokens: 200,
                  durationMs: 5,
                ),
              ),
              gate: releaseChildren.future,
            ),
          },
        ),
      );
      addTearDown(conservationBootstrap.dispose);

      final pCtx = SyscallContext(
        pid: 1,
        capHandle: conservationBootstrap.capHandle,
        sessionId: conservationBootstrap.sessionId,
      );

      // Donate 6,000 tokens to child 1 -> parent available drops to 4,000.
      final s1 = await conservationBootstrap.syscallGate.invoke(
        pCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Task 1',
            'maxTotalTokens': 6000,
          },
        ),
      );
      expect(s1.ok, isTrue);
      expect(conservationBootstrap.pcb.quotaUsage.donatedTokensOut, equals(6000));

      // Attempt to donate 5,000 tokens concurrently -> exceeds remaining 4,000 -> recoverable EDQUOT!
      final doubleSpend = await conservationBootstrap.syscallGate.invoke(
        pCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Task 2 over-budget',
            'maxTotalTokens': 5000,
          },
        ),
      );
      expect(doubleSpend.ok, isFalse);
      expect(doubleSpend.error!.code, equals(SyscallErrorCode.edquot));
      expect(doubleSpend.error!.reason, equals('INSUFFICIENT_PARENT_TOKEN_QUOTA'));
      expect(doubleSpend.error!.recoverable, isTrue);

      // Donate 3,000 tokens -> succeeds (total reserved = 9,000, activeChildProcesses = 2).
      final s2 = await conservationBootstrap.syscallGate.invoke(
        pCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Task 2 within budget',
            'maxTotalTokens': 3000,
          },
        ),
      );
      expect(s2.ok, isTrue);

      // Attempt 3rd concurrent child when maxChildProcesses == 2 -> CHILD_PROCESS_QUOTA_EXCEEDED (recoverable: true).
      final tooMany = await conservationBootstrap.syscallGate.invoke(
        pCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Task 3 over child cap',
            'maxTotalTokens': 500,
          },
        ),
      );
      expect(tooMany.ok, isFalse);
      expect(tooMany.error!.code, equals(SyscallErrorCode.edquot));
      expect(tooMany.error!.reason, equals('CHILD_PROCESS_QUOTA_EXCEEDED'));
      expect(tooMany.error!.recoverable, isTrue);

      // Release both children and wait -> unused tokens returned strictly (10000 - 2400 = 7600 available).
      releaseChildren.complete();
      final waitAll = await conservationBootstrap.syscallGate.invoke(
        pCtx,
        SyscallRequest(name: 'sys_wait'),
      );
      expect(waitAll.ok, isTrue);
      expect(conservationBootstrap.pcb.quotaUsage.donatedTokensOut, equals(0));
      expect(conservationBootstrap.pcb.quotaUsage.activeChildProcesses, equals(0));
      expect(conservationBootstrap.pcb.quotaUsage.totalTokensUsed, equals(2400));
      expect(
        conservationBootstrap.pcb.quotaUsage.availableTokens(
          conservationBootstrap.pcb.quota,
        ),
        equals(7600),
      );

      // Part B: Tiny token budget / wall-time / syscall limit -> child stops locally with EDQUOT, parent completes ok: true.
      var parentStep = 0;
      final localStopBootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          quota: ResourceQuota.stage2Default,
          enableStage2Multiprocess: true,
          childWorkerBackend: const IsolateChildWorkerBackend(),
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: _CallbackLlmDriver(
              onRequest: (req) {
                final isChild =
                    req.prompt.messages.first.content.contains('Ring 3 Explorer');
                if (isChild) {
                  // Child uses 1600 tokens on step 1 and requests another tool -> hits 1500 token cap!
                  return LlmChatResponse(
                    content: 'Partial finding before cap.',
                    toolCalls: <LlmToolCallSpec>[
                      LlmToolCallSpec(
                        id: 'r1',
                        name: 'sys_read_lines',
                        arguments: const <String, dynamic>{
                          'path': '/workspace/allowed/ok.txt',
                        },
                      ),
                    ],
                    usage: const LlmUsageTelemetry(
                      promptTokens: 1300,
                      completionTokens: 300,
                      durationMs: 5,
                    ),
                  );
                }
                parentStep += 1;
                if (parentStep == 1) {
                  return LlmChatResponse(
                    content: '',
                    toolCalls: <LlmToolCallSpec>[
                      LlmToolCallSpec(
                        id: 'sp_tiny',
                        name: 'sys_spawn',
                        arguments: const <String, dynamic>{
                          'profile': 'explorer',
                          'name': 'tiny-token-child',
                          'taskPrompt': 'Investigate with tiny budget',
                          'maxTotalTokens': 1500,
                        },
                      ),
                      LlmToolCallSpec(
                        id: 'wt_tiny',
                        name: 'sys_wait',
                        arguments: const <String, dynamic>{'timeoutMs': 10000},
                      ),
                    ],
                    usage: const LlmUsageTelemetry(
                      promptTokens: 100,
                      completionTokens: 20,
                      durationMs: 5,
                    ),
                  );
                }
                return LlmChatResponse(
                  content: 'Parent handled child EDQUOT gracefully and finished.',
                  usage: const LlmUsageTelemetry(
                    promptTokens: 150,
                    completionTokens: 20,
                    durationMs: 5,
                  ),
                );
              },
            ),
          },
        ),
      );
      addTearDown(localStopBootstrap.dispose);

      final parentTurn = await localStopBootstrap.processRunner.submitPrompt(
        userInput: 'Run child with tiny token budget',
      );
      expect(parentTurn.ok, isTrue, reason: '${parentTurn.error}');
      expect(parentTurn.finalText, contains('Parent handled child EDQUOT gracefully'));
      expect(localStopBootstrap.pcb.quotaUsage.activeChildProcesses, equals(0));

      final waitTurn = localStopBootstrap.pcb.memory.historySegment.turns
          .whereType<CanonicalToolResultTurn>()
          .firstWhere((t) => t.toolName == 'sys_wait');
      expect(waitTurn.content, contains('"errorCode":"EDQUOT"'));
      expect(waitTurn.content, contains('"reason":"TOKEN_QUOTA_EXCEEDED"'));

      // Part C: Hard maxWallTimeMs enforcement kills spinning real Isolate with EDQUOT.
      final wallExec = SyscallExecutionContext(
        syscallSeq: 99,
        context: SyscallContext(
          pid: 1,
          capHandle: localStopBootstrap.capHandle,
          sessionId: localStopBootstrap.sessionId,
        ),
        pcb: localStopBootstrap.pcb,
        syscallName: 'sys_spawn',
        args: const <String, dynamic>{},
      );
      final spinSpawn = await localStopBootstrap.workerHost!.spawnChild(
        wallExec,
        SpawnSpec(
          profile: ProcessProfileId.explorer,
          taskPrompt: 'Spin until wall time',
          maxWallTimeMs: 120,
        ),
        diagnosticMode: 'spin',
      );
      expect(spinSpawn.ok, isTrue);
      final spinPid = spinSpawn.value!['childPid'] as int;
      final waitSpin = await localStopBootstrap.workerHost!.waitForChildren(
        wallExec,
        pids: <int>[spinPid],
        timeoutMs: 5000,
      );
      expect(waitSpin.ok, isTrue);
      final spinStatus = (waitSpin.value!['children'] as List).single
          as Map<String, dynamic>;
      expect(spinStatus['ok'], isFalse);
      expect(spinStatus['errorCode'], equals('EDQUOT'));
      expect(spinStatus['reason'], equals('WALL_TIME_QUOTA_EXCEEDED'));
      expect(localStopBootstrap.pcb.quotaUsage.activeChildProcesses, equals(0));
    });
  });
}

class _CountingApprovalHandler implements ApprovalHandler {
  _CountingApprovalHandler({required this.onRequest});
  final ApprovalDecision Function(ApprovalRequest req) onRequest;

  @override
  Future<ApprovalDecision> requestApproval(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) async {
    return onRequest(request);
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

class _CallbackLlmDriver implements LlmDriver {
  _CallbackLlmDriver({
    required this.onRequest,
    this.gate,
  });

  final LlmChatResponse Function(LlmChatRequest request) onRequest;
  final Future<void>? gate;

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    if (gate != null) {
      await gate;
    }
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
