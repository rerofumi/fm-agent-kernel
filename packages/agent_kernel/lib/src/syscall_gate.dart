import 'approval_gate.dart';
import 'audit_logger.dart';
import 'cancellation.dart';
import 'capability.dart';
import 'io_payload_capper.dart';
import 'pcb.dart';
import 'syscall_error.dart';
import 'syscall_hook.dart';

/// Snapshot metadata supplied to [SyscallGate] for Stage 8 `syscalls.jsonl` attribution ([D-010], [D-014]).
class JjAuditInfo {
  const JjAuditInfo({
    this.jjChangeId,
    this.jjOpId,
  });

  final String? jjChangeId;
  final String? jjOpId;
}

/// Callback reading the current `jj` change/op IDs for audit logging without coupling `agent_kernel` to `JjDriver`.
typedef JjAuditInfoProvider = Future<JjAuditInfo> Function();

/// Process-aware callback reading `jj` change/op IDs for a specific [ProcessControlBlock] ([D-305]).
typedef JjProcessAuditInfoProvider = Future<JjAuditInfo> Function(
  ProcessControlBlock? pcb,
);

/// Caller context passed to [SyscallGate.invoke] ([D-002], [D-005]).
class SyscallContext {
  const SyscallContext({
    required this.pid,
    required this.capHandle,
    required this.sessionId,
    this.cancelToken,
  });

  final Pid pid;
  final CapHandle capHandle;
  final String sessionId;
  final CancellationToken? cancelToken;
}

/// Syscall invocation payload ([D-002]).
class SyscallRequest {
  SyscallRequest({
    required this.name,
    Map<String, dynamic> args = const <String, dynamic>{},
  }) : args = Map<String, dynamic>.unmodifiable(args);

  final String name;
  final Map<String, dynamic> args;
}

/// Execution context supplied to a syscall driver handler at Stage 5.
class SyscallExecutionContext {
  const SyscallExecutionContext({
    required this.syscallSeq,
    required this.context,
    required this.pcb,
    required this.syscallName,
    required this.args,
  });

  final int syscallSeq;
  final SyscallContext context;
  final ProcessControlBlock pcb;
  final String syscallName;
  final Map<String, dynamic> args;
}

typedef SyscallArgValidator = SyscallError? Function(Map<String, dynamic> args);
typedef SyscallArgsNormalizer = Map<String, dynamic> Function(
  Map<String, dynamic> args,
);
typedef SyscallPreconditionChecker = Future<SyscallError?> Function(
  ProcessControlBlock pcb,
  Map<String, dynamic> args,
);
typedef SyscallPolicyEvaluator = Future<RingDecision> Function(
  ProcessControlBlock pcb,
  Map<String, dynamic> args,
);
typedef SyscallHandler = Future<SyscallResult<Map<String, dynamic>>> Function(
  SyscallExecutionContext execContext,
);
typedef SyscallResultSummaryBuilder = Map<String, dynamic>? Function(
  Map<String, dynamic> args,
  SyscallResult<Map<String, dynamic>> result,
);

/// Declarative kernel registration entry for a syscall ([D-002], [D-005], [D-020]).
class SyscallDefinition {
  const SyscallDefinition({
    required this.name,
    required this.requiredRight,
    required this.kind,
    this.applyIoCap = true,
    this.cappedTextFields = const <String>[],
    this.validateArgs,
    this.normalizeArgs,
    this.checkPreconditions,
    this.evaluatePolicy,
    this.approvalPreviewBuilder,
    this.approvalSignatureBuilder,
    this.resultSummaryBuilder,
    required this.handler,
  });

  final String name;
  final CapRight requiredRight;
  final String kind;
  final bool applyIoCap;
  final List<String> cappedTextFields;
  final SyscallArgValidator? validateArgs;
  final SyscallArgsNormalizer? normalizeArgs;
  final SyscallPreconditionChecker? checkPreconditions;
  final SyscallPolicyEvaluator? evaluatePolicy;
  final ApprovalPreviewBuilder? approvalPreviewBuilder;
  final String Function(Map<String, dynamic> args)? approvalSignatureBuilder;
  final SyscallResultSummaryBuilder? resultSummaryBuilder;
  final SyscallHandler handler;
}

class _TargetPrecheckOutcome {
  const _TargetPrecheckOutcome.failure({
    required this.error,
    required this.errorDecision,
    this.definition,
    this.normalizedArgs,
  })  : hookContext = null,
        ringDecision = null;

  const _TargetPrecheckOutcome.success({
    required this.definition,
    required this.normalizedArgs,
    required this.hookContext,
    required this.ringDecision,
  })  : error = null,
        errorDecision = null;

  final SyscallError? error;
  final AuditDecision? errorDecision;
  final SyscallDefinition? definition;
  final Map<String, dynamic>? normalizedArgs;
  final SyscallHookContext? hookContext;
  final RingDecision? ringDecision;

  bool get ok => error == null;
}

