import 'dart:ffi';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Win32JobExecDriver & SysExecClassifier [D-016], [D-002], [D-006]', () {
    late Directory repoDir;
    late VfsNamespace namespace;
    late JjTxContext jjContext;
    late JjDriver jjDriver;
    late Win32JobExecDriver execDriver;
    late AuditLogger auditLogger;
    late KernelProcessTable processTable;
    late ProcessControlBlock pcb;

    const sessionId = 'sess_wp7_exec';
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
      expect(res.exitCode, equals(0), reason: 'jj op log failed: ${res.stderr}');
      return (res.stdout as String).trim();
    }

    String readChangeId(String rev) {
      final res = runJjSync(<String>[
        'log',
        '--no-graph',
        '-r',
        rev,
        '--ignore-working-copy',
        '-T',
        'change_id.short(12)',
      ]);
      expect(res.exitCode, equals(0), reason: 'jj log failed: ${res.stderr}');
      return (res.stdout as String).trim();
    }

    SyscallGate createGate({required ApprovalHandler approvalHandler}) {
      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: approvalHandler),
        ioCapper: IoPayloadCapper(workspaceHostRoot: repoDir.path),
        auditLogger: auditLogger,
        jjAuditInfoProvider: jjDriver.getAuditInfo,
      );
      execDriver.registerSyscalls(gate);
      jjDriver.registerAllSyscalls(gate);
      return gate;
    }

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('wp7_exec_');
      final initRes = runJjSync(<String>['git', 'init', '--colocate']);
      expect(initRes.exitCode, equals(0), reason: '${initRes.stderr}');
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP7 Tester']);
      runJjSync(
          <String>['config', 'set', '--repo', 'user.email', 'wp7@example.com']);

      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# WP7\n');
      expect(
        runJjSync(<String>['describe', '-m', 'human base']).exitCode,
        equals(0),
      );
      expect(
        runJjSync(<String>['new', '-m', 'human wip']).exitCode,
        equals(0),
      );
      File(p.join(repoDir.path, 'human.txt')).writeAsStringSync('human wip\n');

      namespace = VfsNamespace(workspaceHostRoot: repoDir.path);
      jjContext = JjTxContext();
      jjDriver = JjDriver(namespace: namespace, txContext: jjContext);
      auditLogger = AuditLogger(
        workspaceHostRoot: repoDir.path,
        sessionId: sessionId,
      );
      execDriver = Win32JobExecDriver(
        namespace: namespace,
        ensureActiveTransaction: jjDriver.ensureActiveTransaction,
        syncWorkingCopySnapshot: jjDriver.syncWorkingCopySnapshot,
        ioCapper: IoPayloadCapper(workspaceHostRoot: repoDir.path),
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
            instruction: 'Test instruction',
            tools: Win32JobExecDriver.toolSchemas(),
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

    test(
        '[E3] 144-byte JOBOBJECT_EXTENDED_LIMIT_INFORMATION layout sets offset 16 = 0x2000 with no BREAKAWAY_OK',
        () {
      expect(sizeOf<JobObjectBasicLimitInformation>(), equals(64));
      expect(sizeOf<IoCounters>(), equals(48));
      expect(sizeOf<JobObjectExtendedLimitInformation>(), equals(144));
      expect(Win32JobExecDriver.jobExtendedLimitInfoStructBytes, equals(144));
      expect(Win32JobExecDriver.jobLimitFlagsByteOffset, equals(16));
      expect(Win32JobExecDriver.killOnJobCloseFlag, equals(0x00002000));

      final ptr = calloc<JobObjectExtendedLimitInformation>();
      try {
        ptr.ref.basicLimitInformation.limitFlags =
            Win32JobExecDriver.killOnJobCloseFlag;
        final rawDwords = ptr.cast<Uint32>();
        expect(rawDwords[4], equals(0x00002000));
        expect(rawDwords[4] & 0x00000800, equals(0));
      } finally {
        calloc.free(ptr);
      }
    });

    test(
        'buildSanitizedEnvironment excludes OPENROUTER_API_KEY, OLLAMA_API_KEY, *_API_KEY, *_SECRET, *_TOKEN case-insensitively',
        () {
      final sanitized = Win32JobExecDriver.buildSanitizedEnvironment(
        const <String, String>{
          'PATH': r'C:\Windows\System32',
          'OLLAMA_HOST': 'http://192.168.0.5:11434/v1',
          'OPENROUTER_API_KEY': 'sk-or-secret',
          'OLLAMA_API_KEY': 'ollama-secret',
          'GEMINI_API_KEY': 'gemini-secret',
          'custom_api_key': 'lower-secret',
          'JWT_SECRET': 'jwt-secret',
          'github_token': 'ghp-secret',
          'DB_PASSWORD': 'db-secret',
          'SAFE_VAR': 'visible',
        },
      );

      expect(sanitized['PATH'], equals(r'C:\Windows\System32'));
      expect(sanitized['OLLAMA_HOST'], equals('http://192.168.0.5:11434/v1'));
      expect(sanitized['SAFE_VAR'], equals('visible'));
      expect(sanitized.containsKey('OPENROUTER_API_KEY'), isFalse);
      expect(sanitized.containsKey('OLLAMA_API_KEY'), isFalse);
      expect(sanitized.containsKey('GEMINI_API_KEY'), isFalse);
      expect(sanitized.containsKey('custom_api_key'), isFalse);
      expect(sanitized.containsKey('JWT_SECRET'), isFalse);
      expect(sanitized.containsKey('github_token'), isFalse);
      expect(sanitized.containsKey('DB_PASSWORD'), isFalse);
    });

    test('child process started by sys_exec receives no *_API_KEY/*_SECRET/*_TOKEN env vars',
        () async {
      final gate = createGate(
        approvalHandler: PolicyApprovalHandler.alwaysAllow(),
      );

      final res = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: <String, dynamic>{
            'command': 'powershell.exe',
            'args': <String>[
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              r"Get-ChildItem Env: | Where-Object { $_.Name -match '^(OPENROUTER_API_KEY|OLLAMA_API_KEY|.*_(API_KEY|SECRET|TOKEN|PASSWORD))$' } | ForEach-Object { $_.Name }",
            ],
          },
        ),
      );

      expect(res.ok, isTrue, reason: '${res.error}');
      expect(res.value!['exitCode'], equals(0));
      expect((res.value!['stdout'] as String).trim(), isEmpty);
    });

    test('SysExecCommandNormalizer splits single-string args: null commands with quote awareness',
        () {
      final n1 = SysExecCommandNormalizer.normalize(
        command: 'dart test "test/my test.dart" --name \'hello world\'',
        args: null,
      );
      expect(n1.command, equals('dart'));
      expect(
        n1.args,
        equals(<String>['test', 'test/my test.dart', '--name', 'hello world']),
      );
      expect(n1.hadShellMeta, isFalse);
      expect(n1.wasSplitFromSingleString, isTrue);

      final n2 = SysExecCommandNormalizer.normalize(
        command: 'echo ok && git diff',
        args: null,
      );
      expect(n2.command, equals('echo ok && git diff'));
      expect(n2.args, isEmpty);
      expect(n2.hadShellMeta, isTrue);

      expect(
        () => SysExecCommandNormalizer.splitQuotedCommand('dart test "unclosed'),
        throwsFormatException,
      );
    });

    test('SysExecClassifier strictly enforces all 5 immediate-allow conditions (40 §2.3)',
        () {
      final classifier = SysExecClassifier(namespace: namespace);

      // Allowed cases
      expect(
        classifier
            .classify(command: 'dart', args: const <String>['test']).decision,
        equals(RingDecision.allow),
      );
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>[
            'test',
            '-r',
            'expanded',
            '--concurrency=4',
            '--fail-fast',
            '/workspace/test/foo_test.dart',
          ],
          timeoutMs: 120000,
        ).decision,
        equals(RingDecision.allow),
      );
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['analyze', '--fatal-warnings', 'lib'],
        ).decision,
        equals(RingDecision.allow),
      );
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>[
            'format',
            '--output=none',
            '--set-exit-if-changed',
            'lib',
          ],
        ).decision,
        equals(RingDecision.allow),
      );

      // Rejected to ASK_USER
      // Cond 1: metacharacters
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['test', '&&', 'echo'],
        ).decision,
        equals(RingDecision.askUser),
      );
      // Cond 2: shell wrapper or non-dart executable
      expect(
        classifier.classify(
          command: 'powershell',
          args: const <String>['-Command', 'dart test'],
        ).decision,
        equals(RingDecision.askUser),
      );
      expect(
        classifier.classify(
          command: 'python',
          args: const <String>['script.py'],
        ).decision,
        equals(RingDecision.askUser),
      );
      // Cond 3: traversal / external / protected path in args
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['test', '../outside.dart'],
        ).decision,
        equals(RingDecision.askUser),
      );
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['analyze', r'C:\Windows'],
        ).decision,
        equals(RingDecision.askUser),
      );
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['analyze', '.env'],
        ).decision,
        equals(RingDecision.askUser),
      );
      // Cond 4: unsafe dart subcommands / options
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['format', 'lib'],
        ).decision,
        equals(RingDecision.askUser),
      );
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['format', '--output=write', 'lib'],
        ).decision,
        equals(RingDecision.askUser),
      );
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['pub', 'get'],
        ).decision,
        equals(RingDecision.askUser),
      );
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['test', '--concurrency=9'],
        ).decision,
        equals(RingDecision.askUser),
      );
      // Cond 5: timeout > 120000
      expect(
        classifier.classify(
          command: 'dart',
          args: const <String>['test'],
          timeoutMs: 120001,
        ).decision,
        equals(RingDecision.askUser),
      );
    });

    test('handles ultra-short-lived process exit without Job Object assignment race errors',
        () async {
      final gate = createGate(
        approvalHandler: PolicyApprovalHandler.alwaysAllow(),
      );

      for (var i = 0; i < 6; i++) {
        final res = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_exec',
            args: <String, dynamic>{
              'command': 'cmd.exe',
              'args': const <String>['/c', 'exit', '0'],
            },
          ),
        );
        expect(res.ok, isTrue, reason: 'iteration $i failed: ${res.error}');
        expect(res.value!['exitCode'], equals(0));
      }
    });

    test(
        'terminates grandchild process tree on timeout with 0 surviving OS PIDs and returns ETIMEDOUT',
        () async {
      final gate = createGate(
        approvalHandler: PolicyApprovalHandler.alwaysAllow(),
      );
      final k32 = Win32Kernel32();

      const psScript = r'''
$p = Start-Process -FilePath "ping.exe" -ArgumentList "-n","60","127.0.0.1" -WindowStyle Hidden -PassThru
Write-Output ("GRANDCHILD_PID=" + $p.Id)
[Console]::Out.Flush()
Start-Sleep -Seconds 60
''';

      final res = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: <String, dynamic>{
            'command': 'powershell.exe',
            'args': <String>[
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              psScript,
            ],
            'timeoutMs': 1500,
          },
        ),
      );

      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.etimedout));
      expect(res.error!.reason, equals('EXEC_TIMEOUT'));

      final details = res.error!.details!;
      expect(details['timedOut'], isTrue);
      final stdoutText = details['stdout'] as String;
      final match = RegExp(r'GRANDCHILD_PID=(\d+)').firstMatch(stdoutText);
      expect(match, isNotNull, reason: 'stdout was: $stdoutText');
      final grandchildPid = int.parse(match!.group(1)!);

      // Verify OS kernel reports 0 surviving grandchild processes.
      expect(k32.isProcessAlive(grandchildPid), isFalse);
    });

    test('terminates grandchild process tree on CancellationToken cancellation',
        () async {
      final gate = createGate(
        approvalHandler: PolicyApprovalHandler.alwaysAllow(),
      );
      final k32 = Win32Kernel32();
      final pidFile = File(p.join(repoDir.path, 'grandchild_pid.txt'));
      final cancelSource = CancellationTokenSource();

      final psScript = '''
\$p = Start-Process -FilePath "ping.exe" -ArgumentList "-n","60","127.0.0.1" -WindowStyle Hidden -PassThru
Set-Content -Path "${pidFile.path.replaceAll('\\', '\\\\')}" -Value \$p.Id
Start-Sleep -Seconds 60
''';

      final future = gate.invoke(
        SyscallContext(
          pid: 1,
          capHandle: capHandle,
          sessionId: sessionId,
          cancelToken: cancelSource.token,
        ),
        SyscallRequest(
          name: 'sys_exec',
          args: <String, dynamic>{
            'command': 'powershell.exe',
            'args': <String>[
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              psScript,
            ],
            'timeoutMs': 30000,
          },
        ),
      );

      // Wait until the grandchild PID file appears, then cancel.
      var grandchildPid = 0;
      for (var i = 0; i < 50; i++) {
        if (pidFile.existsSync()) {
          final parsed = int.tryParse(pidFile.readAsStringSync().trim());
          if (parsed != null && parsed > 0) {
            grandchildPid = parsed;
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(grandchildPid, greaterThan(0));
      expect(k32.isProcessAlive(grandchildPid), isTrue);

      cancelSource.cancel('user_cancelled');
      final res = await future;
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.ecancelled));
      expect(k32.isProcessAlive(grandchildPid), isFalse);
    });

    test(
        'Stage 2/4 rejection leaves jj op_id untouched; Stage 5 isolates @, leaves @- intact, and syncs snapshot',
        () async {
      final rejectHandler = PolicyApprovalHandler.alwaysReject();
      final gateReject = createGate(approvalHandler: rejectHandler);

      final opBefore = readHeadOpId();
      final humanChangeBefore = readChangeId('@');

      // Rejected out-of-workspace workingDir at Stage 2 (no approval prompt, no jj tx).
      final badWd = await gateReject.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: <String, dynamic>{
            'command': 'dart',
            'args': const <String>['analyze'],
            'workingDir': r'C:\Windows',
          },
        ),
      );
      expect(badWd.ok, isFalse);
      expect(badWd.error!.code, equals(SyscallErrorCode.eacces));
      expect(rejectHandler.recordedRequests, isEmpty);
      expect(readHeadOpId(), equals(opBefore));
      expect(jjContext.state, equals(TxState.readOnly));

      // User-rejected non-allowlisted command at Stage 4 (no side effects, no jj tx).
      final deniedExec = await gateReject.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: <String, dynamic>{
            'command': 'powershell.exe',
            'args': const <String>['-NoProfile', '-Command', 'Write-Output hi'],
          },
        ),
      );
      expect(deniedExec.ok, isFalse);
      expect(deniedExec.error!.code, equals(SyscallErrorCode.eacces));
      expect(deniedExec.error!.reason, equals('DENIED_BY_USER'));
      expect(rejectHandler.recordedRequests, hasLength(1));
      expect(readHeadOpId(), equals(opBefore));
      expect(jjContext.state, equals(TxState.readOnly));

      // Approved command creates file -> isolated in @, @- untouched, snapshot synced.
      final gateAllow = createGate(
        approvalHandler: PolicyApprovalHandler.alwaysAllow(),
      );
      final okExec = await gateAllow.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: <String, dynamic>{
            'command': 'powershell.exe',
            'args': const <String>[
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              "Set-Content -Path 'created_by_exec.txt' -Value 'hello'",
            ],
          },
        ),
      );
      expect(okExec.ok, isTrue, reason: '${okExec.error}');
      expect(jjContext.state, equals(TxState.active));
      expect(readChangeId('@-'), equals(humanChangeBefore));
      expect(readChangeId('@'), isNot(equals(humanChangeBefore)));
      final humanFileAtParent = runJjSync(<String>[
        'file',
        'show',
        '-r',
        '@-',
        '--ignore-working-copy',
        'human.txt',
      ]);
      expect(humanFileAtParent.exitCode, equals(0));
      expect(humanFileAtParent.stdout, equals('human wip\n'));

      final statusRes = await gateAllow.invoke(
        ctx,
        SyscallRequest(name: 'sys_jj_status'),
      );
      expect(statusRes.ok, isTrue);
      expect(
        statusRes.value!['summary'] as String,
        contains('created_by_exec.txt'),
      );
    });

    test('IoPayloadCapper caps large sys_exec stdout while preserving exitCode and timedOut',
        () async {
      final gate = createGate(
        approvalHandler: PolicyApprovalHandler.alwaysAllow(),
      );

      final res = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'powershell.exe',
            'args': <String>[
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              '1..450 | ForEach-Object { "LINE_\$_" }',
            ],
          },
        ),
      );

      expect(res.ok, isTrue, reason: '${res.error}');
      expect(res.value!['exitCode'], equals(0));
      expect(res.value!['timedOut'], isFalse);
      expect(res.value!['truncated'], isTrue);
      expect(res.value!['truncatedStdout'], isTrue);
      expect(res.value!['truncatedStderr'], isFalse);
      expect(res.value!['stdout'] as String, contains('KERNEL I/O CAP'));
    });
  });
}
