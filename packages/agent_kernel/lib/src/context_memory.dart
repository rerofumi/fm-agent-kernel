import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'context_pager.dart';
import 'llm_driver.dart';

/// Tool schema registered in Segment 0 of [VirtualContextMemory] ([D-007]).
class SyscallToolSchema {
  SyscallToolSchema({
    required this.name,
    required this.description,
    required Map<String, dynamic> parametersJsonSchema,
  }) : parametersJsonSchema =
            Map<String, dynamic>.unmodifiable(parametersJsonSchema);

  final String name;
  final String description;
  final Map<String, dynamic> parametersJsonSchema;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': name,
        'description': description,
        'parameters': parametersJsonSchema,
      },
    };
  }
}

/// Pinned system instruction and sorted tool schemas forming Segment 0 ([D-007]).
class PinnedSystemInstruction {
  PinnedSystemInstruction({
    required this.instruction,
    required List<SyscallToolSchema> tools,
  }) : tools = List<SyscallToolSchema>.unmodifiable(
          (List<SyscallToolSchema>.from(tools)
            ..sort((a, b) => a.name.compareTo(b.name))),
        );

  final String instruction;
  final List<SyscallToolSchema> tools;
}

/// Segment 0 of [VirtualContextMemory]; immutable throughout a session ([D-007]).
class SystemPinnedSegment {
  const SystemPinnedSegment({required this.pinned});

  final PinnedSystemInstruction pinned;
}

/// Canonical tool call emitted by an assistant turn ([D-007]).
class CanonicalToolCall {
  CanonicalToolCall({
    required this.canonicalCallId,
    required this.name,
    required Map<String, dynamic> arguments,
  }) : arguments = Map<String, dynamic>.unmodifiable(arguments);

  final String canonicalCallId;
  final String name;
  final Map<String, dynamic> arguments;
}

/// Base class for append-only conversation turns in Segment 1 ([D-007]).
sealed class CanonicalTurn {
  const CanonicalTurn();
}

/// User prompt turn recorded in Segment 1.
class CanonicalUserTurn extends CanonicalTurn {
  const CanonicalUserTurn({required this.text});

  final String text;
}

/// Assistant response turn recorded in Segment 1 with origin metadata for State Spill prevention ([D-007]).
class CanonicalAssistantTurn extends CanonicalTurn {
  CanonicalAssistantTurn({
    required this.originProvider,
    required this.originModel,
    String? content,
    this.thoughtText,
    this.rawReasoningDetails,
    List<CanonicalToolCall> toolCalls = const <CanonicalToolCall>[],
  })  : content = content ?? '',
        toolCalls = List<CanonicalToolCall>.unmodifiable(toolCalls);

  final String originProvider;
  final String originModel;

  /// Normalized text content (`""` when empty on tool-call-only turns).
  final String content;
  final String? thoughtText;

  /// Provider-specific encrypted reasoning signatures (`reasoning_details` / `thought_signature`).
  final Object? rawReasoningDetails;
  final List<CanonicalToolCall> toolCalls;
}

/// Syscall tool execution result turn recorded in Segment 1.
class CanonicalToolResultTurn extends CanonicalTurn {
  const CanonicalToolResultTurn({
    required this.canonicalCallId,
    required this.toolName,
    required this.content,
    this.isError = false,
  });

  final String canonicalCallId;
  final String toolName;
  final String content;
  final bool isError;
}

/// Deterministic structured summary turn replacing swapped-out Dirty Page Turn Groups ([D-317]).
class CanonicalSummaryTurn extends CanonicalTurn {
  const CanonicalSummaryTurn({
    required this.summaryPageId,
    required this.swapBatchId,
    required this.text,
  });

  final String summaryPageId;
  final String swapBatchId;
  final String text;
}

/// Segment 1 of [VirtualContextMemory]: strictly append-only turn log with in-place Clean Page stub replacement ([D-007], [D-207]).
class AppendOnlyHistorySegment {
  final List<CanonicalTurn> _turns = <CanonicalTurn>[];

  /// Read-only view of committed turns in chronological order.
  UnmodifiableListView<CanonicalTurn> get turns =>
      UnmodifiableListView<CanonicalTurn>(_turns);

  /// Appends a completed turn to the tail of Segment 1.
  void append(CanonicalTurn turn) {
    _turns.add(turn);
  }