/// Single mediation gate enforcing Stages 1 through 8 for every syscall ([D-002], [D-704]).
class SyscallGate {
  SyscallGate({
    required this.processTable,
    required this.approvalGate,
    required this.ioCapper,
    required this.auditLogger,
    SecretRedactor? redactor,
    List<SyscallHook> hooks = const <SyscallHook>[],
    List<TxHook> txHooks = const <TxHook>[],
    this.jjAuditInfoProvider,
    this.jjProcessAuditInfoProvider,
    bool enableRequestApprovalSyscall = true,
  })  : redactor = redactor ?? auditLogger.redactor,
        _hooks = List<SyscallHook>.from(hooks),
        _txHooks = List<TxHook>.from(txHooks) {
    if (enableRequestApprovalSyscall) {
      _registerBuiltinRequestApprovalSyscall();
    }
  }

  static const String requestApprovalSyscallName = 'sys_request_approval';
  static const int _maxReasonLength = 1024;
  static const Set<String> _unsupportedApprovalTargets = <String>{
    'sys_exit',
    'sys_llm_chat',
  };

  final KernelProcessTable processTable;
  final ApprovalGate approvalGate;
  final IoPayloadCapper ioCapper;
  final AuditLogger auditLogger;
  final SecretRedactor redactor;
  final JjAuditInfoProvider? jjAuditInfoProvider;
  final JjProcessAuditInfoProvider? jjProcessAuditInfoProvider;

  final List<SyscallHook> _hooks;
  final List<TxHook> _txHooks;
  final Map<String, SyscallDefinition> _definitions =
      <String, SyscallDefinition>{};

  SyscallDefinition? _builtinRequestApprovalDefinition;
  int _seqCounter = 0;

