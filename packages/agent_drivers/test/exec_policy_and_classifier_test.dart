import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ExecPolicyConfigLoader [D-506]', () {
    late Directory tempRoot;
    late Directory sessionDir;
    late Directory currentDir;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('exec_policy_loader_');
      sessionDir = Directory(p.join(tempRoot.path, 'session'))..createSync();
      currentDir = Directory(p.join(tempRoot.path, 'cwd'))..createSync();
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    void writePolicy(Directory dir, String content) {
      final agentOsDir = Directory(p.join(dir.path, '.agent_os'))..createSync();
      File(p.join(agentOsDir.path, 'exec_policy.json')).writeAsStringSync(
        content,
      );
    }

    test('resolves sessionCwd before currentDirectoryPath and defaults when absent', () {
      final absent = ExecPolicyConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();
      expect(absent.loadedFromFile, isFalse);
      expect(absent.sourcePath, isNull);
      expect(absent.warnings, isEmpty);
      expect(absent.config.allow, isEmpty);
      expect(absent.config.toPromptRuleSummaries(), isEmpty);

      writePolicy(
        currentDir,
        '{"allow":[{"command":"cargo","maxTimeoutMs":300000}]}',
      );
      final fromCwd = ExecPolicyConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();
      expect(fromCwd.loadedFromFile, isTrue);
      expect(
        fromCwd.sourcePath,
        equals(p.normalize(p.join(currentDir.path, '.agent_os', 'exec_policy.json'))),
      );
      expect(fromCwd.warnings, isEmpty);
      expect(fromCwd.config.allow.map((r) => r.normalizedCommand), equals(['cargo']));

      writePolicy(
        sessionDir,
        '{"allow":[{"command":"v.exe","allowedSubcommands":["test","check-md"],"maxTimeoutMs":180000}]}',
      );
      final fromSession = ExecPolicyConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();
      expect(fromSession.loadedFromFile, isTrue);
      expect(
        fromSession.sourcePath,
        equals(p.normalize(p.join(sessionDir.path, '.agent_os', 'exec_policy.json'))),
      );
      expect(fromSession.warnings, isEmpty);
      expect(fromSession.config.allow.map((r) => r.normalizedCommand), equals(['v']));
    });

    test('fails closed without falling back to cwd when sessionCwd file has invalid JSON', () {
      writePolicy(
        currentDir,
        '{"allow":[{"command":"cargo"}]}',
      );
      writePolicy(sessionDir, '{ invalid json');

      final res = ExecPolicyConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();
      expect(res.loadedFromFile, isTrue);
      expect(res.hasWarnings, isTrue);
      expect(res.config.allow, isEmpty);
    });

    test('rejects root non-map, non-list allow, unknown keys, empty arrays, and out-of-range timeouts fail-closed', () {
      final nonMap = ExecPolicyConfig.parseJsonString('[]');
      expect(nonMap.hasWarnings, isTrue);
      expect(nonMap.config.allow, isEmpty);

      final nonListAllow = ExecPolicyConfig.parseJsonString('{"allow":{}}');
      expect(nonListAllow.hasWarnings, isTrue);
      expect(nonListAllow.config.allow, isEmpty);

      final mixedRules = ExecPolicyConfig.parseJsonString('''
{
  "extraRoot": true,
  "allow": [
    "not-an-object",
    {"command": "v", "subcommands": ["test"]},
    {"command": "v", "allowedSubcommands": []},
    {"command": "v", "allowedArgPrefixes": []},
    {"command": "v", "allowedArgPrefixes": [[]]},
    {"command": "v", "allowedArgPrefixes": [[""]]},
    {"command": "v", "allowedSubcommands": ["test;rm"]},
    {"command": "v", "maxTimeoutMs": 99},
    {"command": "v", "maxTimeoutMs": 600001},
    {"command": "v", "maxTimeoutMs": "120000"},
    {"command": "C:\\\\tools\\\\v.exe"},
    {"command": "./v"},
    {"command": "v test"},
    {"command": "v;echo"},
    {"command": "v", "allowedSubcommands": ["test", "fmt"], "allowedArgPrefixes": [["fmt"], ["check-md"]], "maxTimeoutMs": 180000},
    {"command": "mise", "allowedArgPrefixes": [["exec", "--"], ["run"]], "maxTimeoutMs": 300000},
    {"command": "cargo", "maxTimeoutMs": 300000}
  ]
}
''');

      expect(mixedRules.hasWarnings, isTrue);
      expect(mixedRules.warnings.length, greaterThanOrEqualTo(14));
      expect(mixedRules.config.allow, hasLength(3));
      expect(
        mixedRules.config.toPromptRuleSummaries(),
        equals(<String>[
          '`v` (allowed prefixes: `test`, `fmt`, `check-md`; maxTimeoutMs: 180000)',
          '`mise` (allowed prefixes: `exec --`, `run`; maxTimeoutMs: 300000)',
          '`cargo` (any safe workspace args; maxTimeoutMs: 300000)',
        ]),
      );
    });

    test('strips forbidden shell wrappers (10), raw VCS (2), and network commands (6) with warnings', () {
      final forbiddenVariants = <String>[
        'cmd',
        'CMD.EXE',
        'powershell',
        'PowerShell.exe',
        'pwsh.exe',
        'sh',
        'bash.cmd',
        'wsl',
        'zsh',
        'fish',
        'ash',
        'dash.ps1',
        'git',
        'git.exe',
        'jj',
        'JJ.EXE',
        'curl',
        'curl.exe',
        'wget',
        'Invoke-WebRequest',
        'iwr',
        'Invoke-RestMethod',
        'irm',
      ];

      final jsonRules = forbiddenVariants
          .map((c) => '{"command":"$c"}')
          .join(',');
      final res = ExecPolicyConfig.parseJsonString('{"allow":[$jsonRules]}');

      expect(res.config.allow, isEmpty);
      expect(res.warnings, hasLength(forbiddenVariants.length));
    });
  });

  group('SysExecClassifier, AntiGitHabitGuardHook & Win32JobExecDriver [D-507], [D-508], [D-509]', () {
    late Directory repoDir;
    late Directory outsideDir;
    late VfsNamespace namespace;
    late ExecPolicyConfig samplePolicy;

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('exec_classifier_repo_');
      outsideDir = Directory.systemTemp.createTempSync('exec_classifier_out_');
      Directory(p.join(repoDir.path, 'src')).createSync();
      Directory(p.join(repoDir.path, 'pkg_a')).createSync();
      Directory(p.join(repoDir.path, 'pkg_b')).createSync();
      Directory(p.join(repoDir.path, '.agent_os')).createSync();
      File(p.join(repoDir.path, 'src', 'foo_test.v')).writeAsStringSync('// v\n');
      File(p.join(repoDir.path, 'pkg_a', 'a.v')).writeAsStringSync('// a\n');
      File(p.join(repoDir.path, 'pkg_b', 'b.v')).writeAsStringSync('// b\n');
      File(p.join(repoDir.path, '.env')).writeAsStringSync('SECRET=1\n');
      File(p.join(repoDir.path, '.agent_os', 'exec_policy.json'))
          .writeAsStringSync('{"allow":[]}\n');
      File(p.join(outsideDir.path, 'secret.txt')).writeAsStringSync('outside\n');

      namespace = VfsNamespace(workspaceHostRoot: repoDir.path);
      samplePolicy = ExecPolicyConfig.parseJsonString('''
{
  "allow": [
    {"command": "v", "allowedSubcommands": ["test", "check-md", "build"], "maxTimeoutMs": 180000},
    {"command": "mise", "allowedArgPrefixes": [["exec", "--"], ["run"]], "maxTimeoutMs": 300000},
    {"command": "cargo", "maxTimeoutMs": 300000},
    {"command": "where"},
    {"command": "dart", "allowedSubcommands": ["compile"], "maxTimeoutMs": 300000}
  ]
}
''').config;
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
      if (outsideDir.existsSync()) {
        outsideDir.deleteSync(recursive: true);
      }
    });

    test('allows configured custom commands and built-in dart rules while preserving dart failure codes', () {
      final classifier = SysExecClassifier(
        namespace: namespace,
        policy: samplePolicy,
      );

      // Custom allowlisted commands
      final vOk = classifier.classify(
        command: 'v',
        args: const <String>['test', '/workspace/src/foo_test.v'],
        timeoutMs: 180000,
      );
      expect(vOk.decision, equals(RingDecision.allow));
      expect(vOk.reason, equals('ALLOWLISTED_BY_EXEC_POLICY'));

      final vEqOk = classifier.classify(
        command: 'v.exe',
        args: const <String>['build', '--out=/workspace/bin/app.exe'],
      );
      expect(vEqOk.decision, equals(RingDecision.allow));

      final miseOk = classifier.classify(
        command: 'mise',
        args: const <String>['exec', '--', 'v', 'test'],
        timeoutMs: 250000,
      );
      expect(miseOk.decision, equals(RingDecision.allow));

      final cargoAnyArgs = classifier.classify(
        command: 'cargo',
        args: const <String>['check', '--workspace'],
        timeoutMs: 300000,
      );
      expect(cargoAnyArgs.decision, equals(RingDecision.allow));

      final whereNoArgs = classifier.classify(
        command: 'where',
        args: const <String>[],
      );
      expect(whereNoArgs.decision, equals(RingDecision.allow));

      // Built-in dart still uses 120000 limit and preserves original reason codes
      final dartBuiltin = classifier.classify(
        command: 'dart',
        args: const <String>['test', 'src/foo_test.v'],
        timeoutMs: 120000,
      );
      expect(dartBuiltin.decision, equals(RingDecision.allow));
      expect(dartBuiltin.reason, equals('ALLOWLISTED_DART_TEST'));

      final dartOverBuiltinTimeout = classifier.classify(
        command: 'dart',
        args: const <String>['test'],
        timeoutMs: 120001,
      );
      expect(dartOverBuiltinTimeout.decision, equals(RingDecision.askUser));
      expect(
        dartOverBuiltinTimeout.reason,
        equals('TIMEOUT_EXCEEDS_AUTO_ALLOW_LIMIT'),
      );

      final dartFormatNoOutputNone = classifier.classify(
        command: 'dart',
        args: const <String>['format', 'src'],
      );
      expect(dartFormatNoOutputNone.decision, equals(RingDecision.askUser));
      expect(
        dartFormatNoOutputNone.reason,
        equals('DART_FORMAT_WITHOUT_OUTPUT_NONE'),
      );

      // Additional dart subcommand enabled via exec_policy.json
      final dartCustom = classifier.classify(
        command: 'dart',
        args: const <String>['compile', 'exe', 'bin/app.dart'],
        timeoutMs: 240000,
      );
      expect(dartCustom.decision, equals(RingDecision.allow));
      expect(dartCustom.reason, equals('ALLOWLISTED_BY_EXEC_POLICY'));
    });

    test('enforces common hard guards even when policy programmatically contains forbidden commands', () {
      // Programmatically inject forbidden names to verify SysExecClassifier defense-in-depth.
      final adversarialPolicy = ExecPolicyConfig(
        allow: <ExecAllowRule>[
          for (final cmd in ExecPolicyConfig.forbiddenCommands)
            ExecAllowRule(command: cmd, maxTimeoutMs: 600000),
          ExecAllowRule(
            command: 'v',
            argPrefixes: const <List<String>>[
              <String>['test'],
              <String>['build'],
            ],
            maxTimeoutMs: 180000,
          ),
          ExecAllowRule(
            command: 'mise',
            argPrefixes: const <List<String>>[
              <String>['exec', '--'],
            ],
            maxTimeoutMs: 300000,
          ),
        ],
      );
      final classifier = SysExecClassifier(
        namespace: namespace,
        policy: adversarialPolicy,
      );

      // Shells, raw VCS, network commands
      for (final shell in ExecPolicyConfig.shellWrappers) {
        final r = classifier.classify(command: shell, args: const <String>['-c', 'echo']);
        expect(r.decision, equals(RingDecision.askUser), reason: shell);
        expect(r.reason, equals('SHELL_WRAPPER_NOT_ALLOWLISTED'));
      }
      for (final vcs in ExecPolicyConfig.blockedVcsCommands) {
        final r = classifier.classify(command: vcs, args: const <String>['status']);
        expect(r.decision, equals(RingDecision.askUser), reason: vcs);
        expect(r.reason, equals('VCS_COMMAND_NOT_ALLOWLISTED'));
      }
      for (final net in ExecPolicyConfig.externalNetworkCommands) {
        final r = classifier.classify(command: net, args: const <String>['https://example.com']);
        expect(r.decision, equals(RingDecision.askUser), reason: net);
        expect(r.reason, startsWith('EXTERNAL_NETWORK_COMMAND'));
      }

      // Path-qualified executable & drive letter in command
      for (final badCmd in const <String>[r'C:\tools\v.exe', './v', 'bin/v', 'C:v']) {
        final r = classifier.classify(command: badCmd, args: const <String>['test']);
        expect(r.decision, equals(RingDecision.askUser), reason: badCmd);
        expect(r.reason, equals('EXECUTABLE_PATH_NOT_ALLOWLISTED'));
      }

      // Shell metacharacters
      for (final metaArgs in const <List<String>>[
        <String>['test', ';', 'echo'],
        <String>['test', '&&', 'echo'],
        <String>['test', '|', 'findstr'],
        <String>['test', r'$(whoami)'],
        <String>['test', '%PATH%'],
        <String>['test\necho'],
        <String>['test\x00'],
      ]) {
        final r = classifier.classify(command: 'v', args: metaArgs);
        expect(r.decision, equals(RingDecision.askUser), reason: '$metaArgs');
        expect(r.reason, equals('SHELL_METACHARS_PRESENT'));
      }

      // Wrapper targets after `--`
      for (final wrapped in const <String>[
        'powershell',
        'cmd.exe',
        'git',
        'jj.exe',
        'curl',
        'iwr',
        '/bin/bash',
        r'C:\Git\bin\git.exe',
      ]) {
        final r = classifier.classify(
          command: 'mise',
          args: <String>['exec', '--', wrapped, 'status'],
        );
        expect(r.decision, equals(RingDecision.askUser), reason: wrapped);
        expect(r.reason, equals('WRAPPER_TARGET_NOT_ALLOWLISTED'));
      }

      // Whitespace-only arg, out-of-workspace, protected paths, attached short-option paths
      final badCustomCases = <List<String>>[
        const <String>['test', '   '],
        const <String>['test', '../outside'],
        const <String>['test', r'C:\Windows'],
        const <String>['test', r'\\server\share\file'],
        const <String>['test', 'https://example.com/script.v'],
        const <String>['test', '/etc/passwd'],
        const <String>['test', '/workspace/.agent_os/exec_policy.json'],
        const <String>['test', '.agent_os/exec_policy.json'],
        const <String>['test', '.env'],
        const <String>['test', '.jj/repo'],
        const <String>['test', '.git/config'],
        const <String>['build', r'-oC:\Users\Public\out.exe'],
        const <String>['build', '-C../outside'],
        const <String>['build', '-f.env'],
        const <String>['build', '-f.agent_os/exec_policy.json'],
        const <String>['build', '-o/workspace/out.exe'],
        const <String>['build', r'-I\\server\share'],
        const <String>['build', '-I/outside'],
        const <String>['build', r'--out:C:\foo'],
        const <String>['build', '--out=/workspace/.env'],
        const <String>['build', '--out=../outside'],
        const <String>['build', '--out='],
        const <String>['build', '-=foo'],
      ];

      for (final badArgs in badCustomCases) {
        final r = classifier.classify(command: 'v', args: badArgs);
        expect(
          r.decision,
          equals(RingDecision.askUser),
          reason: 'Expected askUser for v $badArgs, got ${r.decision} (${r.reason})',
        );
      }

      // Disallowed subcommand & timeout exceeding rule maxTimeoutMs
      expect(
        classifier.classify(
          command: 'v',
          args: const <String>['install', 'foo'],
        ).reason,
        equals('NON_ALLOWLISTED_SUBCOMMAND'),
      );
      expect(
        classifier.classify(
          command: 'v',
          args: const <String>['test'],
          timeoutMs: 180001,
        ).reason,
        equals('TIMEOUT_EXCEEDS_AUTO_ALLOW_LIMIT'),
      );
    });

    test('propagates policy through namespaceOverride and enforces allowedWorkspaceSubpaths & symlinks', () {
      final singleSubpathRes = namespace.deriveForChild(
        allowedSubpaths: const <String>['/workspace/pkg_a'],
      );
      expect(singleSubpathRes.ok, isTrue);
      final singleSubNs = singleSubpathRes.value!;

      final multiSubpathRes = namespace.deriveForChild(
        allowedSubpaths: const <String>['/workspace/pkg_a', '/workspace/pkg_b'],
      );
      expect(multiSubpathRes.ok, isTrue);
      final multiSubNs = multiSubpathRes.value!;

      final classifier = SysExecClassifier(
        namespace: namespace,
        policy: samplePolicy,
      );

      // namespaceOverride must retain `policy`
      final allowedInSub = classifier.classify(
        command: 'v',
        args: const <String>['test', 'a.v'],
        workingDir: '/workspace/pkg_a',
        namespaceOverride: singleSubNs,
      );
      expect(allowedInSub.decision, equals(RingDecision.allow));

      // Accessing pkg_b when restricted to pkg_a must be rejected
      final blockedOtherSub = classifier.classify(
        command: 'v',
        args: const <String>['test', '/workspace/pkg_b/b.v'],
        workingDir: '/workspace/pkg_a',
        namespaceOverride: singleSubNs,
      );
      expect(blockedOtherSub.decision, equals(RingDecision.askUser));

      // Multi-subpath namespace allows virtual path into pkg_b from workingDir pkg_a
      final allowedMultiSub = classifier.classify(
        command: 'v',
        args: const <String>['test', '/workspace/pkg_b/b.v'],
        workingDir: '/workspace/pkg_a',
        namespaceOverride: multiSubNs,
      );
      expect(allowedMultiSub.decision, equals(RingDecision.allow));
    });

    test('resolveHostCommandArg handles standalone and --key=/workspace/... forms', () {
      final subHostDir = p.join(repoDir.path, 'src');

      expect(
        SysExecClassifier.resolveHostCommandArg(
          namespace,
          repoDir.path,
          '/workspace',
        ),
        equals('.'),
      );
      expect(
        SysExecClassifier.resolveHostCommandArg(
          namespace,
          repoDir.path,
          '/workspace/src/foo_test.v',
        ),
        equals('src/foo_test.v'),
      );
      expect(
        SysExecClassifier.resolveHostCommandArg(
          namespace,
          subHostDir,
          '/workspace/pkg_a/a.v',
        ),
        equals('../pkg_a/a.v'),
      );
      expect(
        SysExecClassifier.resolveHostCommandArg(
          namespace,
          repoDir.path,
          '--out=/workspace/bin/app.exe',
        ),
        equals('--out=bin/app.exe'),
      );
      expect(
        SysExecClassifier.resolveHostCommandArg(
          namespace,
          repoDir.path,
          '-o=/workspace/out',
        ),
        equals('-o=out'),
      );
      expect(
        SysExecClassifier.resolveHostCommandArg(
          namespace,
          repoDir.path,
          '/workspace/.agent_os/exec_policy.json',
        ),
        equals('/workspace/.agent_os/exec_policy.json'),
      );
    });

    test('AntiGitHabitGuardHook blocks -- wrapped git/jj at Stage 3 without triggering approval', () async {
      final auditLogger = AuditLogger(
        workspaceHostRoot: repoDir.path,
        sessionId: 'sess_exec_policy_hook',
      );
      final processTable = KernelProcessTable();
      const capHandle = CapHandle('cap_hook_test');
      const ctx = SyscallContext(
        pid: 1,
        capHandle: capHandle,
        sessionId: 'sess_exec_policy_hook',
      );
      processTable.registerProcess(
        ProcessControlBlock(
          pid: 1,
          name: 'lead-agent',
          ring: ProtectionRing.ring2,
          state: ProcessState.running,
          cspace: CapabilityTable.stage1LeadAgent(handle: capHandle),
          quota: ResourceQuota.stage1Default,
          namespace: namespace,
          memory: VirtualContextMemory(
            sessionId: 'sess_exec_policy_hook',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'Hook test',
              tools: Win32JobExecDriver.toolSchemas(policy: samplePolicy),
            ),
          ),
        ),
      );

      final approvalSpy = PolicyApprovalHandler.alwaysAllow();
      final execDriver = Win32JobExecDriver.forWorkspace(
        repoDir.path,
        execPolicy: samplePolicy,
      );
      final baseDef = execDriver.buildSyscallDefinition();
      var driverCount = 0;

      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: approvalSpy),
        ioCapper: IoPayloadCapper(workspaceHostRoot: repoDir.path),
        auditLogger: auditLogger,
        hooks: <SyscallHook>[AntiGitHabitGuardHook()],
      );
      gate.registerSyscall(
        SyscallDefinition(
          name: baseDef.name,
          requiredRight: baseDef.requiredRight,
          kind: baseDef.kind,
          applyIoCap: baseDef.applyIoCap,
          cappedTextFields: baseDef.cappedTextFields,
          validateArgs: baseDef.validateArgs,
          normalizeArgs: baseDef.normalizeArgs,
          checkPreconditions: baseDef.checkPreconditions,
          evaluatePolicy: baseDef.evaluatePolicy,
          handler: (_) async {
            driverCount++;
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{
                'exitCode': 0,
                'stdout': 'ok',
                'stderr': '',
                'timedOut': false,
                'durationMs': 1,
                'truncatedStdout': false,
                'truncatedStderr': false,
              },
            );
          },
        ),
      );

      for (final reqArgs in const <Map<String, dynamic>>[
        <String, dynamic>{
          'command': 'mise',
          'args': <String>['exec', '--', 'git', 'status'],
        },
        <String, dynamic>{
          'command': 'mise exec -- jj log',
        },
        <String, dynamic>{
          'command': 'mise',
          'args': <String>['exec', '--', 'env', 'FOO=1', 'git', 'diff'],
        },
        <String, dynamic>{
          'command': 'mise',
          'args': <String>['exec', '--', r'C:\Git\cmd\git.exe', 'status'],
        },
      ]) {
        final blocked = await gate.invoke(
          ctx,
          SyscallRequest(name: 'sys_exec', args: reqArgs),
        );
        expect(blocked.ok, isFalse);
        expect(blocked.error!.code, equals(SyscallErrorCode.eperm));
        expect(blocked.error!.reason, equals('HOOK_BLOCKED'));
      }
      expect(approvalSpy.recordedRequests, isEmpty);
      expect(driverCount, equals(0));

      // Safe `--` invocations must pass both hook and policy classifier without approval
      final safeMise = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'mise',
            'args': <String>['exec', '--', 'v', 'test'],
          },
        ),
      );
      expect(safeMise.ok, isTrue, reason: '${safeMise.error}');
      expect(approvalSpy.recordedRequests, isEmpty);
      expect(driverCount, equals(1));
    });

    test('Win32JobExecDriver supports maxTimeoutMs 600000, toolSchemas(policy), and direct execution with virtual path resolution', () async {
      expect(Win32JobExecDriver.maxTimeoutMs, equals(600000));
      expect(
        Win32JobExecDriver.validateRawArgs(const <String, dynamic>{
          'command': 'cargo',
          'timeoutMs': 600000,
        }),
        isNull,
      );
      expect(
        Win32JobExecDriver.validateRawArgs(const <String, dynamic>{
          'command': 'cargo',
          'timeoutMs': 600001,
        })?.reason,
        equals('INVALID_TIMEOUT'),
      );

      final defaultSchema = Win32JobExecDriver.toolSchemas().single;
      expect(
        defaultSchema.description,
        isNot(contains('Additional auto-allowed direct commands')),
      );
      expect(
        ((defaultSchema.parametersJsonSchema['properties']
                as Map<String, dynamic>)['timeoutMs']
            as Map<String, dynamic>)['description'],
        contains('100..600000'),
      );

      final policySchema =
          Win32JobExecDriver.toolSchemas(policy: samplePolicy).single;
      expect(
        policySchema.description,
        contains('Additional auto-allowed direct commands (.agent_os/exec_policy.json):'),
      );
      expect(
        policySchema.description,
        contains('`v` (allowed prefixes: `test`, `check-md`, `build`; maxTimeoutMs: 180000)'),
      );

      // End-to-end direct native execution (`where.exe` on Windows) without approval prompt
      final auditLogger = AuditLogger(
        workspaceHostRoot: repoDir.path,
        sessionId: 'sess_win32_exec_policy',
      );
      final processTable = KernelProcessTable();
      const capHandle = CapHandle('cap_exec_direct');
      const ctx = SyscallContext(
        pid: 1,
        capHandle: capHandle,
        sessionId: 'sess_win32_exec_policy',
      );
      processTable.registerProcess(
        ProcessControlBlock(
          pid: 1,
          name: 'lead-agent',
          ring: ProtectionRing.ring2,
          state: ProcessState.running,
          cspace: CapabilityTable.stage1LeadAgent(handle: capHandle),
          quota: ResourceQuota.stage1Default,
          namespace: namespace,
          memory: VirtualContextMemory(
            sessionId: 'sess_win32_exec_policy',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'Exec policy test',
              tools: Win32JobExecDriver.toolSchemas(policy: samplePolicy),
            ),
          ),
        ),
      );

      final rejectHandler = PolicyApprovalHandler.alwaysReject();
      final execDriver = Win32JobExecDriver.forWorkspace(
        repoDir.path,
        execPolicy: samplePolicy,
      );
      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: rejectHandler),
        ioCapper: IoPayloadCapper(workspaceHostRoot: repoDir.path),
        auditLogger: auditLogger,
        hooks: <SyscallHook>[AntiGitHabitGuardHook()],
      );
      execDriver.registerSyscalls(gate);

      final execRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'where',
            'args': <String>['cmd.exe'],
          },
        ),
      );
      expect(execRes.ok, isTrue, reason: '${execRes.error}');
      expect(execRes.value!['exitCode'], equals(0));
      expect(
        (execRes.value!['stdout'] as String).toLowerCase(),
        contains('cmd.exe'),
      );
      expect(rejectHandler.recordedRequests, isEmpty);
    });

    test('HostFsDriver denies all read/write/search access to .agent_os/exec_policy.json with EACCES: PROTECTED_INTERNAL_PATH', () async {
      final fsDriver = HostFsDriver(namespace: namespace);
      final auditLogger = AuditLogger(
        workspaceHostRoot: repoDir.path,
        sessionId: 'sess_vfs_protect',
      );
      final processTable = KernelProcessTable();
      const capHandle = CapHandle('cap_vfs_protect');
      const ctx = SyscallContext(
        pid: 1,
        capHandle: capHandle,
        sessionId: 'sess_vfs_protect',
      );
      processTable.registerProcess(
        ProcessControlBlock(
          pid: 1,
          name: 'lead-agent',
          ring: ProtectionRing.ring2,
          state: ProcessState.running,
          cspace: CapabilityTable.stage1LeadAgent(handle: capHandle),
          quota: ResourceQuota.stage1Default,
          namespace: namespace,
          memory: VirtualContextMemory(
            sessionId: 'sess_vfs_protect',
            systemInstruction: PinnedSystemInstruction(
              instruction: 'VFS protect test',
              tools: HostFsDriver.allToolSchemas(),
            ),
          ),
        ),
      );

      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(workspaceHostRoot: repoDir.path),
        auditLogger: auditLogger,
      );
      fsDriver.registerAllSyscalls(gate);

      for (final targetPath in const <String>[
        '/workspace/.agent_os/exec_policy.json',
        '.agent_os/exec_policy.json',
      ]) {
        final readRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_read_lines',
            args: <String, dynamic>{'path': targetPath},
          ),
        );
        expect(readRes.ok, isFalse);
        expect(readRes.error!.code, equals(SyscallErrorCode.eacces));
        expect(readRes.error!.reason, equals('PROTECTED_INTERNAL_PATH'));

        final writeRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_write_file',
            args: <String, dynamic>{
              'path': targetPath,
              'content': '{"allow":[]}',
            },
          ),
        );
        expect(writeRes.ok, isFalse);
        expect(writeRes.error!.code, equals(SyscallErrorCode.eacces));
        expect(writeRes.error!.reason, equals('PROTECTED_INTERNAL_PATH'));

        final editRes = await gate.invoke(
          ctx,
          SyscallRequest(
            name: 'sys_edit_block',
            args: <String, dynamic>{
              'path': targetPath,
              'expectedSha256': '0' * 64,
              'oldBlock': 'allow',
              'newBlock': 'allow',
            },
          ),
        );
        expect(editRes.ok, isFalse);
        expect(editRes.error!.code, equals(SyscallErrorCode.eacces));
        expect(editRes.error!.reason, equals('PROTECTED_INTERNAL_PATH'));
      }

      final globRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_glob',
          args: const <String, dynamic>{'pattern': '.agent_os/**'},
        ),
      );
      expect(globRes.ok, isFalse);
      expect(globRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(globRes.error!.reason, equals('PROTECTED_INTERNAL_PATH'));

      final grepRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_grep',
          args: const <String, dynamic>{
            'pattern': 'allow',
            'subpath': '/workspace/.agent_os',
          },
        ),
      );
      expect(grepRes.ok, isFalse);
      expect(grepRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(grepRes.error!.reason, equals('PROTECTED_INTERNAL_PATH'));

      final grepScanRes = await gate.invoke(
        ctx,
        SyscallRequest(
          name: 'sys_grep',
          args: const <String, dynamic>{
            'pattern': 'allow',
            'includeGlob': '.agent_os/**',
          },
        ),
      );
      expect(grepScanRes.ok, isFalse);
      expect(grepScanRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(grepScanRes.error!.reason, equals('PROTECTED_INTERNAL_PATH'));
    });
  });
}