  /// Replaces only the `content` of a [CanonicalToolResultTurn] at [turnIndex] with a Page Stub
  /// while preserving its index, `canonicalCallId`, `toolName`, and `isError` ([D-207]).
  void replaceToolResultContentWithStub(int turnIndex, String stubContent) {
    RangeError.checkValidIndex(turnIndex, _turns, 'turnIndex');
    final existing = _turns[turnIndex];
    if (existing is! CanonicalToolResultTurn) {
      throw StateError(
        'Cannot replace turn at index $turnIndex with Page Stub: '
        'expected CanonicalToolResultTurn but found ${existing.runtimeType}.',
      );
    }
    _turns[turnIndex] = CanonicalToolResultTurn(
      canonicalCallId: existing.canonicalCallId,
      toolName: existing.toolName,
      content: stubContent,
      isError: existing.isError,
    );
  }

  /// Collapses an inclusive range `[startIndex .. endIndexInclusive]` of Segment 1 turns
  /// into a single [CanonicalSummaryTurn] after Dirty Page Swap write-back succeeds ([D-317]).
  void replaceTurnRangeWithSummary(
    int startIndex,
    int endIndexInclusive,
    CanonicalSummaryTurn summaryTurn,
  ) {
    RangeError.checkValidRange(
      startIndex,
      endIndexInclusive + 1,
      _turns.length,
      'startIndex',
      'endIndexInclusive',
    );
    _turns.replaceRange(
      startIndex,
      endIndexInclusive + 1,
      <CanonicalTurn>[summaryTurn],
    );
  }
}

/// Segment 2 of [VirtualContextMemory]: per-turn dynamic tail context ([D-007], [D-208]).
class EphemeralTailSegment {
  EphemeralTailSegment({
    this.dynamicContextSummary,
    this.pageDirectorySummary,
    this.currentUserInput,
  });

  String? dynamicContextSummary;

  /// Dynamic `[Context Page Directory]` listing evicted or stale Clean Pages ([D-208]).
  String? pageDirectorySummary;
  String? currentUserInput;

  /// Renders the dynamic context, page directory, and user prompt into a single tail message, or null if empty.
  String? renderTailContent() {
    final parts = <String>[];
    if (dynamicContextSummary != null &&
        dynamicContextSummary!.trim().isNotEmpty) {
      parts.add(dynamicContextSummary!.trim());
    }
    if (pageDirectorySummary != null &&
        pageDirectorySummary!.trim().isNotEmpty) {
      parts.add(pageDirectorySummary!.trim());
    }
    if (currentUserInput != null && currentUserInput!.isNotEmpty) {
      parts.add(currentUserInput!);
    }
    if (parts.isEmpty) {
      return null;
    }
    return parts.join('\n\n');
  }
}

/// Prefix-preserving 3-segment Canonical IR context store with [PageTable] and token anchor ([D-007], [D-204], [D-206]).
class VirtualContextMemory {
  VirtualContextMemory({
    required this.sessionId,
    required PinnedSystemInstruction systemInstruction,
    TokenEstimator estimator = const TokenEstimator(),
  })  : systemSegment = SystemPinnedSegment(pinned: systemInstruction),
        historySegment = AppendOnlyHistorySegment(),
        ephemeralSegment = EphemeralTailSegment(),
        pageTable = PageTable(),
        _estimator = estimator {
    pageTable.registerSystemPinnedPage(
      estimatedTokens: _estimator.estimateSystemSegmentTokens(systemInstruction),
    );
  }

  final String sessionId;
  final SystemPinnedSegment systemSegment;
  final AppendOnlyHistorySegment historySegment;
  final EphemeralTailSegment ephemeralSegment;
  final PageTable pageTable;
  final TokenEstimator _estimator;

  int _currentTurnNumber = 0;
  ModelIdentifier? _lastAnchoredModel;
  int? _lastActualPromptTokens;
  int? _anchorEstimatedBaselineTokens;

  /// Current logical turn counter (incremented on each user turn).
  int get currentTurnNumber => _currentTurnNumber;

  /// Model for which the actual prompt token anchor was last recorded.
  ModelIdentifier? get lastAnchoredModel => _lastAnchoredModel;

  /// Last observed `usage.promptTokens` from a completed LLM inference.
  int? get lastActualPromptTokens => _lastActualPromptTokens;

  /// Heuristic token total at the moment [_lastActualPromptTokens] was recorded.
  int? get anchorEstimatedBaselineTokens => _anchorEstimatedBaselineTokens;

