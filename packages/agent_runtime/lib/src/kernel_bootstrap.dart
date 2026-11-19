import 'dart:io';
import 'dart:math';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';

import 'process_runner.dart';

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
  });

  final String workspaceHostRoot;
  final String? sessionId;
  final String? sessionUuid;
  final String? startupModel;
  final String? systemInstruction;
  final ApprovalHandler? approvalHandler;
  final List<SyscallHook> hooks;
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
    required this.llmRouter,
    required this.syscallGate,
    required this.modelResolver,
    required this.leadAgent,
    required this.processRunner,
    required List<void Function()> ownedClosers,
  }) : _ownedClosers = ownedClosers;

  /// Default immutable Segment 0 instruction for Stage 1 Step 1-1 Read-Only exploration ([D-007]).
  static const String defaultStep1Instruction = '''
You are the LeadAgent running inside FM Agent OS (Stage 1).
All file and repository paths inside tool calls MUST use the virtual root `/workspace` (never host OS paths like `C:\\...`).
Your workspace is managed by Jujutsu (`jj`), where `@` is the current working-copy change and `@-` is its parent change.

Available Step 1-1 Read-Only exploration syscalls:
- `sys_glob`: Find files matching a glob pattern under `/workspace`.
- `sys_grep`: Search UTF-8 text files under `/workspace` for strings or regexes.
- `sys_read_lines`: Read a 1-based line range from a file under `/workspace` (returns `content`, `sha256`, `totalLines`).
- `sys_jj_status`: Inspect `@`, `@-`, changed files summary, and current `opId`.
- `sys_jj_log`: List Jujutsu commits matching a revset.
- `sys_jj_diff`: Inspect unified Git-format diff for a revision.

Rules:
1. Always inspect the actual files and `jj` history via syscalls before answering; never invent file contents, paths, or commit history.
2. If a syscall output is truncated by the Kernel I/O Cap (`truncated: true`), use `totalLines` / `omittedLines` and call `sys_read_lines(path, startLine, endLine)` or narrow `sys_grep` patterns to inspect the needed sections.
3. Protected internal paths (`.jj`, `.git`, `.agent_os`, `.env*`) are denied by the kernel and must not be read.
4. Keep answers concise, accurate, and grounded in observed tool outputs.
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
  final LlmRouter llmRouter;
  final SyscallGate syscallGate;
  final ModelResolver modelResolver;
  final LeadAgent leadAgent;
  final GreenTaskProcessRunner processRunner;
  final List<void Function()> _ownedClosers;

  bool _disposed = false;

  /// Canonical host path mapped to `/workspace`.
  String get workspaceHostRoot => namespace.workspaceHostRoot;

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

    final namespace = VfsNamespace(workspaceHostRoot: config.workspaceHostRoot);

    // Initialize AuditLogger early so `.agent_os/.gitignore` exists before any `jj` command ([D-003]).
    final auditLogger = AuditLogger(
      workspaceHostRoot: namespace.workspaceHostRoot,
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

    final toolSchemas = <SyscallToolSchema>[
      ...HostFsDriver.readToolSchemas(),
      ...JjDriver.readToolSchemas(),
      ...config.extraToolSchemas,
    ];

    const defaultCapHandle = CapHandle('cap_workspace_rw');
    final jjContext = JjTxContext();
    final pcb = ProcessControlBlock(
      pid: 1,
      name: 'lead-agent',
      ring: ProtectionRing.ring2,
      cspace: CapabilityTable.stage1LeadAgent(handle: defaultCapHandle),
      quota: config.quota,
      namespace: namespace,
      jjContext: jjContext,
      memory: VirtualContextMemory(
        sessionId: effectiveSessionId,
        systemInstruction: PinnedSystemInstruction(
          instruction: config.systemInstruction ?? defaultStep1Instruction,
          tools: toolSchemas,
        ),
      ),
    );

    final processTable = KernelProcessTable();
    final registerRes = processTable.registerProcess(pcb);
    if (!registerRes.ok) {
      throw StateError(
        'Failed to register Stage 1 LeadAgent PCB: ${registerRes.error}',
      );
    }

    final hostFsDriver = HostFsDriver(namespace: namespace);
    final jjDriver = JjDriver(
      namespace: namespace,
      txContext: jjContext,
      jjExecutable: config.jjExecutable,
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

    final syscallGate = SyscallGate(
      processTable: processTable,
      approvalGate: approvalGate,
      ioCapper: ioCapper,
      auditLogger: auditLogger,
      redactor: effectiveRedactor,
      hooks: config.hooks,
      jjAuditInfoProvider: jjDriver.getAuditInfo,
    );

    final modelResolver = ModelResolver(
      startupModel: config.startupModel,
    );

    late final LeadAgent leadAgent;
    leadAgent = LeadAgent(
      pcb: pcb,
      syscallGate: syscallGate,
      capHandle: defaultCapHandle,
      modelResolver: modelResolver,
      sessionUuid: config.sessionUuid,
      maxStepsPerTurn: config.maxStepsPerTurn,
    );

    // Register Step 1-1 Read-Only VFS, Jujutsu, and LLM syscalls.
    hostFsDriver.registerReadSyscalls(syscallGate);
    jjDriver.registerReadSyscalls(syscallGate);
    syscallGate.registerSyscall(
      buildLlmChatSyscallDefinition(
        router: effectiveRouter,
        auditLogger: auditLogger,
        projector: config.projector,
        onStreamEvent: (sid, turnIndex, event) {
          leadAgent.forwardLlmStreamEvent(turnIndex, event);
          config.onLlmStreamEvent?.call(sid, turnIndex, event);
        },
      ),
    );

    for (final extra in config.extraSyscalls) {
      syscallGate.registerSyscall(extra);
    }

    final processRunner = GreenTaskProcessRunner(leadAgent: leadAgent);

    return KernelBootstrap._(
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
      llmRouter: effectiveRouter,
      syscallGate: syscallGate,
      modelResolver: modelResolver,
      leadAgent: leadAgent,
      processRunner: processRunner,
      ownedClosers: ownedClosers,
    );
  }

  /// Registers a Stage 3/6 hook on [syscallGate] (extension point for WP-7+).
  void addHook(SyscallHook hook) => syscallGate.addHook(hook);

  /// Registers an additional syscall definition on [syscallGate] (extension point for WP-6/WP-7).
  void registerSyscall(SyscallDefinition definition) =>
      syscallGate.registerSyscall(definition);

  /// Flushes audit logs, disposes the process runner, and closes owned HTTP clients.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await processRunner.dispose();
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
