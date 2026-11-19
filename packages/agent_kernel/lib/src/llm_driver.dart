import 'cancellation.dart';
import 'context_memory.dart';
import 'syscall_error.dart';

/// Supported Stage 1 LLM provider identifiers ([D-002], [D-008], [D-009]).
enum LlmProviderId {
  localOllama('local-ollama'),
  ollamaCloud('ollama-cloud'),
  openRouter('openrouter');

  const LlmProviderId(this.id);

  final String id;

  static LlmProviderId? tryParse(String raw) {
    for (final value in values) {
      if (value.id == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Normalized `<providerId>/<modelName>` identifier split on the first `/` ([D-002]).
class ModelIdentifier {
  const ModelIdentifier({
    required this.provider,
    required this.modelName,
  });

  final LlmProviderId provider;
  final String modelName;

  /// Canonical `<providerId>/<modelName>` string.
  String get canonicalId => '${provider.id}/$modelName';

  /// Parses [raw] by splitting on the first `/`, returning `EINVAL` on unknown provider or empty model.
  static SyscallResult<ModelIdentifier> parse(String raw) {
    final trimmed = raw.trim();
    final slashIdx = trimmed.indexOf('/');
    if (slashIdx <= 0) {
      return SyscallResult<ModelIdentifier>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_MODEL_IDENTIFIER',
          message:
              'Model identifier "$raw" must follow "<providerId>/<modelName>" format.',
          recoverable: true,
          hint:
              'Use local-ollama/<model>, ollama-cloud/<model>, or openrouter/<model>.',
        ),
      );
    }

    final providerStr = trimmed.substring(0, slashIdx);
    final modelName = trimmed.substring(slashIdx + 1).trim();
    final provider = LlmProviderId.tryParse(providerStr);
    if (provider == null) {
      return SyscallResult<ModelIdentifier>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'UNKNOWN_PROVIDER',
          message: 'Unknown LLM provider "$providerStr" in "$raw".',
          recoverable: true,
          hint: 'Supported providers: local-ollama, ollama-cloud, openrouter.',
        ),
      );
    }
    if (modelName.isEmpty) {
      return SyscallResult<ModelIdentifier>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'EMPTY_MODEL_NAME',
          message: 'Model name must not be empty in "$raw".',
          recoverable: true,
        ),
      );
    }

    return SyscallResult<ModelIdentifier>.success(
      ModelIdentifier(provider: provider, modelName: modelName),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ModelIdentifier &&
        other.provider == provider &&
        other.modelName == modelName;
  }

  @override
  int get hashCode => Object.hash(provider, modelName);

  @override
  String toString() => canonicalId;
}

/// Tool call specification returned by an LLM driver ([D-008]).
class LlmToolCallSpec {
  LlmToolCallSpec({
    required this.id,
    required this.name,
    required Map<String, dynamic> arguments,
  }) : arguments = Map<String, dynamic>.unmodifiable(arguments);

  final String id;
  final String name;
  final Map<String, dynamic> arguments;
}

/// Token, KV-cache, cost, and latency telemetry emitted on LLM completion ([D-008], [D-010]).
class LlmUsageTelemetry {
  const LlmUsageTelemetry({
    required this.promptTokens,
    required this.completionTokens,
    int? totalTokens,
    this.cachedTokens,
    this.cacheWriteTokens,
    this.costMicroUsd,
    this.cacheDiscountUsd,
    this.ttftMs,
    required this.durationMs,
  }) : totalTokens = totalTokens ?? (promptTokens + completionTokens);

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int? cachedTokens;
  final int? cacheWriteTokens;
  final int? costMicroUsd;
  final double? cacheDiscountUsd;
  final int? ttftMs;
  final int durationMs;

  /// Cache hit rate rounded to 4 decimal places (`null` when [cachedTokens] is null or `promptTokens <= 0`).
  double? get cacheHitRate {
    if (cachedTokens == null || promptTokens <= 0) {
      return null;
    }
    return double.parse((cachedTokens! / promptTokens).toStringAsFixed(4));
  }
}

/// Final aggregated response from an [LlmDriver] stream ([D-008]).
class LlmChatResponse {
  LlmChatResponse({
    String? content,
    this.thoughtText,
    this.rawReasoningDetails,
    List<LlmToolCallSpec> toolCalls = const <LlmToolCallSpec>[],
    required this.usage,
    this.finishReason = 'stop',
    this.endpoint,
  })  : content = content ?? '',
        toolCalls = List<LlmToolCallSpec>.unmodifiable(toolCalls);

  final String content;
  final String? thoughtText;
  final Object? rawReasoningDetails;
  final List<LlmToolCallSpec> toolCalls;
  final LlmUsageTelemetry usage;
  final String finishReason;
  final String? endpoint;
}

/// Streaming events yielded by [LlmDriver.chatStream] ([D-008]).
sealed class LlmStreamEvent {
  const LlmStreamEvent();
}

/// Incremental reasoning/thinking chunk.
class LlmThoughtDelta extends LlmStreamEvent {
  const LlmThoughtDelta(this.text);

  final String text;
}

/// Incremental assistant message text chunk.
class LlmTextDelta extends LlmStreamEvent {
  const LlmTextDelta(this.text);

  final String text;
}

/// Tool call emitted during or at the end of a stream.
class LlmToolCallEvent extends LlmStreamEvent {
  const LlmToolCallEvent(this.toolCall);

  final LlmToolCallSpec toolCall;
}

/// Terminal event carrying the full [LlmChatResponse] and usage telemetry.
class LlmDoneEvent extends LlmStreamEvent {
  const LlmDoneEvent(this.response);

  final LlmChatResponse response;
}

/// Provider-agnostic request passed to [LlmDriver] ([D-008]).
class LlmChatRequest {
  const LlmChatRequest({
    required this.sessionId,
    required this.sessionUuid,
    required this.model,
    required this.prompt,
    this.turnIndex = 0,
    this.temperature,
    this.maxTokens,
    this.stream = true,
  });

  final String sessionId;
  final String sessionUuid;
  final ModelIdentifier model;
  final ProjectedPrompt prompt;
  final int turnIndex;
  final double? temperature;
  final int? maxTokens;
  final bool stream;
}

/// Abstract LLM provider driver interface implemented in `agent_drivers` ([D-008]).
abstract interface class LlmDriver {
  LlmProviderId get providerId;

  /// Streams thought/text/tool events and terminates with [LlmDoneEvent].
  /// Provider failures should throw [LlmDriverException] or be returned safely by the syscall adapter.
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  });
}

/// Structured driver exception wrapping a [SyscallError] for clean mapping at the syscall boundary.
class LlmDriverException implements Exception {
  const LlmDriverException(this.error);

  final SyscallError error;

  @override
  String toString() => 'LlmDriverException($error)';
}
