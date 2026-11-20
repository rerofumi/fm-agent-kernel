import 'dart:async';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Signals (SIGSTOP/SIGCONT/SIGKILL) ([D-312]..[D-314])', () {
    late Directory tempDir;
    late String repoRoot;
    late JjDriver jjDriver;
    late HostFsDriver fsDriver;
    late Win32JobExecDriver execDriver;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_wp5_sig_');
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
      execDriver = Win32JobExecDriver(
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        ensureActiveTransactionForPcb: jjDriver.ensureActiveTransactionForPcb,
        syncWorkingCopySnapshotForPcb: jjDriver.syncWorkingCopySnapshotForPcb,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        for (var i = 0; i < 3; i++) {
          try {
            await tempDir.delete(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    });

    test(
      'LeadAgent Case A (pre-Step1) & Case B (mid-tool-loop) SIGSTOP/SIGCONT preserve tool_call_id 1:1 pairing and Segment 1 prefix',
      () async {
        final cspace = CapabilityTable.stage3LeadAgent();
        final capHandle = cspace.entries.first.handle;
        final processTable = KernelProcessTable.stage2();
        final leadPcb = ProcessControlBlock(
          pid: 1,
          name: 'lead',
          ring: ProtectionRing.ring2,
          cspace: cspace,
          quota: ResourceQuota.stage2Default,
          namespace: VfsNamespace(workspaceHostRoot: repoRoot),
          memory: VirtualContextMemory(
            sessionId: 'sig_lead_ab',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'System',
              tools: const <SyscallToolSchema>[],
            ),
          ),
        );
        processTable.registerProcess(leadPcb);

        final auditLogger = AuditLogger(
          sessionId: 'sig_lead_ab',
          workspaceHostRoot: repoRoot,
          redactor: SecretRedactor(),
        );
        final gate = SyscallGate(
          processTable: processTable,
          approvalGate: ApprovalGate(
            handler: _AlwaysAllowApprovalHandler(),
          ),
          ioCapper: IoPayloadCapper(),
          auditLogger: auditLogger,
        );
        for (final def in fsDriver.buildReadSyscallDefinitions()) {
          gate.registerSyscall(def);
        }

        final stepPrompts = <List<ProjectedMessage>>[];
        var llmStep = 0;
        final firstToolStarted = Completer<void>();
        final secondToolGate = Completer<void>();

        gate.registerSyscall(
          _buildTestLlmChatSyscall((model, messages) async {
            llmStep += 1;
            stepPrompts.add(List<ProjectedMessage>.from(messages));
            if (llmStep == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_1',
                    name: 'sys_read_lines',
                    arguments: <String, dynamic>{'path': '/workspace/README.md'},
                  ),
                  LlmToolCallSpec(
                    id: 'tc_2',
                    name: 'sys_read_lines',
                    arguments: <String, dynamic>{'path': '/workspace/README.md'},
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
              content: 'DONE_WITH_CONSTRAINTS',
              usage: const LlmUsageTelemetry(
                promptTokens: 30,
                completionTokens: 10,
                durationMs: 1,
              ),
            );
          }),
        );

        // Wrap sys_read_lines to signal mid-step pause between tc_1 and tc_2.
        var readCount = 0;
        final origRead = fsDriver
            .buildReadSyscallDefinitions()
            .firstWhere((d) => d.name == 'sys_read_lines');
        gate.registerSyscall(
          SyscallDefinition(
            name: origRead.name,
            requiredRight: origRead.requiredRight,
            kind: origRead.kind,
            applyIoCap: origRead.applyIoCap,
            cappedTextFields: origRead.cappedTextFields,
            validateArgs: origRead.validateArgs,
            evaluatePolicy: origRead.evaluatePolicy,
            handler: (exec) async {
              readCount += 1;
              if (readCount == 1 && !firstToolStarted.isCompleted) {
                firstToolStarted.complete();
                await secondToolGate.future;
              }
              return origRead.handler(exec);
            },
          ),
        );

        final leadAgent = LeadAgent(
          pcb: leadPcb,
          syscallGate: gate,
          capHandle: capHandle,
          modelResolver: ModelResolver(),
        );
        final runner = GreenTaskProcessRunner(leadAgent: leadAgent);

        // Case A: SIGSTOP -> SIGCONT with constraint BEFORE Step 1 runs.
        runner.sendSignal(ProcessSignalKind.sigstop, reason: 'case_a_stop');
        expect(leadPcb.state, ProcessState.stopped);

        final turnFuture = runner.submitPrompt(userInput: 'Initial task');
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(llmStep, 0, reason: 'SIGSTOP must freeze Step 1 before sys_llm_chat');

        runner.sendSignal(
          ProcessSignalKind.sigcont,
          constraintMessage: 'CASE_A_TAG',
        );

        await firstToolStarted.future;
        // Case B: While tc_1 finished / before tc_2 enters SyscallGate, send SIGSTOP.
        runner.sendSignal(ProcessSignalKind.sigstop, reason: 'case_b_stop');
        secondToolGate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(readCount, 1, reason: 'SIGSTOP must pause tc_2 at Stage 0.5');
        expect(leadPcb.state, ProcessState.stopped);

        runner.sendSignal(
          ProcessSignalKind.sigcont,
          constraintMessage: 'CASE_B_TAG',
        );

        final turnRes = await turnFuture;
        expect(turnRes.ok, isTrue, reason: turnRes.error?.message);
        expect(turnRes.finalText, 'DONE_WITH_CONSTRAINTS');
        expect(llmStep, 2);

        // Step 1 received CASE_A_TAG in user prompt.
        expect(
          stepPrompts[0].last.content,
          contains('[Runtime Policy Update / SIGCONT]\nCASE_A_TAG'),
        );

        // Step 2 must retain CASE_A_TAG in first user turn, have 1:1 tool_call_id pairing,
        // and append CASE_B_TAG strictly AFTER all tool results.
        final msgs2 = stepPrompts[1];
        final assistantIdx =
            msgs2.indexWhere((m) => m.role == ProjectedRole.assistant);
        expect(assistantIdx, greaterThan(0));
        expect(msgs2[assistantIdx].toolCalls.length, 2);
        expect(msgs2[assistantIdx + 1].role, ProjectedRole.tool);
        expect(msgs2[assistantIdx + 2].role, ProjectedRole.tool);
        expect(
          msgs2[assistantIdx + 1].toolCallId,
          msgs2[assistantIdx].toolCalls[0].id,
        );
        expect(
          msgs2[assistantIdx + 2].toolCallId,
          msgs2[assistantIdx].toolCalls[1].id,
        );
        expect(msgs2[assistantIdx + 3].role, ProjectedRole.user);
        expect(
          msgs2[assistantIdx + 3].content,
          contains('[Runtime Policy Update / SIGCONT]\nCASE_B_TAG'),
        );
        // Case A constraint preserved in Segment 1 history.
        final firstUserMsg =
            msgs2.firstWhere((m) => m.role == ProjectedRole.user);
        expect(firstUserMsg.content, contains('CASE_A_TAG'));

        // Segment 1 prefix up to assistant+tools is strictly unchanged.
        expect(msgs2[0].content, stepPrompts[0][0].content);

        await runner.dispose();
      },
    );

    test(
      'Child worker host hook supports Case A/B SIGSTOP/SIGCONT with wallTimer freeze and 1:1 tool_call_id pairing',
      () async {
        final processTable = KernelProcessTable.stage2();
        final quotaLedger = QuotaLedger();
        final cspace = CapabilityTable.stage3LeadAgent();
        final parentPcb = ProcessControlBlock(
          pid: 1,
          name: 'lead',
          ring: ProtectionRing.ring2,
          cspace: cspace,
          quota: ResourceQuota.stage2Default,
          namespace: VfsNamespace(workspaceHostRoot: repoRoot),
          memory: VirtualContextMemory(
            sessionId: 'sig_child_ab',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'System',
              tools: const <SyscallToolSchema>[],
            ),
          ),
        );
        processTable.registerProcess(parentPcb);

        final gate = SyscallGate(
          processTable: processTable,
          approvalGate: ApprovalGate(
            handler: _AlwaysAllowApprovalHandler(),
          ),
          ioCapper: IoPayloadCapper(),
          auditLogger: AuditLogger(
            sessionId: 'sig_child_ab',
            workspaceHostRoot: repoRoot,
            redactor: SecretRedactor(),
          ),
        );
        for (final def in fsDriver.buildReadSyscallDefinitions()) {
          gate.registerSyscall(def);
        }

        final childPrompts = <List<ProjectedMessage>>[];
        var childStep = 0;
        gate.registerSyscall(
          _buildTestLlmChatSyscall((model, messages) async {
            childStep += 1;
            childPrompts.add(List<ProjectedMessage>.from(messages));
            if (childStep == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'c_tc_1',
                    name: 'sys_read_lines',
                    arguments: <String, dynamic>{'path': '/workspace/README.md'},
                  ),
                  LlmToolCallSpec(
                    id: 'c_tc_2',
                    name: 'sys_read_lines',
                    arguments: <String, dynamic>{'path': '/workspace/README.md'},
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
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'c_tc_exit',
                  name: 'sys_exit',
                  arguments: <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'child_ok',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 30,
                completionTokens: 10,
                durationMs: 1,
              ),
            );
          }),
        );

        final toolEntered = Completer<void>();
        final origRead = fsDriver
            .buildReadSyscallDefinitions()
            .firstWhere((d) => d.name == 'sys_read_lines');
        var childReadCount = 0;
        gate.registerSyscall(
          SyscallDefinition(
            name: origRead.name,
            requiredRight: origRead.requiredRight,
            kind: origRead.kind,
            applyIoCap: origRead.applyIoCap,
            cappedTextFields: origRead.cappedTextFields,
            validateArgs: origRead.validateArgs,
            evaluatePolicy: origRead.evaluatePolicy,
            handler: (exec) async {
              childReadCount += 1;
              if (childReadCount == 1 && !toolEntered.isCompleted) {
                toolEntered.complete();
              }
              return origRead.handler(exec);
            },
          ),
        );

        late final IsolateWorkerHost host;
        host = IsolateWorkerHost(
          processTable: processTable,
          syscallGate: gate,
          quotaLedger: quotaLedger,
          jjDriver: jjDriver,
          toolSchemaProvider: (pcb) => filterToolSchemasForPcb(
            pcb: pcb,
            allSchemas: <SyscallToolSchema>[
              ...buildProcessToolSchemas(),
              ...HostFsDriver.readToolSchemas(),
            ],
          ),
          parentCurrentModelProvider: () => 'local-ollama/gemma4:12b',
          backend: const GreenTaskChildWorkerBackend(),
        );
        for (final def in buildProcessSyscallDefinitions(
          host: host,
          processTable: processTable,
        )) {
          gate.registerSyscall(def);
        }

        final ctx = SyscallContext(
          pid: 1,
          capHandle: cspace.entries.first.handle,
          sessionId: 'sig_child_ab',
        );
        final spawnRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'explorer',
              'taskPrompt': 'Inspect README',
              // Short wall time; must NOT expire during SIGSTOP freeze!
              'maxWallTimeMs': 180,
            },
          ),
        );
        expect(spawnRes.ok, isTrue, reason: spawnRes.error?.message);
        final childPid = spawnRes.value!['childPid'] as int;

        // Wait until Step 1 calls tool 1, then SIGSTOP and sleep longer than maxWallTimeMs.
        await toolEntered.future;
        final stopRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_kill',
            args: <String, dynamic>{
              'pid': childPid,
              'signal': 'SIGSTOP',
              'constraintMessage': 'CHILD_CONSTRAINT_B',
            },
          ),
        );
        expect(stopRes.ok, isTrue, reason: stopRes.error?.message);
        expect(stopRes.value!['state'], 'stopped');

        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(
          processTable.getProcess(childPid)!.state,
          ProcessState.stopped,
          reason: 'wallTimer must be frozen during SIGSTOP',
        );

        final contRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_kill',
            args: <String, dynamic>{
              'pid': childPid,
              'signal': 'SIGCONT',
            },
          ),
        );
        expect(contRes.ok, isTrue, reason: contRes.error?.message);

        final waitRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_wait',
            args: <String, dynamic>{
              'pids': <int>[childPid],
            },
          ),
        );
        expect(waitRes.ok, isTrue, reason: waitRes.error?.message);
        final childStatus =
            (waitRes.value!['children'] as List).first as Map<String, dynamic>;
        expect(childStatus['ok'], isTrue, reason: '${childStatus['reason']}');
        expect(childStatus['summary'], 'child_ok');

        // Verify Step 2 child prompt has 1:1 tool pairing followed by SIGCONT constraint.
        final msgs2 = childPrompts[1];
        final assistantIdx =
            msgs2.indexWhere((m) => m.role == ProjectedRole.assistant);
        expect(msgs2[assistantIdx].toolCalls.length, 2);
        expect(msgs2[assistantIdx + 1].role, ProjectedRole.tool);
        expect(msgs2[assistantIdx + 2].role, ProjectedRole.tool);
        expect(msgs2[assistantIdx + 3].role, ProjectedRole.user);
        expect(msgs2[assistantIdx + 3].content, contains('CHILD_CONSTRAINT_B'));

        await host.dispose();
      },
    );

    test(
      'SIGKILL atomically kills active child tree, aborts Win32 Job / Isolate, cleans up jj workspace, suppresses retry, and settles quota once',
      () async {
        final processTable = KernelProcessTable.stage2();
        final quotaLedger = QuotaLedger();
        final cspace = CapabilityTable.stage3LeadAgent();
        final parentPcb = ProcessControlBlock(
          pid: 1,
          name: 'lead',
          ring: ProtectionRing.ring2,
          cspace: cspace,
          quota: const ResourceQuota(
            maxChildProcesses: 4,
            maxTotalTokens: 10000,
          ),
          namespace: VfsNamespace(workspaceHostRoot: repoRoot),
          memory: VirtualContextMemory(
            sessionId: 'sigkill_tree',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'System',
              tools: const <SyscallToolSchema>[],
            ),
          ),
        );
        processTable.registerProcess(parentPcb);

        final gate = SyscallGate(
          processTable: processTable,
          approvalGate: ApprovalGate(
            handler: _AlwaysAllowApprovalHandler(),
          ),
          ioCapper: IoPayloadCapper(),
          auditLogger: AuditLogger(
            sessionId: 'sigkill_tree',
            workspaceHostRoot: repoRoot,
            redactor: SecretRedactor(),
          ),
        );
        for (final def in fsDriver.buildReadSyscallDefinitions()) {
          gate.registerSyscall(def);
        }
        gate.registerSyscall(execDriver.buildSyscallDefinition());

        final childBlockingStarted = Completer<void>();
        gate.registerSyscall(
          _buildTestLlmChatSyscall((model, messages) async {
            if (!childBlockingStarted.isCompleted) {
              childBlockingStarted.complete();
            }
            await Future<void>.delayed(const Duration(seconds: 10));
            return LlmChatResponse(
              content: 'unreachable',
              usage: const LlmUsageTelemetry(
                promptTokens: 1,
                completionTokens: 1,
                durationMs: 1,
              ),
            );
          }),
        );

        final host = IsolateWorkerHost(
          processTable: processTable,
          syscallGate: gate,
          quotaLedger: quotaLedger,
          jjDriver: jjDriver,
          toolSchemaProvider: (pcb) => filterToolSchemasForPcb(
            pcb: pcb,
            allSchemas: buildProcessToolSchemas(),
          ),
          parentCurrentModelProvider: () => 'local-ollama/gemma4:12b',
          backend: const GreenTaskChildWorkerBackend(),
        );
        for (final def in buildProcessSyscallDefinitions(
          host: host,
          processTable: processTable,
        )) {
          gate.registerSyscall(def);
        }

        final ctx = SyscallContext(
          pid: 1,
          capHandle: cspace.entries.first.handle,
          sessionId: 'sigkill_tree',
        );
        final spawnRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'Long work',
              'maxTotalTokens': 4000,
              'supervision': <String, dynamic>{
                'restart': 'on_failure',
                'maxRetries': 2,
              },
            },
          ),
        );
        expect(spawnRes.ok, isTrue, reason: spawnRes.error?.message);
        final childPid = spawnRes.value!['childPid'] as int;
        final wsName = spawnRes.value!['workspaceName'] as String;
        final wsChangeId = spawnRes.value!['workingChangeId'] as String;

        await childBlockingStarted.future;
        // Also put child in SIGSTOP first to verify SIGKILL overrides SIGSTOP + Supervisor!
        await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_kill',
            args: <String, dynamic>{'pid': childPid, 'signal': 'SIGSTOP'},
          ),
        );

        final killRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_kill',
            args: <String, dynamic>{'pid': childPid, 'signal': 'SIGKILL'},
          ),
        );
        expect(killRes.ok, isTrue, reason: killRes.error?.message);

        final waitRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_wait',
            args: <String, dynamic>{
              'pids': <int>[childPid],
            },
          ),
        );
        expect(waitRes.ok, isTrue, reason: waitRes.error?.message);
        final status =
            (waitRes.value!['children'] as List).first as Map<String, dynamic>;
        expect(status['ok'], isFalse);
        expect(status['exitCode'], 137);
        expect(status['workspaceCleanedUp'], isTrue);
        // Supervisor must NOT retry after SIGKILL.
        expect((status['attempts'] as List).length, 1);

        // Workspace directory & jj workspace registration & unintegrated change are all gone.
        expect(
          Directory(p.join(repoRoot, '.agent_os', 'ws', '$childPid')).existsSync(),
          isFalse,
        );
        final wsList = await jjDriver.listWorkspaces();
        expect(
          wsList.value!.map((e) => e['name']).toList(),
          equals(<String>['default']),
          reason: '$wsName must be forgotten',
        );
        final abandonedCheck = await jjDriver.log(revset: wsChangeId);
        expect(abandonedCheck.ok, isFalse, reason: 'Unintegrated change must be abandoned');

        // Quota settled exactly once (0 active children, 0 donated out).
        expect(parentPcb.quotaUsage.activeChildProcesses, 0);
        expect(parentPcb.quotaUsage.donatedTokensOut, 0);

        await host.dispose();
      },
    );
  });

  group('Supervisor Automatic Recovery DI Fault Injection ([D-315])', () {
    late Directory tempDir;
    late String repoRoot;
    late JjDriver jjDriver;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_wp5_sup_');
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
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        for (var i = 0; i < 3; i++) {
          try {
            await tempDir.delete(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    });

    Future<({
      KernelProcessTable processTable,
      QuotaLedger quotaLedger,
      ProcessControlBlock parentPcb,
      SyscallGate gate,
      IsolateWorkerHost host,
      SyscallContext ctx,
    })> createHarness({
      required Future<LlmChatResponse> Function(
        ModelIdentifier model,
        List<ProjectedMessage> messages,
      ) onLlmChat,
      ChildWorkerBackend backend = const GreenTaskChildWorkerBackend(),
      ResourceQuota parentQuota = ResourceQuota.stage2Default,
    }) async {
      final processTable = KernelProcessTable.stage2();
      final quotaLedger = QuotaLedger();
      final cspace = CapabilityTable.stage3LeadAgent();
      final parentPcb = ProcessControlBlock(
        pid: 1,
        name: 'lead',
        ring: ProtectionRing.ring2,
        cspace: cspace,
        quota: parentQuota,
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        memory: VirtualContextMemory(
          sessionId: 'sup_test',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
      processTable.registerProcess(parentPcb);

      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(
          handler: _AlwaysAllowApprovalHandler(),
        ),
        ioCapper: IoPayloadCapper(),
        auditLogger: AuditLogger(
          sessionId: 'sup_test',
          workspaceHostRoot: repoRoot,
          redactor: SecretRedactor(),
        ),
      );
      gate.registerSyscall(_buildTestLlmChatSyscall(onLlmChat));

      final host = IsolateWorkerHost(
        processTable: processTable,
        syscallGate: gate,
        quotaLedger: quotaLedger,
        jjDriver: jjDriver,
        toolSchemaProvider: (pcb) => filterToolSchemasForPcb(
          pcb: pcb,
          allSchemas: buildProcessToolSchemas(),
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

      return (
        processTable: processTable,
        quotaLedger: quotaLedger,
        parentPcb: parentPcb,
        gate: gate,
        host: host,
        ctx: SyscallContext(
          pid: 1,
          capHandle: cspace.entries.first.handle,
          sessionId: 'sup_test',
        ),
      );
    }

    test('① WORKER_CRASHED cleans up old workspace & succeeds on retry with 1:1 attempts[]', () async {
      var launchCount = 0;
      final backend = _CallbackChildWorkerBackend((config) async {
        launchCount += 1;
        if (launchCount == 1) {
          config.onWorkerFatal('Simulated uncaught crash');
          return _NoopChildHandle();
        }
        config.onWorkerDone(
          const ChildWorkerExitReport(
            ok: true,
            exitCode: 0,
            reason: 'EXITED_NORMALLY',
            summary: 'recovered_after_crash',
          ),
        );
        return _NoopChildHandle();
      });

      final h = await createHarness(
        onLlmChat: (_, _) async => LlmChatResponse(
          content: '',
          usage: const LlmUsageTelemetry(
            promptTokens: 1,
            completionTokens: 1,
            durationMs: 1,
          ),
        ),
        backend: backend,
      );

      final spawnRes = await h.gate.invoke(
        h.ctx,
        SyscallRequest(
          name: 'sys_spawn',
          args: <String, dynamic>{
            'profile': 'workspace_worker',
            'taskPrompt': 'Crash then recover',
            'supervision': <String, dynamic>{
              'restart': 'on_failure',
              'maxRetries': 1,
            },
          },
        ),
      );
      expect(spawnRes.ok, isTrue, reason: spawnRes.error?.message);
      final initialPid = spawnRes.value!['childPid'] as int;
      final firstChangeId = spawnRes.value!['workingChangeId'] as String;

      final waitRes = await h.gate.invoke(
        h.ctx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[initialPid]},
        ),
      );
      expect(waitRes.ok, isTrue);
      final status =
          (waitRes.value!['children'] as List).first as Map<String, dynamic>;
      expect(status['ok'], isTrue);
      expect(status['summary'], 'recovered_after_crash');
      final attempts = (status['attempts'] as List).cast<Map<String, dynamic>>();
      expect(attempts.length, 2);
      expect(attempts[0]['ok'], isFalse);
      expect(attempts[0]['reason'], 'WORKER_CRASHED');
      expect(attempts[0]['pid'], initialPid);
      expect(attempts[0]['workingChangeId'], firstChangeId);
      expect(attempts[0]['workspaceCleanedUp'], isTrue);
      expect(attempts[1]['ok'], isTrue);
      expect(attempts[1]['pid'], isNot(equals(initialPid)));
      expect(attempts[1]['workingChangeId'], isNot(equals(firstChangeId)));

      // Old workspace directory & unintegrated change must be gone.
      expect(
        Directory(p.join(repoRoot, '.agent_os', 'ws', '$initialPid')).existsSync(),
        isFalse,
      );
      expect((await jjDriver.log(revset: firstChangeId)).ok, isFalse);

      await h.host.dispose();
    });

    test('② MALFORMED_TOOL_CALL & ④ EPROVIDER switch to fallbackModel and succeed', () async {
      var callIdx = 0;
      final seenModels = <String>[];
      final h = await createHarness(
        onLlmChat: (model, _) async {
          callIdx += 1;
          seenModels.add(model.canonicalId);
          if (callIdx == 1) {
            throw const _InjectedLlmError(
              SyscallError(
                code: SyscallErrorCode.eprovider,
                reason: 'MALFORMED_TOOL_CALL',
                message: 'Invalid JSON tool call from primary model',
                recoverable: true,
              ),
            );
          }
          return LlmChatResponse(
            content: '',
            toolCalls: <LlmToolCallSpec>[
              LlmToolCallSpec(
                id: 'ok_exit',
                name: 'sys_exit',
                arguments: <String, dynamic>{
                  'exitCode': 0,
                  'summary': 'fallback_succeeded',
                },
              ),
            ],
            usage: const LlmUsageTelemetry(
              promptTokens: 60,
              completionTokens: 20,
              durationMs: 1,
            ),
          );
        },
      );

      final spawnRes = await h.gate.invoke(
        h.ctx,
        SyscallRequest(
          name: 'sys_spawn',
          args: <String, dynamic>{
            'profile': 'workspace_worker',
            'taskPrompt': 'Use fallback',
            'model': 'local-ollama/broken:0b',
            'supervision': <String, dynamic>{
              'restart': 'on_failure',
              'maxRetries': 1,
              'fallbackModel': 'local-ollama/gemma4:12b',
            },
          },
        ),
      );
      expect(spawnRes.ok, isTrue, reason: spawnRes.error?.message);
      final pid = spawnRes.value!['childPid'] as int;

      final waitRes = await h.gate.invoke(
        h.ctx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[pid]},
        ),
      );
      final status =
          (waitRes.value!['children'] as List).first as Map<String, dynamic>;
      expect(status['ok'], isTrue);
      expect(status['summary'], 'fallback_succeeded');
      expect(seenModels, <String>[
        'local-ollama/broken:0b',
        'local-ollama/gemma4:12b',
      ]);
      final attempts = (status['attempts'] as List).cast<Map<String, dynamic>>();
      expect(attempts[0]['model'], 'local-ollama/broken:0b');
      expect(attempts[1]['model'], 'local-ollama/gemma4:12b');

      await h.host.dispose();
    });

    test('③ WALL_TIME_QUOTA_EXCEEDED retries cleanly and ⑤ reports structured error on maxRetries exhaustion', () async {
      var attempt = 0;
      final h = await createHarness(
        onLlmChat: (_, _) async {
          attempt += 1;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          return LlmChatResponse(
            content: 'late',
            usage: const LlmUsageTelemetry(
              promptTokens: 1,
              completionTokens: 1,
              durationMs: 1,
            ),
          );
        },
      );

      final spawnRes = await h.gate.invoke(
        h.ctx,
        SyscallRequest(
          name: 'sys_spawn',
          args: <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Hang repeatedly',
            'maxWallTimeMs': 60,
            'supervision': <String, dynamic>{
              'restart': 'on_failure',
              'maxRetries': 1,
            },
          },
        ),
      );
      expect(spawnRes.ok, isTrue);
      final pid = spawnRes.value!['childPid'] as int;

      final waitRes = await h.gate.invoke(
        h.ctx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[pid]},
        ),
      );
      final status =
          (waitRes.value!['children'] as List).first as Map<String, dynamic>;
      expect(status['ok'], isFalse);
      expect(status['reason'], 'WALL_TIME_QUOTA_EXCEEDED');
      final attempts = (status['attempts'] as List).cast<Map<String, dynamic>>();
      expect(attempts.length, 2);
      expect(attempts[0]['reason'], 'WALL_TIME_QUOTA_EXCEEDED');
      expect(attempts[1]['reason'], 'WALL_TIME_QUOTA_EXCEEDED');
      expect(attempt, 2);

      await h.host.dispose();
    });

    test('⑥ TOKEN_QUOTA_EXCEEDED stops immediately with 0 retries', () async {
      var calls = 0;
      final h = await createHarness(
        onLlmChat: (_, _) async {
          calls += 1;
          throw const _InjectedLlmError(
            SyscallError(
              code: SyscallErrorCode.edquot,
              reason: 'TOKEN_QUOTA_EXCEEDED',
              message: 'Token quota exhausted',
              recoverable: false,
            ),
          );
        },
      );

      final spawnRes = await h.gate.invoke(
        h.ctx,
        SyscallRequest(
          name: 'sys_spawn',
          args: <String, dynamic>{
            'profile': 'explorer',
            'taskPrompt': 'Quota test',
            'maxTotalTokens': 2000,
            'supervision': <String, dynamic>{
              'restart': 'on_failure',
              'maxRetries': 3,
            },
          },
        ),
      );
      expect(spawnRes.ok, isTrue);
      final pid = spawnRes.value!['childPid'] as int;

      final waitRes = await h.gate.invoke(
        h.ctx,
        SyscallRequest(
          name: 'sys_wait',
          args: <String, dynamic>{'pids': <int>[pid]},
        ),
      );
      final status =
          (waitRes.value!['children'] as List).first as Map<String, dynamic>;
      expect(status['ok'], isFalse);
      expect(status['reason'], 'TOKEN_QUOTA_EXCEEDED');
      expect((status['attempts'] as List).length, 1);
      expect(calls, 1);

      await h.host.dispose();
    });

    test(
      '⑦ & ⑧ Quota conservation law holds even when parent maxTotalTokens == null (stage2Default) and child specifies maxTotalTokens',
      () async {
        // Parent has maxTotalTokens == null; child has 700.
        // Attempt 1 consumes 400 tokens and fails -> remaining = 300 < minRetryTokenReserve (512) -> RETRY_BUDGET_EXHAUSTED!
        final h = await createHarness(
          parentQuota: ResourceQuota.stage2Default,
          onLlmChat: (_, _) async {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'fail_exit',
                  name: 'sys_exit',
                  arguments: <String, dynamic>{
                    'exitCode': 1,
                    'summary': 'failed_1',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 300,
                completionTokens: 100,
                durationMs: 1,
              ),
            );
          },
        );

        final spawnRes = await h.gate.invoke(
          h.ctx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'explorer',
              'taskPrompt': 'Check conservation',
              'maxTotalTokens': 700,
              'supervision': <String, dynamic>{
                'restart': 'on_failure',
                'maxRetries': 2,
              },
            },
          ),
        );
        expect(spawnRes.ok, isTrue);
        final pid = spawnRes.value!['childPid'] as int;

        final waitRes = await h.gate.invoke(
          h.ctx,
          SyscallRequest(
            name: 'sys_wait',
            args: <String, dynamic>{'pids': <int>[pid]},
          ),
        );
        final status =
            (waitRes.value!['children'] as List).first as Map<String, dynamic>;
        expect(status['ok'], isFalse);
        expect(status['reason'], 'RETRY_BUDGET_EXHAUSTED');
        expect(status['consumedTokens'], 400);
        expect(h.parentPcb.quotaUsage.totalTokensUsed, 400);
        expect((status['attempts'] as List).length, 1);

        await h.host.dispose();
      },
    );
  });

  group('StackedTaskManager & sys_task_stack 7 Actions ([D-311])', () {
    late Directory tempDir;
    late String repoRoot;
    late JjDriver jjDriver;
    late StackedTaskManager manager;
    late SyscallGate gate;
    late SyscallContext leadCtx;
    late ProcessControlBlock leadPcb;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_wp5_stack_');
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
      await File(p.join(repoRoot, 'lib.dart')).writeAsString('int v() => 1;\n');
      await _runCmd('jj', <String>['commit', '-m', 'initial'], repoRoot);

      jjDriver = JjDriver.forWorkspace(repoRoot);
      manager = StackedTaskManager(jjDriver: jjDriver);

      final processTable = KernelProcessTable.stage2();
      final cspace = CapabilityTable.stage3LeadAgent();
      leadPcb = ProcessControlBlock(
        pid: 1,
        name: 'lead',
        ring: ProtectionRing.ring2,
        cspace: cspace,
        quota: ResourceQuota.stage2Default,
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        memory: VirtualContextMemory(
          sessionId: 'stack_7',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
      processTable.registerProcess(leadPcb);
      leadCtx = SyscallContext(
        pid: 1,
        capHandle: cspace.entries.first.handle,
        sessionId: 'stack_7',
      );
      gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(
          handler: _AlwaysAllowApprovalHandler(),
        ),
        ioCapper: IoPayloadCapper(),
        auditLogger: AuditLogger(
          sessionId: 'stack_7',
          workspaceHostRoot: repoRoot,
          redactor: SecretRedactor(),
        ),
      );
      gate.registerSyscall(manager.buildSyscallDefinition());
    });

    tearDown(() async {
      await manager.dispose();
      if (tempDir.existsSync()) {
        for (var i = 0; i < 3; i++) {
          try {
            await tempDir.delete(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    });

    test('executes all 7 sys_task_stack actions and excludes sys_kill/sys_task_stack from Ring 3', () async {
      // Ring 3 schema filtering check
      final childPcb = ProcessControlBlock(
        pid: 2,
        parentPid: 1,
        name: 'wsw',
        ring: ProtectionRing.ring3,
        profile: ProcessProfileId.workspaceWorker,
        cspace: CapabilityTable.stage3LeadAgent()
            .deriveForProfile(ProcessProfileId.workspaceWorker)
            .value!,
        quota: const ResourceQuota(),
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        memory: VirtualContextMemory(
          sessionId: 'stack_7',
          systemInstruction: PinnedSystemInstruction(
            instruction: '',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
      final filtered = filterToolSchemasForPcb(
        pcb: childPcb,
        allSchemas: <SyscallToolSchema>[
          ...buildProcessToolSchemas(),
          StackedTaskManager.buildToolSchema(),
        ],
      );
      expect(filtered.any((s) => s.name == 'sys_kill'), isFalse);
      expect(filtered.any((s) => s.name == 'sys_task_stack'), isFalse);

      // 1. create c_A -> c_B -> c_C
      final cARes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{
            'action': 'create',
            'taskId': 'card_a',
            'title': 'Task A',
          },
        ),
      );
      expect(cARes.ok, isTrue, reason: cARes.error?.message);

      final cBRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{
            'action': 'create',
            'taskId': 'card_b',
            'title': 'Task B',
            'parentTaskId': 'card_a',
          },
        ),
      );
      expect(cBRes.ok, isTrue, reason: cBRes.error?.message);

      final cCRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{
            'action': 'create',
            'taskId': 'card_c',
            'title': 'Task C',
            'parentTaskId': 'card_b',
          },
        ),
      );
      expect(cCRes.ok, isTrue, reason: cCRes.error?.message);

      // 2. edit card_a -> cascades to card_b and card_c
      final editARes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{
            'action': 'edit',
            'taskId': 'card_a',
            'relativePath': 'a.dart',
            'content': 'int a() => 42;\n',
          },
        ),
      );
      expect(editARes.ok, isTrue, reason: editARes.error?.message);
      expect((editARes.value!['cascadedTasks'] as List).length, 2);
      final wsBRoot = manager.registry.getByTaskId('card_b')!.workspaceRoot;
      final wsCRoot = manager.registry.getByTaskId('card_c')!.workspaceRoot;
      expect(await File(p.join(wsBRoot, 'a.dart')).readAsString(), 'int a() => 42;\n');
      expect(await File(p.join(wsCRoot, 'a.dart')).readAsString(), 'int a() => 42;\n');

      // 3. focus
      final focusRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{
            'action': 'focus',
            'taskId': 'card_a',
            'state': 'review',
          },
        ),
      );
      expect(focusRes.ok, isTrue);
      expect((focusRes.value!['task'] as Map)['state'], 'review');
      expect(focusRes.value!['diff'], contains('42'));

      // 4. integrate_worker: allocate a worker off card_a, edit it, and integrate into card_a
      final wsWorker = await jjDriver.allocateWorkerWorkspace(
        pid: 99,
        baseChangeId: manager.registry.getByTaskId('card_a')!.workingChangeId,
      );
      await File(p.join(wsWorker.value!.workspaceRoot, 'w.dart'))
          .writeAsString('int w() => 7;\n');
      final workerCleanup = await jjDriver.cleanupWorkerWorkspace(
        workspaceName: wsWorker.value!.workspaceName,
        workspaceRoot: wsWorker.value!.workspaceRoot,
        workingChangeId: wsWorker.value!.workingChangeId,
        baseChangeId: wsWorker.value!.baseChangeId,
        abandonChange: false,
      );
      expect(workerCleanup.cleanedUp, isTrue);

      final intRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{
            'action': 'integrate_worker',
            'taskId': 'card_a',
            'workerChangeIds': <String>[wsWorker.value!.workingChangeId],
          },
        ),
      );
      expect(intRes.ok, isTrue, reason: intRes.error?.message);
      expect(intRes.value!['hasConflicts'], isFalse);
      expect(await File(p.join(wsCRoot, 'w.dart')).readAsString(), 'int w() => 7;\n');

      // 5. list & 6. sync
      final listRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{'action': 'list'},
        ),
      );
      expect(listRes.ok, isTrue);
      expect((listRes.value!['tasks'] as List).length, 3);

      final syncRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{'action': 'sync'},
        ),
      );
      expect(syncRes.ok, isTrue);

      // 7. remove (non-leaf rejected, leaf accepted)
      final badRemove = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_task_stack',
          args: <String, dynamic>{'action': 'remove', 'taskId': 'card_a'},
        ),
      );
      expect(badRemove.ok, isFalse);
      expect(badRemove.error!.code, SyscallErrorCode.econflict);

      for (final id in <String>['card_c', 'card_b', 'card_a']) {
        final rem = await gate.invoke(
          leadCtx,
          SyscallRequest(
            name: 'sys_task_stack',
            args: <String, dynamic>{'action': 'remove', 'taskId': id},
          ),
        );
        expect(rem.ok, isTrue, reason: rem.error?.message);
        expect(rem.value!['workspaceCleanedUp'], isTrue);
      }
    });
  });
}

class _InjectedLlmError implements Exception {
  const _InjectedLlmError(this.error);
  final SyscallError error;
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
      try {
        final resp = await onLlmChat(model, projected.messages);
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
      } on _InjectedLlmError catch (e) {
        return SyscallResult<Map<String, dynamic>>.failure(e.error);
      }
    },
  );
}

class _CallbackChildWorkerBackend implements ChildWorkerBackend {
  const _CallbackChildWorkerBackend(this._onSpawn);
  final Future<ChildWorkerHandle> Function(ChildWorkerLaunchConfig config)
      _onSpawn;

  @override
  Future<ChildWorkerHandle> spawn(ChildWorkerLaunchConfig config) =>
      _onSpawn(config);
}

class _NoopChildHandle implements ChildWorkerHandle {
  @override
  Future<void> killImmediate() async {}

  @override
  void sendCancel(String reason) {}
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
