import 'dart:async';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;

import 'llm_env_loader.dart';
import 'ollama_driver.dart';
import 'openrouter_driver.dart';

/// Callback notified of incremental [LlmStreamEvent] chunks emitted by `sys_llm_chat`.
typedef LlmStreamObserver = void Function(
  String sessionId,
  int turnIndex,
  LlmStreamEvent event,
);

/// Routes `LlmChatRequest` calls to the concrete [LlmDriver] matching `request.model.provider` ([D-008], [D-009]).
class LlmRouter {
  LlmRouter({
    required Map<LlmProviderId, LlmDriver> drivers,
  }) : _drivers = Map<LlmProviderId, LlmDriver>.unmodifiable(drivers);

  /// Creates a router pre-configured with all 3 Stage 1 providers (`local-ollama`, `ollama-cloud`, `openrouter`).
  factory LlmRouter.withDefaults({
    LlmEnvLoader? envLoader,
    SecretRedactor? redactor,
    http.Client? httpClient,
    String? localOllamaBaseUrl,
    String? ollamaCloudBaseUrl,
    String? openRouterBaseUrl,
    String keepAlive = '15m',
    Duration requestTimeout = const Duration(seconds: 120),
  }) {
    final effectiveRedactor = redactor ?? envLoader?.redactor ?? SecretRedactor();
    final effectiveEnv = envLoader ?? LlmEnvLoader(redactor: effectiveRedactor);

    return LlmRouter(
      drivers: <LlmProviderId, LlmDriver>{
        LlmProviderId.localOllama: OllamaDriver.local(
          baseUrl: localOllamaBaseUrl,
          envLoader: effectiveEnv,
          redactor: effectiveRedactor,
          httpClient: httpClient,
          keepAlive: keepAlive,
          requestTimeout: requestTimeout,
        ),
        LlmProviderId.ollamaCloud: OllamaDriver.cloud(
          baseUrl: ollamaCloudBaseUrl,
          envLoader: effectiveEnv,
          redactor: effectiveRedactor,
          httpClient: httpClient,
          keepAlive: keepAlive,
          requestTimeout: requestTimeout,
        ),
        LlmProviderId.openRouter: OpenRouterDriver(
          baseUrl: openRouterBaseUrl,
          envLoader: effectiveEnv,
          redactor: effectiveRedactor,
          httpClient: httpClient,
          requestTimeout: requestTimeout,
        ),
      },
    );
  }

  final Map<LlmProviderId, LlmDriver> _drivers;

  /// Looks up the registered driver for [providerId].
  LlmDriver? driverFor(LlmProviderId providerId) => _drivers[providerId];

  /// Dispatches [request] to its configured provider driver.
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) {
    final driver = _drivers[request.model.provider];
    if (driver == null) {
      return Stream<LlmStreamEvent>.error(
        LlmDriverException(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'UNREGISTERED_PROVIDER',
            message:
                'No LLM driver is registered for provider "${request.model.provider.id}".',
            recoverable: true,
          ),
        ),
      );
    }
    return driver.chatStream(request, cancelToken: cancelToken);
  }
}

