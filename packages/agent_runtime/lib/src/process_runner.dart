import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:agent_kernel/agent_kernel.dart';

/// Resolves `<providerId>/<modelName>` according to `[D-002]` §2.1(2) precedence:
/// 1. `turnOverride` (per-turn only, never mutates session selection)
/// 2. `sessionSelected` (`/model` or `session/set_config_option`)
/// 3. `startupModel` (CLI `--model` / engine startup option)
/// 4. [defaultModelId] (`local-ollama/gemma4:12b`)
class ModelResolver {
  ModelResolver({
    String? startupModel,
    String? sessionSelectedModel,
    this.defaultModelId = stage1DefaultModelId,
  })  : _startupModel = _normalizeOptional(startupModel),
        _sessionSelectedModel = _normalizeOptional(sessionSelectedModel);

  static const String stage1DefaultModelId = 'local-ollama/gemma4:12b';

  final String defaultModelId;
  String? _startupModel;
  String? _sessionSelectedModel;

  /// Initial model passed at startup/session creation (Priority 3).
  String? get startupModel => _startupModel;

  /// Currently persisted session model (Priority 2), if explicitly selected.
  String? get sessionSelectedModel => _sessionSelectedModel;

  /// Returns the effective raw model string for the given optional [turnOverride] without mutating state.
  String effectiveModelString({String? turnOverride}) {
    final override = _normalizeOptional(turnOverride);
    if (override != null) {
      return override;
    }
    if (_sessionSelectedModel != null) {
      return _sessionSelectedModel!;
    }
    if (_startupModel != null) {
      return _startupModel!;
    }
    return defaultModelId;
  }

  /// Resolves and validates the model for a user input turn boundary ([D-002]).
  SyscallResult<ModelIdentifier> resolveForTurn({String? turnOverride}) {
    final raw = effectiveModelString(turnOverride: turnOverride);
    return ModelIdentifier.parse(raw);
  }

  /// Validates and persists Priority 2 (`sessionSelected`) model for subsequent turns.
  SyscallResult<ModelIdentifier> setSessionModel(String rawModel) {
    final parsed = ModelIdentifier.parse(rawModel);
    if (parsed.ok) {
      _sessionSelectedModel = parsed.value!.canonicalId;
    }
    return parsed;
  }

  /// Updates Priority 3 (`startupModel`) if valid.
  SyscallResult<ModelIdentifier> setStartupModel(String rawModel) {
    final parsed = ModelIdentifier.parse(rawModel);
    if (parsed.ok) {
      _startupModel = parsed.value!.canonicalId;
    }
    return parsed;
  }

