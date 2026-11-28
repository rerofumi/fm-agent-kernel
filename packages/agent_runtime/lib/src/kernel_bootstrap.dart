import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
// ignore: depend_on_referenced_packages
import 'package:meta/meta.dart';

import 'isolate_worker_host.dart';
import 'process_runner.dart';
import 'process_syscalls.dart';
import 'prompts/agent_prompts.dart';
import 'stacked_task_manager.dart';
import 'sub_agent_worker.dart';

/// Configuration options for [KernelBootstrap.create] ([D-001], [D-022]).
class KernelBootstrapConfig {
  const KernelBootstrapConfig({
    required this.workspaceHostRoot,
    this.sessionId,
    this.sessionUuid,
    this.startupModel,
    this.systemInstruction,
    this.approvalHandler,
    this.hooks = const <SyscallHook>[],
    this.enableAntiGitHabitGuard = true,
    this.llmDrivers,
    this.llmRouter,
    this.envLoader,
    this.redactor,
    this.localOllamaBaseUrl,
    this.ollamaCloudBaseUrl,
    this.openRouterBaseUrl,
    this.openAiBaseUrl,
    this.geminiBaseUrl,
    this.nousPortalBaseUrl,
    this.openAiCompatBaseUrl,
    this.modelPolicy,
    this.execPolicy,
    this.onExecPolicyWarning,
    this.keepAlive = '15m',
    this.requestTimeout = const Duration(seconds: 120),
    this.ioCapConfig = const IoCapConfig(),
    this.quota = ResourceQuota.stage1Default,
    this.maxStepsPerTurn = 64,
    this.jjExecutable = 'jj',
    this.projector = const CanonicalIrProjector(),
    this.extraSyscalls = const <SyscallDefinition>[],
    this.extraToolSchemas = const <SyscallToolSchema>[],
    this.onLlmStreamEvent,
    this.onProcessLlmStreamEvent,
    this.contextWindowSource,
    this.contextWindowConfig = const ContextWindowConfig(),
    this.pagerWatermarkConfig = const PagerWatermarkConfig(),
    this.pageFreshnessChecker,
    this.onPagingReport,
    this.enableStage2Multiprocess = false,
    this.enableStage3Team = false,
    this.maxContextTokens,
    this.dirtySwapBackend,
    this.mcpServers = const <McpServerSpec>[],
    this.mcpServerManager,
    this.stackedTaskManager,
    this.childWorkerBackend,
    this.quotaLedger,
    this.leadCspace,
    this.maxActiveProcesses,
    this.skillsDirs = const <String>[],
    this.skillsDirEnv,
    this.llmHooks = const <LlmHook>[],
    this.txHooks = const <TxHook>[],
    this.webSearchBackend,
    @visibleForTesting this.webFetchTransport,
  });

  final String workspaceHostRoot;
  final String? sessionId;
  final String? sessionUuid;
  final String? startupModel;
  final String? systemInstruction;
  final ApprovalHandler? approvalHandler;
  final List<SyscallHook> hooks;
  final bool enableAntiGitHabitGuard;
  final Map<LlmProviderId, LlmDriver>? llmDrivers;
  final LlmRouter? llmRouter;
  final LlmEnvLoader? envLoader;
  final SecretRedactor? redactor;
  final String? localOllamaBaseUrl;
  final String? ollamaCloudBaseUrl;
  final String? openRouterBaseUrl;
  final String? openAiBaseUrl;
  final String? geminiBaseUrl;
  final String? nousPortalBaseUrl;
  final String? openAiCompatBaseUrl;
  final ModelPolicy? modelPolicy;
  final ExecPolicyConfig? execPolicy;
  final void Function(String message)? onExecPolicyWarning;
  final String keepAlive;
  final Duration requestTimeout;
  final IoCapConfig ioCapConfig;
  final ResourceQuota quota;
  final int maxStepsPerTurn;
  final String jjExecutable;
  final CanonicalIrProjector projector;
  final List<SyscallDefinition> extraSyscalls;
  final List<SyscallToolSchema> extraToolSchemas;
  final LlmStreamObserver? onLlmStreamEvent;
  final LlmPidStreamObserver? onProcessLlmStreamEvent;
  final ContextWindowSource? contextWindowSource;
  final ContextWindowConfig contextWindowConfig;
  final PagerWatermarkConfig pagerWatermarkConfig;
  final PageFreshnessChecker? pageFreshnessChecker;
  final PagingReportObserver? onPagingReport;
  final bool enableStage2Multiprocess;
  final bool enableStage3Team;
  final int? maxContextTokens;
  final DirtySwapBackend? dirtySwapBackend;
  final List<McpServerSpec> mcpServers;
  final McpServerManager? mcpServerManager;
  final StackedTaskManager? stackedTaskManager;
  final ChildWorkerBackend? childWorkerBackend;
  final QuotaLedger? quotaLedger;
  final CapabilityTable? leadCspace;
  final int? maxActiveProcesses;

