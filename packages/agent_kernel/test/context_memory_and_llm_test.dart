import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('VirtualContextMemory & CanonicalIrProjector [D-007]', () {
    late VirtualContextMemory memory;
    const projector = CanonicalIrProjector();

    setUp(() {
      memory = VirtualContextMemory(
        sessionId: 'sess_ir_01',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'Pinned OS Rules',
          tools: <SyscallToolSchema>[
            SyscallToolSchema(
              name: 'sys_read_lines',
              description: 'Read lines',
              parametersJsonSchema: const <String, dynamic>{'type': 'object'},
            ),
            SyscallToolSchema(
              name: 'sys_glob',
              description: 'Glob files',
              parametersJsonSchema: const <String, dynamic>{'type': 'object'},
            ),
          ],
        ),
      );
    });

    test('keeps Segment 0 immutable and sorts tool schemas deterministically by name', () {
      expect(
        memory.systemSegment.pinned.tools.map((t) => t.name).toList(),
        equals(<String>['sys_glob', 'sys_read_lines']),
      );

      memory.appendUserTurn('turn 1');
      memory.ephemeralSegment.dynamicContextSummary = 'jj status: clean';
      memory.ephemeralSegment.currentUserInput = 'current question';

      final p1 = projector.project(
        memory,
        targetProvider: 'local-ollama',
        targetModel: 'gemma4:12b',
      );

      expect(p1.messages.first.role, equals(ProjectedRole.system));
      expect(p1.messages.first.segmentIndex, equals(0));
      expect(p1.messages.first.content, equals('Pinned OS Rules'));
      expect(
        p1.messages.where((m) => m.role == ProjectedRole.system).length,
        equals(1),
      );
      expect(p1.messages.last.segmentIndex, equals(2));
      expect(p1.messages.last.content, contains('jj status: clean'));
      expect(p1.messages.last.content, contains('current question'));
    });

    test('normalizes tool_call_id deterministically to [a-zA-Z0-9]{9} paired across assistant and tool turns', () {
      memory.appendUserTurn('inspect repo');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: 'openrouter',
          originModel: 'anthropic/claude-sonnet-4',
          content: null,
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'call_abc_123_long_id',
              name: 'sys_glob',
              arguments: const <String, dynamic>{'pattern': '**/*.dart'},
            ),
          ],
        ),
      );
      memory.appendToolResultTurn(
        const CanonicalToolResultTurn(
          canonicalCallId: 'call_abc_123_long_id',
          toolName: 'sys_glob',
          content: '{"matches":[]}',
        ),
      );

      final projected = projector.project(
        memory,
        targetProvider: 'openrouter',
        targetModel: 'mistralai/mistral-large',
      );

      final assistantMsg = projected.messages
          .firstWhere((m) => m.role == ProjectedRole.assistant);
      final toolMsg =
          projected.messages.firstWhere((m) => m.role == ProjectedRole.tool);

      // Empty assistant content normalized to "".
      expect(assistantMsg.content, equals(''));
      expect(assistantMsg.toolCalls, hasLength(1));

      final id9 = assistantMsg.toolCalls.first.id;
      expect(id9, matches(RegExp(r'^[a-zA-Z0-9]{9}$')));
      expect(toolMsg.toolCallId, equals(id9));
      expect(toolMsg.toolName, equals('sys_glob'));

      // Deterministic across repeated projections.
      expect(
        CanonicalIrProjector.normalizeToolCallId(
          'sess_ir_01',
          'call_abc_123_long_id',
        ),
        equals(id9),
      );
    });

    test('preserves rawReasoningDetails only when (originProvider, originModel) matches target and strips on switch', () {
      final signaturePayload = <String, dynamic>{
        'type': 'encrypted_thinking',
        'thought_signature': 'sig_opaque_12345',
      };
      memory.appendUserTurn('solve');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: 'openrouter',
          originModel: 'google/gemini-3-pro',
          content: 'answer',
          thoughtText: 'internal thought',
          rawReasoningDetails: signaturePayload,
        ),
      );

      // Same provider and model -> echoes rawReasoningDetails & thoughtText.
      final sameTarget = projector.project(
        memory,
        targetProvider: 'openrouter',
        targetModel: 'google/gemini-3-pro',
      );
      final sameAssistant = sameTarget.messages
          .firstWhere((m) => m.role == ProjectedRole.assistant);
      expect(sameAssistant.rawReasoningDetails, equals(signaturePayload));
      expect(sameAssistant.thoughtText, equals('internal thought'));

      // Different model on same provider -> completely stripped.
      final switchedModel = projector.project(
        memory,
        targetProvider: 'openrouter',
        targetModel: 'anthropic/claude-sonnet-4',
      );
      final diffModelAssistant = switchedModel.messages
          .firstWhere((m) => m.role == ProjectedRole.assistant);
      expect(diffModelAssistant.rawReasoningDetails, isNull);
      expect(diffModelAssistant.thoughtText, isNull);

      // Different provider -> completely stripped.
      final switchedProvider = projector.project(
        memory,
        targetProvider: 'local-ollama',
        targetModel: 'gemma4:12b',
      );
      final diffProviderAssistant = switchedProvider.messages
          .firstWhere((m) => m.role == ProjectedRole.assistant);
      expect(diffProviderAssistant.rawReasoningDetails, isNull);
      expect(diffProviderAssistant.thoughtText, isNull);
    });
  });

  group('ModelIdentifier & LlmUsageTelemetry [D-002], [D-008]', () {
    test('parses valid identifiers splitting on first slash only', () {
      final local = ModelIdentifier.parse('local-ollama/gemma4:12b');
      expect(local.ok, isTrue);
      expect(local.value!.provider, equals(LlmProviderId.localOllama));
      expect(local.value!.modelName, equals('gemma4:12b'));

      final openRouterNested =
          ModelIdentifier.parse('openrouter/anthropic/claude-sonnet-4');
      expect(openRouterNested.ok, isTrue);
      expect(openRouterNested.value!.provider, equals(LlmProviderId.openRouter));
      expect(
        openRouterNested.value!.modelName,
        equals('anthropic/claude-sonnet-4'),
      );

      final cloud = ModelIdentifier.parse('ollama-cloud/gpt-oss:120b');
      expect(cloud.ok, isTrue);
      expect(cloud.value!.provider, equals(LlmProviderId.ollamaCloud));
      expect(cloud.value!.modelName, equals('gpt-oss:120b'));
    });

    test('rejects unknown provider, missing slash, or empty model with EINVAL', () {
      final invalidInputs = <String>[
        '',
        'gemma4:12b',
        'openai/gpt-4o',
        'local-ollama/',
        'openrouter/   ',
        '/gemma4:12b',
      ];

      for (final raw in invalidInputs) {
        final res = ModelIdentifier.parse(raw);
        expect(res.ok, isFalse, reason: 'Expected EINVAL for "$raw"');
        expect(res.error!.code, equals(SyscallErrorCode.einval));
      }
    });

    test('computes cacheHitRate safely including null cachedTokens', () {
      const noCacheStats = LlmUsageTelemetry(
        promptTokens: 500,
        completionTokens: 50,
        cachedTokens: null,
        durationMs: 200,
      );
      expect(noCacheStats.cacheHitRate, isNull);
      expect(noCacheStats.totalTokens, equals(550));

      const withCache = LlmUsageTelemetry(
        promptTokens: 1420,
        completionTokens: 95,
        cachedTokens: 1280,
        durationMs: 1000,
      );
      expect(withCache.cacheHitRate, equals(0.9014));
    });
  });
}
