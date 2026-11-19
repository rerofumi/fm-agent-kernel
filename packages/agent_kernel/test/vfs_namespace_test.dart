import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('VfsNamespace [D-011]', () {
    late Directory workspaceDir;
    late Directory outsideDir;
    late VfsNamespace vfs;

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('vfs_ws_');
      outsideDir = Directory.systemTemp.createTempSync('vfs_out_');
      Directory(p.join(workspaceDir.path, 'lib')).createSync();
      File(p.join(workspaceDir.path, 'lib', 'main.dart'))
          .writeAsStringSync('void main() {}');
      File(p.join(outsideDir.path, 'secret.txt'))
          .writeAsStringSync('top-secret');
      vfs = VfsNamespace(workspaceHostRoot: workspaceDir.path);
    });

    tearDown(() {
      if (workspaceDir.existsSync()) {
        workspaceDir.deleteSync(recursive: true);
      }
      if (outsideDir.existsSync()) {
        outsideDir.deleteSync(recursive: true);
      }
    });

    test('normalizes /workspace and relative paths into host paths', () {
      final r1 = vfs.resolveVirtualPath('/workspace');
      expect(r1.ok, isTrue);
      expect(r1.value!.virtualPath, equals('/workspace'));
      expect(r1.value!.isRoot, isTrue);

      final r2 = vfs.resolveVirtualPath('lib/main.dart');
      expect(r2.ok, isTrue);
      expect(r2.value!.virtualPath, equals('/workspace/lib/main.dart'));
      expect(
        r2.value!.hostPath.toLowerCase(),
        equals(p.normalize(p.join(vfs.workspaceHostRoot!, 'lib', 'main.dart')).toLowerCase()),
      );

      final r3 = vfs.resolveVirtualPath('/workspace/lib/../lib/main.dart');
      expect(r3.ok, isTrue);
      expect(r3.value!.virtualPath, equals('/workspace/lib/main.dart'));
    });

    test('rejects traversal, drive letters, UNC, external absolute paths, and NUL bytes with EACCES', () {
      final badPaths = <String>[
        '/workspace/../secret.txt',
        '../../Windows/win.ini',
        'lib/../../secret.txt',
        r'C:\Windows\win.ini',
        'C:/Users/public/test.txt',
        r'\\server\share\file.txt',
        '//server/share/file.txt',
        '/etc/passwd',
        'lib/\x00main.dart',
      ];

      for (final raw in badPaths) {
        final res = vfs.resolveVirtualPath(raw);
        expect(res.ok, isFalse, reason: 'Expected rejection for "$raw"');
        expect(res.error!.code, equals(SyscallErrorCode.eacces));
        expect(res.error!.reason, equals('OUT_OF_WORKSPACE_SCOPE'));
      }
    });

    test('blocks protected internal paths (.jj, .git, .agent_os, .env*) bidirectionally', () {
      final protectedPaths = <String>[
        '/workspace/.jj',
        '/workspace/.jj/repo/store',
        '.jj/working_copy/tree',
        '/workspace/.git/config',
        '.git/HEAD',
        '/workspace/.agent_os/logs/s1/syscalls.jsonl',
        '.agent_os/.gitignore',
        '/workspace/.env',
        '.env',
        '/workspace/.env.local',
        'sub/.env.production',
      ];

      for (final raw in protectedPaths) {
        final res = vfs.resolveVirtualPath(raw);
        expect(res.ok, isFalse, reason: 'Expected protection for "$raw"');
        expect(res.error!.code, equals(SyscallErrorCode.eacces));
        expect(res.error!.reason, equals('PROTECTED_INTERNAL_PATH'));
      }

      // Non-secret files starting with dot remain allowed.
      expect(vfs.resolveVirtualPath('/workspace/.gitignore').ok, isTrue);
      expect(vfs.resolveVirtualPath('/workspace/foo.env').ok, isTrue);
    });

    test('detects protected glob/grep patterns and auto-skip parent scan entries', () {
      expect(vfs.isProtectedPattern('.jj/**'), isTrue);
      expect(vfs.isProtectedPattern('/workspace/.git/HEAD'), isTrue);
      expect(vfs.isProtectedPattern('**/.agent_os/**'), isTrue);
      expect(vfs.isProtectedPattern('.env*'), isTrue);
      expect(vfs.isProtectedPattern('lib/**/*.dart'), isFalse);

      expect(vfs.shouldSkipEntry('/workspace/.jj'), isTrue);
      expect(vfs.shouldSkipEntry('/workspace/.git/objects'), isTrue);
      expect(vfs.shouldSkipEntry('/workspace/.agent_os/io_spill'), isTrue);
      expect(vfs.shouldSkipEntry('/workspace/.env'), isTrue);
      expect(vfs.shouldSkipEntry('/workspace/.env.staging'), isTrue);
      expect(vfs.shouldSkipEntry('/workspace/lib/main.dart'), isFalse);
    });

    test('blocks directory junction or symlink escaping outside workspace root', () {
      final escapeLinkPath = p.join(workspaceDir.path, 'escape_dir');
      var linkCreated = false;
      if (Platform.isWindows) {
        final proc = Process.runSync(
          'cmd',
          <String>['/c', 'mklink', '/J', escapeLinkPath, outsideDir.path],
        );
        linkCreated = proc.exitCode == 0;
      } else {
        Link(escapeLinkPath).createSync(outsideDir.path);
        linkCreated = true;
      }
      expect(linkCreated, isTrue);

      final res = vfs.resolveVirtualPath('/workspace/escape_dir/secret.txt');
      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.eacces));
      expect(res.error!.reason, equals('OUT_OF_WORKSPACE_SCOPE'));
    });

    test('blocks directory junction pointing to protected internal .jj directory', () {
      final jjDir = Directory(p.join(workspaceDir.path, '.jj'))..createSync();
      File(p.join(jjDir.path, 'op_heads')).writeAsStringSync('head');
      final bypassLinkPath = p.join(workspaceDir.path, 'jj_alias');

      var linkCreated = false;
      if (Platform.isWindows) {
        final proc = Process.runSync(
          'cmd',
          <String>['/c', 'mklink', '/J', bypassLinkPath, jjDir.path],
        );
        linkCreated = proc.exitCode == 0;
      } else {
        Link(bypassLinkPath).createSync(jjDir.path);
        linkCreated = true;
      }
      expect(linkCreated, isTrue);

      final res = vfs.resolveVirtualPath('/workspace/jj_alias/op_heads');
      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.eacces));
      expect(res.error!.reason, equals('PROTECTED_INTERNAL_PATH'));
    });

    test('enforces allowedWorkspaceSubpaths and monotonic child subpath attenuation [D-213]', () {
      Directory(p.join(workspaceDir.path, 'lib', 'src')).createSync(recursive: true);
      Directory(p.join(workspaceDir.path, 'lib2')).createSync(recursive: true);
      File(p.join(workspaceDir.path, 'lib', 'src', 'a.dart')).writeAsStringSync('int a = 1;');
      File(p.join(workspaceDir.path, 'lib2', 'b.dart')).writeAsStringSync('int b = 2;');

      final parentScoped = vfs.deriveForChild(
        allowedSubpaths: const <String>['/workspace/lib'],
      );
      expect(parentScoped.ok, isTrue);
      expect(parentScoped.value!.allowedWorkspaceSubpaths, equals(const <String>['/workspace/lib']));

      // Inside allowed subpath succeeds.
      expect(
        parentScoped.value!.resolveVirtualPath('/workspace/lib/src/a.dart').ok,
        isTrue,
      );

      // Sibling prefix `/workspace/lib2` and root `/workspace` must be rejected with EACCES.
      final siblingRes = parentScoped.value!.resolveVirtualPath('/workspace/lib2/b.dart');
      expect(siblingRes.ok, isFalse);
      expect(siblingRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(siblingRes.error!.reason, equals('OUT_OF_ALLOWED_SUBPATH'));

      final rootRes = parentScoped.value!.resolveVirtualPath('/workspace');
      expect(rootRes.ok, isFalse);
      expect(rootRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(rootRes.error!.reason, equals('OUT_OF_ALLOWED_SUBPATH'));

      // Narrowing further succeeds.
      final narrower = parentScoped.value!.deriveForChild(
        allowedSubpaths: const <String>['/workspace/lib/src'],
      );
      expect(narrower.ok, isTrue);
      expect(narrower.value!.resolveVirtualPath('/workspace/lib/src/a.dart').ok, isTrue);
      expect(narrower.value!.resolveVirtualPath('/workspace/lib/main.dart').ok, isFalse);

      // Widening outside parent allowed subpath fails with EPERM.
      final widened = parentScoped.value!.deriveForChild(
        allowedSubpaths: const <String>['/workspace/lib2'],
      );
      expect(widened.ok, isFalse);
      expect(widened.error!.code, equals(SyscallErrorCode.eperm));
      expect(widened.error!.reason, equals('SUBPATH_ATTENUATION_VIOLATION'));

      // Protected subpath derivation fails with EPERM.
      final protectedSub = vfs.deriveForChild(
        allowedSubpaths: const <String>['/workspace/.agent_os'],
      );
      expect(protectedSub.ok, isFalse);
      expect(protectedSub.error!.code, equals(SyscallErrorCode.eperm));
      expect(protectedSub.error!.reason, equals('SUBPATH_ATTENUATION_VIOLATION'));
    });

    test('VfsNamespace.empty() denies all /workspace accesses with WORKSPACE_NOT_MOUNTED [D-213]', () {
      const sterile = VfsNamespace.empty();
      expect(sterile.workspaceHostRoot, isNull);
      expect(sterile.isWorkspaceMounted, isFalse);

      final r1 = sterile.resolveVirtualPath('/workspace');
      expect(r1.ok, isFalse);
      expect(r1.error!.code, equals(SyscallErrorCode.eacces));
      expect(r1.error!.reason, equals('WORKSPACE_NOT_MOUNTED'));

      final r2 = sterile.resolveVirtualPath('lib/main.dart');
      expect(r2.ok, isFalse);
      expect(r2.error!.code, equals(SyscallErrorCode.eacces));
      expect(r2.error!.reason, equals('WORKSPACE_NOT_MOUNTED'));

      final cannotWiden = sterile.deriveForChild(
        allowedSubpaths: const <String>['/workspace/lib'],
      );
      expect(cannotWiden.ok, isFalse);
      expect(cannotWiden.error!.code, equals(SyscallErrorCode.eperm));
      expect(cannotWiden.error!.reason, equals('SUBPATH_ATTENUATION_VIOLATION'));
    });

    test('resolves read-only /skills/<skillName>/... paths and denies writes with READ_ONLY_SKILL_MOUNT [D-219]', () {
      final skillsRoot = Directory.systemTemp.createTempSync('vfs_skills_');
      addTearDown(() {
        if (skillsRoot.existsSync()) {
          skillsRoot.deleteSync(recursive: true);
        }
      });

      final skillDir = Directory(p.join(skillsRoot.path, 'jj-workflow'))
        ..createSync(recursive: true);
      final skillFile = File(p.join(skillDir.path, 'SKILL.md'))
        ..writeAsStringSync('# JJ Workflow');

      final registry = SkillRegistry(
        skills: <SkillManifest>[
          SkillManifest(
            name: 'jj-workflow',
            description: 'JJ guide',
            virtualPath: '/skills/jj-workflow/SKILL.md',
            hostFilePath: skillFile.path,
            hostDirectoryPath: skillDir.path,
            sourceRootPath: skillsRoot.path,
          ),
        ],
      );

      final vfsWithSkills = VfsNamespace(
        workspaceHostRoot: workspaceDir.path,
        skillsMount: registry,
      );
      expect(vfsWithSkills.isSkillsMounted, isTrue);

      // Read resolution succeeds and marks resolution as read-only /skills mount.
      final readRes =
          vfsWithSkills.resolveVirtualPath('/skills/jj-workflow/SKILL.md');
      expect(readRes.ok, isTrue);
      expect(readRes.value!.virtualPath, equals('/skills/jj-workflow/SKILL.md'));
      expect(readRes.value!.isSkillsMount, isTrue);
      expect(readRes.value!.isReadOnly, isTrue);
      expect(readRes.value!.skillName, equals('jj-workflow'));
      expect(
        readRes.value!.hostPath.toLowerCase(),
        equals(p.normalize(skillFile.resolveSymbolicLinksSync()).toLowerCase()),
      );

      // Case-insensitive lookup normalizes to canonical skill name.
      final caseRes =
          vfsWithSkills.resolveVirtualPath('/skills/JJ-WORKFLOW/SKILL.md');
      expect(caseRes.ok, isTrue);
      expect(caseRes.value!.virtualPath, equals('/skills/jj-workflow/SKILL.md'));

      // Write attempts to /skills are unconditionally rejected with READ_ONLY_SKILL_MOUNT.
      final writeRes = vfsWithSkills.resolveVirtualPath(
        '/skills/jj-workflow/SKILL.md',
        forWrite: true,
      );
      expect(writeRes.ok, isFalse);
      expect(writeRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(writeRes.error!.reason, equals('READ_ONLY_SKILL_MOUNT'));

      final writeHelperRes =
          vfsWithSkills.resolveWriteVirtualPath('/skills/jj-workflow/new.md');
      expect(writeHelperRes.ok, isFalse);
      expect(writeHelperRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(writeHelperRes.error!.reason, equals('READ_ONLY_SKILL_MOUNT'));

      // Unknown skill returns ENOENT: SKILL_NOT_FOUND.
      final missingRes =
          vfsWithSkills.resolveVirtualPath('/skills/unknown-skill/SKILL.md');
      expect(missingRes.ok, isFalse);
      expect(missingRes.error!.code, equals(SyscallErrorCode.enoent));
      expect(missingRes.error!.reason, equals('SKILL_NOT_FOUND'));

      // Traversal escaping /skills is rejected with EACCES.
      final escapeRes =
          vfsWithSkills.resolveVirtualPath('/skills/../workspace/lib/main.dart');
      expect(escapeRes.ok, isFalse);
      expect(escapeRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(escapeRes.error!.reason, equals('OUT_OF_SKILLS_SCOPE'));

      // Unmounted /skills (both standard without skillsMount and VfsNamespace.empty()) returns SKILLS_NOT_MOUNTED.
      final unmountedRes = vfs.resolveVirtualPath('/skills/jj-workflow/SKILL.md');
      expect(unmountedRes.ok, isFalse);
      expect(unmountedRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(unmountedRes.error!.reason, equals('SKILLS_NOT_MOUNTED'));

      const sterile = VfsNamespace.empty();
      expect(sterile.isSkillsMounted, isFalse);
      final sterileSkillRes =
          sterile.resolveVirtualPath('/skills/jj-workflow/SKILL.md');
      expect(sterileSkillRes.ok, isFalse);
      expect(sterileSkillRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(sterileSkillRes.error!.reason, equals('SKILLS_NOT_MOUNTED'));

      // Child derivation inherits skillsMount by default and can strip it when inheritSkillsMount: false.
      final childInherit = vfsWithSkills.deriveForChild(
        allowedSubpaths: const <String>['/workspace/lib'],
      );
      expect(childInherit.ok, isTrue);
      expect(childInherit.value!.isSkillsMounted, isTrue);
      expect(
        childInherit.value!.resolveVirtualPath('/skills/jj-workflow/SKILL.md').ok,
        isTrue,
      );

      final childNoSkills = vfsWithSkills.deriveForChild(
        allowedSubpaths: const <String>['/workspace/lib'],
        inheritSkillsMount: false,
      );
      expect(childNoSkills.ok, isTrue);
      expect(childNoSkills.value!.isSkillsMounted, isFalse);
    });

    test('blocks symlink/junction escaping outside mounted skill directory [D-219]', () {
      final skillsRoot = Directory.systemTemp.createTempSync('vfs_skills_link_');
      addTearDown(() {
        if (skillsRoot.existsSync()) {
          skillsRoot.deleteSync(recursive: true);
        }
      });

      final skillDir = Directory(p.join(skillsRoot.path, 'linked-skill'))
        ..createSync(recursive: true);
      final skillFile = File(p.join(skillDir.path, 'SKILL.md'))
        ..writeAsStringSync('# Linked');
      final escapeLinkPath = p.join(skillDir.path, 'escape_out');

      var linkCreated = false;
      if (Platform.isWindows) {
        final proc = Process.runSync(
          'cmd',
          <String>['/c', 'mklink', '/J', escapeLinkPath, outsideDir.path],
        );
        linkCreated = proc.exitCode == 0;
      } else {
        Link(escapeLinkPath).createSync(outsideDir.path);
        linkCreated = true;
      }
      expect(linkCreated, isTrue);

      final registry = SkillRegistry(
        skills: <SkillManifest>[
          SkillManifest(
            name: 'linked-skill',
            virtualPath: '/skills/linked-skill/SKILL.md',
            hostFilePath: skillFile.path,
            hostDirectoryPath: skillDir.path,
            sourceRootPath: skillsRoot.path,
          ),
        ],
      );
      final vfsWithSkills = VfsNamespace(
        workspaceHostRoot: workspaceDir.path,
        skillsMount: registry,
      );

      final res = vfsWithSkills
          .resolveVirtualPath('/skills/linked-skill/escape_out/secret.txt');
      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.eacces));
      expect(res.error!.reason, equals('OUT_OF_SKILLS_SCOPE'));
    });
  });
}
