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

/// Single mediation gate enforcing Stages 1 through 8 for every syscall ([D-002]).
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
  })  : redactor = redactor ?? auditLogger.redactor,
        _hooks = List<SyscallHook>.from(hooks),
        _txHooks = List<TxHook>.from(txHooks);

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

  int _seqCounter = 0;

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

      // Stage 1: Definition lookup, schema/arg validation, and arg normalization.
      definition = _definitions[request.name];
      if (definition == null) {
        if (request.name == 'sys_spawn' && pcb.quota.maxChildProcesses == 0) {
          decision = AuditDecision.deniedByPolicy;
          result = const SyscallResult<Map<String, dynamic>>.failure(
            SyscallError(
              code: SyscallErrorCode.eperm,
              reason: 'STAGE1_SINGLE_PROCESS_LOCK',
              message:
                  'sys_spawn is locked in Stage 1 (maxChildProcesses = 0).',
              recoverable: false,
            ),
          );
          return result;
        }
        decision = AuditDecision.invalidArgs;
        result = SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.einval,
            reason: 'UNKNOWN_SYSCALL',
            message: 'Unknown syscall "${request.name}".',
            recoverable: true,
          ),
        );
        return result;
      }

      final validationError = definition.validateArgs?.call(currentArgs);
      if (validationError != null) {
        decision = AuditDecision.invalidArgs;
        result = SyscallResult<Map<String, dynamic>>.failure(
          _redactError(validationError),
        );
        return result;
      }

      if (definition.normalizeArgs != null) {
        currentArgs = Map<String, dynamic>.from(
          definition.normalizeArgs!(currentArgs),
        );
      }

      // Stage 2: Quota, CSpace capability, Stage 1 lock, and TxState/VFS preconditions.
      final quotaError = pcb.quotaUsage.checkBeforeSyscall(pcb.quota);
      if (quotaError != null) {
        decision = AuditDecision.quotaExceeded;
        result = SyscallResult<Map<String, dynamic>>.failure(
          _redactError(quotaError),
        );
        return result;
      }

      if (request.name == 'sys_spawn') {
        final spawnError = processTable.validateSpawnAllowed(pcb.pid);
        if (spawnError != null) {
          decision = spawnError.code == SyscallErrorCode.edquot
              ? AuditDecision.quotaExceeded
              : AuditDecision.deniedByPolicy;
          result = SyscallResult<Map<String, dynamic>>.failure(
            _redactError(spawnError),
          );
          return result;
        }
      }

      final hasCapability = pcb.cspace.hasRightForContext(
        context.capHandle,
        definition.requiredRight,
      );
      if (!hasCapability) {
        decision = AuditDecision.deniedByPolicy;
        result = SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.eperm,
            reason: 'CAPABILITY_DENIED',
            message:
                'Capability "${context.capHandle.id}" lacks right "${definition.requiredRight.name}" for ${request.name}.',
            recoverable: false,
          ),
        );
        return result;
      }

      if (definition.checkPreconditions != null) {
        final preError = await definition.checkPreconditions!(pcb, currentArgs);
        if (preError != null) {
          decision = _decisionForPreconditionError(preError.code);
          result = SyscallResult<Map<String, dynamic>>.failure(
            _redactError(preError),
          );
          return result;
        }
      }

      pcb.quotaUsage.recordSyscall();

      // Stage 3: beforeSyscall hook chain in FIFO order (MUST execute before Stage 4 Ring 2 gate).
      var hookContext = SyscallHookContext(
        pid: pcb.pid,
        ring: pcb.ring,
        sessionId: context.sessionId,
        syscallName: request.name,
        args: currentArgs,
        jjContext: pcb.jjContext,
      );

      for (final hook in _hooks) {
        final hookResult = await hook.beforeSyscall(hookContext);
        if (hookResult is HookBlock) {
          decision = AuditDecision.hookBlocked;
          result = SyscallResult<Map<String, dynamic>>.failure(
            _redactError(
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
          );
          return result;
        }
        if (hookResult is HookModifyArgs) {
          final modifiedArgs = Map<String, dynamic>.from(hookResult.args);
          final revalidationError = definition.validateArgs?.call(modifiedArgs);
          if (revalidationError != null) {
            decision = AuditDecision.invalidArgs;
            result = SyscallResult<Map<String, dynamic>>.failure(
              _redactError(revalidationError),
            );
            return result;
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
              decision = _decisionForPreconditionError(preError.code);
              result = SyscallResult<Map<String, dynamic>>.failure(
                _redactError(preError),
              );
              return result;
            }
          }
          hookContext = SyscallHookContext(
            pid: pcb.pid,
            ring: pcb.ring,
            sessionId: context.sessionId,
            syscallName: request.name,
            args: currentArgs,
            jjContext: pcb.jjContext,
          );
        }
      }

      // Stage 3.5: sys_tx_squash dedicated TxHook.onTxSquash chain BEFORE Stage 4 ApprovalGate ([D-202], [D-220]).
      if (request.name == 'sys_tx_squash' && _txHooks.isNotEmpty) {
        for (final txHook in _txHooks) {
          final txResult = await txHook.onTxSquash(hookContext);
          if (txResult is HookBlock) {
            decision = AuditDecision.hookBlocked;
            result = SyscallResult<Map<String, dynamic>>.failure(
              _redactError(
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
            );
            return result;
          }
          if (txResult is HookModifyArgs) {
            final modifiedArgs = Map<String, dynamic>.from(txResult.args);
            final revalidationError =
                definition.validateArgs?.call(modifiedArgs);
            if (revalidationError != null) {
              decision = AuditDecision.invalidArgs;
              result = SyscallResult<Map<String, dynamic>>.failure(
                _redactError(revalidationError),
              );
              return result;
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
                decision = _decisionForPreconditionError(preError.code);
                result = SyscallResult<Map<String, dynamic>>.failure(
                  _redactError(preError),
                );
                return result;
              }
            }
            hookContext = SyscallHookContext(
              pid: pcb.pid,
              ring: pcb.ring,
              sessionId: context.sessionId,
              syscallName: request.name,
              args: currentArgs,
              jjContext: pcb.jjContext,
            );
          }
        }
      }

      // Stage 4: Ring 2 approval gate & TTY monopoly enforcement ([D-202], [D-213]).
      final ringDecision = definition.evaluatePolicy != null
          ? await definition.evaluatePolicy!(pcb, currentArgs)
          : RingDecision.allow;

      if (ringDecision == RingDecision.askUser &&
          (pcb.ring == ProtectionRing.ring3 ||
              (pcb.ring == ProtectionRing.ring2 && pcb.pid != 1))) {
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

        ApprovalPreview? preview;
        if (definition.approvalPreviewBuilder != null) {
          preview = await definition.approvalPreviewBuilder!(hookContext);
        }

        final approvalReq = ApprovalRequest(
          requestId: 'apr_${context.sessionId}_$seq',
          sessionId: context.sessionId,
          pid: pcb.pid,
          syscallName: request.name,
          title: preview?.title ?? 'Approve ${request.name}',
          kind: preview?.kind ?? definition.kind,
          argsSummary: _buildArgsSummary(currentArgs),
          content: preview?.content ?? const <Map<String, dynamic>>[],
          approvalSignature:
              definition.approvalSignatureBuilder?.call(currentArgs),
        );

        final prevState = pcb.state;
        pcb.state = ProcessState.waitingApproval;
        final ApprovalDecision approvalDecision;
        try {
          approvalDecision = await approvalGate.evaluate(
            approvalReq,
            cancelToken: context.cancelToken,
          );
        } finally {
          pcb.state = prevState == ProcessState.ready
              ? ProcessState.running
              : prevState;
        }

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
      } else {
        decision = AuditDecision.allowed;
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
        result = await definition.handler(execCtx);
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
        pcb.state =
            prevState == ProcessState.ready ? ProcessState.running : prevState;
      }

      if (!result.ok && result.error != null) {
        result = SyscallResult<Map<String, dynamic>>.failure(
          _redactError(result.error!),
        );
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
      if (result.ok && definition.applyIoCap && result.value != null) {
        final capped = await ioCapper.capStructuredPayload(
          payload: result.value!,
          textFields: definition.cappedTextFields,
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