  void _registerBuiltinRequestApprovalSyscall() {
    final def = SyscallDefinition(
      name: requestApprovalSyscallName,
      requiredRight: CapRight.requestApproval,
      kind: 'other',
      applyIoCap: false,
      validateArgs: _validateRequestApprovalArgs,
      normalizeArgs: _normalizeRequestApprovalArgs,
      handler: (_) async => const SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'INTERNAL_UNREACHABLE',
          message: 'sys_request_approval is handled directly by SyscallGate.',
          recoverable: false,
        ),
      ),
    );
    _builtinRequestApprovalDefinition = def;
    _definitions[requestApprovalSyscallName] = def;
  }

  static SyscallError? _validateRequestApprovalArgs(
    Map<String, dynamic> args,
  ) {
    final rawSyscall = args['syscall'];
    if (rawSyscall is! String || rawSyscall.trim().isEmpty) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Field "syscall" must be a non-empty string.',
        recoverable: true,
      );
    }
    if (args.containsKey('args') && args['args'] != null && args['args'] is! Map) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Field "args" must be a JSON object when provided.',
        recoverable: true,
      );
    }
    if (args.containsKey('reason') &&
        args['reason'] != null &&
        args['reason'] is! String) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_ARGS',
        message: 'Field "reason" must be a string when provided.',
        recoverable: true,
      );
    }
    return null;
  }

  Map<String, dynamic> _normalizeRequestApprovalArgs(
    Map<String, dynamic> args,
  ) {
    final targetSyscall = (args['syscall'] as String).trim();
    final rawTargetArgs = args['args'];
    final targetArgs = rawTargetArgs is Map
        ? rawTargetArgs.map<String, dynamic>(
            (Object? k, Object? v) => MapEntry<String, dynamic>(k.toString(), v),
          )
        : <String, dynamic>{};

    String? normalizedReason;
    final rawReason = args['reason'];
    if (rawReason is String) {
      final trimmed = rawReason.trim();
      if (trimmed.isNotEmpty) {
        final truncatedReason = trimmed.length > _maxReasonLength
            ? trimmed.substring(0, _maxReasonLength)
            : trimmed;
        normalizedReason = redactor.redactString(truncatedReason);
      }
    }

    return <String, dynamic>{
      'syscall': targetSyscall,
      'args': targetArgs,
      'reason': ?normalizedReason,
    };
  }

  /// Registers or replaces a syscall definition.
  void registerSyscall(SyscallDefinition definition) {
    _definitions[definition.name] = definition;
  }

  /// Registers a Stage 3/6 hook (executed in FIFO registration order).
  void addHook(SyscallHook hook) {
    _hooks.add(hook);
  }

  /// Registers a Stage 3.5 `sys_tx_squash` transaction hook (executed in FIFO registration order) ([D-202], [D-220]).
  void addTxHook(TxHook hook) {
    _txHooks.add(hook);
  }

  /// Executes a syscall strictly through Stages 1 to 8 ([D-002]).
  Future<SyscallResult<Map<String, dynamic>>> invoke(
    SyscallContext context,
    SyscallRequest request,
  ) async {
    final seq = ++_seqCounter;
    final stopwatch = Stopwatch()..start();

    final pcb = processTable.getProcess(context.pid);
    SyscallDefinition? definition;
    var currentArgs = Map<String, dynamic>.from(request.args);
    var approvalRequired = false;
    var decision = AuditDecision.deniedByPolicy;
    var truncated = false;
    var result = const SyscallResult<Map<String, dynamic>>.failure(
      SyscallError(
        code: SyscallErrorCode.eio,
        reason: 'INTERNAL_UNINITIALIZED',
        message: 'Syscall terminated unexpectedly before producing a result.',
      ),
    );

    try {
      if (pcb == null) {
        decision = AuditDecision.deniedByPolicy;
        result = SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'UNKNOWN_PROCESS',
            message: 'Process ${context.pid} is not registered in KernelProcessTable.',
          ),
        );
        return result;
      }

      // Stage 0.5: Cooperative suspend gate (SIGSTOP); sys_exit is excluded to prevent exit deadlock ([D-312]).
      if (request.name != 'sys_exit' && pcb.suspendController.isSuspended) {
        await pcb.suspendController.waitIfSuspended(
          pcb: pcb,
          cancelToken: context.cancelToken,
        );
        if (context.cancelToken?.isCancelled ?? false) {
          decision = AuditDecision.deniedByPolicy;
          result = const SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.ecancelled,
              reason: 'CANCELLED',
              message: 'Syscall cancelled while process was suspended.',
              recoverable: true,
            ),
          );
          return result;
        }
      }

      // Stages 1 through 4 (pre-approval): shared validation, quota, capability,
      // preconditions, hooks, and ring policy evaluation ([D-002], [D-704]).
      final precheck = await _validateAndEvaluateTarget(
        pcb: pcb,
        context: context,
        syscallName: request.name,
        rawArgs: currentArgs,
        isApprovalPrecheck: false,
        checkQuotaAndRecord: true,
      );
      definition = precheck.definition;
      if (precheck.normalizedArgs != null) {
        currentArgs = precheck.normalizedArgs!;
      }
      if (!precheck.ok) {
        decision = precheck.errorDecision ?? AuditDecision.deniedByPolicy;
        result = SyscallResult<Map<String, dynamic>>.failure(precheck.error!);
        return result;
      }

      final activeDefinition = precheck.definition!;
      final hookContext = precheck.hookContext!;

      // Dedicated built-in handling for explicit `sys_request_approval` ([D-704]).
      if (request.name == requestApprovalSyscallName &&
          identical(activeDefinition, _builtinRequestApprovalDefinition)) {
        final targetSyscall = currentArgs['syscall'] as String;
        final rawTargetArgs =
            currentArgs['args'] as Map<String, dynamic>? ?? <String, dynamic>{};
        final reason = currentArgs['reason'] as String?;

        if (targetSyscall == requestApprovalSyscallName) {
          decision = AuditDecision.invalidArgs;
          result = const SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'RECURSIVE_APPROVAL_FORBIDDEN',
              message:
                  'sys_request_approval cannot target sys_request_approval recursively.',
              recoverable: true,
            ),
          );
          return result;
        }

        if (_unsupportedApprovalTargets.contains(targetSyscall)) {
          decision = AuditDecision.invalidArgs;
          result = SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.einval,
              reason: 'UNSUPPORTED_APPROVAL_TARGET',
              message:
                  'Syscall "$targetSyscall" cannot be requested via sys_request_approval.',
              recoverable: true,
            ),
          );
          return result;
        }

        final targetPrecheck = await _validateAndEvaluateTarget(
          pcb: pcb,
          context: context,
          syscallName: targetSyscall,
          rawArgs: rawTargetArgs,
          isApprovalPrecheck: true,
          checkQuotaAndRecord: false,
        );
        if (!targetPrecheck.ok) {
          decision =
              targetPrecheck.errorDecision ?? AuditDecision.deniedByPolicy;
          result = SyscallResult<Map<String, dynamic>>.failure(
            targetPrecheck.error!,
          );
          return result;
        }

        final targetDef = targetPrecheck.definition!;
        final normalizedTargetArgs = targetPrecheck.normalizedArgs!;
        final targetHookCtx = targetPrecheck.hookContext!;
        final targetRingDecision = targetPrecheck.ringDecision!;

        if (targetRingDecision == RingDecision.deny) {
          decision = AuditDecision.deniedByPolicy;
          result = SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eperm,
              reason: 'DENIED_BY_POLICY',
              message: 'Syscall "$targetSyscall" is denied by ring policy.',
              recoverable: false,
            ),
          );
          return result;
        }

        if (targetRingDecision == RingDecision.allow) {
          approvalRequired = false;
          decision = AuditDecision.allowed;
          result = SyscallResult<Map<String, dynamic>>.success(
            <String, dynamic>{
              'approved': true,
              'alreadyAllowed': true,
              'decision': 'allow',
              'syscall': targetSyscall,
              'normalizedArgs': normalizedTargetArgs,
              'grantId': null,
            },
          );
        } else {
          // targetRingDecision == RingDecision.askUser
          approvalRequired = true;
          if (context.cancelToken?.isCancelled ?? false) {
            decision = AuditDecision.deniedByUser;
            result = const SyscallResult<Map<String, dynamic>>.failure(
              SyscallError(
                code: SyscallErrorCode.ecancelled,
                reason: 'CANCELLED',
                message: 'Approval request was cancelled before evaluation.',
                recoverable: true,
              ),
            );
            return result;
          }

          final sig =
              targetDef.approvalSignatureBuilder?.call(normalizedTargetArgs);
          if (approvalGate.hasAllowAlways(pid: pcb.pid, signature: sig)) {
            final grant = approvalGate.issueGrant(
              pid: pcb.pid,
              syscallName: targetSyscall,
              normalizedArgs: normalizedTargetArgs,
              decisionOption: ApprovalOption.allowAlways,
            );
            decision = AuditDecision.approvedByUser;
            result = SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{
                'approved': true,
                'alreadyAllowed': false,
                'decision': ApprovalOption.allowAlways.wireValue,
                'syscall': targetSyscall,
                'normalizedArgs': normalizedTargetArgs,
                'grantId': grant.grantId,
              },
            );
          } else {
            ApprovalPreview? preview;
            if (targetDef.approvalPreviewBuilder != null) {
              preview = await targetDef.approvalPreviewBuilder!(targetHookCtx);
            }

            final approvalReq = ApprovalRequest(
              requestId: 'apr_${context.sessionId}_$seq',
              sessionId: context.sessionId,
              pid: pcb.pid,
              syscallName: targetSyscall,
              title: preview?.title ?? 'Approve $targetSyscall',
              kind: preview?.kind ?? targetDef.kind,
              argsSummary: _buildArgsSummary(normalizedTargetArgs),
              content: preview?.content ?? const <Map<String, dynamic>>[],
              approvalSignature: sig,
              processName: pcb.name,
              profile: pcb.profile?.wireValue,
              ring: pcb.ring,
              agentReason: reason,
              requestedVia: requestApprovalSyscallName,
              metadata: preview?.metadata,
            );

            final approvalDecision = await _awaitApprovalWithLifecycle(
              pcb: pcb,
              request: approvalReq,
              cancelToken: context.cancelToken,
            );

            if (approvalDecision.cancelled) {
              decision = AuditDecision.deniedByUser;
              result = const SyscallResult<Map<String, dynamic>>.failure(
                SyscallError(
                  code: SyscallErrorCode.ecancelled,
                  reason: 'CANCELLED',
                  message: 'Approval request was cancelled.',
                  recoverable: true,
                ),
              );
              return result;
            }

            if (!approvalDecision.isAllowed) {
              decision = AuditDecision.deniedByUser;
              result = const SyscallResult<Map<String, dynamic>>.failure(
                SyscallError(
                  code: SyscallErrorCode.eacces,
                  reason: 'DENIED_BY_USER',
                  message: 'User denied this operation.',
                  recoverable: true,
                  hint:
                      'User denied this operation. Discuss an alternative plan with the user or call sys_tx_rollback to discard working changes.',
                ),
              );
              return result;
            }

            final grant = approvalGate.issueGrant(
              pid: pcb.pid,
              syscallName: targetSyscall,
              normalizedArgs: normalizedTargetArgs,
              decisionOption: approvalDecision.option,
              preview: preview,
            );
            decision = AuditDecision.approvedByUser;
            result = SyscallResult<Map<String, dynamic>>.success(
              <String, dynamic>{
                'approved': true,
                'alreadyAllowed': false,
                'decision': approvalDecision.option.wireValue,
                'syscall': targetSyscall,
                'normalizedArgs': normalizedTargetArgs,
                'grantId': grant.grantId,
              },
            );
          }
        }
      } else {
        // Stage 4 (post-policy): Capability-based approval gate & one-time grant consumption ([D-202], [D-704]).
        final ringDecision = precheck.ringDecision!;

        if (ringDecision == RingDecision.deny) {
          decision = AuditDecision.deniedByPolicy;
          result = SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eperm,
              reason: 'DENIED_BY_POLICY',
              message: 'Syscall "${request.name}" is denied by ring policy.',
              recoverable: false,
            ),
          );
          return result;
        }

        if (ringDecision == RingDecision.askUser) {
          final canRequestApproval = pcb.cspace.hasRightForContext(
            context.capHandle,
            CapRight.requestApproval,
          );
          if (!canRequestApproval) {
            decision = AuditDecision.deniedByPolicy;
            result = SyscallResult<Map<String, dynamic>>.failure(
              SyscallError(
                code: SyscallErrorCode.eperm,
                reason: 'TTY_MONOPOLY_DENIED',
                message:
                    'Process "${pcb.name}" (pid=${pcb.pid}, ${pcb.ring.name}) cannot request user approval for "${request.name}" (TTY monopoly).',
                recoverable: false,
              ),
            );
            return result;
          }

          approvalRequired = true;
          if (context.cancelToken?.isCancelled ?? false) {
            decision = AuditDecision.deniedByUser;
            result = const SyscallResult<Map<String, dynamic>>.failure(
              SyscallError(
                code: SyscallErrorCode.ecancelled,
                reason: 'CANCELLED',
                message: 'Syscall cancelled before approval.',
                recoverable: true,
              ),
            );
            return result;
          }

          final consumedGrant = approvalGate.consumeGrant(
            pid: pcb.pid,
            syscallName: request.name,
            normalizedArgs: currentArgs,
          );

          if (consumedGrant != null) {
            decision = AuditDecision.approvedByUser;
          } else {
            ApprovalPreview? preview;
            if (activeDefinition.approvalPreviewBuilder != null) {
              preview =
                  await activeDefinition.approvalPreviewBuilder!(hookContext);
            }

            final approvalReq = ApprovalRequest(
              requestId: 'apr_${context.sessionId}_$seq',
              sessionId: context.sessionId,
              pid: pcb.pid,
              syscallName: request.name,
              title: preview?.title ?? 'Approve ${request.name}',
              kind: preview?.kind ?? activeDefinition.kind,
              argsSummary: _buildArgsSummary(currentArgs),
              content: preview?.content ?? const <Map<String, dynamic>>[],
              approvalSignature:
                  activeDefinition.approvalSignatureBuilder?.call(currentArgs),
              processName: pcb.name,
              profile: pcb.profile?.wireValue,
              ring: pcb.ring,
              requestedVia: 'stage4_gate',
              metadata: preview?.metadata,
            );

            final approvalDecision = await _awaitApprovalWithLifecycle(
              pcb: pcb,
              request: approvalReq,
              cancelToken: context.cancelToken,
            );

            if (approvalDecision.cancelled) {
              decision = AuditDecision.deniedByUser;
              result = const SyscallResult<Map<String, dynamic>>.failure(
                SyscallError(
                  code: SyscallErrorCode.ecancelled,
                  reason: 'CANCELLED',
                  message: 'Approval request was cancelled.',
                  recoverable: true,
                ),
              );
              return result;
            }

            if (!approvalDecision.isAllowed) {
              decision = AuditDecision.deniedByUser;
              result = const SyscallResult<Map<String, dynamic>>.failure(
                SyscallError(
                  code: SyscallErrorCode.eacces,
                  reason: 'DENIED_BY_USER',
                  message: 'User denied this operation.',
                  recoverable: true,
                  hint:
                      'User denied this operation. Discuss an alternative plan with the user or call sys_tx_rollback to discard working changes.',
                ),
              );
              return result;
            }

            decision = AuditDecision.approvedByUser;
          }
        } else {
          decision = AuditDecision.allowed;
        }

        // Stage 4.5: Re-check cooperative suspend gate after approval wait before Stage 5 side effects ([D-704]).
        if (approvalRequired &&
            request.name != 'sys_exit' &&
            pcb.suspendController.isSuspended) {
          await pcb.suspendController.waitIfSuspended(
            pcb: pcb,
            cancelToken: context.cancelToken,
          );
          if (context.cancelToken?.isCancelled ?? false) {
            result = const SyscallResult<Map<String, dynamic>>.failure(
              SyscallError(
                code: SyscallErrorCode.ecancelled,
                reason: 'CANCELLED',
                message: 'Syscall cancelled while process was suspended.',
                recoverable: true,
              ),
            );
            return result;
          }
        }

        // Stage 5: Driver execution.
        if (context.cancelToken?.isCancelled ?? false) {
          result = const SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.ecancelled,
              reason: 'CANCELLED',
              message: 'Syscall cancelled prior to driver execution.',
              recoverable: true,
            ),
          );
          return result;
        }

        final prevState = pcb.state;
        pcb.state = ProcessState.waitingSyscall;
        try {
          final execCtx = SyscallExecutionContext(
            syscallSeq: seq,
            context: context,
            pcb: pcb,
            syscallName: request.name,
            args: Map<String, dynamic>.unmodifiable(currentArgs),
          );
          result = await activeDefinition.handler(execCtx);
        } catch (e) {
          result = SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'UNHANDLED_DRIVER_ERROR',
              message: redactor.redactString(e.toString()),
              recoverable: false,
            ),
          );
        } finally {
          // Restore only our temporary wait state. sys_exit or a concurrent
          // signal may have terminated or stopped the process while awaiting.
          if (pcb.state == ProcessState.waitingSyscall) {
            pcb.state = prevState == ProcessState.ready
                ? ProcessState.running
                : prevState;
          }
        }

        if (!result.ok && result.error != null) {
          result = SyscallResult<Map<String, dynamic>>.failure(
            _redactError(result.error!),
          );
        }
      }

      // Stage 6: afterSyscall hook chain (FIFO transform + observation; never falsifies failure into success) ([D-202], [D-220]).
      for (final hook in _hooks) {
        if (hook is SyscallAfterTransformHook) {
          try {
            final transformed = await hook.transformAfterSyscall(
              hookContext,
              result,
            );
            // TCB invariant: HookAfterReplace is only applied when Stage 5 succeeded.
            if (transformed is HookAfterReplace && result.ok) {
              result = SyscallResult<Map<String, dynamic>>.success(
                Map<String, dynamic>.from(transformed.payload),
              );
            }
          } catch (_) {
            // Do not fail completed syscall on non-critical post-hook transform error.
          }
        }
        try {
          await hook.afterSyscall(hookContext, result);
        } catch (_) {
          // Do not fail completed syscall on non-critical post-hook observer error.
        }
      }

      // Stage 7: I/O payload output capper (always applied AFTER Stage 6 transformAfterSyscall).
      if (result.ok && activeDefinition.applyIoCap && result.value != null) {
        final capped = await ioCapper.capStructuredPayload(
          payload: result.value!,
          textFields: activeDefinition.cappedTextFields,
          sessionId: context.sessionId,
          syscallSeq: seq,
          syscallName: request.name,
        );
        truncated = capped.truncated;
        result = SyscallResult<Map<String, dynamic>>.success(capped.payload);
      }

      // Stage 8 pre-return guard: SecretRedactor enforced on successful payload as well ([D-220]).
      if (result.ok && result.value != null) {
        final redactedPayload =
            redactor.redactJson(result.value!) as Map<String, dynamic>;
        result = SyscallResult<Map<String, dynamic>>.success(redactedPayload);
      }

      return result;
    } catch (e) {
      result = SyscallResult<Map<String, dynamic>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'KERNEL_GATE_ERROR',
          message: redactor.redactString(e.toString()),
          recoverable: false,
        ),
      );
      return result;
    } finally {
      // Stage 8: Mandatory audit logging on every exit path.
      stopwatch.stop();
      JjAuditInfo? jjInfo;
      if (jjProcessAuditInfoProvider != null) {
        try {
          jjInfo = await jjProcessAuditInfoProvider!(pcb);
        } catch (_) {
          jjInfo = null;
        }
      } else if (jjAuditInfoProvider != null) {
        try {
          jjInfo = await jjAuditInfoProvider!();
        } catch (_) {
          jjInfo = null;
        }
      }
      final jjChangeId = jjInfo?.jjChangeId ?? pcb?.jjContext.workingChangeId;
      final jjOpId = jjInfo?.jjOpId ?? pcb?.jjContext.currentOpId;
      final rawSummary = definition?.resultSummaryBuilder?.call(
        currentArgs,
        result,
      );

      await auditLogger.logSyscall(
        SyscallAuditRecord(
          seq: seq,
          timestamp: DateTime.now().toUtc(),
          sessionId: context.sessionId,
          pid: context.pid,
          parentPid: pcb?.parentPid,
          processName: pcb?.name,
          ring: pcb?.ring ?? ProtectionRing.ring2,
          syscallName: request.name,
          argsSummary: _buildArgsSummary(currentArgs),
          approvalRequired: approvalRequired,
          decision: decision,
          ok: result.ok,
          errorCode: result.error?.code.codeName,
          errorReason: result.error?.reason,
          truncated: truncated,
          durationMs: stopwatch.elapsedMilliseconds,
          jjChangeId: jjChangeId,
          jjOpId: jjOpId,
          resultSummary: rawSummary == null
              ? null
              : redactor.redactJson(rawSummary) as Map<String, dynamic>,
        ),
      );
    }
  }

  Future<_TargetPrecheckOutcome> _validateAndEvaluateTarget({
    required ProcessControlBlock pcb,
    required SyscallContext context,
    required String syscallName,
    required Map<String, dynamic> rawArgs,
    required bool isApprovalPrecheck,
    required bool checkQuotaAndRecord,
  }) async {
    var currentArgs = Map<String, dynamic>.from(rawArgs);

    // Stage 1: Definition lookup, schema/arg validation, and arg normalization.
    final definition = _definitions[syscallName];
    if (definition == null) {
      if (syscallName == 'sys_spawn' && pcb.quota.maxChildProcesses == 0) {
        return _TargetPrecheckOutcome.failure(
          error: const SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'STAGE1_SINGLE_PROCESS_LOCK',
            message:
                'sys_spawn is locked in Stage 1 (maxChildProcesses = 0).',
            recoverable: false,
          ),
          errorDecision: AuditDecision.deniedByPolicy,
          normalizedArgs: currentArgs,
        );
      }
      return _TargetPrecheckOutcome.failure(
        error: SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'UNKNOWN_SYSCALL',
          message: 'Unknown syscall "$syscallName".',
          recoverable: true,
        ),
        errorDecision: AuditDecision.invalidArgs,
        normalizedArgs: currentArgs,
      );
    }

    final validationError = definition.validateArgs?.call(currentArgs);
    if (validationError != null) {
      return _TargetPrecheckOutcome.failure(
        error: _redactError(validationError),
        errorDecision: AuditDecision.invalidArgs,
        definition: definition,
        normalizedArgs: currentArgs,
      );
    }

    if (definition.normalizeArgs != null) {
      currentArgs = Map<String, dynamic>.from(
        definition.normalizeArgs!(currentArgs),
      );
    }

    // Stage 2: Quota, CSpace capability, Stage 1 lock, and TxState/VFS preconditions.
    if (checkQuotaAndRecord) {
      final quotaError = pcb.quotaUsage.checkBeforeSyscall(pcb.quota);
      if (quotaError != null) {
        return _TargetPrecheckOutcome.failure(
          error: _redactError(quotaError),
          errorDecision: AuditDecision.quotaExceeded,
          definition: definition,
          normalizedArgs: currentArgs,
        );
      }

      if (syscallName == 'sys_spawn') {
        final spawnError = processTable.validateSpawnAllowed(pcb.pid);
        if (spawnError != null) {
          return _TargetPrecheckOutcome.failure(
            error: _redactError(spawnError),
            errorDecision: spawnError.code == SyscallErrorCode.edquot
                ? AuditDecision.quotaExceeded
                : AuditDecision.deniedByPolicy,
            definition: definition,
            normalizedArgs: currentArgs,
          );
        }
      }
    }

    final hasCapability = pcb.cspace.hasRightForContext(
      context.capHandle,
      definition.requiredRight,
    );
    if (!hasCapability) {
      return _TargetPrecheckOutcome.failure(
        error: SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'CAPABILITY_DENIED',
          message:
              'Capability "${context.capHandle.id}" lacks right "${definition.requiredRight.name}" for $syscallName.',
          recoverable: false,
        ),
        errorDecision: AuditDecision.deniedByPolicy,
        definition: definition,
        normalizedArgs: currentArgs,
      );
    }

    if (definition.checkPreconditions != null) {
      final preError = await definition.checkPreconditions!(pcb, currentArgs);
      if (preError != null) {
        return _TargetPrecheckOutcome.failure(
          error: _redactError(preError),
          errorDecision: _decisionForPreconditionError(preError.code),
          definition: definition,
          normalizedArgs: currentArgs,
        );
      }
    }

    if (checkQuotaAndRecord) {
      pcb.quotaUsage.recordSyscall();
    }

    // Stage 3: beforeSyscall hook chain in FIFO order (MUST execute before Stage 4).
    var hookContext = SyscallHookContext(
      pid: pcb.pid,
      ring: pcb.ring,
      sessionId: context.sessionId,
      syscallName: syscallName,
      args: currentArgs,
      jjContext: pcb.jjContext,
      namespace: pcb.namespace,
      isApprovalPrecheck: isApprovalPrecheck,
    );

    for (final hook in _hooks) {
      final hookResult = await hook.beforeSyscall(hookContext);
      if (hookResult is HookBlock) {
        return _TargetPrecheckOutcome.failure(
          error: _redactError(
            SyscallError(
              code: SyscallErrorCode.eperm,
              reason: 'HOOK_BLOCKED',
              message: hookResult.message,
              recoverable: true,
              hint: hookResult.hint,
              details: <String, dynamic>{
                'hookName': hook.name,
                'blockReason': hookResult.reason,
                'hookPoint': 'beforeSyscall',
              },
            ),
          ),
          errorDecision: AuditDecision.hookBlocked,
          definition: definition,
          normalizedArgs: currentArgs,
        );
      }
      if (hookResult is HookModifyArgs) {
        final modifiedArgs = Map<String, dynamic>.from(hookResult.args);
        final revalidationError = definition.validateArgs?.call(modifiedArgs);
        if (revalidationError != null) {
          return _TargetPrecheckOutcome.failure(
            error: _redactError(revalidationError),
            errorDecision: AuditDecision.invalidArgs,
            definition: definition,
            normalizedArgs: currentArgs,
          );
        }
        currentArgs = definition.normalizeArgs != null
            ? Map<String, dynamic>.from(
                definition.normalizeArgs!(modifiedArgs),
              )
            : modifiedArgs;
        if (definition.checkPreconditions != null) {
          final preError = await definition.checkPreconditions!(
            pcb,
            currentArgs,
          );
          if (preError != null) {
            return _TargetPrecheckOutcome.failure(
              error: _redactError(preError),
              errorDecision: _decisionForPreconditionError(preError.code),
              definition: definition,
              normalizedArgs: currentArgs,
            );
          }
        }
        hookContext = SyscallHookContext(
          pid: pcb.pid,
          ring: pcb.ring,
          sessionId: context.sessionId,
          syscallName: syscallName,
          args: currentArgs,
          jjContext: pcb.jjContext,
          namespace: pcb.namespace,
          isApprovalPrecheck: isApprovalPrecheck,
        );
      }
    }

    // Stage 3.5: sys_tx_squash dedicated TxHook.onTxSquash chain BEFORE Stage 4 ([D-202], [D-220]).
    if (syscallName == 'sys_tx_squash' && _txHooks.isNotEmpty) {
      for (final txHook in _txHooks) {
        final txResult = await txHook.onTxSquash(hookContext);
        if (txResult is HookBlock) {
          return _TargetPrecheckOutcome.failure(
            error: _redactError(
              SyscallError(
                code: SyscallErrorCode.eperm,
                reason: 'HOOK_BLOCKED',
                message: txResult.message,
                recoverable: true,
                hint: txResult.hint,
                details: <String, dynamic>{
                  'hookName': txHook.name,
                  'blockReason': txResult.reason,
                  'hookPoint': 'onTxSquash',
                },
              ),
            ),
            errorDecision: AuditDecision.hookBlocked,
            definition: definition,
            normalizedArgs: currentArgs,
          );
        }
        if (txResult is HookModifyArgs) {
          final modifiedArgs = Map<String, dynamic>.from(txResult.args);
          final revalidationError = definition.validateArgs?.call(modifiedArgs);
          if (revalidationError != null) {
            return _TargetPrecheckOutcome.failure(
              error: _redactError(revalidationError),
              errorDecision: AuditDecision.invalidArgs,
              definition: definition,
              normalizedArgs: currentArgs,
            );
          }
          currentArgs = definition.normalizeArgs != null
              ? Map<String, dynamic>.from(
                  definition.normalizeArgs!(modifiedArgs),
                )
              : modifiedArgs;
          if (definition.checkPreconditions != null) {
            final preError = await definition.checkPreconditions!(
              pcb,
              currentArgs,
            );
            if (preError != null) {
              return _TargetPrecheckOutcome.failure(
                error: _redactError(preError),
                errorDecision: _decisionForPreconditionError(preError.code),
                definition: definition,
                normalizedArgs: currentArgs,
              );
            }
          }
          hookContext = SyscallHookContext(
            pid: pcb.pid,
            ring: pcb.ring,
            sessionId: context.sessionId,
            syscallName: syscallName,
            args: currentArgs,
            jjContext: pcb.jjContext,
            namespace: pcb.namespace,
            isApprovalPrecheck: isApprovalPrecheck,
          );
        }
      }
    }

    // Stage 4 (policy evaluation).
    final ringDecision = definition.evaluatePolicy != null
        ? await definition.evaluatePolicy!(pcb, currentArgs)
        : RingDecision.allow;

    return _TargetPrecheckOutcome.success(
      definition: definition,
      normalizedArgs: currentArgs,
      hookContext: hookContext,
      ringDecision: ringDecision,
    );
  }

  Future<ApprovalDecision> _awaitApprovalWithLifecycle({
    required ProcessControlBlock pcb,
    required ApprovalRequest request,
    CancellationToken? cancelToken,
  }) async {
    if (approvalGate.hasAllowAlways(
      pid: pcb.pid,
      signature: request.approvalSignature,
    )) {
      return const ApprovalDecision.allowAlways();
    }

    final prevState = pcb.state;
    if (!pcb.suspendController.isSuspended &&
        pcb.state != ProcessState.terminated) {
      pcb.state = ProcessState.waitingApproval;
    }

    try {
      approvalGate.onApprovalWaitStart?.call(pcb.pid);
    } catch (_) {
      // Non-critical lifecycle hook error must not abort approval evaluation.
    }

    try {
      return await approvalGate.evaluate(
        request,
        cancelToken: cancelToken,
      );
    } finally {
      try {
        approvalGate.onApprovalWaitEnd?.call(pcb.pid);
      } catch (_) {
        // Non-critical lifecycle hook error must not abort state restoration.
      }
      if (pcb.state == ProcessState.terminated) {
        // Preserve terminated state.
      } else if (pcb.suspendController.isSuspended) {
        pcb.state = ProcessState.stopped;
      } else if (pcb.state == ProcessState.waitingApproval) {
        pcb.state =
            prevState == ProcessState.ready ? ProcessState.running : prevState;
      }
    }
  }

  static AuditDecision _decisionForPreconditionError(SyscallErrorCode code) {
    return switch (code) {
      SyscallErrorCode.einval => AuditDecision.invalidArgs,
      SyscallErrorCode.edquot => AuditDecision.quotaExceeded,
      SyscallErrorCode.econflict => AuditDecision.deniedByPolicy,
      _ => AuditDecision.deniedByPolicy,
    };
  }

  SyscallError _redactError(SyscallError error) {
    return SyscallError(
      code: error.code,
      reason: error.reason,
      message: redactor.redactString(error.message),
      recoverable: error.recoverable,
      hint: error.hint == null ? null : redactor.redactString(error.hint!),
      details: error.details == null
          ? null
          : redactor.redactJson(error.details) as Map<String, dynamic>,
    );
  }

  Map<String, dynamic> _buildArgsSummary(Map<String, dynamic> args) {
    final summary = <String, dynamic>{};
    for (final entry in args.entries) {
      final val = entry.value;
      if (val is String && val.length > 512) {
        summary[entry.key] = '${val.substring(0, 512)}...(${val.length} chars)';
      } else {
        summary[entry.key] = val;
      }
    }
    return redactor.redactJson(summary) as Map<String, dynamic>;
  }
}