  /// Records an actual `usage.promptTokens` anchor after a successful `sys_llm_chat` ([D-206]).
  void recordActualPromptTokensAnchor({
    required ModelIdentifier model,
    required int actualPromptTokens,
    int? estimatedBaselineTokens,
  }) {
    if (actualPromptTokens <= 0) {
      return;
    }
    _lastAnchoredModel = model;
    _lastActualPromptTokens = actualPromptTokens;
    _anchorEstimatedBaselineTokens =
        estimatedBaselineTokens ?? _estimator.estimateMemoryHeuristicTotal(this);
  }

  /// Invalidates the actual token anchor on model switch or Clean Page eviction ([D-204]).
  void invalidateTokenAnchor() {
    _lastAnchoredModel = null;
    _lastActualPromptTokens = null;
    _anchorEstimatedBaselineTokens = null;
  }

  /// Estimates current prompt tokens using UTF-8 heuristic + actual promptTokens anchor delta ([D-206]).
  int estimateCurrentPromptTokens(
    ModelIdentifier targetModel, {
    TokenEstimator? estimator,
  }) {
    final est = estimator ?? _estimator;
    final currentHeuristicTotal = est.estimateMemoryHeuristicTotal(this);
    if (_lastAnchoredModel == targetModel &&
        _lastActualPromptTokens != null &&
        _anchorEstimatedBaselineTokens != null) {
      final delta = currentHeuristicTotal - _anchorEstimatedBaselineTokens!;
      final segment0Tokens = est.estimateSystemSegmentTokens(
        systemSegment.pinned,
      );
      return math.max(segment0Tokens, _lastActualPromptTokens! + delta);
    }
    return currentHeuristicTotal;
  }

  /// Appends a user turn to Segment 1 and registers a Dirty [ContextPage].
  void appendUserTurn(String text) {
    _currentTurnNumber += 1;
    final turn = CanonicalUserTurn(text: text);
    final turnIndex = historySegment.turns.length;
    historySegment.append(turn);
    pageTable.registerHistoryPage(
      kind: PageKind.conversation,
      historyTurnIndex: turnIndex,
      currentTurn: _currentTurnNumber,
      dirty: true,
      estimatedTokens: _estimator.estimateTurnTokens(turn),
    );
  }

  /// Appends an assistant turn to Segment 1 and registers a Dirty [ContextPage].
  void appendAssistantTurn(CanonicalAssistantTurn turn) {
    final turnIndex = historySegment.turns.length;
    historySegment.append(turn);
    pageTable.registerHistoryPage(
      kind: PageKind.conversation,
      historyTurnIndex: turnIndex,
      currentTurn: _currentTurnNumber,
      dirty: true,
      estimatedTokens: _estimator.estimateTurnTokens(turn),
    );
  }

  /// Appends a tool result turn to Segment 1 and registers either a Clean or Dirty [ContextPage] ([D-206]).
  ContextPage appendToolResultTurn(
    CanonicalToolResultTurn turn, {
    CleanPageSourceMeta? cleanSource,
  }) {
    final turnIndex = historySegment.turns.length;
    historySegment.append(turn);
    final isClean =
        !turn.isError && cleanSource != null && cleanSource.isValidCleanMeta;
    final kind = isClean
        ? (cleanSource.sourceKind == CleanSourceKind.vcsSnapshot
              ? PageKind.vcsView
              : PageKind.fileView)
        : PageKind.toolOutput;
    return pageTable.registerHistoryPage(
      kind: kind,
      historyTurnIndex: turnIndex,
      currentTurn: _currentTurnNumber,
      dirty: !isClean,
      estimatedTokens: _estimator.estimateTurnTokens(turn),
      cleanSource: isClean ? cleanSource : null,
    );
  }
}

/// Normalized tool call inside a [ProjectedMessage] ready for provider wire encoding.
class ProjectedToolCall {
  const ProjectedToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// Deterministic 9-character Base62 ID matching `[a-zA-Z0-9]{9}`.
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

/// Role of a projected message ([D-007]).
enum ProjectedRole {
  system,
  user,
  assistant,
  tool,
}

/// Provider-neutral projected message produced by [CanonicalIrProjector].
class ProjectedMessage {
  ProjectedMessage({
    required this.role,
    required this.content,
    this.thoughtText,
    this.rawReasoningDetails,
    List<ProjectedToolCall> toolCalls = const <ProjectedToolCall>[],
    this.toolCallId,
    this.toolName,
    this.segmentIndex = 1,
  }) : toolCalls = List<ProjectedToolCall>.unmodifiable(toolCalls);

