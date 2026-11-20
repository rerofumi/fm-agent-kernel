import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('JjDriver & WorkspacePageFreshnessChecker Step 3-1 ([D-307], [D-308])', () {
    late Directory tempDir;
    late String repoRoot;
    late JjDriver jjDriver;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_ws_step31_');
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

    test(
      'allocateWorkerWorkspace uses --no-colocate, independent Change ID, and cleanup preserves or abandons Change ID',
      () async {
        final alloc1 = await jjDriver.allocateWorkerWorkspace(
          pid: 2,
          description: 'worker-2',
        );
        expect(alloc1.ok, isTrue, reason: alloc1.error?.message);
        final ws1 = alloc1.value!;
        expect(ws1.workspaceName, 'ws-2');
        expect(Directory(ws1.workspaceRoot).existsSync(), isTrue);
        // --no-colocate: no .git file in child workspace, no .git/worktrees/ws-2
        expect(File(p.join(ws1.workspaceRoot, '.git')).existsSync(), isFalse);
        expect(
          Directory(p.join(repoRoot, '.git', 'worktrees', 'ws-2')).existsSync(),
          isFalse,
        );

        final alloc2 = await jjDriver.allocateWorkerWorkspace(
          pid: 3,
          description: 'worker-3',
        );
        expect(alloc2.ok, isTrue, reason: alloc2.error?.message);
        final ws2 = alloc2.value!;
        expect(ws2.workingChangeId, isNot(equals(ws1.workingChangeId)));
        expect(ws2.baseChangeId, equals(ws1.baseChangeId));

        final listRes = await jjDriver.listWorkspaces();
        expect(listRes.ok, isTrue);
        final names = listRes.value!.map((e) => e['name']).toSet();
        expect(names, containsAll(<String>['default', 'ws-2', 'ws-3']));

        // Normal cleanup preserves commit Change ID
        await File(p.join(ws1.workspaceRoot, 'a.txt')).writeAsString('from ws1\n');
        final cleanup1 = await jjDriver.cleanupWorkerWorkspace(
          workspaceName: ws1.workspaceName,
          workspaceRoot: ws1.workspaceRoot,
          workingChangeId: ws1.workingChangeId,
          baseChangeId: ws1.baseChangeId,
          abandonChange: false,
        );
        expect(cleanup1.cleanedUp, isTrue);
        expect(cleanup1.finalCommitId, isNotNull);
        expect(Directory(ws1.workspaceRoot).existsSync(), isFalse);

        final logAfter1 = await jjDriver.log(revset: ws1.workingChangeId);
        expect(logAfter1.ok, isTrue);
        expect((logAfter1.value!['commits'] as List).length, 1);

        // Failure cleanup abandons Change ID
        final cleanup2 = await jjDriver.cleanupWorkerWorkspace(
          workspaceName: ws2.workspaceName,
          workspaceRoot: ws2.workspaceRoot,
          workingChangeId: ws2.workingChangeId,
          baseChangeId: ws2.baseChangeId,
          abandonChange: true,
        );
        expect(cleanup2.cleanedUp, isTrue);
        expect(cleanup2.finalCommitId, isNull);
        expect(Directory(ws2.workspaceRoot).existsSync(), isFalse);

        final listAfter = await jjDriver.listWorkspaces();
        expect(listAfter.ok, isTrue);
        expect(
          listAfter.value!.map((e) => e['name']).toList(),
          equals(<String>['default']),
        );
      },
    );

    test(
      'high-frequency concurrent updates across 3+ workspaces keep jj op log strictly linear (parent count == 1)',
      () async {
        final workers = <AllocatedWorkspace>[];
        for (final pid in <int>[10, 11, 12]) {
          final res = await jjDriver.allocateWorkerWorkspace(
            pid: pid,
            description: 'stress-$pid',
          );
          expect(res.ok, isTrue, reason: res.error?.message);
          workers.add(res.value!);
        }

        final pcbs = workers
            .map(
              (ws) => ProcessControlBlock(
                pid: workers.indexOf(ws) + 10,
                parentPid: 1,
                name: ws.workspaceName,
                ring: ProtectionRing.ring3,
                cspace: CapabilityTable(),
                quota: const ResourceQuota(),
                namespace: VfsNamespace(workspaceHostRoot: ws.workspaceRoot),
                jjContext: JjTxContext(
                  state: TxState.active,
                  parentChangeId: ws.baseChangeId,
                  workingChangeId: ws.workingChangeId,
                ),
                memory: VirtualContextMemory(
                  sessionId: 'stress',
                  systemInstruction: PinnedSystemInstruction(
                    instruction: '',
                    tools: const <SyscallToolSchema>[],
                  ),
                ),
                profile: ProcessProfileId.workspaceWorker,
                jjWorkspaceName: ws.workspaceName,
                jjWorkspaceRoot: ws.workspaceRoot,
              ),
            )
            .toList(growable: false);

        final futures = <Future<void>>[];
        for (var round = 0; round < 10; round++) {
          for (var i = 0; i < pcbs.length; i++) {
            final pcb = pcbs[i];
            final r = round;
            futures.add(() async {
              await File(p.join(pcb.jjWorkspaceRoot!, 'f_${i}_$r.txt'))
                  .writeAsString('round $r\n');
              final syncRes = await jjDriver.syncWorkingCopySnapshotForPcb(pcb);
              expect(syncRes.ok, isTrue, reason: syncRes.error?.message);
              final statusRes = await jjDriver.status(
                forceIgnoreWorkingCopy: true,
                repositoryPath: pcb.jjWorkspaceRoot,
              );
              expect(statusRes.ok, isTrue, reason: statusRes.error?.message);
            }());
          }
        }
        await Future.wait(futures);

        for (final ws in workers) {
          final c = await jjDriver.cleanupWorkerWorkspace(
            workspaceName: ws.workspaceName,
            workspaceRoot: ws.workspaceRoot,
            workingChangeId: ws.workingChangeId,
            baseChangeId: ws.baseChangeId,
            abandonChange: false,
          );
          expect(c.cleanedUp, isTrue);
        }

        final opLogRes = await _runCmd(
          'jj',
          <String>[
            '--no-pager',
            'op',
            'log',
            '--no-graph',
            '-T',
            r'json(self.parents().len()) ++ "\n"',
          ],
          repoRoot,
        );
        final parentCounts = LineSplitter.split(opLogRes.stdout as String)
            .where((l) => l.trim().isNotEmpty)
            .map((l) => int.parse(l.trim()))
            .toList();
        expect(parentCounts, isNotEmpty);
        // Every operation except the initial root (0) must have exactly 1 parent
        expect(parentCounts.last, 0);
        for (var i = 0; i < parentCounts.length - 1; i++) {
          expect(
            parentCounts[i],
            1,
            reason: 'Op index $i had parent count ${parentCounts[i]} (op log branched!)',
          );
        }
      },
    );

    test(
      'WorkspacePageFreshnessChecker.checkFreshnessForProcess scopes file & commit freshness to child workspace',
      () async {
        final alloc = await jjDriver.allocateWorkerWorkspace(
          pid: 20,
          description: 'freshness-worker',
        );
        expect(alloc.ok, isTrue);
        final ws = alloc.value!;

        final childNs = VfsNamespace(workspaceHostRoot: ws.workspaceRoot);
        final childPcb = ProcessControlBlock(
          pid: 20,
          parentPid: 1,
          name: ws.workspaceName,
          ring: ProtectionRing.ring3,
          cspace: CapabilityTable(),
          quota: const ResourceQuota(),
          namespace: childNs,
          jjContext: JjTxContext(
            state: TxState.active,
            parentChangeId: ws.baseChangeId,
            workingChangeId: ws.workingChangeId,
          ),
          memory: VirtualContextMemory(
            sessionId: 'freshness',
            systemInstruction: PinnedSystemInstruction(
              instruction: '',
              tools: const <SyscallToolSchema>[],
            ),
          ),
          profile: ProcessProfileId.workspaceWorker,
          jjWorkspaceName: ws.workspaceName,
          jjWorkspaceRoot: ws.workspaceRoot,
        );

        final hostFs = HostFsDriver(
          namespace: VfsNamespace(workspaceHostRoot: repoRoot),
          ensureActiveTransactionForPcb: jjDriver.ensureActiveTransactionForPcb,
          syncWorkingCopySnapshotForPcb: jjDriver.syncWorkingCopySnapshotForPcb,
          currentCommitIdForPcbProvider: jjDriver.getCurrentCommitIdForPcb,
        );

        final writeRes = await hostFs.writeFile(
          path: '/workspace/child_only.txt',
          content: 'v1\n',
          createOnly: true,
          namespaceOverride: childNs,
          callerPcb: childPcb,
        );
        expect(writeRes.ok, isTrue, reason: writeRes.error?.message);
        final sha1 = writeRes.value!['newSha256'] as String;

        final checker = WorkspacePageFreshnessChecker(
          namespace: VfsNamespace(workspaceHostRoot: repoRoot),
          jjDriver: jjDriver,
        );
        final page = ContextPage(
          pageId: 'pg_0001',
          kind: PageKind.fileView,
          segmentIndex: 1,
          createdAtTurn: 1,
          lastReferencedTurn: 1,
          estimatedTokens: 10,
          dirty: false,
          cleanSource: CleanPageSourceMeta(
            syscallName: 'sys_read_lines',
            sourceKind: CleanSourceKind.workspaceFile,
            replayArgs: const <String, dynamic>{
              'path': '/workspace/child_only.txt',
            },
            virtualPath: '/workspace/child_only.txt',
            readSha256: sha1,
          ),
        );

        final fresh1 = await checker.checkFreshnessForProcess(
          <ContextPage>[page],
          pcb: childPcb,
        );
        expect(fresh1['pg_0001'], PageFreshnessStatus.fresh);

        // Mutate inside child workspace -> stale
        await File(p.join(ws.workspaceRoot, 'child_only.txt')).writeAsString('v2\n');
        final fresh2 = await checker.checkFreshnessForProcess(
          <ContextPage>[page],
          pcb: childPcb,
        );
        expect(fresh2['pg_0001'], PageFreshnessStatus.stale);

        await jjDriver.cleanupWorkerWorkspace(
          workspaceName: ws.workspaceName,
          workspaceRoot: ws.workspaceRoot,
          workingChangeId: ws.workingChangeId,
          baseChangeId: ws.baseChangeId,
          abandonChange: false,
        );
      },
    );
  });

  group('JjDriver Step 3-2 Multi-Parent Merge, Conflicts & Flatten ([D-309], [D-310])', () {
    late Directory tempDir;
    late String repoRoot;
    late JjDriver jjDriver;
    late VfsNamespace mainNamespace;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_ws_step32_');
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
      await File(p.join(repoRoot, 'calc.dart'))
          .writeAsString('int calc() => 0;\n');
      Directory(p.join(repoRoot, 'sub dir')).createSync(recursive: true);
      await File(p.join(repoRoot, 'sub dir', 'spaced file.txt'))
          .writeAsString('base line\n');
      await _runCmd('jj', <String>['commit', '-m', 'initial base'], repoRoot);
      jjDriver = JjDriver.forWorkspace(repoRoot);
      mainNamespace = VfsNamespace(workspaceHostRoot: repoRoot);
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
      'merges 3 non-overlapping worker changes, builds complete multi-parent squash preview, flattens & squashes, and supports rollback',
      () async {
        final txBeginRes = await jjDriver.txBegin(description: 'lead anchor');
        expect(txBeginRes.ok, isTrue);
        final baseOpId = jjDriver.txContext.baseOpId!;
        final anchorId = jjDriver.txContext.anchorWorkingChangeId!;

        // Spawn 3 isolated worker workspaces from anchorId
        final w1 = (await jjDriver.allocateWorkerWorkspace(pid: 2)).value!;
        final w2 = (await jjDriver.allocateWorkerWorkspace(pid: 3)).value!;
        final w3 = (await jjDriver.allocateWorkerWorkspace(pid: 4)).value!;

        await File(p.join(w1.workspaceRoot, 'mod_a.dart'))
            .writeAsString('String modA() => "A";\n');
        await File(p.join(w2.workspaceRoot, 'mod_b.dart'))
            .writeAsString('String modB() => "B";\n');
        await File(p.join(w3.workspaceRoot, 'mod_c.dart'))
            .writeAsString('String modC() => "C";\n');

        await jjDriver.cleanupWorkerWorkspace(
          workspaceName: w1.workspaceName,
          workspaceRoot: w1.workspaceRoot,
          workingChangeId: w1.workingChangeId,
          baseChangeId: w1.baseChangeId,
          abandonChange: false,
        );
        await jjDriver.cleanupWorkerWorkspace(
          workspaceName: w2.workspaceName,
          workspaceRoot: w2.workspaceRoot,
          workingChangeId: w2.workingChangeId,
          baseChangeId: w2.baseChangeId,
          abandonChange: false,
        );
        await jjDriver.cleanupWorkerWorkspace(
          workspaceName: w3.workspaceName,
          workspaceRoot: w3.workspaceRoot,
          workingChangeId: w3.workingChangeId,
          baseChangeId: w3.baseChangeId,
          abandonChange: false,
        );

        // Invalid merge args rejected without side effects
        final invalid1 = await jjDriver.mergeChanges(
          changeIds: <String>[w1.workingChangeId],
        );
        expect(invalid1.ok, isFalse);
        expect(invalid1.error!.code, SyscallErrorCode.einval);

        final invalid2 = await jjDriver.mergeChanges(
          changeIds: <String>[w1.workingChangeId, 'nonexistentrev999'],
        );
        expect(invalid2.ok, isFalse);
        expect(invalid2.error!.code, SyscallErrorCode.enoent);

        // Valid 3-parent merge
        final mergeRes = await jjDriver.mergeChanges(
          changeIds: <String>[
            w1.workingChangeId,
            w2.workingChangeId,
            w3.workingChangeId,
          ],
          message: 'merge 3 modules',
          namespaceOverride: mainNamespace,
        );
        expect(mergeRes.ok, isTrue, reason: mergeRes.error?.message);
        final mergeVal = mergeRes.value!;
        expect(mergeVal['hasConflicts'], isFalse);
        expect(mergeVal['conflictedFiles'], isEmpty);
        expect(mergeVal['anchorWorkingChangeId'], anchorId);

        // Multi-parent approval preview uses parentChangeId (user @-) and produces complete Diff blocks
        final preview = await jjDriver.buildSquashApprovalPreview(
          SyscallHookContext(
            pid: 1,
            ring: ProtectionRing.ring2,
            sessionId: 'step32_preview',
            syscallName: 'sys_tx_squash',
            args: const <String, dynamic>{},
            jjContext: jjDriver.txContext,
          ),
        );
        expect(preview, isNotNull);
        final diffPaths = preview!.content
            .where((b) => b['type'] == 'diff')
            .map((b) => b['path'] as String)
            .toList();
        expect(diffPaths.length, 3);
        expect(diffPaths.any((p) => p.endsWith('/mod_a.dart')), isTrue);
        expect(diffPaths.any((p) => p.endsWith('/mod_b.dart')), isTrue);
        expect(diffPaths.any((p) => p.endsWith('/mod_c.dart')), isTrue);

        // Direct txSquash on multi-parent merge auto-flattens and succeeds
        final squashRes = await jjDriver.txSquash(message: 'feature ABC');
        expect(squashRes.ok, isTrue, reason: squashRes.error?.message);
        expect(squashRes.value!['squashed'], isTrue);

        // All 3 files exist in parent @- after squash
        final parentFiles = await jjDriver.log(revset: '@-', limit: 1);
        expect(parentFiles.ok, isTrue);
        expect(File(p.join(repoRoot, 'mod_a.dart')).existsSync(), isTrue);
        expect(File(p.join(repoRoot, 'mod_b.dart')).existsSync(), isTrue);
        expect(File(p.join(repoRoot, 'mod_c.dart')).existsSync(), isTrue);

        // Rollback restores to baseOpId cleanly
        final rbRes = await jjDriver.txRollback(targetOpId: baseOpId);
        expect(rbRes.ok, isTrue, reason: rbRes.error?.message);
        expect(File(p.join(repoRoot, 'mod_a.dart')).existsSync(), isFalse);
      },
    );

    test(
      'non-destructive conflict detection (including spaced paths) blocks sys_tx_squash with ECONFLICT (0 ApprovalHandler calls, op_id unchanged)',
      () async {
        await jjDriver.txBegin(description: 'lead conflict test');

        final w1 = (await jjDriver.allocateWorkerWorkspace(pid: 2)).value!;
        final w2 = (await jjDriver.allocateWorkerWorkspace(pid: 3)).value!;

        await File(p.join(w1.workspaceRoot, 'calc.dart'))
            .writeAsString('int calc() => 111;\n');
        await File(p.join(w1.workspaceRoot, 'sub dir', 'spaced file.txt'))
            .writeAsString('from worker 1\n');

        await File(p.join(w2.workspaceRoot, 'calc.dart'))
            .writeAsString('int calc() => 222;\n');
        await File(p.join(w2.workspaceRoot, 'sub dir', 'spaced file.txt'))
            .writeAsString('from worker 2\n');

        await jjDriver.cleanupWorkerWorkspace(
          workspaceName: w1.workspaceName,
          workspaceRoot: w1.workspaceRoot,
          workingChangeId: w1.workingChangeId,
          baseChangeId: w1.baseChangeId,
          abandonChange: false,
        );
        await jjDriver.cleanupWorkerWorkspace(
          workspaceName: w2.workspaceName,
          workspaceRoot: w2.workspaceRoot,
          workingChangeId: w2.workingChangeId,
          baseChangeId: w2.baseChangeId,
          abandonChange: false,
        );

        final mergeRes = await jjDriver.mergeChanges(
          changeIds: <String>[w1.workingChangeId, w2.workingChangeId],
          namespaceOverride: mainNamespace,
        );
        expect(mergeRes.ok, isTrue, reason: mergeRes.error?.message);
        expect(mergeRes.value!['hasConflicts'], isTrue);
        final conflicted =
            (mergeRes.value!['conflictedFiles'] as List).cast<String>();
        expect(
          conflicted,
          containsAll(<String>[
            '/workspace/calc.dart',
            '/workspace/sub dir/spaced file.txt',
          ]),
        );

        // sys_jj_conflicts on clean rev returns hasConflicts: false, exit=0 equivalent
        final cleanConf = await jjDriver.inspectConflictsNonDestructive(
          rev: jjDriver.txContext.parentChangeId!,
          namespaceOverride: mainNamespace,
        );
        expect(cleanConf.ok, isTrue, reason: cleanConf.error?.message);
        expect(cleanConf.value!['hasConflicts'], isFalse);
        expect(cleanConf.value!['files'], isEmpty);

        // integrateIntoWorkingChange rejects with ECONFLICT while unresolved
        final intFail = await jjDriver.integrateIntoWorkingChange(
          namespaceOverride: mainNamespace,
        );
        expect(intFail.ok, isFalse);
        expect(intFail.error!.code, SyscallErrorCode.econflict);
        expect(intFail.error!.reason, 'UNRESOLVED_CONFLICTS');

        // Wire SyscallGate with counting ApprovalHandler to verify 0 calls & unchanged op_id
        var approvalCalls = 0;
        final cspace = CapabilityTable.stage3LeadAgent();
        final capHandle = cspace.entries.first.handle;
        final leadPcb = ProcessControlBlock(
          pid: 1,
          name: 'lead',
          ring: ProtectionRing.ring2,
          cspace: cspace,
          quota: const ResourceQuota(),
          namespace: mainNamespace,
          jjContext: jjDriver.txContext,
          memory: VirtualContextMemory(
            sessionId: 'step32_econflict',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'System',
              tools: const <SyscallToolSchema>[],
            ),
          ),
        );
        final processTable = KernelProcessTable()..registerProcess(leadPcb);
        final auditLogger = AuditLogger(
          workspaceHostRoot: repoRoot,
          sessionId: 'step32_econflict',
        );
        final gate = SyscallGate(
          processTable: processTable,
          approvalGate: ApprovalGate(
            handler: PolicyApprovalHandler((_, _) async {
              approvalCalls += 1;
              return const ApprovalDecision.allowOnce();
            }),
          ),
          ioCapper: IoPayloadCapper(workspaceHostRoot: repoRoot),
          auditLogger: auditLogger,
        );
        jjDriver.registerAllSyscalls(gate);

        final opBefore = (await jjDriver.getAuditInfo()).jjOpId;
        final squashBlocked = await gate.invoke(
          SyscallContext(
            sessionId: 'step32_econflict',
            pid: 1,
            capHandle: capHandle,
          ),
          SyscallRequest(
            name: 'sys_tx_squash',
            args: const <String, dynamic>{'message': 'should be blocked'},
          ),
        );
        final opAfter = (await jjDriver.getAuditInfo()).jjOpId;

        expect(squashBlocked.ok, isFalse);
        expect(squashBlocked.error!.code, SyscallErrorCode.econflict);
        expect(squashBlocked.error!.reason, 'UNRESOLVED_CONFLICTS');
        expect(approvalCalls, 0);
        expect(opAfter, equals(opBefore));

        // Resolve both conflicted files cleanly
        await File(p.join(repoRoot, 'calc.dart'))
            .writeAsString('int calc() => 333;\n');
        await File(p.join(repoRoot, 'sub dir', 'spaced file.txt'))
            .writeAsString('resolved 1 + 2\n');
        await jjDriver.syncWorkingCopySnapshot();

        final resolvedConf = await jjDriver.inspectConflictsNonDestructive(
          rev: '@',
          namespaceOverride: mainNamespace,
        );
        expect(resolvedConf.ok, isTrue);
        expect(resolvedConf.value!['hasConflicts'], isFalse);
        expect(resolvedConf.value!['files'], isEmpty);

        // Now sys_jj_integrate succeeds & sys_tx_squash proceeds with approval
        final intOk = await jjDriver.integrateIntoWorkingChange(
          namespaceOverride: mainNamespace,
        );
        expect(intOk.ok, isTrue, reason: intOk.error?.message);

        final squashOk = await gate.invoke(
          SyscallContext(
            sessionId: 'step32_econflict',
            pid: 1,
            capHandle: capHandle,
          ),
          SyscallRequest(
            name: 'sys_tx_squash',
            args: const <String, dynamic>{'message': 'resolved merge'},
          ),
        );
        expect(squashOk.ok, isTrue, reason: squashOk.error?.message);
        expect(approvalCalls, 1);
      },
    );

    test(
      'sys_mem_pagein replays Clean Page for sys_jj_conflicts',
      () async {
        final confRes = await jjDriver.inspectConflictsNonDestructive(
          rev: '@',
          namespaceOverride: mainNamespace,
        );
        expect(confRes.ok, isTrue);
        final commitId = confRes.value!['commitId'] as String;

        final hostFs = HostFsDriver(namespace: mainNamespace);
        final pageinDef = buildMemPageinSyscallDefinition(
          hostFsDriver: hostFs,
          jjDriver: jjDriver,
          freshnessChecker: WorkspacePageFreshnessChecker(
            namespace: mainNamespace,
            jjDriver: jjDriver,
          ),
        );
        final cspace = CapabilityTable.stage3LeadAgent();
        final pcb = ProcessControlBlock(
          pid: 1,
          name: 'lead',
          ring: ProtectionRing.ring2,
          cspace: cspace,
          quota: const ResourceQuota(),
          namespace: mainNamespace,
          memory: VirtualContextMemory(
            sessionId: 'pagein_conflicts',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'System',
              tools: const <SyscallToolSchema>[],
            ),
          ),
        );
        final page = pcb.memory.appendToolResultTurn(
          CanonicalToolResultTurn(
            canonicalCallId: 'tc_conf_1',
            toolName: 'sys_jj_conflicts',
            content: jsonEncode(confRes.value!),
          ),
          cleanSource: CleanPageSourceMeta(
            syscallName: 'sys_jj_conflicts',
            sourceKind: CleanSourceKind.vcsSnapshot,
            replayArgs: const <String, dynamic>{'rev': '@'},
            readCommitId: commitId,
            readOpId: confRes.value!['opId'] as String?,
          ),
        );

        final res = await pageinDef.handler(
          SyscallExecutionContext(
            context: SyscallContext(
              sessionId: 'pagein_conflicts',
              pid: 1,
              capHandle: cspace.entries.first.handle,
            ),
            pcb: pcb,
            syscallName: 'sys_mem_pagein',
            syscallSeq: 1,
            args: <String, dynamic>{'pageId': page.pageId},
          ),
        );
        expect(res.ok, isTrue, reason: res.error?.message);
        expect(res.value!['source'], 'clean_vcs');
        expect(res.value!['hasConflicts'], isFalse);
      },
    );
  });

  group('JjDriver Step 3-3 Stacked Changes & update-stale cascade ([D-311])', () {
    late Directory tempDir;
    late String repoRoot;
    late JjDriver jjDriver;
    late StackedTaskRegistry registry;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_ws_stacked_');
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
      await File(p.join(repoRoot, 'base.txt')).writeAsString('v1\n');
      await _runCmd('jj', <String>['commit', '-m', 'initial'], repoRoot);
      registry = StackedTaskRegistry();
      jjDriver = JjDriver.forWorkspace(
        repoRoot,
        stackedTaskRegistry: registry,
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
      '3-tier stack (c_A -> c_B -> c_C) cascades update-stale on c_A edit with 0 divergent and linear op log',
      () async {
        final wsARes = await jjDriver.allocateTaskWorkspace(taskId: 'task_a');
        expect(wsARes.ok, isTrue, reason: wsARes.error?.message);
        final wsA = wsARes.value!;
        final nodeA = StackedTaskNode(
          taskId: 'task_a',
          title: 'Task A',
          baseChangeId: wsA.baseChangeId,
          workingChangeId: wsA.workingChangeId,
          commitId: wsA.commitId,
          workspaceName: wsA.workspaceName,
          workspaceRoot: wsA.workspaceRoot,
        );
        expect(registry.register(nodeA).ok, isTrue);

        await File(p.join(wsA.workspaceRoot, 'a.txt')).writeAsString('A1\n');
        await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: nodeA,
          descendants: const <StackedTaskNode>[],
        );

        final wsBRes = await jjDriver.allocateTaskWorkspace(
          taskId: 'task_b',
          baseChangeId: nodeA.workingChangeId,
        );
        expect(wsBRes.ok, isTrue, reason: wsBRes.error?.message);
        final wsB = wsBRes.value!;
        final nodeB = StackedTaskNode(
          taskId: 'task_b',
          title: 'Task B',
          parentTaskId: 'task_a',
          baseChangeId: wsB.baseChangeId,
          workingChangeId: wsB.workingChangeId,
          commitId: wsB.commitId,
          workspaceName: wsB.workspaceName,
          workspaceRoot: wsB.workspaceRoot,
        );
        expect(registry.register(nodeB).ok, isTrue);

        await File(p.join(wsB.workspaceRoot, 'b.txt')).writeAsString('B1\n');
        await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: nodeB,
          descendants: const <StackedTaskNode>[],
        );

        final wsCRes = await jjDriver.allocateTaskWorkspace(
          taskId: 'task_c',
          baseChangeId: nodeB.workingChangeId,
        );
        expect(wsCRes.ok, isTrue, reason: wsCRes.error?.message);
        final wsC = wsCRes.value!;
        final nodeC = StackedTaskNode(
          taskId: 'task_c',
          title: 'Task C',
          parentTaskId: 'task_b',
          baseChangeId: wsC.baseChangeId,
          workingChangeId: wsC.workingChangeId,
          commitId: wsC.commitId,
          workspaceName: wsC.workspaceName,
          workspaceRoot: wsC.workspaceRoot,
        );
        expect(registry.register(nodeC).ok, isTrue);

        await File(p.join(wsC.workspaceRoot, 'c.txt')).writeAsString('C1\n');
        await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: nodeC,
          descendants: const <StackedTaskNode>[],
        );

        final prevCommitB = nodeB.commitId;
        final prevCommitC = nodeC.commitId;

        // Modify Task A and cascade update-stale to B and C.
        await File(p.join(wsA.workspaceRoot, 'a.txt')).writeAsString('A2_updated\n');
        final cascadeRes = await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: nodeA,
          descendants: registry.descendantsInTopologicalOrder('task_a'),
        );
        expect(cascadeRes.ok, isTrue, reason: cascadeRes.error?.message);
        expect(cascadeRes.value!.cascaded.length, 2);
        expect(
          cascadeRes.value!.cascaded.map((e) => e.taskId).toList(),
          equals(<String>['task_b', 'task_c']),
        );

        // Both ws_B and ws_C received A2_updated while preserving b.txt and c.txt.
        expect(await File(p.join(wsB.workspaceRoot, 'a.txt')).readAsString(), 'A2_updated\n');
        expect(await File(p.join(wsB.workspaceRoot, 'b.txt')).readAsString(), 'B1\n');
        expect(await File(p.join(wsC.workspaceRoot, 'a.txt')).readAsString(), 'A2_updated\n');
        expect(await File(p.join(wsC.workspaceRoot, 'c.txt')).readAsString(), 'C1\n');
        expect(nodeB.commitId, isNot(equals(prevCommitB)));
        expect(nodeC.commitId, isNot(equals(prevCommitC)));
        expect(nodeB.hasConflicts, isFalse);
        expect(nodeC.hasConflicts, isFalse);

        // Verify 0 divergent changes and linear jj op log.
        final divRes = await _runCmd(
          'jj',
          <String>['--no-pager', 'log', '--no-graph', '-r', 'divergent()', '-T', 'change_id'],
          repoRoot,
        );
        expect((divRes.stdout as String).trim(), isEmpty);

        final opLogRes = await _runCmd(
          'jj',
          <String>['--no-pager', 'op', 'log', '--no-graph', '-T', r'json(self.parents().len()) ++ "\n"'],
          repoRoot,
        );
        final parentCounts = LineSplitter.split(opLogRes.stdout as String)
            .where((l) => l.trim().isNotEmpty)
            .map((l) => jsonDecode(l) as int)
            .toList();
        expect(parentCounts.take(parentCounts.length - 1), everyElement(1));
      },
    );

    test(
      'conflicting edit on parent task transitions descendant to StackedTaskState.conflict without halting',
      () async {
        final wsARes = await jjDriver.allocateTaskWorkspace(taskId: 'parent_a');
        final wsA = wsARes.value!;
        final nodeA = StackedTaskNode(
          taskId: 'parent_a',
          title: 'Parent A',
          baseChangeId: wsA.baseChangeId,
          workingChangeId: wsA.workingChangeId,
          commitId: wsA.commitId,
          workspaceName: wsA.workspaceName,
          workspaceRoot: wsA.workspaceRoot,
        );
        registry.register(nodeA);
        await File(p.join(wsA.workspaceRoot, 'shared.txt')).writeAsString('line1\n');
        await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: nodeA,
          descendants: const <StackedTaskNode>[],
        );

        final wsBRes = await jjDriver.allocateTaskWorkspace(
          taskId: 'child_b',
          baseChangeId: nodeA.workingChangeId,
        );
        final wsB = wsBRes.value!;
        final nodeB = StackedTaskNode(
          taskId: 'child_b',
          title: 'Child B',
          parentTaskId: 'parent_a',
          baseChangeId: wsB.baseChangeId,
          workingChangeId: wsB.workingChangeId,
          commitId: wsB.commitId,
          workspaceName: wsB.workspaceName,
          workspaceRoot: wsB.workspaceRoot,
        );
        registry.register(nodeB);
        await File(p.join(wsB.workspaceRoot, 'shared.txt')).writeAsString('from_B\n');
        await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: nodeB,
          descendants: const <StackedTaskNode>[],
        );

        // Now modify the same line in Parent A.
        await File(p.join(wsA.workspaceRoot, 'shared.txt')).writeAsString('from_A\n');
        final cascadeRes = await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: nodeA,
          descendants: registry.descendantsInTopologicalOrder('parent_a'),
        );
        expect(cascadeRes.ok, isTrue, reason: cascadeRes.error?.message);
        expect(nodeB.hasConflicts, isTrue);
        expect(nodeB.state, StackedTaskState.conflict);
        expect(nodeB.conflictedFiles, contains('/workspace/shared.txt'));

        // Conflict markers are materialized in ws_B; resolving them clears conflict state.
        final contentB =
            await File(p.join(wsB.workspaceRoot, 'shared.txt')).readAsString();
        expect(contentB, contains('<<<<<<<'));
        await File(p.join(wsB.workspaceRoot, 'shared.txt'))
            .writeAsString('from_A_and_B\n');
        final resolveRes = await jjDriver.syncTaskWorkspaceAndCascade(
          taskNode: nodeB,
          descendants: const <StackedTaskNode>[],
        );
        expect(resolveRes.ok, isTrue);
        expect(nodeB.hasConflicts, isFalse);
        expect(nodeB.state, StackedTaskState.todo);
      },
    );
  });
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
    throw StateError('$exe ${args.join(' ')} failed (${res.exitCode}): ${res.stderr}');
  }
  return res;
}
