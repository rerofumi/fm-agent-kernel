import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('AntiGitHabitGuardHook [D-002], [D-017]', () {
    late Directory repoDir;
    late VfsNamespace namespace;
    late AuditLogger auditLogger;
    late KernelProcessTable processTable;
    late ProcessControlBlock pcb;
    late PolicyApprovalHandler approvalSpy;
    late int driverInvokeCount;
    late SyscallGate gate;

    const sessionId = 'sess_wp7_hook';
    const capHandle = CapHandle('cap_workspace_rw');
    const ctx = SyscallContext(
      pid: 1,
      capHandle: capHandle,
      sessionId: sessionId,
    );

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('wp7_hook_');
      namespace = VfsNamespace(workspaceHostRoot: repoDir.path);
      auditLogger = AuditLogger(
        workspaceHostRoot: repoDir.path,
        sessionId: sessionId,
      );
      processTable = KernelProcessTable();
      pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        state: ProcessState.running,
        cspace: CapabilityTable.stage1LeadAgent(handle: capHandle),
        quota: ResourceQuota.stage1Default,
        namespace: namespace,
        memory: VirtualContextMemory(
          sessionId: sessionId,
          systemInstruction: PinnedSystemInstruction(
            instruction: 'Hook test',
            tools: Win32JobExecDriver.toolSchemas(),
          ),
        ),
      );
      processTable.registerProcess(pcb);

      approvalSpy = PolicyApprovalHandler.alwaysAllow();
      driverInvokeCount = 0;

      final execDriver = Win32JobExecDriver(namespace: namespace);
      final baseDef = execDriver.buildSyscallDefinition();

      gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: approvalSpy),
        ioCapper: IoPayloadCapper(workspaceHostRoot: repoDir.path),
        auditLogger: auditLogger,
        hooks: <SyscallHook>[AntiGitHabitGuardHook()],
      );

      // Wrap handler to count Stage 5 driver invocations without spawning real processes.
      gate.registerSyscall(
        SyscallDefinition(
          name: baseDef.name,
          requiredRight: baseDef.requiredRight,
          kind: baseDef.kind,
          applyIoCap: baseDef.applyIoCap,
          cappedTextFields: baseDef.cappedTextFields,
          validateArgs: baseDef.validateArgs,
          normalizeArgs: baseDef.normalizeArgs,
          checkPreconditions: baseDef.checkPreconditions,
          evaluatePolicy: baseDef.evaluatePolicy,
          approvalPreviewBuilder: baseDef.approvalPreviewBuilder,
          approvalSignatureBuilder: baseDef.approvalSignatureBuilder,
          handler: (exec) async {
            driverInvokeCount += 1;
            return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
              'exitCode': 0,
              'stdout': 'stubbed:${exec.args['command']}',
              'stderr': '',
              'timedOut': false,
              'durationMs': 1,
              'truncatedStdout': false,
              'truncatedStderr': false,
            });
          },
        ),
      );
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    Future<void> expectBlocked(
      Map<String, dynamic> args, {
      required String description,
    }) async {
      final approvalsBefore = approvalSpy.recordedRequests.length;
      final driverBefore = driverInvokeCount;

      final res = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_exec', args: args),
      );

      expect(res.ok, isFalse, reason: '$description should be blocked');
      expect(res.error!.code, equals(SyscallErrorCode.eperm), reason: description);
      expect(res.error!.reason, equals('HOOK_BLOCKED'), reason: description);
      expect(res.error!.message, contains('sys_jj_status'), reason: description);
      expect(res.error!.message, contains('sys_tx_rollback'), reason: description);
      expect(
        approvalSpy.recordedRequests.length,
        equals(approvalsBefore),
        reason: '$description must block at Stage 3 BEFORE Stage 4 ApprovalHandler',
      );
      expect(
        driverInvokeCount,
        equals(driverBefore),
        reason: '$description must not reach Stage 5 driver',
      );
    }

    test('blocks standalone, chained, piped, and recursively wrapped git/jj before Stage 4 approval',
        () async {
      await expectBlocked(
        const <String, dynamic>{'command': 'git status'},
        description: 'single-string git status',
      );
      await expectBlocked(
        const <String, dynamic>{
          'command': 'git',
          'args': <String>['diff'],
        },
        description: 'split git diff',
      );
      await expectBlocked(
        const <String, dynamic>{
          'command': r'C:\Program Files\Git\cmd\git.exe',
          'args': <String>['log'],
        },
        description: 'full path git.exe',
      );
      await expectBlocked(
        const <String, dynamic>{'command': 'jj log'},
        description: 'single-string jj log',
      );
      await expectBlocked(
        const <String, dynamic>{
          'command': 'jj.exe',
          'args': <String>['status'],
        },
        description: 'jj.exe status',
      );
      await expectBlocked(
        const <String, dynamic>{'command': 'echo ok && git diff'},
        description: '&& chain to git',
      );
      await expectBlocked(
        const <String, dynamic>{'command': 'echo ok || jj status'},
        description: '|| chain to jj',
      );
      await expectBlocked(
        const <String, dynamic>{'command': 'dir | git apply'},
        description: 'pipe into git',
      );
      await expectBlocked(
        const <String, dynamic>{'command': 'echo ok; jj squash'},
        description: 'semicolon chain to jj',
      );
      await expectBlocked(
        const <String, dynamic>{'command': 'powershell -c "jj squash"'},
        description: 'powershell -c wrapper',
      );
      await expectBlocked(
        const <String, dynamic>{
          'command': 'powershell.exe',
          'args': <String>[
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            '& git status',
          ],
        },
        description: 'powershell.exe -Command & git status',
      );
      await expectBlocked(
        const <String, dynamic>{
          'command': 'pwsh',
          'args': <String>['-c', 'echo hi; jj abandon'],
        },
        description: 'pwsh -c semicolon chain',
      );
      await expectBlocked(
        const <String, dynamic>{'command': 'cmd /c git checkout .'},
        description: 'cmd /c git checkout',
      );
      await expectBlocked(
        const <String, dynamic>{
          'command': 'cmd.exe',
          'args': <String>['/C', 'echo ok && jj describe -m x'],
        },
        description: 'cmd.exe /C chained jj',
      );
      await expectBlocked(
        const <String, dynamic>{
          'command': 'bash',
          'args': <String>['-c', 'FOO=1 git status'],
        },
        description: 'bash -c with env assignment',
      );
      await expectBlocked(
        const <String, dynamic>{
          'command': 'sh',
          'args': <String>['-c', r'echo $(jj log)'],
        },
        description: 'sh -c command substitution',
      );

      final utf16LeBytes = <int>[];
      for (final unit in 'git status'.codeUnits) {
        utf16LeBytes.add(unit & 0xFF);
        utf16LeBytes.add((unit >> 8) & 0xFF);
      }
      final encodedCmd = base64Encode(utf16LeBytes);
      await expectBlocked(
        <String, dynamic>{
          'command': 'powershell',
          'args': <String>['-EncodedCommand', encodedCmd],
        },
        description: 'powershell -EncodedCommand git status',
      );

      await auditLogger.flush();
      final lines = const LineSplitter()
          .convert(File(auditLogger.syscallsLogPath).readAsStringSync())
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(lines, hasLength(17));
      for (final rec in lines) {
        expect(rec['decision'], equals('HOOK_BLOCKED'));
        expect(rec['approvalRequired'], isFalse);
        expect(rec['errorCode'], equals('EPERM'));
        expect(rec['errorReason'], equals('HOOK_BLOCKED'));
      }
    });

    test('does not falsely block safe commands mentioning git or jj in arguments',
        () async {
      final safe1 = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'dart test test/git_helper_test.dart',
          },
        ),
      );
      expect(safe1.ok, isTrue, reason: '${safe1.error}');
      expect(approvalSpy.recordedRequests, isEmpty);

      final safe2 = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'dart',
            'args': <String>['test', '-n', 'jj_driver'],
          },
        ),
      );
      expect(safe2.ok, isTrue, reason: '${safe2.error}');
      expect(approvalSpy.recordedRequests, isEmpty);

      final safe3 = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'powershell.exe',
            'args': <String>[
              '-NoProfile',
              '-Command',
              "Write-Output 'never run git status'",
            ],
          },
        ),
      );
      expect(safe3.ok, isTrue, reason: '${safe3.error}');
      expect(approvalSpy.recordedRequests, hasLength(1));
    });
  });
}
