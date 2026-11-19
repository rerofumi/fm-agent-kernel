import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/fs_jj_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AsyncMutex [D-014]', () {
    test('serializes concurrent tasks in strict FIFO order and recovers on error', () async {
      final mutex = AsyncMutex();
      final events = <String>[];

      final f1 = mutex.synchronized(() async {
        events.add('start-1');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        events.add('end-1');
        return 1;
      });

      final f2 = mutex.synchronized(() async {
        events.add('start-2');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        events.add('throw-2');
        throw StateError('boom');
      });

      final f3 = mutex.synchronized(() async {
        events.add('start-3');
        events.add('end-3');
        return 3;
      });

      expect(await f1, equals(1));
      await expectLater(f2, throwsStateError);
      expect(await f3, equals(3));
      expect(mutex.isLocked, isFalse);

      expect(
        events,
        equals(<String>[
          'start-1',
          'end-1',
          'start-2',
          'throw-2',
          'start-3',
          'end-3',
        ]),
      );
    });
  });

  group('JjDriver Read-Only & Template Integration (isolated jj 0.46.0 repo) [D-003], [D-014]', () {
    late Directory repoDir;
    late VfsNamespace namespace;
    late JjDriver jjDriver;

    ProcessResult runJjSync(List<String> args, {String? workingDir}) {
      return Process.runSync(
        'jj',
        <String>['--no-pager', ...args],
        workingDirectory: workingDir ?? repoDir.path,
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

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('wp3_jj_repo_');
      final initRes = runJjSync(<String>['git', 'init', '--colocate']);
      expect(initRes.exitCode, equals(0), reason: 'jj git init failed: ${initRes.stderr}');

      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP3 Tester']);
      runJjSync(<String>['config', 'set', '--repo', 'user.email', 'wp3@example.com']);

      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base line 1\n');
      final descRes = runJjSync(<String>['describe', '-m', 'base commit']);
      expect(descRes.exitCode, equals(0), reason: '${descRes.stderr}');
      final newRes = runJjSync(<String>['new', '-m', 'work commit']);
      expect(newRes.exitCode, equals(0), reason: '${newRes.stderr}');

      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base line 1\nmodified line 2\n');
      final snapRes = runJjSync(<String>['status']);
      expect(snapRes.exitCode, equals(0));

      namespace = VfsNamespace(workspaceHostRoot: repoDir.path);
      jjDriver = JjDriver(namespace: namespace);
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test('TxState.readOnly keeps head op_id 100% invariant even with unsnapshotted edits', () async {
      final opBefore = readHeadOpId();

      // Introduce unsnapshotted modifications AND an untracked new file.
      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('unsnapshotted edit!\n');
      File(p.join(repoDir.path, 'untracked.txt')).writeAsStringSync('untracked content\n');

      final statusRes = await jjDriver.status();
      expect(statusRes.ok, isTrue, reason: '${statusRes.error}');
      expect(statusRes.value!['ignoredWorkingCopy'], isTrue);
      expect(statusRes.value!['opId'], equals(opBefore));
      expect((statusRes.value!['workingCopy'] as Map<String, dynamic>)['description'], contains('work commit'));
      expect((statusRes.value!['parent'] as Map<String, dynamic>)['description'], contains('base commit'));

      final logRes = await jjDriver.log(revset: '::@ | @-', limit: 10);
      expect(logRes.ok, isTrue, reason: '${logRes.error}');
      expect(logRes.value!['ignoredWorkingCopy'], isTrue);
      expect(logRes.value!['count'], greaterThanOrEqualTo(2));

      final diffRes = await jjDriver.diff(rev: '@');
      expect(diffRes.ok, isTrue, reason: '${diffRes.error}');
      expect(diffRes.value!['ignoredWorkingCopy'], isTrue);
      expect(diffRes.value!['diff'], contains('modified line 2'));
      expect(diffRes.value!['diff'], isNot(contains('unsnapshotted edit!')));

      final auditInfo = await jjDriver.getAuditInfo();
      expect(auditInfo.jjOpId, equals(opBefore));
      expect(auditInfo.jjChangeId, isNotNull);
      expect(auditInfo.jjChangeId!.length, equals(12));

      final opAfter = readHeadOpId();
      expect(opAfter, equals(opBefore));
    });

    test('custom JSON Lines -T template accurately captures conflict and empty flags', () async {
      // Create an empty commit on top of @ and check empty == true, conflict == false.
      expect(runJjSync(<String>['new', '-m', 'empty check']).exitCode, equals(0));
      final emptyLog = await jjDriver.log(revset: '@', limit: 1);
      expect(emptyLog.ok, isTrue);
      final emptyCommit = (emptyLog.value!['commits'] as List<Map<String, dynamic>>).first;
      expect(emptyCommit['empty'], isTrue);
      expect(emptyCommit['conflict'], isFalse);
      expect(emptyCommit['change_id'], isA<String>());
      expect(emptyCommit['change_id_full'], isA<String>());
      expect(emptyCommit['commit_id'], isA<String>());
      expect(emptyCommit['parents'], isA<List<dynamic>>());

      // Create two divergent branches off base commit (@--) that modify the same line, then merge them.
      final branchARes = runJjSync(<String>['new', 'root()+', '-m', 'branch A']);
      expect(branchARes.exitCode, equals(0), reason: '${branchARes.stderr}');
      File(p.join(repoDir.path, 'conflict.txt')).writeAsStringSync('version A\n');
      expect(runJjSync(<String>['status']).exitCode, equals(0));
      final branchAChangeId = (runJjSync(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '-T',
        'change_id',
      ]).stdout as String).trim();

      expect(runJjSync(<String>['new', 'root()+', '-m', 'branch B']).exitCode, equals(0));
      File(p.join(repoDir.path, 'conflict.txt')).writeAsStringSync('version B\n');
      expect(runJjSync(<String>['status']).exitCode, equals(0));
      final branchBChangeId = (runJjSync(<String>[
        'log',
        '--no-graph',
        '-r',
        '@',
        '-T',
        'change_id',
      ]).stdout as String).trim();

      final mergeRes = runJjSync(<String>[
        'new',
        branchAChangeId,
        branchBChangeId,
        '-m',
        'merge conflict',
      ]);
      expect(mergeRes.exitCode, equals(0), reason: '${mergeRes.stderr}');

      final conflictStatus = await jjDriver.status();
      expect(conflictStatus.ok, isTrue, reason: '${conflictStatus.error}');
      final wc = conflictStatus.value!['workingCopy'] as Map<String, dynamic>;
      expect(wc['conflict'], isTrue);
      expect(wc['empty'], isTrue);
      expect((wc['parents'] as List<dynamic>).length, equals(2));
    });

    test('supports --at-op time travel, path-filtered sys_jj_diff, and blocks protected/out-of-scope paths', () async {
      final firstOp = readHeadOpId();

      File(p.join(repoDir.path, 'extra.txt')).writeAsStringSync('extra content\n');
      expect(runJjSync(<String>['status']).exitCode, equals(0));
      final secondOp = readHeadOpId();
      expect(secondOp, isNot(equals(firstOp)));

      final diffAtFirst = await jjDriver.diff(rev: '@', atOp: firstOp);
      expect(diffAtFirst.ok, isTrue);
      expect(diffAtFirst.value!['diff'], isNot(contains('extra content')));

      final diffFiltered = await jjDriver.diff(
        rev: '@',
        paths: <String>['/workspace/extra.txt'],
      );
      expect(diffFiltered.ok, isTrue);
      expect(diffFiltered.value!['diff'], contains('extra content'));
      expect(diffFiltered.value!['diff'], isNot(contains('modified line 2')));

      final protectedDiff = await jjDriver.diff(
        rev: '@',
        paths: <String>['/workspace/.jj/repo'],
      );
      expect(protectedDiff.ok, isFalse);
      expect(protectedDiff.error!.code, equals(SyscallErrorCode.eacces));
      expect(protectedDiff.error!.reason, equals('PROTECTED_INTERNAL_PATH'));

      final escapeDiff = await jjDriver.diff(
        rev: '@',
        paths: <String>['../outside.txt'],
      );
      expect(escapeDiff.ok, isFalse);
      expect(escapeDiff.error!.code, equals(SyscallErrorCode.eacces));
      expect(escapeDiff.error!.reason, equals('OUT_OF_WORKSPACE_SCOPE'));
    });

    test('syncWorkingCopySnapshot captures edits in TxState.active and enforces --ignore-working-copy on past rev', () async {
      final beforeOp = readHeadOpId();
      jjDriver.txContext.enterActive(
        baseOpId: beforeOp,
        parentChangeId: 'parent123456',
        workingChangeId: 'work12345678',
      );

      // Reading past rev (@-) while active still forces --ignore-working-copy.
      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('unsynced active edit\n');
      final pastDiff = await jjDriver.diff(rev: '@-');
      expect(pastDiff.ok, isTrue);
      expect(pastDiff.value!['ignoredWorkingCopy'], isTrue);
      expect(readHeadOpId(), equals(beforeOp));

      // syncWorkingCopySnapshot explicitly snapshots without --ignore-working-copy.
      final syncRes = await jjDriver.syncWorkingCopySnapshot();
      expect(syncRes.ok, isTrue);
      final afterOp = readHeadOpId();
      expect(afterOp, isNot(equals(beforeOp)));
      expect(syncRes.value!.jjOpId, equals(afterOp));
      expect(jjDriver.txContext.allowedCheckpointOpIds, contains(afterOp));
    });

    test('SyscallGate integration logs real jjOpId/jjChangeId in syscalls.jsonl without mutating op_id, and caps large diffs', () async {
      // Create a committed 25-line file so sys_jj_diff exceeds IoCapConfig(maxLines: 10).
      final bigContent = List<String>.generate(25, (i) => 'diff line ${i + 1}').join('\n');
      File(p.join(repoDir.path, 'big_diff.txt')).writeAsStringSync('$bigContent\n');
      expect(runJjSync(<String>['status']).exitCode, equals(0));

      final opBefore = readHeadOpId();
      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('dirty unsnapshotted\n');

      final processTable = KernelProcessTable();
      final pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead',
        ring: ProtectionRing.ring2,
        state: ProcessState.running,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: const ResourceQuota(maxChildProcesses: 0),
        namespace: namespace,
        jjContext: jjDriver.txContext,
        memory: VirtualContextMemory(
          sessionId: 'sess_jj',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: JjDriver.readToolSchemas(),
          ),
        ),
      );
      processTable.registerProcess(pcb);

      final auditLogger = AuditLogger(
        workspaceHostRoot: repoDir.path,
        sessionId: 'sess_jj',
      );
      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(
          config: const IoCapConfig(maxLines: 10, headLines: 5, tailLines: 3),
          workspaceHostRoot: repoDir.path,
        ),
        auditLogger: auditLogger,
        jjAuditInfoProvider: jjDriver.getAuditInfo,
      );
      jjDriver.registerReadSyscalls(gate);

      const ctx = SyscallContext(
        pid: 1,
        capHandle: CapHandle('cap_workspace_rw'),
        sessionId: 'sess_jj',
      );

      final res = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_jj_status'),
      );
      expect(res.ok, isTrue, reason: '${res.error}');

      final diffRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_jj_diff',
          args: const <String, dynamic>{
            'rev': '@',
            'paths': <String>['/workspace/big_diff.txt'],
          },
        ),
      );
      expect(diffRes.ok, isTrue, reason: '${diffRes.error}');
      expect(diffRes.value!['truncated'], isTrue);
      expect(diffRes.value!['diff'], contains('KERNEL I/O CAP'));
      expect(diffRes.value!['spillPath'], isNotNull);

      await auditLogger.flush();
      final lines = File(auditLogger.syscallsLogPath).readAsLinesSync();
      expect(lines.length, equals(2));
      for (final line in lines) {
        final record = jsonDecode(line) as Map<String, dynamic>;
        expect(record['jjOpId'], equals(opBefore));
        expect((record['jjChangeId'] as String).length, equals(12));
      }

      // Verify .agent_os/logs/ and io_spill/ did not pollute jj working copy or advance op_id.
      expect(readHeadOpId(), equals(opBefore));
    });

    test('returns structured EINVAL / ENOENT errors on invalid queries or non-jj directory', () async {
      final badOp = await jjDriver.status(atOp: 'not-hex!');
      expect(badOp.ok, isFalse);
      expect(badOp.error!.code, equals(SyscallErrorCode.einval));

      final missingRev = await jjDriver.diff(rev: 'nonexistent_rev_xyz');
      expect(missingRev.ok, isFalse);
      expect(missingRev.error!.code, equals(SyscallErrorCode.enoent));

      final nonRepoDir = Directory.systemTemp.createTempSync('wp3_non_jj_');
      try {
        final nonRepoDriver = JjDriver.forWorkspace(nonRepoDir.path);
        final res = await nonRepoDriver.status();
        expect(res.ok, isFalse);
        expect(res.error!.code, equals(SyscallErrorCode.einval));
        expect(res.error!.reason, equals('NOT_A_JJ_REPO'));
      } finally {
        nonRepoDir.deleteSync(recursive: true);
      }
    });
  });
}
