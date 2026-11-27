import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('REQ-05 / D-509 / D-510: ExecPolicy Runtime Integration', () {
    late Directory repoDir;

    ProcessResult runCmdSync(String exe, List<String> args, {String? cwd}) {
      final res = Process.runSync(
        exe,
        args,
        workingDirectory: cwd ?? repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
      );
      if (res.exitCode != 0) {
        throw StateError(
          '$exe ${args.join(' ')} failed (${res.exitCode}): ${res.stderr}',
        );
      }
      return res;
    }

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('fm_wp3_exec_policy_');
      runCmdSync('jj', <String>['git', 'init', '--colocate', '.']);
      runCmdSync('jj', <String>['config', 'set', '--repo', 'user.name', 'WP3']);
      runCmdSync(
        'jj',
        <String>['config', 'set', '--repo', 'user.email', 'wp3@example.com'],
      );
      File(p.join(repoDir.path, '.gitignore'))
          .writeAsStringSync('.dart_tool/\n.agent_os/\n');
      File(p.join(repoDir.path, 'notes.txt'))
          .writeAsStringSync('base line\n');
      runCmdSync('jj', <String>['describe', '-m', 'seed']);
      runCmdSync('jj', <String>['new', '-m', 'wip']);

      // Configure .agent_os/exec_policy.json with safe Windows native executables.
      final agentOsDir = Directory(p.join(repoDir.path, '.agent_os'))
        ..createSync(recursive: true);
      File(p.join(agentOsDir.path, 'exec_policy.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'allow': <Map<String, dynamic>>[
            <String, dynamic>{
              'command': 'hostname',
              'maxTimeoutMs': 120000,
            },
            <String, dynamic>{
              'command': 'findstr',
              'allowedArgPrefixes': <List<String>>[
                <String>['hello_wp3'],
              ],
              'maxTimeoutMs': 120000,
            },
          ],
        }),
      );
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        for (var i = 0; i < 4; i++) {
          try {
            repoDir.deleteSync(recursive: true);
            break;
          } on FileSystemException {
            sleep(const Duration(milliseconds: 50));
          }
        }
      }
    });

    test(
        '(a)/(b)/(c)/(d) Ring 3 workspace_worker/conflict_resolver and Ring 2 execute exec_policy commands without approval, block unlisted/explorer, and inject prompts & schemas',
        () async {
      final approvalRequests = <ApprovalRequest>[];
      final approvalHandler = _CountingApprovalHandler((req) async {
        approvalRequests.add(req);
        return const ApprovalDecision.rejectOnce();
      });

      final capturedPromptsByProfile = <String, String>{};
      final capturedToolDescriptions = <String, Map<String, String>>{};
      final capturedLeadSchemas = <String, SyscallToolSchema>{};
      var leadStep = 0;
      final workerSteps = <String, int>{};

      // Create a First-Class Conflict commit in jj so conflict_resolver can also run.
      runCmdSync('jj', <String>['new', '@-', '-m', 'branch_a']);
      File(p.join(repoDir.path, 'conflict.txt'))
          .writeAsStringSync('side A content\n');
      final branchAChange = (runCmdSync(
        'jj',
        <String>['log', '--no-graph', '-r', '@', '-T', 'change_id'],
      ).stdout as String)
          .trim();

      runCmdSync('jj', <String>['new', '@-', '-m', 'branch_b']);
      File(p.join(repoDir.path, 'conflict.txt'))
          .writeAsStringSync('side B content\n');
      final branchBChange = (runCmdSync(
        'jj',
        <String>['log', '--no-graph', '-r', '@', '-T', 'change_id'],
      ).stdout as String)
          .trim();

      runCmdSync(
        'jj',
        <String>['new', branchAChange, branchBChange, '-m', 'merge conflict'],
      );
      final mergeChangeId = (runCmdSync(
        'jj',
        <String>['log', '--no-graph', '-r', '@', '-T', 'change_id'],
      ).stdout as String)
          .trim();

      // Return LeadAgent working copy to a clean child of @-
      runCmdSync('jj', <String>['new', '@--', '-m', 'lead wip']);

      final mockDriver = _ScriptedLlmDriver(
        onRequest: (req) {
          final sysText = req.prompt.messages.first.content;
          final toolsMap = <String, String>{
            for (final t in req.prompt.tools) t.name: t.description,
          };

          if (sysText.contains('Ring 3 WorkspaceWorker')) {
            capturedPromptsByProfile['workspace_worker'] = sysText;
            capturedToolDescriptions['workspace_worker'] = toolsMap;
            final step = (workerSteps['ws'] ?? 0) + 1;
            workerSteps['ws'] = step;
            if (step == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'ws_1',
                    name: 'sys_write_file',
                    arguments: const <String, dynamic>{
                      'path': '/workspace/worker_check.txt',
                      'content': 'hello_wp3 isolated workspace\n',
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 10,
                  durationMs: 5,
                ),
              );
            }
            if (step == 2) {
              // Auto-allowed via exec_policy.json with /workspace/... virtual path arg!
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'ws_2',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'findstr',
                      'args': <String>[
                        'hello_wp3',
                        '/workspace/worker_check.txt',
                      ],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 10,
                  durationMs: 5,
                ),
              );
            }
            if (step == 3) {
              // Unlisted command must be blocked by TTY_MONOPOLY_DENIED in Ring 3.
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'ws_3',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'where',
                      'args': <String>['dart'],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 10,
                  durationMs: 5,
                ),
              );
            }
            final toolResults = req.prompt.messages
                .where((m) => m.role == ProjectedRole.tool)
                .map((m) => m.content)
                .toList();
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'ws_exit',
                  name: 'sys_exit',
                  arguments: <String, dynamic>{
                    'exitCode': 0,
                    'summary': jsonEncode(toolResults),
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 10,
                durationMs: 5,
              ),
            );
          }

          if (sysText.contains('Ring 3 ConflictResolver')) {
            capturedPromptsByProfile['conflict_resolver'] = sysText;
            capturedToolDescriptions['conflict_resolver'] = toolsMap;
            final step = (workerSteps['cr'] ?? 0) + 1;
            workerSteps['cr'] = step;
            if (step == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'cr_1',
                    name: 'sys_read_lines',
                    arguments: const <String, dynamic>{
                      'path': '/workspace/conflict.txt',
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 10,
                  durationMs: 5,
                ),
              );
            }
            if (step == 2) {
              final readMsg = req.prompt.messages
                  .lastWhere((m) => m.role == ProjectedRole.tool)
                  .content;
              final readJson = jsonDecode(readMsg) as Map<String, dynamic>;
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'cr_2',
                    name: 'sys_write_file',
                    arguments: <String, dynamic>{
                      'path': '/workspace/conflict.txt',
                      'content': 'merged A+B\n',
                      'expectedSha256': readJson['sha256'],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 10,
                  durationMs: 5,
                ),
              );
            }
            if (step == 3) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'cr_3',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'hostname',
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 10,
                  completionTokens: 10,
                  durationMs: 5,
                ),
              );
            }
            final toolResults = req.prompt.messages
                .where((m) => m.role == ProjectedRole.tool)
                .map((m) => m.content)
                .toList();
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'cr_exit',
                  name: 'sys_exit',
                  arguments: <String, dynamic>{
                    'exitCode': 0,
                    'summary': jsonEncode(toolResults),
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 10,
                durationMs: 5,
              ),
            );
          }

          if (sysText.contains('Ring 3 Explorer')) {
            capturedPromptsByProfile['explorer'] = sysText;
            capturedToolDescriptions['explorer'] = toolsMap;
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'exp_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'explorer ok',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 10,
                durationMs: 5,
              ),
            );
          }

          if (sysText.contains('Ring 3 WebResearcher')) {
            capturedPromptsByProfile['web_researcher'] = sysText;
            capturedToolDescriptions['web_researcher'] = toolsMap;
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'wr_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'web researcher ok',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 10,
                durationMs: 5,
              ),
            );
          }

          // Ring 2 LeadAgent
          capturedPromptsByProfile['lead'] = sysText;
          capturedToolDescriptions['lead'] = toolsMap;
          for (final t in req.prompt.tools) {
            capturedLeadSchemas[t.name] = t;
          }
          leadStep += 1;
          if (leadStep == 1) {
            // Ring 2 immediate execution of exec_policy command (0 approvals)
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'lead_1',
                  name: 'sys_exec',
                  arguments: const <String, dynamic>{'command': 'hostname'},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 10,
                durationMs: 5,
              ),
            );
          }
          if (leadStep == 2) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'lead_sp_ws',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'workspace_worker',
                    'name': 'ws-worker',
                    'taskPrompt': 'Run findstr in isolated workspace',
                  },
                ),
                LlmToolCallSpec(
                  id: 'lead_sp_cr',
                  name: 'sys_spawn',
                  arguments: <String, dynamic>{
                    'profile': 'conflict_resolver',
                    'name': 'cr-worker',
                    'baseChangeId': mergeChangeId,
                    'taskPrompt': 'Resolve merge conflict and run hostname',
                  },
                ),
                LlmToolCallSpec(
                  id: 'lead_sp_exp',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'explorer',
                    'name': 'exp-worker',
                    'taskPrompt': 'Read repo',
                  },
                ),
                LlmToolCallSpec(
                  id: 'lead_sp_wr',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'web_researcher',
                    'name': 'wr-worker',
                    'taskPrompt': 'Search web',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 10,
                durationMs: 5,
              ),
            );
          }
          if (leadStep == 3) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'lead_wait',
                  name: 'sys_wait',
                  arguments: const <String, dynamic>{'timeoutMs': 30000},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 10,
                completionTokens: 10,
                durationMs: 5,
              ),
            );
          }
          return LlmChatResponse(
            content: 'DONE',
            usage: const LlmUsageTelemetry(
              promptTokens: 10,
              completionTokens: 10,
              durationMs: 5,
            ),
          );
        },
      );

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          approvalHandler: approvalHandler,
          enableStage2Multiprocess: true,
          enableStage3Team: true,
          contextWindowSource: _StaticWindowSource(32768),
          childWorkerBackend: const IsolateChildWorkerBackend(),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: mockDriver,
          },
        ),
      );
      addTearDown(bootstrap.dispose);

      expect(bootstrap.execPolicy.allow, hasLength(2));

      final turnResult = await bootstrap.processRunner.submitPrompt(
        userInput: 'Test exec_policy integration across Ring 2 and Ring 3',
      );
      expect(turnResult.ok, isTrue, reason: '${turnResult.error}');
      expect(turnResult.finalText, equals('DONE'));

      // (a) Zero approval prompts for hostname & findstr in Ring 2 and Ring 3!
      expect(approvalRequests, isEmpty);

      // Verify Ring 2 hostname succeeded
      final leadToolMsgs = bootstrap.pcb.memory.historySegment.turns
          .whereType<CanonicalToolResultTurn>()
          .toList();
      final leadExecRes = jsonDecode(
        leadToolMsgs.firstWhere((t) => t.toolName == 'sys_exec').content,
      ) as Map<String, dynamic>;
      expect(leadExecRes['exitCode'], equals(0));
      expect((leadExecRes['stdout'] as String).trim(), isNotEmpty);

      // Verify sys_wait collected all 4 children
      final waitRes = jsonDecode(
        leadToolMsgs.firstWhere((t) => t.toolName == 'sys_wait').content,
      ) as Map<String, dynamic>;
      final children = (waitRes['children'] as List).cast<Map<String, dynamic>>();
      expect(children, hasLength(4));

      final wsChild =
          children.firstWhere((c) => c['profile'] == 'workspace_worker');
      expect(wsChild['ok'], isTrue);
      expect(wsChild['workingChangeId'], isNotNull);
      final wsResults = (jsonDecode(wsChild['summary'] as String) as List)
          .cast<String>()
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .toList();
      // ws_2: findstr /workspace/worker_check.txt succeeded in isolated workspace
      expect(wsResults[1]['exitCode'], equals(0));
      expect(wsResults[1]['stdout'], contains('hello_wp3 isolated workspace'));
      // ws_3: unlisted `where` blocked by TTY_MONOPOLY_DENIED
      expect(wsResults[2]['code'], equals('EPERM'));
      expect(wsResults[2]['reason'], equals('TTY_MONOPOLY_DENIED'));

      final crChild =
          children.firstWhere((c) => c['profile'] == 'conflict_resolver');
      expect(crChild['ok'], isTrue);
      final crResults = (jsonDecode(crChild['summary'] as String) as List)
          .cast<String>()
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .toList();
      expect(crResults[2]['exitCode'], equals(0));
      expect((crResults[2]['stdout'] as String).trim(), isNotEmpty);

      // (b) Ring 2 unlisted command triggers ApprovalHandler (askUser -> rejectOnce)
      final unlistedLeadRes = await bootstrap.syscallGate.invoke(
        SyscallContext(
          pid: 1,
          capHandle: bootstrap.capHandle,
          sessionId: bootstrap.sessionId,
        ),
        SyscallRequest(
          name: 'sys_exec',
          args: <String, dynamic>{
            'command': 'where',
            'args': <String>['dart'],
          },
        ),
      );
      expect(unlistedLeadRes.ok, isFalse);
      expect(approvalRequests, hasLength(1));
      expect(approvalRequests.single.syscallName, equals('sys_exec'));

      // (c) explorer & web_researcher lack sys_exec schema & fail with CAPABILITY_DENIED
      expect(
        capturedToolDescriptions['explorer']!.containsKey('sys_exec'),
        isFalse,
      );
      expect(
        capturedToolDescriptions['web_researcher']!.containsKey('sys_exec'),
        isFalse,
      );

      for (final profile in const <ProcessProfileId>[
        ProcessProfileId.explorer,
        ProcessProfileId.webResearcher,
      ]) {
        final childHandle = CapHandle('cap_test_${profile.wireValue}');
        final cspace = bootstrap.pcb.cspace
            .deriveForProfile(profile, childHandle: childHandle)
            .value!;
        final testPid = bootstrap.processTable.allocateNextPid();
        final childPcb = ProcessControlBlock(
          pid: testPid,
          parentPid: 1,
          name: 'test-${profile.wireValue}',
          ring: ProtectionRing.ring3,
          cspace: cspace,
          quota: const ResourceQuota(maxSyscallCountPerTurn: 16),
          namespace: profile.mountsWorkspace
              ? bootstrap.namespace
              : const VfsNamespace.empty(),
          memory: VirtualContextMemory(
            sessionId: bootstrap.sessionId,
            systemInstruction: PinnedSystemInstruction(
              instruction: '',
              tools: const <SyscallToolSchema>[],
            ),
          ),
          profile: profile,
        );
        expect(bootstrap.processTable.registerProcess(childPcb).ok, isTrue);
        final execDenied = await bootstrap.syscallGate.invoke(
          SyscallContext(
            pid: testPid,
            capHandle: childHandle,
            sessionId: bootstrap.sessionId,
          ),
          SyscallRequest(
            name: 'sys_exec',
            args: <String, dynamic>{'command': 'hostname'},
          ),
        );
        expect(execDenied.ok, isFalse);
        expect(execDenied.error!.code, equals(SyscallErrorCode.eperm));
        expect(execDenied.error!.reason, equals('CAPABILITY_DENIED'));
      }

      // (d) Prompt & tool schema reflection verification
      for (final role in const <String>[
        'lead',
        'workspace_worker',
        'conflict_resolver',
      ]) {
        final prompt = capturedPromptsByProfile[role]!;
        expect(prompt, contains('Additional `sys_exec` direct commands'));
        expect(prompt, contains('`hostname`'));
        expect(prompt, contains('`findstr`'));

        final execDesc = capturedToolDescriptions[role]!['sys_exec']!;
        expect(
          execDesc,
          contains('Additional auto-allowed direct commands'),
        );
        expect(execDesc, contains('`hostname`'));
        expect(execDesc, contains('`findstr`'));
      }

      final leadSpawnParamsJson =
          jsonEncode(capturedLeadSchemas['sys_spawn']!.parametersJsonSchema);
      expect(leadSpawnParamsJson, contains('3600000'));
      expect(leadSpawnParamsJson, contains('128'));
      expect(leadSpawnParamsJson, contains('heartbeatTimeoutMs'));

      final leadWaitDesc = capturedToolDescriptions['lead']!['sys_wait']!;
      expect(leadWaitDesc, contains('Non-destructive on timeout'));
      expect(leadWaitDesc, contains('heartbeat'));

      expect(
        capturedPromptsByProfile['explorer']!,
        isNot(contains('Additional `sys_exec` direct commands')),
      );
      expect(
        capturedPromptsByProfile['web_researcher']!,
        isNot(contains('Additional `sys_exec` direct commands')),
      );
    });

    test(
        'malformed exec_policy.json emits redacted warnings to onExecPolicyWarning (never stdout) and fails closed',
        () async {
      const secretVal = 'secret_token_wp3_xyz987';
      File(p.join(repoDir.path, '.agent_os', 'exec_policy.json'))
          .writeAsStringSync(
        '{"allow":[{"command":"cmd","subcommands":["/c"]},{"command":"bad/$secretVal"}]}',
      );

      final warnings = <String>[];
      final redactor = SecretRedactor(initialSecrets: const <String>[secretVal]);
      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          startupModel: 'local-ollama/gemma4:12b',
          redactor: redactor,
          onExecPolicyWarning: warnings.add,
          contextWindowSource: _StaticWindowSource(32768),
          llmDrivers: <LlmProviderId, LlmDriver>{
            LlmProviderId.localOllama: _ScriptedLlmDriver(
              onRequest: (_) => LlmChatResponse(
                content: 'ok',
                usage: const LlmUsageTelemetry(
                  promptTokens: 1,
                  completionTokens: 1,
                  durationMs: 1,
                ),
              ),
            ),
          },
        ),
      );
      addTearDown(bootstrap.dispose);

      expect(bootstrap.execPolicy.allow, isEmpty);
      expect(warnings, isNotEmpty);
      expect(warnings.join('\n'), isNot(contains(secretVal)));
      expect(warnings.join('\n'), contains('<REDACTED>'));
    });
  });
}

class _CountingApprovalHandler implements ApprovalHandler {
  _CountingApprovalHandler(this._handler);
  final Future<ApprovalDecision> Function(ApprovalRequest req) _handler;

  @override
  Future<ApprovalDecision> requestApproval(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) =>
      _handler(request);
}

class _StaticWindowSource implements ContextWindowSource {
  _StaticWindowSource(this.windowTokens);
  final int windowTokens;

  @override
  Future<ContextWindowSpec> resolve(
    ModelIdentifier model, {
    bool forceRefreshPs = false,
  }) async {
    return ContextWindowSpec(
      contextWindowTokens: windowTokens,
      source: 'test_static',
      isLoadedExact: true,
    );
  }
}

class _ScriptedLlmDriver implements LlmDriver {
  _ScriptedLlmDriver({required this.onRequest});
  final LlmChatResponse Function(LlmChatRequest request) onRequest;

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final resp = onRequest(request);
    if (resp.content.isNotEmpty) {
      yield LlmTextDelta(resp.content);
    }
    for (final tc in resp.toolCalls) {
      yield LlmToolCallEvent(tc);
    }
    yield LlmDoneEvent(resp);
  }
}
