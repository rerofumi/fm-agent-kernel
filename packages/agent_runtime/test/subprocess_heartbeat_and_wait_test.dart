import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('REQ-01 / REQ-02 / REQ-03: Subprocess limits, Heartbeat, and non-destructive sys_wait', () {
    late Directory tempDir;
    late String repoRoot;
    late JjDriver jjDriver;
    late HostFsDriver fsDriver;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_wp1_hb_');
      repoRoot = p.normalize(tempDir.path);
      await _runCmd('jj', <String>['git', 'init', '--colocate', '.'], repoRoot);
      await _runCmd(
        'jj',
        <String>['config', 'set', '--repo', 'user.name', 'Test User'],
        repoRoot,
      );
      await _runCmd(
        'jj',
        <String>['config', 'set', '--repo', 'user.email', 'test@example.com'],
        repoRoot,
      );
      await File(p.join(repoRoot, '.gitignore')).writeAsString('.agent_os/\n');
      await File(p.join(repoRoot, 'README.md')).writeAsString('base\n');
      await _runCmd('jj', <String>['commit', '-m', 'initial'], repoRoot);

      jjDriver = JjDriver.forWorkspace(repoRoot);
      fsDriver = HostFsDriver(
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        ensureActiveTransactionForPcb: jjDriver.ensureActiveTransactionForPcb,
        syncWorkingCopySnapshotForPcb: jjDriver.syncWorkingCopySnapshotForPcb,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        for (var i = 0; i < 4; i++) {
          try {
            await tempDir.delete(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    });

    ({
      KernelProcessTable processTable,
      QuotaLedger quotaLedger,
      ProcessControlBlock parentPcb,
      SyscallGate gate,
      SyscallContext leadCtx,
    }) createBaseKernel(String sessionId) {
      final processTable = KernelProcessTable.stage2();
      final quotaLedger = QuotaLedger();
      final cspace = CapabilityTable.stage3LeadAgent();
      final parentPcb = ProcessControlBlock(
        pid: 1,
        name: 'lead',
        ring: ProtectionRing.ring2,
        cspace: cspace,
        quota: const ResourceQuota(
          maxChildProcesses: 8,
          maxSyscallCountPerTurn: 128,
          maxTotalTokens: 1000000,
        ),
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        memory: VirtualContextMemory(
          sessionId: sessionId,
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
      processTable.registerProcess(parentPcb);
      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: _AlwaysAllowApprovalHandler()),
        ioCapper: IoPayloadCapper(),
        auditLogger: AuditLogger(
          sessionId: sessionId,
          workspaceHostRoot: repoRoot,
          redactor: SecretRedactor(),
        ),
      );
      for (final def in fsDriver.buildReadSyscallDefinitions()) {
        gate.registerSyscall(def);
      }
      for (final def in fsDriver.buildWriteSyscallDefinitions()) {
        gate.registerSyscall(def);
      }
      final leadCtx = SyscallContext(
        pid: 1,
        capHandle: cspace.entries.first.handle,
        sessionId: sessionId,
      );
      return (
        processTable: processTable,
        quotaLedger: quotaLedger,
        parentPcb: parentPcb,
        gate: gate,
        leadCtx: leadCtx,
      );
    }

    IsolateWorkerHost wireHost({
      required KernelProcessTable processTable,
      required QuotaLedger quotaLedger,
      required SyscallGate gate,
      ChildWorkerBackend backend = const GreenTaskChildWorkerBackend(),
    }) {
      final host = IsolateWorkerHost(
        processTable: processTable,
        syscallGate: gate,
        quotaLedger: quotaLedger,
        jjDriver: jjDriver,
        toolSchemaProvider: (pcb) => filterToolSchemasForPcb(
          pcb: pcb,
          allSchemas: <SyscallToolSchema>[
            ...buildProcessToolSchemas(),
            ...HostFsDriver.readToolSchemas(),
            ...HostFsDriver.writeToolSchemas(),
          ],
        ),
        parentCurrentModelProvider: () => 'local-ollama/gemma4:12b',
        backend: backend,
      );
      for (final def in buildProcessSyscallDefinitions(
        host: host,
        processTable: processTable,
      )) {
        gate.registerSyscall(def);
      }
      return host;
    }

    test('buildProcessToolSchemas reflects extended limits, heartbeatTimeoutMs, and non-destructive sys_wait [D-509]', () {
      final schemas = buildProcessToolSchemas();
      final spawn = schemas.firstWhere((s) => s.name == 'sys_spawn');
      final spawnProps =
          spawn.parametersJsonSchema['properties'] as Map<String, dynamic>;
      final profileDesc =
          (spawnProps['profile'] as Map<String, dynamic>)['description']
              as String;
      expect(profileDesc, contains('allowlisted sys_exec commands'));
      expect(
        (spawnProps['maxWallTimeMs'] as Map<String, dynamic>)['description'],
        allOf(contains('600000'), contains('3600000')),
      );
      expect(
        (spawnProps['maxSteps'] as Map<String, dynamic>)['description'],
        allOf(contains('32'), contains('128')),
      );
      expect(
        (spawnProps['heartbeatTimeoutMs'] as Map<String, dynamic>)['description'],
        allOf(contains('300000'), contains('600000'), contains('SIGSTOP')),
      );

      final wait = schemas.firstWhere((s) => s.name == 'sys_wait');
      expect(wait.description, contains('Non-destructive on timeout'));
      final waitProps =
          wait.parametersJsonSchema['properties'] as Map<String, dynamic>;
      expect(
        (waitProps['timeoutMs'] as Map<String, dynamic>)['description'],
        allOf(contains('120000'), contains('600000')),
      );
    });

    test('REQ-01: sys_spawn & sys_wait validate boundary values and child completes > 32 steps (40 steps)', () async {
      final k = createBaseKernel('req01_bounds');
      var stepCounter = 0;
      k.gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          stepCounter += 1;
          if (stepCounter <= 40) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'r_$stepCounter',
                  name: 'sys_read_lines',
                  arguments: const <String, dynamic>{'path': '/workspace/README.md'},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          }
          return LlmChatResponse(
            content: '40_STEPS_OK',
            usage: const LlmUsageTelemetry(
              promptTokens: 5,
              completionTokens: 5,
              durationMs: 1,
            ),
          );
        }),
      );
      final host = wireHost(
        processTable: k.processTable,
        quotaLedger: k.quotaLedger,
        gate: k.gate,
      );
      addTearDown(host.dispose);

      // Invalid boundaries -> EINVAL
      for (final badArgs in <Map<String, dynamic>>[
        <String, dynamic>{'profile': 'explorer', 'taskPrompt': 'x', 'maxWallTimeMs': 0},
        <String, dynamic>{'profile': 'explorer', 'taskPrompt': 'x', 'maxWallTimeMs': -1},
        <String, dynamic>{'profile': 'explorer', 'taskPrompt': 'x', 'maxWallTimeMs': 3600001},
        <String, dynamic>{'profile': 'explorer', 'taskPrompt': 'x', 'maxSteps': 0},
        <String, dynamic>{'profile': 'explorer', 'taskPrompt': 'x', 'maxSteps': 129},
        <String, dynamic>{'profile': 'explorer', 'taskPrompt': 'x', 'heartbeatTimeoutMs': 0},
        <String, dynamic>{'profile': 'explorer', 'taskPrompt': 'x', 'heartbeatTimeoutMs': 600001},
      ]) {
        final res = await k.gate.invoke(
          k.leadCtx,
          SyscallRequest(name: 'sys_spawn', args: badArgs),
        );
        expect(res.ok, isFalse, reason: 'Expected EINVAL for $badArgs');
        expect(res.error!.code, equals(SyscallErrorCode.einval));
      }

      // sys_wait timeoutMs validation (0 and 600001 rejected; 600000 accepted)
      for (final badTimeout in <int>[0, -5, 600001]) {
        final waitErr = await k.gate.invoke(
          k.leadCtx,
          SyscallRequest(
            name: 'sys_wait',
            args: <String, dynamic>{'timeoutMs': badTimeout},
          ),
        );
        expect(waitErr.ok, isFalse);
        expect(waitErr.error!.code, equals(SyscallErrorCode.einval));
      }
      final emptyMaxWait = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: const <String, dynamic>{'timeoutMs': 600000},
        ),
      );
      expect(emptyMaxWait.ok, isTrue);
      expect(emptyMaxWait.value!['timedOut'], isFalse);
      expect(emptyMaxWait.value!['children'], isEmpty);
      expect(emptyMaxWait.value!['running'], isEmpty);

      // Accept max boundary arguments (validated without crashing).
      final maxBoundSpawn = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Max bounds check',
            'maxWallTimeMs': 3600000,
            'maxSteps': 128,
            'heartbeatTimeoutMs': 600000,
          },
        ),
      );
      expect(maxBoundSpawn.ok, isTrue, reason: maxBoundSpawn.error?.message);
      final maxBoundPid = maxBoundSpawn.value!['childPid'] as int;
      expect(
        k.processTable.getProcess(maxBoundPid)!.quota.maxSyscallCountPerTurn,
        equals(128 * 8),
      );
      expect(
        k.processTable.getProcess(maxBoundPid)!.quota.maxWallTimeMs,
        equals(3600000),
      );
      final waitMaxBound = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[maxBoundPid], 'timeoutMs': 10000},
        ),
      );
      expect(waitMaxBound.ok, isTrue);

      // Run 40 steps (> old 32 maxSteps) with maxSteps: 45
      stepCounter = 0;
      final spawn40 = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Run 40 steps',
            'maxSteps': 45,
          },
        ),
      );
      expect(spawn40.ok, isTrue, reason: spawn40.error?.message);
      final pid40 = spawn40.value!['childPid'] as int;
      expect(
        k.processTable.getProcess(pid40)!.quota.maxSyscallCountPerTurn,
        equals(45 * 8),
      );

      final wait40 = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[pid40], 'timeoutMs': 30000},
        ),
      );
      expect(wait40.ok, isTrue);
      expect(wait40.value!['timedOut'], isFalse);
      final child40 = (wait40.value!['children'] as List).single as Map<String, dynamic>;
      expect(child40['ok'], isTrue, reason: '${child40['reason']}: ${child40['summary']}');
      expect(child40['exitCode'], equals(0));
      expect(child40['summary'], equals('40_STEPS_OK'));
      expect(stepCounter, equals(41));
    });

    test('REQ-02(a): HEARTBEAT_TIMEOUT kills stalled worker, cleans workspace, settles quota, and supports on_failure retry', () async {
      final k = createBaseKernel('req02_stall');
      var llmCalls = 0;
      final blockedCall = Completer<void>();
      k.gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          llmCalls += 1;
          if (llmCalls == 1) {
            // Hang until cancelled (simulating stalled LLM call)
            await blockedCall.future.timeout(const Duration(seconds: 5), onTimeout: () {});
          }
          return LlmChatResponse(
            content: 'RECOVERED_ON_RETRY',
            usage: const LlmUsageTelemetry(
              promptTokens: 10,
              completionTokens: 5,
              durationMs: 1,
            ),
          );
        }),
      );
      final host = wireHost(
        processTable: k.processTable,
        quotaLedger: k.quotaLedger,
        gate: k.gate,
      );
      addTearDown(() async {
        if (!blockedCall.isCompleted) {
          blockedCall.complete();
        }
        await host.dispose();
      });

      // 1. restart: "never" -> single HEARTBEAT_TIMEOUT terminates with ETIMEDOUT / 124 and cleans jj workspace
      final spawnStall = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'workspace_worker',
            'taskPrompt': 'Stall test',
            'maxWallTimeMs': 10000,
            'heartbeatTimeoutMs': 150,
          },
        ),
      );
      expect(spawnStall.ok, isTrue, reason: spawnStall.error?.message);
      final stallPid = spawnStall.value!['childPid'] as int;
      final wsRoot = k.processTable.getProcess(stallPid)!.jjWorkspaceRoot!;
      final wsDir = Directory(wsRoot);
      expect(wsDir.existsSync(), isTrue);

      final waitStall = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{
            'pids': <int>[stallPid],
            'timeoutMs': 5000,
          },
        ),
      );
      expect(waitStall.ok, isTrue);
      final stallStatus =
          (waitStall.value!['children'] as List).single as Map<String, dynamic>;
      expect(stallStatus['ok'], isFalse);
      expect(stallStatus['reason'], equals('HEARTBEAT_TIMEOUT'));
      expect(stallStatus['errorCode'], equals('ETIMEDOUT'));
      expect(stallStatus['exitCode'], equals(124));
      expect(stallStatus['workspaceCleanedUp'], isTrue);
      expect(wsDir.existsSync(), isFalse);
      expect(k.parentPcb.quotaUsage.activeChildProcesses, equals(0));

      // 2. restart: "on_failure" -> HEARTBEAT_TIMEOUT is retryable and recovers on attempt 2
      llmCalls = 0;
      final retrySpawn = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Retry on stall',
            'maxWallTimeMs': 10000,
            'heartbeatTimeoutMs': 150,
            'supervision': <String, dynamic>{
              'restart': 'on_failure',
              'maxRetries': 1,
            },
          },
        ),
      );
      expect(retrySpawn.ok, isTrue);
      final waitRetry = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{
            'pids': <int>[retrySpawn.value!['childPid'] as int],
            'timeoutMs': 5000,
          },
        ),
      );
      expect(waitRetry.ok, isTrue);
      final retryStatus =
          (waitRetry.value!['children'] as List).single as Map<String, dynamic>;
      expect(retryStatus['ok'], isTrue, reason: '${retryStatus['reason']}');
      expect(retryStatus['summary'], equals('RECOVERED_ON_RETRY'));
      final attempts = retryStatus['attempts'] as List<dynamic>;
      expect(attempts, hasLength(2));
      expect((attempts[0] as Map<String, dynamic>)['reason'], equals('HEARTBEAT_TIMEOUT'));
      expect((attempts[1] as Map<String, dynamic>)['ok'], isTrue);
    });

    test('REQ-02(b): Child making steady progress exceeds heartbeatTimeoutMs total wall time without stall kill', () async {
      final k = createBaseKernel('req02_progress');
      var step = 0;
      k.gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          step += 1;
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (step <= 5) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'step_$step',
                  name: 'sys_read_lines',
                  arguments: const <String, dynamic>{'path': '/workspace/README.md'},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 80,
              ),
            );
          }
          return LlmChatResponse(
            content: 'STEADY_PROGRESS_DONE',
            usage: const LlmUsageTelemetry(
              promptTokens: 5,
              completionTokens: 5,
              durationMs: 80,
            ),
          );
        }),
      );
      final host = wireHost(
        processTable: k.processTable,
        quotaLedger: k.quotaLedger,
        gate: k.gate,
      );
      addTearDown(host.dispose);

      // Total time ~480ms > heartbeatTimeoutMs 200ms, each step ~80ms < 200ms
      final spawnRes = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Steady multi-step',
            'maxWallTimeMs': 10000,
            'heartbeatTimeoutMs': 200,
          },
        ),
      );
      expect(spawnRes.ok, isTrue);

      final waitRes = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{
            'pids': <int>[spawnRes.value!['childPid'] as int],
            'timeoutMs': 10000,
          },
        ),
      );
      expect(waitRes.ok, isTrue);
      final status = (waitRes.value!['children'] as List).single as Map<String, dynamic>;
      expect(status['ok'], isTrue, reason: '${status['reason']}: ${status['summary']}');
      expect(status['summary'], equals('STEADY_PROGRESS_DONE'));
    });

    test('REQ-02(c): consecutiveErrors increments on tool failure, persists across sys_llm_chat, and resets on tool success', () async {
      final k = createBaseKernel('req02_errors');
      var step = 0;
      final beforeStep2Gate = Completer<void>();
      final step2Started = Completer<void>();
      final beforeSuccessToolGate = Completer<void>();
      final afterSuccessLlmStarted = Completer<void>();

      late final IsolateWorkerHost host;
      k.gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          step += 1;
          if (step == 1) {
            // Step 1: call missing file twice -> 2 consecutive tool errors
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'e1',
                  name: 'sys_read_lines',
                  arguments: const <String, dynamic>{'path': '/workspace/MISSING_1.txt'},
                ),
                LlmToolCallSpec(
                  id: 'e2',
                  name: 'sys_read_lines',
                  arguments: const <String, dynamic>{'path': '/workspace/MISSING_2.txt'},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          }
          if (step == 2) {
            if (!step2Started.isCompleted) {
              step2Started.complete();
            }
            await beforeStep2Gate.future;
            // Step 2: sys_llm_chat succeeded, now call a succeeding tool
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'ok1',
                  name: 'sys_read_lines',
                  arguments: const <String, dynamic>{'path': '/workspace/README.md'},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          }
          if (!afterSuccessLlmStarted.isCompleted) {
            afterSuccessLlmStarted.complete();
          }
          await beforeSuccessToolGate.future;
          return LlmChatResponse(
            content: 'ERRORS_TRACKED_AND_RESET',
            usage: const LlmUsageTelemetry(
              promptTokens: 5,
              completionTokens: 5,
              durationMs: 1,
            ),
          );
        }),
      );
      host = wireHost(
        processTable: k.processTable,
        quotaLedger: k.quotaLedger,
        gate: k.gate,
      );
      addTearDown(host.dispose);

      final spawnRes = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Error loop check',
          },
        ),
      );
      expect(spawnRes.ok, isTrue);

      await step2Started.future;
      final midSnap = host.snapshotProcesses().single;
      final midHb = midSnap['heartbeat'] as Map<String, dynamic>;
      expect(midHb['consecutiveErrors'], equals(2));
      expect(midHb['lastErrorReason'], isNotNull);
      expect(midHb['activeSyscall'], equals('sys_llm_chat'));
      beforeStep2Gate.complete();

      await afterSuccessLlmStarted.future;
      final postSnap = host.snapshotProcesses().single;
      final postHb = postSnap['heartbeat'] as Map<String, dynamic>;
      expect(postHb['consecutiveErrors'], equals(0));
      expect(postHb['lastErrorReason'], isNull);
      expect(postHb['lastSyscall'], equals('sys_read_lines'));
      beforeSuccessToolGate.complete();

      final waitRes = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(name: 'sys_wait', args: const <String, dynamic>{'timeoutMs': 5000}),
      );
      expect(waitRes.ok, isTrue);
      final status = (waitRes.value!['children'] as List).single as Map<String, dynamic>;
      expect(status['ok'], isTrue);
    });

    test('REQ-02(d): SIGSTOP pauses heartbeatTimer across single long wait and multiple SIGSTOP/SIGCONT round-trips', () async {
      final k = createBaseKernel('req02_sigstop');
      var llmCalls = 0;
      final step1ToolEntered = Completer<void>();
      final step1ToolRelease = Completer<void>();

      final origRead = fsDriver
          .buildReadSyscallDefinitions()
          .firstWhere((d) => d.name == 'sys_read_lines');
      k.gate.registerSyscall(
        SyscallDefinition(
          name: origRead.name,
          requiredRight: origRead.requiredRight,
          kind: origRead.kind,
          applyIoCap: origRead.applyIoCap,
          cappedTextFields: origRead.cappedTextFields,
          validateArgs: origRead.validateArgs,
          evaluatePolicy: origRead.evaluatePolicy,
          handler: (exec) async {
            if (!step1ToolEntered.isCompleted) {
              step1ToolEntered.complete();
              await step1ToolRelease.future;
            }
            return origRead.handler(exec);
          },
        ),
      );
      k.gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          llmCalls += 1;
          if (llmCalls == 1) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'r1',
                  name: 'sys_read_lines',
                  arguments: const <String, dynamic>{'path': '/workspace/README.md'},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          }
          return LlmChatResponse(
            content: 'SIGSTOP_HEARTBEAT_OK',
            usage: const LlmUsageTelemetry(
              promptTokens: 5,
              completionTokens: 5,
              durationMs: 1,
            ),
          );
        }),
      );
      final host = wireHost(
        processTable: k.processTable,
        quotaLedger: k.quotaLedger,
        gate: k.gate,
      );
      addTearDown(host.dispose);

      final spawnRes = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Sigstop heartbeat test',
            'maxWallTimeMs': 10000,
            'heartbeatTimeoutMs': 500,
          },
        ),
      );
      expect(spawnRes.ok, isTrue);
      final pid = spawnRes.value!['childPid'] as int;

      await step1ToolEntered.future;

      // Round-trip 1: active ~30ms, then SIGSTOP for 650ms (> 500ms heartbeatTimeoutMs)
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_kill',
          args: <String, dynamic>{'pid': pid, 'signal': 'SIGSTOP'},
        ),
      );
      final pausedSnap = host.snapshotProcesses().single;
      expect((pausedSnap['heartbeat'] as Map<String, dynamic>)['isPaused'], isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(k.processTable.getProcess(pid)!.state, equals(ProcessState.stopped));

      await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_kill',
          args: <String, dynamic>{'pid': pid, 'signal': 'SIGCONT'},
        ),
      );

      // Round-trip 2 in SAME idle interval (no recordHeartbeat between): active ~30ms, SIGSTOP 650ms
      // Verifies remainingHeartbeatMs is not double-subtracted!
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_kill',
          args: <String, dynamic>{'pid': pid, 'signal': 'SIGSTOP'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(k.processTable.getProcess(pid)!.state, equals(ProcessState.stopped));

      await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_kill',
          args: <String, dynamic>{'pid': pid, 'signal': 'SIGCONT'},
        ),
      );
      step1ToolRelease.complete();

      final waitRes = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[pid], 'timeoutMs': 5000},
        ),
      );
      expect(waitRes.ok, isTrue);
      final status = (waitRes.value!['children'] as List).single as Map<String, dynamic>;
      expect(status['ok'], isTrue, reason: '${status['reason']}: ${status['summary']}');
      expect(status['summary'], equals('SIGSTOP_HEARTBEAT_OK'));
    });

    test('REQ-03(a)(d): non-destructive sys_wait returns timedOut + running heartbeat, second sys_wait reaps workingChangeId, and audit records summary', () async {
      final k = createBaseKernel('req03_non_destructive');
      final releaseWorker = Completer<void>();
      k.gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          await releaseWorker.future;
          return LlmChatResponse(
            content: 'WORKER_FINISHED',
            usage: const LlmUsageTelemetry(
              promptTokens: 42,
              completionTokens: 8,
              durationMs: 5,
            ),
          );
        }),
      );
      final host = wireHost(
        processTable: k.processTable,
        quotaLedger: k.quotaLedger,
        gate: k.gate,
      );
      addTearDown(() async {
        if (!releaseWorker.isCompleted) {
          releaseWorker.complete();
        }
        await host.dispose();
      });

      final spawnRes = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'workspace_worker',
            'taskPrompt': 'Slow work',
            'maxWallTimeMs': 10000,
          },
        ),
      );
      expect(spawnRes.ok, isTrue);
      final pid = spawnRes.value!['childPid'] as int;
      final logicalTaskId = spawnRes.value!['logicalTaskId'] as String;

      // 1st sys_wait times out non-destructively
      final wait1 = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: const <String, dynamic>{'timeoutMs': 80},
        ),
      );
      expect(wait1.ok, isTrue, reason: wait1.error?.message);
      expect(wait1.value!['timedOut'], isTrue);
      expect(wait1.value!['children'], isEmpty);
      final running = wait1.value!['running'] as List<dynamic>;
      expect(running, hasLength(1));
      final r0 = running.single as Map<String, dynamic>;
      expect(r0['pid'], equals(pid));
      expect(r0['logicalTaskId'], equals(logicalTaskId));
      expect(r0['state'], anyOf(equals('running'), equals('waitingSyscall')));
      expect(r0['consumedTokens'], isA<int>());
      final hb = r0['heartbeat'] as Map<String, dynamic>;
      expect(hb['currentStep'], greaterThanOrEqualTo(1));
      expect(hb['idleMs'], isA<int>());
      expect(hb['activeSyscall'], equals('sys_llm_chat'));
      expect(hb['consecutiveErrors'], equals(0));

      // Verify snapshotProcesses() exposes heartbeat & quotas too
      final procSnap = host.snapshotProcesses().single;
      expect(procSnap['maxWallTimeMs'], equals(10000));
      expect(procSnap['heartbeat'], isA<Map<String, dynamic>>());

      // Release worker and re-wait -> collects completed child with workingChangeId
      releaseWorker.complete();
      final wait2 = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: const <String, dynamic>{'timeoutMs': 5000},
        ),
      );
      expect(wait2.ok, isTrue);
      expect(wait2.value!['timedOut'], isFalse);
      expect(wait2.value!['running'], isEmpty);
      final children2 = wait2.value!['children'] as List<dynamic>;
      expect(children2, hasLength(1));
      final c0 = children2.single as Map<String, dynamic>;
      expect(c0['pid'], equals(pid));
      expect(c0['ok'], isTrue);
      expect(c0['summary'], equals('WORKER_FINISHED'));
      expect(c0['workingChangeId'], isNotNull);

      // Verify audit log recorded timedOut, runningCount, runningPids
      await k.gate.auditLogger.flush();
      final auditLines =
          File(k.gate.auditLogger.syscallsLogPath).readAsLinesSync();
      final waitAudits = auditLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .where((m) => m['syscallName'] == 'sys_wait')
          .toList();
      expect(waitAudits, hasLength(2));
      final summary1 = waitAudits[0]['resultSummary'] as Map<String, dynamic>;
      expect(summary1['timedOut'], isTrue);
      expect(summary1['runningCount'], equals(1));
      expect(summary1['runningPids'], equals(<int>[pid]));
      final summary2 = waitAudits[1]['resultSummary'] as Map<String, dynamic>;
      expect(summary2['timedOut'], isFalse);
      expect(summary2['runningCount'], equals(0));
      expect(summary2['childCount'], equals(1));
    });

    test('REQ-03(b): partial completion reaps finished child A only and keeps child B in running for next sys_wait()', () async {
      final k = createBaseKernel('req03_partial');
      final releaseSlow = Completer<void>();
      k.gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          final isSlow = exec.pcb.name.contains('slow');
          if (isSlow) {
            await releaseSlow.future;
            return LlmChatResponse(
              content: 'SLOW_DONE',
              usage: const LlmUsageTelemetry(promptTokens: 5, completionTokens: 5, durationMs: 1),
            );
          }
          return LlmChatResponse(
            content: 'FAST_DONE',
            usage: const LlmUsageTelemetry(promptTokens: 5, completionTokens: 5, durationMs: 1),
          );
        }),
      );
      final host = wireHost(
        processTable: k.processTable,
        quotaLedger: k.quotaLedger,
        gate: k.gate,
      );
      addTearDown(() async {
        if (!releaseSlow.isCompleted) {
          releaseSlow.complete();
        }
        await host.dispose();
      });

      final spawnA = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'name': 'fast-a',
            'taskPrompt': 'Fast A',
          },
        ),
      );
      final spawnB = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'name': 'slow-b',
            'taskPrompt': 'Slow B',
          },
        ),
      );
      final pidA = spawnA.value!['childPid'] as int;
      final pidB = spawnB.value!['childPid'] as int;

      final wait1 = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: const <String, dynamic>{'timeoutMs': 300},
        ),
      );
      expect(wait1.ok, isTrue);
      expect(wait1.value!['timedOut'], isTrue);
      final children1 = wait1.value!['children'] as List<dynamic>;
      final running1 = wait1.value!['running'] as List<dynamic>;
      expect(children1.map((e) => (e as Map)['pid']), equals(<int>[pidA]));
      expect(running1.map((e) => (e as Map)['pid']), equals(<int>[pidB]));

      // Now finish B and call sys_wait() without pids -> only B is returned (A already reaped)
      releaseSlow.complete();
      final wait2 = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: const <String, dynamic>{'timeoutMs': 5000},
        ),
      );
      expect(wait2.ok, isTrue);
      expect(wait2.value!['timedOut'], isFalse);
      expect(wait2.value!['running'], isEmpty);
      final children2 = wait2.value!['children'] as List<dynamic>;
      expect(children2.map((e) => (e as Map)['pid']), equals(<int>[pidB]));
      expect((children2.single as Map)['summary'], equals('SLOW_DONE'));
    });

    test('REQ-03(c)(e): parent can SIGKILL running child after timed-out sys_wait, and orphan cleanup kills unawaited child on turn exit', () async {
      final k = createBaseKernel('req03_kill_orphan');
      final blockForever = Completer<void>();
      k.gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          await blockForever.future.timeout(const Duration(seconds: 10), onTimeout: () {});
          return LlmChatResponse(
            content: 'unreachable',
            usage: const LlmUsageTelemetry(promptTokens: 1, completionTokens: 1, durationMs: 1),
          );
        }),
      );
      final host = wireHost(
        processTable: k.processTable,
        quotaLedger: k.quotaLedger,
        gate: k.gate,
      );
      addTearDown(() async {
        if (!blockForever.isCompleted) {
          blockForever.complete();
        }
        await host.dispose();
      });

      // (c) timed-out sys_wait -> running -> sys_kill(SIGKILL) -> sys_wait confirms KILLED_BY_SIGNAL
      final spawnKill = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Kill after wait timeout',
          },
        ),
      );
      final killPid = spawnKill.value!['childPid'] as int;
      final waitTimeout = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[killPid], 'timeoutMs': 60},
        ),
      );
      expect(waitTimeout.value!['timedOut'], isTrue);
      expect((waitTimeout.value!['running'] as List), hasLength(1));

      final killRes = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_kill',
          args: <String, dynamic>{'pid': killPid, 'signal': 'SIGKILL'},
        ),
      );
      expect(killRes.ok, isTrue);

      final waitKilled = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[killPid], 'timeoutMs': 5000},
        ),
      );
      expect(waitKilled.ok, isTrue);
      expect(waitKilled.value!['timedOut'], isFalse);
      final killedStatus =
          (waitKilled.value!['children'] as List).single as Map<String, dynamic>;
      expect(killedStatus['ok'], isFalse);
      expect(killedStatus['reason'], equals('SYS_KILL_SIGKILL'));
      expect(killedStatus['exitCode'], equals(137));

      // (e) timed-out sys_wait -> parent turn exits without re-waiting -> PARENT_TURN_ENDED cleanup
      final spawnOrphan = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_spawn',
          args: const <String, dynamic>{
            'profile': 'workspace_worker',
            'taskPrompt': 'Orphan after wait timeout',
          },
        ),
      );
      final orphanPid = spawnOrphan.value!['childPid'] as int;
      final waitOrphanTimeout = await k.gate.invoke(
        k.leadCtx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[orphanPid], 'timeoutMs': 60},
        ),
      );
      expect(waitOrphanTimeout.value!['timedOut'], isTrue);
      expect(k.parentPcb.quotaUsage.activeChildProcesses, equals(1));

      await host.terminateActiveChildrenForParent(1);
      expect(k.parentPcb.quotaUsage.activeChildProcesses, equals(0));
      final snapAfterCleanup = host
          .snapshotProcesses()
          .firstWhere((p) => p['pid'] == orphanPid);
      expect(snapAfterCleanup['state'], equals('failed'));
    });
  });
}

