import 'dart:async';
import 'dart:io';
import 'dart:math';

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

/// Configuration options for [AcpServer] ([D-018], [D-022]).
class AcpServerConfig {
  const AcpServerConfig({
    this.startupModel,
    this.systemInstruction,
    this.localOllamaBaseUrl,
    this.ollamaCloudBaseUrl,
    this.openRouterBaseUrl,
    this.maxStepsPerTurn = 32,
    this.jjExecutable = 'jj',
    this.bootstrapFactory,
  });

  final String? startupModel;
  final String? systemInstruction;
  final String? localOllamaBaseUrl;
  final String? ollamaCloudBaseUrl;
  final String? openRouterBaseUrl;
  final int maxStepsPerTurn;
  final String jjExecutable;
  final AcpBootstrapFactory? bootstrapFactory;
}

/// ACP v1 JSON-RPC 2.0 `stdio` server hosting `KernelBootstrap` sessions ([D-018]..[D-020]).
class AcpServer {
  AcpServer({
    required JsonRpcPeer peer,
    this.config = const AcpServerConfig(),
  }) : _peer = peer {
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
      maxStepsPerTurn: config.maxStepsPerTurn,
      jjExecutable: config.jjExecutable,
      onLlmStreamEvent: (sid, turnIndex, event) {
        mapper.onLlmStreamEvent(sid, turnIndex, event);
      },
    );

    bootstrap = config.bootstrapFactory != null
        ? config.bootstrapFactory!(bootstrapConfig)
        : KernelBootstrap.create(bootstrapConfig);

    mapper = AcpEventMapper(
      sessionId: sessionId,
      peer: _peer,
      namespace: bootstrap.namespace,
      jjContext: bootstrap.pcb.jjContext,
      redactor: bootstrap.redactor,
      contextWindowSize: bootstrap.pcb.quota.maxTotalTokens ?? 32768,
    );

    final eventSubscription =
        bootstrap.processRunner.events.listen(mapper.onAgentLoopEvent);

    final session = _AcpSession(
      sessionId: sessionId,
      bootstrap: bootstrap,
      mapper: mapper,
      eventSubscription: eventSubscription,
      initialCatalog: defaultModelCatalog,
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
        modelOverride = check.value!.canonicalId;
      }
    }

    session.isPromptActive = true;
    final AgentTurnResult result;
    try {
      result = await session.bootstrap.processRunner.submitPrompt(
        userInput: userInput,
        modelOverride: modelOverride,
      );
    } finally {
      session.isPromptActive = false;
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
    };
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
    if (context.syscallName != 'sys_llm_chat') {
      _mapperProvider().recordBeforeSyscall(context);
    }
    return const HookAllow();
  }

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    if (context.syscallName != 'sys_llm_chat') {
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
  }) : _modelOptions = List<AcpModelOption>.from(initialCatalog);

  final String sessionId;
  final KernelBootstrap bootstrap;
  final AcpEventMapper mapper;
  final StreamSubscription<AgentLoopEvent> eventSubscription;
  final List<AcpModelOption> _modelOptions;

  String modeId = 'default';
  bool isPromptActive = false;

  void ensureModelInOptions(String canonicalModelId) {
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