  final ProjectedRole role;
  final String content;
  final String? thoughtText;
  final Object? rawReasoningDetails;
  final List<ProjectedToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;

  /// Source segment index (`0` = system, `1` = append-only history, `2` = ephemeral tail).
  final int segmentIndex;
}

/// Projected prompt structure consumed by [LlmDriver] adapters ([D-007]).
class ProjectedPrompt {
  ProjectedPrompt({
    required List<ProjectedMessage> messages,
    required List<SyscallToolSchema> tools,
  })  : messages = List<ProjectedMessage>.unmodifiable(messages),
        tools = List<SyscallToolSchema>.unmodifiable(tools);

  final List<ProjectedMessage> messages;
  final List<SyscallToolSchema> tools;
}

/// Deterministic projector transforming [VirtualContextMemory] into [ProjectedPrompt] ([D-007]).
class CanonicalIrProjector {
  const CanonicalIrProjector();

  static const String _base62Alphabet =
      '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

  /// Produces a deterministic 9-character Base62 (`[a-zA-Z0-9]{9}`) ID from `SHA-256("$sessionId:$canonicalCallId")`.
  static String normalizeToolCallId(String sessionId, String canonicalCallId) {
    final digest = sha256.convert(utf8.encode('$sessionId:$canonicalCallId'));
    final bytes = digest.bytes;
    var value = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | BigInt.from(bytes[i]);
    }
    final radix = BigInt.from(62);
    final chars = List<String>.filled(9, '0');
    for (var i = 8; i >= 0; i--) {
      final rem = (value % radix).toInt();
      chars[i] = _base62Alphabet[rem];
      value = value ~/ radix;
    }
    return chars.join();
  }

  /// Projects all 3 segments for [targetProvider] and [targetModel] while preventing State Spill ([D-007]).
  ProjectedPrompt project(
    VirtualContextMemory memory, {
    required String targetProvider,
    required String targetModel,
  }) {
    final messages = <ProjectedMessage>[];

    // Segment 0: single pinned system message at index 0, never inserted mid-history.
    messages.add(
      ProjectedMessage(
        role: ProjectedRole.system,
        content: memory.systemSegment.pinned.instruction,
        segmentIndex: 0,
      ),
    );

    // Segment 1: append-only history with deterministic 9-char tool IDs and signature stripping.
    for (final turn in memory.historySegment.turns) {
      switch (turn) {
        case CanonicalUserTurn(:final text):
          messages.add(
            ProjectedMessage(
              role: ProjectedRole.user,
              content: text,
              segmentIndex: 1,
            ),
          );
        case CanonicalAssistantTurn():
          final sameOrigin = turn.originProvider == targetProvider &&
              turn.originModel == targetModel;
          final projectedCalls = turn.toolCalls
              .map(
                (tc) => ProjectedToolCall(
                  id: normalizeToolCallId(memory.sessionId, tc.canonicalCallId),
                  name: tc.name,
                  arguments: tc.arguments,
                ),
              )
              .toList(growable: false);
          messages.add(
            ProjectedMessage(
              role: ProjectedRole.assistant,
              content: turn.content,
              thoughtText: sameOrigin ? turn.thoughtText : null,
              rawReasoningDetails: sameOrigin ? turn.rawReasoningDetails : null,
              toolCalls: projectedCalls,
              segmentIndex: 1,
            ),
          );
        case CanonicalToolResultTurn():
          messages.add(
            ProjectedMessage(
              role: ProjectedRole.tool,
              content: turn.content,
              toolCallId: normalizeToolCallId(
                memory.sessionId,
                turn.canonicalCallId,
              ),
              toolName: turn.toolName,
              segmentIndex: 1,
            ),
          );
        case CanonicalSummaryTurn(:final text):
          messages.add(
            ProjectedMessage(
              role: ProjectedRole.user,
              content: text,
              segmentIndex: 1,
            ),
          );
      }
    }

    // Segment 2: ephemeral dynamic context and current input placed strictly at tail.
    final tailText = memory.ephemeralSegment.renderTailContent();
    if (tailText != null) {
      messages.add(
        ProjectedMessage(
          role: ProjectedRole.user,
          content: tailText,
          segmentIndex: 2,
        ),
      );
    }

    return ProjectedPrompt(
      messages: messages,
      tools: memory.systemSegment.pinned.tools,
    );
  }
}
