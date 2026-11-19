import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _StubWebSearchBackend implements WebSearchBackend {
  @override
  String get providerName => 'stub-search';

  @override
  Future<SyscallResult<WebSearchResponse>> search({
    required String query,
    int maxResults = 5,
    CancellationToken? cancelToken,
  }) async {
    return SyscallResult<WebSearchResponse>.success(
      WebSearchResponse(
        query: query,
        provider: providerName,
        results: const <WebSearchResultItem>[
          WebSearchResultItem(
            title: 'Dart Docs',
            url: 'https://dart.dev',
            content: 'Dart language documentation.',
          ),
        ],
      ),
    );
  }
}

class _OrderedSyscallHook extends BaseSyscallHook {
  _OrderedSyscallHook({
    required this.hookName,
    required this.log,
    this.blockBefore = false,
    this.appendTag,
    this.injectSecret,
    this.expandLines,
    this.tryForgeSuccess = false,
  });

  final String hookName;
  final List<String> log;
  final bool blockBefore;
  final String? appendTag;
  final String? injectSecret;
  final int? expandLines;
  final bool tryForgeSuccess;

  @override
  String get name => hookName;

  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async {
    log.add('before:$hookName');
    if (blockBefore) {
      return HookBlock(
        reason: 'BLOCKED_BY_$hookName',
        message: 'Blocked by $hookName',
      );
    }
    return const HookAllow();
  }

  @override
  Future<HookAfterResult> transformAfterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    log.add('transform:$hookName');
    if (tryForgeSuccess && !result.ok) {
      return HookAfterReplace(const <String, dynamic>{'forged': true});
    }
    if (!result.ok || result.value == null) {
      return const HookAfterKeep();
    }
    if (appendTag != null || injectSecret != null || expandLines != null) {
      final updated = Map<String, dynamic>.from(result.value!);
      final tags = List<String>.from(
        (updated['tags'] as List<dynamic>?) ?? const <dynamic>[],
      );
      if (appendTag != null) {
        tags.add(appendTag!);
        updated['tags'] = tags;
      }
      if (expandLines != null) {
        final secretSuffix = injectSecret == null ? '' : ' $injectSecret';
        updated['content'] = List<String>.generate(
          expandLines!,
          (i) => 'row_$i$secretSuffix',
        ).join('\n');
      } else if (injectSecret != null) {
        updated['content'] = '${updated['content']} $injectSecret';
      }
      return HookAfterReplace(updated);
    }
    return const HookAfterKeep();
  }

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    log.add('after:$hookName');
  }
}

class _OrderedTxHook implements TxHook {
  _OrderedTxHook({
    required this.hookName,
    required this.log,
    this.block = false,
  });

  final String hookName;
  final List<String> log;
  final bool block;

  @override
  String get name => hookName;

  @override
  Future<HookBeforeResult> onTxSquash(SyscallHookContext context) async {
    log.add('onTxSquash:$hookName');
    if (block) {
      return HookBlock(
        reason: 'TX_BLOCK_$hookName',
        message: 'Blocked squash by $hookName',
      );
    }
    return const HookAllow();
  }
}

class _OrderedLlmHook extends BaseLlmHook {
  _OrderedLlmHook({
    required this.hookName,
    required this.log,
    this.tailNote,
    this.blockBefore = false,
    this.replaceSuffix,
    this.blockAfter = false,
  });

  final String hookName;
  final List<String> log;
  final String? tailNote;
  final bool blockBefore;
  final String? replaceSuffix;
  final bool blockAfter;

  @override
  String get name => hookName;

  @override
  Future<LlmHookBeforeResult> beforeLlmRequest(LlmHookContext context) async {
    log.add('beforeLlm:$hookName');
    if (blockBefore) {
      return LlmHookBlock(
        reason: 'LLM_BEFORE_BLOCK_$hookName',
        message: 'Blocked before LLM by $hookName',
      );
    }
    if (tailNote != null) {
      return LlmHookAppendTailNote(tailNote!);
    }
    return const LlmHookAllow();
  }

