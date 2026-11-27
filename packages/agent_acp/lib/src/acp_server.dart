import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;

import 'acp_approval_handler.dart';
import 'acp_event_mapper.dart';
import 'json_rpc_peer.dart';

/// Bootstrap factory signature allowing tests to customize [KernelBootstrapConfig]
/// (e.g., injecting mock LLM drivers) while keeping ACP wiring identical ([D-018]).
typedef AcpBootstrapFactory = KernelBootstrap Function(
  KernelBootstrapConfig config,
);

/// Default model options advertised in `session/new` and `session/set_config_option` ([D-018]).
class AcpModelOption {
  const AcpModelOption({
    required this.value,
    required this.name,
    required this.description,
  });

  final String value;
  final String name;
  final String description;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'value': value,
      'name': name,
      'description': description,
    };
  }
}

/// Configuration options for [AcpServer] ([D-018], [D-022], [D-219]).
class AcpServerConfig {
  const AcpServerConfig({
    this.startupModel,
    this.systemInstruction,
    this.localOllamaBaseUrl,
    this.ollamaCloudBaseUrl,
    this.openRouterBaseUrl,
    this.openAiBaseUrl,
    this.geminiBaseUrl,
    this.nousPortalBaseUrl,
    this.openAiCompatBaseUrl,
    this.modelPolicy,
    this.execPolicy,
    this.modelCatalogService,
    this.maxStepsPerTurn = 64,
    this.maxSyscallsPerTurn,
    this.jjExecutable = 'jj',
    this.skillsDirs = const <String>[],
    this.skillsDirEnv,
    this.maxContextTokens,
    this.mcpServers = const <McpServerSpec>[],
    this.bootstrapFactory,
  });

  final String? startupModel;
  final String? systemInstruction;
  final String? localOllamaBaseUrl;
  final String? ollamaCloudBaseUrl;
  final String? openRouterBaseUrl;
  final String? openAiBaseUrl;
  final String? geminiBaseUrl;
  final String? nousPortalBaseUrl;
  final String? openAiCompatBaseUrl;

  /// Optional explicit [ModelPolicy] override (primarily for tests, [D-410]).
  final ModelPolicy? modelPolicy;

  /// Optional explicit [ExecPolicyConfig] override (primarily for tests, [D-510]).
  final ExecPolicyConfig? execPolicy;

  /// Optional shared [ModelCatalogService] instance ([D-409], [D-410]).
  final ModelCatalogService? modelCatalogService;

  final int maxStepsPerTurn;
  final int? maxSyscallsPerTurn;
  final String jjExecutable;

  /// Repeatable `--skills-dir <path>` directories in priority order ([D-203], [D-219]).
  final List<String> skillsDirs;

  /// Captured `AGENT_OS_SKILLS_DIR` environment value for session skill loading ([D-203], [D-219]).
  final String? skillsDirEnv;

  /// Optional session-wide effective context window cap (`--max-context-tokens`) ([D-316], [D-320]).
  final int? maxContextTokens;

  /// CLI `--mcp-server` specifications merged with `session/new` `mcpServers` ([D-303], [D-320]).
  final List<McpServerSpec> mcpServers;

  final AcpBootstrapFactory? bootstrapFactory;
}

/// ACP v1 JSON-RPC 2.0 `stdio` server hosting `KernelBootstrap` sessions ([D-018]..[D-020]).
class AcpServer {
  AcpServer({
    required JsonRpcPeer peer,
    this.config = const AcpServerConfig(),
  }) : _peer = peer {
    if (config.modelCatalogService != null) {
      _modelCatalogService = config.modelCatalogService!;
      _ownsModelCatalogService = false;
    } else {
      _modelCatalogService = ModelCatalogService(
        localOllamaBaseUrl: config.localOllamaBaseUrl,
        ollamaCloudBaseUrl: config.ollamaCloudBaseUrl,
        openRouterBaseUrl: config.openRouterBaseUrl,
        openAiBaseUrl: config.openAiBaseUrl,
        geminiBaseUrl: config.geminiBaseUrl,
        nousPortalBaseUrl: config.nousPortalBaseUrl,
        openAiCompatBaseUrl: config.openAiCompatBaseUrl,
        onWarning: (msg) => stderr.writeln('[model_catalog] $msg'),
      );
      _ownsModelCatalogService = true;
    }
    _peer.onRequest = _handleRequest;
    _peer.onNotification = _handleNotification;
  }

  static const int protocolVersion = 1;

  static const List<AcpModelOption> defaultModelCatalog = <AcpModelOption>[
    AcpModelOption(
      value: 'local-ollama/gemma4:12b',
      name: 'Local Ollama: gemma4:12b',
      description: 'Local Ollama default model',
    ),
    AcpModelOption(
      value: 'local-ollama/qwen3.8:27b',
      name: 'Local Ollama: qwen3.8:27b',
      description: 'Local Ollama 27B tool-calling model',
    ),
    AcpModelOption(
      value: 'local-ollama/ministral-3:14b',
      name: 'Local Ollama: ministral-3:14b',
      description: 'Local Ollama 14B model',
    ),
    AcpModelOption(
      value: 'ollama-cloud/gpt-oss:120b',
      name: 'Ollama Cloud: gpt-oss:120b',
      description: 'Ollama Cloud model (requires OLLAMA_API_KEY)',
    ),
    AcpModelOption(
      value: 'openrouter/anthropic/claude-sonnet-4',
      name: 'OpenRouter: Claude Sonnet 4',
      description: 'OpenRouter Anthropic Claude (requires OPENROUTER_API_KEY)',
    ),
    AcpModelOption(
      value: 'openrouter/openai/gpt-4.1',
      name: 'OpenRouter: GPT-4.1',
      description: 'OpenRouter OpenAI GPT-4.1 (requires OPENROUTER_API_KEY)',
    ),
  ];

  final JsonRpcPeer _peer;
  final AcpServerConfig config;
  late final ModelCatalogService _modelCatalogService;
  late final bool _ownsModelCatalogService;

  final Map<String, _AcpSession> _sessions = <String, _AcpSession>{};
  int _sessionCounter = 0;
  bool _disposed = false;

  /// Active session IDs currently registered in this server.
  Iterable<String> get sessionIds => _sessions.keys;

  /// Requests cooperative cancellation of any currently active turns across sessions.
  void cancelActiveTurns([String reason = 'Server shutting down']) {
    for (final session in _sessions.values) {
      session.bootstrap.processRunner.cancelActiveTurn(reason);
    }
  }

