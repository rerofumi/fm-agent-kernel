import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _TestBlockHook extends BaseSyscallHook {
  _TestBlockHook({required this.blockedCommand});

  final String blockedCommand;
  int beforeCallCount = 0;
  int afterCallCount = 0;

  @override
  String get name => 'test_block_hook';

  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async {
    beforeCallCount += 1;
    if (context.syscallName == 'sys_exec' &&
        context.args['command'] == blockedCommand) {
      return const HookBlock(
        reason: 'RAW_GIT_PROHIBITED',
        message: 'Raw git is blocked before approval.',
        hint: 'Use sys_jj_status instead.',
      );
    }
    return const HookAllow();
  }

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    afterCallCount += 1;
  }
}

void main() {
  group('SyscallGate pipeline & ApprovalGate [D-002], [D-004], [D-005], [D-010], [D-020]', () {
    late Directory workspaceDir;
    late KernelProcessTable processTable;
    late ProcessControlBlock pcb;
    late AuditLogger auditLogger;
    late SecretRedactor redactor;
    late SyscallContext ctx;

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('gate_ws_');
      processTable = KernelProcessTable();
      redactor = SecretRedactor()..registerSecret('top-secret-token');
      auditLogger = AuditLogger(
        workspaceHostRoot: workspaceDir.path,
        sessionId: 'sess_gate',
        redactor: redactor,
      );
      pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        state: ProcessState.running,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: const ResourceQuota(
          maxChildProcesses: 0,
          maxSyscallCountPerTurn: 10,
        ),
        namespace: VfsNamespace(workspaceHostRoot: workspaceDir.path),
        memory: VirtualContextMemory(
          sessionId: 'sess_gate',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
      processTable.registerProcess(pcb);
      ctx = const SyscallContext(
        pid: 1,
        capHandle: CapHandle('cap_workspace_rw'),
        sessionId: 'sess_gate',
      );
    });

    tearDown(() {
      if (workspaceDir.existsSync()) {
        workspaceDir.deleteSync(recursive: true);
      }
    });

    SyscallGate createGate({
      required ApprovalHandler approvalHandler,
      List<SyscallHook> hooks = const <SyscallHook>[],
      IoCapConfig ioCapConfig = const IoCapConfig(),
      JjAuditInfoProvider? jjProvider,
    }) {
      return SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: approvalHandler),
        ioCapper: IoPayloadCapper(
          config: ioCapConfig,
          workspaceHostRoot: workspaceDir.path,
        ),
        auditLogger: auditLogger,
        redactor: redactor,
        hooks: hooks,
        jjAuditInfoProvider: jjProvider,
      );
    }

    test('enforces Stage 3 hook BEFORE Stage 4 ApprovalGate (approval handler called 0 times)', () async {
      final hook = _TestBlockHook(blockedCommand: 'git status');
      final approvalHandler = PolicyApprovalHandler.alwaysAllow();
      var driverExecuted = false;

      final gate = createGate(
        approvalHandler: approvalHandler,
        hooks: <SyscallHook>[hook],
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_exec',
          requiredRight: CapRight.exec,
          kind: 'execute',
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async {
            driverExecuted = true;
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{'exitCode': 0},
            );
          },
        ),
      );

      final res = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{'command': 'git status'},
        ),
      );

      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.eperm));
      expect(res.error!.reason, equals('HOOK_BLOCKED'));
      expect(hook.beforeCallCount, equals(1));
      expect(hook.afterCallCount, equals(0));
      expect(approvalHandler.recordedRequests, isEmpty);
      expect(driverExecuted, isFalse);

      final records = File(auditLogger.syscallsLogPath)
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(records, hasLength(1));
      expect(records.first['decision'], equals('HOOK_BLOCKED'));
      expect(records.first['errorCode'], equals('EPERM'));
      expect(records.first['approvalRequired'], isFalse);
    });

    test('transitions PCB to WAITING_APPROVAL, uses non-destructive preview, and blocks side effects on reject_once', () async {
      ProcessState? observedStateDuringWait;
      var previewCalls = 0;
      var driverCalls = 0;

      final approvalHandler = PolicyApprovalHandler((req, _) async {
        observedStateDuringWait = pcb.state;
        expect(req.title, equals('Squash working change into @- (1 files)'));
        expect(req.content, hasLength(1));
        return const ApprovalDecision.rejectOnce();
      });

      final gate = createGate(
        approvalHandler: approvalHandler,
        jjProvider: () async => const JjAuditInfo(
          jjChangeId: 'chg_work_1',
          jjOpId: 'op_123456',
        ),
      );

      pcb.jjContext.enterActive(
        baseOpId: 'op_base',
        parentChangeId: 'chg_parent',
        workingChangeId: 'chg_work_1',
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_tx_squash',
          requiredRight: CapRight.vcsTx,
          kind: 'edit',
          checkPreconditions: (p, _) async {
            if (p.jjContext.state != TxState.active) {
              return const SyscallError(
                code: SyscallErrorCode.econflict,
                reason: 'NO_ACTIVE_TRANSACTION',
                message: 'No active transaction.',
              );
            }
            return null;
          },
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          approvalPreviewBuilder: (_) async {
            previewCalls += 1;
            return ApprovalPreview(
              title: 'Squash working change into @- (1 files)',
              kind: 'edit',
              content: const <Map<String, dynamic>>[
                <String, dynamic>{'type': 'diff', 'path': 'lib/a.dart'},
              ],
            );
          },
          handler: (_) async {
            driverCalls += 1;
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{'squashed': true},
            );
          },
        ),
      );

      final deniedRes = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_squash'),
      );

      expect(observedStateDuringWait, equals(ProcessState.waitingApproval));
      expect(pcb.state, equals(ProcessState.running));
      expect(previewCalls, equals(1));
      expect(driverCalls, equals(0));
      expect(deniedRes.ok, isFalse);
      expect(deniedRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(deniedRes.error!.reason, equals('DENIED_BY_USER'));
      expect(deniedRes.error!.recoverable, isTrue);

      final records = File(auditLogger.syscallsLogPath)
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(records.last['decision'], equals('DENIED_BY_USER'));
      expect(records.last['approvalRequired'], isTrue);
      expect(records.last['jjChangeId'], equals('chg_work_1'));
      expect(records.last['jjOpId'], equals('op_123456'));
    });

    test('Stage 2 precondition rejects sys_tx_squash before Stage 4 approval when TxState != active', () async {
      final approvalHandler = PolicyApprovalHandler.alwaysAllow();
      final gate = createGate(approvalHandler: approvalHandler);

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_tx_squash',
          requiredRight: CapRight.vcsTx,
          kind: 'edit',
          checkPreconditions: (p, _) async {
            if (p.jjContext.state != TxState.active) {
              return const SyscallError(
                code: SyscallErrorCode.econflict,
                reason: 'NO_ACTIVE_TRANSACTION',
                message: 'TxState is not active.',
              );
            }
            return null;
          },
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async =>
              const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{}),
        ),
      );

      final res = await gate.invoke(ctx, SyscallRequest(name: 'sys_tx_squash'));
      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.econflict));
      expect(res.error!.reason, equals('NO_ACTIVE_TRANSACTION'));
      expect(approvalHandler.recordedRequests, isEmpty);
    });

    test('allow_always caches signature but never bypasses Stage 1-3 checks, and cancellation returns ECANCELLED', () async {
      final approvalHandler = PolicyApprovalHandler.alwaysAllowSession();
      final hook = _TestBlockHook(blockedCommand: 'git diff');
      final gate = createGate(
        approvalHandler: approvalHandler,
        hooks: <SyscallHook>[hook],
      );

      var runCount = 0;
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_exec',
          requiredRight: CapRight.exec,
          kind: 'execute',
          validateArgs: (args) {
            if (args['command'] is! String ||
                (args['command'] as String).isEmpty) {
              return const SyscallError(
                code: SyscallErrorCode.einval,
                reason: 'INVALID_ARGS',
                message: 'command must be non-empty string',
              );
            }
            return null;
          },
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          approvalSignatureBuilder: (args) => 'exec:${args['command']}',
          handler: (_) async {
            runCount += 1;
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{'exitCode': 0},
            );
          },
        ),
      );

      final first = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_exec', args: const <String, dynamic>{'command': 'echo hi'}),
      );
      final second = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_exec', args: const <String, dynamic>{'command': 'echo hi'}),
      );
      expect(first.ok, isTrue);
      expect(second.ok, isTrue);
      expect(runCount, equals(2));
      expect(approvalHandler.recordedRequests, hasLength(1));

      // Cancel during approval wait unblocks immediately with ECANCELLED and zero side effects.
      final cancelSource = CancellationTokenSource();
      final hangingGate = createGate(
        approvalHandler: PolicyApprovalHandler((_, _) {
          return Completer<ApprovalDecision>().future;
        }),
      );
      hangingGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_tx_squash',
          requiredRight: CapRight.vcsTx,
          kind: 'edit',
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async {
            fail('Handler must not execute when cancelled during approval');
          },
        ),
      );

      final pendingFuture = hangingGate.invoke(
        SyscallContext(
          pid: 1,
          capHandle: const CapHandle('cap_workspace_rw'),
          sessionId: 'sess_gate',
          cancelToken: cancelSource.token,
        ),
        SyscallRequest(name: 'sys_tx_squash'),
      );
      cancelSource.cancel('user_cancelled');
      final cancelledRes = await pendingFuture;
      expect(cancelledRes.ok, isFalse);
      expect(cancelledRes.error!.code, equals(SyscallErrorCode.ecancelled));
      expect(pcb.state, equals(ProcessState.running));
    });

    test('records syscalls.jsonl on all exit paths (EINVAL, EPERM sys_spawn, EDQUOT, EIO uncaught exception, Stage 7 cap)', () async {
      final gate = createGate(
        approvalHandler: PolicyApprovalHandler.alwaysAllow(),
        ioCapConfig: const IoCapConfig(maxLines: 6, maxUtf8Bytes: 1024),
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_read_lines',
          requiredRight: CapRight.read,
          kind: 'read',
          applyIoCap: true,
          cappedTextFields: const <String>['content'],
          validateArgs: (args) {
            if (args['path'] == null) {
              return const SyscallError(
                code: SyscallErrorCode.einval,
                reason: 'MISSING_PATH',
                message: 'path is required',
              );
            }
            return null;
          },
          handler: (execCtx) async {
            if (execCtx.args['path'] == 'throw') {
              throw StateError('boom with top-secret-token');
            }
            final lines = List<String>.generate(20, (i) => 'L$i').join('\n');
            return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
              'sha256': 'hash123',
              'content': lines,
            });
          },
        ),
      );

      // 1. Unknown syscall -> EINVAL
      final unknownRes = await gate.invoke(ctx, SyscallRequest(name: 'sys_nope'));
      expect(unknownRes.error!.code, equals(SyscallErrorCode.einval));

      // 2. Stage 1 single-process lock -> EPERM
      final spawnRes = await gate.invoke(ctx, SyscallRequest(name: 'sys_spawn'));
      expect(spawnRes.error!.code, equals(SyscallErrorCode.eperm));
      expect(spawnRes.error!.reason, equals('STAGE1_SINGLE_PROCESS_LOCK'));

      // 3. Stage 1 validation failure -> EINVAL
      final invalidArgRes = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_read_lines'),
      );
      expect(invalidArgRes.error!.code, equals(SyscallErrorCode.einval));

      // 4. Stage 5 uncaught exception -> redacted EIO
      final crashRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_read_lines',
          args: const <String, dynamic>{'path': 'throw'},
        ),
      );
      expect(crashRes.ok, isFalse);
      expect(crashRes.error!.code, equals(SyscallErrorCode.eio));
      expect(crashRes.error!.message, isNot(contains('top-secret-token')));
      expect(crashRes.error!.message, contains('<REDACTED>'));

      // 5. Normal call hitting Stage 7 capper -> truncated: true
      final cappedRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_read_lines',
          args: const <String, dynamic>{'path': '/workspace/a.dart'},
        ),
      );
      expect(cappedRes.ok, isTrue);
      expect(cappedRes.value!['sha256'], equals('hash123'));
      expect(cappedRes.value!['truncated'], isTrue);

      // 6. CSpace missing right -> EPERM (CAPABILITY_DENIED)
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_admin_op',
          requiredRight: CapRight.admin,
          kind: 'execute',
          handler: (_) async =>
              const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{}),
        ),
      );
      final capDeniedRes = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_admin_op'),
      );
      expect(capDeniedRes.ok, isFalse);
      expect(capDeniedRes.error!.code, equals(SyscallErrorCode.eperm));
      expect(capDeniedRes.error!.reason, equals('CAPABILITY_DENIED'));

      // 7. Quota exceeded -> EDQUOT (QUOTA_EXCEEDED)
      pcb.quotaUsage.syscallCountInTurn = pcb.quota.maxSyscallCountPerTurn;
      final quotaRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_read_lines',
          args: const <String, dynamic>{'path': '/workspace/a.dart'},
        ),
      );
      expect(quotaRes.ok, isFalse);
      expect(quotaRes.error!.code, equals(SyscallErrorCode.edquot));
      expect(quotaRes.error!.reason, equals('SYSCALL_QUOTA_EXCEEDED'));

      final lines = File(auditLogger.syscallsLogPath)
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(lines, hasLength(7));
      expect(lines[0]['decision'], equals('INVALID_ARGS'));
      expect(lines[1]['decision'], equals('DENIED_BY_POLICY'));
      expect(lines[2]['decision'], equals('INVALID_ARGS'));
      expect(lines[3]['errorCode'], equals('EIO'));
      expect(lines[4]['truncated'], isTrue);
      expect(lines[5]['decision'], equals('DENIED_BY_POLICY'));
      expect(lines[5]['errorReason'], equals('CAPABILITY_DENIED'));
      expect(lines[6]['decision'], equals('QUOTA_EXCEEDED'));
      expect(lines[6]['errorCode'], equals('EDQUOT'));
    });

    test('E3 structural dependency check: agent_kernel has zero forbidden imports', () {
      final libDir = Directory(
        p.join(Directory.current.path, 'packages', 'agent_kernel', 'lib'),
      );
      final targetDir = libDir.existsSync()
          ? libDir
          : Directory(p.join(Directory.current.path, 'lib'));
      expect(targetDir.existsSync(), isTrue);

      final forbiddenPatterns = <String>[
        'package:http/',
        'dart:ffi',
        'package:win32/',
        'dart:mirrors',
        'package:agent_drivers/',
        'package:agent_runtime/',
        'package:agent_acp/',
      ];

      final dartFiles = targetDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      expect(dartFiles, isNotEmpty);

      for (final file in dartFiles) {
        final content = file.readAsStringSync();
        for (final forbidden in forbiddenPatterns) {
          expect(
            content.contains(forbidden),
            isFalse,
            reason: '${file.path} must not depend on $forbidden ([D-001])',
          );
        }
      }
    });
  });
}