/// Builds the kernel `sys_llm_chat` [SyscallDefinition] wired to [router] and [auditLogger] ([D-002], [D-007], [D-010]).
SyscallDefinition buildLlmChatSyscallDefinition({
  required LlmRouter router,
  required AuditLogger auditLogger,
  CanonicalIrProjector projector = const CanonicalIrProjector(),
  LlmStreamObserver? onStreamEvent,
}) {
  var llmSeqCounter = 0;

  return SyscallDefinition(
    name: 'sys_llm_chat',
    requiredRight: CapRight.llmInfer,
    kind: 'other',
    applyIoCap: false,
    validateArgs: (args) {
      final rawModel = args['model'];
      if (rawModel is! String || rawModel.trim().isEmpty) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'MISSING_MODEL',
          message: 'sys_llm_chat requires a non-empty "model" string.',
          recoverable: true,
        );
      }
      final parsed = ModelIdentifier.parse(rawModel);
      if (!parsed.ok) {
        return parsed.error;
      }
      final turnIndex = args['turnIndex'];
      if (turnIndex != null && (turnIndex is! int || turnIndex < 0)) {
        return const SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_TURN_INDEX',
          message: 'turnIndex must be a non-negative integer.',
          recoverable: true,
        );
      }
      return null;
    },
    evaluatePolicy: (_, _) async => RingDecision.allow,
    handler: (execContext) async {
      final args = execContext.args;
      final modelResult = ModelIdentifier.parse(args['model'] as String);
      if (!modelResult.ok) {
        return SyscallResult<Map<String, dynamic>>.failure(modelResult.error!);
      }
      final model = modelResult.value!;
      final turnIndex = (args['turnIndex'] as int?) ?? 0;
      final sessionUuid = (args['sessionUuid'] as String?) ??
          execContext.context.sessionId;
      final stream = (args['stream'] as bool?) ?? true;
      final temperature = (args['temperature'] as num?)?.toDouble();
      final maxTokens = (args['maxTokens'] as num?)?.toInt();

      final projected = projector.project(
        execContext.pcb.memory,
        targetProvider: model.provider.id,
        targetModel: model.modelName,
      );

      final chatRequest = LlmChatRequest(
        sessionId: execContext.context.sessionId,
        sessionUuid: sessionUuid,
        model: model,
        prompt: projected,
        turnIndex: turnIndex,
        temperature: temperature,
        maxTokens: maxTokens,
        stream: stream,
      );

      final llmSeq = ++llmSeqCounter;
      final stopwatch = Stopwatch()..start();
      LlmChatResponse? doneResponse;

      try {
        await for (final event in router.chatStream(
          chatRequest,
          cancelToken: execContext.context.cancelToken,
        )) {
          onStreamEvent?.call(execContext.context.sessionId, turnIndex, event);
          if (event is LlmDoneEvent) {
            doneResponse = event.response;
          }
        }
      } on LlmDriverException catch (e) {
        stopwatch.stop();
        await auditLogger.logLlmIo(
          LlmIoAuditRecord(
            seq: llmSeq,
            turnIndex: turnIndex,
            timestamp: DateTime.now().toUtc(),
            sessionId: execContext.context.sessionId,
            provider: model.provider.id,
            model: model.modelName,
            ok: false,
            errorCode: e.error.code.codeName,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            durationMs: stopwatch.elapsedMilliseconds,
            toolCallsCount: 0,
            requestDebug: <String, dynamic>{
              'messageCount': projected.messages.length,
              'toolsCount': projected.tools.length,
            },
          ),
        );
        return SyscallResult<Map<String, dynamic>>.failure(e.error);
      } catch (e) {
        stopwatch.stop();
        final err = SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'LLM_DRIVER_ERROR',
          message: auditLogger.redactor.redactString(e.toString()),
          recoverable: true,
        );
        await auditLogger.logLlmIo(
          LlmIoAuditRecord(
            seq: llmSeq,
            turnIndex: turnIndex,
            timestamp: DateTime.now().toUtc(),
            sessionId: execContext.context.sessionId,
            provider: model.provider.id,
            model: model.modelName,
            ok: false,
            errorCode: err.code.codeName,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            durationMs: stopwatch.elapsedMilliseconds,
            toolCallsCount: 0,
            requestDebug: <String, dynamic>{
              'messageCount': projected.messages.length,
              'toolsCount': projected.tools.length,
            },
          ),
        );
        return SyscallResult<Map<String, dynamic>>.failure(err);
      }

      stopwatch.stop();
      if (doneResponse == null) {
        const err = SyscallError(
          code: SyscallErrorCode.eprovider,
          reason: 'EMPTY_STREAM',
          message: 'LLM stream completed without a terminal LlmDoneEvent.',
          recoverable: true,
        );
        await auditLogger.logLlmIo(
          LlmIoAuditRecord(
            seq: llmSeq,
            turnIndex: turnIndex,
            timestamp: DateTime.now().toUtc(),
            sessionId: execContext.context.sessionId,
            provider: model.provider.id,
            model: model.modelName,
            ok: false,
            errorCode: err.code.codeName,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            durationMs: stopwatch.elapsedMilliseconds,
            toolCallsCount: 0,
          ),
        );
        return const SyscallResult<Map<String, dynamic>>.failure(err);
      }

      final usage = doneResponse.usage;
      execContext.pcb.quotaUsage.recordUsage(
        tokens: usage.totalTokens,
        costMicroUsd: usage.costMicroUsd ?? 0,
      );

      await auditLogger.logLlmIo(
        LlmIoAuditRecord(
          seq: llmSeq,
          turnIndex: turnIndex,
          timestamp: DateTime.now().toUtc(),
          sessionId: execContext.context.sessionId,
          provider: model.provider.id,
          model: model.modelName,
          endpoint: doneResponse.endpoint,
          ok: true,
          promptTokens: usage.promptTokens,
          completionTokens: usage.completionTokens,
          totalTokens: usage.totalTokens,
          cachedTokens: usage.cachedTokens,
          cacheWriteTokens: usage.cacheWriteTokens,
          cacheHitRate: usage.cacheHitRate,
          costMicroUsd: usage.costMicroUsd,
          ttftMs: usage.ttftMs,
          durationMs: usage.durationMs,
          toolCallsCount: doneResponse.toolCalls.length,
          requestDebug: <String, dynamic>{
            'messageCount': projected.messages.length,
            'toolsCount': projected.tools.length,
          },
          responseDebug: <String, dynamic>{
            'finishReason': doneResponse.finishReason,
            'thoughtChars': doneResponse.thoughtText?.length ?? 0,
            'textChars': doneResponse.content.length,
          },
        ),
      );

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'provider': model.provider.id,
        'model': model.modelName,
        'canonicalModel': model.canonicalId,
        'endpoint': doneResponse.endpoint,
        'content': doneResponse.content,
        'thoughtText': doneResponse.thoughtText,
        'rawReasoningDetails': doneResponse.rawReasoningDetails,
        'finishReason': doneResponse.finishReason,
        'toolCalls': doneResponse.toolCalls
            .map(
              (tc) => <String, dynamic>{
                'id': tc.id,
                'name': tc.name,
                'arguments': tc.arguments,
              },
            )
            .toList(growable: false),
        'usage': <String, dynamic>{
          'promptTokens': usage.promptTokens,
          'completionTokens': usage.completionTokens,
          'totalTokens': usage.totalTokens,
          'cachedTokens': usage.cachedTokens,
          'cacheWriteTokens': usage.cacheWriteTokens,
          'cacheHitRate': usage.cacheHitRate,
          'costMicroUsd': usage.costMicroUsd,
          'cacheDiscountUsd': usage.cacheDiscountUsd,
          'ttftMs': usage.ttftMs,
          'durationMs': usage.durationMs,
        },
      });
    },
  );
}
