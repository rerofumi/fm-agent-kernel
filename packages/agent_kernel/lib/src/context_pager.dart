import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'context_memory.dart';
import 'llm_driver.dart';
import 'syscall_error.dart';

/// Classification of a page tracked in [PageTable] ([D-206]).
enum PageKind {
  /// Segment 0 pinned system instruction and tool schemas (non-evictable).
  systemPinned,

  /// User or assistant turn in Segment 1 (Dirty Page, non-evictable in Stage 2).
  conversation,

  /// Successful file view from `sys_read_lines` or `sys_skill_read` (Clean Page).
  fileView,

  /// Successful VCS/search snapshot from `sys_jj_*`, `sys_glob`, `sys_grep` (Clean Page).
  vcsView,

  /// Side-effecting, non-deterministic, or error tool output (Dirty Page).
  toolOutput,
}

/// Source kind of a Clean Page used for freshness verification ([D-206], [D-208]).
enum CleanSourceKind {
  /// Workspace file verified by SHA-256 and FileStat.
  workspaceFile,

  /// Read-only `/skills` file verified by SHA-256 and FileStat.
  skillFile,

  /// VCS/repository snapshot verified by `jj @` `commit_id`.
  vcsSnapshot,
}

/// Freshness state of a Clean Page relative to the backing workspace/VCS ([D-208]).
enum PageFreshnessStatus {
  fresh,
  stale,
  deleted,
}

/// Immutable origin metadata attached to a Clean Page for `[STALE]` detection and `sys_mem_pagein` ([D-206], [D-208]).
class CleanPageSourceMeta {
  CleanPageSourceMeta({
    required this.sourceKind,
    required this.syscallName,
    required Map<String, dynamic> replayArgs,
    this.virtualPath,
    this.startLine,
    this.endLine,
    this.readSha256,
    this.readModifiedUtc,
    this.readByteLength,
    this.readChangeId,
    this.readCommitId,
    this.readOpId,
  }) : replayArgs = Map<String, dynamic>.unmodifiable(replayArgs);

  final CleanSourceKind sourceKind;
  final String syscallName;
  final Map<String, dynamic> replayArgs;
  final String? virtualPath;
  final int? startLine;
  final int? endLine;
  final String? readSha256;
  final DateTime? readModifiedUtc;
  final int? readByteLength;
  final String? readChangeId;
  final String? readCommitId;
  final String? readOpId;

  /// Returns true if this metadata satisfies the mandatory Clean Page invariants ([D-206]).
  bool get isValidCleanMeta {
    switch (sourceKind) {
      case CleanSourceKind.workspaceFile:
      case CleanSourceKind.skillFile:
        return readSha256 != null && readSha256!.trim().isNotEmpty;
      case CleanSourceKind.vcsSnapshot:
        return readCommitId != null && readCommitId!.trim().isNotEmpty;
    }
  }

  /// Creates a copy with updated freshness/snapshot fields (e.g. after `sys_mem_pagein`).
  CleanPageSourceMeta copyWith({
    CleanSourceKind? sourceKind,
    String? syscallName,
    Map<String, dynamic>? replayArgs,
    String? virtualPath,
    int? startLine,
    int? endLine,
    String? readSha256,
    DateTime? readModifiedUtc,
    int? readByteLength,
    String? readChangeId,
    String? readCommitId,
    String? readOpId,
  }) {
    return CleanPageSourceMeta(
      sourceKind: sourceKind ?? this.sourceKind,
      syscallName: syscallName ?? this.syscallName,
      replayArgs: replayArgs ?? this.replayArgs,
      virtualPath: virtualPath ?? this.virtualPath,
      startLine: startLine ?? this.startLine,
      endLine: endLine ?? this.endLine,
      readSha256: readSha256 ?? this.readSha256,
      readModifiedUtc: readModifiedUtc ?? this.readModifiedUtc,
      readByteLength: readByteLength ?? this.readByteLength,
      readChangeId: readChangeId ?? this.readChangeId,
      readCommitId: readCommitId ?? this.readCommitId,
      readOpId: readOpId ?? this.readOpId,
    );
  }
}

