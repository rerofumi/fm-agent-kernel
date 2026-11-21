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

    test(
        'SysExecApprovalScope builds origin-scoped signature only for safe read-only curl/wget',
        () {
      final scope1 = SysExecApprovalScope.build(
        command: 'curl.exe',
        args: const <String>[
          '-sL',
          '-o',
          'research/a.json',
          'https://en.wikipedia.org/api/rest_v1/page/summary/Dart',
        ],
        workingDir: '/workspace',
      );
      final scope2 = SysExecApprovalScope.build(
        command: 'CURL.EXE',
        args: const <String>[
          '-sL',
          '-X',
          'get',
          '-o',
          'research/b.json',
          'https://en.wikipedia.org/wiki/Operating_system',
        ],
        workingDir: '/workspace',
      );
      expect(scope1.isOriginScoped, isTrue);
      expect(scope2.isOriginScoped, isTrue);
      expect(scope1.signature, equals(scope2.signature));
      expect(
        scope1.signature,
        equals('exec:net_read:curl\u0000https://en.wikipedia.org\u0000/workspace'),
      );
      expect(
        scope1.scopeDescription,
        equals('Read-only curl requests to https://en.wikipedia.org (in /workspace)'),
      );

      // Single-string args: null normalization also works.
      final scopeSingleStr = SysExecApprovalScope.build(
        command: 'curl -sL -XHEAD https://en.wikipedia.org/wiki/Plan_9',
      );
      expect(scopeSingleStr.isOriginScoped, isTrue);
      expect(scopeSingleStr.signature, equals(scope1.signature));

      // wget read-only also shares origin-scoped signature.
      final wget1 = SysExecApprovalScope.build(
        command: 'wget.exe',
        args: const <String>['--method=HEAD', '-O', 'a.html', 'https://example.org/a'],
      );
      final wget2 = SysExecApprovalScope.build(
        command: 'wget',
        args: const <String>['-O', 'b.html', 'https://example.org/b'],
      );
      expect(wget1.isOriginScoped, isTrue);
      expect(wget1.signature, equals(wget2.signature));

      // Different origin or workingDir produces different signature.
      final diffOrigin = SysExecApprovalScope.build(
        command: 'curl.exe',
        args: const <String>['https://example.com/a'],
      );
      final diffWd = SysExecApprovalScope.build(
        command: 'curl.exe',
        args: const <String>['https://en.wikipedia.org/a'],
        workingDir: '/workspace/sub',
      );
      expect(diffOrigin.isOriginScoped, isTrue);
      expect(diffOrigin.signature, isNot(equals(scope1.signature)));
      expect(diffWd.signature, isNot(equals(scope1.signature)));
    });

    test(
        'SysExecApprovalScope falls back to exact match on mutating flags, attached forms, shell meta, path-qualified exe, userInfo, multi-URL, and localhost/private IPs',
        () {
      final fallbackCases = <({String command, List<String>? args})>[
        // Shell metacharacters (with args and args: null)
        (
          command: 'curl.exe',
          args: const <String>['https://en.wikipedia.org/a', '|', 'findstr', 'x'],
        ),
        (
          command: 'curl.exe https://en.wikipedia.org/a && echo hi',
          args: null,
        ),
        // Path-qualified exe
        (
          command: r'C:\Windows\System32\curl.exe',
          args: const <String>['https://en.wikipedia.org/a'],
        ),
        (
          command: '/usr/bin/curl',
          args: const <String>['https://en.wikipedia.org/a'],
        ),
        // Mutating / upload / config / chaining curl options (including attached & = forms)
        (command: 'curl', args: const <String>['-d', 'x=1', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-dx=1', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--data=x=1', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--data-raw', 'x', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--json', '{}', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--json={}', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-F', 'f=@a', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-Ff=@a', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--form=f=a', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-T', 'a.txt', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-Ta.txt', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--upload-file=a.txt', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-K', 'cfg', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-Kcfg', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--config=cfg', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--next', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-:', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--url=https://example.com/a']),
        (command: 'curl', args: const <String>['--url', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-X', 'post', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-XPOST', 'https://example.com/a']),
        (command: 'curl', args: const <String>['--request=DELETE', 'https://example.com/a']),
        (command: 'curl', args: const <String>['https://example.com/a', '-X']),
        (command: 'curl', args: const <String>['-sXd', 'https://example.com/a']),
        (command: 'curl', args: const <String>['-sX', 'GET', 'https://example.com/a']),
        // wget mutating / input-file options
        (command: 'wget', args: const <String>['--post-data=a=1', 'https://example.com/a']),
        (command: 'wget', args: const <String>['--post-file=a.txt', 'https://example.com/a']),
        (command: 'wget', args: const <String>['--body-data=a', 'https://example.com/a']),
        (command: 'wget', args: const <String>['--body-file=a.txt', 'https://example.com/a']),
        (command: 'wget', args: const <String>['--method=POST', 'https://example.com/a']),
        (command: 'wget', args: const <String>['--method', 'PUT', 'https://example.com/a']),
        (command: 'wget', args: const <String>['https://example.com/a', '--method']),
        (command: 'wget', args: const <String>['-i', 'urls.txt']),
        (command: 'wget', args: const <String>['-qi', 'urls.txt']),
        (command: 'wget', args: const <String>['--input-file=urls.txt']),
        // Multiple URLs, zero URLs, userInfo, non-http scheme
        (command: 'curl', args: const <String>['https://example.com/a', 'https://example.com/b']),
        (command: 'curl', args: const <String>['--version']),
        (command: 'curl', args: const <String>['https://user:pass@example.com/a']),
        (command: 'curl', args: const <String>['ftp://example.com/a']),
        // Localhost, private, link-local, loopback IPv4 & IPv6
        (command: 'curl', args: const <String>['http://localhost/a']),
        (command: 'curl', args: const <String>['http://sub.localhost:8080/a']),
        (command: 'curl', args: const <String>['http://localhost./a']),
        (command: 'curl', args: const <String>['http://127.0.0.1:8080/a']),
        (command: 'curl', args: const <String>['http://127.1.2.3/a']),
        (command: 'curl', args: const <String>['http://10.0.0.5/a']),
        (command: 'curl', args: const <String>['http://172.16.0.1/a']),
        (command: 'curl', args: const <String>['http://192.168.1.10/a']),
        (command: 'curl', args: const <String>['http://169.254.169.254/latest']),
        (command: 'curl', args: const <String>['http://0.0.0.0/a']),
        (command: 'curl', args: const <String>['http://[::1]:8080/a']),
        (command: 'curl', args: const <String>['http://[::]/a']),
        (command: 'curl', args: const <String>['http://[fc00::1]/a']),
        (command: 'curl', args: const <String>['http://[fe80::1]/a']),
        (command: 'curl', args: const <String>['http://[::ffff:127.0.0.1]/a']),
        (command: 'curl', args: const <String>['http://[::ffff:192.168.1.1]/a']),
        // Non-network command
        (command: 'dart', args: const <String>['--version']),
      ];

      for (final c in fallbackCases) {
        final scope = SysExecApprovalScope.build(
          command: c.command,
          args: c.args,
        );
        expect(
          scope.isOriginScoped,
          isFalse,
          reason: 'Expected exact-match fallback for ${c.command} ${c.args}',
        );
        final expectedArgs = (c.args ?? const <String>[]).join('\u0000');
        expect(
          scope.signature,
          equals('${c.command}\u0000$expectedArgs\u0000/workspace'),
        );
        expect(scope.scopeDescription, equals('Exact command in /workspace'));
      }
    });

    test(
        'SysExecClassifier flags external network commands and ApprovalPreview includes scope & reason',
        () async {
      final classifier = SysExecClassifier(namespace: namespace);
      for (final exe in const <String>[
        'curl',
        'curl.exe',
        'wget',
        'wget.exe',
        'Invoke-WebRequest',
        'iwr',
        'Invoke-RestMethod',
        'irm',
      ]) {
        final cls = classifier.classify(
          command: exe,
          args: const <String>['https://en.wikipedia.org/wiki/Dart'],
        );
        expect(cls.decision, equals(RingDecision.askUser));
        expect(
          cls.reason,
          equals(
            'EXTERNAL_NETWORK_COMMAND: Direct network command via sys_exec (prefer delegating web lookup to web_researcher).',
          ),
        );
      }

      // Existing rules remain intact.
      expect(
        classifier.classify(command: 'dart', args: const <String>['test']).decision,
        equals(RingDecision.allow),
      );
      expect(
        classifier
            .classify(command: r'C:\Windows\System32\curl.exe', args: const <String>[])
            .reason,
        equals('EXECUTABLE_PATH_NOT_ALLOWLISTED'),
      );

      // ApprovalPreview through SyscallGate includes EXTERNAL_NETWORK_COMMAND and Session allow_always scope.
      final rejectHandler = PolicyApprovalHandler.alwaysReject();
      final gate = createGate(approvalHandler: rejectHandler);
      final denied = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'curl.exe',
            'args': <String>['-sL', '-o', 'out.json', 'https://en.wikipedia.org/wiki/Dart'],
          },
        ),
      );
      expect(denied.ok, isFalse);
      expect(rejectHandler.recordedRequests, hasLength(1));
      final approvalReq = rejectHandler.recordedRequests.single;
      final previewText =
          ((approvalReq.content.first['content'] as Map<String, dynamic>)['text'])
              as String;
      expect(previewText, contains('EXTERNAL_NETWORK_COMMAND'));
      expect(
        previewText,
        contains(
          'Session allow_always scope: Read-only curl requests to https://en.wikipedia.org (in /workspace)',
        ),
      );
      final def = execDriver.buildSyscallDefinition();
      final builtPreview = await def.approvalPreviewBuilder!(
        SyscallHookContext(
          pid: 1,
          ring: ProtectionRing.ring2,
          sessionId: sessionId,
          syscallName: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'curl.exe',
            'args': <String>['-sL', '-o', 'out.json', 'https://en.wikipedia.org/wiki/Dart'],
            'workingDir': '/workspace',
          },
          jjContext: jjContext,
        ),
      );
      expect(
        builtPreview!.metadata!['approvalScope'],
        equals('Read-only curl requests to https://en.wikipedia.org (in /workspace)'),
      );
    });
  });
}
