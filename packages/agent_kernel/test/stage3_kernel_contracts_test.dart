import 'dart:async';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('Stage 3 ProcessProfile & CapabilityTable ([D-302], [D-306])', () {
    test('stage3LeadAgent holds mcpCall while stage2LeadAgent does not', () {
      final s2 = CapabilityTable.stage2LeadAgent();
      final s3 = CapabilityTable.stage3LeadAgent();
      expect(s2.hasAnyRight(CapRight.mcpCall), isFalse);
      expect(s3.hasAnyRight(CapRight.mcpCall), isTrue);
    });

    test('workspaceWorker & conflictResolver allow isolated mutation but forbid Stage 3 privileges', () {
      final parent = CapabilityTable.stage3LeadAgent();

      for (final profile in <ProcessProfileId>[
        ProcessProfileId.workspaceWorker,
        ProcessProfileId.conflictResolver,
      ]) {
        expect(profile.requiresIsolatedJjWorkspace, isTrue);
        expect(profile.allowsIsolatedWorkspaceMutation, isTrue);
        expect(profile.mountsWorkspace, isTrue);
        expect(profile.mountsSkills, isTrue);
        expect(profile.forcesVcsIgnoreWorkingCopy, isTrue);

        final derived = parent.deriveForProfile(profile);
        expect(derived.ok, isTrue, reason: derived.error?.toString());
        final child = derived.value!;
        expect(child.hasAnyRight(CapRight.writeCow), isTrue);
        expect(child.hasAnyRight(CapRight.exec), isTrue);
        expect(child.hasAnyRight(CapRight.vcsTx), isFalse);
        expect(child.hasAnyRight(CapRight.procSpawn), isFalse);
        expect(child.hasAnyRight(CapRight.mcpCall), isFalse);
        expect(child.hasAnyRight(CapRight.admin), isFalse);

        for (final forbidden in CapabilityTable.stage3ForbiddenChildRights) {
          final denied = parent.deriveForProfile(
            profile,
            requestedRights: <CapRight>{CapRight.read, forbidden},
          );
          expect(denied.ok, isFalse);
          expect(denied.error!.code, SyscallErrorCode.eperm);
          expect(denied.error!.reason, 'STAGE3_FORBIDDEN_CHILD_RIGHT');
        }
      }
    });

    test('explorer & webResearcher preserve Stage 2 STAGE2_READONLY_CHILD_LOCK', () {
      final parent = CapabilityTable.stage3LeadAgent();
      final denied = parent.deriveForProfile(
        ProcessProfileId.explorer,
        requestedRights: const <CapRight>{CapRight.read, CapRight.writeCow},
      );
      expect(denied.ok, isFalse);
      expect(denied.error!.code, SyscallErrorCode.eperm);
      expect(denied.error!.reason, 'STAGE2_READONLY_CHILD_LOCK');
    });
  });

  group('ProcessSuspendController & SyscallGate Stage 0.5/2/8 ([D-305], [D-310], [D-312])', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ak_s3_gate_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    ProcessControlBlock makePcb({
      required Pid pid,
      required String name,
      ProtectionRing ring = ProtectionRing.ring2,
      String? wsName,
      String? wsRoot,
      String? workingChangeId,
    }) {
      return ProcessControlBlock(
        pid: pid,
        parentPid: pid == 1 ? null : 1,
        name: name,
        ring: ring,
        cspace: CapabilityTable.stage3LeadAgent(),
        quota: ResourceQuota.stage2Default,
        namespace: VfsNamespace(workspaceHostRoot: tempDir.path),
        jjContext: JjTxContext(workingChangeId: workingChangeId),
        memory: VirtualContextMemory(
          sessionId: 'sess_gate',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'sys',
            tools: const <SyscallToolSchema>[],
          ),
        ),
        jjWorkspaceName: wsName,
        jjWorkspaceRoot: wsRoot,
      );
    }

    test('ProcessSuspendController freezes at Stage 0.5, excludes sys_exit, and drains FIFO constraints', () async {
      final table = KernelProcessTable.stage2();
      final childCspace = CapabilityTable.stage3LeadAgent()
          .deriveForProfile(ProcessProfileId.workspaceWorker)
          .value!;
      final pcb = ProcessControlBlock(
        pid: 2,
        parentPid: 1,
        name: 'ws-worker',
        ring: ProtectionRing.ring3,
        cspace: childCspace,
        quota: ResourceQuota.stage2Default,
        namespace: VfsNamespace(workspaceHostRoot: tempDir.path),
        memory: VirtualContextMemory(
          sessionId: 'sess_gate',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'sys',
            tools: const <SyscallToolSchema>[],
          ),
        ),
        profile: ProcessProfileId.workspaceWorker,
      );
      table.registerProcess(pcb);

      final auditLogger = AuditLogger(
        workspaceHostRoot: tempDir.path,
        sessionId: 'sess_gate',
      );
      final gate = SyscallGate(
        processTable: table,
        approvalGate: ApprovalGate(
          handler: PolicyApprovalHandler.alwaysReject(),
        ),
        ioCapper: IoPayloadCapper(
          workspaceHostRoot: tempDir.path,
        ),
        auditLogger: auditLogger,
        jjProcessAuditInfoProvider: (p) async => JjAuditInfo(
          jjChangeId: p?.jjContext.workingChangeId ?? 'main_chg',
          jjOpId: 'op_1',
        ),
      );

      var executed = false;
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_ping',
          requiredRight: CapRight.read,
          kind: 'read',
          resultSummaryBuilder: (args, res) => <String, dynamic>{
            'pong': res.value?['pong'],
          },
          handler: (ctx) async {
            executed = true;
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{'pong': true},
            );
          },
        ),
      );
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_exit',
          requiredRight: CapRight.procSelf,
          kind: 'proc',
          handler: (ctx) async =>
              const SyscallResult<Map<String, dynamic>>.success(
                <String, dynamic>{'exited': true},
              ),
        ),
      );

      pcb.suspendController.requestStop(reason: 'human pause');
      expect(pcb.suspendController.isSuspended, isTrue);

      final pingFuture = gate.invoke(
        const SyscallContext(
          pid: 2,
          capHandle: CapHandle('cap_workspace_worker'),
          sessionId: 'sess_gate',
        ),
        SyscallRequest(name: 'sys_ping'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(executed, isFalse);
      expect(pcb.state, ProcessState.stopped);

      // sys_exit is never blocked by Stage 0.5 suspend gate.
      final exitRes = await gate.invoke(
        const SyscallContext(
          pid: 2,
          capHandle: CapHandle('cap_workspace_worker'),
          sessionId: 'sess_gate',
        ),
        SyscallRequest(name: 'sys_exit'),
      );
      expect(exitRes.ok, isTrue);

      pcb.suspendController.requestContinue(constraintMessage: 'first rule');
      pcb.suspendController.requestContinue(constraintMessage: 'second rule');
      expect(
        pcb.suspendController.drainPendingConstraintText(),
        'first rule\nsecond rule',
      );

      final pingRes = await pingFuture;
      expect(pingRes.ok, isTrue);
      expect(executed, isTrue);
      expect(pcb.state, ProcessState.running);
    });

    test('Stage 0.5 unblocks immediately with ECANCELLED when cancelToken fires', () async {
      final table = KernelProcessTable.stage2();
      final pcb = makePcb(pid: 2, name: 'ws-worker');
      table.registerProcess(pcb);

      final auditLogger = AuditLogger(
        workspaceHostRoot: tempDir.path,
        sessionId: 'sess_gate',
      );
      final gate = SyscallGate(
        processTable: table,
        approvalGate: ApprovalGate(
          handler: PolicyApprovalHandler.alwaysReject(),
        ),
        ioCapper: IoPayloadCapper(
          workspaceHostRoot: tempDir.path,
        ),
        auditLogger: auditLogger,
      );
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_ping',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (ctx) async =>
              const SyscallResult<Map<String, dynamic>>.success(
                <String, dynamic>{'pong': true},
              ),
        ),
      );

      pcb.suspendController.requestStop();
      final cancelSource = CancellationTokenSource();
      final future = gate.invoke(
        SyscallContext(
          pid: 2,
          capHandle: const CapHandle('cap_workspace_rw'),
          sessionId: 'sess_gate',
          cancelToken: cancelSource.token,
        ),
        SyscallRequest(name: 'sys_ping'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancelSource.cancel('SIGKILL');
      pcb.suspendController.releaseForTermination();

      final res = await future;
      expect(res.ok, isFalse);
      expect(res.error!.code, SyscallErrorCode.ecancelled);
    });

    test('Stage 2 econflict maps to deniedByPolicy and Stage 8 attributes child jjChangeId', () async {
      final table = KernelProcessTable.stage2();
      final pcb = makePcb(
        pid: 3,
        name: 'worker-3',
        ring: ProtectionRing.ring3,
        workingChangeId: 'child_chg_3',
      );
      table.registerProcess(pcb);

      final auditLogger = AuditLogger(
        workspaceHostRoot: tempDir.path,
        sessionId: 'sess_gate',
      );
      final gate = SyscallGate(
        processTable: table,
        approvalGate: ApprovalGate(
          handler: PolicyApprovalHandler.alwaysReject(),
        ),
        ioCapper: IoPayloadCapper(
          workspaceHostRoot: tempDir.path,
        ),
        auditLogger: auditLogger,
        jjProcessAuditInfoProvider: (p) async => JjAuditInfo(
          jjChangeId: p?.jjContext.workingChangeId,
          jjOpId: 'op_child_3',
        ),
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_tx_squash',
          requiredRight: CapRight.read,
          kind: 'vcs_tx',
          checkPreconditions: (p, args) async => const SyscallError(
            code: SyscallErrorCode.econflict,
            reason: 'UNRESOLVED_CONFLICTS',
            message: 'Conflicts remain',
          ),
          handler: (ctx) async =>
              const SyscallResult<Map<String, dynamic>>.success(
                <String, dynamic>{},
              ),
        ),
      );

      final res = await gate.invoke(
        const SyscallContext(
          pid: 3,
          capHandle: CapHandle('cap_workspace_rw'),
          sessionId: 'sess_gate',
        ),
        SyscallRequest(name: 'sys_tx_squash'),
      );
      expect(res.ok, isFalse);
      expect(res.error!.code, SyscallErrorCode.econflict);

      await auditLogger.flush();
      final lines = File(auditLogger.syscallsLogPath).readAsLinesSync();
      expect(lines.length, 1);
      expect(lines.first, contains('"decision":"DENIED_BY_POLICY"'));
      expect(lines.first, contains('"jjChangeId":"child_chg_3"'));
      expect(lines.first, contains('"jjOpId":"op_child_3"'));
    });
  });

  group('ContextPager Dirty Page Swap & validateMaxContextTokens ([D-316], [D-317])', () {
    test('validateMaxContextTokens enforces segment0 + reservedOut + 512', () {
      final sys = PinnedSystemInstruction(
        instruction: 'System prompt ' * 10,
        tools: const <SyscallToolSchema>[],
      );
      final errTooSmall = ContextPager.validateMaxContextTokens(
        maxContextTokens: 600,
        systemInstruction: sys,
        reservedOutputTokens: 512,
      );
      expect(errTooSmall, isNotNull);
      expect(errTooSmall!.code, SyscallErrorCode.einval);
      expect(errTooSmall.reason, 'MAX_CONTEXT_TOKENS_TOO_SMALL');

      final ok = ContextPager.validateMaxContextTokens(
        maxContextTokens: 4096,
        systemInstruction: sys,
        reservedOutputTokens: 512,
      );
      expect(ok, isNull);
    });

    test('Clean First, Dirty Second: Clean eviction sufficiency prevents Dirty Swap', () async {
      final swapBackend = _InMemoryDirtySwapBackend();
      final pager = ContextPager(
        dirtySwapBackend: swapBackend,
      );
      final memory = VirtualContextMemory(
        sessionId: 'sess_clean_first',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'sys',
          tools: const <SyscallToolSchema>[],
        ),
      );
      memory.appendUserTurn('read file');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: 'local-ollama',
          originModel: 'gemma4:12b',
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'c1',
              name: 'sys_read_lines',
              arguments: const <String, dynamic>{'path': '/workspace/a.dart'},
            ),
          ],
        ),
      );
      memory.appendToolResultTurn(
        CanonicalToolResultTurn(
          canonicalCallId: 'c1',
          toolName: 'sys_read_lines',
          content: 'line\n' * 600,
        ),
        cleanSource: CleanPageSourceMeta(
          sourceKind: CleanSourceKind.workspaceFile,
          syscallName: 'sys_read_lines',
          replayArgs: const <String, dynamic>{'path': '/workspace/a.dart'},
          virtualPath: '/workspace/a.dart',
          readSha256: 'abc123',
        ),
      );
      memory.appendUserTurn('next question');

      final res = await pager.prepareFrameForModelAsync(
        memory: memory,
        targetModel: ModelIdentifier.parse('local-ollama/gemma4:12b').value!,
        windowSpec: const ContextWindowSpec(contextWindowTokens: 1200),
      );

      expect(res.ok, isTrue);
      expect(res.value!.evictedPagesInStep, 1);
      expect(res.value!.swappedDirtyPagesInStep, 0);
      expect(swapBackend.writeCalls, 0);
    });

    test('Dirty Swap preserves tool_call_id pairing, redacts secrets, and rolls back nothing on write failure', () async {
      final failingBackend = _InMemoryDirtySwapBackend(shouldFailWrite: true);
      final pagerFail = ContextPager(dirtySwapBackend: failingBackend);

      final memory = VirtualContextMemory(
        sessionId: 'sess_dirty',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'sys',
          tools: const <SyscallToolSchema>[],
        ),
      );
      final redactor = SecretRedactor(initialSecrets: <String>['SUPER_SECRET_KEY_999']);

      for (var i = 0; i < 4; i++) {
        memory.appendUserTurn('task $i with SUPER_SECRET_KEY_999');
        memory.appendAssistantTurn(
          CanonicalAssistantTurn(
            originProvider: 'local-ollama',
            originModel: 'gemma4:12b',
            content: 'running step $i',
            toolCalls: <CanonicalToolCall>[
              CanonicalToolCall(
                canonicalCallId: 'call_$i',
                name: 'sys_exec',
                arguments: <String, dynamic>{'command': 'dart', 'args': <String>['test']},
              ),
            ],
          ),
        );
        memory.appendToolResultTurn(
          CanonicalToolResultTurn(
            canonicalCallId: 'call_$i',
            toolName: 'sys_exec',
            content: 'output $i ' * 150,
          ),
        );
      }

      final turnsBeforeFail = memory.historySegment.turns.length;
      final failRes = await pagerFail.prepareFrameForModelAsync(
        memory: memory,
        targetModel: ModelIdentifier.parse('local-ollama/gemma4:12b').value!,
        windowSpec: const ContextWindowSpec(contextWindowTokens: 1500),
        redactor: redactor,
      );
      expect(failRes.ok, isFalse);
      expect(memory.historySegment.turns.length, turnsBeforeFail);
      expect(memory.pageTable.swappedDirtyPagesTotal, 0);

      // Now succeed with working backend.
      final okBackend = _InMemoryDirtySwapBackend();
      final pagerOk = ContextPager(dirtySwapBackend: okBackend);
      final okRes = await pagerOk.prepareFrameForModelAsync(
        memory: memory,
        targetModel: ModelIdentifier.parse('local-ollama/gemma4:12b').value!,
        windowSpec: const ContextWindowSpec(contextWindowTokens: 1500),
        redactor: redactor,
      );
      expect(okRes.ok, isTrue, reason: okRes.error?.toString());
      expect(okRes.value!.swappedDirtyPagesInStep, greaterThan(0));
      expect(okRes.value!.swappedDirtyPagesTotal, okRes.value!.swappedDirtyPagesInStep);
      expect(okRes.value!.swappedTurnGroupsInStep, greaterThan(0));

      // Verify SummaryTurn is present and secret is redacted.
      final firstTurn = memory.historySegment.turns.first;
      expect(firstTurn, isA<CanonicalSummaryTurn>());
      final summaryText = (firstTurn as CanonicalSummaryTurn).text;
      expect(summaryText, isNot(contains('SUPER_SECRET_KEY_999')));
      expect(summaryText, contains('<REDACTED>'));

      // Verify no orphaned tool_call_id in projected prompt.
      final projected = const CanonicalIrProjector().project(
        memory,
        targetProvider: 'local-ollama',
        targetModel: 'gemma4:12b',
      );
      for (var i = 0; i < projected.messages.length; i++) {
        final msg = projected.messages[i];
        if (msg.role == ProjectedRole.assistant && msg.toolCalls.isNotEmpty) {
          for (var j = 0; j < msg.toolCalls.length; j++) {
            expect(projected.messages[i + 1 + j].role, ProjectedRole.tool);
            expect(
              projected.messages[i + 1 + j].toolCallId,
              msg.toolCalls[j].id,
            );
          }
        }
      }
    });
  });

  group('StackedTaskRegistry & Contracts ([D-311], [D-315], [D-318])', () {
    test('StackedTaskRegistry orders descendants topologically and rejects cycles', () {
      final reg = StackedTaskRegistry();
      StackedTaskNode mk(String id, {String? parent}) => StackedTaskNode(
        taskId: id,
        title: 'Task $id',
        parentTaskId: parent,
        baseChangeId: 'base',
        workingChangeId: 'chg_$id',
        commitId: 'commit_$id',
        workspaceName: 'ws-task-$id',
        workspaceRoot: '/repo/.agent_os/ws/task_$id',
      );

      expect(reg.register(mk('a')).ok, isTrue);
      expect(reg.register(mk('b', parent: 'a')).ok, isTrue);
      expect(reg.register(mk('c', parent: 'a')).ok, isTrue);
      expect(reg.register(mk('d', parent: 'b')).ok, isTrue);

      final desc = reg.descendantsInTopologicalOrder('a');
      expect(desc.map((n) => n.taskId).toList(), <String>['b', 'c', 'd']);

      // Cannot remove parent with children.
      final remFail = reg.remove('a');
      expect(remFail.ok, isFalse);
      expect(remFail.error!.code, SyscallErrorCode.econflict);

      // Duplicate ID rejected.
      final dup = reg.register(mk('d'));
      expect(dup.ok, isFalse);
      expect(dup.error!.code, SyscallErrorCode.eexist);
    });

    test('McpServerSpec.toJson redacts env values by default', () {
      final spec = McpServerSpec(
        name: 'demo',
        command: 'dart',
        args: const <String>['run'],
        env: const <McpEnvVar>[
          McpEnvVar(name: 'API_TOKEN', value: 'secret_val_123'),
        ],
      );
      final json = spec.toJson();
      final envList = json['env'] as List<dynamic>;
      expect((envList.first as Map<String, dynamic>)['value'], '<REDACTED>');
    });
  });
}