/// Page Table Entry (PTE) representing a single context element in Segment 0 or 1 ([D-206]).
class ContextPage {
  ContextPage({
    required this.pageId,
    required this.kind,
    required this.segmentIndex,
    this.historyTurnIndex,
    required this.createdAtTurn,
    required this.lastReferencedTurn,
    required this.dirty,
    this.pinned = false,
    this.resident = true,
    required this.estimatedTokens,
    this.originalTokens,
    this.cleanSource,
    this.freshness = PageFreshnessStatus.fresh,
  });

  /// Deterministic page identifier: `"pg_0000"` for Segment 0, `"pg_0001"`+ for Segment 1.
  final String pageId;
  final PageKind kind;

  /// Segment index (`0` = pinned system, `1` = append-only history).
  final int segmentIndex;

  /// Zero-based index inside [AppendOnlyHistorySegment.turns] when [segmentIndex] == 1.
  final int? historyTurnIndex;
  final int createdAtTurn;
  int lastReferencedTurn;
  int referenceCount = 1;
  final bool dirty;
  bool pinned;

  /// `true` when full payload is resident; `false` after mechanical stub eviction.
  bool resident;
  int estimatedTokens;
  final int? originalTokens;
  CleanPageSourceMeta? cleanSource;
  PageFreshnessStatus freshness;

  /// Returns true if this page is a valid Clean Page backed by reproducible source metadata.
  bool get isClean => !dirty && cleanSource != null;

  /// Returns true if this page is currently eligible for mechanical stub eviction.
  bool get isEvictable =>
      segmentIndex == 1 &&
      !dirty &&
      resident &&
      !pinned &&
      cleanSource != null &&
      historyTurnIndex != null;
}

/// Tracks all Segment 0 and Segment 1 pages for a [VirtualContextMemory] ([D-206]).
class PageTable {
  final List<ContextPage> _pages = <ContextPage>[];
  final Map<String, ContextPage> _byId = <String, ContextPage>{};
  final Map<int, ContextPage> _byHistoryIndex = <int, ContextPage>{};
  int _nextHistorySeq = 1;

  /// Unmodifiable chronological list of all tracked pages.
  UnmodifiableListView<ContextPage> get pages =>
      UnmodifiableListView<ContextPage>(_pages);

  /// Looks up a page by its [pageId].
  ContextPage? lookup(String pageId) => _byId[pageId];

  /// Looks up the page corresponding to [historyTurnIndex] in Segment 1.
  ContextPage? findByHistoryTurnIndex(int historyTurnIndex) =>
      _byHistoryIndex[historyTurnIndex];

  /// Registers Segment 0 as pinned page `"pg_0000"`.
  ContextPage registerSystemPinnedPage({required int estimatedTokens}) {
    final existing = _byId['pg_0000'];
    if (existing != null) {
      existing.estimatedTokens = estimatedTokens;
      return existing;
    }
    final page = ContextPage(
      pageId: 'pg_0000',
      kind: PageKind.systemPinned,
      segmentIndex: 0,
      historyTurnIndex: null,
      createdAtTurn: 0,
      lastReferencedTurn: 0,
      dirty: false,
      pinned: true,
      resident: true,
      estimatedTokens: estimatedTokens,
      originalTokens: estimatedTokens,
      cleanSource: null,
      freshness: PageFreshnessStatus.fresh,
    );
    _pages.add(page);
    _byId[page.pageId] = page;
    return page;
  }

  /// Registers a new Segment 1 history turn page with a monotonically increasing ID.
  ContextPage registerHistoryPage({
    required PageKind kind,
    required int historyTurnIndex,
    required int currentTurn,
    required bool dirty,
    required int estimatedTokens,
    bool pinned = false,
    CleanPageSourceMeta? cleanSource,
  }) {
    final pageId = 'pg_${_nextHistorySeq.toString().padLeft(4, '0')}';
    _nextHistorySeq += 1;
    final page = ContextPage(
      pageId: pageId,
      kind: kind,
      segmentIndex: 1,
      historyTurnIndex: historyTurnIndex,
      createdAtTurn: currentTurn,
      lastReferencedTurn: currentTurn,
      dirty: dirty,
      pinned: pinned,
      resident: true,
      estimatedTokens: estimatedTokens,
      originalTokens: estimatedTokens,
      cleanSource: dirty ? null : cleanSource,
      freshness: PageFreshnessStatus.fresh,
    );
    _pages.add(page);
    _byId[pageId] = page;
    _byHistoryIndex[historyTurnIndex] = page;
    return page;
  }

