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
        equals(p.normalize(p.join(vfs.workspaceHostRoot, 'lib', 'main.dart')).toLowerCase()),
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
  });
}