  /// Repeatable `--skills-dir <path>` directories in priority order ([D-203], [D-219]).
  final List<String> skillsDirs;

  /// Optional override for `AGENT_OS_SKILLS_DIR` environment value ([D-203], [D-219]).
  final String? skillsDirEnv;

  /// Pre/Post LLM hooks invoked in FIFO order around `sys_llm_chat` ([D-203], [D-220]).
  final List<LlmHook> llmHooks;

  /// Stage 3.5 transaction hooks invoked in FIFO order before `sys_tx_squash` approval ([D-202], [D-220]).
  final List<TxHook> txHooks;

  /// Optional custom [WebSearchBackend] (defaults to [OllamaWebSearchBackend], [D-216]).
  final WebSearchBackend? webSearchBackend;

  /// Test-only [WebFetchTransport] DI hook for Layer B injection tests ([D-205]).
  ///
  /// Production callers MUST leave this `null` so [PinnedHttpWebFetchTransport] is always used.
  final WebFetchTransport? webFetchTransport;
}

/// Compile-time assembly wiring Stage 1 kernel, drivers, hooks, and [LeadAgent] ([D-001], [D-022]).
class KernelBootstrap {
  KernelBootstrap._({
    required this.sessionId,
    required this.redactor,
    required this.envLoader,
    required this.namespace,
    required this.processTable,
    required this.pcb,
    required this.capHandle,
    required this.approvalGate,
    required this.ioCapper,
    required this.auditLogger,
    required this.hostFsDriver,
    required this.jjDriver,
    required this.win32JobExecDriver,
    required this.skillRegistry,
    required this.webSearchBackend,
    required this.webFetchDriver,
    required this.llmRouter,
    required this.contextWindowSource,
    required this.pageFreshnessChecker,
    required this.contextPager,
    required this.syscallGate,
    required this.modelResolver,
    required this.leadAgent,
    required this.processRunner,
    required this.quotaLedger,
    required this.modelPolicy,
    required this.execPolicy,
    this.workerHost,
    this.dirtySwapBackend,
    this.mcpServerManager,
    this.stackedTaskManager,
    List<McpServerSpec> initialMcpServers = const <McpServerSpec>[],
    required List<FutureOr<void> Function()> ownedClosers,
  })  : _initialMcpServers = initialMcpServers,
        _ownedClosers = ownedClosers;

  /// Default immutable Segment 0 instruction for Stage 1 Step 1-1/1-2 execution ([D-007]).
  static const String defaultStep1Instruction =
      AgentPrompts.leadStep1Instruction;

  /// Default immutable Segment 0 instruction for Stage 2 multi-process execution ([D-007], [D-211], [D-218], [D-219]).
  static const String defaultStage2Instruction =
      AgentPrompts.leadStage2Instruction;

  /// Default immutable Segment 0 instruction for Stage 3 team, signal, dirty-swap, MCP, and stacked-task execution ([D-301], [D-311], [D-312], [D-319]).
  static const String defaultStage3Instruction =
      AgentPrompts.leadStage3Instruction;

  final String sessionId;
  final SecretRedactor redactor;
  final LlmEnvLoader envLoader;
  final VfsNamespace namespace;
  final KernelProcessTable processTable;
  final ProcessControlBlock pcb;
  final CapHandle capHandle;
  final ApprovalGate approvalGate;
  final IoPayloadCapper ioCapper;
  final AuditLogger auditLogger;
  final HostFsDriver hostFsDriver;
  final JjDriver jjDriver;
  final Win32JobExecDriver win32JobExecDriver;
  final SkillRegistry skillRegistry;
  final WebSearchBackend webSearchBackend;
  final WebFetchDriver webFetchDriver;
  final LlmRouter llmRouter;
  final ContextWindowSource contextWindowSource;
  final PageFreshnessChecker pageFreshnessChecker;
  final ContextPager contextPager;
  final SyscallGate syscallGate;
  final ModelResolver modelResolver;
  final LeadAgent leadAgent;
  final GreenTaskProcessRunner processRunner;
  final QuotaLedger quotaLedger;
  final ModelPolicy modelPolicy;
  final ExecPolicyConfig execPolicy;
  final IsolateWorkerHost? workerHost;
  final DirtySwapBackend? dirtySwapBackend;
  final McpServerManager? mcpServerManager;
  final StackedTaskManager? stackedTaskManager;
  final List<McpServerSpec> _initialMcpServers;
  final List<FutureOr<void> Function()> _ownedClosers;

