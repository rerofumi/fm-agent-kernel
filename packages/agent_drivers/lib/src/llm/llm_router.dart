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

/// Process-aware stream observer propagating the caller's [Pid] (`[D-215]`).
typedef LlmPidStreamObserver = void Function(
  String sessionId,
  int turnIndex,
  LlmStreamEvent event, {
  Pid pid,
});

/// Callback notified of pre-inference [ContextPagingReport] telemetry (`[D-207]`, `[D-209]`).
typedef PagingReportObserver = void Function(
  ContextPagingReport report, {
  Pid pid,
});

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

/// Builds the kernel `sys_llm_chat` [SyscallDefinition] wired to [router], [auditLogger],
/// [contextWindowSource], [freshnessChecker], [contextPager], and [llmHooks]
/// ([D-002], [D-007], [D-010], [D-203], [D-207]..[D-209], [D-215], [D-220]).
SyscallDefinition buildLlmChatSyscallDefinition({
  required LlmRouter router,
  required AuditLogger auditLogger,
  CanonicalIrProjector projector = const CanonicalIrProjector(),
  LlmStreamObserver? onStreamEvent,
  LlmPidStreamObserver? onProcessStreamEvent,
  ContextWindowSource? contextWindowSource,
  PageFreshnessChecker? freshnessChecker,
  ContextPager contextPager = const ContextPager(),
  PagingReportObserver? onPagingReport,
  List<LlmHook> llmHooks = const <LlmHook>[],
}) {
  final effectiveLlmHooks = List<LlmHook>.unmodifiable(llmHooks);
  var llmSeqCounter = 0;
  final lastModelByPid = <Pid, ModelIdentifier>{};
  final lastWindowSpecByPid = <Pid, ContextWindowSpec>{};

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

      final pcb = execContext.pcb;
      final pid = pcb.pid;
      final prevModel = lastModelByPid[pid];
      final isModelSwitch = prevModel != null && prevModel != model;
      final prevWindowSpec = lastWindowSpecByPid[pid];

      // 1. Resolve effective context window ([D-203] §3.1(2), [D-204], [D-209]).
      ContextWindowSpec? windowSpec;
      if (contextWindowSource != null) {
        final forceRefreshPs =
            isModelSwitch || (prevWindowSpec != null && !prevWindowSpec.isLoadedExact);
        windowSpec = await contextWindowSource.resolve(
          model,
          forceRefreshPs: forceRefreshPs,
        );
        lastModelByPid[pid] = model;
        lastWindowSpecByPid[pid] = windowSpec;
      }

      // 2. Refresh Clean Page freshness & perform Dynamic Frame Resizing ([D-207], [D-208], [D-209]).
      ContextPagingReport? pagingReport;
      if (windowSpec != null) {
        final pagingRes = await contextPager.refreshAndPrepareFrame(
          memory: pcb.memory,
          targetModel: model,
          windowSpec: windowSpec,
          freshnessChecker: freshnessChecker,
          requestedMaxTokens: maxTokens,
          isModelSwitch: isModelSwitch,
        );
        if (!pagingRes.ok) {
          final err = pagingRes.error!;
          final llmSeq = ++llmSeqCounter;
          await auditLogger.logLlmIo(
            LlmIoAuditRecord(
              seq: llmSeq,
              turnIndex: turnIndex,
              timestamp: DateTime.now().toUtc(),
              sessionId: execContext.context.sessionId,
              pid: pid,
              parentPid: pcb.parentPid,
              processName: pcb.name,
              ring: pcb.ring,
              provider: model.provider.id,
              model: model.modelName,
              ok: false,
              errorCode: err.code.codeName,
              promptTokens: 0,
              completionTokens: 0,
              totalTokens: 0,
              durationMs: 0,
              toolCallsCount: 0,
              effectiveWindowTokens: windowSpec.contextWindowTokens,
              evictedPagesInStep: 0,
              residentCleanPages: pcb.memory.pageTable.residentCleanPagesCount,
              evictedCleanPages: pcb.memory.pageTable.evictedCleanPagesCount,
              stalePagesCount: pcb.memory.pageTable.stalePagesCount,
            ),
          );
          return SyscallResult<Map<String, dynamic>>.failure(err);
        }
        pagingReport = pagingRes.value!;
        onPagingReport?.call(pagingReport, pid: pid);
      } else if (freshnessChecker != null) {
        await contextPager.refreshFreshness(
          pcb.memory,
          freshnessChecker: freshnessChecker,
        );
      }

      final baselineEstimatedTokens =
          contextPager.estimator.estimateMemoryHeuristicTotal(pcb.memory);

      var projected = projector.project(
        pcb.memory,
        targetProvider: model.provider.id,
        targetModel: model.modelName,
      );

      final llmSeq = ++llmSeqCounter;
      final effectiveWindowTokens =
          pagingReport?.effectiveWindowTokens ?? windowSpec?.contextWindowTokens;
      final evictedPagesInStep = pagingReport?.evictedPagesInStep ?? 0;
      final residentCleanPages = pagingReport?.residentCleanPages ??
          pcb.memory.pageTable.residentCleanPagesCount;
      final evictedCleanPages = pagingReport?.evictedCleanPages ??
          pcb.memory.pageTable.evictedCleanPagesCount;
      final stalePagesCount =
          pagingReport?.stalePagesCount ?? pcb.memory.pageTable.stalePagesCount;

      // 3. Execute beforeLlmRequest hooks in FIFO registration order ([D-203] §3.1(4), [D-220]).
      // TCB invariant: Segment 0 and Segment 1 messages are strictly immutable; only ephemeral Segment 2 tail notes are allowed.
      if (effectiveLlmHooks.isNotEmpty) {
        for (final hook in effectiveLlmHooks) {
          final hookCtx = LlmHookContext(
            pid: pid,
            ring: pcb.ring,
            sessionId: execContext.context.sessionId,
            turnIndex: turnIndex,
            model: model,
            prompt: projected,
          );
          final beforeRes = await hook.beforeLlmRequest(hookCtx);
          switch (beforeRes) {
            case LlmHookAllow():
              break;
            case LlmHookAppendTailNote(:final note):
              projected = _appendEphemeralTailNote(projected, note);
            case LlmHookBlock(:final reason, :final message, :final hint):
              final err = SyscallError(
                code: SyscallErrorCode.eperm,
                reason: 'HOOK_BLOCKED',
                message: auditLogger.redactor.redactString(message),
                recoverable: true,
                hint: hint == null
                    ? null
                    : auditLogger.redactor.redactString(hint),
                details: <String, dynamic>{
                  'hookName': hook.name,
                  'blockReason': reason,
                  'hookPoint': 'beforeLlmRequest',
                },
              );
              await auditLogger.logLlmIo(
                LlmIoAuditRecord(
                  seq: llmSeq,
                  turnIndex: turnIndex,
                  timestamp: DateTime.now().toUtc(),
                  sessionId: execContext.context.sessionId,
                  pid: pid,
                  parentPid: pcb.parentPid,
                  processName: pcb.name,
                  ring: pcb.ring,
                  provider: model.provider.id,
                  model: model.modelName,
                  ok: false,
                  errorCode: err.code.codeName,
                  promptTokens: 0,
                  completionTokens: 0,
                  totalTokens: 0,
                  durationMs: 0,
                  toolCallsCount: 0,
                  effectiveWindowTokens: effectiveWindowTokens,
                  evictedPagesInStep: evictedPagesInStep,
                  residentCleanPages: residentCleanPages,
                  evictedCleanPages: evictedCleanPages,
                  stalePagesCount: stalePagesCount,
                  requestDebug: <String, dynamic>{
                    'messageCount': projected.messages.length,
                    'toolsCount': projected.tools.length,
                    'blockedByHook': hook.name,
                  },
                ),
              );
              return SyscallResult<Map<String, dynamic>>.failure(err);
          }
        }
      }

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

      final stopwatch = Stopwatch()..start();
      LlmChatResponse? doneResponse;

      try {
        await for (final event in router.chatStream(
          chatRequest,
          cancelToken: execContext.context.cancelToken,
        )) {
          onProcessStreamEvent?.call(
            execContext.context.sessionId,
            turnIndex,
            event,
            pid: pid,
          );
          if (pid == 1) {
            onStreamEvent?.call(
              execContext.context.sessionId,
              turnIndex,
              event,
            );
          }
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
            pid: pid,
            parentPid: pcb.parentPid,
            processName: pcb.name,
            ring: pcb.ring,
            provider: model.provider.id,
            model: model.modelName,
            ok: false,
            errorCode: e.error.code.codeName,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            durationMs: stopwatch.elapsedMilliseconds,
            toolCallsCount: 0,
            effectiveWindowTokens: effectiveWindowTokens,
            evictedPagesInStep: evictedPagesInStep,
            residentCleanPages: residentCleanPages,
            evictedCleanPages: evictedCleanPages,
            stalePagesCount: stalePagesCount,
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
            pid: pid,
            parentPid: pcb.parentPid,
            processName: pcb.name,
            ring: pcb.ring,
            provider: model.provider.id,
            model: model.modelName,
            ok: false,
            errorCode: err.code.codeName,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            durationMs: stopwatch.elapsedMilliseconds,
            toolCallsCount: 0,
            effectiveWindowTokens: effectiveWindowTokens,
            evictedPagesInStep: evictedPagesInStep,
            residentCleanPages: residentCleanPages,
            evictedCleanPages: evictedCleanPages,
            stalePagesCount: stalePagesCount,
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
            pid: pid,
            parentPid: pcb.parentPid,
            processName: pcb.name,
            ring: pcb.ring,
            provider: model.provider.id,
            model: model.modelName,
            ok: false,
            errorCode: err.code.codeName,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            durationMs: stopwatch.elapsedMilliseconds,
            toolCallsCount: 0,
            effectiveWindowTokens: effectiveWindowTokens,
            evictedPagesInStep: evictedPagesInStep,
            residentCleanPages: residentCleanPages,
            evictedCleanPages: evictedCleanPages,
            stalePagesCount: stalePagesCount,
          ),
        );
        return const SyscallResult<Map<String, dynamic>>.failure(err);
      }

      // 4. Execute afterLlmResponse hooks in FIFO registration order ([D-203] §3.1(4), [D-220]).
      // TCB invariant: actual consumed usage is captured immutably and can never be reduced by hooks.
      final usage = doneResponse.usage;
      var effectiveResponse = doneResponse;
      if (effectiveLlmHooks.isNotEmpty) {
        final afterHookCtx = LlmHookContext(
          pid: pid,
          ring: pcb.ring,
          sessionId: execContext.context.sessionId,
          turnIndex: turnIndex,
          model: model,
          prompt: projected,
        );
        for (final hook in effectiveLlmHooks) {
          final afterRes = await hook.afterLlmResponse(
            afterHookCtx,
            effectiveResponse,
          );
          switch (afterRes) {
            case LlmHookAfterKeep():
              break;
            case LlmHookAfterReplaceText(:final content):
              effectiveResponse = LlmChatResponse(
                content: content,
                thoughtText: effectiveResponse.thoughtText,
                rawReasoningDetails: effectiveResponse.rawReasoningDetails,
                toolCalls: effectiveResponse.toolCalls,
                usage: usage,
                finishReason: effectiveResponse.finishReason,
                endpoint: effectiveResponse.endpoint,
              );
            case LlmHookAfterBlock(:final reason, :final message, :final hint):
              // Record actual token/cost consumption even when response is blocked (anti quota-evasion).
              pcb.quotaUsage.recordUsage(
                tokens: usage.totalTokens,
                costMicroUsd: usage.costMicroUsd ?? 0,
              );
              if (usage.promptTokens > 0) {
                pcb.memory.recordActualPromptTokensAnchor(
                  model: model,
                  actualPromptTokens: usage.promptTokens,
                  estimatedBaselineTokens: baselineEstimatedTokens,
                );
              }
              final err = SyscallError(
                code: SyscallErrorCode.eperm,
                reason: 'HOOK_BLOCKED',
                message: auditLogger.redactor.redactString(message),
                recoverable: true,
                hint: hint == null
                    ? null
                    : auditLogger.redactor.redactString(hint),
                details: <String, dynamic>{
                  'hookName': hook.name,
                  'blockReason': reason,
                  'hookPoint': 'afterLlmResponse',
                },
              );
              await auditLogger.logLlmIo(
                LlmIoAuditRecord(
                  seq: llmSeq,
                  turnIndex: turnIndex,
                  timestamp: DateTime.now().toUtc(),
                  sessionId: execContext.context.sessionId,
                  pid: pid,
                  parentPid: pcb.parentPid,
                  processName: pcb.name,
                  ring: pcb.ring,
                  provider: model.provider.id,
                  model: model.modelName,
                  endpoint: effectiveResponse.endpoint,
                  ok: false,
                  errorCode: err.code.codeName,
                  promptTokens: usage.promptTokens,
                  completionTokens: usage.completionTokens,
                  totalTokens: usage.totalTokens,
                  cachedTokens: usage.cachedTokens,
                  cacheWriteTokens: usage.cacheWriteTokens,
                  cacheHitRate: usage.cacheHitRate,
                  costMicroUsd: usage.costMicroUsd,
                  ttftMs: usage.ttftMs,
                  durationMs: usage.durationMs,
                  toolCallsCount: effectiveResponse.toolCalls.length,
                  effectiveWindowTokens: effectiveWindowTokens,
                  evictedPagesInStep: evictedPagesInStep,
                  residentCleanPages: residentCleanPages,
                  evictedCleanPages: evictedCleanPages,
                  stalePagesCount: stalePagesCount,
                  requestDebug: <String, dynamic>{
                    'messageCount': projected.messages.length,
                    'toolsCount': projected.tools.length,
                  },
                  responseDebug: <String, dynamic>{
                    'finishReason': effectiveResponse.finishReason,
                    'blockedByHook': hook.name,
                  },
                ),
              );
              return SyscallResult<Map<String, dynamic>>.failure(err);
          }
        }
      }

      pcb.quotaUsage.recordUsage(
        tokens: usage.totalTokens,
        costMicroUsd: usage.costMicroUsd ?? 0,
      );

      // Update hybrid token estimator anchor from actual provider promptTokens ([D-206]).
      if (usage.promptTokens > 0) {
        pcb.memory.recordActualPromptTokensAnchor(
          model: model,
          actualPromptTokens: usage.promptTokens,
          estimatedBaselineTokens: baselineEstimatedTokens,
        );
      }

      // Sync loaded Local Ollama effective context window from /api/ps immediately after initial cold inference ([D-204], [D-209]).
      if (contextWindowSource != null &&
          model.provider == LlmProviderId.localOllama &&
          windowSpec != null &&
          !windowSpec.isLoadedExact) {
        try {
          final refreshed = await contextWindowSource.resolve(
            model,
            forceRefreshPs: true,
          );
          if (refreshed.isLoadedExact) {
            lastWindowSpecByPid[pid] = refreshed;
          }
        } catch (_) {
          // Best-effort post-load synchronization.
        }
      }

      await auditLogger.logLlmIo(
        LlmIoAuditRecord(
          seq: llmSeq,
          turnIndex: turnIndex,
          timestamp: DateTime.now().toUtc(),
          sessionId: execContext.context.sessionId,
          pid: pid,
          parentPid: pcb.parentPid,
          processName: pcb.name,
          ring: pcb.ring,
          provider: model.provider.id,
          model: model.modelName,
          endpoint: effectiveResponse.endpoint,
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
          toolCallsCount: effectiveResponse.toolCalls.length,
          effectiveWindowTokens: effectiveWindowTokens,
          evictedPagesInStep: evictedPagesInStep,
          residentCleanPages: residentCleanPages,
          evictedCleanPages: evictedCleanPages,
          stalePagesCount: stalePagesCount,
          requestDebug: <String, dynamic>{
            'messageCount': projected.messages.length,
            'toolsCount': projected.tools.length,
          },
          responseDebug: <String, dynamic>{
            'finishReason': effectiveResponse.finishReason,
            'thoughtChars': effectiveResponse.thoughtText?.length ?? 0,
            'textChars': effectiveResponse.content.length,
          },
        ),
      );

      return SyscallResult<Map<String, dynamic>>.success(<String, dynamic>{
        'provider': model.provider.id,
        'model': model.modelName,
        'canonicalModel': model.canonicalId,
        'endpoint': effectiveResponse.endpoint,
        'content': effectiveResponse.content,
        'thoughtText': effectiveResponse.thoughtText,
        'rawReasoningDetails': effectiveResponse.rawReasoningDetails,
        'finishReason': effectiveResponse.finishReason,
        'toolCalls': effectiveResponse.toolCalls
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
        if (pagingReport != null)
          'paging': <String, dynamic>{
            'effectiveWindowTokens': pagingReport.effectiveWindowTokens,
            'effectiveInputBudget': pagingReport.effectiveInputBudget,
            'evictedPagesInStep': pagingReport.evictedPagesInStep,
            'residentCleanPages': pagingReport.residentCleanPages,
            'evictedCleanPages': pagingReport.evictedCleanPages,
            'stalePagesCount': pagingReport.stalePagesCount,
          },
      });
    },
  );
}

/// Appends [note] strictly to the Segment 2 ephemeral tail of [prompt], leaving Segment 0 and Segment 1 untouched ([D-220]).
ProjectedPrompt _appendEphemeralTailNote(ProjectedPrompt prompt, String note) {
  final trimmed = note.trim();
  if (trimmed.isEmpty) {
    return prompt;
  }

  final updatedMessages = List<ProjectedMessage>.from(prompt.messages);
  if (updatedMessages.isNotEmpty && updatedMessages.last.segmentIndex == 2) {
    final existingTail = updatedMessages.last;
    final combined = existingTail.content.isEmpty
        ? trimmed
        : '${existingTail.content}\n\n$trimmed';
    updatedMessages[updatedMessages.length - 1] = ProjectedMessage(
      role: existingTail.role,
      content: combined,
      segmentIndex: 2,
    );
  } else {
    updatedMessages.add(
      ProjectedMessage(
        role: ProjectedRole.user,
        content: trimmed,
        segmentIndex: 2,
      ),
    );
  }

  return ProjectedPrompt(
    messages: updatedMessages,
    tools: prompt.tools,
  );
}
