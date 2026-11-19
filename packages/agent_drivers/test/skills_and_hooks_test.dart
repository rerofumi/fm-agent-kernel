import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/fs_jj_drivers.dart';
import 'package:agent_drivers/llm_drivers.dart';
import 'package:agent_drivers/skill_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SkillDirectoryLoader & /skills dynamic mounting [D-203], [D-204], [D-219]', () {
    late Directory tempRoot;
    late Directory workspaceDir;
    late Directory cliDir1;
    late Directory cliDir2;
    late Directory envDir1;
    late Directory envDir2;
    late Directory repoSkillsDir;
    late Directory outsideDir;

    void writeSkill(
      Directory parentRoot,
      String dirName,
      String content,
    ) {
      final skillDir = Directory(p.join(parentRoot.path, dirName))
        ..createSync(recursive: true);
      File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync(content);
    }

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('fm_wp7_skills_');
      workspaceDir = Directory(p.join(tempRoot.path, 'workspace'))
        ..createSync(recursive: true);
      cliDir1 = Directory(p.join(tempRoot.path, 'cli_skills_1'))
        ..createSync(recursive: true);
      cliDir2 = Directory(p.join(tempRoot.path, 'cli_skills_2'))
        ..createSync(recursive: true);
      envDir1 = Directory(p.join(tempRoot.path, 'env_skills_1'))
        ..createSync(recursive: true);
      envDir2 = Directory(p.join(tempRoot.path, 'env_skills_2'))
        ..createSync(recursive: true);
      repoSkillsDir =
          Directory(p.join(workspaceDir.path, '.agent_os', 'skills'))
            ..createSync(recursive: true);
      outsideDir = Directory(p.join(tempRoot.path, 'outside_secret'))
        ..createSync(recursive: true);
      File(p.join(outsideDir.path, 'SKILL.md'))
          .writeAsStringSync('---\nname: escaped\n---\n# SECRET\n');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('enforces First-Win priority: --skills-dir (order) > AGENT_OS_SKILLS_DIR > .agent_os/skills', () {
      writeSkill(
        cliDir1,
        'shared-skill',
        '---\nname: shared-skill\ndescription: From CLI 1\n---\n# CLI 1\n',
      );
      writeSkill(
        cliDir2,
        'shared-skill',
        '---\nname: Shared-Skill\ndescription: From CLI 2 (shadowed)\n---\n# CLI 2\n',
      );
      writeSkill(
        cliDir2,
        'cli2-only',
        '---\nname: cli2-only\ndescription: From CLI 2\n---\n# CLI 2 Only\n',
      );
      writeSkill(
        envDir1,
        'env-vs-repo',
        '---\nname: env-vs-repo\ndescription: From ENV 1\n---\n# ENV 1\n',
      );
      writeSkill(
        envDir2,
        'env-vs-repo',
        '---\nname: env-vs-repo\ndescription: From ENV 2 (shadowed)\n---\n# ENV 2\n',
      );
      writeSkill(
        envDir2,
        'env2-only',
        '---\nname: env2-only\ndescription: From ENV 2\n---\n# ENV 2 Only\n',
      );
      writeSkill(
        repoSkillsDir,
        'shared-skill',
        '---\nname: shared-skill\ndescription: From Repo (shadowed)\n---\n# Repo\n',
      );
      writeSkill(
        repoSkillsDir,
        'env-vs-repo',
        '---\nname: env-vs-repo\ndescription: From Repo (shadowed)\n---\n# Repo\n',
      );
      writeSkill(
        repoSkillsDir,
        'repo-only',
        '---\nname: repo-only\ndescription: From Repo\n---\n# Repo Only\n',
      );

      final warnings = <String>[];
      final loader = SkillDirectoryLoader(onWarning: warnings.add);
      final sep = Platform.isWindows ? ';' : ':';
      final registry = loader.load(
        cliSkillsDirs: <String>[cliDir1.path, cliDir2.path],
        envSkillsDir: '${envDir1.path}$sep$sep"${envDir2.path}"',
        workspaceHostRoot: workspaceDir.path,
      );

      expect(registry.length, equals(5));
      expect(registry.lookup('shared-skill')?.description, equals('From CLI 1'));
      expect(registry.lookup('SHARED-SKILL')?.description, equals('From CLI 1'));
      expect(registry.lookup('cli2-only')?.description, equals('From CLI 2'));
      expect(registry.lookup('env-vs-repo')?.description, equals('From ENV 1'));
      expect(registry.lookup('env2-only')?.description, equals('From ENV 2'));
      expect(registry.lookup('repo-only')?.description, equals('From Repo'));

      // Lower-priority duplicates must be recorded as DUPLICATE_SHADOWED skips.
      final shadowedSkips = registry.skipped
          .where((s) => s.reason == 'DUPLICATE_SHADOWED')
          .toList();
      expect(shadowedSkips.length, equals(4));
      expect(warnings, isNotEmpty);

      // Verify YamlMap/YamlList values were unwrapped to plain JSON-encodable structures.
      for (final manifest in registry.allSkills) {
        expect(() => jsonEncode(manifest.metadata), returnsNormally);
      }
    });

    test('supports omitted required_capabilities & frontmatter-less SKILL.md for LeadAgent/Explorer while denying sterile WebResearcher', () async {
      writeSkill(
        cliDir1,
        'std-skill',
        '---\nname: std-skill\ndescription: Standard skill without required_capabilities\ntags:\n  - workflow\n  - docs\n---\n# Standard Skill\nUse clean steps.\n',
      );
      writeSkill(
        cliDir1,
        'plain-markdown-skill',
        '# Plain Skill Without Frontmatter\nHello from plain markdown.\n',
      );

      final loader = SkillDirectoryLoader(onWarning: (_) {});
      final registry = loader.load(cliSkillsDirs: <String>[cliDir1.path]);
      expect(registry.length, equals(2));
      expect(registry.lookup('std-skill')!.requiredCapabilities, isEmpty);
      expect(
        registry.lookup('plain-markdown-skill')!.requiredCapabilities,
        isEmpty,
      );
      // Confirm nested YAML list was unwrapped to plain List<dynamic>.
      expect(registry.lookup('std-skill')!.metadata['tags'], isA<List<dynamic>>());
      expect(() => jsonEncode(registry.lookup('std-skill')!.metadata), returnsNormally);

      final harness = _TestKernelHarness.create(
        workspaceHostRoot: workspaceDir.path,
        skillsMount: registry,
      );

      // 1. LeadAgent (pid=1) can list, sys_skill_read, and sys_read_lines("/skills/...").
      final leadList = await harness.invokeAsLead('sys_skill_list', const <String, dynamic>{});
      expect(leadList.ok, isTrue);
      final leadNames = (leadList.value!['skills'] as List<dynamic>)
          .map((e) => (e as Map<String, dynamic>)['name'])
          .toSet();
      expect(leadNames, equals(<String>{'std-skill', 'plain-markdown-skill'}));

      final leadRead = await harness.invokeAsLead('sys_skill_read', const <String, dynamic>{
        'name': 'std-skill',
      });
      expect(leadRead.ok, isTrue);
      expect(leadRead.value!['content'], contains('Use clean steps.'));
      expect((leadRead.value!['sha256'] as String).length, equals(64));

      final leadFsRead = await harness.invokeAsLead('sys_read_lines', const <String, dynamic>{
        'path': '/skills/plain-markdown-skill/SKILL.md',
      });
      expect(leadFsRead.ok, isTrue);
      expect(leadFsRead.value!['content'], contains('Hello from plain markdown.'));

      // 2. Explorer (Ring 3, read + vcsRead + /skills mounted) can also access omitted-cap skills.
      final explorerPid = harness.spawnExplorer();
      final expList = await harness.invokeAs(explorerPid, 'sys_skill_list', const <String, dynamic>{});
      expect(expList.ok, isTrue);
      expect(expList.value!['totalCount'], equals(2));

      final expRead = await harness.invokeAs(explorerPid, 'sys_skill_read', const <String, dynamic>{
        'name': 'std-skill',
      });
      expect(expRead.ok, isTrue);
      expect(expRead.value!['content'], contains('Use clean steps.'));

      // 3. Sterile WebResearcher (Ring 3, no CapRight.read, VfsNamespace.empty()) cannot access any skill.
      final webPid = harness.spawnWebResearcher();
      final webList = await harness.invokeAs(webPid, 'sys_skill_list', const <String, dynamic>{});
      expect(webList.ok, isFalse);
      expect(webList.error!.code, equals(SyscallErrorCode.eperm));

      final webRead = await harness.invokeAs(webPid, 'sys_skill_read', const <String, dynamic>{
        'name': 'std-skill',
      });
      expect(webRead.ok, isFalse);
      expect(webRead.error!.code, equals(SyscallErrorCode.eperm));

      final webFsRead = await harness.invokeAs(webPid, 'sys_read_lines', const <String, dynamic>{
        'path': '/skills/std-skill/SKILL.md',
      });
      expect(webFsRead.ok, isFalse);
      expect(webFsRead.error!.code, equals(SyscallErrorCode.eperm));

      // Even if a process had CapRight.read but /skills is NOT mounted (VfsNamespace.empty),
      // SkillRegistry denies with EACCES: SKILLS_NOT_MOUNTED.
      final readOnlyNoSkillsPid = harness.spawnCustom(
        name: 'no_skills_reader',
        cspace: CapabilityTable(
          initialEntries: <CapabilityEntry>[
            CapabilityEntry(
              handle: const CapHandle('cap_read_only'),
              rights: <CapRight>{CapRight.read},
              resourceScope: '/workspace',
            ),
          ],
        ),
        namespace: const VfsNamespace.empty(),
      );
      final noSkillsList = await harness.invokeAs(
        readOnlyNoSkillsPid,
        'sys_skill_list',
        const <String, dynamic>{},
      );
      expect(noSkillsList.ok, isFalse);
      expect(noSkillsList.error!.code, equals(SyscallErrorCode.eacces));
      expect(noSkillsList.error!.reason, equals('SKILLS_NOT_MOUNTED'));
    });

    test('hides privileged skills from Explorer, rejects direct reads with EPERM, and guarantees zero CSpace escalation', () async {
      writeSkill(
        cliDir1,
        'public-guide',
        '---\nname: public-guide\ndescription: Read-only guide\nrequired_capabilities:\n  - read\n  - vcsRead\n---\n# Public Guide\n',
      );
      writeSkill(
        cliDir1,
        'exec-deploy',
        '---\nname: exec-deploy\ndescription: Requires exec\nrequired_capabilities:\n  - read\n  - exec\n---\n# Exec Deploy\n',
      );
      writeSkill(
        cliDir1,
        'write-refactor',
        '---\nname: write-refactor\ndescription: Requires writeCow\nrequired_capabilities:\n  - writeCow\n---\n# Write Refactor\n',
      );

      final registry = SkillDirectoryLoader(onWarning: (_) {})
          .load(cliSkillsDirs: <String>[cliDir1.path]);
      expect(registry.length, equals(3));

      final harness = _TestKernelHarness.create(
        workspaceHostRoot: workspaceDir.path,
        skillsMount: registry,
      );

      // LeadAgent has read, writeCow, exec, vcsRead -> sees all 3 skills.
      final leadBeforeRights = Set<CapRight>.from(harness.leadPcb.cspace.allRights);
      final leadList = await harness.invokeAsLead('sys_skill_list', const <String, dynamic>{});
      expect(leadList.ok, isTrue);
      expect(leadList.value!['totalCount'], equals(3));
      expect(harness.leadPcb.cspace.allRights, equals(leadBeforeRights));

      // Explorer has only {read, vcsRead, llmInfer, ipc, procSelf, memManage}.
      final explorerPid = harness.spawnExplorer();
      final explorerPcb = harness.processTable.getProcess(explorerPid)!;
      final explorerBeforeRights = Set<CapRight>.from(explorerPcb.cspace.allRights);

      final expList = await harness.invokeAs(explorerPid, 'sys_skill_list', const <String, dynamic>{});
      expect(expList.ok, isTrue);
      final expNames = (expList.value!['skills'] as List<dynamic>)
          .map((e) => (e as Map<String, dynamic>)['name'])
          .toList();
      expect(expNames, equals(<String>['public-guide']));

      // Direct sys_skill_read of exec-deploy -> EPERM: SKILL_CAPABILITY_DENIED.
      final expReadExec = await harness.invokeAs(explorerPid, 'sys_skill_read', const <String, dynamic>{
        'name': 'exec-deploy',
      });
      expect(expReadExec.ok, isFalse);
      expect(expReadExec.error!.code, equals(SyscallErrorCode.eperm));
      expect(expReadExec.error!.reason, equals('SKILL_CAPABILITY_DENIED'));

      // Direct sys_read_lines("/skills/write-refactor/SKILL.md") -> EPERM: SKILL_CAPABILITY_DENIED.
      final expFsReadWrite = await harness.invokeAs(explorerPid, 'sys_read_lines', const <String, dynamic>{
        'path': '/skills/write-refactor/SKILL.md',
      });
      expect(expFsReadWrite.ok, isFalse);
      expect(expFsReadWrite.error!.code, equals(SyscallErrorCode.eperm));
      expect(expFsReadWrite.error!.reason, equals('SKILL_CAPABILITY_DENIED'));

      // Reading allowed public-guide via sys_read_lines succeeds.
      final expReadPublic = await harness.invokeAs(explorerPid, 'sys_read_lines', const <String, dynamic>{
        'path': '/skills/public-guide/SKILL.md',
      });
      expect(expReadPublic.ok, isTrue);
      expect(expReadPublic.value!['content'], contains('# Public Guide'));

      // Zero CSpace escalation: Explorer rights remain strictly unchanged.
      expect(explorerPcb.cspace.allRights, equals(explorerBeforeRights));
      expect(explorerPcb.cspace.allRights.contains(CapRight.exec), isFalse);
      expect(explorerPcb.cspace.allRights.contains(CapRight.writeCow), isFalse);
    });

    test('rejects writes to /skills via sys_write_file and sys_edit_block with EACCES: READ_ONLY_SKILL_MOUNT', () async {
      const originalContent = '---\nname: immutable-skill\n---\n# Original Skill\n';
      writeSkill(cliDir1, 'immutable-skill', originalContent);

      final registry = SkillDirectoryLoader(onWarning: (_) {})
          .load(cliSkillsDirs: <String>[cliDir1.path]);
      final harness = _TestKernelHarness.create(
        workspaceHostRoot: workspaceDir.path,
        skillsMount: registry,
      );

      final originalSha = sha256.convert(utf8.encode(originalContent)).toString();

      final writeRes = await harness.invokeAsLead('sys_write_file', const <String, dynamic>{
        'path': '/skills/immutable-skill/SKILL.md',
        'content': '# Hacked',
      });
      expect(writeRes.ok, isFalse);
      expect(writeRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(writeRes.error!.reason, equals('READ_ONLY_SKILL_MOUNT'));

      final editRes = await harness.invokeAsLead('sys_edit_block', <String, dynamic>{
        'path': '/skills/immutable-skill/SKILL.md',
        'expectedSha256': originalSha,
        'oldBlock': '# Original Skill',
        'newBlock': '# Modified Skill',
      });
      expect(editRes.ok, isFalse);
      expect(editRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(editRes.error!.reason, equals('READ_ONLY_SKILL_MOUNT'));

      // Verify on-disk file is completely unchanged.
      final onDisk =
          File(p.join(cliDir1.path, 'immutable-skill', 'SKILL.md')).readAsStringSync();
      expect(onDisk, equals(originalContent));
    });

    test('safely skips broken YAML, path traversal names, unknown capabilities, binary files, and symlink escapes', () async {
      // 1. Valid control skill (loader must continue and mount this one).
      writeSkill(
        cliDir1,
        'valid-skill',
        '---\nname: valid-skill\ndescription: Good skill\nrequired_capabilities:\n  - net:public_readonly\n---\n# Good\n',
      );
      // 2. Broken YAML syntax.
      writeSkill(
        cliDir1,
        'broken-yaml',
        '---\nname: [unclosed\n---\n# Broken\n',
      );
      // 3. Unterminated YAML frontmatter.
      writeSkill(
        cliDir1,
        'unterminated-yaml',
        '---\nname: unterminated\n# No closing fence\n',
      );
      // 4. Path traversal name `../escape`.
      writeSkill(
        cliDir1,
        'traversal-name',
        '---\nname: ../escape\n---\n# Escape\n',
      );
      // 5. Slash in name `a/b`.
      writeSkill(
        cliDir1,
        'slash-name',
        '---\nname: a/b\n---\n# Slash\n',
      );
      // 6. Unknown capability (fail-closed).
      writeSkill(
        cliDir1,
        'unknown-cap',
        '---\nname: unknown-cap\nrequired_capabilities:\n  - read\n  - rootAdminSuperPower\n---\n# Unknown\n',
      );
      // 7. Binary SKILL.md (NUL byte).
      final binDir = Directory(p.join(cliDir1.path, 'binary-skill'))
        ..createSync(recursive: true);
      File(p.join(binDir.path, 'SKILL.md'))
          .writeAsBytesSync(<int>[0x23, 0x20, 0x00, 0x42, 0x49, 0x4E]);

      // 8. Out-of-root directory link (junction on Windows, symlink on POSIX).
      final escapedLinkPath = p.join(cliDir1.path, 'symlink-escape');
      final linkCreated = _createDirectoryLink(
        linkPath: escapedLinkPath,
        targetPath: outsideDir.path,
      );

      final warnings = <String>[];
      final registry = SkillDirectoryLoader(onWarning: warnings.add)
          .load(cliSkillsDirs: <String>[cliDir1.path]);

      // Only valid-skill is mounted (and alias net:public_readonly -> CapRight.netRead).
      expect(registry.length, equals(1));
      final valid = registry.lookup('valid-skill');
      expect(valid, isNotNull);
      expect(valid!.requiredCapabilities, equals(<CapRight>{CapRight.netRead}));

      final reasons = registry.skipped.map((s) => s.reason).toSet();
      expect(reasons, contains('INVALID_YAML_FRONTMATTER'));
      expect(reasons, contains('INVALID_SKILL_NAME'));
      expect(reasons, contains('UNKNOWN_CAPABILITY'));
      expect(reasons, contains('BINARY_FILE'));
      if (linkCreated) {
        expect(reasons, contains('SYMLINK_OUT_OF_ROOT'));
      }
      expect(warnings, isNotEmpty);

      // [D-204] §3.2(2): Read-time check when host SKILL.md is deleted after mount -> ENOENT.
      writeSkill(cliDir2, 'vanishing-skill', '---\nname: vanishing-skill\n---\n# Temp\n');
      final registry2 = SkillDirectoryLoader(onWarning: (_) {})
          .load(cliSkillsDirs: <String>[cliDir2.path]);
      final harness = _TestKernelHarness.create(
        workspaceHostRoot: workspaceDir.path,
        skillsMount: registry2,
      );

      File(p.join(cliDir2.path, 'vanishing-skill', 'SKILL.md')).deleteSync();
      final missingRes = await harness.invokeAsLead('sys_skill_read', const <String, dynamic>{
        'name': 'vanishing-skill',
      });
      expect(missingRes.ok, isFalse);
      expect(missingRes.error!.code, equals(SyscallErrorCode.enoent));
    });
  });

  group('Expanded 5-Point Pre/Post Hook Pipeline with Drivers [D-202], [D-203], [D-220]', () {
    late Directory tempRoot;
    late Directory workspaceDir;
    late Directory skillsDir;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('fm_wp7_hooks_');
      workspaceDir = Directory(p.join(tempRoot.path, 'workspace'))
        ..createSync(recursive: true);
      skillsDir = Directory(p.join(tempRoot.path, 'skills'))
        ..createSync(recursive: true);
      final sDir = Directory(p.join(skillsDir.path, 'hook-skill'))
        ..createSync(recursive: true);
      File(p.join(sDir.path, 'SKILL.md')).writeAsStringSync(
        '---\nname: hook-skill\ndescription: Skill for hook tests\n---\n# Hook Skill Body\n',
      );
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('covers beforeSyscall (FIFO/modify/block), onTxSquash (0 approvals), and afterSyscall (transform + Capper + Redactor)', () async {
      final registry = SkillDirectoryLoader(onWarning: (_) {})
          .load(cliSkillsDirs: <String>[skillsDir.path]);

      final trace = <String>[];
      const secretValue = 'sk-test-secret-token-9876543210';

      final hook1 = _RecordingSyscallHook(
        name: 'hook_1',
        onBefore: (ctx) async {
          trace.add('before:hook_1:${ctx.syscallName}');
          if (ctx.syscallName == 'sys_skill_read' &&
              ctx.args['name'] == 'blocked-by-hook') {
            return const HookBlock(
              reason: 'POLICY_DENIED',
              message: 'Blocked by hook_1',
            );
          }
          if (ctx.syscallName == 'sys_skill_read' &&
              ctx.args['name'] == 'alias-skill') {
            return HookModifyArgs(const <String, dynamic>{'name': 'hook-skill'});
          }
          return const HookAllow();
        },
        onTransformAfter: (ctx, res) async {
          trace.add('transform:hook_1:${ctx.syscallName}');
          if (ctx.syscallName == 'sys_skill_read' && res.ok) {
            final updated = Map<String, dynamic>.from(res.value!);
            // Inject both many lines (Stage 7 IoPayloadCapper) and a secret (Stage 8 SecretRedactor).
            final extraLines = List<String>.generate(
              20,
              (i) => 'extra_line_$i SECRET=$secretValue',
            ).join('\n');
            updated['content'] = '${updated['content']}\n$extraLines';
            return HookAfterReplace(updated);
          }
          return const HookAfterKeep();
        },
        onAfter: (ctx, res) async {
          trace.add('after:hook_1:${ctx.syscallName}:${res.ok}');
        },
      );

      final hook2 = _RecordingSyscallHook(
        name: 'hook_2',
        onBefore: (ctx) async {
          trace.add('before:hook_2:${ctx.syscallName}');
          return const HookAllow();
        },
        onAfter: (ctx, res) async {
          trace.add('after:hook_2:${ctx.syscallName}:${res.ok}');
        },
      );

      final txHook = _RecordingTxHook(
        name: 'tx_guard',
        onSquash: (ctx) async {
          trace.add('onTxSquash:tx_guard');
          if (ctx.args['message'] == 'bad commit') {
            return const HookBlock(
              reason: 'COMMIT_CONVENTION',
              message: 'Commit message violates convention.',
            );
          }
          return const HookAllow();
        },
      );

      final approvalHandler = PolicyApprovalHandler.alwaysAllow();
      final harness = _TestKernelHarness.create(
        workspaceHostRoot: workspaceDir.path,
        skillsMount: registry,
        hooks: <SyscallHook>[hook1, hook2],
        txHooks: <TxHook>[txHook],
        approvalHandler: approvalHandler,
        ioCapConfig: const IoCapConfig(maxLines: 5, maxUtf8Bytes: 256),
      );
      harness.redactor.registerSecret(secretValue);

      // Register a synthetic sys_tx_squash requiring Ring 2 approval.
      harness.gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_tx_squash',
          requiredRight: CapRight.vcsTx,
          kind: 'tx',
          applyIoCap: false,
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{'squashed': true},
          ),
        ),
      );

      // 1. beforeSyscall HookBlock short-circuits hook_2 and driver.
      final blocked = await harness.invokeAsLead('sys_skill_read', const <String, dynamic>{
        'name': 'blocked-by-hook',
      });
      expect(blocked.ok, isFalse);
      expect(blocked.error!.code, equals(SyscallErrorCode.eperm));
      expect(blocked.error!.reason, equals('HOOK_BLOCKED'));
      expect(trace, equals(<String>['before:hook_1:sys_skill_read']));

      // 2. beforeSyscall HookModifyArgs + afterSyscall HookAfterReplace -> Stage 7 Capper + Stage 8 Redactor enforced!
      trace.clear();
      final modified = await harness.invokeAsLead('sys_skill_read', const <String, dynamic>{
        'name': 'alias-skill',
      });
      expect(modified.ok, isTrue);
      final content = modified.value!['content'] as String;
      expect(modified.value!['truncated'], isTrue);
      expect(content, isNot(contains(secretValue)));
      expect(content, contains('<REDACTED>'));
      expect(
        trace,
        equals(<String>[
          'before:hook_1:sys_skill_read',
          'before:hook_2:sys_skill_read',
          'transform:hook_1:sys_skill_read',
          'after:hook_1:sys_skill_read:true',
          'after:hook_2:sys_skill_read:true',
        ]),
      );

      // 3. onTxSquash HookBlock short-circuits BEFORE Stage 4 ApprovalGate (0 approval calls).
      trace.clear();
      final squashBlocked = await harness.invokeAsLead('sys_tx_squash', const <String, dynamic>{
        'message': 'bad commit',
      });
      expect(squashBlocked.ok, isFalse);
      expect(squashBlocked.error!.code, equals(SyscallErrorCode.eperm));
      expect(squashBlocked.error!.reason, equals('HOOK_BLOCKED'));
      expect(approvalHandler.recordedRequests, isEmpty);
      expect(
        trace,
        equals(<String>[
          'before:hook_1:sys_tx_squash',
          'before:hook_2:sys_tx_squash',
          'onTxSquash:tx_guard',
        ]),
      );

      // 4. onTxSquash HookAllow proceeds to ApprovalGate and executes handler.
      final squashOk = await harness.invokeAsLead('sys_tx_squash', const <String, dynamic>{
        'message': 'feat: valid commit',
      });
      expect(squashOk.ok, isTrue);
      expect(approvalHandler.recordedRequests, hasLength(1));
    });

    test('covers beforeLlmRequest & afterLlmResponse LlmHooks via llm_router.dart (FIFO, Prefix immutability, quota non-reduction, block)', () async {
      final trace = <String>[];
      final seenRequests = <LlmChatRequest>[];
      final fakeDriver = _FakeLlmDriver(
        onChat: (req) {
          seenRequests.add(req);
          return LlmChatResponse(
            content: 'raw assistant reply',
            finishReason: 'stop',
            usage: const LlmUsageTelemetry(
              promptTokens: 120,
              completionTokens: 30,
              totalTokens: 150,
              durationMs: 42,
            ),
          );
        },
      );
      final router = LlmRouter(
        drivers: <LlmProviderId, LlmDriver>{
          LlmProviderId.localOllama: fakeDriver,
        },
      );

      var blockBefore = false;
      var blockAfter = false;

      final llmHook1 = _RecordingLlmHook(
        name: 'llm_hook_1',
        onBefore: (ctx) async {
          trace.add('before:llm_hook_1');
          if (blockBefore) {
            return const LlmHookBlock(
              reason: 'LLM_PRE_POLICY',
              message: 'Blocked before LLM request',
            );
          }
          return const LlmHookAppendTailNote('[note-1 from hook 1]');
        },
        onAfter: (ctx, resp) async {
          trace.add('after:llm_hook_1');
          return LlmHookAfterReplaceText('${resp.content} [annotated-1]');
        },
      );

      final llmHook2 = _RecordingLlmHook(
        name: 'llm_hook_2',
        onBefore: (ctx) async {
          trace.add('before:llm_hook_2');
          return const LlmHookAppendTailNote('[note-2 from hook 2]');
        },
        onAfter: (ctx, resp) async {
          trace.add('after:llm_hook_2');
          if (blockAfter) {
            return const LlmHookAfterBlock(
              reason: 'LLM_POST_POLICY',
              message: 'Blocked after LLM response',
            );
          }
          return LlmHookAfterReplaceText('${resp.content} [annotated-2]');
        },
      );

      final harness = _TestKernelHarness.create(
        workspaceHostRoot: workspaceDir.path,
        skillsMount: const SkillRegistry.empty(),
      );

      // Populate Segment 0 & Segment 1 to verify strict Prefix immutability.
      harness.leadPcb.memory.appendUserTurn('Stable user history turn');
      final beforeProjection = const CanonicalIrProjector().project(
        harness.leadPcb.memory,
        targetProvider: 'local-ollama',
        targetModel: 'gemma4:12b',
      );
      final prefixBeforeJson = jsonEncode(
        beforeProjection.messages
            .take(2)
            .map((m) => <String, dynamic>{'role': m.role.name, 'content': m.content})
            .toList(),
      );

      harness.gate.registerSyscall(
        buildLlmChatSyscallDefinition(
          router: router,
          auditLogger: harness.auditLogger,
          llmHooks: <LlmHook>[llmHook1, llmHook2],
        ),
      );

      // 1. Normal call: FIFO beforeLlmRequest appends Segment 2 tail notes without mutating Segment 0/1;
      //    afterLlmResponse transforms text while preserving exact 150 token quota consumption.
      final okRes = await harness.invokeAsLead('sys_llm_chat', const <String, dynamic>{
        'model': 'local-ollama/gemma4:12b',
        'turnIndex': 1,
      });
      expect(okRes.ok, isTrue);
      expect(
        okRes.value!['content'],
        equals('raw assistant reply [annotated-1] [annotated-2]'),
      );
      expect(harness.leadPcb.quotaUsage.totalTokensUsed, equals(150));
      expect(
        trace,
        equals(<String>[
          'before:llm_hook_1',
          'before:llm_hook_2',
          'after:llm_hook_1',
          'after:llm_hook_2',
        ]),
      );

      // Verify Segment 0 + Segment 1 prefix is byte-for-byte identical, and Segment 2 tail has both notes.
      expect(seenRequests.length, equals(1));
      final sentMessages = seenRequests.single.prompt.messages;
      final prefixAfterJson = jsonEncode(
        sentMessages
            .take(2)
            .map((m) => <String, dynamic>{'role': m.role.name, 'content': m.content})
            .toList(),
      );
      expect(prefixAfterJson, equals(prefixBeforeJson));
      expect(sentMessages.last.content, contains('[note-1 from hook 1]'));
      expect(sentMessages.last.content, contains('[note-2 from hook 2]'));

      // 2. beforeLlmRequest LlmHookBlock short-circuits driver & hook 2 with EPERM: HOOK_BLOCKED.
      trace.clear();
      blockBefore = true;
      final preBlocked = await harness.invokeAsLead('sys_llm_chat', const <String, dynamic>{
        'model': 'local-ollama/gemma4:12b',
        'turnIndex': 2,
      });
      expect(preBlocked.ok, isFalse);
      expect(preBlocked.error!.code, equals(SyscallErrorCode.eperm));
      expect(preBlocked.error!.reason, equals('HOOK_BLOCKED'));
      expect(seenRequests.length, equals(1));
      expect(trace, equals(<String>['before:llm_hook_1']));

      // 3. afterLlmResponse LlmHookAfterBlock returns EPERM: HOOK_BLOCKED while still accounting real 150 tokens!
      trace.clear();
      blockBefore = false;
      blockAfter = true;
      final postBlocked = await harness.invokeAsLead('sys_llm_chat', const <String, dynamic>{
        'model': 'local-ollama/gemma4:12b',
        'turnIndex': 3,
      });
      expect(postBlocked.ok, isFalse);
      expect(postBlocked.error!.code, equals(SyscallErrorCode.eperm));
      expect(postBlocked.error!.reason, equals('HOOK_BLOCKED'));
      expect(seenRequests.length, equals(2));
      expect(harness.leadPcb.quotaUsage.totalTokensUsed, equals(300));
    });
  });
}