class _InMemoryDirtySwapBackend implements DirtySwapBackend {
  _InMemoryDirtySwapBackend({this.shouldFailWrite = false});

  final bool shouldFailWrite;
  int writeCalls = 0;
  final List<DirtySwapRecord> stored = <DirtySwapRecord>[];

  @override
  Future<SyscallResult<void>> writeBackTurnGroups({
    required String sessionId,
    Pid pid = 1,
    ProcessControlBlock? pcb,
    required String swapBatchId,
    required String summaryPageId,
    required List<DirtySwapRecord> records,
  }) async {
    writeCalls += 1;
    if (shouldFailWrite) {
      return const SyscallResult<void>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'DISK_FULL',
          message: 'Simulated disk write failure',
        ),
      );
    }
    stored.addAll(records);
    return const SyscallResult<void>.success(null);
  }

  @override
  Future<SyscallResult<List<DirtySwapRecord>>> readSwappedPages({
    required String sessionId,
    Pid pid = 1,
    ProcessControlBlock? pcb,
    String? pageId,
    String? swapBatchId,
  }) async {
    final filtered = stored.where((r) {
      if (pageId != null && r.pageId != pageId) return false;
      if (swapBatchId != null && r.swapBatchId != swapBatchId) return false;
      return true;
    }).toList(growable: false);
    return SyscallResult<List<DirtySwapRecord>>.success(filtered);
  }
}
