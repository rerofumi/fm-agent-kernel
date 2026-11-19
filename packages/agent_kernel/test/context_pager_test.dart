import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

class _FakeFreshnessChecker implements PageFreshnessChecker {
  _FakeFreshnessChecker(this.statuses);

  final Map<String, PageFreshnessStatus> statuses;

  @override
  Future<Map<String, PageFreshnessStatus>> checkFreshness(
    Iterable<ContextPage> cleanPages,
  ) async {
    return <String, PageFreshnessStatus>{
      for (final page in cleanPages)
        if (statuses.containsKey(page.pageId))
          page.pageId: statuses[page.pageId]!,
    };
  }
}

VirtualContextMemory _createMemory({
  String sessionId = 'sess_pager_01',
  String instruction = 'You are a test agent.',
}) {
  return VirtualContextMemory(
    sessionId: sessionId,
    systemInstruction: PinnedSystemInstruction(
      instruction: instruction,
      tools: <SyscallToolSchema>[
        SyscallToolSchema(
          name: 'sys_read_lines',
          description: 'Read lines from a file.',
          parametersJsonSchema: const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
            },
          },
        ),
        SyscallToolSchema(
          name: 'sys_mem_pagein',
          description: 'Reload an evicted clean page.',
          parametersJsonSchema: const <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'pageId': <String, dynamic>{'type': 'string'},
            },
          },
        ),
      ],
    ),
  );
}

List<String> _snapshotSegment0And1(ProjectedPrompt prompt) {
  return prompt.messages
      .where((m) => m.segmentIndex == 0 || m.segmentIndex == 1)
      .map(
        (m) => jsonEncode(<String, dynamic>{
          'segment': m.segmentIndex,
          'role': m.role.name,
          'content': m.content,
          'toolCallId': m.toolCallId,
          'toolName': m.toolName,
          'toolCalls': m.toolCalls
              .map(
                (tc) => <String, dynamic>{
                  'id': tc.id,
                  'name': tc.name,
                  'arguments': tc.arguments,
                },
              )
              .toList(),
        }),
      )
      .toList(growable: false);
}

