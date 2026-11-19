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
      final badSet = resolver.setSessionModel('openai/gpt-4o');
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
  });
}
