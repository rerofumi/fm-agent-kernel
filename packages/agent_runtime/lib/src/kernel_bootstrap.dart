import 'dart:io';
import 'dart:math';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
// ignore: depend_on_referenced_packages
import 'package:meta/meta.dart';

import 'isolate_worker_host.dart';
import 'process_runner.dart';
import 'process_syscalls.dart';
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
    this.keepAlive = '15m',
    this.requestTimeout = const Duration(seconds: 120),
    this.ioCapConfig = const IoCapConfig(),
    this.quota = ResourceQuota.stage1Default,
    this.maxStepsPerTurn = 32,
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
    this.workerHost,
    required List<void Function()> ownedClosers,
  }) : _ownedClosers = ownedClosers;

  /// Default immutable Segment 0 instruction for Stage 1 Step 1-1/1-2 execution ([D-007]).
  static const String defaultStep1Instruction = '''
You are the LeadAgent running inside FM Agent OS (Stage 1).
All file and repository paths inside tool calls MUST use the virtual root `/workspace` (never host OS paths like `C:\\...`).
Your workspace is managed by Jujutsu (`jj`), where `@` is the current working-copy change and `@-` is its parent change.

Available Read-Only exploration syscalls:
- `sys_glob`: Find files matching a glob pattern under `/workspace`.
- `sys_grep`: Search UTF-8 text files under `/workspace` for strings or regexes.
- `sys_read_lines`: Read a 1-based line range from a file under `/workspace` (returns `content`, `sha256`, `totalLines`).
- `sys_jj_status`: Inspect `@`, `@-`, changed files summary, and current `opId`.
- `sys_jj_log`: List Jujutsu commits matching a revset.
- `sys_jj_diff`: Inspect unified Git-format diff for a revision.

Available CoW transaction, CAS editing, and isolated execution syscalls:
- `sys_edit_block`: Replace a unique `oldBlock` in an existing file after verifying `expectedSha256` from `sys_read_lines`.
- `sys_write_file`: Create a new file (`expectedSha256` omitted) or overwrite an existing file with `expectedSha256`.
- `sys_tx_begin` / `sys_tx_describe` / `sys_tx_squash` / `sys_tx_rollback`: Manage isolated `@` CoW transactions (leaving `@-` untouched).
- `sys_exec`: Execute an external command inside a Win32 Job Object within `/workspace` (safe `dart test` / `dart analyze` / `dart format --output=none` run directly; other commands require user approval).

Rules:
1. Always inspect the actual files and `jj` history via syscalls before answering or editing; never invent file contents, paths, hashes, or commit history.
2. Before modifying an existing file with `sys_edit_block` or `sys_write_file`, read it with `sys_read_lines` to obtain its current `sha256`.
3. Never invoke raw `git` or `jj` CLI commands via `sys_exec` (blocked by kernel policy); always use `sys_jj_*` and `sys_tx_*` syscalls instead.
4. If a syscall output is truncated by the Kernel I/O Cap (`truncated: true`), use `totalLines` / `omittedLines` and call `sys_read_lines(path, startLine, endLine)` or narrow `sys_grep` patterns to inspect the needed sections.
5. Protected internal paths (`.jj`, `.git`, `.agent_os`, `.env*`) are denied by the kernel and must not be read or written.
6. Keep answers concise, accurate, and grounded in observed tool outputs.
''';

  /// Default immutable Segment 0 instruction for Stage 2 multi-process execution ([D-007], [D-211], [D-218], [D-219]).
  static const String defaultStage2Instruction = '''
$defaultStep1Instruction
Available Stage 2 virtual memory, multi-process, and skill syscalls:
- `sys_mem_pagein`: Reload an evicted Clean Page by `pageId` from Segment 2's Page Directory Summary.
- `sys_spawn`: Spawn sandboxed Ring 3 child Isolate workers (`explorer` for parallel read-only workspace inspection, `web_researcher` for sterile external web research).
- `sys_wait`: Wait for spawned child processes and receive only their concise exit summaries (keeping raw file contents and raw web HTML out of your context).
- `sys_send` / `sys_recv`: Exchange bounded structured IPC messages between parent and own children.
- `sys_skill_list` / `sys_skill_read` (when `/skills` has mounted skills): Discover and read external read-only `SKILL.md` guides on demand.

Multi-process and isolation rules:
7. When asked to investigate multiple packages or directories in parallel, spawn `explorer` children with `sys_spawn` (optionally narrowing `allowedSubpaths`) and collect their concise conclusions with `sys_wait`.
8. Child processes are strictly Read-Only (or zero-workspace) and cannot request user approval; perform any edits, commits, or command executions yourself after reviewing child findings.
9. Workspace ⊕ Net isolation: You hold `/workspace` access and CANNOT invoke `sys_web_search` or `sys_web_fetch` directly. Whenever external web search or URL documentation lookup is required, delegate to a sterile `web_researcher` child via `sys_spawn(profile: "web_researcher", taskPrompt: "...", model: "<optional provider/model>")` and collect its concise summary and source URLs via `sys_wait`.
''';

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
  final IsolateWorkerHost? workerHost;
  final List<void Function()> _ownedClosers;

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

    final ioCapper = IoPayloadCapper(
      config: config.ioCapConfig,
      workspaceHostRoot: namespace.workspaceHostRoot,
    );

    final approvalGate = ApprovalGate(
      handler: config.approvalHandler ?? PolicyApprovalHandler.alwaysAllow(),
    );

    final isStage2Multiprocess =
        config.enableStage2Multiprocess || config.quota.maxChildProcesses > 0;
    final effectiveQuota = (isStage2Multiprocess &&
            config.quota.maxChildProcesses == 0)
        ? ResourceQuota.stage2Default
        : config.quota;
    final effectiveQuotaLedger = config.quotaLedger ?? QuotaLedger();

    final allToolSchemas = <SyscallToolSchema>[
      ...HostFsDriver.allToolSchemas(),
      ...JjDriver.allToolSchemas(),
      ...Win32JobExecDriver.toolSchemas(),
      buildMemPageinToolSchema(),
      if (isStage2Multiprocess) ...buildProcessToolSchemas(),
      if (isStage2Multiprocess) buildWebSearchToolSchema(),
      if (isStage2Multiprocess) buildWebFetchToolSchema(),
      if (skillRegistry.isNotEmpty) ...SkillSyscallDriver.toolSchemas(),
      ...config.extraToolSchemas,
    ];

    const defaultCapHandle = CapHandle('cap_workspace_rw');
    final CapabilityTable baseCspace;
    if (config.leadCspace != null) {
      baseCspace = config.leadCspace!;
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
        systemInstruction: PinnedSystemInstruction(
          instruction: config.systemInstruction ??
              (isStage2Multiprocess
                  ? defaultStage2Instruction
                  : defaultStep1Instruction),
          tools: leadToolSchemas,
        ),
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
    );
    final win32JobExecDriver = Win32JobExecDriver(
      namespace: namespace,
      ensureActiveTransaction: jjDriver.ensureActiveTransaction,
      syncWorkingCopySnapshot: jjDriver.syncWorkingCopySnapshot,
      ioCapper: ioCapper,
    );

    final ownedClosers = <void Function()>[];
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
        } else if (created is OpenRouterDriver) {
          ownedClosers.add(created.close);
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
    );

    final modelResolver = ModelResolver(
      startupModel: config.startupModel,
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
        backend: config.childWorkerBackend ?? const IsolateChildWorkerBackend(),
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

    final ContextWindowSource effectiveWindowSource;
    if (config.contextWindowSource != null) {
      effectiveWindowSource = config.contextWindowSource!;
    } else {
      final resolver = ContextWindowResolver(
        config: config.contextWindowConfig,
        localOllamaBaseUrl: config.localOllamaBaseUrl,
        ollamaCloudBaseUrl: config.ollamaCloudBaseUrl,
        openRouterBaseUrl: config.openRouterBaseUrl,
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
    );

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
      ),
    );
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

    final processRunner = GreenTaskProcessRunner(leadAgent: leadAgent);

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
      workerHost: workerHost,
      ownedClosers: ownedClosers,
    );
    return bootstrap;
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
    await auditLogger.flush();
    for (final closer in _ownedClosers) {
      try {
        closer();
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
