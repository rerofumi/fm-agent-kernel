import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

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

/// Segment 1 of [VirtualContextMemory]: strictly append-only turn log ([D-007]).
class AppendOnlyHistorySegment {
  final List<CanonicalTurn> _turns = <CanonicalTurn>[];

  /// Read-only view of committed turns in chronological order.
  UnmodifiableListView<CanonicalTurn> get turns =>
      UnmodifiableListView<CanonicalTurn>(_turns);

  /// Appends a completed turn to the tail of Segment 1.
  void append(CanonicalTurn turn) {
    _turns.add(turn);
  }
}

/// Segment 2 of [VirtualContextMemory]: per-turn dynamic tail context ([D-007]).
class EphemeralTailSegment {
  EphemeralTailSegment({
    this.dynamicContextSummary,
    this.currentUserInput,
  });

  String? dynamicContextSummary;
  String? currentUserInput;

  /// Renders the dynamic context and user prompt into a single tail message, or null if empty.
  String? renderTailContent() {
    final parts = <String>[];
    if (dynamicContextSummary != null &&
        dynamicContextSummary!.trim().isNotEmpty) {
      parts.add(dynamicContextSummary!.trim());
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

/// Prefix-preserving 3-segment Canonical IR context store ([D-007]).
class VirtualContextMemory {
  VirtualContextMemory({
    required this.sessionId,
    required PinnedSystemInstruction systemInstruction,
  })  : systemSegment = SystemPinnedSegment(pinned: systemInstruction),
        historySegment = AppendOnlyHistorySegment(),
        ephemeralSegment = EphemeralTailSegment();

  final String sessionId;
  final SystemPinnedSegment systemSegment;
  final AppendOnlyHistorySegment historySegment;
  final EphemeralTailSegment ephemeralSegment;

  /// Appends a user turn to Segment 1.
  void appendUserTurn(String text) {
    historySegment.append(CanonicalUserTurn(text: text));
  }

  /// Appends an assistant turn to Segment 1.
  void appendAssistantTurn(CanonicalAssistantTurn turn) {
    historySegment.append(turn);
  }

  /// Appends a tool result turn to Segment 1.
  void appendToolResultTurn(CanonicalToolResultTurn turn) {
    historySegment.append(turn);
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