  /// Cancels any active turns, disposes all sessions, and flushes audit logs.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final session in sessions) {
      await session.dispose();
    }
    if (_ownsModelCatalogService) {
      _modelCatalogService.close();
    }
  }

  Future<Object?> _handleRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    return switch (method) {
      'initialize' => _onInitialize(params),
      'session/new' => _onSessionNew(params),
      'session/set_config_option' => _onSetConfigOption(params),
      'session/set_mode' => _onSetMode(params),
      'session/prompt' => _onSessionPrompt(params),
      '_fm_agent_os/tx_rollback' => _onTxRollback(params),
      '_fm_agent_os/status' => _onStatus(params),
      '_fm_agent_os/signal' => _onSignal(params),
      '_fm_agent_os/processes' => _onProcesses(params),
      '_fm_agent_os/stack_list' => _onStackList(params),
      '_fm_agent_os/stack_create' => _onStackCreate(params),
      '_fm_agent_os/stack_update' => _onStackUpdate(params),
      '_fm_agent_os/stack_edit' => _onStackEdit(params),
      '_fm_agent_os/stack_sync' => _onStackSync(params),
      '_fm_agent_os/jj_diff' => _onJjDiff(params),
      '_fm_agent_os/tx_squash' => _onTxSquash(params),
      _ => throw JsonRpcException(
          JsonRpcErrorCodes.methodNotFound,
          'Method not found: $method',
        ),
    };
  }

  Future<void> _handleNotification(
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case 'session/cancel':
        final sessionId = params['sessionId'];
        if (sessionId is String) {
          final session = _sessions[sessionId];
          session?.bootstrap.processRunner.cancelActiveTurn('ACP session/cancel');
        }
        return;
      default:
        // Unknown notifications (including `_` extensions) are ignored per JSON-RPC 2.0 & ACP.
        return;
    }
  }

  Map<String, dynamic> _onInitialize(Map<String, dynamic> params) {
    final clientProto = params['protocolVersion'];
    if (clientProto != null && clientProto is! int) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: protocolVersion must be an integer.',
      );
    }

    return <String, dynamic>{
      'protocolVersion': protocolVersion,
      'agentInfo': <String, dynamic>{
        'name': 'fm-agent-os',
        'version': '0.1.0',
      },
      'agentCapabilities': <String, dynamic>{
        'promptCapabilities': <String, dynamic>{
          'embeddedContext': true,
        },
      },
      'authMethods': const <Object>[],
    };
  }

  Future<Map<String, dynamic>> _onSessionNew(
    Map<String, dynamic> params,
  ) async {
    final rawCwd = params['cwd'];
    if (rawCwd is! String || rawCwd.trim().isEmpty) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: cwd must be a non-empty absolute path.',
      );
    }

    final rawMcpServers = params['mcpServers'];
    if (rawMcpServers != null && rawMcpServers is! List) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: mcpServers must be a list.',
      );
    }
    final sessionMcpSpecs = _parseSessionMcpServers(rawMcpServers as List?);
    final mergedMcpServers = _mergeMcpServers(
      cliSpecs: config.mcpServers,
      sessionSpecs: sessionMcpSpecs,
    );

    int? sessionMaxContextTokens;
    final rawNewMeta = params['_meta'];
    if (rawNewMeta != null) {
      if (rawNewMeta is! Map) {
        throw const JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: _meta must be an object.',
        );
      }
      final rawCap = rawNewMeta['fm_agent_os/maxContextTokens'];
      if (rawCap != null) {
        if (rawCap is! int || rawCap <= 0) {
          throw const JsonRpcException(
            JsonRpcErrorCodes.invalidParams,
            'Invalid params: _meta["fm_agent_os/maxContextTokens"] must be a positive integer.',
          );
        }
        sessionMaxContextTokens = rawCap;
      }
    }
    final effectiveMaxContextTokens =
        sessionMaxContextTokens ?? config.maxContextTokens;

    final trimmedCwd = rawCwd.trim();
    if (!p.isAbsolute(trimmedCwd)) {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: cwd "$trimmedCwd" must be an absolute path.',
      );
    }

    final normalizedCwd = p.normalize(trimmedCwd);
    if (!Directory(normalizedCwd).existsSync()) {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: cwd directory does not exist: $normalizedCwd',
      );
    }

    if (!Directory(p.join(normalizedCwd, '.jj')).existsSync()) {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: cwd is not a Jujutsu (.jj) repository: $normalizedCwd',
      );
    }

    final ModelPolicy effectivePolicy;
    if (config.modelPolicy != null) {
      effectivePolicy = config.modelPolicy!;
    } else {
      final loadResult = ModelsConfigLoader(sessionCwd: normalizedCwd).load();
      for (final warning in loadResult.warnings) {
        stderr.writeln('[models_config] $warning');
      }
      effectivePolicy = ModelPolicy(
        config: loadResult.config,
        envLoader: LlmEnvLoader(sessionCwd: normalizedCwd),
        explicitOpenAiCompatBaseUrl: config.openAiCompatBaseUrl,
      );
    }

    final rawStartupModel = config.startupModel?.trim();
    final hasStartupModel =
        rawStartupModel != null && rawStartupModel.isNotEmpty;
    final targetModelStr =
        hasStartupModel ? rawStartupModel : ModelResolver.stage1DefaultModelId;
    final parsedTarget = ModelIdentifier.parse(targetModelStr);
    if (!parsedTarget.ok) {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        parsedTarget.error!.message,
        data: parsedTarget.error!.toJson(),
      );
    }
    final startupPolicyErr = effectivePolicy.validateModel(parsedTarget.value!);
    if (startupPolicyErr != null) {
      final message = hasStartupModel
          ? startupPolicyErr.message
          : 'Default startup model "${ModelResolver.stage1DefaultModelId}" is disabled or excluded by .agent_os/models.json. Specify an allowed model via --model <providerId>/<modelName>.';
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        message,
        data: startupPolicyErr.toJson(),
      );
    }

    final catalogEntries =
        await _modelCatalogService.resolveOptions(effectivePolicy);
    final dynamicCatalog = catalogEntries
        .map(
          (entry) => AcpModelOption(
            value: entry.id,
            name: entry.displayName,
            description: entry.description,
          ),
        )
        .toList(growable: false);

    final sessionId = _generateSessionId();
    late final AcpEventMapper mapper;
    late final KernelBootstrap bootstrap;

    final approvalHandler = AcpApprovalHandler(
      peer: _peer,
      activeToolCallIdProvider: () => mapper.activeToolCallId,
      onDecision: (req, decision) =>
          mapper.recordApprovalResolution(req, decision),
    );

    final observerHook = _DeferredAcpObserverHook(() => mapper);
    final effectiveMaxSyscalls =
        config.maxSyscallsPerTurn ?? max(256, config.maxStepsPerTurn * 8);
    final leadQuota = ResourceQuota(
      maxChildProcesses: ResourceQuota.stage2Default.maxChildProcesses,
      maxSyscallCountPerTurn: effectiveMaxSyscalls,
    );

    final bootstrapConfig = KernelBootstrapConfig(
      workspaceHostRoot: normalizedCwd,
      sessionId: sessionId,
      startupModel: config.startupModel,
      systemInstruction: config.systemInstruction,
      approvalHandler: approvalHandler,
      hooks: <SyscallHook>[observerHook],
      localOllamaBaseUrl: config.localOllamaBaseUrl,
      ollamaCloudBaseUrl: config.ollamaCloudBaseUrl,
      openRouterBaseUrl: config.openRouterBaseUrl,
      openAiBaseUrl: config.openAiBaseUrl,
      geminiBaseUrl: config.geminiBaseUrl,
      nousPortalBaseUrl: config.nousPortalBaseUrl,
      openAiCompatBaseUrl: config.openAiCompatBaseUrl,
      modelPolicy: effectivePolicy,
      execPolicy: config.execPolicy,
      quota: leadQuota,
      enableStage2Multiprocess: true,
      enableStage3Team: true,
      maxContextTokens: effectiveMaxContextTokens,
      mcpServers: mergedMcpServers,
      maxStepsPerTurn: config.maxStepsPerTurn,
      jjExecutable: config.jjExecutable,
      skillsDirs: config.skillsDirs,
      skillsDirEnv: config.skillsDirEnv,
      onPagingReport: (report, {Pid pid = 1}) {
        if (pid == 1) {
          mapper.recordPagingReport(report);
        }
      },
      onLlmStreamEvent: (sid, turnIndex, event) {
        mapper.onLlmStreamEvent(sid, turnIndex, event, pid: 1);
      },
    );

    try {
      bootstrap = config.bootstrapFactory != null
          ? config.bootstrapFactory!(bootstrapConfig)
          : KernelBootstrap.create(bootstrapConfig);
    } on ArgumentError catch (e) {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        e.message?.toString() ?? 'Invalid session configuration.',
        data: <String, dynamic>{
          'code': 'EINVAL',
          'reason': 'MAX_CONTEXT_TOKENS_TOO_SMALL',
        },
      );
    }

    if (mergedMcpServers.isNotEmpty) {
      final mcpConnRes = await bootstrap.connectMcpServers(mergedMcpServers);
      if (!mcpConnRes.ok) {
        await bootstrap.dispose();
        final err = mcpConnRes.error!;
        final rpcCode = err.code == SyscallErrorCode.einval
            ? JsonRpcErrorCodes.invalidParams
            : JsonRpcErrorCodes.serverError;
        throw JsonRpcException(
          rpcCode,
          bootstrap.redactor.redactString(err.message),
          data: bootstrap.redactor.redactJson(err.toJson()),
        );
      }
    }

    mapper = AcpEventMapper(
      sessionId: sessionId,
      peer: _peer,
      namespace: bootstrap.namespace,
      jjContext: bootstrap.pcb.jjContext,
      redactor: bootstrap.redactor,
      contextWindowSize: effectiveMaxContextTokens ??
          bootstrap.pcb.quota.maxTotalTokens ??
          32768,
    );

    final eventSubscription =
        bootstrap.processRunner.events.listen(mapper.onAgentLoopEvent);

    final session = _AcpSession(
      sessionId: sessionId,
      bootstrap: bootstrap,
      mapper: mapper,
      eventSubscription: eventSubscription,
      initialCatalog: dynamicCatalog,
      modelPolicy: effectivePolicy,
    );
    session.ensureModelInOptions(bootstrap.modelResolver.effectiveModelString());
    _sessions[sessionId] = session;

    final jjInfo = await bootstrap.jjDriver.getAuditInfo();

    return <String, dynamic>{
      'sessionId': sessionId,
      'configOptions': session.buildConfigOptions(),
      '_meta': <String, dynamic>{
        'fm_agent_os/jj': <String, dynamic>{
          'jjChangeId': jjInfo.jjChangeId,
          'jjOpId': jjInfo.jjOpId,
          'txState': bootstrap.pcb.jjContext.state.name,
        },
      },
    };
  }

  Map<String, dynamic> _onSetConfigOption(Map<String, dynamic> params) {
    final session = _requireSession(params);
    final configId = params['configId'];
    if (configId != 'model') {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: unsupported configId "$configId".',
      );
    }

    final value = params['value'];
    if (value is! String || value.trim().isEmpty) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: value must be a non-empty "<providerId>/<modelName>" string.',
      );
    }

    final res = session.bootstrap.processRunner.setSessionModel(value);
    if (!res.ok) {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        res.error!.message,
        data: res.error!.toJson(),
      );
    }

    session.ensureModelInOptions(res.value!.canonicalId);
    return <String, dynamic>{
      'configOptions': session.buildConfigOptions(),
    };
  }

  Map<String, dynamic> _onSetMode(Map<String, dynamic> params) {
    final session = _requireSession(params);
    final modeId = params['modeId'];
    if (modeId is! String || modeId.trim().isEmpty) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: modeId must be a non-empty string.',
      );
    }
    session.modeId = modeId.trim();
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _onSessionPrompt(
    Map<String, dynamic> params,
  ) async {
    final session = _requireSession(params);
    if (session.isPromptActive) {
      throw JsonRpcException(
        JsonRpcErrorCodes.serverError,
        'A prompt turn is already active for session "${session.sessionId}".',
      );
    }

    final rawPrompt = params['prompt'];
    if (rawPrompt is! List) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: prompt must be a list of ContentBlock objects.',
      );
    }

    final userInput = _extractPromptText(rawPrompt);
    if (userInput.isEmpty) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: prompt must contain at least one non-empty text block.',
      );
    }

    String? modelOverride;
    String? taskId;
    var executionMode = 'single';
    final rawMeta = params['_meta'];
    if (rawMeta != null) {
      if (rawMeta is! Map) {
        throw const JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: _meta must be an object.',
        );
      }
      final overrideVal = rawMeta['fm_agent_os/modelOverride'];
      if (overrideVal != null) {
        if (overrideVal is! String || overrideVal.trim().isEmpty) {
          throw const JsonRpcException(
            JsonRpcErrorCodes.invalidParams,
            'Invalid params: _meta["fm_agent_os/modelOverride"] must be a non-empty string.',
          );
        }
        final check = ModelIdentifier.parse(overrideVal);
        if (!check.ok) {
          throw JsonRpcException(
            JsonRpcErrorCodes.invalidParams,
            check.error!.message,
          );
        }
        final policyErr = session.modelPolicy.validateModel(check.value!);
        if (policyErr != null) {
          throw JsonRpcException(
            JsonRpcErrorCodes.invalidParams,
            policyErr.message,
            data: policyErr.toJson(),
          );
        }
        modelOverride = check.value!.canonicalId;
      }

      final rawTaskId = rawMeta['fm_agent_os/taskId'];
      if (rawTaskId != null) {
        if (rawTaskId is! String || rawTaskId.trim().isEmpty) {
          throw const JsonRpcException(
            JsonRpcErrorCodes.invalidParams,
            'Invalid params: _meta["fm_agent_os/taskId"] must be a non-empty string.',
          );
        }
        taskId = rawTaskId.trim();
      }

      final rawExecMode = rawMeta['fm_agent_os/executionMode'];
      if (rawExecMode != null) {
        if (rawExecMode is! String ||
            (rawExecMode != 'single' && rawExecMode != 'parallel_team')) {
          throw const JsonRpcException(
            JsonRpcErrorCodes.invalidParams,
            'Invalid params: _meta["fm_agent_os/executionMode"] must be "single" or "parallel_team".',
          );
        }
        executionMode = rawExecMode;
      }
    }

    StackedTaskNode? boundTask;
    if (taskId != null) {
      final stackMgr = session.bootstrap.stackedTaskManager;
      boundTask = stackMgr?.registry.getByTaskId(taskId);
      if (boundTask == null) {
        throw JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'ENOENT: TASK_NOT_FOUND: Task "$taskId" was not found.',
          data: const <String, dynamic>{
            'code': 'ENOENT',
            'reason': 'TASK_NOT_FOUND',
          },
        );
      }
    }

    final dynamicContextParts = <String>[];
    final mcpSummary = session.bootstrap.renderDynamicContextSummary();
    if (mcpSummary.isNotEmpty) {
      dynamicContextParts.add(mcpSummary);
    }
    if (boundTask != null) {
      dynamicContextParts.add(
        '[StackedTask Context] Bound to task "${boundTask.taskId}" '
        '(workspace="${boundTask.workspaceName}", workingChangeId="${boundTask.workingChangeId}"). '
        'Direct file edits apply inside this task workspace. '
        'If you spawn WorkspaceWorker children, integrate their completed Change IDs into this task '
        'using sys_task_stack(action: "integrate_worker", taskId: "${boundTask.taskId}", workerChangeIds: [...]).',
      );
    }
    if (executionMode == 'parallel_team') {
      dynamicContextParts.add(
        AgentPrompts.buildParallelTeamInstruction(
          boundTaskId: boundTask?.taskId,
        ),
      );
    }
    final dynamicContextSummary = dynamicContextParts.isEmpty
        ? null
        : dynamicContextParts.join('\n');

    final origNamespace = session.bootstrap.pcb.namespace;
    final origWsName = session.bootstrap.pcb.jjWorkspaceName;
    final origWsRoot = session.bootstrap.pcb.jjWorkspaceRoot;
    final origWorkingChangeId =
        session.bootstrap.pcb.jjContext.workingChangeId;

    if (boundTask != null) {
      boundTask.state = StackedTaskState.running;
      boundTask.activePid = 1;
      session.bootstrap.pcb.namespace = VfsNamespace(
        workspaceHostRoot: boundTask.workspaceRoot,
        skillsMount: origNamespace.skillsMount,
      );
      session.bootstrap.pcb.jjWorkspaceName = boundTask.workspaceName;
      session.bootstrap.pcb.jjWorkspaceRoot = boundTask.workspaceRoot;
      session.bootstrap.pcb.jjContext.workingChangeId =
          boundTask.workingChangeId;
      session.mapper.emitTeamEvent(<String, dynamic>{
        'kind': 'task_started',
        'task': boundTask.toJson(),
      });
    }

    session.isPromptActive = true;
    AgentTurnResult? result;
    try {
      result = await session.bootstrap.processRunner.submitPrompt(
        userInput: userInput,
        dynamicContextSummary: dynamicContextSummary,
        modelOverride: modelOverride,
      );
    } finally {
      session.isPromptActive = false;
      if (boundTask != null) {
        session.bootstrap.pcb.namespace = origNamespace;
        session.bootstrap.pcb.jjWorkspaceName = origWsName;
        session.bootstrap.pcb.jjWorkspaceRoot = origWsRoot;
        session.bootstrap.pcb.jjContext.workingChangeId = origWorkingChangeId;

        final stackMgr = session.bootstrap.stackedTaskManager!;
        final syncRes = await stackMgr.syncTasks(taskId: boundTask.taskId);
        boundTask.activePid = null;
        if (session.bootstrap.pcb.state != ProcessState.stopped) {
          if (result == null || !result.ok) {
            boundTask.state = StackedTaskState.failed;
          } else if (boundTask.hasConflicts) {
            boundTask.state = StackedTaskState.conflict;
          } else {
            boundTask.state = StackedTaskState.review;
          }
        }
        session.mapper.emitTeamEvent(<String, dynamic>{
          'kind': 'task_completed',
          'task': boundTask.toJson(),
          if (syncRes.ok) 'cascadedTasks': syncRes.value!['cascadedTasks'],
        });
      }
    }

    final jjInfo = await session.bootstrap.jjDriver.getAuditInfo();
    final redactor = session.bootstrap.redactor;

    final turnSummary = <String, dynamic>{
      'sessionId': session.sessionId,
      'turnIndex': result.turnIndex,
      'ok': result.ok,
      'model': result.model?.canonicalId,
      'steps': result.steps,
      'toolCallsExecuted': result.toolCallsExecuted,
      'jjChangeId': jjInfo.jjChangeId,
      'jjOpId': jjInfo.jjOpId,
      'txState': session.bootstrap.pcb.jjContext.state.name,
      'totalTokensUsed': session.bootstrap.pcb.quotaUsage.totalTokensUsed,
      'activeChildProcesses':
          session.bootstrap.pcb.quotaUsage.activeChildProcesses,
      'spawnedChildrenCount':
          session.bootstrap.workerHost?.spawnedChildrenCount ?? 0,
      ...session.mapper.buildTurnSummaryPagingMeta(
        session.bootstrap.pcb.memory,
      ),
      if (result.usage != null)
        'usage': <String, dynamic>{
          'promptTokens': result.usage!.promptTokens,
          'completionTokens': result.usage!.completionTokens,
          'totalTokens': result.usage!.totalTokens,
          'cachedTokens': result.usage!.cachedTokens,
          'cacheWriteTokens': result.usage!.cacheWriteTokens,
          'cacheHitRate': result.usage!.cacheHitRate,
          'costMicroUsd': result.usage!.costMicroUsd,
          'ttftMs': result.usage!.ttftMs,
          'durationMs': result.usage!.durationMs,
        },
      if (!result.ok && result.error != null)
        'error': redactor.redactJson(result.error!.toJson()),
    };

    if (result.ok) {
      return <String, dynamic>{
        'stopReason': 'end_turn',
        '_meta': <String, dynamic>{
          'fm_agent_os/turnSummary': turnSummary,
        },
      };
    }

    final err = result.error!;
    switch (err.code) {
      case SyscallErrorCode.ecancelled:
        return <String, dynamic>{
          'stopReason': 'cancelled',
          '_meta': <String, dynamic>{
            'fm_agent_os/turnSummary': turnSummary,
          },
        };
      case SyscallErrorCode.edquot:
        return <String, dynamic>{
          'stopReason': 'max_tokens',
          '_meta': <String, dynamic>{
            'fm_agent_os/turnSummary': turnSummary,
          },
        };
      case SyscallErrorCode.eperm:
      case SyscallErrorCode.eacces:
        return <String, dynamic>{
          'stopReason': 'refusal',
          '_meta': <String, dynamic>{
            'fm_agent_os/turnSummary': turnSummary,
          },
        };
      case SyscallErrorCode.einval:
        throw JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          redactor.redactString(err.message),
          data: redactor.redactJson(err.toJson()),
        );
      default:
        throw JsonRpcException(
          JsonRpcErrorCodes.serverError,
          redactor.redactString(err.message),
          data: redactor.redactJson(err.toJson()),
        );
    }
  }

  Future<Map<String, dynamic>> _onTxRollback(
    Map<String, dynamic> params,
  ) async {
    final session = _requireSession(params);
    final rawTarget = params['targetOpId'];
    if (rawTarget != null && rawTarget is! String) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: targetOpId must be a string.',
      );
    }

    final trimmedTarget = (rawTarget as String?)?.trim();
    final res = await session.bootstrap.syscallGate.invoke(
      SyscallContext(
        pid: session.bootstrap.pcb.pid,
        capHandle: session.bootstrap.capHandle,
        sessionId: session.sessionId,
      ),
      SyscallRequest(
        name: 'sys_tx_rollback',
        args: <String, dynamic>{
          if (trimmedTarget != null && trimmedTarget.isNotEmpty)
            'targetOpId': trimmedTarget,
        },
      ),
    );

    if (!res.ok) {
      final err = res.error!;
      final rpcCode = err.code == SyscallErrorCode.einval
          ? JsonRpcErrorCodes.invalidParams
          : JsonRpcErrorCodes.serverError;
      throw JsonRpcException(
        rpcCode,
        session.bootstrap.redactor.redactString(err.message),
        data: session.bootstrap.redactor.redactJson(err.toJson()),
      );
    }

    final value = res.value!;
    return <String, dynamic>{
      'restoredOpId': value['restoredToOpId'],
      'currentOpId': value['jjOpId'],
      'workingChangeId': value['workingChangeId'],
      'state': value['state'],
    };
  }

  Future<Map<String, dynamic>> _onStatus(Map<String, dynamic> params) async {
    final session = _requireSession(params);
    final jjInfo = await session.bootstrap.jjDriver.getAuditInfo();
    final tx = session.bootstrap.pcb.jjContext;
    return <String, dynamic>{
      'sessionId': session.sessionId,
      'model': session.bootstrap.modelResolver.effectiveModelString(),
      'modeId': session.modeId,
      'jjChangeId': jjInfo.jjChangeId,
      'jjOpId': jjInfo.jjOpId,
      'txState': tx.state.name,
      'baseOpId': tx.baseOpId,
      'parentChangeId': tx.parentChangeId,
      'totalTokensUsed': session.bootstrap.pcb.quotaUsage.totalTokensUsed,
      'activeChildProcesses':
          session.bootstrap.pcb.quotaUsage.activeChildProcesses,
      'spawnedChildrenCount':
          session.bootstrap.workerHost?.spawnedChildrenCount ?? 0,
      ...session.mapper.buildTurnSummaryPagingMeta(
        session.bootstrap.pcb.memory,
      ),
    };
  }

  Future<Map<String, dynamic>> _onSignal(Map<String, dynamic> params) async {
    final session = _requireSession(params);
    final rawSignal = params['signal'];
    if (rawSignal is! String || rawSignal.trim().isEmpty) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: signal must be "SIGSTOP", "SIGCONT", or "SIGKILL".',
      );
    }
    final signalKind = ProcessSignalKind.tryParse(rawSignal.trim());
    if (signalKind == null) {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: unsupported signal "$rawSignal".',
      );
    }

    final rawPid = params['pid'];
    if (rawPid != null && (rawPid is! int || rawPid < 1)) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: pid must be a positive integer.',
      );
    }

    final rawTaskId = params['taskId'];
    final taskId = (rawTaskId is String && rawTaskId.trim().isNotEmpty)
        ? rawTaskId.trim()
        : null;
    final rawConstraint = params['constraintMessage'];
    if (rawConstraint != null && rawConstraint is! String) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: constraintMessage must be a string.',
      );
    }
    final constraintMessage = (rawConstraint as String?)?.trim();
    final cascadeChildren = (params['cascadeChildren'] as bool?) ?? true;

    StackedTaskNode? taskNode;
    if (taskId != null) {
      taskNode = session.bootstrap.stackedTaskManager?.registry.getByTaskId(
        taskId,
      );
    }
    final targetPid = rawPid as int? ?? taskNode?.activePid ?? 1;

    final workerHost = session.bootstrap.workerHost;
    final affectedPids = <int>[targetPid];

    if (targetPid == 1) {
      final rootPcb = session.bootstrap.pcb;
      switch (signalKind) {
        case ProcessSignalKind.sigstop:
          rootPcb.suspendController.requestStop(reason: 'ACP SIGSTOP');
          if (rootPcb.state == ProcessState.running ||
              rootPcb.state == ProcessState.waitingSyscall ||
              rootPcb.state == ProcessState.waitingApproval) {
            rootPcb.state = ProcessState.stopped;
          }
          if (taskNode != null) {
            taskNode.state = StackedTaskState.paused;
          }
        case ProcessSignalKind.sigcont:
          rootPcb.suspendController.requestContinue(
            constraintMessage:
                (constraintMessage != null && constraintMessage.isNotEmpty)
                    ? constraintMessage
                    : null,
          );
          if (rootPcb.state == ProcessState.stopped) {
            rootPcb.state = ProcessState.running;
          }
          if (taskNode != null && taskNode.state == StackedTaskState.paused) {
            taskNode.state = StackedTaskState.running;
          }
        case ProcessSignalKind.sigkill:
          await session.bootstrap.processRunner
              .killActiveTurnAndTree('ACP SIGKILL');
          if (taskNode != null) {
            taskNode.state = StackedTaskState.failed;
            taskNode.activePid = null;
          }
      }
      if (workerHost != null) {
        if (cascadeChildren && signalKind != ProcessSignalKind.sigkill) {
          for (final proc in workerHost.snapshotProcesses()) {
            final cPid = proc['pid'] as int?;
            final cState = proc['state'] as String?;
            if (cPid != null &&
                cState != 'terminated' &&
                cState != 'failed') {
              affectedPids.add(cPid);
            }
          }
        }
        await workerHost.sendSignal(
          targetPid: 1,
          signal: signalKind,
          constraintMessage:
              (constraintMessage != null && constraintMessage.isNotEmpty)
                  ? constraintMessage
                  : null,
          reason: 'ACP ${signalKind.wireValue}',
          cascadeChildren: cascadeChildren,
        );
      }
      if (signalKind == ProcessSignalKind.sigstop &&
          rootPcb.suspendController.isSuspended) {
        rootPcb.state = ProcessState.stopped;
      } else if (signalKind == ProcessSignalKind.sigcont &&
          rootPcb.state == ProcessState.stopped) {
        rootPcb.state = ProcessState.running;
      }
    } else {
      if (workerHost == null) {
        throw const JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'No child worker host available for target pid.',
        );
      }
      await workerHost.sendSignal(
        targetPid: targetPid,
        signal: signalKind,
        constraintMessage:
            (constraintMessage != null && constraintMessage.isNotEmpty)
                ? constraintMessage
                : null,
        reason: 'ACP ${signalKind.wireValue}',
        cascadeChildren: cascadeChildren,
      );
    }

    session.mapper.emitTeamEvent(<String, dynamic>{
      'kind': 'signal',
      'signal': signalKind.wireValue,
      'targetPid': targetPid,
      'affectedPids': affectedPids,
      'leadState': session.bootstrap.pcb.state.name,
      'taskId': ?taskId,
    });

    return <String, dynamic>{
      'ok': true,
      'signal': signalKind.wireValue,
      'affectedPids': affectedPids,
      'leadState': session.bootstrap.pcb.state.name,
    };
  }

  Future<Map<String, dynamic>> _onProcesses(Map<String, dynamic> params) async {
    final session = _requireSession(params);
    final jjInfo = await session.bootstrap.jjDriver.getAuditInfo();
    final rootPcb = session.bootstrap.pcb;
    final children =
        session.bootstrap.workerHost?.snapshotProcesses() ?? const <Map<String, dynamic>>[];

    return <String, dynamic>{
      'lead': <String, dynamic>{
        'pid': rootPcb.pid,
        'state': rootPcb.state.name,
        'isSuspended': rootPcb.suspendController.isSuspended,
        'jjChangeId': jjInfo.jjChangeId,
        'jjOpId': jjInfo.jjOpId,
      },
      'processes': children,
    };
  }

  Future<Map<String, dynamic>> _onStackList(Map<String, dynamic> params) async {
    final session = _requireSession(params);
    final stackMgr = _requireStackedTaskManager(session);
    final res = await stackMgr.listTasks();
    if (!res.ok) {
      _throwSyscallRpcError(session, res.error!);
    }
    return res.value!;
  }

  Future<Map<String, dynamic>> _onStackCreate(
    Map<String, dynamic> params,
  ) async {
    final session = _requireSession(params);
    final stackMgr = _requireStackedTaskManager(session);
    final title = params['title'];
    if (title is! String || title.trim().isEmpty) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: title must be a non-empty string.',
      );
    }
    final res = await stackMgr.createTask(
      taskId: params['taskId'] as String?,
      title: title,
      description: (params['description'] as String?) ?? '',
      parentTaskId: params['parentTaskId'] as String?,
      baseChangeId: params['baseChangeId'] as String?,
      model: params['model'] as String?,
    );
    if (!res.ok) {
      _throwSyscallRpcError(session, res.error!);
    }
    session.mapper.emitTeamEvent(<String, dynamic>{
      'kind': 'stack_created',
      'task': res.value!['task'],
    });
    return res.value!;
  }

  Future<Map<String, dynamic>> _onStackUpdate(
    Map<String, dynamic> params,
  ) async {
    final session = _requireSession(params);
    final stackMgr = _requireStackedTaskManager(session);
    final rawTaskId = params['taskId'];
    if (rawTaskId is! String || rawTaskId.trim().isEmpty) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: taskId must be a non-empty string.',
      );
    }
    final node = stackMgr.registry.getByTaskId(rawTaskId.trim());
    if (node == null) {
      _throwSyscallRpcError(
        session,
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'TASK_NOT_FOUND',
          message: 'Task "${rawTaskId.trim()}" was not found.',
        ),
      );
    }

    final rawModel = params['model'];
    if (rawModel != null) {
      if (rawModel is! String || rawModel.trim().isEmpty) {
        throw const JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: model must be a non-empty string.',
        );
      }
      final check = ModelIdentifier.parse(rawModel.trim());
      if (!check.ok) {
        throw JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          check.error!.message,
        );
      }
      node.assignedModel = check.value!.canonicalId;
    }

    final rawState = params['state'];
    if (rawState != null) {
      if (rawState is! String || rawState.trim().isEmpty) {
        throw const JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: state must be a non-empty string.',
        );
      }
      final parsedState = StackedTaskState.tryParse(rawState);
      if (parsedState == null) {
        throw JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: unknown StackedTaskState "$rawState".',
        );
      }
      node.state = parsedState;
    }

    final rawTitle = params['title'];
    if (rawTitle is String && rawTitle.trim().isNotEmpty) {
      node.title = rawTitle.trim();
    }
    final rawDesc = params['description'];
    if (rawDesc is String) {
      node.description = rawDesc;
    }

    session.mapper.emitTeamEvent(<String, dynamic>{
      'kind': 'stack_updated',
      'task': node.toJson(),
    });
    return <String, dynamic>{'task': node.toJson()};
  }

  Future<Map<String, dynamic>> _onStackEdit(Map<String, dynamic> params) async {
    final session = _requireSession(params);
    final stackMgr = _requireStackedTaskManager(session);
    final taskId = params['taskId'];
    final relativePath = params['relativePath'];
    final content = params['content'];
    if (taskId is! String ||
        taskId.trim().isEmpty ||
        relativePath is! String ||
        relativePath.trim().isEmpty ||
        content is! String) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: taskId, relativePath, and content are required.',
      );
    }

    var expectedSha256 = params['expectedSha256'] as String?;
    if (expectedSha256 == null) {
      final node = stackMgr.registry.getByTaskId(taskId.trim());
      if (node != null) {
        final cleanRel = relativePath.replaceAll('\\', '/').trim();
        final virtualPath =
            cleanRel.startsWith('/workspace/') ? cleanRel : '/workspace/$cleanRel';
        final taskNs = VfsNamespace(workspaceHostRoot: node.workspaceRoot);
        final readRes = await session.bootstrap.hostFsDriver.readLines(
          path: virtualPath,
          startLine: 1,
          endLine: 1,
          namespaceOverride: taskNs,
        );
        if (readRes.ok && readRes.value != null) {
          expectedSha256 = readRes.value!['sha256'] as String?;
        }
      }
    }

    final res = await stackMgr.editTaskFile(
      taskId: taskId.trim(),
      relativePath: relativePath.trim(),
      content: content,
      expectedSha256: expectedSha256,
    );
    if (!res.ok) {
      _throwSyscallRpcError(session, res.error!);
    }

    session.mapper.emitTeamEvent(<String, dynamic>{
      'kind': 'stack_edited',
      'task': res.value!['task'],
      'cascadedTasks': res.value!['cascadedTasks'],
    });
    return <String, dynamic>{
      'task': res.value!['task'],
      'cascadedTasks': res.value!['cascadedTasks'],
      'jjOpId': res.value!['jjOpId'],
    };
  }

  Future<Map<String, dynamic>> _onStackSync(Map<String, dynamic> params) async {
    final session = _requireSession(params);
    final stackMgr = _requireStackedTaskManager(session);
    final rawTaskId = params['taskId'];
    if (rawTaskId != null && rawTaskId is! String) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: taskId must be a string.',
      );
    }
    final res = await stackMgr.syncTasks(taskId: rawTaskId as String?);
    if (!res.ok) {
      _throwSyscallRpcError(session, res.error!);
    }
    session.mapper.emitTeamEvent(<String, dynamic>{
      'kind': 'stack_synced',
      'cascadedTasks': res.value!['cascadedTasks'],
    });
    return res.value!;
  }

  Future<Map<String, dynamic>> _onJjDiff(Map<String, dynamic> params) async {
    final session = _requireSession(params);
    final rawTaskId = params['taskId'];
    final rawRev = params['rev'];
    if (rawTaskId is String && rawTaskId.trim().isNotEmpty) {
      final stackMgr = _requireStackedTaskManager(session);
      final node = stackMgr.registry.getByTaskId(rawTaskId.trim());
      if (node == null) {
        _throwSyscallRpcError(
          session,
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'TASK_NOT_FOUND',
            message: 'Task "${rawTaskId.trim()}" was not found.',
          ),
        );
      }
      final diffRes = await session.bootstrap.jjDriver.diffForTask(
        taskNode: node,
      );
      if (!diffRes.ok) {
        _throwSyscallRpcError(session, diffRes.error!);
      }
      return <String, dynamic>{
        'rev': node.workingChangeId,
        'diff': diffRes.value!,
        'hasConflicts': node.hasConflicts,
        'conflictedFiles': List<String>.from(node.conflictedFiles),
      };
    }

    final rev =
        (rawRev is String && rawRev.trim().isNotEmpty) ? rawRev.trim() : '@';
    final diffRes = await session.bootstrap.jjDriver.diff(rev: rev);
    if (!diffRes.ok) {
      _throwSyscallRpcError(session, diffRes.error!);
    }
    final confRes =
        await session.bootstrap.jjDriver.inspectConflictsNonDestructive(
      rev: rev,
    );
    final confMap = confRes.ok ? confRes.value! : const <String, dynamic>{};
    return <String, dynamic>{
      ...diffRes.value!,
      'hasConflicts': confMap['hasConflicts'] ?? false,
      'conflictedFiles': confMap['files'] ?? const <String>[],
    };
  }

  Future<Map<String, dynamic>> _onTxSquash(Map<String, dynamic> params) async {
    final session = _requireSession(params);
    final rawTaskId = params['taskId'];
    final rawMessage = params['message'];
    if (rawMessage != null && rawMessage is! String) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: message must be a string.',
      );
    }

    StackedTaskNode? taskNode;
    if (rawTaskId is String && rawTaskId.trim().isNotEmpty) {
      final stackMgr = _requireStackedTaskManager(session);
      taskNode = stackMgr.registry.getByTaskId(rawTaskId.trim());
      if (taskNode == null) {
        _throwSyscallRpcError(
          session,
          SyscallError(
            code: SyscallErrorCode.enoent,
            reason: 'TASK_NOT_FOUND',
            message: 'Task "${rawTaskId.trim()}" was not found.',
          ),
        );
      }
      if (taskNode.hasConflicts) {
        _throwSyscallRpcError(
          session,
          SyscallError(
            code: SyscallErrorCode.econflict,
            reason: 'UNRESOLVED_CONFLICTS',
            message:
                'Task "${taskNode.taskId}" still has unresolved conflicts: ${taskNode.conflictedFiles.join(', ')}.',
          ),
        );
      }
    }

    final res = await session.bootstrap.syscallGate.invoke(
      SyscallContext(
        pid: session.bootstrap.pcb.pid,
        capHandle: session.bootstrap.capHandle,
        sessionId: session.sessionId,
      ),
      SyscallRequest(
        name: 'sys_tx_squash',
        args: <String, dynamic>{
          if (rawMessage is String && rawMessage.trim().isNotEmpty)
            'message': rawMessage.trim(),
        },
      ),
    );
    if (!res.ok) {
      _throwSyscallRpcError(session, res.error!);
    }
    if (taskNode != null) {
      taskNode.state = StackedTaskState.done;
      session.mapper.emitTeamEvent(<String, dynamic>{
        'kind': 'stack_squashed',
        'task': taskNode.toJson(),
      });
    }
    return <String, dynamic>{
      ...res.value!,
      if (taskNode != null) 'task': taskNode.toJson(),
    };
  }

  StackedTaskManager _requireStackedTaskManager(_AcpSession session) {
    final mgr = session.bootstrap.stackedTaskManager;
    if (mgr == null) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.serverError,
        'StackedTaskManager is not enabled on this session.',
      );
    }
    return mgr;
  }

  Never _throwSyscallRpcError(_AcpSession session, SyscallError err) {
    final rpcCode = err.code == SyscallErrorCode.einval
        ? JsonRpcErrorCodes.invalidParams
        : JsonRpcErrorCodes.serverError;
    throw JsonRpcException(
      rpcCode,
      session.bootstrap.redactor.redactString(err.message),
      data: session.bootstrap.redactor.redactJson(err.toJson()),
    );
  }

  static List<McpServerSpec> _parseSessionMcpServers(List<dynamic>? rawList) {
    if (rawList == null || rawList.isEmpty) {
      return const <McpServerSpec>[];
    }
    final seenNames = <String>{};
    final specs = <McpServerSpec>[];
    for (final item in rawList) {
      if (item is! Map) {
        throw const JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: each mcpServers entry must be an object.',
        );
      }
      final map = Map<String, dynamic>.from(item);
      final rawType = map['type'];
      final transportType = rawType == null
          ? 'stdio'
          : (rawType is String ? rawType.trim().toLowerCase() : '');
      if (transportType != 'stdio') {
        throw JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: unsupported MCP transport "$rawType"; only "stdio" is supported.',
          data: const <String, dynamic>{
            'code': 'EINVAL',
            'reason': 'UNSUPPORTED_MCP_TRANSPORT',
          },
        );
      }
      final rawName = map['name'];
      final rawCommand = map['command'];
      if (rawName is! String ||
          rawName.trim().isEmpty ||
          rawCommand is! String ||
          rawCommand.trim().isEmpty) {
        throw const JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'Invalid params: mcpServers entries require non-empty "name" and "command".',
        );
      }
      final name = rawName.trim();
      if (!seenNames.add(name)) {
        throw JsonRpcException(
          JsonRpcErrorCodes.invalidParams,
          'EINVAL: DUPLICATE_MCP_SERVER_NAME: Duplicate MCP server name "$name".',
          data: const <String, dynamic>{
            'code': 'EINVAL',
            'reason': 'DUPLICATE_MCP_SERVER_NAME',
          },
        );
      }
      final args = <String>[];
      final rawArgs = map['args'];
      if (rawArgs != null) {
        if (rawArgs is! List) {
          throw const JsonRpcException(
            JsonRpcErrorCodes.invalidParams,
            'Invalid params: mcpServers[].args must be a list of strings.',
          );
        }
        for (final arg in rawArgs) {
          if (arg is! String) {
            throw const JsonRpcException(
              JsonRpcErrorCodes.invalidParams,
              'Invalid params: mcpServers[].args entries must be strings.',
            );
          }
          args.add(arg);
        }
      }
      final env = <McpEnvVar>[];
      final rawEnv = map['env'];
      if (rawEnv != null) {
        if (rawEnv is! List) {
          throw const JsonRpcException(
            JsonRpcErrorCodes.invalidParams,
            'Invalid params: mcpServers[].env must be a list.',
          );
        }
        for (final entry in rawEnv) {
          if (entry is! Map) {
            throw const JsonRpcException(
              JsonRpcErrorCodes.invalidParams,
              'Invalid params: mcpServers[].env entries must be objects.',
            );
          }
          final eName = entry['name'];
          final eVal = entry['value'];
          if (eName is! String || eName.trim().isEmpty || eVal is! String) {
            throw const JsonRpcException(
              JsonRpcErrorCodes.invalidParams,
              'Invalid params: mcpServers[].env entries require non-empty "name" and string "value".',
            );
          }
          env.add(McpEnvVar(name: eName.trim(), value: eVal));
        }
      }
      specs.add(
        McpServerSpec(
          name: name,
          command: rawCommand.trim(),
          args: args,
          env: env,
        ),
      );
    }
    return specs;
  }

  static List<McpServerSpec> _mergeMcpServers({
    required List<McpServerSpec> cliSpecs,
    required List<McpServerSpec> sessionSpecs,
  }) {
    final byName = <String, McpServerSpec>{};
    for (final spec in cliSpecs) {
      byName[spec.name.trim()] = spec;
    }
    for (final spec in sessionSpecs) {
      byName[spec.name.trim()] = spec;
    }
    return byName.values.toList(growable: false);
  }

  _AcpSession _requireSession(Map<String, dynamic> params) {
    final sessionId = params['sessionId'];
    if (sessionId is! String || sessionId.trim().isEmpty) {
      throw const JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Invalid params: sessionId is required.',
      );
    }
    final session = _sessions[sessionId];
    if (session == null) {
      throw JsonRpcException(
        JsonRpcErrorCodes.invalidParams,
        'Unknown sessionId: "$sessionId".',
      );
    }
    return session;
  }

  static String _extractPromptText(List<dynamic> rawPrompt) {
    final parts = <String>[];
    for (final item in rawPrompt) {
      if (item is! Map) {
        continue;
      }
      final block = Map<String, dynamic>.from(item);
      final type = block['type'];
      if (type == 'text') {
        final text = block['text'];
        if (text is String && text.trim().isNotEmpty) {
          parts.add(text);
        }
      } else if (type == 'resource') {
        final rawRes = block['resource'];
        if (rawRes is Map) {
          final text = rawRes['text'];
          final uri = rawRes['uri'];
          if (text is String && text.trim().isNotEmpty) {
            parts.add(uri is String ? '[$uri]\n$text' : text);
          }
        }
      }
    }
    return parts.join('\n').trim();
  }

  String _generateSessionId() {
    final seq = ++_sessionCounter;
    final rand = Random.secure()
        .nextInt(0xFFFF)
        .toRadixString(16)
        .padLeft(4, '0');
    return 'sess_${seq.toString().padLeft(2, '0')}_$rand';
  }
}

