import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Subprocess approval runtime integration ([D-707], [D-711])', () {
    late Directory tempDir;
    late String repoRoot;
    late JjDriver jjDriver;
    late HostFsDriver fsDriver;
    late Win32JobExecDriver execDriver;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fm_wp4_sub_apr_');
      repoRoot = p.normalize(tempDir.path);
      await _runCmd('jj', <String>['git', 'init', '--colocate', '.'], repoRoot);
      await _runCmd(
        'jj',
        <String>['config', 'set', '--repo', 'user.name', 'WP4 Tester'],
        repoRoot,
      );
      await _runCmd(
        'jj',
        <String>['config', 'set', '--repo', 'user.email', 'wp4@example.com'],
        repoRoot,
      );
      await File(p.join(repoRoot, '.gitignore')).writeAsString('.agent_os/\n');
      await File(p.join(repoRoot, 'README.md')).writeAsString('wp4 base\n');
      await _runCmd('jj', <String>['commit', '-m', 'initial'], repoRoot);

      jjDriver = JjDriver.forWorkspace(repoRoot);
      fsDriver = HostFsDriver(
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        ensureActiveTransactionForPcb: jjDriver.ensureActiveTransactionForPcb,
        syncWorkingCopySnapshotForPcb: jjDriver.syncWorkingCopySnapshotForPcb,
      );
      execDriver = Win32JobExecDriver(
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        ensureActiveTransactionForPcb: jjDriver.ensureActiveTransactionForPcb,
        syncWorkingCopySnapshotForPcb: jjDriver.syncWorkingCopySnapshotForPcb,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        for (var i = 0; i < 4; i++) {
          try {
            await tempDir.delete(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }
      }
    });

    _RuntimeHarness createHarness({
      required String sessionId,
      ApprovalHandler? approvalHandler,
      CapabilityTable? leadCspace,
      Set<ProcessProfileId> subprocessApprovalProfiles =
          const <ProcessProfileId>{},
      Future<LlmChatResponse> Function(
        Pid pid,
        int step,
        List<ProjectedMessage> messages,
        SyscallExecutionContext exec,
      )? onLlmChat,
      List<SyscallDefinition> extraSyscalls = const <SyscallDefinition>[],
      List<SyscallToolSchema> extraSchemas = const <SyscallToolSchema>[],
    }) {
      final cspace = leadCspace ?? CapabilityTable.stage3LeadAgent();
      final capHandle = cspace.entries.first.handle;
      final processTable = KernelProcessTable.stage2();
      final leadPcb = ProcessControlBlock(
        pid: 1,
        name: 'lead',
        ring: ProtectionRing.ring2,
        cspace: cspace,
        quota: ResourceQuota.stage2Default,
        namespace: VfsNamespace(workspaceHostRoot: repoRoot),
        memory: VirtualContextMemory(
          sessionId: sessionId,
          systemInstruction: PinnedSystemInstruction(
            instruction: AgentPrompts.leadStage3Instruction,
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
      processTable.registerProcess(leadPcb);

      final auditLogger = AuditLogger(
        sessionId: sessionId,
        workspaceHostRoot: repoRoot,
        redactor: SecretRedactor(),
      );
      final approvalGate = ApprovalGate(
        handler: approvalHandler ?? PolicyApprovalHandler.alwaysAllow(),
      );
      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: approvalGate,
        ioCapper: IoPayloadCapper(),
        auditLogger: auditLogger,
        hooks: <SyscallHook>[AntiGitHabitGuardHook()],
      );
      fsDriver.registerAllSyscalls(gate);
      jjDriver.registerAllSyscalls(gate);
      execDriver.registerSyscalls(gate);
      for (final def in extraSyscalls) {
        gate.registerSyscall(def);
      }

      final allSchemas = <SyscallToolSchema>[
        ...HostFsDriver.allToolSchemas(),
        ...JjDriver.allToolSchemas(),
        ...Win32JobExecDriver.toolSchemas(),
        ...buildProcessToolSchemas(),
        ...extraSchemas,
      ];

      final quotaLedger = QuotaLedger();
      final host = IsolateWorkerHost(
        processTable: processTable,
        syscallGate: gate,
        quotaLedger: quotaLedger,
        jjDriver: jjDriver,
        toolSchemaProvider: (pcb) => filterToolSchemasForPcb(
          pcb: pcb,
          allSchemas: allSchemas,
        ),
        parentCurrentModelProvider: () => 'local-ollama/gemma4:12b',
        backend: const GreenTaskChildWorkerBackend(),
        subprocessApprovalProfiles: subprocessApprovalProfiles,
      );
      for (final def in buildProcessSyscallDefinitions(
        host: host,
        processTable: processTable,
      )) {
        gate.registerSyscall(def);
      }

      final stepByPid = <Pid, int>{};
      gate.registerSyscall(
        _buildTestLlmChatSyscall((model, messages, exec) async {
          final step = (stepByPid[exec.pcb.pid] ?? 0) + 1;
          stepByPid[exec.pcb.pid] = step;
          if (onLlmChat != null) {
            return onLlmChat(exec.pcb.pid, step, messages, exec);
          }
          return LlmChatResponse(
            content: 'done',
            usage: const LlmUsageTelemetry(
              promptTokens: 10,
              completionTokens: 5,
              durationMs: 1,
            ),
          );
        }),
      );

      final parentCtx = SyscallContext(
        pid: 1,
        capHandle: capHandle,
        sessionId: sessionId,
      );

      return _RuntimeHarness(
        processTable: processTable,
        approvalGate: approvalGate,
        gate: gate,
        host: host,
        quotaLedger: quotaLedger,
        leadPcb: leadPcb,
        parentCtx: parentCtx,
      );
    }

    test(
      'REQ-01: sys_spawn argument validation, 2-system opt-in priority, attenuation, and tool schema filtering',
      () async {
        final h = createHarness(
          sessionId: 'req01_optin',
          subprocessApprovalProfiles: const <ProcessProfileId>{
            ProcessProfileId.workspaceWorker,
          },
        );
        addTearDown(() => h.host.dispose());

        // 1. Non-bool allowUserApproval -> EINVAL: INVALID_ARGS
        final badBool = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'check',
              'allowUserApproval': 'yes',
            },
          ),
        );
        expect(badBool.ok, isFalse);
        expect(badBool.error!.code, equals(SyscallErrorCode.einval));
        expect(badBool.error!.reason, equals('INVALID_ARGS'));

        // 2. allowUserApproval: false + requestedRights: ['requestApproval'] -> EINVAL: CONFLICTING_APPROVAL_ARGS
        final conflict = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'check',
              'allowUserApproval': false,
              'requestedRights': <String>[
                'read',
                'llmInfer',
                'procSelf',
                'requestApproval',
              ],
            },
          ),
        );
        expect(conflict.ok, isFalse);
        expect(conflict.error!.code, equals(SyscallErrorCode.einval));
        expect(conflict.error!.reason, equals('CONFLICTING_APPROVAL_ARGS'));

        // 3. Sterile explorer / web_researcher with explicit allowUserApproval: true -> EPERM: APPROVAL_NOT_ALLOWED_FOR_PROFILE
        for (final profile in const <String>['explorer', 'web_researcher']) {
          final sterile = await h.gate.invoke(
            h.parentCtx,
            SyscallRequest(
              name: 'sys_spawn',
              args: <String, dynamic>{
                'profile': profile,
                'taskPrompt': 'check',
                'allowUserApproval': true,
              },
            ),
          );
          expect(sterile.ok, isFalse);
          expect(sterile.error!.code, equals(SyscallErrorCode.eperm));
          expect(
            sterile.error!.reason,
            equals('APPROVAL_NOT_ALLOWED_FOR_PROFILE'),
          );
        }

        // 4. Policy opt-in grants CapRight.requestApproval + sys_request_approval schema to workspace_worker
        final policySpawn = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'policy opted in',
            },
          ),
        );
        expect(policySpawn.ok, isTrue, reason: '${policySpawn.error}');
        final pidPolicy = policySpawn.value!['childPid'] as int;
        final pcbPolicy = h.processTable.getProcess(pidPolicy)!;
        expect(
          pcbPolicy.cspace.hasAnyRight(CapRight.requestApproval),
          isTrue,
        );
        expect(
          pcbPolicy.memory.systemSegment.pinned.tools
              .map((SyscallToolSchema t) => t.name)
              .toList(),
          contains('sys_request_approval'),
        );
        expect(
          pcbPolicy.memory.systemSegment.pinned.instruction,
          contains('sys_request_approval'),
        );

        // 5. Parent explicit allowUserApproval: false overrides exec_policy.json opt-in
        final overrideFalse = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'override false',
              'allowUserApproval': false,
            },
          ),
        );
        expect(overrideFalse.ok, isTrue, reason: '${overrideFalse.error}');
        final pidFalse = overrideFalse.value!['childPid'] as int;
        final pcbFalse = h.processTable.getProcess(pidFalse)!;
        expect(
          pcbFalse.cspace.hasAnyRight(CapRight.requestApproval),
          isFalse,
        );
        expect(
          pcbFalse.memory.systemSegment.pinned.tools
              .map((SyscallToolSchema t) => t.name),
          isNot(contains('sys_request_approval')),
        );
        expect(
          pcbFalse.memory.systemSegment.pinned.instruction,
          contains('TTY monopoly (`EPERM`)'),
        );

        // 6. Parent explicit requestedRights (omitting requestApproval) overrides exec_policy.json opt-in
        final overrideRights = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'override rights',
              'requestedRights': <String>[
                'read',
                'exec',
                'llmInfer',
                'procSelf',
              ],
            },
          ),
        );
        expect(overrideRights.ok, isTrue, reason: '${overrideRights.error}');
        final pidRights = overrideRights.value!['childPid'] as int;
        final pcbRights = h.processTable.getProcess(pidRights)!;
        expect(
          pcbRights.cspace.hasAnyRight(CapRight.requestApproval),
          isFalse,
        );

        // Wait for all spawned children to finish cleanly.
        final waitRes = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(name: 'sys_wait', args: <String, dynamic>{}),
        );
        expect(waitRes.ok, isTrue);

        // 7. Parent lacking CapRight.requestApproval:
        //    - explicit allowUserApproval: true -> CAPABILITY_ATTENUATION_VIOLATION
        //    - policy opt-in only -> succeeds WITHOUT requestApproval
        final parentRightsNoApproval =
            CapabilityTable.stage3LeadAgent().allRights.difference(
                  const <CapRight>{CapRight.requestApproval},
                );
        final attenuatedParent = CapabilityTable(
          initialEntries: <CapabilityEntry>[
            CapabilityEntry(
              handle: const CapHandle('cap_workspace_rw'),
              resourceScope: '/workspace',
              rights: parentRightsNoApproval,
            ),
          ],
        );
        final hNoApr = createHarness(
          sessionId: 'req01_no_parent_apr',
          leadCspace: attenuatedParent,
          subprocessApprovalProfiles: const <ProcessProfileId>{
            ProcessProfileId.workspaceWorker,
          },
        );
        addTearDown(() => hNoApr.host.dispose());

        final explicitFail = await hNoApr.gate.invoke(
          hNoApr.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'explicit',
              'allowUserApproval': true,
            },
          ),
        );
        expect(explicitFail.ok, isFalse);
        expect(explicitFail.error!.code, equals(SyscallErrorCode.eperm));
        expect(
          explicitFail.error!.reason,
          equals('CAPABILITY_ATTENUATION_VIOLATION'),
        );

        final policySilentNoApr = await hNoApr.gate.invoke(
          hNoApr.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'policy silent',
            },
          ),
        );
        expect(
          policySilentNoApr.ok,
          isTrue,
          reason: '${policySilentNoApr.error}',
        );
        final pidSilent = policySilentNoApr.value!['childPid'] as int;
        expect(
          hNoApr.processTable
              .getProcess(pidSilent)!
              .cspace
              .hasAnyRight(CapRight.requestApproval),
          isFalse,
        );
        await hNoApr.gate.invoke(
          hNoApr.parentCtx,
          SyscallRequest(name: 'sys_wait', args: <String, dynamic>{}),
        );
      },
    );

    test(
      'REQ-02 & REQ-03: opted-in workspace_worker executes safe command via explicit ticket and implicit Stage 4, while Ring 3 hard-guards are unconditionally denied with 0 handler calls',
      () async {
        final approvalHandler = PolicyApprovalHandler(
          (req, _) async => const ApprovalDecision.allowOnce(),
        );
        final observedResults = <Map<String, dynamic>>[];

        final h = createHarness(
          sessionId: 'req02_03_exec',
          approvalHandler: approvalHandler,
          onLlmChat: (pid, step, messages, exec) async {
            if (step == 1) {
              // Step 1: explicit sys_request_approval for safe unregistered command `where dart`
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_apr',
                    name: 'sys_request_approval',
                    arguments: const <String, dynamic>{
                      'syscall': 'sys_exec',
                      'args': <String, dynamic>{
                        'command': 'where',
                        'args': <String>['dart'],
                      },
                      'reason': 'Locate dart executable in workspace check',
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 5,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            if (step == 2) {
              // Step 2: execute `where dart` (consumes 1-time ticket) + try hard-guarded `powershell.exe`
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_exec1',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'where',
                      'args': <String>['dart'],
                    },
                  ),
                  LlmToolCallSpec(
                    id: 'tc_shell',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'powershell.exe',
                      'args': <String>['-Command', 'echo hi'],
                    },
                  ),
                  LlmToolCallSpec(
                    id: 'tc_exec2_implicit',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'where',
                      'args': <String>['dart'],
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 5,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            // Capture tool results from messages
            for (final msg in messages) {
              if (msg.role == ProjectedRole.tool) {
                observedResults.add(
                  jsonDecode(msg.content) as Map<String, dynamic>,
                );
              }
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'tc_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'exec verified',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          },
        );
        addTearDown(() => h.host.dispose());

        final spawnRes = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'run where dart',
              'allowUserApproval': true,
            },
          ),
        );
        expect(spawnRes.ok, isTrue, reason: '${spawnRes.error}');

        final waitRes = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(name: 'sys_wait', args: <String, dynamic>{}),
        );
        expect(waitRes.ok, isTrue, reason: '${waitRes.error}');
        final children = waitRes.value!['children'] as List<dynamic>;
        expect(children, hasLength(1));
        expect((children.first as Map<String, dynamic>)['ok'], isTrue);

        // Exactly 2 ApprovalHandler invocations:
        //   #1: explicit sys_request_approval (consumed by tc_exec1 without re-asking)
        //   #2: implicit Stage 4 on tc_exec2_implicit (ticket already consumed)
        //   0 calls for powershell.exe (unconditionally denied by Ring 3 hard-guard)
        expect(approvalHandler.recordedRequests, hasLength(2));
        expect(
          approvalHandler.recordedRequests[0].requestedVia,
          equals('sys_request_approval'),
        );
        expect(
          approvalHandler.recordedRequests[0].agentReason,
          equals('Locate dart executable in workspace check'),
        );
        expect(
          approvalHandler.recordedRequests[1].requestedVia,
          equals('stage4_gate'),
        );

        // Verify powershell.exe got DENIED_BY_POLICY (EPERM)
        final shellErr = observedResults.firstWhere(
          (m) => m['code'] == 'EPERM' && m['reason'] == 'DENIED_BY_POLICY',
          orElse: () => const <String, dynamic>{},
        );
        expect(shellErr, isNotEmpty);
      },
    );

    test(
      'REQ-04: parallel FIFO serialization, PID-scoped allow_always non-propagation (other child & Supervisor retry), and clearForPid on exit',
      () async {
        var inFlight = 0;
        var maxInFlight = 0;
        final requestsByPid = <Pid, int>{};
        final firstEntered = Completer<void>();
        final releaseFirst = Completer<void>();

        final approvalHandler = PolicyApprovalHandler((req, _) async {
          inFlight += 1;
          if (inFlight > maxInFlight) {
            maxInFlight = inFlight;
          }
          requestsByPid[req.pid] = (requestsByPid[req.pid] ?? 0) + 1;
          try {
            if (!firstEntered.isCompleted) {
              firstEntered.complete();
              await releaseFirst.future;
            }
            return const ApprovalDecision.allowAlways();
          } finally {
            inFlight -= 1;
          }
        });

        final customExecCountByPid = <Pid, int>{};
        final customDef = SyscallDefinition(
          name: 'sys_custom_probe',
          requiredRight: CapRight.exec,
          kind: 'execute',
          applyIoCap: false,
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          approvalSignatureBuilder: (_) => 'custom_probe_sig',
          handler: (exec) async {
            customExecCountByPid[exec.pcb.pid] =
                (customExecCountByPid[exec.pcb.pid] ?? 0) + 1;
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{'ran': true},
            );
          },
        );

        // Track retry attempts by logicalTaskId
        final attemptNumByLogical = <String, int>{};
        final h = createHarness(
          sessionId: 'req04_fifo_scope',
          approvalHandler: approvalHandler,
          extraSyscalls: <SyscallDefinition>[customDef],
          onLlmChat: (pid, step, messages, exec) async {
            final logicalId = exec.pcb.logicalTaskId ?? '';
            if (logicalId == 'retry_task') {
              if (step == 1) {
                attemptNumByLogical[logicalId] =
                    (attemptNumByLogical[logicalId] ?? 0) + 1;
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'tc_probe',
                      name: 'sys_custom_probe',
                      arguments: const <String, dynamic>{},
                    ),
                  ],
                  usage: const LlmUsageTelemetry(
                    promptTokens: 5,
                    completionTokens: 5,
                    durationMs: 1,
                  ),
                );
              }
              final attempt = attemptNumByLogical[logicalId] ?? 1;
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_exit',
                    name: 'sys_exit',
                    arguments: <String, dynamic>{
                      'exitCode': attempt == 1 ? 1 : 0,
                      'summary': 'attempt $attempt',
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 5,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }

            // Parallel workers A & B: call sys_custom_probe TWICE
            if (step == 1 || step == 2) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_p_$step',
                    name: 'sys_custom_probe',
                    arguments: const <String, dynamic>{},
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 5,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'tc_done',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'ok',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          },
        );
        addTearDown(() => h.host.dispose());

        // Spawn Worker A & Worker B concurrently
        final spawnA = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'name': 'worker-a',
              'taskPrompt': 'parallel a',
              'allowUserApproval': true,
            },
          ),
        );
        final spawnB = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'name': 'worker-b',
              'taskPrompt': 'parallel b',
              'allowUserApproval': true,
            },
          ),
        );
        expect(spawnA.ok, isTrue);
        expect(spawnB.ok, isTrue);
        final pidA = spawnA.value!['childPid'] as int;
        final pidB = spawnB.value!['childPid'] as int;

        await firstEntered.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(maxInFlight, equals(1));
        releaseFirst.complete();

        final waitAB = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_wait',
            args: <String, dynamic>{'pids': <int>[pidA, pidB]},
          ),
        );
        expect(waitAB.ok, isTrue);
        // FIFO serialized (never > 1 concurrent)
        expect(maxInFlight, equals(1));
        // Each child asked ONCE (allow_always remembered for its 2nd call, NOT shared across PIDs)
        expect(requestsByPid[pidA], equals(1));
        expect(requestsByPid[pidB], equals(1));
        expect(customExecCountByPid[pidA], equals(2));
        expect(customExecCountByPid[pidB], equals(2));
        // After exit, clearForPid cleared both children's remembered allow_always
        expect(h.approvalGate.allowAlwaysSignaturesForPid(pidA), isEmpty);
        expect(h.approvalGate.allowAlwaysSignaturesForPid(pidB), isEmpty);
        expect(h.approvalGate.allowAlwaysSignaturesForPid(1), isEmpty);

        // Now spawn a supervised task that fails attempt 1 after allow_always, then retries on new PID
        final spawnRetry = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'logicalTaskId': 'retry_task',
              'taskPrompt': 'retry check',
              'allowUserApproval': true,
              'supervision': <String, dynamic>{
                'restart': 'on_failure',
                'maxRetries': 1,
              },
            },
          ),
        );
        expect(spawnRetry.ok, isTrue, reason: '${spawnRetry.error}');
        final waitRetry = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(name: 'sys_wait', args: <String, dynamic>{}),
        );
        expect(waitRetry.ok, isTrue);
        final retryChild =
            (waitRetry.value!['children'] as List<dynamic>).single
                as Map<String, dynamic>;
        expect(retryChild['ok'], isTrue);
        final attempts = retryChild['attempts'] as List<dynamic>;
        expect(attempts, hasLength(2));
        final retryPid1 = (attempts[0] as Map<String, dynamic>)['pid'] as int;
        final retryPid2 = (attempts[1] as Map<String, dynamic>)['pid'] as int;
        expect(retryPid2, isNot(equals(retryPid1)));
        // Both attempt 1 and attempt 2 had to ask user (allow_always did NOT leak to retryPid2)
        expect(requestsByPid[retryPid1], equals(1));
        expect(requestsByPid[retryPid2], equals(1));
        expect(h.approvalGate.allowAlwaysSignaturesForPid(retryPid1), isEmpty);
        expect(h.approvalGate.allowAlwaysSignaturesForPid(retryPid2), isEmpty);
      },
    );

    test(
      'REQ-05: waitingApproval pauses wallTimer & heartbeatTimer, shifts startedAtUtc once, and surfaces in sys_wait / snapshotProcesses',
      () async {
        final approvalEntered = Completer<void>();
        final releaseApproval = Completer<ApprovalDecision>();

        final approvalHandler = PolicyApprovalHandler((req, _) async {
          if (!approvalEntered.isCompleted) {
            approvalEntered.complete();
          }
          return releaseApproval.future;
        });

        final customDef = SyscallDefinition(
          name: 'sys_gated_op',
          requiredRight: CapRight.exec,
          kind: 'execute',
          applyIoCap: false,
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{'ok': true},
          ),
        );

        final h = createHarness(
          sessionId: 'req05_timer_pause',
          approvalHandler: approvalHandler,
          extraSyscalls: <SyscallDefinition>[customDef],
          onLlmChat: (pid, step, messages, exec) async {
            if (step == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_gate',
                    name: 'sys_gated_op',
                    arguments: const <String, dynamic>{},
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 5,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            if (step == 2) {
              // Post-approval syscall to verify QuotaConsumption.checkBeforeSyscall does NOT throw EDQUOT
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_read',
                    name: 'sys_read_lines',
                    arguments: const <String, dynamic>{
                      'path': '/workspace/README.md',
                    },
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 5,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'tc_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'survived long approval wait',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          },
        );
        addTearDown(() => h.host.dispose());

        final spawnRes = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'long wait test',
              'allowUserApproval': true,
              'heartbeatTimeoutMs': 150,
              'maxWallTimeMs': 240,
            },
          ),
        );
        expect(spawnRes.ok, isTrue, reason: '${spawnRes.error}');
        final childPid = spawnRes.value!['childPid'] as int;

        await approvalEntered.future.timeout(const Duration(seconds: 5));

        // Short non-destructive sys_wait observes state == waitingApproval & heartbeat.isPaused == true
        final shortWait = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_wait',
            args: <String, dynamic>{'timeoutMs': 60},
          ),
        );
        expect(shortWait.ok, isTrue);
        expect(shortWait.value!['timedOut'], isTrue);
        final running = shortWait.value!['running'] as List<dynamic>;
        expect(running, hasLength(1));
        final runningEntry = running.first as Map<String, dynamic>;
        expect(runningEntry['state'], equals('waitingApproval'));
        expect(
          (runningEntry['heartbeat'] as Map<String, dynamic>)['isPaused'],
          isTrue,
        );

        // snapshotProcesses() also reports waitingApproval + isPaused: true
        final snap = h.host.snapshotProcesses();
        expect(snap.single['state'], equals('waitingApproval'));
        expect(
          (snap.single['heartbeat'] as Map<String, dynamic>)['isPaused'],
          isTrue,
        );

        // Hold approval for 340ms (well beyond heartbeatTimeoutMs=150 and maxWallTimeMs=240)
        await Future<void>.delayed(const Duration(milliseconds: 340));
        expect(
          h.processTable.getProcess(childPid)!.state,
          equals(ProcessState.waitingApproval),
        );

        // Release approval and re-wait -> child completes without HEARTBEAT_TIMEOUT or WALL_TIME_QUOTA_EXCEEDED or EDQUOT
        releaseApproval.complete(const ApprovalDecision.allowOnce());
        final finalWait = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(name: 'sys_wait', args: <String, dynamic>{}),
        );
        expect(finalWait.ok, isTrue);
        final childResult =
            (finalWait.value!['children'] as List<dynamic>).single
                as Map<String, dynamic>;
        expect(
          childResult['ok'],
          isTrue,
          reason: 'Unexpected failure: $childResult',
        );
        expect(childResult['summary'], equals('survived long approval wait'));
      },
    );

    test(
      'REQ-05: SIGSTOP x waitingApproval bidirectional race (a) approve-while-stopped waits for SIGCONT, (b) SIGCONT-while-awaiting restores waitingApproval without premature timeout',
      () async {
        // --- Case (a): waitingApproval -> SIGSTOP -> approve -> Stage 5 blocked until SIGCONT ---
        final approvalEnteredA = Completer<void>();
        final releaseApprovalA = Completer<ApprovalDecision>();
        var stage5ExecutedA = false;

        final hA = createHarness(
          sessionId: 'req05_race_a',
          approvalHandler: PolicyApprovalHandler((req, _) async {
            if (!approvalEnteredA.isCompleted) {
              approvalEnteredA.complete();
            }
            return releaseApprovalA.future;
          }),
          extraSyscalls: <SyscallDefinition>[
            SyscallDefinition(
              name: 'sys_race_op',
              requiredRight: CapRight.exec,
              kind: 'execute',
              applyIoCap: false,
              evaluatePolicy: (_, _) async => RingDecision.askUser,
              handler: (_) async {
                stage5ExecutedA = true;
                return const SyscallResult<Map<String, dynamic>>.success(
                  <String, dynamic>{'executed': true},
                );
              },
            ),
          ],
          onLlmChat: (pid, step, messages, exec) async {
            if (step == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_r',
                    name: 'sys_race_op',
                    arguments: const <String, dynamic>{},
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 5,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'tc_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'raceA ok',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          },
        );
        addTearDown(() => hA.host.dispose());

        final spawnA = await hA.gate.invoke(
          hA.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'race a',
              'allowUserApproval': true,
              'heartbeatTimeoutMs': 150,
              'maxWallTimeMs': 300,
            },
          ),
        );
        final pidA = spawnA.value!['childPid'] as int;
        await approvalEnteredA.future.timeout(const Duration(seconds: 5));

        // Send SIGSTOP while waitingApproval
        await hA.host.sendSignal(
          targetPid: pidA,
          signal: ProcessSignalKind.sigstop,
        );
        expect(
          hA.processTable.getProcess(pidA)!.state,
          equals(ProcessState.stopped),
        );

        // Resolve approval while SIGSTOP is active
        releaseApprovalA.complete(const ApprovalDecision.allowOnce());
        await Future<void>.delayed(const Duration(milliseconds: 120));

        // Stage 4.5 must keep Stage 5 blocked and state stopped
        expect(stage5ExecutedA, isFalse);
        expect(
          hA.processTable.getProcess(pidA)!.state,
          equals(ProcessState.stopped),
        );

        // Now send SIGCONT -> Stage 5 runs and child completes
        await hA.host.sendSignal(
          targetPid: pidA,
          signal: ProcessSignalKind.sigcont,
        );
        final waitA = await hA.gate.invoke(
          hA.parentCtx,
          SyscallRequest(name: 'sys_wait', args: <String, dynamic>{}),
        );
        expect(waitA.ok, isTrue);
        expect(stage5ExecutedA, isTrue);
        expect(
          ((waitA.value!['children'] as List<dynamic>).single
              as Map<String, dynamic>)['ok'],
          isTrue,
        );

        // --- Case (b): waitingApproval -> SIGSTOP -> SIGCONT (still awaiting) -> state returns to waitingApproval, timers stay paused ---
        final approvalEnteredB = Completer<void>();
        final releaseApprovalB = Completer<ApprovalDecision>();

        final hB = createHarness(
          sessionId: 'req05_race_b',
          approvalHandler: PolicyApprovalHandler((req, _) async {
            if (!approvalEnteredB.isCompleted) {
              approvalEnteredB.complete();
            }
            return releaseApprovalB.future;
          }),
          extraSyscalls: <SyscallDefinition>[
            SyscallDefinition(
              name: 'sys_race_op',
              requiredRight: CapRight.exec,
              kind: 'execute',
              applyIoCap: false,
              evaluatePolicy: (_, _) async => RingDecision.askUser,
              handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(
                <String, dynamic>{'executed': true},
              ),
            ),
          ],
          onLlmChat: (pid, step, messages, exec) async {
            if (step == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'tc_r',
                    name: 'sys_race_op',
                    arguments: const <String, dynamic>{},
                  ),
                ],
                usage: const LlmUsageTelemetry(
                  promptTokens: 5,
                  completionTokens: 5,
                  durationMs: 1,
                ),
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'tc_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'raceB ok',
                  },
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          },
        );
        addTearDown(() => hB.host.dispose());

        final spawnB = await hB.gate.invoke(
          hB.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'race b',
              'allowUserApproval': true,
              'heartbeatTimeoutMs': 150,
              'maxWallTimeMs': 250,
            },
          ),
        );
        final pidB = spawnB.value!['childPid'] as int;
        await approvalEnteredB.future.timeout(const Duration(seconds: 5));

        await hB.host.sendSignal(
          targetPid: pidB,
          signal: ProcessSignalKind.sigstop,
        );
        expect(
          hB.processTable.getProcess(pidB)!.state,
          equals(ProcessState.stopped),
        );

        await hB.host.sendSignal(
          targetPid: pidB,
          signal: ProcessSignalKind.sigcont,
        );
        expect(
          hB.processTable.getProcess(pidB)!.state,
          equals(ProcessState.waitingApproval),
        );

        // Wait past heartbeatTimeoutMs (150ms) and maxWallTimeMs (250ms) while still awaiting approval
        await Future<void>.delayed(const Duration(milliseconds: 320));
        expect(
          hB.processTable.getProcess(pidB)!.state,
          equals(ProcessState.waitingApproval),
        );

        releaseApprovalB.complete(const ApprovalDecision.allowOnce());
        final waitB = await hB.gate.invoke(
          hB.parentCtx,
          SyscallRequest(name: 'sys_wait', args: <String, dynamic>{}),
        );
        expect(waitB.ok, isTrue);
        expect(
          ((waitB.value!['children'] as List<dynamic>).single
              as Map<String, dynamic>)['ok'],
          isTrue,
        );
      },
    );

    test(
      'REQ-05: SIGKILL and PARENT_TURN_ENDED during waitingApproval immediately cancel wait, delete isolated workspace, settle quota, and clearForPid',
      () async {
        final entered1 = Completer<void>();
        final entered2 = Completer<void>();

        final h = createHarness(
          sessionId: 'req05_kill_cleanup',
          approvalHandler: PolicyApprovalHandler((req, cancelToken) async {
            if (!entered1.isCompleted) {
              entered1.complete();
            } else if (!entered2.isCompleted) {
              entered2.complete();
            }
            if (cancelToken != null) {
              await cancelToken.onCancel;
            }
            return const ApprovalDecision.cancelled();
          }),
          extraSyscalls: <SyscallDefinition>[
            SyscallDefinition(
              name: 'sys_wait_forever',
              requiredRight: CapRight.exec,
              kind: 'execute',
              applyIoCap: false,
              evaluatePolicy: (_, _) async => RingDecision.askUser,
              handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(
                <String, dynamic>{},
              ),
            ),
          ],
          onLlmChat: (pid, step, messages, exec) async {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'tc_w',
                  name: 'sys_wait_forever',
                  arguments: const <String, dynamic>{},
                ),
              ],
              usage: const LlmUsageTelemetry(
                promptTokens: 5,
                completionTokens: 5,
                durationMs: 1,
              ),
            );
          },
        );
        addTearDown(() => h.host.dispose());

        // 1. SIGKILL while waitingApproval
        final spawn1 = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'kill me',
              'allowUserApproval': true,
            },
          ),
        );
        final pid1 = spawn1.value!['childPid'] as int;
        final wsRoot1 = h.processTable.getProcess(pid1)!.jjWorkspaceRoot!;
        expect(Directory(wsRoot1).existsSync(), isTrue);

        await entered1.future.timeout(const Duration(seconds: 5));
        final killRes = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_kill',
            args: <String, dynamic>{'pid': pid1, 'signal': 'SIGKILL'},
          ),
        );
        expect(killRes.ok, isTrue);
        expect(Directory(wsRoot1).existsSync(), isFalse);
        expect(h.approvalGate.allowAlwaysSignaturesForPid(pid1), isEmpty);

        // 2. PARENT_TURN_ENDED while waitingApproval
        final spawn2 = await h.gate.invoke(
          h.parentCtx,
          SyscallRequest(
            name: 'sys_spawn',
            args: <String, dynamic>{
              'profile': 'workspace_worker',
              'taskPrompt': 'parent turn ends',
              'allowUserApproval': true,
            },
          ),
        );
        final pid2 = spawn2.value!['childPid'] as int;
        final wsRoot2 = h.processTable.getProcess(pid2)!.jjWorkspaceRoot!;
        expect(Directory(wsRoot2).existsSync(), isTrue);

        await entered2.future.timeout(const Duration(seconds: 5));
        await h.host.terminateActiveChildrenForParent(1);
        expect(Directory(wsRoot2).existsSync(), isFalse);
        expect(h.host.activeChildCount, equals(0));
        expect(h.approvalGate.allowAlwaysSignaturesForPid(pid2), isEmpty);
      },
    );
  });
}