  @override
  Future<LlmHookAfterResult> afterLlmResponse(
    LlmHookContext context,
    LlmChatResponse response,
  ) async {
    log.add('afterLlm:$hookName');
    if (blockAfter) {
      return LlmHookAfterBlock(
        reason: 'LLM_AFTER_BLOCK_$hookName',
        message: 'Blocked after LLM by $hookName',
      );
    }
    if (replaceSuffix != null) {
      return LlmHookAfterReplaceText('${response.content}$replaceSuffix');
    }
    return const LlmHookAfterKeep();
  }
}

/// Pure Ring 0 simulator mirroring the `[D-203]` §3.1(4) / `[D-220]` LLM hook pipeline invariants.
Future<({ProjectedPrompt prompt, LlmChatResponse? response, SyscallError? error})>
    _runLlmHookPipeline({
  required List<LlmHook> hooks,
  required ProjectedPrompt initialPrompt,
  required LlmChatResponse Function(ProjectedPrompt sentPrompt) driver,
  required QuotaConsumption quotaUsage,
}) async {
  const model = ModelIdentifier(
    provider: LlmProviderId.localOllama,
    modelName: 'gemma4:12b',
  );
  var currentPrompt = initialPrompt;
  for (final hook in hooks) {
    final res = await hook.beforeLlmRequest(
      LlmHookContext(
        pid: 1,
        ring: ProtectionRing.ring2,
        sessionId: 'sess_llm_hook',
        turnIndex: 1,
        model: model,
        prompt: currentPrompt,
      ),
    );
    switch (res) {
      case LlmHookAllow():
        break;
      case LlmHookAppendTailNote(:final note):
        final trimmed = note.trim();
        if (trimmed.isNotEmpty) {
          final msgs = List<ProjectedMessage>.from(currentPrompt.messages);
          if (msgs.isNotEmpty && msgs.last.segmentIndex == 2) {
            final tail = msgs.last;
            msgs[msgs.length - 1] = ProjectedMessage(
              role: tail.role,
              content: '${tail.content}\n\n$trimmed',
              segmentIndex: 2,
            );
          } else {
            msgs.add(
              ProjectedMessage(
                role: ProjectedRole.user,
                content: trimmed,
                segmentIndex: 2,
              ),
            );
          }
          currentPrompt = ProjectedPrompt(
            messages: msgs,
            tools: currentPrompt.tools,
          );
        }
      case LlmHookBlock(:final reason, :final message, :final hint):
        return (
          prompt: currentPrompt,
          response: null,
          error: SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'HOOK_BLOCKED',
            message: message,
            hint: hint,
            details: <String, dynamic>{
              'hookName': hook.name,
              'blockReason': reason,
              'hookPoint': 'beforeLlmRequest',
            },
          ),
        );
    }
  }

  final rawResponse = driver(currentPrompt);
  final originalUsage = rawResponse.usage;
  var effectiveResponse = rawResponse;
  for (final hook in hooks) {
    final res = await hook.afterLlmResponse(
      LlmHookContext(
        pid: 1,
        ring: ProtectionRing.ring2,
        sessionId: 'sess_llm_hook',
        turnIndex: 1,
        model: model,
        prompt: currentPrompt,
      ),
      effectiveResponse,
    );
    switch (res) {
      case LlmHookAfterKeep():
        break;
      case LlmHookAfterReplaceText(:final content):
        effectiveResponse = LlmChatResponse(
          content: content,
          thoughtText: effectiveResponse.thoughtText,
          rawReasoningDetails: effectiveResponse.rawReasoningDetails,
          toolCalls: effectiveResponse.toolCalls,
          usage: originalUsage,
          finishReason: effectiveResponse.finishReason,
          endpoint: effectiveResponse.endpoint,
        );
      case LlmHookAfterBlock(:final reason, :final message, :final hint):
        quotaUsage.recordUsage(
          tokens: originalUsage.totalTokens,
          costMicroUsd: originalUsage.costMicroUsd ?? 0,
        );
        return (
          prompt: currentPrompt,
          response: null,
          error: SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'HOOK_BLOCKED',
            message: message,
            hint: hint,
            details: <String, dynamic>{
              'hookName': hook.name,
              'blockReason': reason,
              'hookPoint': 'afterLlmResponse',
            },
          ),
        );
    }
  }

  quotaUsage.recordUsage(
    tokens: originalUsage.totalTokens,
    costMicroUsd: originalUsage.costMicroUsd ?? 0,
  );
  return (prompt: currentPrompt, response: effectiveResponse, error: null);
}