  ContextPagingReport? _lastPagingReport;

  /// Latest [ContextPagingReport] emitted for `pid == 1` (`LeadAgent`), if any.
  ContextPagingReport? get lastPagingReport => _lastPagingReport;

  bool _disposed = false;

  /// Canonical host path mapped to `/workspace`.
  String get workspaceHostRoot => namespace.workspaceHostRoot!;

  /// Resolved `/api/chat` endpoint for `local-ollama` when an [OllamaDriver] is registered.
  Uri? get localOllamaEndpoint {
    final driver = llmRouter.driverFor(LlmProviderId.localOllama);
    return driver is OllamaDriver ? driver.resolveEndpoint() : null;
  }

  /// Creates and wires a complete Stage 1 Step 1-1 runtime from [config].
  factory KernelBootstrap.create(KernelBootstrapConfig config) {
    final effectiveSessionId =
        _normalizeNonEmpty(config.sessionId) ?? _generateSessionId();

    final effectiveRedactor = config.redactor ??
        config.envLoader?.redactor ??
        SecretRedactor();
    effectiveRedactor.registerFromEnvironment(Platform.environment);
    for (final mcpSpec in config.mcpServers) {
      for (final envVar in mcpSpec.env) {
        effectiveRedactor.registerSecret(envVar.value);
      }
    }

    // Load external SKILL.md manifests at startup in [D-203] §3.1(3) priority order ([D-219]).
    final skillLoader = SkillDirectoryLoader(
      onWarning: (msg) => stderr.writeln('[agent_os_skills] $msg'),
    );
    final skillRegistry = skillLoader.load(
      cliSkillsDirs: config.skillsDirs,
      envSkillsDir: config.skillsDirEnv,
      workspaceHostRoot: config.workspaceHostRoot,
    );

    final namespace = VfsNamespace(
      workspaceHostRoot: config.workspaceHostRoot,
      skillsMount: skillRegistry,
    );

    // Initialize AuditLogger early so `.agent_os/.gitignore` exists before any `jj` command ([D-003]).
    final auditLogger = AuditLogger(
      workspaceHostRoot: namespace.workspaceHostRoot!,
      sessionId: effectiveSessionId,
      redactor: effectiveRedactor,
    );

    final effectiveEnvLoader = config.envLoader ??
        LlmEnvLoader(
          sessionCwd: namespace.workspaceHostRoot,
          redactor: effectiveRedactor,
        );

    final ExecPolicyConfig effectiveExecPolicy;
    if (config.execPolicy != null) {
      effectiveExecPolicy = config.execPolicy!;
    } else {
      final execPolicyLoadResult = ExecPolicyConfigLoader(
        sessionCwd: namespace.workspaceHostRoot,
      ).load();
      final warnSink = config.onExecPolicyWarning ??
          ((String msg) => stderr.writeln('[exec_policy] $msg'));
      for (final warning in execPolicyLoadResult.warnings) {
        warnSink(effectiveRedactor.redactString(warning));
      }
      effectiveExecPolicy = execPolicyLoadResult.config;
    }
    final execRuleSummaries = effectiveExecPolicy.toPromptRuleSummaries();
    final subprocessApprovalProfiles =
        effectiveExecPolicy.subprocessApprovalProfiles;
    final subprocessApprovalProfileNames = subprocessApprovalProfiles
        .map((profile) => profile.wireValue)
        .toList(growable: false)
      ..sort();

    final ioCapper = IoPayloadCapper(
      config: config.ioCapConfig,
      workspaceHostRoot: namespace.workspaceHostRoot,
    );

    final approvalGate = ApprovalGate(
      handler: config.approvalHandler ?? PolicyApprovalHandler.alwaysAllow(),
    );

    final isStage3Team = config.enableStage3Team;
    final isStage2Multiprocess = config.enableStage2Multiprocess ||
        isStage3Team ||
        config.quota.maxChildProcesses > 0;
    final effectiveQuota = (isStage2Multiprocess &&
            config.quota.maxChildProcesses == 0)
        ? ResourceQuota.stage2Default
        : config.quota;
    final effectiveQuotaLedger = config.quotaLedger ?? QuotaLedger();

    final McpServerManager? effectiveMcpManager = config.mcpServerManager ??
        ((isStage3Team || config.mcpServers.isNotEmpty)
            ? McpServerManager(
                workspaceHostRoot: namespace.workspaceHostRoot!,
                redactor: effectiveRedactor,
              )
            : null);

    final DirtySwapBackend? effectiveDirtySwapBackend =
        config.dirtySwapBackend ??
            (isStage3Team
                ? JsonlDirtySwapStore(
                    workspaceHostRoot: namespace.workspaceHostRoot!,
                    redactor: effectiveRedactor,
                  )
                : null);

    final jjSchemas = isStage2Multiprocess
        ? JjDriver.allToolSchemas()
        : JjDriver.allToolSchemas()
            .where(
              (s) =>
                  s.name != 'sys_jj_merge' &&
                  s.name != 'sys_jj_conflicts' &&
                  s.name != 'sys_jj_integrate',
            )
            .toList(growable: false);

    final allToolSchemas = <SyscallToolSchema>[
      ...HostFsDriver.allToolSchemas(),
      ...jjSchemas,
      ...Win32JobExecDriver.toolSchemas(policy: effectiveExecPolicy),
      buildMemPageinToolSchema(),
      if (isStage2Multiprocess) ...buildProcessToolSchemas(),
      if (isStage2Multiprocess) buildWebSearchToolSchema(),
      if (isStage2Multiprocess) buildWebFetchToolSchema(),
      if (isStage3Team || effectiveMcpManager != null) ...buildMcpToolSchemas(),
      if (isStage3Team || config.stackedTaskManager != null)
        StackedTaskManager.buildToolSchema(),
      if (skillRegistry.isNotEmpty) ...SkillSyscallDriver.toolSchemas(),
      ...config.extraToolSchemas,
    ];

    const defaultCapHandle = CapHandle('cap_workspace_rw');
    final CapabilityTable baseCspace;
    if (config.leadCspace != null) {
      baseCspace = config.leadCspace!;
    } else if (isStage3Team) {
      baseCspace = CapabilityTable.stage3LeadAgent(
        workspaceHandle: defaultCapHandle,
      );
    } else if (isStage2Multiprocess) {
      baseCspace = CapabilityTable.stage2LeadAgent(
        workspaceHandle: defaultCapHandle,
      );
    } else {
      baseCspace = CapabilityTable.stage1LeadAgent(handle: defaultCapHandle);
      final baseEntry = baseCspace.lookup(defaultCapHandle)!;
      baseCspace.grant(
        CapabilityEntry(
          handle: defaultCapHandle,
          resourceScope: baseEntry.resourceScope,
          rights: <CapRight>{
            ...baseEntry.rights,
            CapRight.memManage,
          },
        ),
      );
    }

    final jjContext = JjTxContext();
    final tempPcbForFilter = ProcessControlBlock(
      pid: 1,
      name: 'lead-agent',
      ring: ProtectionRing.ring2,
      cspace: baseCspace,
      quota: effectiveQuota,
      namespace: namespace,
      jjContext: jjContext,
      memory: VirtualContextMemory(
        sessionId: effectiveSessionId,
        systemInstruction: PinnedSystemInstruction(
          instruction: '',
          tools: const <SyscallToolSchema>[],
        ),
      ),
    );
    final leadToolSchemas = isStage2Multiprocess
        ? filterToolSchemasForPcb(
            pcb: tempPcbForFilter,
            allSchemas: allToolSchemas,
          )
        : allToolSchemas;

    final pinnedSystem = PinnedSystemInstruction(
      instruction: config.systemInstruction ??
          AgentPrompts.buildLeadInstruction(
            stage: isStage3Team ? 3 : (isStage2Multiprocess ? 2 : 1),
            additionalExecRuleSummaries: execRuleSummaries,
            subprocessApprovalProfileNames: subprocessApprovalProfileNames,
          ),
      tools: leadToolSchemas,
    );

    final pcb = ProcessControlBlock(
      pid: 1,
      name: 'lead-agent',
      ring: ProtectionRing.ring2,
      cspace: baseCspace,
      quota: effectiveQuota,
      namespace: namespace,
      jjContext: jjContext,
      memory: VirtualContextMemory(
        sessionId: effectiveSessionId,
        systemInstruction: pinnedSystem,
      ),
    );

    final processTable = isStage2Multiprocess
        ? KernelProcessTable.stage2(
            maxActiveProcesses: config.maxActiveProcesses ??
                KernelProcessTable.stage2DefaultMaxActiveProcesses,
          )
        : KernelProcessTable();
    final registerRes = processTable.registerProcess(pcb);
    if (!registerRes.ok) {
      throw StateError(
        'Failed to register LeadAgent PCB: ${registerRes.error}',
      );
    }

    final jjDriver = JjDriver(
      namespace: namespace,
      txContext: jjContext,
      jjExecutable: config.jjExecutable,
    );
    final hostFsDriver = HostFsDriver(
      namespace: namespace,
      ensureActiveTransaction: jjDriver.ensureActiveTransaction,
      syncWorkingCopySnapshot: jjDriver.syncWorkingCopySnapshot,
      currentCommitIdProvider: jjDriver.getCurrentCommitIdNonDestructive,
      ensureActiveTransactionForPcb: jjDriver.ensureActiveTransactionForPcb,
      syncWorkingCopySnapshotForPcb: jjDriver.syncWorkingCopySnapshotForPcb,
      currentCommitIdForPcbProvider: jjDriver.getCurrentCommitIdForPcb,
    );
    final win32JobExecDriver = Win32JobExecDriver(
      namespace: namespace,
      ensureActiveTransaction: jjDriver.ensureActiveTransaction,
      syncWorkingCopySnapshot: jjDriver.syncWorkingCopySnapshot,
      ensureActiveTransactionForPcb: jjDriver.ensureActiveTransactionForPcb,
      syncWorkingCopySnapshotForPcb: jjDriver.syncWorkingCopySnapshotForPcb,
      ioCapper: ioCapper,
      classifier: SysExecClassifier(
        namespace: namespace,
        policy: effectiveExecPolicy,
      ),
    );

    final effectiveModelPolicy = config.modelPolicy ??
        ModelPolicy.fromEnvironment(
          envLoader: effectiveEnvLoader,
          sessionCwd: namespace.workspaceHostRoot,
          explicitOpenAiCompatBaseUrl: config.openAiCompatBaseUrl,
        );
    final resolvedOpenAiCompatBaseUrl =
        _normalizeNonEmpty(config.openAiCompatBaseUrl) ??
            effectiveModelPolicy.resolveOpenAiCompatBaseUrl();

    final ownedClosers = <FutureOr<void> Function()>[];
    final LlmRouter effectiveRouter;
    if (config.llmRouter != null) {
      effectiveRouter = config.llmRouter!;
    } else {
      final drivers = <LlmProviderId, LlmDriver>{};

      void registerDefaultDriver(
        LlmProviderId id,
        LlmDriver Function() buildDefault,
      ) {
        final injected = config.llmDrivers?[id];
        if (injected != null) {
          drivers[id] = injected;
          return;
        }
        final created = buildDefault();
        drivers[id] = created;
        if (created is OllamaDriver) {
          ownedClosers.add(created.close);
        } else if (created is OpenAiCompatDriver) {
          ownedClosers.add(created.close);
        } else if (created is GeminiDriver) {
          ownedClosers.add(created.dispose);
        }
      }

      registerDefaultDriver(
        LlmProviderId.localOllama,
        () => OllamaDriver.local(
          baseUrl: config.localOllamaBaseUrl,
          envLoader: effectiveEnvLoader,
          redactor: effectiveRedactor,
          keepAlive: config.keepAlive,
          requestTimeout: config.requestTimeout,
        ),
      );
      registerDefaultDriver(
        LlmProviderId.ollamaCloud,
        () => OllamaDriver.cloud(
          baseUrl: config.ollamaCloudBaseUrl,
          envLoader: effectiveEnvLoader,
          redactor: effectiveRedactor,
          keepAlive: config.keepAlive,
          requestTimeout: config.requestTimeout,
        ),
      );
      registerDefaultDriver(
        LlmProviderId.openRouter,
        () => OpenRouterDriver(
          baseUrl: config.openRouterBaseUrl,
          envLoader: effectiveEnvLoader,
          redactor: effectiveRedactor,
          requestTimeout: config.requestTimeout,
        ),
      );
      registerDefaultDriver(
        LlmProviderId.openai,
        () => OpenAiDriver(
          baseUrl: config.openAiBaseUrl,
          envLoader: effectiveEnvLoader,
          redactor: effectiveRedactor,
          requestTimeout: config.requestTimeout,
        ),
      );
      registerDefaultDriver(
        LlmProviderId.gemini,
        () => GeminiDriver(
          baseUrl: config.geminiBaseUrl,
          envLoader: effectiveEnvLoader,
          redactor: effectiveRedactor,
          requestTimeout: config.requestTimeout,
        ),
      );
      registerDefaultDriver(
        LlmProviderId.nousPortal,
        () => NousPortalDriver(
          baseUrl: config.nousPortalBaseUrl,
          envLoader: effectiveEnvLoader,
          redactor: effectiveRedactor,
          requestTimeout: config.requestTimeout,
        ),
      );
      registerDefaultDriver(
        LlmProviderId.openaiCompat,
        () => LocalOpenAiCompatDriver(
          baseUrl: resolvedOpenAiCompatBaseUrl,
          envLoader: effectiveEnvLoader,
          redactor: effectiveRedactor,
          requestTimeout: config.requestTimeout,
        ),
      );

      effectiveRouter = LlmRouter(drivers: drivers);
    }

    final effectiveHooks = <SyscallHook>[
      if (config.enableAntiGitHabitGuard &&
          !config.hooks.any((h) => h is AntiGitHabitGuardHook))
        AntiGitHabitGuardHook(),
      ...config.hooks,
    ];

    final syscallGate = SyscallGate(
      processTable: processTable,
      approvalGate: approvalGate,
      ioCapper: ioCapper,
      auditLogger: auditLogger,
      redactor: effectiveRedactor,
      hooks: effectiveHooks,
      txHooks: config.txHooks,
      jjAuditInfoProvider: jjDriver.getAuditInfo,
      jjProcessAuditInfoProvider: jjDriver.getAuditInfoForProcess,
    );

    final modelResolver = ModelResolver(
      startupModel: config.startupModel,
      modelValidator: config.modelPolicy?.validateModel,
    );

    late final LeadAgent leadAgent;
    IsolateWorkerHost? workerHost;
    if (isStage2Multiprocess) {
      workerHost = IsolateWorkerHost(
        processTable: processTable,
        syscallGate: syscallGate,
        quotaLedger: effectiveQuotaLedger,
        toolSchemaProvider: (childPcb) => filterToolSchemasForPcb(
          pcb: childPcb,
          allSchemas: allToolSchemas,
        ),
        parentCurrentModelProvider: () =>
            leadAgent.activeTurnModel?.canonicalId ??
            modelResolver.effectiveModelString(),
        jjDriver: jjDriver,
        backend: config.childWorkerBackend ?? const IsolateChildWorkerBackend(),
        additionalExecRuleSummaries: execRuleSummaries,
        subprocessApprovalProfiles: subprocessApprovalProfiles,
      );
    }

    leadAgent = LeadAgent(
      pcb: pcb,
      syscallGate: syscallGate,
      capHandle: defaultCapHandle,
      modelResolver: modelResolver,
      sessionUuid: config.sessionUuid,
      maxStepsPerTurn: config.maxStepsPerTurn,
      onTurnExitCleanup: workerHost == null
          ? null
          : () => workerHost!.terminateActiveChildrenForParent(pcb.pid),
    );

    final effectiveWindowConfig = config.maxContextTokens != null
        ? ContextWindowConfig(
            modelOverrides: config.contextWindowConfig.modelOverrides,
            maxContextTokens: config.maxContextTokens,
            defaultLocalUnloadedCap:
                config.contextWindowConfig.defaultLocalUnloadedCap,
            defaultLocalFallback:
                config.contextWindowConfig.defaultLocalFallback,
            defaultCloudFallback:
                config.contextWindowConfig.defaultCloudFallback,
            defaultOpenRouterFallback:
                config.contextWindowConfig.defaultOpenRouterFallback,
            localProbeTimeout: config.contextWindowConfig.localProbeTimeout,
            remoteProbeTimeout: config.contextWindowConfig.remoteProbeTimeout,
          )
        : config.contextWindowConfig;

    if (config.maxContextTokens != null) {
      final tokenErr = ContextPager.validateMaxContextTokens(
        maxContextTokens: config.maxContextTokens,
        systemInstruction: pinnedSystem,
      );
      if (tokenErr != null) {
        throw ArgumentError.value(
          config.maxContextTokens,
          'maxContextTokens',
          '${tokenErr.reason}: ${tokenErr.message}',
        );
      }
    }

    final ContextWindowSource effectiveWindowSource;
    if (config.contextWindowSource != null) {
      effectiveWindowSource = config.contextWindowSource!;
    } else {
      final resolver = ContextWindowResolver(
        config: effectiveWindowConfig,
        localOllamaBaseUrl: config.localOllamaBaseUrl,
        ollamaCloudBaseUrl: config.ollamaCloudBaseUrl,
        openRouterBaseUrl: config.openRouterBaseUrl,
        openAiBaseUrl: config.openAiBaseUrl,
        geminiBaseUrl: config.geminiBaseUrl,
        nousPortalBaseUrl: config.nousPortalBaseUrl,
        openAiCompatBaseUrl: resolvedOpenAiCompatBaseUrl,
        envLoader: effectiveEnvLoader,
        redactor: effectiveRedactor,
      );
      ownedClosers.add(resolver.close);
      effectiveWindowSource = resolver;
    }

    final effectiveFreshnessChecker = config.pageFreshnessChecker ??
        WorkspacePageFreshnessChecker(
          namespace: namespace,
          jjDriver: jjDriver,
          jjExecutable: config.jjExecutable,
        );

    final effectiveContextPager = ContextPager(
      config: config.pagerWatermarkConfig,
      dirtySwapBackend: effectiveDirtySwapBackend,
    );

    final StackedTaskManager? effectiveStackedManager =
        config.stackedTaskManager ??
            (isStage3Team ? StackedTaskManager(jjDriver: jjDriver) : null);

    final WebSearchBackend effectiveWebSearchBackend;
    if (config.webSearchBackend != null) {
      effectiveWebSearchBackend = config.webSearchBackend!;
    } else {
      final ollamaSearch = OllamaWebSearchBackend(
        envLoader: effectiveEnvLoader,
        redactor: effectiveRedactor,
      );
      ownedClosers.add(ollamaSearch.close);
      effectiveWebSearchBackend = ollamaSearch;
    }

    final webFetchDriver = WebFetchDriver(
      // ignore: invalid_use_of_visible_for_testing_member
      transport: config.webFetchTransport,
    );
    const skillSyscallDriver = SkillSyscallDriver();

    // Register Step 1-1, Step 1-2, Step 2-1, Step 2-2, and Step 2-3 syscalls.
    hostFsDriver.registerAllSyscalls(syscallGate);
    jjDriver.registerAllSyscalls(syscallGate);
    win32JobExecDriver.registerSyscalls(syscallGate);
    skillSyscallDriver.registerSyscalls(syscallGate);
    syscallGate.registerSyscall(
      buildWebSearchSyscallDefinition(backend: effectiveWebSearchBackend),
    );
    syscallGate.registerSyscall(
      buildWebFetchSyscallDefinition(driver: webFetchDriver),
    );
    syscallGate.registerSyscall(
      buildMemPageinSyscallDefinition(
        hostFsDriver: hostFsDriver,
        jjDriver: jjDriver,
        freshnessChecker: effectiveFreshnessChecker,
        dirtySwapBackend: effectiveDirtySwapBackend,
        redactor: effectiveRedactor,
      ),
    );
    if (effectiveMcpManager != null) {
      for (final def in buildMcpSyscallDefinitions(
        manager: effectiveMcpManager,
        redactor: effectiveRedactor,
      )) {
        syscallGate.registerSyscall(def);
      }
    }
    if (effectiveStackedManager != null) {
      syscallGate.registerSyscall(
        effectiveStackedManager.buildSyscallDefinition(),
      );
    }
    if (workerHost != null) {
      for (final def in buildProcessSyscallDefinitions(
        host: workerHost,
        processTable: processTable,
      )) {
        syscallGate.registerSyscall(def);
      }
    }

    late final KernelBootstrap bootstrap;
    syscallGate.registerSyscall(
      buildLlmChatSyscallDefinition(
        router: effectiveRouter,
        auditLogger: auditLogger,
        projector: config.projector,
        contextWindowSource: effectiveWindowSource,
        freshnessChecker: effectiveFreshnessChecker,
        contextPager: effectiveContextPager,
        llmHooks: config.llmHooks,
        onPagingReport: (report, {Pid pid = 1}) {
          if (pid == 1) {
            bootstrap._lastPagingReport = report;
          }
          config.onPagingReport?.call(report, pid: pid);
        },
        onProcessStreamEvent: (sid, turnIndex, event, {Pid pid = 1}) {
          config.onProcessLlmStreamEvent?.call(sid, turnIndex, event, pid: pid);
          if (pid == 1) {
            leadAgent.forwardLlmStreamEvent(turnIndex, event);
            config.onLlmStreamEvent?.call(sid, turnIndex, event);
          }
        },
      ),
    );

    for (final extra in config.extraSyscalls) {
      syscallGate.registerSyscall(extra);
    }

    final processRunner = GreenTaskProcessRunner(
      leadAgent: leadAgent,
      onKillTree: workerHost == null
          ? null
          : (reason) => workerHost!.killProcessTree(1, reason: reason),
    );

    bootstrap = KernelBootstrap._(
      sessionId: effectiveSessionId,
      redactor: effectiveRedactor,
      envLoader: effectiveEnvLoader,
      namespace: namespace,
      processTable: processTable,
      pcb: pcb,
      capHandle: defaultCapHandle,
      approvalGate: approvalGate,
      ioCapper: ioCapper,
      auditLogger: auditLogger,
      hostFsDriver: hostFsDriver,
      jjDriver: jjDriver,
      win32JobExecDriver: win32JobExecDriver,
      skillRegistry: skillRegistry,
      webSearchBackend: effectiveWebSearchBackend,
      webFetchDriver: webFetchDriver,
      llmRouter: effectiveRouter,
      contextWindowSource: effectiveWindowSource,
      pageFreshnessChecker: effectiveFreshnessChecker,
      contextPager: effectiveContextPager,
      syscallGate: syscallGate,
      modelResolver: modelResolver,
      leadAgent: leadAgent,
      processRunner: processRunner,
      quotaLedger: effectiveQuotaLedger,
      modelPolicy: effectiveModelPolicy,
      execPolicy: effectiveExecPolicy,
      workerHost: workerHost,
      dirtySwapBackend: effectiveDirtySwapBackend,
      mcpServerManager: effectiveMcpManager,
      stackedTaskManager: effectiveStackedManager,
      initialMcpServers: config.mcpServers,
      ownedClosers: ownedClosers,
    );
    return bootstrap;
  }