class _RuntimeHarness {
  _RuntimeHarness({
    required this.processTable,
    required this.approvalGate,
    required this.gate,
    required this.host,
    required this.quotaLedger,
    required this.leadPcb,
    required this.parentCtx,
  });

  final KernelProcessTable processTable;
  final ApprovalGate approvalGate;
  final SyscallGate gate;
  final IsolateWorkerHost host;
  final QuotaLedger quotaLedger;
  final ProcessControlBlock leadPcb;
  final SyscallContext parentCtx;
}

SyscallDefinition _buildTestLlmChatSyscall(
  Future<LlmChatResponse> Function(
    String model,
    List<ProjectedMessage> messages,
    SyscallExecutionContext exec,
  ) responder,
) {
  return SyscallDefinition(
    name: 'sys_llm_chat',
    requiredRight: CapRight.llmInfer,
    kind: 'other',
    applyIoCap: false,
    evaluatePolicy: (_, _) async => RingDecision.allow,
    handler: (exec) async {
      final model = (exec.args['model'] as String?) ?? 'local-ollama/gemma4:12b';
      const projector = CanonicalIrProjector();
      final projected = projector.project(
        exec.pcb.memory,
        targetProvider: LlmProviderId.localOllama.id,
        targetModel: model,
      );
      final resp = await responder(model, projected.messages, exec);
      exec.pcb.quotaUsage.recordUsage(
        tokens: resp.usage.totalTokens,
        costMicroUsd: resp.usage.costMicroUsd ?? 0,
      );
      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'content': resp.content,
        'toolCalls': resp.toolCalls
            .map(
              (tc) => <String, dynamic>{
                'id': tc.id,
                'name': tc.name,
                'arguments': tc.arguments,
              },
            )
            .toList(growable: false),
        'usage': <String, dynamic>{
          'promptTokens': resp.usage.promptTokens,
          'completionTokens': resp.usage.completionTokens,
          'totalTokens': resp.usage.totalTokens,
          'durationMs': resp.usage.durationMs,
        },
      });
    },
  );
}

Future<void> _runCmd(
  String executable,
  List<String> args,
  String workingDirectory,
) async {
  final res = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory,
    runInShell: false,
    environment: JjDriver.buildNonInteractiveEnvironment(),
  );
  if (res.exitCode != 0) {
    throw StateError(
      'Command failed: $executable ${args.join(' ')} (exit=${res.exitCode}): ${res.stderr}',
    );
  }
}