void main() {
  group('WebSearchBackend abstraction [D-216]', () {
    test('serializes normalized WebSearchResponse and WebSearchResultItem', () async {
      final backend = _StubWebSearchBackend();
      final res = await backend.search(query: 'dart isolate');
      expect(res.ok, isTrue);
      final json = res.value!.toJson();
      expect(json['query'], equals('dart isolate'));
      expect(json['provider'], equals('stub-search'));
      expect(json['results'], hasLength(1));
      expect((json['results'] as List<dynamic>).first['url'], equals('https://dart.dev'));
    });
  });

  group('SkillRegistry CSpace matching, compatibility, and zero escalation [D-203], [D-219]', () {
    late Directory tempRoot;
    late SkillRegistry registry;
    late SkillManifest compatSkill;
    late SkillManifest vcsSkill;
    late SkillManifest execSkill;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('skill_reg_');
      final compatDir = Directory(p.join(tempRoot.path, 'plain-guide'))
        ..createSync();
      final vcsDir = Directory(p.join(tempRoot.path, 'jj-guide'))..createSync();
      final execDir = Directory(p.join(tempRoot.path, 'shell-ops'))
        ..createSync();

      compatSkill = SkillManifest(
        name: 'plain-guide',
        description: 'Compatible skill with omitted required_capabilities',
        virtualPath: '/skills/plain-guide/SKILL.md',
        hostFilePath: p.join(compatDir.path, 'SKILL.md'),
        hostDirectoryPath: compatDir.path,
        sourceRootPath: tempRoot.path,
      );
      vcsSkill = SkillManifest(
        name: 'jj-guide',
        description: 'Requires vcsRead',
        virtualPath: '/skills/jj-guide/SKILL.md',
        hostFilePath: p.join(vcsDir.path, 'SKILL.md'),
        hostDirectoryPath: vcsDir.path,
        sourceRootPath: tempRoot.path,
        requiredCapabilities: const <CapRight>{CapRight.read, CapRight.vcsRead},
      );
      execSkill = SkillManifest(
        name: 'shell-ops',
        description: 'Requires exec and writeCow',
        virtualPath: '/skills/shell-ops/SKILL.md',
        hostFilePath: p.join(execDir.path, 'SKILL.md'),
        hostDirectoryPath: execDir.path,
        sourceRootPath: tempRoot.path,
        requiredCapabilities: const <CapRight>{CapRight.exec, CapRight.writeCow},
      );

      final duplicateLowerPriority = SkillManifest(
        name: 'PLAIN-GUIDE',
        description: 'Lower priority duplicate must be ignored',
        virtualPath: '/skills/PLAIN-GUIDE/SKILL.md',
        hostFilePath: p.join(compatDir.path, 'SKILL.md'),
        hostDirectoryPath: compatDir.path,
        sourceRootPath: tempRoot.path,
      );

      registry = SkillRegistry(
        skills: <SkillManifest>[
          compatSkill,
          vcsSkill,
          execSkill,
          duplicateLowerPriority,
        ],
      );
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('enforces First-Win deduplication, name validation, and fail-closed capability parsing', () {
      expect(registry.length, equals(3));
      expect(
        registry.lookup('plain-guide')!.description,
        equals('Compatible skill with omitted required_capabilities'),
      );
      expect(registry.lookup('PLAIN-GUIDE')!.name, equals('plain-guide'));

      expect(SkillRegistry.isValidSkillName('jj-stacked_workflow.v1'), isTrue);
      expect(SkillRegistry.isValidSkillName('../escape'), isFalse);
      expect(SkillRegistry.isValidSkillName('a/b'), isFalse);
      expect(SkillRegistry.isValidSkillName(r'a\b'), isFalse);
      expect(SkillRegistry.isValidSkillName('.hidden'), isFalse);
      expect(SkillRegistry.isValidSkillName(''), isFalse);

      expect(SkillRegistry.parseCapabilityName('read'), equals(CapRight.read));
      expect(
        SkillRegistry.parseCapabilityName('net:public_readonly'),
        equals(CapRight.netRead),
      );
      expect(SkillRegistry.parseCapabilityName('unknown_cap'), isNull);
      expect(SkillRegistry.parseCapabilityName(''), isNull);
    });

    test('enforces omitted-capability compatibility, CSpace filtering, and zero capability escalation', () {
      final leadCspace = CapabilityTable.stage2LeadAgent();
      final leadNs = VfsNamespace(
        workspaceHostRoot: tempRoot.path,
        skillsMount: registry,
      );
      final leadRightsBefore = Set<CapRight>.from(leadCspace.allRights);

      final leadVisible = registry.listAccessibleBy(leadCspace, leadNs);
      expect(
        leadVisible.map((s) => s.name),
        equals(<String>['plain-guide', 'jj-guide', 'shell-ops']),
      );
      expect(leadCspace.allRights, equals(leadRightsBefore));

      // Explorer has read + vcsRead (no exec/writeCow): sees plain-guide & jj-guide, NOT shell-ops.
      final explorerCspace = leadCspace
          .deriveForProfile(ProcessProfileId.explorer)
          .value!;
      final explorerNs = leadNs.deriveForChild().value!;
      final explorerRightsBefore = Set<CapRight>.from(explorerCspace.allRights);

      final explorerVisible =
          registry.listAccessibleBy(explorerCspace, explorerNs);
      expect(
        explorerVisible.map((s) => s.name),
        equals(<String>['plain-guide', 'jj-guide']),
      );
      expect(registry.isAccessibleBy(explorerCspace, explorerNs, execSkill), isFalse);
      final deniedExec =
          registry.checkAccess(explorerCspace, explorerNs, execSkill);
      expect(deniedExec, isNotNull);
      expect(deniedExec!.code, equals(SyscallErrorCode.eperm));
      expect(deniedExec.reason, equals('SKILL_CAPABILITY_DENIED'));
      // Zero capability escalation invariant.
      expect(explorerCspace.allRights, equals(explorerRightsBefore));

      // Sterile WebResearcher (VfsNamespace.empty(), no CapRight.read) cannot access even omitted-capability skills.
      final webCspace = leadCspace
          .deriveForProfile(ProcessProfileId.webResearcher)
          .value!;
      const webNs = VfsNamespace.empty();
      final webRightsBefore = Set<CapRight>.from(webCspace.allRights);

      expect(registry.listAccessibleBy(webCspace, webNs), isEmpty);
      final deniedUnmounted =
          registry.checkAccess(webCspace, webNs, compatSkill);
      expect(deniedUnmounted!.code, equals(SyscallErrorCode.eacces));
      expect(deniedUnmounted.reason, equals('SKILLS_NOT_MOUNTED'));

      // Even if a namespace had /skills mounted, lacking CapRight.read still fails with CAPABILITY_DENIED.
      final deniedNoRead =
          registry.checkAccess(webCspace, leadNs, compatSkill);
      expect(deniedNoRead!.code, equals(SyscallErrorCode.eperm));
      expect(deniedNoRead.reason, equals('CAPABILITY_DENIED'));
      expect(webCspace.allRights, equals(webRightsBefore));
    });
  });

  group('5-point Pre/Post Hook pipeline FIFO, blocking, and TCB invariants [D-202], [D-203], [D-220]', () {
    late Directory workspaceDir;
    late KernelProcessTable processTable;
    late ProcessControlBlock pcb;
    late AuditLogger auditLogger;
    late SecretRedactor redactor;
    late SyscallContext ctx;

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('hooks_ws_');
      processTable = KernelProcessTable();
      redactor = SecretRedactor()..registerSecret('super-secret-api-key');
      auditLogger = AuditLogger(
        workspaceHostRoot: workspaceDir.path,
        sessionId: 'sess_hooks',
        redactor: redactor,
      );
      pcb = ProcessControlBlock(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        state: ProcessState.running,
        cspace: CapabilityTable.stage2LeadAgent(),
        quota: ResourceQuota.stage2Default,
        namespace: VfsNamespace(workspaceHostRoot: workspaceDir.path),
        memory: VirtualContextMemory(
          sessionId: 'sess_hooks',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'Pinned System Prompt',
            tools: const <SyscallToolSchema>[],
          ),
        ),
      );
      processTable.registerProcess(pcb);
      ctx = const SyscallContext(
        pid: 1,
        capHandle: CapHandle('cap_workspace_rw'),
        sessionId: 'sess_hooks',
      );
    });

    tearDown(() {
      if (workspaceDir.existsSync()) {
        workspaceDir.deleteSync(recursive: true);
      }
    });

    test('executes beforeSyscall, onTxSquash, and afterSyscall transform in strict FIFO order and short-circuits on HookBlock', () async {
      final log = <String>[];
      final approvalHandler = PolicyApprovalHandler.alwaysAllow();

      final gate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: approvalHandler),
        ioCapper: IoPayloadCapper(
          config: const IoCapConfig(maxLines: 4, maxUtf8Bytes: 256),
          workspaceHostRoot: workspaceDir.path,
        ),
        auditLogger: auditLogger,
        redactor: redactor,
        hooks: <SyscallHook>[
          _OrderedSyscallHook(
            hookName: 'h1',
            log: log,
            appendTag: 't1',
          ),
          _OrderedSyscallHook(
            hookName: 'h2',
            log: log,
            appendTag: 't2',
            expandLines: 10,
            injectSecret: 'super-secret-api-key',
          ),
        ],
        txHooks: <TxHook>[
          _OrderedTxHook(hookName: 'tx1', log: log),
          _OrderedTxHook(hookName: 'tx2', log: log),
        ],
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_tx_squash',
          requiredRight: CapRight.vcsTx,
          kind: 'edit',
          applyIoCap: true,
          cappedTextFields: const <String>['content'],
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async {
            log.add('driver:sys_tx_squash');
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{'content': 'ok'},
            );
          },
        ),
      );

      final okRes = await gate.invoke(ctx, SyscallRequest(name: 'sys_tx_squash'));
      expect(okRes.ok, isTrue);
      expect(
        log,
        equals(<String>[
          'before:h1',
          'before:h2',
          'onTxSquash:tx1',
          'onTxSquash:tx2',
          'driver:sys_tx_squash',
          'transform:h1',
          'after:h1',
          'transform:h2',
          'after:h2',
        ]),
      );
      expect(okRes.value!['tags'], equals(<String>['t1', 't2']));
      expect(okRes.value!['truncated'], isTrue);
      expect(
        okRes.value!['content'] as String,
        isNot(contains('super-secret-api-key')),
      );
      expect(okRes.value!['content'] as String, contains('<REDACTED>'));
      expect(approvalHandler.recordedRequests, hasLength(1));

      // Short-circuit when tx1 blocks: tx2, ApprovalHandler, and driver must NOT run.
      final blockedLog = <String>[];
      final blockedApproval = PolicyApprovalHandler.alwaysAllow();
      final blockedGate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: blockedApproval),
        ioCapper: IoPayloadCapper(workspaceHostRoot: workspaceDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
        hooks: <SyscallHook>[
          _OrderedSyscallHook(hookName: 'h1', log: blockedLog),
        ],
        txHooks: <TxHook>[
          _OrderedTxHook(hookName: 'tx1', log: blockedLog, block: true),
          _OrderedTxHook(hookName: 'tx2', log: blockedLog),
        ],
      );
      blockedGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_tx_squash',
          requiredRight: CapRight.vcsTx,
          kind: 'edit',
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async {
            blockedLog.add('driver:must_not_run');
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{},
            );
          },
        ),
      );

      final blockedRes = await blockedGate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_squash'),
      );
      expect(blockedRes.ok, isFalse);
      expect(blockedRes.error!.code, equals(SyscallErrorCode.eperm));
      expect(blockedRes.error!.reason, equals('HOOK_BLOCKED'));
      expect(blockedApproval.recordedRequests, isEmpty);
      expect(blockedLog, equals(<String>['before:h1', 'onTxSquash:tx1']));

      // Short-circuit when beforeSyscall blocks: subsequent beforeSyscall, onTxSquash, ApprovalHandler, and driver must NOT run.
      final beforeBlockLog = <String>[];
      final beforeBlockApproval = PolicyApprovalHandler.alwaysAllow();
      final beforeBlockGate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: beforeBlockApproval),
        ioCapper: IoPayloadCapper(workspaceHostRoot: workspaceDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
        hooks: <SyscallHook>[
          _OrderedSyscallHook(
            hookName: 'h1_block',
            log: beforeBlockLog,
            blockBefore: true,
          ),
          _OrderedSyscallHook(
            hookName: 'h2_never',
            log: beforeBlockLog,
            tryForgeSuccess: true,
          ),
        ],
        txHooks: <TxHook>[
          _OrderedTxHook(hookName: 'tx_never', log: beforeBlockLog),
        ],
      );
      beforeBlockGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_tx_squash',
          requiredRight: CapRight.vcsTx,
          kind: 'edit',
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{},
          ),
        ),
      );
      final beforeBlockedRes = await beforeBlockGate.invoke(
        ctx,
        SyscallRequest(name: 'sys_tx_squash'),
      );
      expect(beforeBlockedRes.ok, isFalse);
      expect(beforeBlockedRes.error!.code, equals(SyscallErrorCode.eperm));
      expect(beforeBlockedRes.error!.reason, equals('HOOK_BLOCKED'));
      expect(beforeBlockApproval.recordedRequests, isEmpty);
      expect(beforeBlockLog, equals(<String>['before:h1_block']));

      // Stage 6 HookAfterReplace cannot forge a failed Stage 5 result into success.
      final forgeLog = <String>[];
      final forgeGate = SyscallGate(
        processTable: processTable,
        approvalGate: ApprovalGate(handler: PolicyApprovalHandler.alwaysAllow()),
        ioCapper: IoPayloadCapper(workspaceHostRoot: workspaceDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
        hooks: <SyscallHook>[
          _OrderedSyscallHook(
            hookName: 'forger',
            log: forgeLog,
            tryForgeSuccess: true,
          ),
        ],
      );
      forgeGate.registerSyscall(
        SyscallDefinition(
          name: 'sys_fail_op',
          requiredRight: CapRight.read,
          kind: 'read',
          handler: (_) async => const SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'DISK_ERROR',
              message: 'read failed',
            ),
          ),
        ),
      );
      final forgeRes = await forgeGate.invoke(
        ctx,
        SyscallRequest(name: 'sys_fail_op'),
      );
      expect(forgeRes.ok, isFalse);
      expect(forgeRes.error!.code, equals(SyscallErrorCode.eio));
      expect(forgeRes.error!.reason, equals('DISK_ERROR'));
    });

    test('enforces LlmHook FIFO order, Segment 0/1 immutability, before/after blocking, and quota non-reduction', () async {
      pcb.memory.appendUserTurn('Turn 1 user question');
      pcb.memory.appendAssistantTurn(
        CanonicalAssistantTurn(
          originProvider: 'local-ollama',
          originModel: 'gemma4:12b',
          content: 'Turn 1 answer',
        ),
      );
      pcb.memory.ephemeralSegment.currentUserInput = 'Turn 2 question';

      const projector = CanonicalIrProjector();
      final initialPrompt = projector.project(
        pcb.memory,
        targetProvider: 'local-ollama',
        targetModel: 'gemma4:12b',
      );
      final seg0Before = initialPrompt.messages
          .where((m) => m.segmentIndex == 0)
          .map((m) => m.content)
          .toList();
      final seg1Before = initialPrompt.messages
          .where((m) => m.segmentIndex == 1)
          .map((m) => m.content)
          .toList();

      final log = <String>[];
      final quotaUsage = QuotaConsumption();
      ProjectedPrompt? observedSentPrompt;

      final res = await _runLlmHookPipeline(
        hooks: <LlmHook>[
          _OrderedLlmHook(
            hookName: 'llm1',
            log: log,
            tailNote: '[Note 1]',
            replaceSuffix: ' [checked-1]',
          ),
          _OrderedLlmHook(
            hookName: 'llm2',
            log: log,
            tailNote: '[Note 2]',
            replaceSuffix: ' [checked-2]',
          ),
        ],
        initialPrompt: initialPrompt,
        quotaUsage: quotaUsage,
        driver: (sentPrompt) {
          observedSentPrompt = sentPrompt;
          return LlmChatResponse(
            content: 'Base reply',
            usage: const LlmUsageTelemetry(
              promptTokens: 100,
              completionTokens: 25,
              totalTokens: 125,
              durationMs: 10,
            ),
          );
        },
      );

      expect(res.error, isNull);
      expect(
        log,
        equals(<String>[
          'beforeLlm:llm1',
          'beforeLlm:llm2',
          'afterLlm:llm1',
          'afterLlm:llm2',
        ]),
      );

      // Segment 0 and Segment 1 remain byte-identical; notes appended strictly to Segment 2 tail.
      final sent = observedSentPrompt!;
      expect(
        sent.messages.where((m) => m.segmentIndex == 0).map((m) => m.content).toList(),
        equals(seg0Before),
      );
      expect(
        sent.messages.where((m) => m.segmentIndex == 1).map((m) => m.content).toList(),
        equals(seg1Before),
      );
      final tailMsg = sent.messages.last;
      expect(tailMsg.segmentIndex, equals(2));
      expect(tailMsg.content, equals('Turn 2 question\n\n[Note 1]\n\n[Note 2]'));

      // afterLlmResponse text transform preserves immutable token usage.
      expect(res.response!.content, equals('Base reply [checked-1] [checked-2]'));
      expect(res.response!.usage.totalTokens, equals(125));
      expect(quotaUsage.totalTokensUsed, equals(125));

      // afterLlmResponse block still charges full consumed quota (no quota reduction/evasion).
      final afterBlockQuota = QuotaConsumption();
      final afterBlockLog = <String>[];
      final afterBlockRes = await _runLlmHookPipeline(
        hooks: <LlmHook>[
          _OrderedLlmHook(
            hookName: 'llm_block_after',
            log: afterBlockLog,
            blockAfter: true,
          ),
        ],
        initialPrompt: initialPrompt,
        quotaUsage: afterBlockQuota,
        driver: (_) => LlmChatResponse(
          content: 'Sensitive output',
          usage: const LlmUsageTelemetry(
            promptTokens: 80,
            completionTokens: 20,
            totalTokens: 100,
            durationMs: 5,
          ),
        ),
      );
      expect(afterBlockRes.error, isNotNull);
      expect(afterBlockRes.error!.code, equals(SyscallErrorCode.eperm));
      expect(afterBlockRes.error!.reason, equals('HOOK_BLOCKED'));
      expect(afterBlockQuota.totalTokensUsed, equals(100));

      // beforeLlmRequest block short-circuits before driver dispatch and charges 0 tokens.
      final beforeBlockQuota = QuotaConsumption();
      final beforeBlockLog = <String>[];
      var driverCalledOnBeforeBlock = false;
      final beforeBlockRes = await _runLlmHookPipeline(
        hooks: <LlmHook>[
          _OrderedLlmHook(
            hookName: 'llm_block_before',
            log: beforeBlockLog,
            blockBefore: true,
          ),
          _OrderedLlmHook(
            hookName: 'llm_never',
            log: beforeBlockLog,
          ),
        ],
        initialPrompt: initialPrompt,
        quotaUsage: beforeBlockQuota,
        driver: (_) {
          driverCalledOnBeforeBlock = true;
          return LlmChatResponse(
            content: 'must not run',
            usage: const LlmUsageTelemetry(
              promptTokens: 50,
              completionTokens: 10,
              totalTokens: 60,
              durationMs: 1,
            ),
          );
        },
      );
      expect(beforeBlockRes.error, isNotNull);
      expect(beforeBlockRes.error!.code, equals(SyscallErrorCode.eperm));
      expect(beforeBlockRes.error!.reason, equals('HOOK_BLOCKED'));
      expect(driverCalledOnBeforeBlock, isFalse);
      expect(beforeBlockQuota.totalTokensUsed, equals(0));
      expect(beforeBlockLog, equals(<String>['beforeLlm:llm_block_before']));
    });
  });
}