class _AlwaysAllowApprovalHandler implements ApprovalHandler {
  @override
  Future<ApprovalDecision> requestApproval(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) async {
    return const ApprovalDecision.allowOnce();
  }
}

SyscallDefinition _buildTestLlmChatSyscall(
  Future<LlmChatResponse> Function(
    ModelIdentifier model,
    List<ProjectedMessage> messages,
    SyscallExecutionContext exec,
  ) onLlmChat,
) {
  return SyscallDefinition(
    name: 'sys_llm_chat',
    requiredRight: CapRight.llmInfer,
    kind: 'llm',
    applyIoCap: false,
    evaluatePolicy: (_, _) async => RingDecision.allow,
    handler: (exec) async {
      final model = ModelIdentifier.parse(exec.args['model'] as String).value!;
      final prep = const ContextPager().prepareFrameForModel(
        memory: exec.pcb.memory,
        targetModel: model,
        windowSpec: const ContextWindowSpec(
          contextWindowTokens: 32000,
          source: 'test_static',
        ),
      );
      if (!prep.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(prep.error!);
      }
      final projected = const CanonicalIrProjector().project(
        exec.pcb.memory,
        targetProvider: model.provider.id,
        targetModel: model.modelName,
      );
      final resp = await onLlmChat(model, projected.messages, exec);
      exec.pcb.quotaUsage.recordUsage(
        tokens: resp.usage.totalTokens,
        costMicroUsd: resp.usage.costMicroUsd ?? 0,
      );
      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'content': resp.content,
        'toolCalls': resp.toolCalls
            .map(
              (tc) => <String, dynamic>{
                'id': tc.id,
                'name': tc.name,
                'arguments': tc.arguments,
              },
            )
            .toList(growable: false),
        'usage': <String, dynamic>{
          'promptTokens': resp.usage.promptTokens,
          'completionTokens': resp.usage.completionTokens,
          'totalTokens': resp.usage.totalTokens,
          if (resp.usage.costMicroUsd != null)
            'costMicroUsd': resp.usage.costMicroUsd,
        },
      });
    },
  );
}

Future<ProcessResult> _runCmd(
  String exe,
  List<String> args,
  String workingDir,
) async {
  final res = await Process.run(
    exe,
    args,
    workingDirectory: workingDir,
    runInShell: false,
    environment: JjDriver.buildNonInteractiveEnvironment(),
  );
  if (res.exitCode != 0) {
    throw StateError(
      '$exe ${args.join(' ')} failed (${res.exitCode}): ${res.stderr}',
    );
  }
  return res;
}