void main() {
  const localModel = ModelIdentifier(
    provider: LlmProviderId.localOllama,
    modelName: 'gemma4:12b',
  );
  const cloudModel = ModelIdentifier(
    provider: LlmProviderId.openRouter,
    modelName: 'openai/gpt-4o-mini',
  );
  const projector = CanonicalIrProjector();

  group('TokenEstimator & Anchor Correction [D-204], [D-206]', () {
    test('estimates Japanese and JSON/Hex safely above naive chars/4', () {
      const estimator = TokenEstimator();
      const japaneseDoc =
          '日本語の設計ドキュメントでは1文字あたり3バイトのUTF-8表現となるため、'
          '文字数ベースの簡易推定 chars/4 では実トークン数の半分以下に過小評価されてしまう。'
          'UTF-8バイト長を3.0で割って切り上げることで安全側に見積もる。';
      const jsonHexOutput =
          '{"path":"/workspace/lib/src/pcb.dart","sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","lines":["1: final a = 0x1a2b3c4d;","2: final b = 0xdeadbeef;"]}';

      final jpEstimate = estimator.estimateTextTokens(japaneseDoc);
      final jpNaive = (japaneseDoc.length / 4.0).ceil();
      expect(jpEstimate, equals((utf8.encode(japaneseDoc).length / 3.0).ceil()));
      expect(jpEstimate, greaterThan(jpNaive * 2));

      final jsonEstimate = estimator.estimateTextTokens(jsonHexOutput);
      final jsonNaive = (jsonHexOutput.length / 4.0).ceil();
      expect(
        jsonEstimate,
        equals((utf8.encode(jsonHexOutput).length / 3.0).ceil()),
      );
      expect(jsonEstimate, greaterThan(jsonNaive));
      expect(estimator.estimateTextTokens(''), equals(0));
    });

    test('applies actual promptTokens anchor delta and resets on model switch', () {
      final memory = _createMemory();
      const estimator = TokenEstimator();

      memory.appendUserTurn('Hello, inspect pcb.dart please.');
      final baselineHeuristic = estimator.estimateMemoryHeuristicTotal(memory);
      expect(memory.estimateCurrentPromptTokens(localModel), equals(baselineHeuristic));

      // Record actual provider promptTokens (e.g. 500 tokens).
      memory.recordActualPromptTokensAnchor(
        model: localModel,
        actualPromptTokens: 500,
        estimatedBaselineTokens: baselineHeuristic,
      );
      expect(memory.estimateCurrentPromptTokens(localModel), equals(500));

      // Append new turn -> anchored estimate shifts by heuristic delta.
      memory.appendUserTurn('Now explain CapabilityTable in detail.');
      final afterHeuristic = estimator.estimateMemoryHeuristicTotal(memory);
      final expectedDelta = afterHeuristic - baselineHeuristic;
      expect(
        memory.estimateCurrentPromptTokens(localModel),
        equals(500 + expectedDelta),
      );

      // Switching model falls back to pure heuristic (no stale cross-model anchor).
      expect(
        memory.estimateCurrentPromptTokens(cloudModel),
        equals(afterHeuristic),
      );

      // Explicit invalidation clears anchor fields.
      memory.invalidateTokenAnchor();
      expect(memory.lastAnchoredModel, isNull);
      expect(memory.lastActualPromptTokens, isNull);
      expect(memory.anchorEstimatedBaselineTokens, isNull);
      expect(
        memory.estimateCurrentPromptTokens(localModel),
        equals(afterHeuristic),
      );
    });
  });

  group('Clean vs Dirty Page Classification [D-206]', () {
    test('classifies valid file/VCS reads as Clean and errors/mutations as Dirty', () {
      final memory = _createMemory();
      memory.appendUserTurn('Read files and run edit.');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: localModel.provider.id,
          originModel: localModel.modelName,
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'tc_1',
              name: 'sys_read_lines',
              arguments: const <String, dynamic>{'path': '/workspace/a.dart'},
            ),
            CanonicalToolCall(
              canonicalCallId: 'tc_2',
              name: 'sys_jj_diff',
              arguments: const <String, dynamic>{'rev': '@'},
            ),
            CanonicalToolCall(
              canonicalCallId: 'tc_3',
              name: 'sys_read_lines',
              arguments: const <String, dynamic>{'path': '/workspace/missing.dart'},
            ),
            CanonicalToolCall(
              canonicalCallId: 'tc_4',
              name: 'sys_edit_block',
              arguments: const <String, dynamic>{'path': '/workspace/a.dart'},
            ),
          ],
        ),
      );

      final filePage = memory.appendToolResultTurn(
        const CanonicalToolResultTurn(
          canonicalCallId: 'tc_1',
          toolName: 'sys_read_lines',
          content: 'line 1\nline 2',
        ),
        cleanSource: CleanPageSourceMeta(
          sourceKind: CleanSourceKind.workspaceFile,
          syscallName: 'sys_read_lines',
          replayArgs: const <String, dynamic>{'path': '/workspace/a.dart'},
          virtualPath: '/workspace/a.dart',
          startLine: 1,
          endLine: 2,
          readSha256: '9f86d081884c7d659a2feaa0c55ad015',
        ),
      );

      final vcsPage = memory.appendToolResultTurn(
        const CanonicalToolResultTurn(
          canonicalCallId: 'tc_2',
          toolName: 'sys_jj_diff',
          content: 'diff --git a/a.dart b/a.dart',
        ),
        cleanSource: CleanPageSourceMeta(
          sourceKind: CleanSourceKind.vcsSnapshot,
          syscallName: 'sys_jj_diff',
          replayArgs: const <String, dynamic>{'rev': '@'},
          readCommitId: 'a1b2c3d4e5f600001111222233334444',
        ),
      );

      // Error tool result must remain Dirty even if cleanSource was supplied.
      final errorPage = memory.appendToolResultTurn(
        const CanonicalToolResultTurn(
          canonicalCallId: 'tc_3',
          toolName: 'sys_read_lines',
          content: '{"code":"ENOENT"}',
          isError: true,
        ),
        cleanSource: CleanPageSourceMeta(
          sourceKind: CleanSourceKind.workspaceFile,
          syscallName: 'sys_read_lines',
          replayArgs: const <String, dynamic>{'path': '/workspace/missing.dart'},
          virtualPath: '/workspace/missing.dart',
          readSha256: 'should_not_be_clean',
        ),
      );

      // Mutation syscall without cleanSource is Dirty.
      final editPage = memory.appendToolResultTurn(
        const CanonicalToolResultTurn(
          canonicalCallId: 'tc_4',
          toolName: 'sys_edit_block',
          content: '{"ok":true}',
        ),
      );

      expect(memory.pageTable.lookup('pg_0000')?.pinned, isTrue);
      expect(filePage.isClean, isTrue);
      expect(filePage.kind, equals(PageKind.fileView));
      expect(vcsPage.isClean, isTrue);
      expect(vcsPage.kind, equals(PageKind.vcsView));
      expect(errorPage.dirty, isTrue);
      expect(errorPage.isClean, isFalse);
      expect(editPage.dirty, isTrue);
      expect(editPage.isClean, isFalse);
      expect(memory.pageTable.residentCleanPagesCount, equals(2));
    });
  });

  group('ContextPager Batch Eviction, Prefix Invariance & Tool Pair Integrity [D-207], [D-208], [D-209]', () {
    test('preserves Segment 0 and Segment 1 byte-for-byte when below high watermark', () {
      final memory = _createMemory();
      const pager = ContextPager();

      memory.appendUserTurn('Inspect lib/a.dart');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: localModel.provider.id,
          originModel: localModel.modelName,
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'call_normal_1',
              name: 'sys_read_lines',
              arguments: const <String, dynamic>{'path': '/workspace/lib/a.dart'},
            ),
          ],
        ),
      );
      memory.appendToolResultTurn(
        const CanonicalToolResultTurn(
          canonicalCallId: 'call_normal_1',
          toolName: 'sys_read_lines',
          content: 'int a = 1;\nint b = 2;',
        ),
        cleanSource: CleanPageSourceMeta(
          sourceKind: CleanSourceKind.workspaceFile,
          syscallName: 'sys_read_lines',
          replayArgs: const <String, dynamic>{'path': '/workspace/lib/a.dart'},
          virtualPath: '/workspace/lib/a.dart',
          startLine: 1,
          endLine: 2,
          readSha256: '1234567890abcdef1234567890abcdef',
        ),
      );

      final beforeSnapshot = _snapshotSegment0And1(
        projector.project(
          memory,
          targetProvider: localModel.provider.id,
          targetModel: localModel.modelName,
        ),
      );

      final result = pager.prepareFrameForModel(
        memory: memory,
        targetModel: localModel,
        windowSpec: const ContextWindowSpec(contextWindowTokens: 32768),
      );

      expect(result.isSuccess, isTrue);
      expect(result.value!.evictedPagesInStep, equals(0));
      expect(result.value!.didEvict, isFalse);
      expect(memory.ephemeralSegment.pageDirectorySummary, isNull);

      final afterSnapshot = _snapshotSegment0And1(
        projector.project(
          memory,
          targetProvider: localModel.provider.id,
          targetModel: localModel.modelName,
        ),
      );
      expect(afterSnapshot, equals(beforeSnapshot));
    });

    test('batch-evicts oldest Clean Pages from high to low watermark while preserving tool_call_id pairs and Dirty/Pinned pages', () {
      final memory = _createMemory();
      const pager = ContextPager(
        config: PagerWatermarkConfig(
          highWatermarkRatio: 0.85,
          lowWatermarkRatio: 0.55,
          minKeepRecentTurns: 1,
        ),
      );

      // Build 5 clean file reads across 5 turns + 1 pinned clean page + 1 dirty exec output.
      final bigBody = List<String>.filled(120, 'final line = "0123456789abcdef";').join('\n');
      final cleanPages = <ContextPage>[];

      for (var i = 1; i <= 5; i++) {
        memory.appendUserTurn('Turn $i: read file_$i.dart');
        final callId = 'call_file_$i';
        memory.appendAssistantTurn(
          CanonicalAssistantTurn(
            originProvider: localModel.provider.id,
            originModel: localModel.modelName,
            toolCalls: <CanonicalToolCall>[
              CanonicalToolCall(
                canonicalCallId: callId,
                name: 'sys_read_lines',
                arguments: <String, dynamic>{'path': '/workspace/file_$i.dart'},
              ),
            ],
          ),
        );
        final page = memory.appendToolResultTurn(
          CanonicalToolResultTurn(
            canonicalCallId: callId,
            toolName: 'sys_read_lines',
            content: bigBody,
          ),
          cleanSource: CleanPageSourceMeta(
            sourceKind: CleanSourceKind.workspaceFile,
            syscallName: 'sys_read_lines',
            replayArgs: <String, dynamic>{
              'path': '/workspace/file_$i.dart',
              'startLine': 1,
              'endLine': 120,
            },
            virtualPath: '/workspace/file_$i.dart',
            startLine: 1,
            endLine: 120,
            readSha256: 'sha256file000$i' '0000000000000000',
          ),
        );
        cleanPages.add(page);
      }

      // Pin cleanPages[0] (file_1) so it must NOT be evicted.
      cleanPages[0].pinned = true;

      // Add a dirty sys_exec result before the tail clean page.
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: localModel.provider.id,
          originModel: localModel.modelName,
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'call_exec_1',
              name: 'sys_exec',
              arguments: const <String, dynamic>{'cmd': 'dart test'},
            ),
          ],
        ),
      );
      final dirtyExecPage = memory.appendToolResultTurn(
        const CanonicalToolResultTurn(
          canonicalCallId: 'call_exec_1',
          toolName: 'sys_exec',
          content: 'All tests passed!',
        ),
      );

      // Anchor before eviction to verify anchor is invalidated after eviction.
      final totalNow = const TokenEstimator().estimateMemoryHeuristicTotal(memory);
      memory.recordActualPromptTokensAnchor(
        model: localModel,
        actualPromptTokens: totalNow,
        estimatedBaselineTokens: totalNow,
      );

      // Choose a window where effectiveInputBudget puts totalNow strictly above 85% high watermark
      // but below 100% effectiveInputBudget so normal batch eviction triggers.
      final targetBudget = (totalNow / 0.92).ceil();
      final windowTokens = targetBudget + 1024;
      final spec = ContextWindowSpec(contextWindowTokens: windowTokens);

      final result = pager.prepareFrameForModel(
        memory: memory,
        targetModel: localModel,
        windowSpec: spec,
        requestedMaxTokens: 1024,
      );

      expect(result.isSuccess, isTrue);
      final report = result.value!;
      expect(report.didEvict, isTrue);
      expect(report.evictedPagesInStep, greaterThanOrEqualTo(2));
      expect(
        report.estimatedTokensAfter,
        lessThanOrEqualTo(pager.config.highWatermarkTokens(report.effectiveInputBudget)),
      );

      // Pinned page (file_1) and dirty exec page must remain intact and resident.
      expect(cleanPages[0].resident, isTrue);
      expect(dirtyExecPage.resident, isTrue);
      expect(
        (memory.historySegment.turns[dirtyExecPage.historyTurnIndex!]
                as CanonicalToolResultTurn)
            .content,
        equals('All tests passed!'),
      );

      // Oldest unpinned Clean Page (file_2) must be evicted first.
      expect(cleanPages[1].resident, isFalse);
      final evictedTurn =
          memory.historySegment.turns[cleanPages[1].historyTurnIndex!]
              as CanonicalToolResultTurn;
      expect(evictedTurn.content, startsWith('[PageOut ${cleanPages[1].pageId}:'));
      expect(evictedTurn.content, contains('sys_mem_pagein({"pageId":"${cleanPages[1].pageId}"})'));

      // Anchor must be invalidated after eviction ([D-204]).
      expect(memory.lastActualPromptTokens, isNull);

      // Segment 2 PageDirectorySummary must list evicted pages.
      expect(memory.ephemeralSegment.pageDirectorySummary, isNotNull);
      expect(
        memory.ephemeralSegment.pageDirectorySummary,
        contains('[Context Page Directory]'),
      );
      expect(
        memory.ephemeralSegment.pageDirectorySummary,
        contains('${cleanPages[1].pageId}: /workspace/file_2.dart (L1-120) [EVICTED | FRESH'),
      );

      // Tool call ID 1:1 pairing must remain 100% intact across ProjectedPrompt.
      final projected = projector.project(
        memory,
        targetProvider: localModel.provider.id,
        targetModel: localModel.modelName,
      );
      final assistantCallIds = <String>[];
      final toolResultCallIds = <String>[];
      for (final msg in projected.messages) {
        if (msg.role == ProjectedRole.assistant) {
          assistantCallIds.addAll(msg.toolCalls.map((tc) => tc.id));
        } else if (msg.role == ProjectedRole.tool) {
          toolResultCallIds.add(msg.toolCallId!);
        }
      }
      expect(toolResultCallIds, equals(assistantCallIds));
      for (final id in assistantCallIds) {
        expect(id, matches(RegExp(r'^[a-zA-Z0-9]{9}$')));
      }
    });

    test('renders [STALE] and DELETED in Segment 2 without mutating Segment 1 stubs', () async {
      final memory = _createMemory();
      const pager = ContextPager();

      memory.appendUserTurn('Read two files.');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: localModel.provider.id,
          originModel: localModel.modelName,
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'c1',
              name: 'sys_read_lines',
              arguments: const <String, dynamic>{'path': '/workspace/a.dart'},
            ),
            CanonicalToolCall(
              canonicalCallId: 'c2',
              name: 'sys_read_lines',
              arguments: const <String, dynamic>{'path': '/workspace/b.dart'},
            ),
          ],
        ),
      );

      final pageA = memory.appendToolResultTurn(
        CanonicalToolResultTurn(
          canonicalCallId: 'c1',
          toolName: 'sys_read_lines',
          content: List<String>.filled(200, 'int a = 1;').join('\n'),
        ),
        cleanSource: CleanPageSourceMeta(
          sourceKind: CleanSourceKind.workspaceFile,
          syscallName: 'sys_read_lines',
          replayArgs: const <String, dynamic>{'path': '/workspace/a.dart'},
          virtualPath: '/workspace/a.dart',
          startLine: 1,
          endLine: 200,
          readSha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      );
      final pageB = memory.appendToolResultTurn(
        const CanonicalToolResultTurn(
          canonicalCallId: 'c2',
          toolName: 'sys_read_lines',
          content: 'int b = 2;',
        ),
        cleanSource: CleanPageSourceMeta(
          sourceKind: CleanSourceKind.workspaceFile,
          syscallName: 'sys_read_lines',
          replayArgs: const <String, dynamic>{'path': '/workspace/b.dart'},
          virtualPath: '/workspace/b.dart',
          startLine: 1,
          endLine: 1,
          readSha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      );

      // Force eviction of pageA via small window.
      final res = pager.prepareFrameForModel(
        memory: memory,
        targetModel: localModel,
        windowSpec: const ContextWindowSpec(contextWindowTokens: 1024),
        isModelSwitch: true,
      );
      expect(res.isSuccess, isTrue);
      expect(pageA.resident, isFalse);

      final segment1BeforeStale = _snapshotSegment0And1(
        projector.project(
          memory,
          targetProvider: localModel.provider.id,
          targetModel: localModel.modelName,
        ),
      );

      // Mark evicted pageA as STALE and resident pageB as DELETED.
      await pager.refreshFreshness(
        memory,
        freshnessChecker: _FakeFreshnessChecker(<String, PageFreshnessStatus>{
          pageA.pageId: PageFreshnessStatus.stale,
          pageB.pageId: PageFreshnessStatus.deleted,
        }),
      );

      // Segment 1 must be byte-for-byte identical after freshness changes ([D-208]).
      final segment1AfterStale = _snapshotSegment0And1(
        projector.project(
          memory,
          targetProvider: localModel.provider.id,
          targetModel: localModel.modelName,
        ),
      );
      expect(segment1AfterStale, equals(segment1BeforeStale));

      // Segment 2 PageDirectorySummary reflects both statuses.
      final dir = memory.ephemeralSegment.pageDirectorySummary!;
      expect(dir, contains('[EVICTED | STALE: modified since read'));
      expect(dir, contains('[RESIDENT | STALE: DELETED'));
      expect(memory.pageTable.stalePagesCount, equals(2));
    });

    test('returns EDQUOT CONTEXT_FRAME_EXCEEDED without silent truncation when Dirty Pages exceed target budget', () {
      final memory = _createMemory();
      const pager = ContextPager();

      // Add large Dirty conversation turns (cannot be evicted in Stage 2).
      final hugeDirtyText = List<String>.filled(600, 'Important user requirements and decisions. ').join();
      memory.appendUserTurn(hugeDirtyText);

      // Switch to tiny 2048-token window -> effectiveInputBudget = 1536 tokens.
      final result = pager.prepareFrameForModel(
        memory: memory,
        targetModel: localModel,
        windowSpec: const ContextWindowSpec(contextWindowTokens: 2048),
        isModelSwitch: true,
      );

      expect(result.isFailure, isTrue);
      final err = result.error!;
      expect(err.code, equals(SyscallErrorCode.edquot));
      expect(err.reason, equals('CONTEXT_FRAME_EXCEEDED'));
      expect(err.recoverable, isTrue);
      expect(err.details?['model'], equals(localModel.canonicalId));
      expect(err.details?['effectiveInputBudget'], equals(1536));

      // Dirty turn must NOT have been silently truncated or dropped.
      expect(memory.historySegment.turns, hasLength(1));
      expect((memory.historySegment.turns.first as CanonicalUserTurn).text, equals(hugeDirtyText));
    });

    test('computes ContextWindowSpec output headroom and effectiveInputBudget per [D-203]', () {
      // Standard 32k window: 15% = 4915 (within 512..8192).
      const w32k = ContextWindowSpec(contextWindowTokens: 32768);
      expect(w32k.reservedOutputTokens(), equals(4915));
      expect(w32k.effectiveInputBudget(), equals(32768 - 4915));

      // Large 128k window: 15% clamped at 8192.
      const w128k = ContextWindowSpec(contextWindowTokens: 131072);
      expect(w128k.reservedOutputTokens(), equals(8192));
      expect(w128k.effectiveInputBudget(), equals(131072 - 8192));

      // Small 2048 window: max(128, 2048 ~/ 4) = 512.
      const w2k = ContextWindowSpec(contextWindowTokens: 2048);
      expect(w2k.reservedOutputTokens(), equals(512));
      expect(w2k.effectiveInputBudget(), equals(1536));

      // Explicit requestedMaxTokens overrides default headroom.
      expect(w32k.reservedOutputTokens(requestedMaxTokens: 2000), equals(2000));
      expect(w32k.effectiveInputBudget(requestedMaxTokens: 2000), equals(30768));
    });
  });

  group('Stage 2 CapRight enumeration [D-213]', () {
    test('includes all Stage 1 and Stage 2 capability rights', () {
      expect(
        CapRight.values,
        containsAll(<CapRight>[
          CapRight.read,
          CapRight.writeCow,
          CapRight.exec,
          CapRight.vcsRead,
          CapRight.vcsTx,
          CapRight.llmInfer,
          CapRight.admin,
          CapRight.memManage,
          CapRight.procSpawn,
          CapRight.procSelf,
          CapRight.ipc,
          CapRight.netRead,
        ]),
      );
    });
  });
}