  /// Updates reference metadata when a page is accessed (e.g. via `sys_mem_pagein`).
  void touchPage(String pageId, int currentTurn) {
    final page = _byId[pageId];
    if (page == null) {
      return;
    }
    page.lastReferencedTurn = currentTurn;
    page.referenceCount += 1;
  }

  /// All Clean Pages currently tracked in this table.
  Iterable<ContextPage> get cleanPages => _pages.where((p) => p.isClean);

  /// Count of resident Clean Pages.
  int get residentCleanPagesCount =>
      _pages.where((p) => p.isClean && p.resident).length;

  /// Count of evicted (stubbed) Clean Pages.
  int get evictedCleanPagesCount =>
      _pages.where((p) => p.isClean && !p.resident).length;

  /// Count of Clean Pages whose freshness is not [PageFreshnessStatus.fresh].
  int get stalePagesCount => _pages
      .where((p) => p.isClean && p.freshness != PageFreshnessStatus.fresh)
      .length;

  /// Sum of current [ContextPage.estimatedTokens] across Segment 0 and Segment 1.
  int get totalEstimatedTokens =>
      _pages.fold<int>(0, (sum, p) => sum + p.estimatedTokens);

  /// Returns evictable Clean Pages sorted by `(lastReferencedTurn ASC, createdAtTurn ASC, pageId ASC)` ([D-207]).
  List<ContextPage> sortedEvictableCleanPages({
    int? maxHistoryTurnIndexExclusive,
  }) {
    final candidates = _pages.where((p) {
      if (!p.isEvictable) {
        return false;
      }
      if (maxHistoryTurnIndexExclusive != null &&
          p.historyTurnIndex! >= maxHistoryTurnIndexExclusive) {
        return false;
      }
      return true;
    }).toList(growable: false);

    candidates.sort((a, b) {
      final refCmp = a.lastReferencedTurn.compareTo(b.lastReferencedTurn);
      if (refCmp != 0) {
        return refCmp;
      }
      final createdCmp = a.createdAtTurn.compareTo(b.createdAtTurn);
      if (createdCmp != 0) {
        return createdCmp;
      }
      return a.pageId.compareTo(b.pageId);
    });
    return candidates;
  }
}

/// UTF-8 byte-based token estimator avoiding CJK/JSON underestimation ([D-206], `OM-202`).
class TokenEstimator {
  const TokenEstimator();

  /// Per-message chat template structural overhead.
  static const int messageOverheadTokens = 6;

  /// Per-tool schema structural overhead.
  static const int toolSchemaOverheadTokens = 4;

  /// Estimates tokens for a plain string as `ceil(utf8Bytes / 3.0)`.
  int estimateTextTokens(String text) {
    if (text.isEmpty) {
      return 0;
    }
    return (utf8.encode(text).length / 3.0).ceil();
  }

  /// Estimates fixed tokens for Segment 0 (system instruction + tool schemas) ([D-206]).
  int estimateSystemSegmentTokens(PinnedSystemInstruction pinned) {
    var total = estimateTextTokens(pinned.instruction) + messageOverheadTokens;
    for (final tool in pinned.tools) {
      total +=
          estimateTextTokens(jsonEncode(tool.toJson())) +
          toolSchemaOverheadTokens;
    }
    return total;
  }

  /// Estimates tokens for a single Segment 1 [CanonicalTurn].
  int estimateTurnTokens(CanonicalTurn turn) {
    switch (turn) {
      case CanonicalUserTurn(:final text):
        return estimateTextTokens(text) + messageOverheadTokens;
      case CanonicalAssistantTurn():
        var total = estimateTextTokens(turn.content) + messageOverheadTokens;
        if (turn.thoughtText != null && turn.thoughtText!.isNotEmpty) {
          total += estimateTextTokens(turn.thoughtText!);
        }
        for (final tc in turn.toolCalls) {
          total +=
              estimateTextTokens(tc.name) +
              estimateTextTokens(jsonEncode(tc.arguments)) +
              toolSchemaOverheadTokens;
        }
        return total;
      case CanonicalToolResultTurn():
        return estimateTextTokens(turn.content) +
            estimateTextTokens(turn.toolName) +
            messageOverheadTokens;
    }
  }