  static String? _normalizeOptional(String? value) {
    if (value == null) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Real-time events emitted by [LeadAgent] and [ProcessRunner] ([D-005], [D-019]).
sealed class AgentLoopEvent {
  const AgentLoopEvent({
    required this.sessionId,
    required this.turnIndex,
  });

  final String sessionId;
  final int turnIndex;
}

class AgentTurnStartedEvent extends AgentLoopEvent {
  const AgentTurnStartedEvent({
    required super.sessionId,
    required super.turnIndex,
    required this.model,
    required this.userInput,
  });

  final ModelIdentifier model;
  final String userInput;
}

class AgentThoughtDeltaEvent extends AgentLoopEvent {
  const AgentThoughtDeltaEvent({
    required super.sessionId,
    required super.turnIndex,
    required this.text,
  });

  final String text;
}

class AgentTextDeltaEvent extends AgentLoopEvent {
  const AgentTextDeltaEvent({
    required super.sessionId,
    required super.turnIndex,
    required this.text,
  });

  final String text;
}

class AgentToolCallStartedEvent extends AgentLoopEvent {
  AgentToolCallStartedEvent({
    required super.sessionId,
    required super.turnIndex,
    required this.callId,
    required this.toolName,
    required Map<String, dynamic> arguments,
  }) : arguments = Map<String, dynamic>.unmodifiable(arguments);

  final String callId;
  final String toolName;
  final Map<String, dynamic> arguments;
}

class AgentToolCallCompletedEvent extends AgentLoopEvent {
  const AgentToolCallCompletedEvent({
    required super.sessionId,
    required super.turnIndex,
    required this.callId,
    required this.toolName,
    required this.ok,
    this.errorCode,
  });

  final String callId;
  final String toolName;
  final bool ok;
  final String? errorCode;
}

class AgentTurnCompletedEvent extends AgentLoopEvent {
  const AgentTurnCompletedEvent({
    required super.sessionId,
    required super.turnIndex,
    required this.model,
    required this.finalText,
    required this.steps,
    required this.toolCallsExecuted,
    this.usage,
  });

  final ModelIdentifier model;
  final String finalText;
  final int steps;
  final int toolCallsExecuted;
  final LlmUsageTelemetry? usage;
}

class AgentTurnFailedEvent extends AgentLoopEvent {
  const AgentTurnFailedEvent({
    required super.sessionId,
    required super.turnIndex,
    this.model,
    required this.error,
  });

  final ModelIdentifier? model;
  final SyscallError error;
}

/// Outcome of a single [LeadAgent] user input turn ([D-005]).
class AgentTurnResult {
  const AgentTurnResult._({
    required this.ok,
    required this.turnIndex,
    this.model,
    this.finalText = '',
    this.thoughtText,
    this.steps = 0,
    this.toolCallsExecuted = 0,
    this.usage,
    this.error,
  });

  const AgentTurnResult.success({
    required int turnIndex,
    required ModelIdentifier model,
    required String finalText,
    String? thoughtText,
    required int steps,
    required int toolCallsExecuted,
    LlmUsageTelemetry? usage,
  }) : this._(
          ok: true,
          turnIndex: turnIndex,
          model: model,
          finalText: finalText,
          thoughtText: thoughtText,
          steps: steps,
          toolCallsExecuted: toolCallsExecuted,
          usage: usage,
        );

  const AgentTurnResult.failure({
    required int turnIndex,
    ModelIdentifier? model,
    required SyscallError error,
    int steps = 0,
    int toolCallsExecuted = 0,
  }) : this._(
          ok: false,
          turnIndex: turnIndex,
          model: model,
          steps: steps,
          toolCallsExecuted: toolCallsExecuted,
          error: error,
        );

  final bool ok;
  final int turnIndex;
  final ModelIdentifier? model;
  final String finalText;
  final String? thoughtText;
  final int steps;
  final int toolCallsExecuted;
  final LlmUsageTelemetry? usage;
  final SyscallError? error;
}

/// Ring 2 ReAct agent loop communicating strictly through [SyscallGate.invoke] ([D-005]).
///
/// Notice this class has zero references to concrete drivers (`agent_drivers`, `http`, or OS I/O).
class LeadAgent {
  LeadAgent({
    required this.pcb,
    required this.syscallGate,
    required this.capHandle,
    required this.modelResolver,
    String? sessionUuid,
    this.maxStepsPerTurn = 32,
  }) : sessionUuid = sessionUuid ?? _generateUuidV4();

  final ProcessControlBlock pcb;
  final SyscallGate syscallGate;
  final CapHandle capHandle;
  final ModelResolver modelResolver;
  final String sessionUuid;
  final int maxStepsPerTurn;

  final StreamController<AgentLoopEvent> _eventController =
      StreamController<AgentLoopEvent>.broadcast(sync: true);

  int _turnCounter = 0;
  int _canonicalCallSeq = 0;

  /// Broadcast stream of real-time agent loop events.
  Stream<AgentLoopEvent> get events => _eventController.stream;

  /// Forwards incremental [LlmStreamEvent] deltas emitted by `sys_llm_chat` into [events].
  void forwardLlmStreamEvent(int turnIndex, LlmStreamEvent event) {
    if (_eventController.isClosed) {
      return;
    }
    switch (event) {
      case LlmThoughtDelta(:final text):
        _eventController.add(
          AgentThoughtDeltaEvent(
            sessionId: pcb.memory.sessionId,
            turnIndex: turnIndex,
            text: text,
          ),
        );
      case LlmTextDelta(:final text):
        _eventController.add(
          AgentTextDeltaEvent(
            sessionId: pcb.memory.sessionId,
            turnIndex: turnIndex,
            text: text,
          ),
        );
      case LlmToolCallEvent():
      case LlmDoneEvent():
        break;
    }
  }

  /// Executes one complete user input turn (fixing model at turn boundary across all ReAct steps).
  Future<AgentTurnResult> runTurn({
    required String userInput,
    String? dynamicContextSummary,
    String? modelOverride,
    CancellationToken? cancelToken,
    double? temperature,
    int? maxTokens,
  }) async {
    final turnIndex = ++_turnCounter;
    final sessionId = pcb.memory.sessionId;

    if (cancelToken?.isCancelled ?? false) {
      const err = SyscallError(
        code: SyscallErrorCode.ecancelled,
        reason: 'CANCELLED',
        message: 'Turn cancelled before starting.',
        recoverable: true,
      );
      _emit(
        AgentTurnFailedEvent(
          sessionId: sessionId,
          turnIndex: turnIndex,
          error: err,
        ),
      );
      return AgentTurnResult.failure(turnIndex: turnIndex, error: err);
    }

    // Resolve model once at user input turn boundary ([D-002] §2.1(2)).
    final modelRes = modelResolver.resolveForTurn(turnOverride: modelOverride);
    if (!modelRes.ok) {
      _emit(
        AgentTurnFailedEvent(
          sessionId: sessionId,
          turnIndex: turnIndex,
          error: modelRes.error!,
        ),
      );
      return AgentTurnResult.failure(
        turnIndex: turnIndex,
        error: modelRes.error!,
      );
    }
    final resolvedModel = modelRes.value!;

    // Reset per-turn syscall counter while preserving cumulative token/cost counters.
    pcb.quotaUsage.resetTurn();
    pcb.state = ProcessState.running;

    // Place current prompt and dynamic context in Segment 2 (ephemeral tail) for Step 1.
    pcb.memory.ephemeralSegment.dynamicContextSummary = dynamicContextSummary;
    pcb.memory.ephemeralSegment.currentUserInput = userInput;

    _emit(
      AgentTurnStartedEvent(
        sessionId: sessionId,
        turnIndex: turnIndex,
        model: resolvedModel,
        userInput: userInput,
      ),
    );

    final syscallContext = SyscallContext(
      pid: pcb.pid,
      capHandle: capHandle,
      sessionId: sessionId,
      cancelToken: cancelToken,
    );

    var steps = 0;
    var toolCallsExecuted = 0;
    var userTurnCommitted = false;
    var promptAgg = 0;
    var completionAgg = 0;
    int? lastCachedTokens;
    int? lastCacheWriteTokens;
    var costAgg = 0;
    var hasAnyCost = false;
    int? lastTtftMs;
    var durationAgg = 0;

    try {
      while (steps < maxStepsPerTurn) {
        if (cancelToken?.isCancelled ?? false) {
          const err = SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'CANCELLED',
            message: 'Turn cancelled during ReAct execution.',
            recoverable: true,
          );
          _emit(
            AgentTurnFailedEvent(
              sessionId: sessionId,
              turnIndex: turnIndex,
              model: resolvedModel,
              error: err,
            ),
          );
          return AgentTurnResult.failure(
            turnIndex: turnIndex,
            model: resolvedModel,
            error: err,
            steps: steps,
            toolCallsExecuted: toolCallsExecuted,
          );
        }

        final quotaCheck = pcb.quotaUsage.checkBeforeSyscall(pcb.quota);
        if (quotaCheck != null) {
          _emit(
            AgentTurnFailedEvent(
              sessionId: sessionId,
              turnIndex: turnIndex,
              model: resolvedModel,
              error: quotaCheck,
            ),
          );
          return AgentTurnResult.failure(
            turnIndex: turnIndex,
            model: resolvedModel,
            error: quotaCheck,
            steps: steps,
            toolCallsExecuted: toolCallsExecuted,
          );
        }

        steps += 1;
        final llmResult = await syscallGate.invoke(
          syscallContext,
          SyscallRequest(
            name: 'sys_llm_chat',
            args: <String, dynamic>{
              'model': resolvedModel.canonicalId,
              'turnIndex': turnIndex,
              'sessionUuid': sessionUuid,
              'stream': true,
              'temperature': ?temperature,
              'maxTokens': ?maxTokens,
            },
          ),
        );

        if (!llmResult.ok) {
          final err = llmResult.error!;
          _emit(
            AgentTurnFailedEvent(
              sessionId: sessionId,
              turnIndex: turnIndex,
              model: resolvedModel,
              error: err,
            ),
          );
          return AgentTurnResult.failure(
            turnIndex: turnIndex,
            model: resolvedModel,
            error: err,
            steps: steps,
            toolCallsExecuted: toolCallsExecuted,
          );
        }

        final payload = llmResult.value!;
        final content = (payload['content'] as String?) ?? '';
        final thoughtText = payload['thoughtText'] as String?;
        final rawReasoningDetails = payload['rawReasoningDetails'];
        final rawToolCalls =
            (payload['toolCalls'] as List<dynamic>?) ?? const <dynamic>[];

        final usageMap = payload['usage'];
        if (usageMap is Map) {
          promptAgg += (usageMap['promptTokens'] as num?)?.toInt() ?? 0;
          completionAgg += (usageMap['completionTokens'] as num?)?.toInt() ?? 0;
          final cached = usageMap['cachedTokens'];
          if (cached is num) {
            lastCachedTokens = cached.toInt();
          }
          final cacheWrite = usageMap['cacheWriteTokens'];
          if (cacheWrite is num) {
            lastCacheWriteTokens = cacheWrite.toInt();
          }
          final cost = usageMap['costMicroUsd'];
          if (cost is num) {
            costAgg += cost.toInt();
            hasAnyCost = true;
          }
          final ttft = usageMap['ttftMs'];
          if (ttft is num) {
            lastTtftMs ??= ttft.toInt();
          }
          durationAgg += (usageMap['durationMs'] as num?)?.toInt() ?? 0;
        }

        // Commit user prompt into Segment 1 once Step 1 succeeds and clear Segment 2.
        if (!userTurnCommitted) {
          pcb.memory.appendUserTurn(userInput);
          pcb.memory.ephemeralSegment.dynamicContextSummary = null;
          pcb.memory.ephemeralSegment.currentUserInput = null;
          userTurnCommitted = true;
        }

        final canonicalCalls = <CanonicalToolCall>[];
        for (final item in rawToolCalls) {
          if (item is! Map) {
            continue;
          }
          final tcMap = Map<String, dynamic>.from(item);
          final name = (tcMap['name'] as String?) ?? '';
          final rawArgs = tcMap['arguments'];
          final args = rawArgs is Map
              ? Map<String, dynamic>.from(rawArgs)
              : const <String, dynamic>{};
          canonicalCalls.add(
            CanonicalToolCall(
              canonicalCallId: 'sc_${(++_canonicalCallSeq).toString().padLeft(4, '0')}',
              name: name,
              arguments: args,
            ),
          );
        }

        pcb.memory.appendAssistantTurn(
          CanonicalAssistantTurn(
            originProvider: resolvedModel.provider.id,
            originModel: resolvedModel.modelName,
            content: content,
            thoughtText: thoughtText,
            rawReasoningDetails: rawReasoningDetails,
            toolCalls: canonicalCalls,
          ),
        );

        if (canonicalCalls.isEmpty) {
          final telemetry = LlmUsageTelemetry(
            promptTokens: promptAgg,
            completionTokens: completionAgg,
            cachedTokens: lastCachedTokens,
            cacheWriteTokens: lastCacheWriteTokens,
            costMicroUsd: hasAnyCost ? costAgg : null,
            ttftMs: lastTtftMs,
            durationMs: durationAgg,
          );
          _emit(
            AgentTurnCompletedEvent(
              sessionId: sessionId,
              turnIndex: turnIndex,
              model: resolvedModel,
              finalText: content,
              steps: steps,
              toolCallsExecuted: toolCallsExecuted,
              usage: telemetry,
            ),
          );
          return AgentTurnResult.success(
            turnIndex: turnIndex,
            model: resolvedModel,
            finalText: content,
            thoughtText: thoughtText,
            steps: steps,
            toolCallsExecuted: toolCallsExecuted,
            usage: telemetry,
          );
        }

        // Execute each requested tool syscall sequentially through SyscallGate.
        for (final tc in canonicalCalls) {
          if (cancelToken?.isCancelled ?? false) {
            const err = SyscallError(
              code: SyscallErrorCode.ecancelled,
              reason: 'CANCELLED',
              message: 'Turn cancelled before executing tool call.',
              recoverable: true,
            );
            _emit(
              AgentTurnFailedEvent(
                sessionId: sessionId,
                turnIndex: turnIndex,
                model: resolvedModel,
                error: err,
              ),
            );
            return AgentTurnResult.failure(
              turnIndex: turnIndex,
              model: resolvedModel,
              error: err,
              steps: steps,
              toolCallsExecuted: toolCallsExecuted,
            );
          }

          _emit(
            AgentToolCallStartedEvent(
              sessionId: sessionId,
              turnIndex: turnIndex,
              callId: tc.canonicalCallId,
              toolName: tc.name,
              arguments: tc.arguments,
            ),
          );

          final toolRes = await syscallGate.invoke(
            syscallContext,
            SyscallRequest(
              name: tc.name,
              args: tc.arguments,
            ),
          );
          toolCallsExecuted += 1;

          _emit(
            AgentToolCallCompletedEvent(
              sessionId: sessionId,
              turnIndex: turnIndex,
              callId: tc.canonicalCallId,
              toolName: tc.name,
              ok: toolRes.ok,
              errorCode: toolRes.error?.code.codeName,
            ),
          );

          final resultText = toolRes.ok
              ? jsonEncode(toolRes.value ?? const <String, dynamic>{})
              : toolRes.error!.toJsonString();

          pcb.memory.appendToolResultTurn(
            CanonicalToolResultTurn(
              canonicalCallId: tc.canonicalCallId,
              toolName: tc.name,
              content: resultText,
              isError: !toolRes.ok,
            ),
          );

          if (!toolRes.ok &&
              (toolRes.error!.code == SyscallErrorCode.edquot ||
                  toolRes.error!.code == SyscallErrorCode.ecancelled)) {
            _emit(
              AgentTurnFailedEvent(
                sessionId: sessionId,
                turnIndex: turnIndex,
                model: resolvedModel,
                error: toolRes.error!,
              ),
            );
            return AgentTurnResult.failure(
              turnIndex: turnIndex,
              model: resolvedModel,
              error: toolRes.error!,
              steps: steps,
              toolCallsExecuted: toolCallsExecuted,
            );
          }
        }
      }

      final stepLimitError = SyscallError(
        code: SyscallErrorCode.edquot,
        reason: 'MAX_STEPS_EXCEEDED',
        message:
            'LeadAgent exceeded maxStepsPerTurn ($maxStepsPerTurn) without a final response.',
        recoverable: false,
      );
      _emit(
        AgentTurnFailedEvent(
          sessionId: sessionId,
          turnIndex: turnIndex,
          model: resolvedModel,
          error: stepLimitError,
        ),
      );
      return AgentTurnResult.failure(
        turnIndex: turnIndex,
        model: resolvedModel,
        error: stepLimitError,
        steps: steps,
        toolCallsExecuted: toolCallsExecuted,
      );
    } finally {
      pcb.memory.ephemeralSegment.dynamicContextSummary = null;
      pcb.memory.ephemeralSegment.currentUserInput = null;
      if (pcb.state != ProcessState.terminated) {
        pcb.state = ProcessState.ready;
      }
    }
  }

  /// Closes the event stream when the agent is disposed.
  Future<void> dispose() async {
    if (!_eventController.isClosed) {
      await _eventController.close();
    }
  }

  void _emit(AgentLoopEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  static String _generateUuidV4() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}

/// Abstract process runner boundary allowing Stage 1 green tasks and Stage 2/3 Isolate runners ([D-005]).
abstract interface class ProcessRunner {
  Stream<AgentLoopEvent> get events;

  ModelResolver get modelResolver;

  Future<AgentTurnResult> submitPrompt({
    required String userInput,
    String? dynamicContextSummary,
    String? modelOverride,
    double? temperature,
    int? maxTokens,
  });

  SyscallResult<ModelIdentifier> setSessionModel(String rawModel);

  void cancelActiveTurn([String? reason]);

  Future<void> dispose();
}

/// Stage 1 single-process logical task runner executing [LeadAgent] in the host Isolate ([D-005]).
class GreenTaskProcessRunner implements ProcessRunner {
  GreenTaskProcessRunner({
    required this.leadAgent,
  });

  final LeadAgent leadAgent;
  CancellationTokenSource? _activeCancelSource;
  Future<void> _turnQueue = Future<void>.value();
  bool _disposed = false;

  @override
  Stream<AgentLoopEvent> get events => leadAgent.events;

  @override
  ModelResolver get modelResolver => leadAgent.modelResolver;

  @override
  Future<AgentTurnResult> submitPrompt({
    required String userInput,
    String? dynamicContextSummary,
    String? modelOverride,
    double? temperature,
    int? maxTokens,
  }) {
    if (_disposed) {
      return Future<AgentTurnResult>.value(
        const AgentTurnResult.failure(
          turnIndex: 0,
          error: SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'RUNNER_DISPOSED',
            message: 'GreenTaskProcessRunner has been disposed.',
          ),
        ),
      );
    }

    final completer = Completer<AgentTurnResult>();
    _turnQueue = _turnQueue.then((_) async {
      if (_disposed) {
        completer.complete(
          const AgentTurnResult.failure(
            turnIndex: 0,
            error: SyscallError(
              code: SyscallErrorCode.eperm,
              reason: 'RUNNER_DISPOSED',
              message: 'GreenTaskProcessRunner has been disposed.',
            ),
          ),
        );
        return;
      }

      final cancelSource = CancellationTokenSource();
      _activeCancelSource = cancelSource;
      try {
        final result = await leadAgent.runTurn(
          userInput: userInput,
          dynamicContextSummary: dynamicContextSummary,
          modelOverride: modelOverride,
          cancelToken: cancelSource.token,
          temperature: temperature,
          maxTokens: maxTokens,
        );
        completer.complete(result);
      } catch (e) {
        completer.complete(
          AgentTurnResult.failure(
            turnIndex: 0,
            error: SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'UNHANDLED_AGENT_ERROR',
              message: e.toString(),
            ),
          ),
        );
      } finally {
        if (identical(_activeCancelSource, cancelSource)) {
          _activeCancelSource = null;
        }
      }
    });

    return completer.future;
  }

  @override
  SyscallResult<ModelIdentifier> setSessionModel(String rawModel) {
    return leadAgent.modelResolver.setSessionModel(rawModel);
  }

  @override
  void cancelActiveTurn([String? reason]) {
    _activeCancelSource?.cancel(reason);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    cancelActiveTurn('ProcessRunner disposed');
    await _turnQueue;
    leadAgent.pcb.state = ProcessState.terminated;
    await leadAgent.dispose();
  }
}