bool _createDirectoryLink({
  required String linkPath,
  required String targetPath,
}) {
  try {
    Link(linkPath).createSync(targetPath);
    return true;
  } on FileSystemException {
    if (Platform.isWindows) {
      final res = Process.runSync(
        'cmd',
        <String>['/c', 'mklink', '/J', linkPath, targetPath],
        runInShell: false,
      );
      return res.exitCode == 0;
    }
    return false;
  }
}

class _TestKernelHarness {
  _TestKernelHarness._({
    required this.processTable,
    required this.leadPcb,
    required this.leadCapHandle,
    required this.redactor,
    required this.auditLogger,
    required this.gate,
    required this.namespace,
  });

  factory _TestKernelHarness.create({
    required String workspaceHostRoot,
    required SkillRegistry skillsMount,
    List<SyscallHook> hooks = const <SyscallHook>[],
    List<TxHook> txHooks = const <TxHook>[],
    ApprovalHandler? approvalHandler,
    IoCapConfig ioCapConfig = const IoCapConfig(),
  }) {
    final redactor = SecretRedactor();
    final auditLogger = AuditLogger(
      workspaceHostRoot: workspaceHostRoot,
      sessionId: 'sess_wp7_test',
      redactor: redactor,
    );
    final namespace = VfsNamespace(
      workspaceHostRoot: workspaceHostRoot,
      skillsMount: skillsMount,
    );
    final processTable = KernelProcessTable.stage2();
    final leadPcb = ProcessControlBlock(
      pid: 1,
      name: 'lead-agent',
      ring: ProtectionRing.ring2,
      state: ProcessState.running,
      cspace: CapabilityTable.stage2LeadAgent(),
      quota: ResourceQuota.stage2Default,
      namespace: namespace,
      memory: VirtualContextMemory(
        sessionId: 'sess_wp7_test',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'Test LeadAgent System Prompt',
          tools: const <SyscallToolSchema>[],
        ),
      ),
    );
    processTable.registerProcess(leadPcb);
    final leadCapHandle = leadPcb.cspace.entries.first.handle;