  /// Estimates tokens for Segment 2 [EphemeralTailSegment].
  int estimateEphemeralSegmentTokens(EphemeralTailSegment ephemeral) {
    final tail = ephemeral.renderTailContent();
    if (tail == null || tail.isEmpty) {
      return 0;
    }
    return estimateTextTokens(tail) + messageOverheadTokens;
  }

  /// Estimates total heuristic prompt tokens across Segments 0, 1, and 2.
  int estimateMemoryHeuristicTotal(VirtualContextMemory memory) {
    var total = estimateSystemSegmentTokens(memory.systemSegment.pinned);
    for (final turn in memory.historySegment.turns) {
      total += estimateTurnTokens(turn);
    }
    total += estimateEphemeralSegmentTokens(memory.ephemeralSegment);
    return total;
  }
}

/// High/Low watermark configuration governing batch Clean Page eviction ([D-207], `OM-202`).
class PagerWatermarkConfig {
  const PagerWatermarkConfig({
    this.highWatermarkRatio = 0.85,
    this.lowWatermarkRatio = 0.55,
    this.minKeepRecentTurns = 1,
  }) : assert(
         lowWatermarkRatio > 0 && lowWatermarkRatio <= highWatermarkRatio,
         'lowWatermarkRatio must be in (0, highWatermarkRatio]',
       ),
       assert(
         highWatermarkRatio <= 1.0,
         'highWatermarkRatio must be <= 1.0',
       ),
       assert(
         minKeepRecentTurns >= 0,
         'minKeepRecentTurns must be >= 0',
       );

  final double highWatermarkRatio;
  final double lowWatermarkRatio;
  final int minKeepRecentTurns;

  int highWatermarkTokens(int effectiveInputBudget) =>
      (effectiveInputBudget * highWatermarkRatio).floor();

  int lowWatermarkTokens(int effectiveInputBudget) =>
      (effectiveInputBudget * lowWatermarkRatio).floor();
}

/// Resolved effective context window specification for a target model ([D-203], [D-209]).
class ContextWindowSpec {
  const ContextWindowSpec({
    required this.contextWindowTokens,
    this.maxCompletionTokens,
    this.isLoadedExact = false,
    this.source = 'fallback',
  });

  final int contextWindowTokens;
  final int? maxCompletionTokens;
  final bool isLoadedExact;
  final String source;

  /// Computes output headroom reservation per `[D-203]` §3.1(2)(4).
  int reservedOutputTokens({int? requestedMaxTokens}) {
    if (requestedMaxTokens != null && requestedMaxTokens > 0) {
      return requestedMaxTokens;
    }
    if (contextWindowTokens <= 2048) {
      return math.max(128, contextWindowTokens ~/ 4);
    }
    final pct = (contextWindowTokens * 0.15).round();
    return pct.clamp(512, 8192);
  }

  /// Computes `effectiveInputBudget = max(256, contextWindow - reservedOutputTokens)` ([D-203]).
  int effectiveInputBudget({int? requestedMaxTokens}) {
    final reserved = reservedOutputTokens(
      requestedMaxTokens: requestedMaxTokens,
    );
    return math.max(256, contextWindowTokens - reserved);
  }
}

/// Abstract Ring 0 interface for resolving model context window sizes ([D-209]).
abstract interface class ContextWindowSource {
  Future<ContextWindowSpec> resolve(
    ModelIdentifier model, {
    bool forceRefreshPs = false,
  });
}

/// Abstract Ring 0 interface for checking Clean Page freshness without side effects ([D-208]).
abstract interface class PageFreshnessChecker {
  /// Returns updated [PageFreshnessStatus] keyed by `pageId` for the given Clean Pages.
  Future<Map<String, PageFreshnessStatus>> checkFreshness(
    Iterable<ContextPage> cleanPages,
  );
}

/// Result summary emitted by [ContextPager] before an LLM inference step ([D-207], [D-215]).
class ContextPagingReport {
  ContextPagingReport({
    required this.effectiveWindowTokens,
    required this.effectiveInputBudget,
    required this.estimatedTokensBefore,
    required this.estimatedTokensAfter,
    required this.evictedPagesInStep,
    required List<String> evictedPageIds,
    required this.residentCleanPages,
    required this.evictedCleanPages,
    required this.stalePagesCount,
  }) : evictedPageIds = List<String>.unmodifiable(evictedPageIds);

