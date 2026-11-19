import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/fs_jj_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('HostFsDriver Read-Only VFS [D-011], [D-012]', () {
    late Directory workspaceDir;
    late Directory outsideDir;
    late VfsNamespace namespace;
    late HostFsDriver fsDriver;

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('wp3_fs_ws_');
      outsideDir = Directory.systemTemp.createTempSync('wp3_fs_out_');

      Directory(p.join(workspaceDir.path, 'lib', 'src')).createSync(recursive: true);
      Directory(p.join(workspaceDir.path, 'test')).createSync(recursive: true);
      Directory(p.join(workspaceDir.path, '.jj', 'repo')).createSync(recursive: true);
      Directory(p.join(workspaceDir.path, '.git', 'objects')).createSync(recursive: true);
      Directory(p.join(workspaceDir.path, '.agent_os', 'logs')).createSync(recursive: true);

      File(p.join(workspaceDir.path, 'lib', 'main.dart')).writeAsStringSync(
        'line1: void main() {\n'
        'line2:   final greeting = "hello";\n'
        'line3:   print(greeting);\n'
        'line4: }\n',
      );
      File(p.join(workspaceDir.path, 'lib', 'src', 'helper.dart')).writeAsStringSync(
        'String helper() => "HELPER_TOKEN";\n',
      );
      File(p.join(workspaceDir.path, 'test', 'sample_test.dart')).writeAsStringSync(
        'void testFn() { /* helper_token */ }\n',
      );
      File(p.join(workspaceDir.path, 'empty.txt')).writeAsStringSync('');
      File(p.join(workspaceDir.path, 'crlf.txt')).writeAsBytesSync(
        utf8.encode('alpha\r\nbeta\r\ngamma\r\n'),
      );
      File(p.join(workspaceDir.path, 'binary.bin')).writeAsBytesSync(
        <int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A],
      );
      File(p.join(workspaceDir.path, 'bad_utf8.dat')).writeAsBytesSync(
        <int>[0xFF, 0xFE, 0xFD, 0x80],
      );

      // Protected files that must never be exposed via direct read or parent scans.
      File(p.join(workspaceDir.path, '.jj', 'repo', 'secret_jj.txt'))
          .writeAsStringSync('SECRET_IN_JJ');
      File(p.join(workspaceDir.path, '.git', 'HEAD'))
          .writeAsStringSync('ref: refs/heads/main SECRET_IN_GIT');
      File(p.join(workspaceDir.path, '.agent_os', 'logs', 'audit.txt'))
          .writeAsStringSync('SECRET_IN_AGENT_OS');
      File(p.join(workspaceDir.path, '.env'))
          .writeAsStringSync('OPENROUTER_API_KEY=SECRET_IN_ENV');
      File(p.join(workspaceDir.path, '.env.local'))
          .writeAsStringSync('OLLAMA_API_KEY=SECRET_IN_ENV_LOCAL');

      File(p.join(outsideDir.path, 'outside.txt'))
          .writeAsStringSync('OUTSIDE_SECRET');

      namespace = VfsNamespace(workspaceHostRoot: workspaceDir.path);
      fsDriver = HostFsDriver(namespace: namespace);
    });

    tearDown(() {
      if (workspaceDir.existsSync()) {
        workspaceDir.deleteSync(recursive: true);
      }
      if (outsideDir.existsSync()) {
        outsideDir.deleteSync(recursive: true);
      }
    });

    test('sys_read_lines slices exact 1-based range and returns whole-file SHA-256 and totalLines', () async {
      final fileBytes = File(p.join(workspaceDir.path, 'lib', 'main.dart')).readAsBytesSync();
      final expectedSha = sha256.convert(fileBytes).toString();

      final res = await fsDriver.readLines(
        path: '/workspace/lib/main.dart',
        startLine: 2,
        endLine: 3,
      );

      expect(res.ok, isTrue);
      final data = res.value!;
      expect(data['path'], equals('/workspace/lib/main.dart'));
      expect(data['sha256'], equals(expectedSha));
      expect((data['sha256'] as String).length, equals(64));
      expect(data['totalLines'], equals(4));
      expect(data['startLine'], equals(2));
      expect(data['endLine'], equals(3));
      expect(
        data['content'],
        equals('line2:   final greeting = "hello";\nline3:   print(greeting);'),
      );
    });

    test('sys_read_lines preserves CRLF inside slice for exact oldBlock matching', () async {
      final res = await fsDriver.readLines(
        path: 'crlf.txt',
        startLine: 1,
        endLine: 2,
      );
      expect(res.ok, isTrue);
      expect(res.value!['totalLines'], equals(3));
      expect(res.value!['content'], equals('alpha\r\nbeta'));
    });

    test('sys_read_lines handles empty file and startLine > totalLines cleanly', () async {
      final emptyRes = await fsDriver.readLines(path: '/workspace/empty.txt');
      expect(emptyRes.ok, isTrue);
      expect(emptyRes.value!['totalLines'], equals(0));
      expect(emptyRes.value!['content'], equals(''));
      expect(
        emptyRes.value!['sha256'],
        equals(sha256.convert(const <int>[]).toString()),
      );

      final beyondRes = await fsDriver.readLines(
        path: '/workspace/lib/main.dart',
        startLine: 50,
        endLine: 60,
      );
      expect(beyondRes.ok, isTrue);
      expect(beyondRes.value!['totalLines'], equals(4));
      expect(beyondRes.value!['content'], equals(''));
      expect((beyondRes.value!['sha256'] as String).length, equals(64));
    });

    test('sys_read_lines returns EINVAL on invalid line numbers, directory, or binary/invalid UTF-8 and ENOENT on missing', () async {
      final invalidStart = await fsDriver.readLines(
        path: '/workspace/lib/main.dart',
        startLine: 0,
      );
      expect(invalidStart.ok, isFalse);
      expect(invalidStart.error!.code, equals(SyscallErrorCode.einval));

      final invalidRange = await fsDriver.readLines(
        path: '/workspace/lib/main.dart',
        startLine: 3,
        endLine: 2,
      );
      expect(invalidRange.ok, isFalse);
      expect(invalidRange.error!.code, equals(SyscallErrorCode.einval));

      final dirRead = await fsDriver.readLines(path: '/workspace/lib');
      expect(dirRead.ok, isFalse);
      expect(dirRead.error!.code, equals(SyscallErrorCode.einval));

      final rootRead = await fsDriver.readLines(path: '/workspace');
      expect(rootRead.ok, isFalse);
      expect(rootRead.error!.code, equals(SyscallErrorCode.einval));

      final missingRead = await fsDriver.readLines(path: '/workspace/missing.dart');
      expect(missingRead.ok, isFalse);
      expect(missingRead.error!.code, equals(SyscallErrorCode.enoent));

      final binRead = await fsDriver.readLines(path: '/workspace/binary.bin');
      expect(binRead.ok, isFalse);
      expect(binRead.error!.code, equals(SyscallErrorCode.einval));
      expect(binRead.error!.reason, equals('BINARY_FILE'));

      final badUtf8Read = await fsDriver.readLines(path: '/workspace/bad_utf8.dat');
      expect(badUtf8Read.ok, isFalse);
      expect(badUtf8Read.error!.code, equals(SyscallErrorCode.einval));
      expect(badUtf8Read.error!.reason, equals('BINARY_FILE'));
    });

    test('rejects direct access to protected paths (.jj, .git, .agent_os, .env*) and out-of-scope paths with EACCES', () async {
      final protectedTargets = <String>[
        '/workspace/.jj/repo/secret_jj.txt',
        '.git/HEAD',
        '/workspace/.agent_os/logs/audit.txt',
        '.env',
        '/workspace/.env.local',
      ];
      for (final target in protectedTargets) {
        final rRead = await fsDriver.readLines(path: target);
        expect(rRead.ok, isFalse, reason: 'readLines should reject $target');
        expect(rRead.error!.code, equals(SyscallErrorCode.eacces));
        expect(rRead.error!.reason, equals('PROTECTED_INTERNAL_PATH'));

        final rGlob = await fsDriver.glob(pattern: '*', subpath: target);
        expect(rGlob.ok, isFalse, reason: 'glob subpath should reject $target');
        expect(rGlob.error!.code, equals(SyscallErrorCode.eacces));

        final rGrep = await fsDriver.grep(pattern: 'SECRET', subpath: target);
        expect(rGrep.ok, isFalse, reason: 'grep subpath should reject $target');
        expect(rGrep.error!.code, equals(SyscallErrorCode.eacces));
      }

      for (final pat in <String>['.jj/**', '/workspace/.git/*', '**/.agent_os/**', '.env*']) {
        final g = await fsDriver.glob(pattern: pat);
        expect(g.ok, isFalse, reason: 'glob pattern should reject $pat');
        expect(g.error!.code, equals(SyscallErrorCode.eacces));
        expect(g.error!.reason, equals('PROTECTED_INTERNAL_PATH'));
      }

      final grepIncludeProtected = await fsDriver.grep(
        pattern: 'SECRET',
        includeGlob: '.env*',
      );
      expect(grepIncludeProtected.ok, isFalse);
      expect(grepIncludeProtected.error!.code, equals(SyscallErrorCode.eacces));

      for (final badPath in <String>[
        '../outside.txt',
        r'C:\Windows\win.ini',
        r'\\server\share\file.txt',
        '/etc/passwd',
      ]) {
        final r = await fsDriver.readLines(path: badPath);
        expect(r.ok, isFalse, reason: 'Should reject $badPath');
        expect(r.error!.code, equals(SyscallErrorCode.eacces));
        expect(r.error!.reason, equals('OUT_OF_WORKSPACE_SCOPE'));
      }
    });

    test('blocks symlink/junction escape on direct read and auto-skips unsafe links & protected paths in parent scans', () async {
      final escapeLink = p.join(workspaceDir.path, 'escape_dir');
      final jjAliasLink = p.join(workspaceDir.path, 'jj_alias');

      bool createDirLink(String linkPath, String targetPath) {
        if (Platform.isWindows) {
          final proc = Process.runSync(
            'cmd',
            <String>['/c', 'mklink', '/J', linkPath, targetPath],
          );
          return proc.exitCode == 0;
        }
        Link(linkPath).createSync(targetPath);
        return true;
      }

      expect(createDirLink(escapeLink, outsideDir.path), isTrue);
      expect(
        createDirLink(jjAliasLink, p.join(workspaceDir.path, '.jj')),
        isTrue,
      );

      final directEscape = await fsDriver.readLines(
        path: '/workspace/escape_dir/outside.txt',
      );
      expect(directEscape.ok, isFalse);
      expect(directEscape.error!.code, equals(SyscallErrorCode.eacces));
      expect(directEscape.error!.reason, equals('OUT_OF_WORKSPACE_SCOPE'));

      final directJjAlias = await fsDriver.readLines(
        path: '/workspace/jj_alias/repo/secret_jj.txt',
      );
      expect(directJjAlias.ok, isFalse);
      expect(directJjAlias.error!.code, equals(SyscallErrorCode.eacces));
      expect(directJjAlias.error!.reason, equals('PROTECTED_INTERNAL_PATH'));

      // Parent sys_glob must succeed while automatically skipping protected dirs, .env*, and escape/alias links.
      final globRes = await fsDriver.glob(pattern: '**/*');
      expect(globRes.ok, isTrue);
      final matches = globRes.value!['matches'] as List<String>;
      expect(matches, contains('/workspace/lib/main.dart'));
      expect(matches, contains('/workspace/lib/src/helper.dart'));
      expect(matches.any((m) => m.contains('.jj')), isFalse);
      expect(matches.any((m) => m.contains('.git')), isFalse);
      expect(matches.any((m) => m.contains('.agent_os')), isFalse);
      expect(matches.any((m) => m.contains('.env')), isFalse);
      expect(matches.any((m) => m.contains('escape_dir')), isFalse);
      expect(matches.any((m) => m.contains('jj_alias')), isFalse);

      // Parent sys_grep must also skip binary, protected, and escaped targets without erroring.
      final grepSecret = await fsDriver.grep(pattern: 'SECRET');
      expect(grepSecret.ok, isTrue);
      expect(grepSecret.value!['totalMatches'], equals(0));
    });

    test('sys_glob and sys_grep support subpath, regex, case sensitivity, and includeGlob', () async {
      final dartGlob = await fsDriver.glob(
        pattern: '**/*.dart',
        subpath: '/workspace/lib',
      );
      expect(dartGlob.ok, isTrue);
      expect(
        dartGlob.value!['matches'],
        equals(<String>[
          '/workspace/lib/main.dart',
          '/workspace/lib/src/helper.dart',
        ]),
      );

      final grepCaseInsensitive = await fsDriver.grep(
        pattern: 'helper_token',
        caseSensitive: false,
      );
      expect(grepCaseInsensitive.ok, isTrue);
      expect(grepCaseInsensitive.value!['totalMatches'], equals(2));

      final grepIncludeDart = await fsDriver.grep(
        pattern: r'greeting\s*=',
        isRegex: true,
        includeGlob: '*.dart',
      );
      expect(grepIncludeDart.ok, isTrue);
      final matches = grepIncludeDart.value!['matches'] as List<Map<String, dynamic>>;
      expect(matches.length, equals(1));
      expect(matches.first['path'], equals('/workspace/lib/main.dart'));
      expect(matches.first['line'], equals(2));

      final badRegex = await fsDriver.grep(pattern: '[unclosed', isRegex: true);
      expect(badRegex.ok, isFalse);
      expect(badRegex.error!.code, equals(SyscallErrorCode.einval));
      expect(badRegex.error!.reason, equals('INVALID_REGEX'));
    });

    test('SyscallGate + IoPayloadCapper caps oversized sys_read_lines content while preserving sha256 and totalLines', () async {
      final bigLines = List<String>.generate(250, (i) => 'line_${i + 1}_payload');
      final bigFile = File(p.join(workspaceDir.path, 'big.txt'));
      bigFile.writeAsStringSync('${bigLines.join('\n')}\n');
      final expectedSha = sha256.convert(bigFile.readAsBytesSync()).toString();

      final processTable = KernelProcessTable();
      final pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead',
        ring: ProtectionRing.ring2,
        state: ProcessState.running,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: const ResourceQuota(maxChildProcesses: 0),
        namespace: namespace,
        memory: VirtualContextMemory(
          sessionId: 'sess_fs',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'System',
            tools: HostFsDriver.readToolSchemas(),
          ),
        ),
      );
      processTable.registerProcess(pcb);

      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(
          config: const IoCapConfig(maxLines: 20, headLines: 10, tailLines: 5),
          workspaceHostRoot: workspaceDir.path,
        ),
        auditLogger: AuditLogger(
          workspaceHostRoot: workspaceDir.path,
          sessionId: 'sess_fs',
        ),
      );
      fsDriver.registerReadSyscalls(gate);

      const ctx = SyscallContext(
        pid: 1,
        capHandle: CapHandle('cap_workspace_rw'),
        sessionId: 'sess_fs',
      );

      final res = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_read_lines',
          args: const <String, dynamic>{
            'path': '/workspace/big.txt',
            'startLine': 1,
            'endLine': 250,
          },
        ),
      );

      expect(res.ok, isTrue);
      final value = res.value!;
      expect(value['sha256'], equals(expectedSha));
      expect(value['totalLines'], equals(250));
      expect(value['truncated'], isTrue);
      expect(value['content'], contains('KERNEL I/O CAP'));
      expect(value['spillPath'], isNotNull);
    });
  });
}