    final gate = SyscallGate(
      processTable: processTable,
      approvalGate: ApprovalGate(
        handler: approvalHandler ?? PolicyApprovalHandler.alwaysAllow(),
      ),
      ioCapper: IoPayloadCapper(
        config: ioCapConfig,
        workspaceHostRoot: workspaceHostRoot,
      ),
      auditLogger: auditLogger,
      redactor: redactor,
      hooks: hooks,
      txHooks: txHooks,
    );

    final fsDriver = HostFsDriver(namespace: namespace);
    fsDriver.registerAllSyscalls(gate);
    const SkillSyscallDriver().registerSyscalls(gate);

    return _TestKernelHarness._(
      processTable: processTable,
      leadPcb: leadPcb,
      leadCapHandle: leadCapHandle,
      redactor: redactor,
      auditLogger: auditLogger,
      gate: gate,
      namespace: namespace,
    );
  }

  final KernelProcessTable processTable;
  final ProcessControlBlock leadPcb;
  final CapHandle leadCapHandle;
  final SecretRedactor redactor;
  final AuditLogger auditLogger;
  final SyscallGate gate;
  final VfsNamespace namespace;
  int _nextChildPid = 2;

  Pid spawnExplorer() {
    final cspaceRes =
        leadPcb.cspace.deriveForProfile(ProcessProfileId.explorer);
    expect(cspaceRes.ok, isTrue);

    final nsRes = namespace.deriveForChild(inheritSkillsMount: true);
    expect(nsRes.ok, isTrue);

    final pid = _nextChildPid++;
    final child = ProcessControlBlock(
      pid: pid,
      parentPid: leadPcb.pid,
      name: 'explorer',
      ring: ProtectionRing.ring3,
      state: ProcessState.running,
      cspace: cspaceRes.value!,
      quota: const ResourceQuota(maxTotalTokens: 10000),
      namespace: nsRes.value!,
      memory: VirtualContextMemory(
        sessionId: 'sess_wp7_test',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'Explorer',
          tools: const <SyscallToolSchema>[],
        ),
      ),
    );
    expect(processTable.registerProcess(child).ok, isTrue);
    return pid;
  }

  Pid spawnWebResearcher() {
    final cspace = CapabilityTable(
      initialEntries: <CapabilityEntry>[
        CapabilityEntry(
          handle: const CapHandle('cap_web_researcher'),
          rights: <CapRight>{
            CapRight.netRead,
            CapRight.llmInfer,
            CapRight.ipc,
            CapRight.procSelf,
          },
          resourceScope: 'net:public_readonly',
        ),
      ],
    );
    final pid = _nextChildPid++;
    final child = ProcessControlBlock(
      pid: pid,
      parentPid: leadPcb.pid,
      name: 'web_researcher',
      ring: ProtectionRing.ring3,
      state: ProcessState.running,
      cspace: cspace,
      quota: const ResourceQuota(maxTotalTokens: 10000),
      namespace: const VfsNamespace.empty(),
      memory: VirtualContextMemory(
        sessionId: 'sess_wp7_test',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'WebResearcher',
          tools: const <SyscallToolSchema>[],
        ),
      ),
    );
    expect(processTable.registerProcess(child).ok, isTrue);
    return pid;
  }

  Pid spawnCustom({
    required String name,
    required CapabilityTable cspace,
    required VfsNamespace namespace,
  }) {
    final pid = _nextChildPid++;
    final child = ProcessControlBlock(
      pid: pid,
      parentPid: leadPcb.pid,
      name: name,
      ring: ProtectionRing.ring3,
      state: ProcessState.running,
      cspace: cspace,
      quota: const ResourceQuota(maxTotalTokens: 10000),
      namespace: namespace,
      memory: VirtualContextMemory(
        sessionId: 'sess_wp7_test',
        systemInstruction: PinnedSystemInstruction(
          instruction: name,
          tools: const <SyscallToolSchema>[],
        ),
      ),
    );
    expect(processTable.registerProcess(child).ok, isTrue);
    return pid;
  }

  Future<SyscallResult<Map<String, dynamic>>> invokeAsLead(
    String syscallName,
    Map<String, dynamic> args,
  ) {
    return gate.invoke(
      SyscallContext(
        pid: leadPcb.pid,
        capHandle: leadCapHandle,
        sessionId: 'sess_wp7_test',
      ),
      SyscallRequest(name: syscallName, args: args),
    );
  }

  Future<SyscallResult<Map<String, dynamic>>> invokeAs(
    Pid pid,
    String syscallName,
    Map<String, dynamic> args,
  ) {
    final pcb = processTable.getProcess(pid)!;
    final capHandle = pcb.cspace.entries.first.handle;
    return gate.invoke(
      SyscallContext(
        pid: pid,
        capHandle: capHandle,
        sessionId: 'sess_wp7_test',
      ),
      SyscallRequest(name: syscallName, args: args),
    );
  }
}