  final int effectiveWindowTokens;
  final int effectiveInputBudget;
  final int estimatedTokensBefore;
  final int estimatedTokensAfter;
  final int evictedPagesInStep;
  final List<String> evictedPageIds;
  final int residentCleanPages;
  final int evictedCleanPages;
  final int stalePagesCount;

  bool get didEvict => evictedPagesInStep > 0;
}

/// Batch Clean Page eviction engine and Segment 2 directory renderer ([D-207], [D-208], [D-209]).
class ContextPager {
  const ContextPager({
    this.config = const PagerWatermarkConfig(),
    this.estimator = const TokenEstimator(),
  });

  final PagerWatermarkConfig config;
  final TokenEstimator estimator;

  /// Builds the immutable 1-line mechanical Page Stub replacing an evicted Clean Page ([D-207]).
  String buildPageStub(ContextPage page) {
    final meta = page.cleanSource;
    final origTokens = page.originalTokens ?? page.estimatedTokens;
    if (meta == null) {
      return '[PageOut ${page.pageId}: orig: $origTokens tokens — Evicted clean page.]';
    }

    switch (meta.sourceKind) {
      case CleanSourceKind.workspaceFile:
      case CleanSourceKind.skillFile:
        final pathLabel = meta.virtualPath ?? meta.syscallName;
        final rangePart = (meta.startLine != null && meta.endLine != null)
            ? 'L${meta.startLine}-${meta.endLine}, '
            : '';
        final shortSha = _shortHash(meta.readSha256);
        return '[PageOut ${page.pageId}: $pathLabel (${rangePart}sha256: $shortSha, orig: $origTokens tokens) '
            '— Evicted clean page. Call sys_mem_pagein({"pageId":"${page.pageId}"}) or ${meta.syscallName} to reload.]';
      case CleanSourceKind.vcsSnapshot:
        final argsStr = _formatReplayArgs(meta.replayArgs);
        final argsPart = argsStr.isEmpty ? '' : '$argsStr, ';
        final shortCommit = _shortHash(meta.readCommitId);
        return '[PageOut ${page.pageId}: ${meta.syscallName}(${argsPart}commit: $shortCommit, orig: $origTokens tokens) '
            '— Evicted clean page. Call sys_mem_pagein({"pageId":"${page.pageId}"}) or re-run syscall to reload.]';
    }
  }

  /// Renders Segment 2 `[Context Page Directory]` only when evicted or non-fresh Clean Pages exist ([D-208]).
  String? renderPageDirectorySummary(PageTable pageTable) {
    final entries = pageTable.cleanPages
        .where((p) => !p.resident || p.freshness != PageFreshnessStatus.fresh)
        .toList(growable: false);
    if (entries.isEmpty) {
      return null;
    }

    final lines = <String>['[Context Page Directory]'];
    for (final page in entries) {
      final meta = page.cleanSource!;
      final label = _formatPageDirectoryLabel(meta);
      final status = _formatPageDirectoryStatus(page, meta);
      lines.add('- ${page.pageId}: $label $status');
    }
    return lines.join('\n');
  }

  /// Refreshes Clean Page freshness via [freshnessChecker] (if provided) and updates Segment 2 summary ([D-208]).
  Future<void> refreshFreshness(
    VirtualContextMemory memory, {
    PageFreshnessChecker? freshnessChecker,
  }) async {
    if (freshnessChecker != null) {
      final clean = memory.pageTable.cleanPages.toList(growable: false);
      if (clean.isNotEmpty) {
        final updates = await freshnessChecker.checkFreshness(clean);
        for (final entry in updates.entries) {
          final page = memory.pageTable.lookup(entry.key);
          if (page != null && page.isClean) {
            page.freshness = entry.value;
          }
        }
      }
    }
    memory.ephemeralSegment.pageDirectorySummary = renderPageDirectorySummary(
      memory.pageTable,
    );
  }