  /// Connects configured or supplied `stdio` MCP servers ([D-318], [D-320]).
  Future<SyscallResult<void>> connectMcpServers([
    List<McpServerSpec>? specs,
  ]) async {
    final manager = mcpServerManager;
    final targetSpecs = specs ?? _initialMcpServers;
    if (manager == null || targetSpecs.isEmpty) {
      return const SyscallResult<void>.success(null);
    }
    return manager.registerAndConnectAll(targetSpecs);
  }

  /// Renders a lightweight Segment 2 dynamic context summary (e.g., connected MCP servers) ([D-319]).
  String renderDynamicContextSummary() {
    return mcpServerManager?.renderDynamicContextSummary() ?? '';
  }

  /// Registers a Stage 3/6 hook on [syscallGate] ([D-220]).
  void addHook(SyscallHook hook) => syscallGate.addHook(hook);

  /// Registers a Stage 3.5 `sys_tx_squash` hook on [syscallGate] ([D-220]).
  void addTxHook(TxHook hook) => syscallGate.addTxHook(hook);

  /// Registers an additional syscall definition on [syscallGate].
  void registerSyscall(SyscallDefinition definition) =>
      syscallGate.registerSyscall(definition);

  /// Flushes audit logs, disposes the process runner, terminates active children, and closes owned HTTP clients.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await processRunner.dispose();
    await workerHost?.dispose();
    await stackedTaskManager?.dispose();
    await mcpServerManager?.dispose();
    await auditLogger.flush();
    for (final closer in _ownedClosers) {
      try {
        await closer();
      } catch (_) {
        // Best-effort resource cleanup on shutdown.
      }
    }
  }

  static String? _normalizeNonEmpty(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _generateSessionId() {
    final now = DateTime.now().toUtc();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    final rand = Random.secure()
        .nextInt(0xFFFF)
        .toRadixString(16)
        .padLeft(4, '0');
    return 's_$y$m${d}_$hh$mm${ss}_$rand';
  }
}
