import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

class _PrecheckObserverHook extends BaseSyscallHook {
  _PrecheckObserverHook({this.modifyTargetArgs = false, this.blockCommand});

  final bool modifyTargetArgs;
  final String? blockCommand;
  final List<SyscallHookContext> observedBefore = <SyscallHookContext>[];

  @override
  String get name => 'precheck_observer_hook';

  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async {
    observedBefore.add(context);
    if (blockCommand != null &&
        context.syscallName == 'sys_exec' &&
        context.args['command'] == blockCommand) {
      return const HookBlock(
        reason: 'RAW_GIT_PROHIBITED',
        message: 'Raw git is blocked.',
        hint: 'Use sys_jj_status.',
      );
    }
    if (modifyTargetArgs &&
        context.syscallName == 'sys_exec' &&
        context.args['command'] == 'needs_rewrite') {
      return HookModifyArgs(<String, dynamic>{
        ...context.args,
        'command': 'rewritten_cmd',
      });
    }
    return const HookAllow();
  }
}

void main() {
  group('D-702 CapRight.requestApproval & ProcessProfile boundaries', () {
    test('stage1/2/3LeadAgent hold requestApproval and resolve across distinct scopes', () {
      final s1 = CapabilityTable.stage1LeadAgent();
      final s2 = CapabilityTable.stage2LeadAgent();
      final s3 = CapabilityTable.stage3LeadAgent();

      expect(
        s1.hasRight(
          const CapHandle('cap_workspace_rw'),
          CapRight.requestApproval,
        ),
        isTrue,
      );
      expect(
        s2.hasRight(
          const CapHandle('cap_workspace_rw'),
          CapRight.requestApproval,
        ),
        isTrue,
      );
      expect(
        s3.hasRight(
          const CapHandle('cap_workspace_rw'),
          CapRight.requestApproval,
        ),
        isTrue,
      );
      // Cross-scope resolution from cap_mcp_session resolves /workspace requestApproval.
      expect(
        s3.hasRightForContext(
          const CapHandle('cap_mcp_session'),
          CapRight.requestApproval,
        ),
        isTrue,
      );
    });

    test('all 4 child profiles exclude requestApproval from defaultRights and separate optInRights', () {
      for (final profile in ProcessProfileId.values) {
        expect(
          profile.defaultRights.contains(CapRight.requestApproval),
          isFalse,
          reason: '${profile.wireValue} must default-off requestApproval',
        );
      }

      expect(ProcessProfileId.explorer.optInRights, isEmpty);
      expect(ProcessProfileId.webResearcher.optInRights, isEmpty);
      expect(ProcessProfileId.explorer.supportsUserApprovalOptIn, isFalse);
      expect(ProcessProfileId.webResearcher.supportsUserApprovalOptIn, isFalse);

      expect(
        ProcessProfileId.workspaceWorker.optInRights,
        equals(const <CapRight>{CapRight.requestApproval}),
      );
      expect(
        ProcessProfileId.conflictResolver.optInRights,
        equals(const <CapRight>{CapRight.requestApproval}),
      );
      expect(
        ProcessProfileId.workspaceWorker.supportsUserApprovalOptIn,
        isTrue,
      );
      expect(
        ProcessProfileId.conflictResolver.supportsUserApprovalOptIn,
        isTrue,
      );
      expect(
        ProcessProfileId.workspaceWorker.maxAllowedRights
            .contains(CapRight.requestApproval),
        isTrue,
      );
    });

    test('deriveForProfile enforces opt-in, sterile profile guard, Stage 2 lock precedence, and monotonic attenuation', () {
      final parent = CapabilityTable.stage3LeadAgent();

      // Default derivation excludes requestApproval.
      final defaultWorker =
          parent.deriveForProfile(ProcessProfileId.workspaceWorker);
      expect(defaultWorker.ok, isTrue);
      expect(
        defaultWorker.value!.hasAnyRight(CapRight.requestApproval),
        isFalse,
      );

      // Opt-in via allowUserApproval: true succeeds for workspaceWorker & conflictResolver.
      for (final profile in <ProcessProfileId>[
        ProcessProfileId.workspaceWorker,
        ProcessProfileId.conflictResolver,
      ]) {
        final viaFlag = parent.deriveForProfile(
          profile,
          allowUserApproval: true,
        );
        expect(viaFlag.ok, isTrue, reason: viaFlag.error?.toString());
        expect(viaFlag.value!.hasAnyRight(CapRight.requestApproval), isTrue);

        final viaRequested = parent.deriveForProfile(
          profile,
          requestedRights: <CapRight>{
            CapRight.read,
            CapRight.exec,
            CapRight.requestApproval,
          },
        );
        expect(viaRequested.ok, isTrue, reason: viaRequested.error?.toString());
        expect(
          viaRequested.value!.hasAnyRight(CapRight.requestApproval),
          isTrue,
        );
      }

      // Sterile profiles reject allowUserApproval: true and requestedRights containing requestApproval.
      for (final sterile in <ProcessProfileId>[
        ProcessProfileId.explorer,
        ProcessProfileId.webResearcher,
      ]) {
        final viaFlag = parent.deriveForProfile(
          sterile,
          allowUserApproval: true,
        );
        expect(viaFlag.ok, isFalse);
        expect(viaFlag.error!.code, SyscallErrorCode.eperm);
        expect(viaFlag.error!.reason, 'APPROVAL_NOT_ALLOWED_FOR_PROFILE');

        final viaReq = parent.deriveForProfile(
          sterile,
          requestedRights: <CapRight>{
            ...sterile.defaultRights,
            CapRight.requestApproval,
          },
        );
        expect(viaReq.ok, isFalse);
        expect(viaReq.error!.code, SyscallErrorCode.eperm);
        expect(viaReq.error!.reason, 'APPROVAL_NOT_ALLOWED_FOR_PROFILE');
      }

      // explorer with both writeCow and requestApproval surfaces STAGE2_READONLY_CHILD_LOCK first.
      final stage2LockFirst = parent.deriveForProfile(
        ProcessProfileId.explorer,
        requestedRights: const <CapRight>{
          CapRight.read,
          CapRight.writeCow,
          CapRight.requestApproval,
        },
      );
      expect(stage2LockFirst.ok, isFalse);
      expect(stage2LockFirst.error!.reason, 'STAGE2_READONLY_CHILD_LOCK');

      // Parent without requestApproval cannot grant it (monotonic attenuation).
      final parentWithoutApproval = CapabilityTable(
        initialEntries: <CapabilityEntry>[
          CapabilityEntry(
            handle: const CapHandle('cap_workspace_rw'),
            resourceScope: '/workspace',
            rights: const <CapRight>{
              CapRight.read,
              CapRight.writeCow,
              CapRight.exec,
              CapRight.vcsRead,
              CapRight.llmInfer,
              CapRight.memManage,
              CapRight.ipc,
            },
          ),
        ],
      );
      final attenuatedFail = parentWithoutApproval.deriveForProfile(
        ProcessProfileId.workspaceWorker,
        allowUserApproval: true,
      );
      expect(attenuatedFail.ok, isFalse);
      expect(attenuatedFail.error!.code, SyscallErrorCode.eperm);
      expect(attenuatedFail.error!.reason, 'CAPABILITY_ATTENUATION_VIOLATION');
      expect(
        attenuatedFail.error!.details?['missingParentRights'],
        equals(<String>['requestApproval']),
      );
    });

    test('SpawnSpec.allowUserApproval defaults to null and serializes conditionally', () {
      final defaultSpec = SpawnSpec(
        profile: ProcessProfileId.workspaceWorker,
        taskPrompt: 'work',
      );
      expect(defaultSpec.allowUserApproval, isNull);
      expect(defaultSpec.toJson().containsKey('allowUserApproval'), isFalse);

      final optInSpec = SpawnSpec(
        profile: ProcessProfileId.workspaceWorker,
        taskPrompt: 'work',
        allowUserApproval: true,
      );
      expect(optInSpec.allowUserApproval, isTrue);
      expect(optInSpec.toJson()['allowUserApproval'], isTrue);
    });
  });

  group('D-704 sys_request_approval, one-time ApprovalGrant, Stage 4 & Stage 4.5', () {
    late Directory workspaceDir;
    late KernelProcessTable table;
    late AuditLogger auditLogger;
    late SecretRedactor redactor;
    late ProcessControlBlock leadPcb;
    late ProcessControlBlock workerWithApproval;
    late ProcessControlBlock workerNoApproval;

    ProcessControlBlock buildPcb({
      required Pid pid,
      Pid? parentPid,
      required String name,
      required ProtectionRing ring,
      required CapabilityTable cspace,
      ProcessProfileId? profile,
    }) {
      return ProcessControlBlock(
        pid: pid,
        parentPid: parentPid,
        name: name,
        ring: ring,
        state: ProcessState.running,
        cspace: cspace,
        quota: ResourceQuota.stage2Default,
        namespace: VfsNamespace(workspaceHostRoot: workspaceDir.path),
        memory: VirtualContextMemory(
          sessionId: 'sess_sub_apr',
          systemInstruction: PinnedSystemInstruction(
            instruction: 'sys',
            tools: const <SyscallToolSchema>[],
          ),
        ),
        profile: profile,
      );
    }

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('sub_apr_gate_');
      table = KernelProcessTable.stage2();
      redactor = SecretRedactor()..registerSecret('SECRET_TOKEN_XYZ');
      auditLogger = AuditLogger(
        workspaceHostRoot: workspaceDir.path,
        sessionId: 'sess_sub_apr',
        redactor: redactor,
      );

      final parentCspace = CapabilityTable.stage3LeadAgent();
      leadPcb = buildPcb(
        pid: 1,
        name: 'lead-agent',
        ring: ProtectionRing.ring2,
        cspace: parentCspace,
      );
      workerWithApproval = buildPcb(
        pid: 2,
        parentPid: 1,
        name: 'worker-optin',
        ring: ProtectionRing.ring3,
        cspace: parentCspace
            .deriveForProfile(
              ProcessProfileId.workspaceWorker,
              allowUserApproval: true,
            )
            .value!,
        profile: ProcessProfileId.workspaceWorker,
      );
      workerNoApproval = buildPcb(
        pid: 3,
        parentPid: 1,
        name: 'worker-default',
        ring: ProtectionRing.ring3,
        cspace: parentCspace
            .deriveForProfile(ProcessProfileId.workspaceWorker)
            .value!,
        profile: ProcessProfileId.workspaceWorker,
      );
      expect(table.registerProcess(leadPcb).ok, isTrue);
      expect(table.registerProcess(workerWithApproval).ok, isTrue);
      expect(table.registerProcess(workerNoApproval).ok, isTrue);
    });

    tearDown(() {
      if (workspaceDir.existsSync()) {
        workspaceDir.deleteSync(recursive: true);
      }
    });

    SyscallContext ctxFor(
      ProcessControlBlock pcb, {
      CancellationToken? cancelToken,
    }) {
      final handle = pcb.pid == 1
          ? const CapHandle('cap_workspace_rw')
          : const CapHandle('cap_workspace_worker');
      return SyscallContext(
        pid: pcb.pid,
        capHandle: handle,
        sessionId: 'sess_sub_apr',
        cancelToken: cancelToken,
      );
    }

    test('sys_request_approval rejects missing capability, invalid args, recursion, unsupported targets, unknown syscall, hook block, and policy deny with 0 ApprovalHandler calls', () async {
      final hook = _PrecheckObserverHook(blockCommand: 'git');
      final approvalHandler = PolicyApprovalHandler.alwaysAllow();
      final gate = SyscallGate(
        processTable: table,
        approvalGate: ApprovalGate(handler: approvalHandler),
        ioCapper: IoPayloadCapper(workspaceHostRoot: workspaceDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
        hooks: <SyscallHook>[hook],
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_exec',
          requiredRight: CapRight.exec,
          kind: 'execute',
          validateArgs: (args) {
            if (args['command'] is! String ||
                (args['command'] as String).isEmpty) {
              return const SyscallError(
                code: SyscallErrorCode.einval,
                reason: 'INVALID_ARGS',
                message: 'command is required',
              );
            }
            return null;
          },
          evaluatePolicy: (pcb, args) async {
            if (args['command'] == 'powershell') {
              return RingDecision.deny;
            }
            if (args['command'] == 'dart') {
              return RingDecision.allow;
            }
            return RingDecision.askUser;
          },
          handler: (_) async =>
              const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{'exitCode': 0},
          ),
        ),
      );
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_admin_only',
          requiredRight: CapRight.admin,
          kind: 'other',
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async =>
              const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{},
          ),
        ),
      );

      // 1. Missing CapRight.requestApproval -> CAPABILITY_DENIED
      final noCapRes = await gate.invoke(
        ctxFor(workerNoApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{
            'syscall': 'sys_exec',
            'args': <String, dynamic>{'command': 'where'},
          },
        ),
      );
      expect(noCapRes.ok, isFalse);
      expect(noCapRes.error!.code, SyscallErrorCode.eperm);
      expect(noCapRes.error!.reason, 'CAPABILITY_DENIED');

      // 2. Invalid outer args -> EINVAL
      final badOuter = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{'syscall': '   '},
        ),
      );
      expect(badOuter.ok, isFalse);
      expect(badOuter.error!.code, SyscallErrorCode.einval);

      // 3. Self-recursion -> RECURSIVE_APPROVAL_FORBIDDEN
      final recursiveRes = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{'syscall': 'sys_request_approval'},
        ),
      );
      expect(recursiveRes.ok, isFalse);
      expect(recursiveRes.error!.reason, 'RECURSIVE_APPROVAL_FORBIDDEN');

      // 4. Unsupported targets -> UNSUPPORTED_APPROVAL_TARGET
      for (final target in <String>['sys_exit', 'sys_llm_chat']) {
        final unsupported = await gate.invoke(
          ctxFor(workerWithApproval),
          SyscallRequest(
            name: 'sys_request_approval',
            args: <String, dynamic>{'syscall': target},
          ),
        );
        expect(unsupported.ok, isFalse);
        expect(unsupported.error!.reason, 'UNSUPPORTED_APPROVAL_TARGET');
      }

      // 5. Unknown target syscall -> UNKNOWN_SYSCALL
      final unknown = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{'syscall': 'sys_nonexistent'},
        ),
      );
      expect(unknown.ok, isFalse);
      expect(unknown.error!.reason, 'UNKNOWN_SYSCALL');

      // 6. Target missing right -> CAPABILITY_DENIED
      final missingRight = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{'syscall': 'sys_admin_only'},
        ),
      );
      expect(missingRight.ok, isFalse);
      expect(missingRight.error!.reason, 'CAPABILITY_DENIED');

      // 7. Target invalid args -> EINVAL
      final invalidTargetArgs = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{
            'syscall': 'sys_exec',
            'args': <String, dynamic>{'command': ''},
          },
        ),
      );
      expect(invalidTargetArgs.ok, isFalse);
      expect(invalidTargetArgs.error!.code, SyscallErrorCode.einval);

      // 8. Stage 3 hook block (git) -> HOOK_BLOCKED
      final hookBlocked = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{
            'syscall': 'sys_exec',
            'args': <String, dynamic>{'command': 'git'},
          },
        ),
      );
      expect(hookBlocked.ok, isFalse);
      expect(hookBlocked.error!.reason, 'HOOK_BLOCKED');

      // 9. Ring 3 hard-guard policy deny (powershell) -> DENIED_BY_POLICY
      final policyDenied = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{
            'syscall': 'sys_exec',
            'args': <String, dynamic>{'command': 'powershell'},
          },
        ),
      );
      expect(policyDenied.ok, isFalse);
      expect(policyDenied.error!.reason, 'DENIED_BY_POLICY');

      // 10. Already allowed syscall -> alreadyAllowed: true, grantId: null
      final alreadyAllowed = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{
            'syscall': 'sys_exec',
            'args': <String, dynamic>{'command': 'dart'},
          },
        ),
      );
      expect(alreadyAllowed.ok, isTrue);
      expect(alreadyAllowed.value!['approved'], isTrue);
      expect(alreadyAllowed.value!['alreadyAllowed'], isTrue);
      expect(alreadyAllowed.value!['decision'], 'allow');
      expect(alreadyAllowed.value!['grantId'], isNull);

      // In all 10 cases above, ApprovalHandler was never invoked.
      expect(approvalHandler.recordedRequests, isEmpty);

      // Verify precheck hooks received isApprovalPrecheck: true and namespace.
      final precheckCalls =
          hook.observedBefore.where((c) => c.isApprovalPrecheck).toList();
      expect(precheckCalls, isNotEmpty);
      expect(precheckCalls.every((c) => c.namespace != null), isTrue);

      // Verify audit log recorded ALLOWED + approvalRequired: false for alreadyAllowed.
      final records = File(auditLogger.syscallsLogPath)
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(records.last['decision'], 'ALLOWED');
      expect(records.last['approvalRequired'], isFalse);
    });

    test('one-time ApprovalGrant consumes exactly once for matching (pid, syscall, canonicalArgs) and isolates args/pid', () async {
      final approvalHandler = PolicyApprovalHandler.alwaysAllow();
      final consumedGrants = <ApprovalGrant>[];
      final approvalGate = ApprovalGate(
        handler: approvalHandler,
        onGrantConsumed: consumedGrants.add,
      );
      final hook = _PrecheckObserverHook(modifyTargetArgs: true);
      final gate = SyscallGate(
        processTable: table,
        approvalGate: approvalGate,
        ioCapper: IoPayloadCapper(workspaceHostRoot: workspaceDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
        hooks: <SyscallHook>[hook],
      );

      var execCount = 0;
      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_exec',
          requiredRight: CapRight.exec,
          kind: 'execute',
          normalizeArgs: (args) => <String, dynamic>{
            'command': args['command'],
            'args': args['args'] ?? const <String>[],
            'workingDir': args['workingDir'] ?? '/workspace',
            'timeoutMs': args['timeoutMs'] ?? 60000,
          },
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          approvalPreviewBuilder: (ctx) async => ApprovalPreview(
            title: 'Run ${ctx.args['command']}',
            kind: 'execute',
            metadata: const <String, dynamic>{'previewKey': 'v1'},
          ),
          handler: (_) async {
            execCount += 1;
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{'exitCode': 0},
            );
          },
        ),
      );

      // Request approval with reason containing secret & > 1024 chars to verify redaction + truncation.
      final longReason = 'Need tool for SECRET_TOKEN_XYZ ${'a' * 1200}';
      final reqRes = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: <String, dynamic>{
            'syscall': 'sys_exec',
            'args': const <String, dynamic>{
              'timeoutMs': 60000,
              'command': 'where',
              'args': <String>['dart'],
            },
            'reason': longReason,
          },
        ),
      );
      expect(reqRes.ok, isTrue, reason: reqRes.error?.toString());
      expect(reqRes.value!['approved'], isTrue);
      expect(reqRes.value!['alreadyAllowed'], isFalse);
      expect(reqRes.value!['decision'], 'allow_once');
      expect(reqRes.value!['grantId'], isA<String>());
      expect(approvalHandler.recordedRequests, hasLength(1));

      final sentReq = approvalHandler.recordedRequests.first;
      expect(sentReq.pid, workerWithApproval.pid);
      expect(sentReq.processName, workerWithApproval.name);
      expect(sentReq.profile, 'workspace_worker');
      expect(sentReq.ring, ProtectionRing.ring3);
      expect(sentReq.requestedVia, 'sys_request_approval');
      expect(sentReq.metadata?['previewKey'], 'v1');
      expect(sentReq.agentReason, isNotNull);
      expect(sentReq.agentReason, isNot(contains('SECRET_TOKEN_XYZ')));
      expect(sentReq.agentReason, contains('<REDACTED>'));
      expect(sentReq.agentReason!.length, lessThanOrEqualTo(1024));

      // Different PID (pid=1) cannot consume pid=2's grant -> triggers a new prompt.
      final otherPidRes = await gate.invoke(
        ctxFor(leadPcb),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'where',
            'args': <String>['dart'],
          },
        ),
      );
      expect(otherPidRes.ok, isTrue);
      expect(approvalHandler.recordedRequests, hasLength(2));
      expect(consumedGrants, isEmpty);

      // Changed args (different timeoutMs) does NOT consume pid=2's grant -> prompts again.
      final diffArgsRes = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'where',
            'args': <String>['dart'],
            'timeoutMs': 30000,
          },
        ),
      );
      expect(diffArgsRes.ok, isTrue);
      expect(approvalHandler.recordedRequests, hasLength(3));
      expect(consumedGrants, isEmpty);

      // Matching (pid=2, sys_exec, canonicalArgs with different key order & null field) consumes grant with 0 extra prompts!
      final firstExec = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'args': <String>['dart'],
            'command': 'where',
            'extraNull': null,
          },
        ),
      );
      expect(firstExec.ok, isTrue);
      expect(approvalHandler.recordedRequests, hasLength(3));
      expect(consumedGrants, hasLength(1));
      expect(consumedGrants.first.pid, workerWithApproval.pid);
      expect(consumedGrants.first.preview?.title, 'Run where');

      // Second identical call finds ticket already consumed -> prompts again.
      final secondExec = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{
            'command': 'where',
            'args': <String>['dart'],
          },
        ),
      );
      expect(secondExec.ok, isTrue);
      expect(approvalHandler.recordedRequests, hasLength(4));
      expect(execCount, 4);

      // HookModifyArgs during sys_request_approval binds ticket to rewritten args.
      final rewriteReq = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_request_approval',
          args: const <String, dynamic>{
            'syscall': 'sys_exec',
            'args': <String, dynamic>{'command': 'needs_rewrite'},
          },
        ),
      );
      expect(rewriteReq.ok, isTrue);
      expect(
        (rewriteReq.value!['normalizedArgs'] as Map<String, dynamic>)['command'],
        'rewritten_cmd',
      );
      expect(approvalHandler.recordedRequests, hasLength(5));

      final rewriteExec = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{'command': 'needs_rewrite'},
        ),
      );
      expect(rewriteExec.ok, isTrue);
      // Consumed without extra prompt because HookModifyArgs produced identical rewritten_cmd.
      expect(approvalHandler.recordedRequests, hasLength(5));
    });

    test('Stage 4 enforces TTY_MONOPOLY_DENIED without requestApproval and supports implicit approval with requestApproval', () async {
      final approvalHandler = PolicyApprovalHandler.alwaysAllow();
      final waitEvents = <String>[];
      final approvalGate = ApprovalGate(
        handler: approvalHandler,
        onApprovalWaitStart: (pid) => waitEvents.add('start:$pid'),
        onApprovalWaitEnd: (pid) => waitEvents.add('end:$pid'),
      );
      final gate = SyscallGate(
        processTable: table,
        approvalGate: approvalGate,
        ioCapper: IoPayloadCapper(workspaceHostRoot: workspaceDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_exec',
          requiredRight: CapRight.exec,
          kind: 'execute',
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async =>
              const SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{'exitCode': 0},
          ),
        ),
      );

      // Worker without requestApproval -> EPERM: TTY_MONOPOLY_DENIED, 0 prompts.
      final denied = await gate.invoke(
        ctxFor(workerNoApproval),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{'command': 'where'},
        ),
      );
      expect(denied.ok, isFalse);
      expect(denied.error!.code, SyscallErrorCode.eperm);
      expect(denied.error!.reason, 'TTY_MONOPOLY_DENIED');
      expect(denied.error!.recoverable, isFalse);
      expect(approvalHandler.recordedRequests, isEmpty);
      expect(waitEvents, isEmpty);

      // Worker with requestApproval -> implicit Stage 4 approval succeeds.
      final allowed = await gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{'command': 'where'},
        ),
      );
      expect(allowed.ok, isTrue);
      expect(approvalHandler.recordedRequests, hasLength(1));
      expect(approvalHandler.recordedRequests.first.requestedVia, 'stage4_gate');
      expect(waitEvents, equals(<String>['start:2', 'end:2']));
    });

    test('Stage 4.5 re-checks SIGSTOP received during approval wait before Stage 5 execution', () async {
      final enteredApproval = Completer<void>();
      final approveCompleter = Completer<ApprovalDecision>();
      var driverExecuted = false;

      final gate = SyscallGate(
        processTable: table,
        approvalGate: ApprovalGate(
          handler: PolicyApprovalHandler((_, _) {
            enteredApproval.complete();
            return approveCompleter.future;
          }),
        ),
        ioCapper: IoPayloadCapper(workspaceHostRoot: workspaceDir.path),
        auditLogger: auditLogger,
        redactor: redactor,
      );

      gate.registerSyscall(
        SyscallDefinition(
          name: 'sys_exec',
          requiredRight: CapRight.exec,
          kind: 'execute',
          evaluatePolicy: (_, _) async => RingDecision.askUser,
          handler: (_) async {
            driverExecuted = true;
            return const SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{'exitCode': 0},
            );
          },
        ),
      );

      final invokeFuture = gate.invoke(
        ctxFor(workerWithApproval),
        SyscallRequest(
          name: 'sys_exec',
          args: const <String, dynamic>{'command': 'where'},
        ),
      );

      await enteredApproval.future;
      expect(workerWithApproval.state, ProcessState.waitingApproval);

      // Receive SIGSTOP while waiting for user approval.
      workerWithApproval.suspendController.requestStop(reason: 'paused');
      approveCompleter.complete(const ApprovalDecision.allowOnce());

      // Give microtasks a chance to settle; Stage 4.5 must hold before Stage 5!
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(driverExecuted, isFalse);
      expect(workerWithApproval.state, ProcessState.stopped);

      // Resume with SIGCONT -> Stage 5 now executes.
      workerWithApproval.suspendController.requestContinue();
      final res = await invokeFuture;
      expect(res.ok, isTrue);
      expect(driverExecuted, isTrue);
      expect(workerWithApproval.state, ProcessState.running);
    });
  });

  group('D-706 ApprovalGate FIFO serialization, per-request cancel, RV-001 cleanup grace, and PID-scoped allow_always', () {
    ApprovalRequest makeReq(
      String id, {
      Pid pid = 2,
      String? signature,
    }) {
      return ApprovalRequest(
        requestId: id,
        sessionId: 'sess_fifo',
        pid: pid,
        syscallName: 'sys_exec',
        title: 'Run $id',
        kind: 'execute',
        argsSummary: <String, dynamic>{'command': id},
        approvalSignature: signature,
      );
    }

    test('serializes 3 concurrent requests in FIFO order with max in-flight == 1', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final startedOrder = <String>[];
      final completers = <String, Completer<ApprovalDecision>>{};

      final gate = ApprovalGate(
        handler: PolicyApprovalHandler((req, _) {
          inFlight += 1;
          if (inFlight > maxInFlight) {
            maxInFlight = inFlight;
          }
          startedOrder.add(req.requestId);
          final c = Completer<ApprovalDecision>();
          completers[req.requestId] = c;
          return c.future.whenComplete(() {
            inFlight -= 1;
          });
        }),
      );

      final f1 = gate.evaluate(makeReq('r1', pid: 2));
      final f2 = gate.evaluate(makeReq('r2', pid: 3));
      final f3 = gate.evaluate(makeReq('r3', pid: 4));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(startedOrder, equals(<String>['r1']));
      expect(maxInFlight, equals(1));

      completers['r1']!.complete(const ApprovalDecision.allowOnce());
      expect((await f1).isAllowed, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(startedOrder, equals(<String>['r1', 'r2']));
      expect(maxInFlight, equals(1));

      completers['r2']!.complete(const ApprovalDecision.rejectOnce());
      expect((await f2).isAllowed, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(startedOrder, equals(<String>['r1', 'r2', 'r3']));
      expect(maxInFlight, equals(1));

      completers['r3']!.complete(const ApprovalDecision.allowOnce());
      expect((await f3).isAllowed, isTrue);
      expect(maxInFlight, equals(1));
    });

    test('cancelling queued 2nd request resolves immediately without blocking on 1st and skips handler dispatch', () async {
      final startedOrder = <String>[];
      final completers = <String, Completer<ApprovalDecision>>{};

      final gate = ApprovalGate(
        handler: PolicyApprovalHandler((req, _) {
          startedOrder.add(req.requestId);
          final c = Completer<ApprovalDecision>();
          completers[req.requestId] = c;
          return c.future;
        }),
      );

      final cancel2 = CancellationTokenSource();
      final f1 = gate.evaluate(makeReq('r1', pid: 2));
      final f2 = gate.evaluate(makeReq('r2', pid: 3), cancelToken: cancel2.token);
      final f3 = gate.evaluate(makeReq('r3', pid: 4));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(startedOrder, equals(<String>['r1']));

      // Cancel 2nd while 1st is still pending -> f2 resolves immediately!
      cancel2.cancel('worker_2_killed');
      final d2 = await f2.timeout(const Duration(milliseconds: 50));
      expect(d2.cancelled, isTrue);

      // Complete 1st -> 3rd is dispatched directly, 2nd never reached handler.
      completers['r1']!.complete(const ApprovalDecision.allowOnce());
      expect((await f1).isAllowed, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(startedOrder, equals(<String>['r1', 'r3']));

      completers['r3']!.complete(const ApprovalDecision.allowOnce());
      expect((await f3).isAllowed, isTrue);
    });

    test('RV-001: cancelling active 1st request resolves caller immediately while waiting for cooperative cleanup before dispatching 2nd', () async {
      final events = <String>[];
      final secondStarted = Completer<void>();

      final gate = ApprovalGate(
        handler: PolicyApprovalHandler((req, cancelToken) async {
          events.add('start:${req.requestId}');
          if (req.requestId == 'r1') {
            await cancelToken!.onCancel;
            // Simulate async permission_cancelled wire flush (~15ms).
            await Future<void>.delayed(const Duration(milliseconds: 15));
            events.add('cleanup_done:r1');
            return const ApprovalDecision.cancelled();
          }
          secondStarted.complete();
          return const ApprovalDecision.allowOnce();
        }),
      );

      final cancel1 = CancellationTokenSource();
      final f1 = gate.evaluate(makeReq('r1', pid: 2), cancelToken: cancel1.token);
      final f2 = gate.evaluate(makeReq('r2', pid: 3));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(events, equals(<String>['start:r1']));

      cancel1.cancel('sigkill_r1');
      // Caller of f1 unblocks immediately (well before 15ms cleanup).
      final d1 = await f1.timeout(const Duration(milliseconds: 10));
      expect(d1.cancelled, isTrue);

      await secondStarted.future.timeout(const Duration(milliseconds: 200));
      final d2 = await f2;
      expect(d2.isAllowed, isTrue);

      // Strict wire order: r1 cleanup MUST complete BEFORE r2 starts!
      expect(
        events,
        equals(<String>['start:r1', 'cleanup_done:r1', 'start:r2']),
      );
    });

    test('RV-001: non-cooperative stub handler ignoring cancelToken advances to 2nd request after 50ms grace timeout', () async {
      final started = <String>[];
      final gate = ApprovalGate(
        handler: PolicyApprovalHandler((req, _) {
          started.add(req.requestId);
          if (req.requestId == 'r1') {
            // Stub that ignores cancelToken and never completes.
            return Completer<ApprovalDecision>().future;
          }
          return Future<ApprovalDecision>.value(
            const ApprovalDecision.allowOnce(),
          );
        }),
      );

      final cancel1 = CancellationTokenSource();
      final f1 = gate.evaluate(makeReq('r1', pid: 2), cancelToken: cancel1.token);
      final f2 = gate.evaluate(makeReq('r2', pid: 3));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      cancel1.cancel('sigkill_stub');

      final d1 = await f1.timeout(const Duration(milliseconds: 20));
      expect(d1.cancelled, isTrue);

      final d2 = await f2.timeout(const Duration(milliseconds: 300));
      expect(d2.isAllowed, isTrue);
      expect(started, equals(<String>['r1', 'r2']));
    });

    test('allow_always is strictly scoped per PID and released by clearForPid', () async {
      final handler = PolicyApprovalHandler.alwaysAllowSession();
      final gate = ApprovalGate(handler: handler);

      // pid=2 approves sig_a with allow_always.
      final d1 = await gate.evaluate(makeReq('r1', pid: 2, signature: 'sig_a'));
      expect(d1.option, ApprovalOption.allowAlways);
      expect(handler.recordedRequests, hasLength(1));

      // pid=2 second call auto-approves without handler call.
      final d2 = await gate.evaluate(makeReq('r2', pid: 2, signature: 'sig_a'));
      expect(d2.option, ApprovalOption.allowAlways);
      expect(handler.recordedRequests, hasLength(1));

      // pid=3 and pid=1 do NOT inherit pid=2's allow_always.
      await gate.evaluate(makeReq('r3', pid: 3, signature: 'sig_a'));
      expect(handler.recordedRequests, hasLength(2));
      expect(gate.allowAlwaysSignatures, isEmpty);

      await gate.evaluate(makeReq('r4', pid: 1, signature: 'sig_a'));
      expect(handler.recordedRequests, hasLength(3));
      expect(gate.allowAlwaysSignatures, contains('sig_a'));

      // clearForPid(2) removes pid=2's allow_always and grants without affecting pid=1.
      gate.issueGrant(
        pid: 2,
        syscallName: 'sys_exec',
        normalizedArgs: const <String, dynamic>{'command': 'x'},
        decisionOption: ApprovalOption.allowOnce,
      );
      gate.clearForPid(2);
      expect(gate.allowAlwaysSignaturesForPid(2), isEmpty);
      expect(gate.allowAlwaysSignaturesForPid(1), contains('sig_a'));
      expect(
        gate.consumeGrant(
          pid: 2,
          syscallName: 'sys_exec',
          normalizedArgs: const <String, dynamic>{'command': 'x'},
        ),
        isNull,
      );

      // pid=2 (or new retry pid=4) prompts again.
      await gate.evaluate(makeReq('r5', pid: 2, signature: 'sig_a'));
      expect(handler.recordedRequests, hasLength(4));
      await gate.evaluate(makeReq('r6', pid: 4, signature: 'sig_a'));
      expect(handler.recordedRequests, hasLength(5));
    });

    test('canonicalJsonEncode sorts map keys, omits null entries, preserves list order and types', () {
      final a = ApprovalGate.canonicalJsonEncode(<String, dynamic>{
        'b': 1,
        'a': <String, dynamic>{'z': true, 'm': null, 'k': <Object?>[1, '2']},
        'c': null,
      });
      final b = ApprovalGate.canonicalJsonEncode(<String, dynamic>{
        'a': <String, dynamic>{'k': <Object?>[1, '2'], 'z': true},
        'b': 1,
      });
      final diffOrder = ApprovalGate.canonicalJsonEncode(<String, dynamic>{
        'a': <String, dynamic>{'k': <Object?>['2', 1], 'z': true},
        'b': 1,
      });
      expect(a, equals(b));
      expect(a, isNot(equals(diffOrder)));
    });
  });
}