class _RecordingSyscallHook extends BaseSyscallHook {
  _RecordingSyscallHook({
    required this.name,
    this.onBefore,
    this.onTransformAfter,
    this.onAfter,
  });

  @override
  final String name;

  final Future<HookBeforeResult> Function(SyscallHookContext context)? onBefore;
  final Future<HookAfterResult> Function(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  )? onTransformAfter;
  final Future<void> Function(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  )? onAfter;

  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async {
    if (onBefore != null) {
      return onBefore!(context);
    }
    return const HookAllow();
  }

  @override
  Future<HookAfterResult> transformAfterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    if (onTransformAfter != null) {
      return onTransformAfter!(context, result);
    }
    return const HookAfterKeep();
  }

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    if (onAfter != null) {
      await onAfter!(context, result);
    }
  }
}

class _RecordingTxHook implements TxHook {
  _RecordingTxHook({
    required this.name,
    required this.onSquash,
  });

  @override
  final String name;

  final Future<HookBeforeResult> Function(SyscallHookContext context) onSquash;

  @override
  Future<HookBeforeResult> onTxSquash(SyscallHookContext context) =>
      onSquash(context);
}

class _RecordingLlmHook extends BaseLlmHook {
  _RecordingLlmHook({
    required this.name,
    this.onBefore,
    this.onAfter,
  });

  @override
  final String name;

  final Future<LlmHookBeforeResult> Function(LlmHookContext context)? onBefore;
  final Future<LlmHookAfterResult> Function(
    LlmHookContext context,
    LlmChatResponse response,
  )? onAfter;

  @override
  Future<LlmHookBeforeResult> beforeLlmRequest(LlmHookContext context) async {
    if (onBefore != null) {
      return onBefore!(context);
    }
    return const LlmHookAllow();
  }

  @override
  Future<LlmHookAfterResult> afterLlmResponse(
    LlmHookContext context,
    LlmChatResponse response,
  ) async {
    if (onAfter != null) {
      return onAfter!(context, response);
    }
    return const LlmHookAfterKeep();
  }
}

class _FakeLlmDriver implements LlmDriver {
  _FakeLlmDriver({required this.onChat});

  final LlmChatResponse Function(LlmChatRequest request) onChat;

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final resp = onChat(request);
    yield LlmTextDelta(resp.content);
    yield LlmDoneEvent(resp);
  }
}
