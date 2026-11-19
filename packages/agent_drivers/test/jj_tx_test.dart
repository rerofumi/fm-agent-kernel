import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('JjDriver CoW Transaction Control [D-003], [D-014], [D-015], RV-001', () {
    late Directory repoDir;
    late VfsNamespace namespace;
    late JjTxContext jjContext;
    late JjDriver jjDriver;
    late AuditLogger auditLogger;
    late KernelProcessTable processTable;
    late ProcessControlBlock pcb;

    const sessionId = 'sess_wp6_tx';
    const capHandle = CapHandle('cap_workspace_rw');
    const ctx = SyscallContext(
      pid: 1,
      capHandle: capHandle,
      sessionId: sessionId,
    );

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
      expect(res.exitCode, equals(0), reason: 'op log failed: ${res.stderr}');
      return (res.stdout as String).trim();
    }

    String readCommitField(String rev, String template) {
      final res = runJjSync(<String>[
        'log',
        '--no-graph',
        '-r',
        rev,
        '--ignore-working-copy',
        '-T',
        template,
      ]);
      expect(res.exitCode, equals(0), reason: 'jj log -r $rev failed: ${res.stderr}');
      return (res.stdout as String).trim();
    }

    List<int> readFileBytesAtRev(String rev, String relPath) {
      final res = Process.runSync(
        'jj',
        <String>[
          '--no-pager',
          'file',
          'show',
          '-r',
          rev,
          '--ignore-working-copy',
          relPath,
        ],
        workingDirectory: repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
        stdoutEncoding: null,
      );
      expect(res.exitCode, equals(0), reason: 'jj file show $rev:$relPath failed: ${res.stderr}');
      return res.stdout as List<int>;
    }

    SyscallGate createGate({required ApprovalHandler approvalHandler}) {
      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: approvalHandler),
        ioCapper: IoPayloadCapper(workspaceHostRoot: repoDir.path),
        auditLogger: auditLogger,
        jjAuditInfoProvider: jjDriver.getAuditInfo,
      );
      jjDriver.registerAllSyscalls(gate);
      return gate;
    }

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('wp6_jj_tx_');
      final initRes = runJjSync(<String>['git', 'init', '--colocate']);
      expect(initRes.exitCode, equals(0), reason: '${initRes.stderr}');
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP6 Tester']);
      runJjSync(<String>['config', 'set', '--repo', 'user.email', 'wp6@example.com']);

      File(p.join(repoDir.path, 'app.dart')).writeAsStringSync(
        'String greet() => "v1";\n',
      );
      File(p.join(repoDir.path, 'crlf.txt')).writeAsBytesSync(
        utf8.encode('alpha\r\nbeta\r\n'),
      );
      File(p.join(repoDir.path, 'remove_me.txt')).writeAsStringSync('will be removed\n');
      expect(runJjSync(<String>['describe', '-m', 'human base commit']).exitCode, equals(0));
      expect(runJjSync(<String>['new', '-m', 'human wip commit']).exitCode, equals(0));

      // Create snapshotted base state for human WIP, then add unsnapshotted edits on top.
      File(p.join(repoDir.path, 'app.dart')).writeAsStringSync(
        'String greet() => "human-wip-snap";\n',
      );
      expect(runJjSync(<String>['status']).exitCode, equals(0));

      // Now introduce unsnapshotted human edits & an untracked human file.
      File(p.join(repoDir.path, 'app.dart')).writeAsStringSync(
        'String greet() => "human-unsnapshotted-wip";\n',
      );
      File(p.join(repoDir.path, 'human_untracked.txt')).writeAsStringSync(
        'human untracked content\n',
      );

      namespace = VfsNamespace(workspaceHostRoot: repoDir.path);
      jjContext = JjTxContext();
      jjDriver = JjDriver(namespace: namespace, txContext: jjContext);
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
        jjContext: jjContext,
        memory: VirtualContextMemory(
          sessionId: sessionId,
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: JjDriver.allToolSchemas(),
          ),
        ),
      );
      processTable.registerProcess(pcb);
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test('Read-Only reads preserve op_id, then ensureActiveTransaction isolates @ without touching @-', () async {
      final preSessionOpId = readHeadOpId();

      // While TxState.readOnly, reads must not snapshot human's unsnapshotted changes.
      final statusRo = await jjDriver.status();
      expect(statusRo.ok, isTrue);
      expect(statusRo.value!['ignoredWorkingCopy'], isTrue);
      expect(readHeadOpId(), equals(preSessionOpId));

      final humanExpectedAppBytes = File(p.join(repoDir.path, 'app.dart')).readAsBytesSync();
      final humanExpectedUntrackedBytes =
          File(p.join(repoDir.path, 'human_untracked.txt')).readAsBytesSync();

      // Begin transaction via ensureActiveTransaction.
      final beginRes = await jjDriver.ensureActiveTransaction(
        description: 'agent-os: isolated edit',
      );
      expect(beginRes.ok, isTrue, reason: '${beginRes.error}');
      expect(jjContext.state, equals(TxState.active));
      expect(jjContext.baseOpId, isNotNull);
      expect(jjContext.baseOpId, isNot(equals(preSessionOpId)));
      expect(jjContext.allowedCheckpointOpIds, contains(jjContext.baseOpId));
      expect(jjContext.parentChangeId, isNotNull);
      expect(jjContext.workingChangeId, isNotNull);
      expect(jjContext.workingChangeId, isNot(equals(jjContext.parentChangeId)));

      // `.agent_os/.gitignore` is guaranteed to exist with `*\n`.
      expect(
        File(p.join(repoDir.path, '.agent_os', '.gitignore')).readAsStringSync(),
        equals('*\n'),
      );

      final parentCommitIdBeforeEdits = readCommitField('@-', 'commit_id');
      expect(readCommitField('@-', 'change_id.short(12)'), equals(jjContext.parentChangeId));
      expect(readFileBytesAtRev('@-', 'app.dart'), equals(humanExpectedAppBytes));
      expect(
        readFileBytesAtRev('@-', 'human_untracked.txt'),
        equals(humanExpectedUntrackedBytes),
      );

      // Idempotent second call does not split another commit.
      final gate = createGate(approvalHandler: PolicyApprovalHandler.alwaysAllow());
      final secondBegin = await gate.invoke(ctx, SyscallRequest(name: 'sys_tx_begin'));
      expect(secondBegin.ok, isTrue);
      expect(secondBegin.value!['alreadyActive'], isTrue);
      expect(readCommitField('@', 'change_id.short(12)'), equals(jjContext.workingChangeId));

      // Mutate files in @ and sync snapshot; @- must stay 100% byte-identical.
      File(p.join(repoDir.path, 'app.dart')).writeAsStringSync('String greet() => "agent";\n');
      File(p.join(repoDir.path, 'agent_new.txt')).writeAsStringSync('new agent file\n');
      final syncRes = await jjDriver.syncWorkingCopySnapshot();
      expect(syncRes.ok, isTrue);

      expect(readCommitField('@-', 'commit_id'), equals(parentCommitIdBeforeEdits));
      expect(readFileBytesAtRev('@-', 'app.dart'), equals(humanExpectedAppBytes));
      expect(
        readFileBytesAtRev('@-', 'human_untracked.txt'),
        equals(humanExpectedUntrackedBytes),
      );

      final diffAtParent = await jjDriver.diff(rev: '@-');
      expect(diffAtParent.ok, isTrue);
      expect(diffAtParent.value!['diff'], isNot(contains('agent_new.txt')));
      expect(diffAtParent.value!['diff'], isNot(contains('"agent"')));
    });

    test('RV-001: sys_tx_describe and sys_tx_squash are rejected at Stage 2 with ECONFLICT (NO_ACTIVE_TRANSACTION) when TxState != active', () async {
      final approvalHandler = PolicyApprovalHandler.alwaysAllow();
      final gate = createGate(approvalHandler: approvalHandler);
      final opBefore = readHeadOpId();
      final commitBefore = readCommitField('@', 'commit_id');

      // 1. Initial TxState.readOnly -> immediate Stage 2 ECONFLICT, 0 approval requests.
      final descRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_tx_describe',
          args: const <String, dynamic>{'message': 'should fail'},
        ),
      );
      expect(descRes.ok, isFalse);
      expect(descRes.error!.code, equals(SyscallErrorCode.econflict));
      expect(descRes.error!.reason, equals('NO_ACTIVE_TRANSACTION'));

      final squashRes = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_squash'),
      );
      expect(squashRes.ok, isFalse);
      expect(squashRes.error!.code, equals(SyscallErrorCode.econflict));
      expect(squashRes.error!.reason, equals('NO_ACTIVE_TRANSACTION'));
      expect(approvalHandler.recordedRequests, isEmpty);
      expect(readHeadOpId(), equals(opBefore));
      expect(readCommitField('@', 'commit_id'), equals(commitBefore));

      // 2. Also verify direct calls return ECONFLICT.
      final directDesc = await jjDriver.txDescribe(message: 'direct fail');
      expect(directDesc.ok, isFalse);
      expect(directDesc.error!.code, equals(SyscallErrorCode.econflict));
      expect(directDesc.error!.reason, equals('NO_ACTIVE_TRANSACTION'));

      final directSquash = await jjDriver.txSquash();
      expect(directSquash.ok, isFalse);
      expect(directSquash.error!.code, equals(SyscallErrorCode.econflict));
      expect(directSquash.error!.reason, equals('NO_ACTIVE_TRANSACTION'));
    });

    test('RV-001: sys_tx_squash Stage 4 preview is strictly non-destructive (--ignore-working-copy) and rejection leaves zero side effects', () async {
      final beginRes = await jjDriver.ensureActiveTransaction(description: 'agent work');
      expect(beginRes.ok, isTrue);

      File(p.join(repoDir.path, 'app.dart')).writeAsStringSync('String greet() => "agent-edited";\n');
      File(p.join(repoDir.path, 'added.dart')).writeAsStringSync('int added() => 42;\n');
      File(p.join(repoDir.path, 'remove_me.txt')).deleteSync();
      expect((await jjDriver.syncWorkingCopySnapshot()).ok, isTrue);

      final opBeforeApproval = readHeadOpId();
      final wcCommitBefore = readCommitField('@', 'commit_id');
      final parentCommitBefore = readCommitField('@-', 'commit_id');
      final appShaBefore = sha256
          .convert(File(p.join(repoDir.path, 'app.dart')).readAsBytesSync())
          .toString();

      final rejectHandler = PolicyApprovalHandler.alwaysReject();
      final gate = createGate(approvalHandler: rejectHandler);

      final squashRejected = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_squash'),
      );

      expect(squashRejected.ok, isFalse);
      expect(squashRejected.error!.code, equals(SyscallErrorCode.eacces));
      expect(squashRejected.error!.reason, equals('DENIED_BY_USER'));
      expect(pcb.state, equals(ProcessState.running));
      expect(jjContext.state, equals(TxState.active));

      // Preview was delivered to ApprovalHandler with diff details.
      expect(rejectHandler.recordedRequests, hasLength(1));
      final req = rejectHandler.recordedRequests.first;
      expect(req.title, equals('Squash working change into @- (3 files)'));
      expect(req.kind, equals('edit'));
      final diffBlocks = req.content.where((c) => c['type'] == 'diff').toList();
      expect(diffBlocks, hasLength(3));
      expect(
        diffBlocks.any(
          (d) =>
              (d['path'] as String).endsWith('/added.dart') &&
              d['oldText'] == null &&
              (d['newText'] as String).contains('42'),
        ),
        isTrue,
      );
      expect(
        diffBlocks.any(
          (d) =>
              (d['path'] as String).endsWith('/app.dart') &&
              (d['oldText'] as String).contains('human-unsnapshotted-wip') &&
              (d['newText'] as String).contains('agent-edited'),
        ),
        isTrue,
      );

      // op_id, @ commit_id, @- commit_id, and workspace file SHA-256 are 100% unchanged.
      expect(readHeadOpId(), equals(opBeforeApproval));
      expect(readCommitField('@', 'commit_id'), equals(wcCommitBefore));
      expect(readCommitField('@-', 'commit_id'), equals(parentCommitBefore));
      final appShaAfter = sha256
          .convert(File(p.join(repoDir.path, 'app.dart')).readAsBytesSync())
          .toString();
      expect(appShaAfter, equals(appShaBefore));
    });

    test('sys_tx_describe and non-interactive sys_tx_squash (-u and -m) complete without hanging and return to TxState.readOnly', () async {
      final allowHandler = PolicyApprovalHandler.alwaysAllow();
      final gate = createGate(approvalHandler: allowHandler);

      // Round 1: Both @- and @ have non-empty descriptions; squash without message uses `-u`.
      expect((await gate.invoke(ctx, SyscallRequest(name: 'sys_tx_begin'))).ok, isTrue);
      final descRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_tx_describe',
          args: const <String, dynamic>{'message': 'agent temporary description'},
        ),
      );
      expect(descRes.ok, isTrue);
      expect(readCommitField('@', 'description'), contains('agent temporary description'));

      File(p.join(repoDir.path, 'app.dart')).writeAsStringSync('String greet() => "squashed-1";\n');
      expect((await jjDriver.syncWorkingCopySnapshot()).ok, isTrue);

      final squashUseDest = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_squash'),
      );
      expect(squashUseDest.ok, isTrue, reason: '${squashUseDest.error}');
      expect(squashUseDest.value!['squashed'], isTrue);
      expect(squashUseDest.value!['usedDestinationMessage'], isTrue);
      expect(jjContext.state, equals(TxState.readOnly));
      expect(
        readCommitField('@-', 'description'),
        contains('human wip commit'),
      );
      expect(
        String.fromCharCodes(readFileBytesAtRev('@-', 'app.dart')),
        contains('squashed-1'),
      );

      // Immediately calling sys_tx_squash again must fail at Stage 2 (NO_ACTIVE_TRANSACTION).
      final squashAfterDone = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_squash'),
      );
      expect(squashAfterDone.ok, isFalse);
      expect(squashAfterDone.error!.code, equals(SyscallErrorCode.econflict));
      expect(squashAfterDone.error!.reason, equals('NO_ACTIVE_TRANSACTION'));
      expect(allowHandler.recordedRequests, hasLength(1));

      // Round 2: Squash with explicit message (`-m`).
      expect((await gate.invoke(ctx, SyscallRequest(name: 'sys_tx_begin'))).ok, isTrue);
      File(p.join(repoDir.path, 'app.dart')).writeAsStringSync('String greet() => "squashed-2";\n');
      expect((await jjDriver.syncWorkingCopySnapshot()).ok, isTrue);

      final squashWithMsg = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_tx_squash',
          args: const <String, dynamic>{'message': 'final squashed message'},
        ),
      );
      expect(squashWithMsg.ok, isTrue, reason: '${squashWithMsg.error}');
      expect(squashWithMsg.value!['usedDestinationMessage'], isFalse);
      expect(jjContext.state, equals(TxState.readOnly));
      expect(readCommitField('@-', 'description'), contains('final squashed message'));
      expect(
        String.fromCharCodes(readFileBytesAtRev('@-', 'app.dart')),
        contains('squashed-2'),
      );
    });

    test('sys_tx_rollback restores byte-identical files, deletes new files, preserves .agent_os/logs/, and blocks invalid/pre-session op_ids', () async {
      final preSessionOpId = readHeadOpId();
      final gate = createGate(approvalHandler: PolicyApprovalHandler.alwaysAllow());

      // Never started transaction -> EACCES on rollback.
      final neverStartedRes = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_rollback'),
      );
      expect(neverStartedRes.ok, isFalse);
      expect(neverStartedRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(neverStartedRes.error!.reason, equals('INVALID_OR_PRE_SESSION_OP_ID'));

      // Capture exact pre-transaction workspace bytes.
      final initialAppBytes = File(p.join(repoDir.path, 'app.dart')).readAsBytesSync();
      final initialCrlfBytes = File(p.join(repoDir.path, 'crlf.txt')).readAsBytesSync();
      final initialUntrackedBytes =
          File(p.join(repoDir.path, 'human_untracked.txt')).readAsBytesSync();
      final initialRemoveMeBytes =
          File(p.join(repoDir.path, 'remove_me.txt')).readAsBytesSync();

      // Start transaction and perform multiple destructive changes + write audit logs.
      expect((await gate.invoke(ctx, SyscallRequest(name: 'sys_tx_begin'))).ok, isTrue);
      File(p.join(repoDir.path, 'app.dart')).writeAsStringSync('BROKEN CODE;\n');
      File(p.join(repoDir.path, 'crlf.txt')).writeAsStringSync('corrupted lf\n');
      File(p.join(repoDir.path, 'remove_me.txt')).deleteSync();
      final nestedNewFile = File(p.join(repoDir.path, 'lib', 'generated', 'temp.dart'));
      nestedNewFile.createSync(recursive: true);
      nestedNewFile.writeAsStringSync('void temp() {}\n');
      expect((await jjDriver.syncWorkingCopySnapshot()).ok, isTrue);
      final midCheckpointOpId = jjContext.currentOpId!;

      // Further edit after midCheckpointOpId.
      File(p.join(repoDir.path, 'extra_after_mid.txt')).writeAsStringSync('later\n');
      expect((await jjDriver.syncWorkingCopySnapshot()).ok, isTrue);

      // Invalid op_id syntax -> EINVAL.
      final malformedRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_tx_rollback',
          args: const <String, dynamic>{'targetOpId': 'not-hex!!'},
        ),
      );
      expect(malformedRes.ok, isFalse);
      expect(malformedRes.error!.code, equals(SyscallErrorCode.einval));
      expect(malformedRes.error!.reason, equals('INVALID_OP_ID'));

      // Pre-session op_id -> EACCES (must not wipe user history predating session).
      final preSessionAttempt = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_tx_rollback',
          args: <String, dynamic>{'targetOpId': preSessionOpId},
        ),
      );
      expect(preSessionAttempt.ok, isFalse);
      expect(preSessionAttempt.error!.code, equals(SyscallErrorCode.eacces));
      expect(preSessionAttempt.error!.reason, equals('INVALID_OR_PRE_SESSION_OP_ID'));

      // Mid-session checkpoint (using 12-char short prefix) IS permitted.
      final midRestoreRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_tx_rollback',
          args: <String, dynamic>{
            'targetOpId': midCheckpointOpId.substring(0, 12),
          },
        ),
      );
      expect(midRestoreRes.ok, isTrue, reason: '${midRestoreRes.error}');
      expect(File(p.join(repoDir.path, 'extra_after_mid.txt')).existsSync(), isFalse);
      expect(nestedNewFile.existsSync(), isTrue);

      // Full rollback to baseOpId (targetOpId omitted).
      final rollbackRes = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_rollback'),
      );
      expect(rollbackRes.ok, isTrue, reason: '${rollbackRes.error}');
      expect(rollbackRes.value!['rolledBack'], isTrue);
      expect(rollbackRes.value!['restoredToOpId'], equals(jjContext.baseOpId));
      expect(jjContext.state, equals(TxState.readOnly));

      // Verify byte-exact restoration and deletion of all agent-created files.
      expect(File(p.join(repoDir.path, 'app.dart')).readAsBytesSync(), equals(initialAppBytes));
      expect(File(p.join(repoDir.path, 'crlf.txt')).readAsBytesSync(), equals(initialCrlfBytes));
      expect(
        File(p.join(repoDir.path, 'human_untracked.txt')).readAsBytesSync(),
        equals(initialUntrackedBytes),
      );
      expect(
        File(p.join(repoDir.path, 'remove_me.txt')).readAsBytesSync(),
        equals(initialRemoveMeBytes),
      );
      expect(nestedNewFile.existsSync(), isFalse);

      // Audit logs under `.agent_os/logs/` must remain intact across `jj op restore`!
      await auditLogger.flush();
      final logFile = File(auditLogger.syscallsLogPath);
      expect(logFile.existsSync(), isTrue);
      final logLines = logFile.readAsLinesSync();
      expect(logLines.length, greaterThanOrEqualTo(5));

      // Subsequent describe/squash after rollback must be rejected at Stage 2.
      final squashAfterRollback = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_squash'),
      );
      expect(squashAfterRollback.ok, isFalse);
      expect(squashAfterRollback.error!.code, equals(SyscallErrorCode.econflict));
      expect(squashAfterRollback.error!.reason, equals('NO_ACTIVE_TRANSACTION'));
    });
  });
}
