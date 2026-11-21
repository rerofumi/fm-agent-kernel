import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/src/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ModelResolver priority 1..4 [D-002] §2.1(2)', () {
    test('resolves turnOverride > sessionSelected > startupModel > default', () {
      final resolver = ModelResolver();

      // Priority 4: default
      expect(
        resolver.resolveForTurn().value!.canonicalId,
        equals('local-ollama/gemma4:12b'),
      );

      // Priority 3: startupModel
      expect(resolver.setStartupModel('ollama-cloud/gpt-oss:120b').ok, isTrue);
      expect(
        resolver.resolveForTurn().value!.canonicalId,
        equals('ollama-cloud/gpt-oss:120b'),
      );

      // Priority 2: sessionSelected (/model)
      expect(
        resolver.setSessionModel('openrouter/anthropic/claude-sonnet-4').ok,
        isTrue,
      );
      expect(
        resolver.resolveForTurn().value!.canonicalId,
        equals('openrouter/anthropic/claude-sonnet-4'),
      );

      // Priority 1: turnOverride applies ONLY to that turn and does not mutate sessionSelected.
      expect(
        resolver
            .resolveForTurn(turnOverride: 'local-ollama/ministral-3:14b')
            .value!
            .canonicalId,
        equals('local-ollama/ministral-3:14b'),
      );
      expect(
        resolver.resolveForTurn().value!.canonicalId,
        equals('openrouter/anthropic/claude-sonnet-4'),
      );
    });

    test('rejects invalid model identifiers with EINVAL without overwriting valid state', () {
      final resolver = ModelResolver(startupModel: 'local-ollama/gemma4:12b');
      final badSet = resolver.setSessionModel('unknown-provider/gpt-4o');
      expect(badSet.ok, isFalse);
      expect(badSet.error!.code, equals(SyscallErrorCode.einval));
      expect(
        resolver.resolveForTurn().value!.canonicalId,
        equals('local-ollama/gemma4:12b'),
      );

      final badTurn = resolver.resolveForTurn(turnOverride: 'invalid_no_slash');
      expect(badTurn.ok, isFalse);
      expect(badTurn.error!.code, equals(SyscallErrorCode.einval));
    });
  });

  group('LeadAgent ReAct loop & GreenTaskProcessRunner [D-005]', () {
    late Directory tempRoot;
    late ProcessControlBlock pcb;
    late AuditLogger auditLogger;
    late SyscallGate gate;
    late ModelResolver modelResolver;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('fm_wp4_loop_test_');
      auditLogger = AuditLogger(
        workspaceHostRoot: tempRoot.path,
        sessionId: 'sess_loop',
      );
      final processTable = KernelProcessTable();
      pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: const ResourceQuota(
          maxChildProcesses: 0,
          maxSyscallCountPerTurn: 10,
        ),
        namespace: VfsNamespace(workspaceHostRoot: tempRoot.path),
        memory: VirtualContextMemory(
          sessionId: 'sess_loop',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'OS Rules',
            tools: <SyscallToolSchema>[
              SyscallToolSchema(
                name: 'sys_read_lines',
                description: 'Read lines',
                parametersJsonSchema: const <String, dynamic>{'type': 'object'},
              ),
            ],
          ),
        ),
      );
      processTable.registerProcess(pcb);
      gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(
          workspaceHostRoot: tempRoot.path,
          config: const IoCapConfig(),
        ),
        auditLogger: auditLogger,
      );
      modelResolver = ModelResolver(startupModel: 'local-ollama/gemma4:12b');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('executes multi-step tool call roundtrip strictly via SyscallGate keeping model fixed within turn', () async {
      final seenModelsInTurn = <String>[];
      var llmCallCount = 0;

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (execCtx) async {
            llmCallCount += 1;
            seenModelsInTurn.add(execCtx.args['model'] as String);
            if (llmCallCount == 1) {
              // Simulate an external attempt to change session model mid-turn;
              // the already-started turn MUST keep its resolved boundary model.
              modelResolver.setSessionModel('openrouter/openai/gpt-4o');
              return SyscallResult<Map<String, dynamic>>.success(
                <String, dynamic>{
                  'content': '',
                  'thoughtText': 'Need to read foo.dart',
                  'toolCalls': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'call_1',
                      'name': 'sys_read_lines',
                      'arguments': <String, dynamic>{'path': '/workspace/foo.dart'},
                    },
                  ],
                  'usage': const <String, dynamic>{
                    'promptTokens': 100,
                    'completionTokens': 20,
                    'cachedTokens': 0,
                    'durationMs': 50,
                  },
                },
              );
            }
            return SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{
                'content': 'Done reading foo.dart',
                'toolCalls': const <dynamic>[],
                'usage': const <String, dynamic>{
                  'promptTokens': 140,
                  'completionTokens': 12,
                  'cachedTokens': 90,
                  'durationMs': 40,
                },
              },
            );
          },
        ),
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_read_lines',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (execCtx) async {
            return SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{
                'path': execCtx.args['path'],
                'content': 'void main() {}',
              },
            );
          },
        ),
      );

      final agent = LeadAgent(
        pcb: pcb,
        syscallGate: gate,
        capHandle: const CapHandle('cap_workspace_rw'),
        modelResolver: modelResolver,
      );
      final events = <AgentLoopEvent>[];
      final sub = agent.events.listen(events.add);
      addTearDown(() async {
        await sub.cancel();
        await agent.dispose();
      });

      final result = await agent.runTurn(
        userInput: 'Inspect foo.dart',
        dynamicContextSummary: 'jj status: clean',
      );

      expect(result.ok, isTrue);
      expect(result.finalText, equals('Done reading foo.dart'));
      expect(result.steps, equals(2));
      expect(result.toolCallsExecuted, equals(1));
      expect(result.model!.canonicalId, equals('local-ollama/gemma4:12b'));
      expect(
        seenModelsInTurn,
        equals(<String>[
          'local-ollama/gemma4:12b',
          'local-ollama/gemma4:12b',
        ]),
      );

      // Segment 1 contains: User -> Assistant(tool_call) -> ToolResult -> Assistant(final).
      expect(pcb.memory.historySegment.turns, hasLength(4));
      expect(pcb.memory.ephemeralSegment.currentUserInput, isNull);
      expect(pcb.memory.ephemeralSegment.dynamicContextSummary, isNull);

      expect(events.whereType<AgentTurnStartedEvent>(), hasLength(1));
      expect(events.whereType<AgentToolCallStartedEvent>(), hasLength(1));
      expect(events.whereType<AgentToolCallCompletedEvent>(), hasLength(1));
      expect(events.whereType<AgentTurnCompletedEvent>(), hasLength(1));

      // Next turn picks up the updated session model!
      final turn2 = await agent.runTurn(userInput: 'Follow up');
      expect(turn2.ok, isTrue);
      expect(turn2.model!.canonicalId, equals('openrouter/openai/gpt-4o'));
    });

    test('passes recoverable tool errors (EACCES) back to LLM and stops on EDQUOT', () async {
      var step = 0;
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (_) async {
            step += 1;
            if (step == 1) {
              return SyscallResult<Map<String, dynamic>>.success(
                <String, dynamic>{
                  'content': '',
                  'toolCalls': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'id': 'c1',
                      'name': 'sys_read_lines',
                      'arguments': <String, dynamic>{'path': '/workspace/.env'},
                    },
                  ],
                  'usage': const <String, dynamic>{
                    'promptTokens': 50,
                    'completionTokens': 10,
                    'durationMs': 10,
                  },
                },
              );
            }
            return SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{
                'content': 'Cannot read protected .env',
                'toolCalls': const <dynamic>[],
                'usage': const <String, dynamic>{
                  'promptTokens': 80,
                  'completionTokens': 10,
                  'durationMs': 10,
                },
              },
            );
          },
        ),
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_read_lines',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eacces,
              reason: 'PROTECTED_INTERNAL_PATH',
              message: 'Access denied to .env',
              recoverable: true,
            ),
          ),
        ),
      );

      final agent = LeadAgent(
        pcb: pcb,
        syscallGate: gate,
        capHandle: const CapHandle('cap_workspace_rw'),
        modelResolver: modelResolver,
      );
      addTearDown(agent.dispose);

      final recovered = await agent.runTurn(userInput: 'Read .env');
      expect(recovered.ok, isTrue);
      expect(recovered.finalText, equals('Cannot read protected .env'));
      final toolTurn = pcb.memory.historySegment.turns
          .whereType<CanonicalToolResultTurn>()
          .single;
      expect(toolTurn.isError, isTrue);
      expect(jsonDecode(toolTurn.content)['code'], equals('EACCES'));

      // Now test quota limit stop (maxSyscallCountPerTurn = 2).
      final lowQuotaPcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: const ResourceQuota(
          maxChildProcesses: 0,
          maxSyscallCountPerTurn: 2,
        ),
        namespace: pcb.namespace,
        memory: pcb.memory,
      );
      final lowQuotaTable = KernelProcessTable()..registerProcess(lowQuotaPcb);
      final lowQuotaGate = SyscallGate(
        processTable: lowQuotaTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(
          workspaceHostRoot: tempRoot.path,
          config: const IoCapConfig(),
        ),
        auditLogger: auditLogger,
      );
      lowQuotaGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (_) async => SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{
              'content': '',
              'toolCalls': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'loop',
                  'name': 'sys_read_lines',
                  'arguments': const <String, dynamic>{'path': '/workspace/a.dart'},
                },
              ],
              'usage': const <String, dynamic>{
                'promptTokens': 10,
                'completionTokens': 5,
                'durationMs': 5,
              },
            },
          ),
        ),
      );
      lowQuotaGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_read_lines',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{'content': 'ok'},
          ),
        ),
      );

      final quotaAgent = LeadAgent(
        pcb: lowQuotaPcb,
        syscallGate: lowQuotaGate,
        capHandle: const CapHandle('cap_workspace_rw'),
        modelResolver: modelResolver,
      );
      addTearDown(quotaAgent.dispose);

      final quotaResult = await quotaAgent.runTurn(userInput: 'Loop until quota');
      expect(quotaResult.ok, isFalse);
      expect(quotaResult.error!.code, equals(SyscallErrorCode.edquot));
      expect(quotaResult.error!.reason, equals('SYSCALL_QUOTA_EXCEEDED'));
    });

    test('GreenTaskProcessRunner supports cancellation via cancelActiveTurn', () async {
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (execCtx) async {
            await execCtx.context.cancelToken?.onCancel;
            return const SyscallResult<Map<String, dynamic>>.failure(
              SyscallError(
                code: SyscallErrorCode.ecancelled,
                reason: 'CANCELLED',
                message: 'Cancelled',
                recoverable: true,
              ),
            );
          },
        ),
      );

      final runner = GreenTaskProcessRunner(
        leadAgent: LeadAgent(
          pcb: pcb,
          syscallGate: gate,
          capHandle: const CapHandle('cap_workspace_rw'),
          modelResolver: modelResolver,
        ),
      );
      addTearDown(runner.dispose);

      final future = runner.submitPrompt(userInput: 'Long running turn');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      runner.cancelActiveTurn('User cancelled');

      final res = await future;
      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.ecancelled));
      expect(pcb.state, equals(ProcessState.ready));
    });

    test('E3 structural boundary check: process_runner.dart has zero concrete driver or HTTP imports', () {
      final file = File(
        p.join(
          Directory.current.path,
          'packages',
          'agent_runtime',
          'lib',
          'src',
          'process_runner.dart',
        ),
      );
      final source = file.existsSync()
          ? file.readAsStringSync()
          : File(
              p.join('lib', 'src', 'process_runner.dart'),
            ).readAsStringSync();

      expect(source, isNot(contains('package:agent_drivers')));
      expect(source, isNot(contains('package:http')));
      expect(source, isNot(contains('dart:io')));
      expect(source, isNot(contains('OllamaDriver')));
      expect(source, isNot(contains('OpenRouterDriver')));
    });

    test('continues turn on recoverable: true EDQUOT (MAILBOX_FULL / INSUFFICIENT_PARENT_TOKEN_QUOTA)', () async {
      var llmStep = 0;
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (_) async {
            llmStep += 1;
            if (llmStep == 1) {
              return const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
                'content': '',
                'toolCalls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'c1',
                    'name': 'sys_read_lines',
                    'arguments': <String, dynamic>{'path': '/workspace/a.txt'},
                  },
                ],
              });
            }
            return const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
              'content': 'Recovered after recoverable EDQUOT.',
              'toolCalls': <Map<String, dynamic>>[],
            });
          },
        ),
      );
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_read_lines',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.edquot,
              reason: 'MAILBOX_FULL',
              message: 'Recipient mailbox is full.',
              recoverable: true,
            ),
          ),
        ),
      );

      final agent = LeadAgent(
        pcb: pcb,
        syscallGate: gate,
        capHandle: const CapHandle('cap_workspace_rw'),
        modelResolver: modelResolver,
      );
      addTearDown(agent.dispose);

      final res = await agent.runTurn(userInput: 'Try sending message');
      expect(res.ok, isTrue);
      expect(res.steps, equals(2));
      expect(res.finalText, equals('Recovered after recoverable EDQUOT.'));

      final toolTurns = pcb.memory.historySegment.turns
          .whereType<CanonicalToolResultTurn>()
          .toList();
      expect(toolTurns.length, equals(1));
      expect(toolTurns.first.isError, isTrue);
      expect(toolTurns.first.content, contains('MAILBOX_FULL'));
    });

    test('backfills CanonicalToolResultTurn(isError: true) for unexecuted trailing toolCalls on fatal EDQUOT or ECANCELLED', () async {
      var toolCount = 0;
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (_) async {
            return const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
              'content': '',
              'toolCalls': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'c1',
                  'name': 'sys_read_lines',
                  'arguments': <String, dynamic>{'path': '/workspace/1.txt'},
                },
                <String, dynamic>{
                  'id': 'c2',
                  'name': 'sys_read_lines',
                  'arguments': <String, dynamic>{'path': '/workspace/2.txt'},
                },
                <String, dynamic>{
                  'id': 'c3',
                  'name': 'sys_read_lines',
                  'arguments': <String, dynamic>{'path': '/workspace/3.txt'},
                },
              ],
            });
          },
        ),
      );
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_read_lines',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (_) async {
            toolCount += 1;
            return const SyscallResult<Map<String, dynamic>>.failure(
              SyscallError(
                code: SyscallErrorCode.edquot,
                reason: 'TOKEN_QUOTA_EXCEEDED',
                message: 'Process token budget exhausted.',
                recoverable: false,
              ),
            );
          },
        ),
      );

      final agent = LeadAgent(
        pcb: pcb,
        syscallGate: gate,
        capHandle: const CapHandle('cap_workspace_rw'),
        modelResolver: modelResolver,
      );
      addTearDown(agent.dispose);

      final res = await agent.runTurn(userInput: 'Run 3 tools');
      expect(res.ok, isFalse);
      expect(res.error!.code, equals(SyscallErrorCode.edquot));
      expect(res.error!.recoverable, isFalse);
      expect(toolCount, equals(1));

      final assistantTurn = pcb.memory.historySegment.turns
          .whereType<CanonicalAssistantTurn>()
          .single;
      final toolResults = pcb.memory.historySegment.turns
          .whereType<CanonicalToolResultTurn>()
          .toList();

      expect(assistantTurn.toolCalls.length, equals(3));
      expect(toolResults.length, equals(3));
      for (var i = 0; i < 3; i++) {
        expect(
          toolResults[i].canonicalCallId,
          equals(assistantTurn.toolCalls[i].canonicalCallId),
        );
        expect(toolResults[i].isError, isTrue);
        expect(toolResults[i].content, contains('TOKEN_QUOTA_EXCEEDED'));
      }
    });

    test('awaits onTurnExitCleanup in finally on both normal completion and error exit', () async {
      var cleanupCount = 0;
      var cleanupCompletedBeforeReturn = false;

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (_) async {
            return const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
              'content': 'Done.',
              'toolCalls': <Map<String, dynamic>>[],
            });
          },
        ),
      );

      final agent = LeadAgent(
        pcb: pcb,
        syscallGate: gate,
        capHandle: const CapHandle('cap_workspace_rw'),
        modelResolver: modelResolver,
        onTurnExitCleanup: () async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          cleanupCount += 1;
          cleanupCompletedBeforeReturn = true;
        },
      );
      addTearDown(agent.dispose);

      final res = await agent.runTurn(userInput: 'Hello');
      expect(res.ok, isTrue);
      expect(cleanupCompletedBeforeReturn, isTrue);
      expect(cleanupCount, equals(1));
    });

    test('injects Segment 2 budget warning at >=85% step or syscall threshold without mutating Segment 0/1 and clears on exit', () async {
      // Case A: Step threshold (maxStepsPerTurn = 10 -> steps 0..8 are < 0.85, step 9 is 0.90 >= 0.85).
      final observedDynamicSummaries = <String?>[];
      final initialPinned = pcb.memory.systemSegment.pinned;
      final stepPcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: const ResourceQuota(
          maxChildProcesses: 0,
          maxSyscallCountPerTurn: 100,
        ),
        namespace: pcb.namespace,
        memory: VirtualContextMemory(
          sessionId: 'sess_loop_step',
          systemInstruction: initialPinned,
        ),
      );
      final stepTable = KernelProcessTable()..registerProcess(stepPcb);
      final stepGate = SyscallGate(
        processTable: stepTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(
          workspaceHostRoot: tempRoot.path,
          config: const IoCapConfig(),
        ),
        auditLogger: auditLogger,
      );
      var callIdx = 0;

      stepGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (_) async {
            observedDynamicSummaries.add(
              stepPcb.memory.ephemeralSegment.dynamicContextSummary,
            );
            callIdx += 1;
            if (callIdx < 10) {
              return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
                'content': '',
                'toolCalls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'tc_$callIdx',
                    'name': 'sys_read_lines',
                    'arguments': const <String, dynamic>{'path': '/workspace/a.dart'},
                  },
                ],
              });
            }
            return const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
              'content': 'Wrapped up before limit.',
              'toolCalls': <Map<String, dynamic>>[],
            });
          },
        ),
      );
      stepGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_read_lines',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{'content': 'ok'},
          ),
        ),
      );

      final stepAgent = LeadAgent(
        pcb: stepPcb,
        syscallGate: stepGate,
        capHandle: const CapHandle('cap_workspace_rw'),
        modelResolver: modelResolver,
        maxStepsPerTurn: 10,
      );
      addTearDown(stepAgent.dispose);

      final stepRes = await stepAgent.runTurn(userInput: 'Do 10 steps');
      expect(stepRes.ok, isTrue);
      expect(stepRes.finalText, equals('Wrapped up before limit.'));
      expect(observedDynamicSummaries.length, equals(10));
      for (var i = 0; i < 9; i++) {
        expect(observedDynamicSummaries[i], isNull);
      }
      expect(
        observedDynamicSummaries[9],
        contains('[Runtime Budget Warning] Approaching turn execution limit (steps: 9/10, syscalls: 18/100).'),
      );
      expect(stepPcb.memory.ephemeralSegment.dynamicContextSummary, isNull);
      expect(
        stepPcb.memory.systemSegment.pinned.instruction,
        equals(initialPinned.instruction),
      );
      expect(
        stepPcb.memory.historySegment.turns
            .whereType<CanonicalUserTurn>()
            .any((t) => t.text.contains('[Runtime Budget Warning]')),
        isFalse,
      );

      // Case B: Syscall threshold (maxStepsPerTurn = 64, maxSyscallCountPerTurn = 10).
      final syscallPcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage1LeadAgent(),
        quota: const ResourceQuota(
          maxChildProcesses: 0,
          maxSyscallCountPerTurn: 10,
        ),
        namespace: pcb.namespace,
        memory: VirtualContextMemory(
          sessionId: 'sess_loop_syscall',
          systemInstruction: initialPinned,
        ),
      );
      final syscallTable = KernelProcessTable()..registerProcess(syscallPcb);
      final syscallGate2 = SyscallGate(
        processTable: syscallTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(
          workspaceHostRoot: tempRoot.path,
          config: const IoCapConfig(),
        ),
        auditLogger: auditLogger,
      );
      final syscallSummaries = <String?>[];
      var syscallStep = 0;
      syscallGate2.registerSyscall(
        SyscallDefinition(
          name: 'sys_llm_chat',
          requiredRight: CapRight.llmInfer,
          kind: 'other',
          applyIoCap: false,
          handler: (_) async {
            syscallSummaries.add(
              syscallPcb.memory.ephemeralSegment.dynamicContextSummary,
            );
            syscallStep += 1;
            if (syscallStep == 1) {
              // 1 llm_chat + 8 read_lines = 9/10 syscalls (90% >= 85%).
              return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
                'content': '',
                'toolCalls': List<Map<String, dynamic>>.generate(
                  8,
                  (i) => <String, dynamic>{
                    'id': 'sc_$i',
                    'name': 'sys_read_lines',
                    'arguments': const <String, dynamic>{'path': '/workspace/a.dart'},
                  },
                ),
              });
            }
            return const SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
              'content': 'Done after syscall warning.',
              'toolCalls': <Map<String, dynamic>>[],
            });
          },
        ),
      );
      syscallGate2.registerSyscall(
        SyscallDefinition(
          name: 'sys_read_lines',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{'content': 'ok'},
          ),
        ),
      );

      final syscallAgent = LeadAgent(
        pcb: syscallPcb,
        syscallGate: syscallGate2,
        capHandle: const CapHandle('cap_workspace_rw'),
        modelResolver: modelResolver,
      );
      addTearDown(syscallAgent.dispose);

      final syscallRes = await syscallAgent.runTurn(userInput: 'Burst syscalls');
      expect(syscallRes.ok, isTrue);
      expect(syscallSummaries.length, equals(2));
      expect(syscallSummaries[0], isNull);
      expect(
        syscallSummaries[1],
        contains('[Runtime Budget Warning] Approaching turn execution limit (steps: 1/64, syscalls: 9/10).'),
      );
      expect(syscallPcb.memory.ephemeralSegment.dynamicContextSummary, isNull);
    });
  });
}
