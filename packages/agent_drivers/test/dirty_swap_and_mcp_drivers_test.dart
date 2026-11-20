import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _StubLlmDriver implements LlmDriver {
  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    yield const LlmTextDelta('ok');
    yield LlmDoneEvent(
      LlmChatResponse(
        content: 'ok',
        usage: const LlmUsageTelemetry(
          promptTokens: 120,
          completionTokens: 10,
          durationMs: 15,
        ),
        finishReason: 'stop',
      ),
    );
  }
}

class _StubApprovalHandler implements ApprovalHandler {
  _StubApprovalHandler({required this.decision});

  ApprovalDecision decision;
  final List<ApprovalRequest> requests = <ApprovalRequest>[];

  @override
  Future<ApprovalDecision> requestApproval(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) async {
    requests.add(request);
    return decision;
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fm_wp4_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('WP-4 Dirty Page Swap & --max-context-tokens ([D-316], [D-317])', () {
    test('① maxContextTokens clamps provider window and rejects < minRequiredWindow with EINVAL', () async {
      final mockHttp = MockClient((req) async {
        if (req.url.path.endsWith('/api/ps')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'models': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'gemma4:12b',
                  'context_length': 32768,
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final resolver = ContextWindowResolver(
        config: const ContextWindowConfig(maxContextTokens: 4096),
        httpClient: mockHttp,
      );
      addTearDown(resolver.close);

      final model = ModelIdentifier.parse('local-ollama/gemma4:12b').value!;
      final spec = await resolver.resolve(model);
      expect(spec.contextWindowTokens, 4096);
      expect(spec.source, contains(':capped(4096)'));

      // Too small maxContextTokens (< segment0 + reservedOut + 512) -> EINVAL.
      final tooSmallResolver = ContextWindowResolver(
        config: const ContextWindowConfig(maxContextTokens: 100),
        httpClient: mockHttp,
      );
      addTearDown(tooSmallResolver.close);

      final pinned = PinnedSystemInstruction(
        instruction: 'System rules ' * 20,
        tools: buildMcpToolSchemas(),
      );
      final err = tooSmallResolver.validateMaxContextTokens(
        systemInstruction: pinned,
      );
      expect(err, isNotNull);
      expect(err!.code, SyscallErrorCode.einval);
      expect(err.reason, 'MAX_CONTEXT_TOKENS_TOO_SMALL');
    });

    test('② Clean First, Dirty Second: Clean-only eviction yields swappedDirtyPagesInStep == 0', () async {
      final redactor = SecretRedactor();
      final auditLogger = AuditLogger(
        workspaceHostRoot: tempDir.path,
        sessionId: 'sess_clean_only',
        redactor: redactor,
      );
      final swapStore = JsonlDirtySwapStore(
        workspaceHostRoot: tempDir.path,
        redactor: redactor,
      );

      final namespace = VfsNamespace(workspaceHostRoot: tempDir.path);
      final memory = VirtualContextMemory(
        sessionId: 'sess_clean_only',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'Kernel rules',
          tools: const <SyscallToolSchema>[],
        ),
      );
      final pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage3LeadAgent(),
        quota: ResourceQuota.stage1Default,
        namespace: namespace,
        jjContext: JjTxContext(),
        memory: memory,
      );
      final table = KernelProcessTable()..registerProcess(pcb);

      // Add a large Clean Page (sys_read_lines) that can be evicted in Pass 1.
      memory.appendUserTurn('Read file');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: 'local-ollama',
          originModel: 'gemma4:12b',
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'sc_1',
              name: 'sys_read_lines',
              arguments: <String, dynamic>{'path': '/workspace/big.txt'},
            ),
          ],
        ),
      );
      memory.appendToolResultTurn(
        CanonicalToolResultTurn(
          canonicalCallId: 'sc_1',
          toolName: 'sys_read_lines',
          content: 'line\n' * 1200,
        ),
        cleanSource: CleanPageSourceMeta(
          sourceKind: CleanSourceKind.workspaceFile,
          syscallName: 'sys_read_lines',
          virtualPath: '/workspace/big.txt',
          readSha256: 'abc',
          replayArgs: const <String, dynamic>{'path': '/workspace/big.txt'},
        ),
      );
      memory.appendUserTurn('Continue');

      final router = LlmRouter(
        drivers: <LlmProviderId, LlmDriver>{
          LlmProviderId.localOllama: _StubLlmDriver(),
        },
      );
      final windowResolver = ContextWindowResolver(
        config: const ContextWindowConfig(
          modelOverrides: <String, int>{'local-ollama/gemma4:12b': 1800},
          maxContextTokens: 1800,
        ),
      );
      addTearDown(windowResolver.close);

      final gate = SyscallGate(
        processTable: table,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(workspaceHostRoot: tempDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
      );
      gate.registerSyscall(
        buildLlmChatSyscallDefinition(
          router: router,
          auditLogger: auditLogger,
          contextWindowSource: windowResolver,
          dirtySwapBackend: swapStore,
        ),
      );

      final res = await gate.invoke(
        const SyscallContext(
          pid: 1,
          capHandle: CapHandle('cap_workspace_rw'),
          sessionId: 'sess_clean_only',
        ),
        SyscallRequest(
          name: 'sys_llm_chat',
          args: <String, dynamic>{
            'model': 'local-ollama/gemma4:12b',
            'turnIndex': 2,
          },
        ),
      );

      expect(res.ok, isTrue, reason: '${res.error}');
      final paging = res.value!['paging'] as Map<String, dynamic>;
      expect(paging['evictedPagesInStep'], greaterThan(0));
      expect(paging['swappedDirtyPagesInStep'], 0);
      expect(paging['swappedDirtyPagesTotal'], 0);
    });

    test('③④ Dirty Page Turn Group Swap writes redacted JSONL, preserves tool_call_id pairing, and sys_mem_pagein restores dirty_swap', () async {
      const secretValue = 'sk-or-v1-supersecret999888777666';
      final redactor = SecretRedactor()..registerSecret(secretValue);
      final auditLogger = AuditLogger(
        workspaceHostRoot: tempDir.path,
        sessionId: 'sess_dirty_swap',
        redactor: redactor,
      );
      final swapStore = JsonlDirtySwapStore(
        workspaceHostRoot: tempDir.path,
        redactor: redactor,
      );
      final namespace = VfsNamespace(workspaceHostRoot: tempDir.path);
      final hostFs = HostFsDriver(namespace: namespace);

      final memory = VirtualContextMemory(
        sessionId: 'sess_dirty_swap',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'Kernel rules',
          tools: const <SyscallToolSchema>[],
        ),
      );
      final pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage3LeadAgent(),
        quota: ResourceQuota.stage1Default,
        namespace: namespace,
        jjContext: JjTxContext(),
        memory: memory,
      );
      final table = KernelProcessTable()..registerProcess(pcb);

      // Populate multiple Dirty Turn Groups exceeding a capped window of 1800 tokens.
      memory.appendUserTurn('Investigate auth bug with token $secretValue');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: 'local-ollama',
          originModel: 'gemma4:12b',
          content: 'Checking auth module',
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'call_dirty_1',
              name: 'sys_edit_block',
              arguments: <String, dynamic>{'path': '/workspace/auth.dart'},
            ),
          ],
        ),
      );
      memory.appendToolResultTurn(
        CanonicalToolResultTurn(
          canonicalCallId: 'call_dirty_1',
          toolName: 'sys_edit_block',
          content: 'Edited /workspace/auth.dart successfully. ' * 90,
        ),
      );

      memory.appendUserTurn('Run tests now');
      memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: 'local-ollama',
          originModel: 'gemma4:12b',
          content: 'Running tests',
          toolCalls: <CanonicalToolCall>[
            CanonicalToolCall(
              canonicalCallId: 'call_dirty_2',
              name: 'sys_exec',
              arguments: <String, dynamic>{'command': 'dart test'},
            ),
          ],
        ),
      );
      memory.appendToolResultTurn(
        CanonicalToolResultTurn(
          canonicalCallId: 'call_dirty_2',
          toolName: 'sys_exec',
          content: 'All tests passed. ' * 90,
        ),
      );

      // Recent turn (protected).
      memory.appendUserTurn('Summarize final findings');

      final router = LlmRouter(
        drivers: <LlmProviderId, LlmDriver>{
          LlmProviderId.localOllama: _StubLlmDriver(),
        },
      );
      final windowResolver = ContextWindowResolver(
        config: const ContextWindowConfig(
          modelOverrides: <String, int>{'local-ollama/gemma4:12b': 1800},
          maxContextTokens: 1800,
        ),
      );
      addTearDown(windowResolver.close);

      final gate = SyscallGate(
        processTable: table,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(workspaceHostRoot: tempDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
      );
      gate.registerSyscall(
        buildLlmChatSyscallDefinition(
          router: router,
          auditLogger: auditLogger,
          contextWindowSource: windowResolver,
          dirtySwapBackend: swapStore,
        ),
      );
      gate.registerSyscall(
        buildMemPageinSyscallDefinition(
          hostFsDriver: hostFs,
          dirtySwapBackend: swapStore,
          redactor: redactor,
        ),
      );

      final chatRes = await gate.invoke(
        const SyscallContext(
          pid: 1,
          capHandle: CapHandle('cap_workspace_rw'),
          sessionId: 'sess_dirty_swap',
        ),
        SyscallRequest(
          name: 'sys_llm_chat',
          args: <String, dynamic>{
            'model': 'local-ollama/gemma4:12b',
            'turnIndex': 3,
          },
        ),
      );

      expect(chatRes.ok, isTrue, reason: '${chatRes.error}');
      final paging = chatRes.value!['paging'] as Map<String, dynamic>;
      expect(paging['swappedDirtyPagesInStep'], greaterThan(0));
      expect(paging['swappedTurnGroupsInStep'], greaterThan(0));

      // Verify swap file exists and secret is <REDACTED>.
      final swapPath = swapStore.swapFilePath(
        sessionId: 'sess_dirty_swap',
        pid: pcb.pid,
      );
      expect(File(swapPath).existsSync(), isTrue);
      final swapRaw = await File(swapPath).readAsString();
      expect(swapRaw, isNot(contains(secretValue)));
      expect(swapRaw, contains(SecretRedactor.redactedToken));

      // Verify llm_io.jsonl telemetry recorded swappedDirtyPagesInStep > 0.
      await auditLogger.flush();
      final llmIoLines = await File(auditLogger.llmIoLogPath).readAsLines();
      expect(llmIoLines, isNotEmpty);
      final lastLlmIo =
          jsonDecode(llmIoLines.last) as Map<String, dynamic>;
      expect(lastLlmIo['swappedDirtyPagesInStep'], greaterThan(0));

      // Verify CanonicalIrProjector has 0 orphaned tool_call_id.
      final projected = const CanonicalIrProjector().project(
        pcb.memory,
        targetProvider: 'local-ollama',
        targetModel: 'gemma4:12b',
      );
      final expectedCallIds = <String>{};
      final toolResultCallIds = <String>{};
      for (final msg in projected.messages) {
        for (final tc in msg.toolCalls) {
          expectedCallIds.add(tc.id);
        }
        if (msg.role == ProjectedRole.tool && msg.toolCallId != null) {
          toolResultCallIds.add(msg.toolCallId!);
        }
      }
      expect(toolResultCallIds, equals(expectedCallIds));

      // Verify SummaryPage and individual swapped pageId can be restored via sys_mem_pagein.
      final summaryPages = pcb.memory.pageTable.pages
          .where((p) => p.swapMeta != null && p.pageId == p.swapMeta!.summaryPageId)
          .toList();
      expect(summaryPages, isNotEmpty);
      final summaryPageId = summaryPages.first.pageId;

      final swappedLeafPages = pcb.memory.pageTable.pages
          .where((p) => p.swapMeta != null && p.pageId != p.swapMeta!.summaryPageId)
          .toList();
      expect(swappedLeafPages, isNotEmpty);
      final leafPageId = swappedLeafPages.first.pageId;

      final pageinLeaf = await gate.invoke(
        const SyscallContext(
          pid: 1,
          capHandle: CapHandle('cap_workspace_rw'),
          sessionId: 'sess_dirty_swap',
        ),
        SyscallRequest(
          name: 'sys_mem_pagein',
          args: <String, dynamic>{'pageId': leafPageId},
        ),
      );
      expect(pageinLeaf.ok, isTrue, reason: '${pageinLeaf.error}');
      expect(pageinLeaf.value!['source'], 'dirty_swap');
      expect(pageinLeaf.value!['content'].toString(), isNot(contains(secretValue)));

      final pageinSummary = await gate.invoke(
        const SyscallContext(
          pid: 1,
          capHandle: CapHandle('cap_workspace_rw'),
          sessionId: 'sess_dirty_swap',
        ),
        SyscallRequest(
          name: 'sys_mem_pagein',
          args: <String, dynamic>{'pageId': summaryPageId},
        ),
      );
      expect(pageinSummary.ok, isTrue, reason: '${pageinSummary.error}');
      expect(pageinSummary.value!['source'], 'dirty_swap');
      expect(
        (pageinSummary.value!['restoredPageIds'] as List).length,
        greaterThanOrEqualTo(2),
      );

      // Resident Dirty Page (un-swapped) still returns NOT_CLEAN_PAGE for Stage 2 compatibility.
      pcb.memory.appendUserTurn('New resident dirty turn');
      final residentDirty = pcb.memory.pageTable.pages.lastWhere(
        (p) => p.resident && p.dirty && p.swapMeta == null,
      );
      final residentRes = await gate.invoke(
        const SyscallContext(
          pid: 1,
          capHandle: CapHandle('cap_workspace_rw'),
          sessionId: 'sess_dirty_swap',
        ),
        SyscallRequest(
          name: 'sys_mem_pagein',
          args: <String, dynamic>{'pageId': residentDirty.pageId},
        ),
      );
      expect(residentRes.ok, isFalse);
      expect(residentRes.error!.code, SyscallErrorCode.einval);
      expect(residentRes.error!.reason, 'NOT_CLEAN_PAGE');
    });

    test('JsonlDirtySwapStore returns ENOENT when missing and EIO when corrupted', () async {
      final store = JsonlDirtySwapStore(workspaceHostRoot: tempDir.path);
      final missing = await store.readSwappedPages(
        sessionId: 'no_such_session',
        pid: 1,
      );
      expect(missing.ok, isFalse);
      expect(missing.error!.code, SyscallErrorCode.enoent);
      expect(missing.error!.reason, 'SWAP_RECORD_NOT_FOUND');

      final path = store.swapFilePath(sessionId: 'corrupt_sess', pid: 1);
      await File(path).parent.create(recursive: true);
      await File(path).writeAsString('{not valid json\n');
      final corrupted = await store.readSwappedPages(
        sessionId: 'corrupt_sess',
        pid: 1,
      );
      expect(corrupted.ok, isFalse);
      expect(corrupted.error!.code, SyscallErrorCode.eio);
      expect(corrupted.error!.reason, 'SWAP_CORRUPTED');
    });
  });

  group('WP-4 StdioMcpClient & sys_mcp_* ([D-318], [D-319])', () {
    late String fixtureScriptPath;

    setUp(() {
      fixtureScriptPath = p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'mock_stdio_mcp_server.dart',
      );
      if (!File(fixtureScriptPath).existsSync()) {
        fixtureScriptPath = p.join(
          Directory.current.path,
          'packages',
          'agent_drivers',
          'test',
          'fixtures',
          'mock_stdio_mcp_server.dart',
        );
      }
      expect(File(fixtureScriptPath).existsSync(), isTrue);
    });

    test('⑤⑥⑦⑧⑨ full stdio MCP lifecycle, pagination, redaction, Ring 2 approval, Ring 3 EPERM, Segment 0 invariance, and 0 lingering processes', () async {
      const secretEnvValue = 'mcp_super_secret_token_xyz_987';
      final redactor = SecretRedactor();
      final manager = McpServerManager(
        workspaceHostRoot: tempDir.path,
        redactor: redactor,
      );

      final spec = McpServerSpec(
        name: 'demo_mcp',
        command: Platform.resolvedExecutable,
        args: <String>[fixtureScriptPath],
        env: const <McpEnvVar>[
          McpEnvVar(name: 'MCP_TEST_SECRET', value: secretEnvValue),
        ],
      );

      final connRes = await manager.registerAndConnectAll(<McpServerSpec>[spec]);
      expect(connRes.ok, isTrue, reason: '${connRes.error}');

      final client = manager.clientFor('demo_mcp')!;
      final stdioTransport = client.transport as StdioMcpTransport;
      final mcpOsPid = stdioTransport.osPid;
      expect(mcpOsPid, isNotNull);
      expect(client.negotiatedProtocolVersion, '2025-11-25');
      expect(
        client.cachedTools.map((t) => t.name).toList(),
        containsAll(<String>[
          'echo_Note',
          'calc_sum',
          'fail_domain',
          'echo_secret_env',
        ]),
      );

      // Capture Segment 0 tool schemas before any notification/refresh.
      final segment0ToolsBefore = jsonEncode(
        buildMcpToolSchemas().map((s) => s.toJson()).toList(),
      );

      final namespace = VfsNamespace(workspaceHostRoot: tempDir.path);
      final leadMemory = VirtualContextMemory(
        sessionId: 'sess_mcp',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'Kernel rules',
          tools: buildMcpToolSchemas(),
        ),
      );
      final pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: CapabilityTable.stage3LeadAgent(),
        quota: ResourceQuota.stage1Default,
        namespace: namespace,
        jjContext: JjTxContext(),
        memory: leadMemory,
      );

      final childMemory = VirtualContextMemory(
        sessionId: 'sess_mcp',
        systemInstruction: PinnedSystemInstruction(
          instruction: 'Child rules',
          tools: const <SyscallToolSchema>[],
        ),
      );
      final childPcb = ProcessControlBlock(
        pid: 2,
        parentPid: 1,
        name: 'explorer-1',
        ring: ProtectionRing.ring3,
        profile: ProcessProfileId.explorer,
        cspace: pcb.cspace
            .deriveForProfile(
              ProcessProfileId.explorer,
              childHandle: const CapHandle('cap_child_ws'),
            )
            .value!,
        quota: ResourceQuota.stage1Default,
        namespace: namespace,
        jjContext: JjTxContext(),
        memory: childMemory,
      );

      final table = KernelProcessTable.stage2()
        ..registerProcess(pcb)
        ..registerProcess(childPcb);

      final approvalHandler = _StubApprovalHandler(
        decision: const ApprovalDecision.allowOnce(),
      );
      final auditLogger = AuditLogger(
        workspaceHostRoot: tempDir.path,
        sessionId: 'sess_mcp',
        redactor: redactor,
      );
      final gate = SyscallGate(
        processTable: table,
        approvalGate: ApprovalGate(handler: approvalHandler),
        ioCapper: IoPayloadCapper(workspaceHostRoot: tempDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
      );
      for (final def in buildMcpSyscallDefinitions(
        manager: manager,
        redactor: redactor,
      )) {
        gate.registerSyscall(def);
      }

      const leadCtx = SyscallContext(
        pid: 1,
        capHandle: CapHandle('cap_mcp_session'),
        sessionId: 'sess_mcp',
      );
      const childCtx = SyscallContext(
        pid: 2,
        capHandle: CapHandle('cap_child_ws'),
        sessionId: 'sess_mcp',
      );

      // ⑤ sys_mcp_list_tools works without approval.
      final listRes = await gate.invoke(
        leadCtx,
        SyscallRequest(name: 'sys_mcp_list_tools'),
      );
      expect(listRes.ok, isTrue, reason: '${listRes.error}');
      expect((listRes.value!['tools'] as List).length, 4);

      // ⑤ Unknown server & unknown tool -> ENOENT before approval gate.
      final unknownServer = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{'server': 'missing', 'tool': 'calc_sum'},
        ),
      );
      expect(unknownServer.ok, isFalse);
      expect(unknownServer.error!.code, SyscallErrorCode.enoent);
      expect(unknownServer.error!.reason, 'MCP_SERVER_NOT_FOUND');
      expect(approvalHandler.requests, isEmpty);

      final unknownTool = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{'server': 'demo_mcp', 'tool': 'missing_tool'},
        ),
      );
      expect(unknownTool.ok, isFalse);
      expect(unknownTool.error!.code, SyscallErrorCode.enoent);
      expect(unknownTool.error!.reason, 'MCP_TOOL_NOT_FOUND');
      expect(approvalHandler.requests, isEmpty);

      // ⑦ Ring 2 allow_once -> executes calc_sum and returns structuredContent.
      final sumRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{
            'server': 'demo_mcp',
            'tool': 'calc_sum',
            'arguments': <String, dynamic>{'a': 19, 'b': 23},
          },
        ),
      );
      expect(sumRes.ok, isTrue, reason: '${sumRes.error}');
      expect(sumRes.value!['isError'], isFalse);
      expect(sumRes.value!['content'], 'sum=42');
      expect((sumRes.value!['structuredContent'] as Map)['sum'], 42);
      expect(approvalHandler.requests.length, 1);
      expect(
        approvalHandler.requests.first.approvalSignature,
        'mcp:demo_mcp:calc_sum',
      );

      // ⑦ Ring 2 allow_always -> subsequent call skips ApprovalHandler.
      approvalHandler.decision = const ApprovalDecision.allowAlways();
      final sumRes2 = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{
            'server': 'demo_mcp',
            'tool': 'calc_sum',
            'arguments': <String, dynamic>{'a': 1, 'b': 2},
          },
        ),
      );
      expect(sumRes2.ok, isTrue);
      expect(approvalHandler.requests.length, 2);

      final sumRes3 = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{
            'server': 'demo_mcp',
            'tool': 'calc_sum',
            'arguments': <String, dynamic>{'a': 3, 'b': 4},
          },
        ),
      );
      expect(sumRes3.ok, isTrue);
      expect(approvalHandler.requests.length, 2); // allow_always cached!

      // ⑦ Ring 2 reject_once -> EACCES without calling subprocess.
      approvalHandler.decision = const ApprovalDecision.rejectOnce();
      final rejectedRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{
            'server': 'demo_mcp',
            'tool': 'fail_domain',
            'arguments': <String, dynamic>{'reason': 'should not run'},
          },
        ),
      );
      expect(rejectedRes.ok, isFalse);
      expect(rejectedRes.error!.code, SyscallErrorCode.eacces);
      expect(rejectedRes.error!.reason, 'DENIED_BY_USER');

      // ⑤ Business error (isError: true) returns SyscallResult.success with isError=true & resultSummary.
      approvalHandler.decision = const ApprovalDecision.allowOnce();
      final domainErrRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{
            'server': 'demo_mcp',
            'tool': 'fail_domain',
            'arguments': <String, dynamic>{'reason': 'bad item'},
          },
        ),
      );
      expect(domainErrRes.ok, isTrue);
      expect(domainErrRes.value!['isError'], isTrue);
      expect(domainErrRes.value!['content'], contains('Domain error: bad item'));

      // ⑥ env[].value secret is masked in sys_mcp_call output, stderr ring, and syscalls.jsonl.
      final secretRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{
            'server': 'demo_mcp',
            'tool': 'echo_secret_env',
          },
        ),
      );
      expect(secretRes.ok, isTrue);
      expect(secretRes.value!['content'], isNot(contains(secretEnvValue)));
      expect(secretRes.value!['content'], contains(SecretRedactor.redactedToken));
      expect(
        stdioTransport.recentStderr.join('\n'),
        isNot(contains(secretEnvValue)),
      );

      // ⑧ tools/list_changed notification + refresh keeps Segment 0 100% invariant.
      final noteRes = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{
            'server': 'demo_mcp',
            'tool': 'echo_Note',
            'arguments': <String, dynamic>{
              'text': 'hi',
              'notifyToolsChanged': true,
            },
          },
        ),
      );
      expect(noteRes.ok, isTrue);
      final refreshedList = await gate.invoke(
        leadCtx,
        SyscallRequest(
          name: 'sys_mcp_list_tools',
          args: <String, dynamic>{'refresh': true},
        ),
      );
      expect(refreshedList.ok, isTrue);
      final segment0ToolsAfter = jsonEncode(
        buildMcpToolSchemas().map((s) => s.toJson()).toList(),
      );
      expect(segment0ToolsAfter, equals(segment0ToolsBefore));

      // ⑦ Ring 3 child calling sys_mcp_call -> immediate EPERM with 0 ApprovalHandler calls.
      final approvalCountBeforeChild = approvalHandler.requests.length;
      final childRes = await gate.invoke(
        childCtx,
        SyscallRequest(
          name: 'sys_mcp_call',
          args: <String, dynamic>{
            'server': 'demo_mcp',
            'tool': 'calc_sum',
            'arguments': <String, dynamic>{'a': 1, 'b': 1},
          },
        ),
      );
      expect(childRes.ok, isFalse);
      expect(childRes.error!.code, SyscallErrorCode.eperm);
      expect(approvalHandler.requests.length, approvalCountBeforeChild);

      // Verify syscalls.jsonl contains resultSummary and 0 secret leakage.
      await auditLogger.flush();
      final auditRaw = await File(auditLogger.syscallsLogPath).readAsString();
      expect(auditRaw, isNot(contains(secretEnvValue)));
      expect(auditRaw, contains('"isToolError":true'));

      // ⑨ Dispose terminates subprocess cleanly with 0 lingering processes.
      await manager.dispose();
      expect(client.isConnected, isFalse);
      if (Platform.isWindows && mcpOsPid != null) {
        final k32 = Win32Kernel32();
        expect(k32.isProcessAlive(mcpOsPid), isFalse);
      }
    });
  });
}
