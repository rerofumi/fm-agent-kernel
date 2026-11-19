import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('CapabilityTable (CSpace) [D-005]', () {
    test('stage1LeadAgent grants expected workspace rights and rejects missing rights', () {
      final cspace = CapabilityTable.stage1LeadAgent();
      const handle = CapHandle('cap_workspace_rw');
      const unknownHandle = CapHandle('cap_unknown');

      expect(cspace.hasRight(handle, CapRight.read), isTrue);
      expect(cspace.hasRight(handle, CapRight.writeCow), isTrue);
      expect(cspace.hasRight(handle, CapRight.exec), isTrue);
      expect(cspace.hasRight(handle, CapRight.vcsRead), isTrue);
      expect(cspace.hasRight(handle, CapRight.vcsTx), isTrue);
      expect(cspace.hasRight(handle, CapRight.llmInfer), isTrue);
      expect(cspace.hasRight(handle, CapRight.admin), isFalse);
      expect(cspace.hasRight(unknownHandle, CapRight.read), isFalse);

      expect(cspace.revoke(handle), isTrue);
      expect(cspace.hasRight(handle, CapRight.read), isFalse);
    });

    test('stage2LeadAgent and deriveForChild enforce monotonic attenuation and Stage 2 child locks [D-213]', () {
      final parentStage2 = CapabilityTable.stage2LeadAgent();
      expect(
        parentStage2.hasRight(const CapHandle('cap_workspace_rw'), CapRight.procSpawn),
        isTrue,
      );
      expect(
        parentStage2.hasRight(const CapHandle('cap_net_public'), CapRight.netRead),
        isTrue,
      );
      expect(parentStage2.hasAnyRight(CapRight.netRead), isTrue);

      // Valid Explorer & WebResearcher profile derivations succeed.
      final explorerCap = parentStage2.deriveForProfile(ProcessProfileId.explorer);
      expect(explorerCap.ok, isTrue);
      expect(explorerCap.value!.hasAnyRight(CapRight.read), isTrue);
      expect(explorerCap.value!.hasAnyRight(CapRight.vcsRead), isTrue);
      expect(explorerCap.value!.hasAnyRight(CapRight.procSelf), isTrue);
      expect(explorerCap.value!.hasAnyRight(CapRight.writeCow), isFalse);
      expect(explorerCap.value!.hasAnyRight(CapRight.netRead), isFalse);

      final researcherCap =
          parentStage2.deriveForProfile(ProcessProfileId.webResearcher);
      expect(researcherCap.ok, isTrue);
      expect(researcherCap.value!.hasAnyRight(CapRight.netRead), isTrue);
      expect(researcherCap.value!.hasAnyRight(CapRight.read), isFalse);
      expect(researcherCap.value!.hasAnyRight(CapRight.vcsRead), isFalse);

      // Stage 2 forbidden child rights are rejected with STAGE2_READONLY_CHILD_LOCK.
      for (final forbidden in CapabilityTable.stage2ForbiddenChildRights) {
        final res = parentStage2.deriveForChild(
          requestedRights: <CapRight>{CapRight.read, forbidden},
        );
        expect(res.ok, isFalse, reason: 'Expected rejection for ${forbidden.name}');
        expect(res.error!.code, equals(SyscallErrorCode.eperm));
        expect(res.error!.reason, equals('STAGE2_READONLY_CHILD_LOCK'));
      }

      // Stage 1 parent lacks netRead/ipc -> cannot derive WebResearcher (CAPABILITY_ATTENUATION_VIOLATION).
      final parentStage1 = CapabilityTable.stage1LeadAgent();
      final missingParentRight =
          parentStage1.deriveForProfile(ProcessProfileId.webResearcher);
      expect(missingParentRight.ok, isFalse);
      expect(missingParentRight.error!.code, equals(SyscallErrorCode.eperm));
      expect(
        missingParentRight.error!.reason,
        equals('CAPABILITY_ATTENUATION_VIOLATION'),
      );

      // Requesting rights outside profile boundary (e.g., read on WebResearcher) fails with EPERM.
      final outsideProfile = parentStage2.deriveForProfile(
        ProcessProfileId.webResearcher,
        requestedRights: const <CapRight>{CapRight.netRead, CapRight.read},
      );
      expect(outsideProfile.ok, isFalse);
      expect(outsideProfile.error!.code, equals(SyscallErrorCode.eperm));
      expect(outsideProfile.error!.reason, equals('CAPABILITY_ATTENUATION_VIOLATION'));
    });
  });

  group('ResourceQuota & QuotaConsumption [D-005]', () {
    test('enforces syscall, token, and cost quotas with EDQUOT', () {
      const quota = ResourceQuota(
        maxChildProcesses: 0,
        maxSyscallCountPerTurn: 2,
        maxTotalTokens: 100,
        maxCostMicroUsd: 500,
      );
      final usage = QuotaConsumption();

      expect(usage.checkBeforeSyscall(quota), isNull);
      usage.recordSyscall();
      usage.recordSyscall();

      final syscallExceeded = usage.checkBeforeSyscall(quota);
      expect(syscallExceeded, isNotNull);
      expect(syscallExceeded!.code, equals(SyscallErrorCode.edquot));
      expect(syscallExceeded.reason, equals('SYSCALL_QUOTA_EXCEEDED'));

      usage.resetTurn();
      expect(usage.checkBeforeSyscall(quota), isNull);

      usage.recordUsage(tokens: 100, costMicroUsd: 100);
      final tokenExceeded = usage.checkBeforeSyscall(quota);
      expect(tokenExceeded, isNotNull);
      expect(tokenExceeded!.code, equals(SyscallErrorCode.edquot));
      expect(tokenExceeded.reason, equals('TOKEN_QUOTA_EXCEEDED'));

      final costUsage = QuotaConsumption(costMicroUsdUsed: 500);
      final costExceeded = costUsage.checkBeforeSyscall(quota);
      expect(costExceeded, isNotNull);
      expect(costExceeded!.code, equals(SyscallErrorCode.edquot));
      expect(costExceeded.reason, equals('COST_QUOTA_EXCEEDED'));
    });

    test('enforces Stage 2 maxTotalSyscalls and maxWallTimeMs quotas [D-214]', () {
      const quota = ResourceQuota(
        maxChildProcesses: 0,
        maxSyscallCountPerTurn: 10,
        maxTotalSyscalls: 3,
        maxWallTimeMs: 1000,
      );
      final start = DateTime.utc(2026, 11, 19, 12, 0, 0);
      final usage = QuotaConsumption(startedAtUtc: start);

      usage.recordSyscall();
      usage.recordSyscall();
      usage.resetTurn();
      expect(usage.checkBeforeSyscall(quota, nowUtc: start.add(const Duration(milliseconds: 500))), isNull);

      usage.recordSyscall();
      final totalExceeded = usage.checkBeforeSyscall(
        quota,
        nowUtc: start.add(const Duration(milliseconds: 500)),
      );
      expect(totalExceeded, isNotNull);
      expect(totalExceeded!.code, equals(SyscallErrorCode.edquot));
      expect(totalExceeded.reason, equals('TOTAL_SYSCALL_QUOTA_EXCEEDED'));

      final wallUsage = QuotaConsumption(startedAtUtc: start);
      final wallExceeded = wallUsage.checkBeforeSyscall(
        quota,
        nowUtc: start.add(const Duration(milliseconds: 1000)),
      );
      expect(wallExceeded, isNotNull);
      expect(wallExceeded!.code, equals(SyscallErrorCode.edquot));
      expect(wallExceeded.reason, equals('WALL_TIME_QUOTA_EXCEEDED'));
    });
  });

  group('KernelProcessTable & Stage 1 single-process lock [D-005]', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('agent_kernel_pcb_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    ProcessControlBlock buildPcb(Pid pid, {ResourceQuota? quota}) {
      return ProcessControlBlock(
        pid: pid,
        name: 'agent-$pid',
        ring: ProtectionRing.ring2,
        state: ProcessState.running,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: quota ?? ResourceQuota.stage1Default,
        namespace: VfsNamespace(workspaceHostRoot: tempDir.path),
        memory: VirtualContextMemory(
          sessionId: 'sess_1',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'system',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
    }

    test('blocks second active process and sys_spawn with EPERM', () {
      final table = KernelProcessTable();
      final lead = buildPcb(1);
      final first = table.registerProcess(lead);
      expect(first.ok, isTrue);

      final spawnErr = table.validateSpawnAllowed(1);
      expect(spawnErr, isNotNull);
      expect(spawnErr!.code, equals(SyscallErrorCode.eperm));
      expect(spawnErr.reason, equals('STAGE1_SINGLE_PROCESS_LOCK'));

      final second = table.registerProcess(buildPcb(2));
      expect(second.ok, isFalse);
      expect(second.error!.code, equals(SyscallErrorCode.eperm));
      expect(second.error!.reason, equals('STAGE1_SINGLE_PROCESS_LOCK'));
    });

    test('JjTxContext transitions between readOnly and active while tracking checkpoints', () {
      final tx = JjTxContext();
      expect(tx.state, equals(TxState.readOnly));

      tx.enterActive(
        baseOpId: 'op_base_1',
        parentChangeId: 'chg_parent',
        workingChangeId: 'chg_work',
      );
      expect(tx.state, equals(TxState.active));
      expect(tx.allowedCheckpointOpIds, contains('op_base_1'));

      tx.updateSnapshot(currentOpId: 'op_snap_2', workingChangeId: 'chg_work_2');
      expect(tx.currentOpId, equals('op_snap_2'));
      expect(tx.allowedCheckpointOpIds, contains('op_snap_2'));

      tx.resetToReadOnly(currentOpId: 'op_done_3');
      expect(tx.state, equals(TxState.readOnly));
      expect(tx.allowedCheckpointOpIds, contains('op_done_3'));
    });

    test('KernelProcessTable.stage2 allocates monotonic PIDs and returns recoverable EDQUOT at child limit [D-211]', () {
      final table = KernelProcessTable.stage2(maxActiveProcesses: 3);
      final lead = buildPcb(
        1,
        quota: const ResourceQuota(maxChildProcesses: 2),
      );
      expect(table.registerProcess(lead).ok, isTrue);

      final pid2 = table.allocateNextPid();
      final pid3 = table.allocateNextPid();
      expect(pid2, equals(2));
      expect(pid3, equals(3));

      final child2 = ProcessControlBlock(
        pid: pid2,
        parentPid: 1,
        name: 'explorer-2',
        ring: ProtectionRing.ring3,
        state: ProcessState.running,
        cspace: CapabilityTable.stage2LeadAgent()
            .deriveForProfile(ProcessProfileId.explorer)
            .value!,
        quota: const ResourceQuota(maxChildProcesses: 0),
        namespace: VfsNamespace(workspaceHostRoot: tempDir.path),
        memory: VirtualContextMemory(
          sessionId: 'sess_1',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'child',
            tools: const <SyscallToolSchema>[],
          ),
        ),
        profile: ProcessProfileId.explorer,
      );
      expect(table.registerProcess(child2).ok, isTrue);
      lead.quotaUsage.activeChildProcesses += 1;

      final child3 = ProcessControlBlock(
        pid: pid3,
        parentPid: 1,
        name: 'explorer-3',
        ring: ProtectionRing.ring3,
        state: ProcessState.running,
        cspace: child2.cspace,
        quota: const ResourceQuota(maxChildProcesses: 0),
        namespace: VfsNamespace(workspaceHostRoot: tempDir.path),
        memory: child2.memory,
        profile: ProcessProfileId.explorer,
      );
      expect(table.registerProcess(child3).ok, isTrue);
      lead.quotaUsage.activeChildProcesses += 1;

      // Child process quota reached -> recoverable EDQUOT (not Stage 1 EPERM).
      final spawnErr = table.validateSpawnAllowed(1);
      expect(spawnErr, isNotNull);
      expect(spawnErr!.code, equals(SyscallErrorCode.edquot));
      expect(spawnErr.reason, equals('CHILD_PROCESS_QUOTA_EXCEEDED'));
      expect(spawnErr.recoverable, isTrue);

      // Terminating child2 frees active slot, but next PID is strictly monotonic (4, never reusing 2).
      child2.state = ProcessState.terminated;
      lead.quotaUsage.activeChildProcesses -= 1;
      expect(table.validateSpawnAllowed(1), isNull);
      expect(table.allocateNextPid(), equals(4));
      expect(table.activeChildrenOf(1).map((p) => p.pid), equals(<int>[3]));
    });

    test('QuotaLedger enforces parallel reservation donation and exact conservation-law return [D-214]', () {
      final ledger = QuotaLedger();
      final parent = buildPcb(
        1,
        quota: const ResourceQuota(
          maxChildProcesses: 4,
          maxTotalTokens: 10000,
          maxCostMicroUsd: 1000,
        ),
      );

      // Parallel donations: child 2 gets 4000 tokens / 400 cost, child 3 gets 4000 tokens / 300 cost.
      final d2 = ledger.donateToChild(
        parent: parent,
        childPid: 2,
        requestedTokens: 4000,
        requestedCostMicroUsd: 400,
      );
      final d3 = ledger.donateToChild(
        parent: parent,
        childPid: 3,
        requestedTokens: 4000,
        requestedCostMicroUsd: 300,
      );
      expect(d2.ok, isTrue);
      expect(d3.ok, isTrue);
      expect(parent.quotaUsage.donatedTokensOut, equals(8000));
      expect(parent.quotaUsage.donatedCostMicroUsdOut, equals(700));
      expect(parent.quotaUsage.activeChildProcesses, equals(2));
      expect(parent.quotaUsage.availableTokens(parent.quota), equals(2000));
      expect(parent.quotaUsage.availableCostMicroUsd(parent.quota), equals(300));

      // Requesting 3000 tokens for child 4 exceeds remaining 2000 -> recoverable EDQUOT without mutating parent.
      final d4Fail = ledger.donateToChild(
        parent: parent,
        childPid: 4,
        requestedTokens: 3000,
        requestedCostMicroUsd: 100,
      );
      expect(d4Fail.ok, isFalse);
      expect(d4Fail.error!.code, equals(SyscallErrorCode.edquot));
      expect(d4Fail.error!.reason, equals('INSUFFICIENT_PARENT_TOKEN_QUOTA'));
      expect(d4Fail.error!.recoverable, isTrue);
      expect(parent.quotaUsage.donatedTokensOut, equals(8000));
      expect(parent.quotaUsage.activeChildProcesses, equals(2));

      // Parent spends its remaining 2000 tokens -> committed (2000 + 8000) hits 10000 limit.
      parent.quotaUsage.recordUsage(tokens: 2000, costMicroUsd: 100);
      final parentCheck = parent.quotaUsage.checkBeforeSyscall(parent.quota);
      expect(parentCheck, isNotNull);
      expect(parentCheck!.code, equals(SyscallErrorCode.edquot));
      expect(parentCheck.reason, equals('TOKEN_QUOTA_EXCEEDED'));

      // Child 2 finishes using 1200 tokens / 150 cost -> 2800 tokens / 250 cost returned to parent.
      final child2 = buildPcb(2, quota: d2.value!.childQuota);
      child2.quotaUsage.recordUsage(tokens: 1200, costMicroUsd: 150);
      final settle2 = ledger.settleChildExit(parent: parent, child: child2);
      expect(settle2, isNotNull);
      expect(settle2!.returnedTokens, equals(2800));
      expect(settle2.returnedCostMicroUsd, equals(250));
      // Idempotent guard: second settle is a no-op.
      expect(ledger.settleChildExit(parent: parent, child: child2), isNull);

      expect(parent.quotaUsage.donatedTokensOut, equals(4000));
      expect(parent.quotaUsage.totalTokensUsed, equals(3200));
      expect(parent.quotaUsage.availableTokens(parent.quota), equals(2800));
      expect(parent.quotaUsage.checkBeforeSyscall(parent.quota), isNull);

      // Child 3 finishes using 3500 tokens / 200 cost -> 500 tokens / 100 cost returned.
      final child3 = buildPcb(3, quota: d3.value!.childQuota);
      child3.quotaUsage.recordUsage(tokens: 3500, costMicroUsd: 200);
      final settle3 = ledger.settleChildExit(parent: parent, child: child3);
      expect(settle3, isNotNull);
      expect(settle3!.returnedTokens, equals(500));
      expect(settle3.returnedCostMicroUsd, equals(100));

      // Exact conservation law check: initial 10000 - (parent 2000 + child2 1200 + child3 3500) == 3300.
      expect(parent.quotaUsage.donatedTokensOut, equals(0));
      expect(parent.quotaUsage.donatedCostMicroUsdOut, equals(0));
      expect(parent.quotaUsage.activeChildProcesses, equals(0));
      expect(parent.quotaUsage.totalTokensUsed, equals(6700));
      expect(parent.quotaUsage.costMicroUsdUsed, equals(450));
      expect(parent.quotaUsage.availableTokens(parent.quota), equals(3300));
      expect(parent.quotaUsage.availableCostMicroUsd(parent.quota), equals(550));
    });
  });
}
