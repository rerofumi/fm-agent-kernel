import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('HostFsDriver CAS File Editing [D-011], [D-013], OM-03', () {
    late Directory workspaceDir;
    late Directory outsideDir;
    late VfsNamespace namespace;
    late HostFsDriver fsDriver;

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('wp6_fs_cas_');
      outsideDir = Directory.systemTemp.createTempSync('wp6_fs_out_');

      Directory(p.join(workspaceDir.path, 'lib')).createSync(recursive: true);
      Directory(p.join(workspaceDir.path, '.jj', 'repo')).createSync(recursive: true);
      Directory(p.join(workspaceDir.path, '.git', 'objects')).createSync(recursive: true);
      Directory(p.join(workspaceDir.path, '.agent_os', 'logs')).createSync(recursive: true);

      File(p.join(workspaceDir.path, 'lib', 'sample.dart')).writeAsStringSync(
        'int compute(int x) {\n'
        '  final a = x + 1;\n'
        '  return a * 2;\n'
        '}\n',
      );
      File(p.join(workspaceDir.path, 'lib', 'dup.dart')).writeAsStringSync(
        'const marker = 1;\n'
        'void f1() => print(marker);\n'
        'void f2() => print(marker);\n',
      );
      File(p.join(workspaceDir.path, 'lib', 'crlf.txt')).writeAsBytesSync(
        utf8.encode('line1\r\nline2_target\r\nline3\r\n'),
      );
      File(p.join(workspaceDir.path, 'binary.bin')).writeAsBytesSync(
        <int>[0x00, 0x01, 0x02, 0x03],
      );

      // Protected internal files.
      File(p.join(workspaceDir.path, '.jj', 'repo', 'cfg')).writeAsStringSync('JJ_SECRET');
      File(p.join(workspaceDir.path, '.git', 'HEAD')).writeAsStringSync('ref: refs/heads/main');
      File(p.join(workspaceDir.path, '.agent_os', 'logs', 'audit.jsonl'))
          .writeAsStringSync('AUDIT_LINE\n');
      File(p.join(workspaceDir.path, '.env')).writeAsStringSync('OPENROUTER_API_KEY=abc\n');
      File(p.join(workspaceDir.path, '.env.prod')).writeAsStringSync('OLLAMA_API_KEY=xyz\n');

      File(p.join(outsideDir.path, 'outside.txt')).writeAsStringSync('OUTSIDE_ORIGINAL');

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

    test('sys_edit_block replaces unique block with matching SHA-256 and supports chained edits & CRLF preservation', () async {
      final readRes = await fsDriver.readLines(path: '/workspace/lib/sample.dart');
      expect(readRes.ok, isTrue);
      final sha1 = readRes.value!['sha256'] as String;

      final edit1 = await fsDriver.editBlock(
        path: '/workspace/lib/sample.dart',
        expectedSha256: sha1.toUpperCase(), // case-insensitive hex accepted
        oldBlock: '  final a = x + 1;\n  return a * 2;',
        newBlock: '  final a = x + 10;\n  return a * 3;',
      );
      expect(edit1.ok, isTrue, reason: '${edit1.error}');
      expect(edit1.value!['path'], equals('/workspace/lib/sample.dart'));
      expect(edit1.value!['previousSha256'], equals(sha1));
      final sha2 = edit1.value!['newSha256'] as String;
      expect(sha2, isNot(equals(sha1)));

      final actualDiskBytes =
          File(p.join(workspaceDir.path, 'lib', 'sample.dart')).readAsBytesSync();
      expect(sha256.convert(actualDiskBytes).toString(), equals(sha2));
      expect(
        utf8.decode(actualDiskBytes),
        equals('int compute(int x) {\n  final a = x + 10;\n  return a * 3;\n}\n'),
      );

      // Chained edit deleting a line (newBlock: "").
      final edit2 = await fsDriver.editBlock(
        path: 'lib/sample.dart',
        expectedSha256: sha2,
        oldBlock: '  final a = x + 10;\n',
        newBlock: '',
      );
      expect(edit2.ok, isTrue, reason: '${edit2.error}');
      expect(
        File(p.join(workspaceDir.path, 'lib', 'sample.dart')).readAsStringSync(),
        equals('int compute(int x) {\n  return a * 3;\n}\n'),
      );

      // CRLF file edited with LF blocks preserves CRLF on disk.
      final crlfRead = await fsDriver.readLines(path: '/workspace/lib/crlf.txt');
      expect(crlfRead.ok, isTrue);
      final crlfEdit = await fsDriver.editBlock(
        path: '/workspace/lib/crlf.txt',
        expectedSha256: crlfRead.value!['sha256'] as String,
        oldBlock: 'line1\nline2_target',
        newBlock: 'line1\nline2_updated',
      );
      expect(crlfEdit.ok, isTrue, reason: '${crlfEdit.error}');
      expect(
        File(p.join(workspaceDir.path, 'lib', 'crlf.txt')).readAsBytesSync(),
        equals(utf8.encode('line1\r\nline2_updated\r\nline3\r\n')),
      );
    });

    test('sys_edit_block rejects mismatch, missing/ambiguous block, binary, protected, and out-of-scope paths with zero file modifications', () async {
      final sampleFile = File(p.join(workspaceDir.path, 'lib', 'sample.dart'));
      final dupFile = File(p.join(workspaceDir.path, 'lib', 'dup.dart'));
      final binFile = File(p.join(workspaceDir.path, 'binary.bin'));

      final sampleOrigBytes = sampleFile.readAsBytesSync();
      final dupOrigBytes = dupFile.readAsBytesSync();
      final binOrigBytes = binFile.readAsBytesSync();
      final sampleSha = sha256.convert(sampleOrigBytes).toString();
      final dupSha = sha256.convert(dupOrigBytes).toString();
      final binSha = sha256.convert(binOrigBytes).toString();

      // 1. CAS hash mismatch -> ECONFLICT (CAS_HASH_MISMATCH).
      final wrongSha = '0' * 64;
      final mismatchRes = await fsDriver.editBlock(
        path: '/workspace/lib/sample.dart',
        expectedSha256: wrongSha,
        oldBlock: '  final a = x + 1;',
        newBlock: '  final a = x + 2;',
      );
      expect(mismatchRes.ok, isFalse);
      expect(mismatchRes.error!.code, equals(SyscallErrorCode.econflict));
      expect(mismatchRes.error!.reason, equals('CAS_HASH_MISMATCH'));
      expect(mismatchRes.error!.details!['actualSha256'], equals(sampleSha));
      expect(sampleFile.readAsBytesSync(), equals(sampleOrigBytes));

      // 2. Target block not found (0 matches) -> ECONFLICT (TARGET_BLOCK_NOT_FOUND).
      final notFoundBlockRes = await fsDriver.editBlock(
        path: '/workspace/lib/sample.dart',
        expectedSha256: sampleSha,
        oldBlock: 'NON_EXISTENT_BLOCK',
        newBlock: 'replacement',
      );
      expect(notFoundBlockRes.ok, isFalse);
      expect(notFoundBlockRes.error!.code, equals(SyscallErrorCode.econflict));
      expect(notFoundBlockRes.error!.reason, equals('TARGET_BLOCK_NOT_FOUND'));
      expect(sampleFile.readAsBytesSync(), equals(sampleOrigBytes));

      // 3. Ambiguous block match (>= 2 matches) -> ECONFLICT (AMBIGUOUS_BLOCK_MATCH).
      final ambiguousRes = await fsDriver.editBlock(
        path: '/workspace/lib/dup.dart',
        expectedSha256: dupSha,
        oldBlock: 'print(marker);',
        newBlock: 'print(0);',
      );
      expect(ambiguousRes.ok, isFalse);
      expect(ambiguousRes.error!.code, equals(SyscallErrorCode.econflict));
      expect(ambiguousRes.error!.reason, equals('AMBIGUOUS_BLOCK_MATCH'));
      expect(ambiguousRes.error!.details!['matchCount'], equals(2));
      expect(dupFile.readAsBytesSync(), equals(dupOrigBytes));

      // 4. Empty oldBlock & malformed sha256 -> EINVAL.
      final emptyOldRes = await fsDriver.editBlock(
        path: '/workspace/lib/sample.dart',
        expectedSha256: sampleSha,
        oldBlock: '',
        newBlock: 'x',
      );
      expect(emptyOldRes.ok, isFalse);
      expect(emptyOldRes.error!.code, equals(SyscallErrorCode.einval));

      final badShaRes = await fsDriver.editBlock(
        path: '/workspace/lib/sample.dart',
        expectedSha256: 'short-hex',
        oldBlock: 'x',
        newBlock: 'y',
      );
      expect(badShaRes.ok, isFalse);
      expect(badShaRes.error!.code, equals(SyscallErrorCode.einval));

      // 5. Missing file -> ENOENT; binary file -> EINVAL; directory -> EINVAL.
      final missingRes = await fsDriver.editBlock(
        path: '/workspace/lib/no_such_file.dart',
        expectedSha256: sampleSha,
        oldBlock: 'x',
        newBlock: 'y',
      );
      expect(missingRes.ok, isFalse);
      expect(missingRes.error!.code, equals(SyscallErrorCode.enoent));

      final binaryRes = await fsDriver.editBlock(
        path: '/workspace/binary.bin',
        expectedSha256: binSha,
        oldBlock: 'x',
        newBlock: 'y',
      );
      expect(binaryRes.ok, isFalse);
      expect(binaryRes.error!.code, equals(SyscallErrorCode.einval));
      expect(binaryRes.error!.reason, equals('BINARY_FILE'));
      expect(binFile.readAsBytesSync(), equals(binOrigBytes));

      final dirRes = await fsDriver.editBlock(
        path: '/workspace/lib',
        expectedSha256: sampleSha,
        oldBlock: 'x',
        newBlock: 'y',
      );
      expect(dirRes.ok, isFalse);
      expect(dirRes.error!.code, equals(SyscallErrorCode.einval));

      // 6. Protected paths and out-of-scope / symlink escape -> EACCES & untouched bytes.
      final protectedFiles = <String, File>{
        '/workspace/.jj/repo/cfg': File(p.join(workspaceDir.path, '.jj', 'repo', 'cfg')),
        '/workspace/.git/HEAD': File(p.join(workspaceDir.path, '.git', 'HEAD')),
        '/workspace/.agent_os/logs/audit.jsonl':
            File(p.join(workspaceDir.path, '.agent_os', 'logs', 'audit.jsonl')),
        '/workspace/.env': File(p.join(workspaceDir.path, '.env')),
        '/workspace/.env.prod': File(p.join(workspaceDir.path, '.env.prod')),
      };
      for (final entry in protectedFiles.entries) {
        final orig = entry.value.readAsBytesSync();
        final sha = sha256.convert(orig).toString();
        final res = await fsDriver.editBlock(
          path: entry.key,
          expectedSha256: sha,
          oldBlock: utf8.decode(orig).trim(),
          newBlock: 'HACKED',
        );
        expect(res.ok, isFalse, reason: '${entry.key} must be rejected');
        expect(res.error!.code, equals(SyscallErrorCode.eacces));
        expect(res.error!.reason, equals('PROTECTED_INTERNAL_PATH'));
        expect(entry.value.readAsBytesSync(), equals(orig));
      }

      // Junction/symlink escape check.
      final escapeLink = p.join(workspaceDir.path, 'escape_dir');
      if (Platform.isWindows) {
        final mk = Process.runSync(
          'cmd',
          <String>['/c', 'mklink', '/J', escapeLink, outsideDir.path],
        );
        expect(mk.exitCode, equals(0));
      } else {
        Link(escapeLink).createSync(outsideDir.path);
      }

      final outsideFile = File(p.join(outsideDir.path, 'outside.txt'));
      final outsideOrig = outsideFile.readAsBytesSync();
      final outsideSha = sha256.convert(outsideOrig).toString();
      for (final badPath in <String>[
        '../outside.txt',
        r'C:\Windows\win.ini',
        '/workspace/escape_dir/outside.txt',
      ]) {
        final res = await fsDriver.editBlock(
          path: badPath,
          expectedSha256: outsideSha,
          oldBlock: 'OUTSIDE_ORIGINAL',
          newBlock: 'TAMPERED',
        );
        expect(res.ok, isFalse);
        expect(res.error!.code, equals(SyscallErrorCode.eacces));
        expect(res.error!.reason, equals('OUT_OF_WORKSPACE_SCOPE'));
      }
      expect(outsideFile.readAsBytesSync(), equals(outsideOrig));
    });

    test('sys_write_file enforces OM-03 createOnly / EEXIST / CAS update / EACCES without modifying existing files on failure', () async {
      final sampleFile = File(p.join(workspaceDir.path, 'lib', 'sample.dart'));
      final sampleOrigBytes = sampleFile.readAsBytesSync();
      final sampleSha = sha256.convert(sampleOrigBytes).toString();

      // 1. Unread overwrite attempt (expectedSha256 omitted) on existing file -> EEXIST, untouched.
      final unreadOverwrite = await fsDriver.writeFile(
        path: '/workspace/lib/sample.dart',
        content: 'WIPED!',
      );
      expect(unreadOverwrite.ok, isFalse);
      expect(unreadOverwrite.error!.code, equals(SyscallErrorCode.eexist));
      expect(unreadOverwrite.error!.reason, equals('FILE_ALREADY_EXISTS_READ_FIRST'));
      expect(sampleFile.readAsBytesSync(), equals(sampleOrigBytes));

      // 2. createOnly: true on existing file (even with matching sha) -> EEXIST, untouched.
      final createOnlyExisting = await fsDriver.writeFile(
        path: '/workspace/lib/sample.dart',
        content: 'WIPED!',
        expectedSha256: sampleSha,
        createOnly: true,
      );
      expect(createOnlyExisting.ok, isFalse);
      expect(createOnlyExisting.error!.code, equals(SyscallErrorCode.eexist));
      expect(sampleFile.readAsBytesSync(), equals(sampleOrigBytes));

      // 3. New file creation in nested directory -> succeeds.
      final createNew = await fsDriver.writeFile(
        path: '/workspace/lib/nested/new_mod.dart',
        content: 'String hello() => "world";\n',
        createOnly: true,
      );
      expect(createNew.ok, isTrue, reason: '${createNew.error}');
      expect(createNew.value!['created'], isTrue);
      expect(createNew.value!['previousSha256'], isNull);
      final newModSha = createNew.value!['newSha256'] as String;
      expect(
        File(p.join(workspaceDir.path, 'lib', 'nested', 'new_mod.dart')).readAsStringSync(),
        equals('String hello() => "world";\n'),
      );

      // 4. CAS mismatch on existing update -> ECONFLICT, file untouched.
      final staleUpdate = await fsDriver.writeFile(
        path: '/workspace/lib/nested/new_mod.dart',
        content: 'stale overwrite',
        expectedSha256: 'a' * 64,
      );
      expect(staleUpdate.ok, isFalse);
      expect(staleUpdate.error!.code, equals(SyscallErrorCode.econflict));
      expect(staleUpdate.error!.reason, equals('CAS_HASH_MISMATCH'));
      expect(
        File(p.join(workspaceDir.path, 'lib', 'nested', 'new_mod.dart')).readAsStringSync(),
        equals('String hello() => "world";\n'),
      );

      // 5. Missing file with expectedSha256 != null -> ENOENT.
      final missingUpdate = await fsDriver.writeFile(
        path: '/workspace/lib/does_not_exist.dart',
        content: 'content',
        expectedSha256: newModSha,
      );
      expect(missingUpdate.ok, isFalse);
      expect(missingUpdate.error!.code, equals(SyscallErrorCode.enoent));

      // 6. Matching expectedSha256 update -> succeeds.
      final validUpdate = await fsDriver.writeFile(
        path: '/workspace/lib/nested/new_mod.dart',
        content: 'String hello() => "updated";\n',
        expectedSha256: newModSha,
      );
      expect(validUpdate.ok, isTrue, reason: '${validUpdate.error}');
      expect(validUpdate.value!['created'], isFalse);
      expect(validUpdate.value!['previousSha256'], equals(newModSha));
      expect(
        File(p.join(workspaceDir.path, 'lib', 'nested', 'new_mod.dart')).readAsStringSync(),
        equals('String hello() => "updated";\n'),
      );

      // 7. Protected path & out-of-scope creation/overwrite -> EACCES, zero disk changes.
      final envBytes = File(p.join(workspaceDir.path, '.env')).readAsBytesSync();
      final envSha = sha256.convert(envBytes).toString();
      final protectedWrite = await fsDriver.writeFile(
        path: '/workspace/.env',
        content: 'EVIL=1',
        expectedSha256: envSha,
      );
      expect(protectedWrite.ok, isFalse);
      expect(protectedWrite.error!.code, equals(SyscallErrorCode.eacces));
      expect(File(p.join(workspaceDir.path, '.env')).readAsBytesSync(), equals(envBytes));

      final protectedNew = await fsDriver.writeFile(
        path: '/workspace/.agent_os/injected.txt',
        content: 'evil',
      );
      expect(protectedNew.ok, isFalse);
      expect(protectedNew.error!.code, equals(SyscallErrorCode.eacces));
      expect(
        File(p.join(workspaceDir.path, '.agent_os', 'injected.txt')).existsSync(),
        isFalse,
      );

      final outWrite = await fsDriver.writeFile(
        path: '../evil.txt',
        content: 'evil',
      );
      expect(outWrite.ok, isFalse);
      expect(outWrite.error!.code, equals(SyscallErrorCode.eacces));
      expect(File(p.join(outsideDir.path, 'evil.txt')).existsSync(), isFalse);
    });
  });

  group('SyscallGate Integration: HostFsDriver CAS + JjDriver CoW [D-002], [D-003], [D-013], [D-015]', () {
    late Directory repoDir;
    late VfsNamespace namespace;
    late JjTxContext jjContext;
    late JjDriver jjDriver;
    late HostFsDriver fsDriver;
    late AuditLogger auditLogger;
    late SyscallGate gate;

    const sessionId = 'sess_wp6_cas_jj';
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
      expect(res.exitCode, equals(0));
      return (res.stdout as String).trim();
    }

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('wp6_cas_jj_');
      expect(runJjSync(<String>['git', 'init', '--colocate']).exitCode, equals(0));
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP6 Tester']);
      runJjSync(<String>['config', 'set', '--repo', 'user.email', 'wp6@example.com']);

      File(p.join(repoDir.path, 'main.dart')).writeAsStringSync('void main() {}\n');
      expect(runJjSync(<String>['describe', '-m', 'base']).exitCode, equals(0));
      expect(runJjSync(<String>['new', '-m', 'human edit']).exitCode, equals(0));
      File(p.join(repoDir.path, 'main.dart')).writeAsStringSync(
        'void main() {\n  print("human-wip");\n}\n',
      );

      namespace = VfsNamespace(workspaceHostRoot: repoDir.path);
      jjContext = JjTxContext();
      jjDriver = JjDriver(namespace: namespace, txContext: jjContext);
      fsDriver = HostFsDriver(
        namespace: namespace,
        ensureActiveTransaction: jjDriver.ensureActiveTransaction,
        syncWorkingCopySnapshot: jjDriver.syncWorkingCopySnapshot,
      );
      auditLogger = AuditLogger(
        workspaceHostRoot: repoDir.path,
        sessionId: sessionId,
      );

      final processTable = KernelProcessTable();
      final pcb = ProcessControlBlock(
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
            tools: <SyscallToolSchema>[
              ...HostFsDriver.allToolSchemas(),
              ...JjDriver.allToolSchemas(),
            ],
          ),
        ),
      );
      processTable.registerProcess(pcb);

      gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(workspaceHostRoot: repoDir.path),
        auditLogger: auditLogger,
        jjAuditInfoProvider: jjDriver.getAuditInfo,
      );
      fsDriver.registerAllSyscalls(gate);
      jjDriver.registerAllSyscalls(gate);
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test('CAS validation failure leaves TxState.readOnly and op_id invariant; valid edit triggers CoW split and snapshot sync', () async {
      final initialOpId = readHeadOpId();
      final humanBytes = File(p.join(repoDir.path, 'main.dart')).readAsBytesSync();

      // 1. Read-Only inspection does not mutate op_id.
      final readRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_read_lines',
          args: const <String, dynamic>{'path': '/workspace/main.dart'},
        ),
      );
      expect(readRes.ok, isTrue);
      expect(readHeadOpId(), equals(initialOpId));
      expect(jjContext.state, equals(TxState.readOnly));

      // 2. Failing CAS edit must NOT trigger ensureActiveTransaction or change op_id.
      final badEdit = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_edit_block',
          args: <String, dynamic>{
            'path': '/workspace/main.dart',
            'expectedSha256': 'f' * 64,
            'oldBlock': 'human-wip',
            'newBlock': 'agent-wip',
          },
        ),
      );
      expect(badEdit.ok, isFalse);
      expect(badEdit.error!.code, equals(SyscallErrorCode.econflict));
      expect(jjContext.state, equals(TxState.readOnly));
      expect(readHeadOpId(), equals(initialOpId));
      expect(File(p.join(repoDir.path, 'main.dart')).readAsBytesSync(), equals(humanBytes));

      // 3. Valid sys_edit_block triggers CoW split (@- preserves human-wip) & snapshot sync.
      final validEdit = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_edit_block',
          args: <String, dynamic>{
            'path': '/workspace/main.dart',
            'expectedSha256': readRes.value!['sha256'],
            'oldBlock': '  print("human-wip");',
            'newBlock': '  print("agent-edit");',
          },
        ),
      );
      expect(validEdit.ok, isTrue, reason: '${validEdit.error}');
      expect(jjContext.state, equals(TxState.active));

      // Immediate sys_jj_diff sees agent-edit on @ and zero agent edits on @-.
      final diffWorking = await gate.invoke(
        ctx,
        SyscallRequest(name: 'sys_jj_diff'),
      );
      expect(diffWorking.ok, isTrue);
      expect(diffWorking.value!['diff'], contains('agent-edit'));

      final parentContentRes = Process.runSync(
        'jj',
        <String>[
          '--no-pager',
          'file',
          'show',
          '-r',
          '@-',
          '--ignore-working-copy',
          'main.dart',
        ],
        workingDirectory: repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
        stdoutEncoding: null,
      );
      expect(parentContentRes.exitCode, equals(0));
      expect(parentContentRes.stdout as List<int>, equals(humanBytes));

      // 4. Valid sys_write_file new creation also syncs snapshot; syscalls.jsonl records latest jjOpId.
      final createRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_write_file',
          args: const <String, dynamic>{
            'path': '/workspace/extra.dart',
            'content': 'int extra() => 7;\n',
            'createOnly': true,
          },
        ),
      );
      expect(createRes.ok, isTrue, reason: '${createRes.error}');

      await auditLogger.flush();
      final records = File(auditLogger.syscallsLogPath)
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(records.last['syscallName'], equals('sys_write_file'));
      expect(records.last['ok'], isTrue);
      expect(records.last['jjOpId'], equals(jjContext.currentOpId));
      expect(records.last['jjChangeId'], equals(jjContext.workingChangeId));
    });
  });
}