class _DeferredAcpObserverHook extends BaseSyscallHook {
  _DeferredAcpObserverHook(this._mapperProvider);

  final AcpEventMapper Function() _mapperProvider;

  @override
  String get name => 'acp_syscall_observer';

  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async {
    if (context.pid == 1 && context.syscallName != 'sys_llm_chat') {
      _mapperProvider().recordBeforeSyscall(context);
    }
    return const HookAllow();
  }

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    if (context.pid == 1 && context.syscallName != 'sys_llm_chat') {
      _mapperProvider().recordAfterSyscall(context, result);
    }
  }
}

class _AcpSession {
  _AcpSession({
    required this.sessionId,
    required this.bootstrap,
    required this.mapper,
    required this.eventSubscription,
    required List<AcpModelOption> initialCatalog,
    required this.modelPolicy,
  }) : _modelOptions = List<AcpModelOption>.from(initialCatalog);

  final String sessionId;
  final KernelBootstrap bootstrap;
  final AcpEventMapper mapper;
  final StreamSubscription<AgentLoopEvent> eventSubscription;
  final ModelPolicy modelPolicy;
  final List<AcpModelOption> _modelOptions;

  String modeId = 'default';
  bool isPromptActive = false;

  void ensureModelInOptions(String canonicalModelId) {
    final parsed = ModelIdentifier.parse(canonicalModelId);
    if (!parsed.ok || modelPolicy.validateModel(parsed.value!) != null) {
      return;
    }
    final exists = _modelOptions.any((opt) => opt.value == canonicalModelId);
    if (!exists) {
      _modelOptions.add(
        AcpModelOption(
          value: canonicalModelId,
          name: canonicalModelId,
          description: 'Custom configured model',
        ),
      );
    }
  }

  List<Map<String, dynamic>> buildConfigOptions() {
    final current = bootstrap.modelResolver.effectiveModelString();
    ensureModelInOptions(current);
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'model',
        'name': 'Model',
        'description': 'Active LLM provider/model for subsequent turns',
        'category': 'model',
        'type': 'select',
        'currentValue': current,
        'options': _modelOptions.map((o) => o.toJson()).toList(growable: false),
      },
    ];
  }

  Future<void> dispose() async {
    await eventSubscription.cancel();
    await bootstrap.dispose();
  }
}