  /// Checks frame budget and performs batch Clean Page stub eviction when exceeding watermark or input budget ([D-207], [D-209]).
  ///
  /// When [estimatedTokens] stays at or below high watermark and input budget,
  /// Segment 0 and Segment 1 are not modified by a single byte.
  SyscallResult<ContextPagingReport> prepareFrameForModel({
    required VirtualContextMemory memory,
    required ModelIdentifier targetModel,
    required ContextWindowSpec windowSpec,
    int? requestedMaxTokens,
    bool isModelSwitch = false,
  }) {
    final effectiveInputBudget = windowSpec.effectiveInputBudget(
      requestedMaxTokens: requestedMaxTokens,
    );
    final highWatermark = config.highWatermarkTokens(effectiveInputBudget);
    final lowWatermark = config.lowWatermarkTokens(effectiveInputBudget);

    final modelChanged =
        isModelSwitch ||
        (memory.lastAnchoredModel != null &&
            memory.lastAnchoredModel != targetModel);
    if (modelChanged) {
      memory.invalidateTokenAnchor();
    }

    final estimatedBefore = memory.estimateCurrentPromptTokens(
      targetModel,
      estimator: estimator,
    );

    final needsEviction =
        estimatedBefore > highWatermark ||
        estimatedBefore > effectiveInputBudget;

    if (!needsEviction) {
      return SyscallResult<ContextPagingReport>.success(
        ContextPagingReport(
          effectiveWindowTokens: windowSpec.contextWindowTokens,
          effectiveInputBudget: effectiveInputBudget,
          estimatedTokensBefore: estimatedBefore,
          estimatedTokensAfter: estimatedBefore,
          evictedPagesInStep: 0,
          evictedPageIds: const <String>[],
          residentCleanPages: memory.pageTable.residentCleanPagesCount,
          evictedCleanPages: memory.pageTable.evictedCleanPagesCount,
          stalePagesCount: memory.pageTable.stalePagesCount,
        ),
      );
    }

    final evictedIds = <String>[];
    var currentTokens = estimatedBefore;

    void evictCandidates(List<ContextPage> candidates, int targetTokens) {
      for (final page in candidates) {
        if (currentTokens <= targetTokens) {
          break;
        }
        final turnIdx = page.historyTurnIndex;
        if (turnIdx == null || !page.isEvictable) {
          continue;
        }
        final stubText = buildPageStub(page);
        memory.historySegment.replaceToolResultContentWithStub(
          turnIdx,
          stubText,
        );
        final updatedTurn = memory.historySegment.turns[turnIdx];
        final stubTokens = estimator.estimateTurnTokens(updatedTurn);
        final saved = page.estimatedTokens - stubTokens;
        page.resident = false;
        page.estimatedTokens = stubTokens;
        evictedIds.add(page.pageId);
        if (saved > 0) {
          currentTokens -= saved;
        }
      }
    }

    final totalTurns = memory.historySegment.turns.length;
    final protectTailInFirstPass =
        !modelChanged &&
        estimatedBefore <= effectiveInputBudget &&
        config.minKeepRecentTurns > 0;

    if (protectTailInFirstPass) {
      final maxIdxExclusive = math.max(
        0,
        totalTurns - config.minKeepRecentTurns,
      );
      final firstPassCandidates = memory.pageTable.sortedEvictableCleanPages(
        maxHistoryTurnIndexExclusive: maxIdxExclusive,
      );
      evictCandidates(firstPassCandidates, lowWatermark);
    } else {
      final allCandidates = memory.pageTable.sortedEvictableCleanPages();
      evictCandidates(allCandidates, lowWatermark);
    }

    if (evictedIds.isNotEmpty) {
      memory.invalidateTokenAnchor();
      memory.ephemeralSegment.pageDirectorySummary = renderPageDirectorySummary(
        memory.pageTable,
      );
    }

    var estimatedAfter = memory.estimateCurrentPromptTokens(
      targetModel,
      estimator: estimator,
    );

    // Second pass: if still over effectiveInputBudget (e.g. tail-protected page or directory overhead),
    // evict any remaining evictable Clean Pages including recent tail pages.
    if (estimatedAfter > effectiveInputBudget) {
      final remaining = memory.pageTable.sortedEvictableCleanPages();
      if (remaining.isNotEmpty) {
        currentTokens = estimatedAfter;
        evictCandidates(remaining, lowWatermark);
        if (evictedIds.isNotEmpty) {
          memory.invalidateTokenAnchor();
          memory.ephemeralSegment.pageDirectorySummary =
              renderPageDirectorySummary(memory.pageTable);
        }
        estimatedAfter = memory.estimateCurrentPromptTokens(
          targetModel,
          estimator: estimator,
        );
      }
    }

    if (estimatedAfter > effectiveInputBudget) {
      return SyscallResult<ContextPagingReport>.failure(
        SyscallError(
          code: SyscallErrorCode.edquot,
          reason: 'CONTEXT_FRAME_EXCEEDED',
          message:
              'Non-evictable context ($estimatedAfter tokens) exceeds effective input budget '
              '($effectiveInputBudget tokens) for ${targetModel.canonicalId}.',
          recoverable: true,
          hint:
              'Target model input budget ($effectiveInputBudget tokens) is smaller than '
              'non-evictable conversation history ($estimatedAfter tokens). '
              'Switch to a larger-context model via /model or start a new session.',
          details: <String, dynamic>{
            'model': targetModel.canonicalId,
            'contextWindow': windowSpec.contextWindowTokens,
            'effectiveInputBudget': effectiveInputBudget,
            'estimatedTokens': estimatedAfter,
            'evictedCleanPages': memory.pageTable.evictedCleanPagesCount,
          },
        ),
      );
    }

    return SyscallResult<ContextPagingReport>.success(
      ContextPagingReport(
        effectiveWindowTokens: windowSpec.contextWindowTokens,
        effectiveInputBudget: effectiveInputBudget,
        estimatedTokensBefore: estimatedBefore,
        estimatedTokensAfter: estimatedAfter,
        evictedPagesInStep: evictedIds.length,
        evictedPageIds: evictedIds,
        residentCleanPages: memory.pageTable.residentCleanPagesCount,
        evictedCleanPages: memory.pageTable.evictedCleanPagesCount,
        stalePagesCount: memory.pageTable.stalePagesCount,
      ),
    );
  }

