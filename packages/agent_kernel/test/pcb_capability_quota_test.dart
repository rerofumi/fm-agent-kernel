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
  });
}