  /// Convenience helper combining freshness refresh and frame preparation before `sys_llm_chat`.
  Future<SyscallResult<ContextPagingReport>> refreshAndPrepareFrame({
    required VirtualContextMemory memory,
    required ModelIdentifier targetModel,
    required ContextWindowSpec windowSpec,
    PageFreshnessChecker? freshnessChecker,
    int? requestedMaxTokens,
    bool isModelSwitch = false,
  }) async {
    await refreshFreshness(memory, freshnessChecker: freshnessChecker);
    return prepareFrameForModel(
      memory: memory,
      targetModel: targetModel,
      windowSpec: windowSpec,
      requestedMaxTokens: requestedMaxTokens,
      isModelSwitch: isModelSwitch,
    );
  }

  static String _shortHash(String? hash) {
    if (hash == null || hash.isEmpty) {
      return 'unknown';
    }
    return hash.length <= 12 ? hash : hash.substring(0, 12);
  }

  static String _formatReplayArgs(Map<String, dynamic> replayArgs) {
    if (replayArgs.isEmpty) {
      return '';
    }
    final keys = replayArgs.keys.toList(growable: false)..sort();
    final parts = <String>[];
    for (final k in keys) {
      final v = replayArgs[k];
      if (v == null) {
        continue;
      }
      if (v is String) {
        parts.add('$k="$v"');
      } else {
        parts.add('$k=$v');
      }
    }
    return parts.join(', ');
  }

  static String _formatPageDirectoryLabel(CleanPageSourceMeta meta) {
    switch (meta.sourceKind) {
      case CleanSourceKind.workspaceFile:
      case CleanSourceKind.skillFile:
        final pathLabel = meta.virtualPath ?? meta.syscallName;
        if (meta.startLine != null && meta.endLine != null) {
          return '$pathLabel (L${meta.startLine}-${meta.endLine})';
        }
        return pathLabel;
      case CleanSourceKind.vcsSnapshot:
        final argsStr = _formatReplayArgs(meta.replayArgs);
        return '${meta.syscallName}($argsStr)';
    }
  }

  static String _formatPageDirectoryStatus(
    ContextPage page,
    CleanPageSourceMeta meta,
  ) {
    final residence = page.resident ? 'RESIDENT' : 'EVICTED';
    switch (page.freshness) {
      case PageFreshnessStatus.fresh:
        return '[$residence | FRESH — reload with sys_mem_pagein({"pageId":"${page.pageId}"})]';
      case PageFreshnessStatus.stale:
        if (page.resident) {
          return '[$residence | STALE: modified since read — re-read latest before editing]';
        }
        return '[$residence | STALE: modified since read — reload with sys_mem_pagein({"pageId":"${page.pageId}"}) or ${meta.syscallName}]';
      case PageFreshnessStatus.deleted:
        return '[$residence | STALE: DELETED — source no longer exists]';
    }
  }
}
