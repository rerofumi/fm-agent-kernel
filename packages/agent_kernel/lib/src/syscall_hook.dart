import 'context_memory.dart';
import 'llm_driver.dart';
import 'pcb.dart';
import 'syscall_error.dart';

/// Read-only context supplied to [SyscallHook] and [TxHook] callbacks ([D-017], [D-220]).
class SyscallHookContext {
  SyscallHookContext({
    required this.pid,
    required this.ring,
    required this.sessionId,
    required this.syscallName,
    required Map<String, dynamic> args,
    required this.jjContext,
  }) : args = Map<String, dynamic>.unmodifiable(args);

  final Pid pid;
  final ProtectionRing ring;
  final String sessionId;
  final String syscallName;
  final Map<String, dynamic> args;
  final JjTxContext jjContext;
}

/// Decision returned by [SyscallHook.beforeSyscall] and [TxHook.onTxSquash] ([D-017], [D-220]).
sealed class HookBeforeResult {
  const HookBeforeResult();
}

/// Permits syscall execution to proceed to the next hook or Stage 4.
class HookAllow extends HookBeforeResult {
  const HookAllow();
}

/// Replaces syscall arguments before proceeding; [SyscallGate] re-runs Stage 1/2 validation ([D-220]).
class HookModifyArgs extends HookBeforeResult {
  HookModifyArgs(Map<String, dynamic> args)
      : args = Map<String, dynamic>.unmodifiable(args);

  final Map<String, dynamic> args;
}

/// Blocks syscall execution before Stage 4 approval and Stage 5 driver invocation ([D-002], [D-017], [D-220]).
class HookBlock extends HookBeforeResult {
  const HookBlock({
    required this.reason,
    required this.message,
    this.hint,
  });

  final String reason;
  final String message;
  final String? hint;
}

/// Decision returned by Stage 6 [SyscallAfterTransformHook.transformAfterSyscall] ([D-220]).
sealed class HookAfterResult {
  const HookAfterResult();
}

/// Preserves the current syscall output payload unchanged.
class HookAfterKeep extends HookAfterResult {
  const HookAfterKeep();
}

/// Replaces a successful syscall output payload before Stage 7 [IoPayloadCapper] and Stage 8 [SecretRedactor] ([D-220]).
///
/// TCB invariant: [SyscallGate] never allows [HookAfterReplace] to turn a failed result (`!result.ok`) into success.
class HookAfterReplace extends HookAfterResult {
  HookAfterReplace(Map<String, dynamic> payload)
      : payload = Map<String, dynamic>.unmodifiable(payload);

  final Map<String, dynamic> payload;
}

/// Kernel syscall hook interface executed at Stage 3 and Stage 6 ([D-002], [D-017]).
abstract interface class SyscallHook {
  String get name;

  /// Invoked at Stage 3 prior to Ring 2 approval gating.
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context);

  /// Invoked at Stage 6 after Stage 5 driver execution completes (read-only observation).
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  );
}

/// Extended [SyscallHook] supporting Stage 6 output transformation ([D-220]).
abstract interface class SyscallAfterTransformHook implements SyscallHook {
  /// Optional Stage 6 output transformation invoked prior to Stage 7 [IoPayloadCapper] and Stage 8 [SecretRedactor].
  Future<HookAfterResult> transformAfterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  );
}

/// Convenience base class providing default allow/no-op implementations for [SyscallHook] and [SyscallAfterTransformHook].
///
/// Stage 1 hooks extending [BaseSyscallHook] remain 100% source- and behavior-compatible ([D-220]).
abstract class BaseSyscallHook implements SyscallAfterTransformHook {
  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async =>
      const HookAllow();

  @override
  Future<HookAfterResult> transformAfterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async =>
      const HookAfterKeep();

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {}
}

/// Transaction hook invoked at Stage 3.5 for `sys_tx_squash` before Stage 4 [ApprovalGate] ([D-202], [D-220]).
abstract interface class TxHook {
  String get name;

  /// Validates a pending `sys_tx_squash` prior to user approval.
  ///
  /// Returning [HookBlock] short-circuits with `EPERM: HOOK_BLOCKED` without invoking [ApprovalHandler].
  Future<HookBeforeResult> onTxSquash(SyscallHookContext context);
}

/// Read-only context supplied to [LlmHook] callbacks around `sys_llm_chat` ([D-220]).
class LlmHookContext {
  const LlmHookContext({
    required this.pid,
    required this.ring,
    required this.sessionId,
    required this.turnIndex,
    required this.model,
    required this.prompt,
  });

  final Pid pid;
  final ProtectionRing ring;
  final String sessionId;
  final int turnIndex;
  final ModelIdentifier model;
  final ProjectedPrompt prompt;
}

/// Decision returned by [LlmHook.beforeLlmRequest] ([D-220]).
sealed class LlmHookBeforeResult {
  const LlmHookBeforeResult();
}

/// Permits the LLM request to proceed unchanged.
class LlmHookAllow extends LlmHookBeforeResult {
  const LlmHookAllow();
}

/// Appends an ephemeral note strictly to the tail of Segment 2 without mutating Segment 0 or Segment 1 ([D-220]).
class LlmHookAppendTailNote extends LlmHookBeforeResult {
  const LlmHookAppendTailNote(this.note);

  final String note;
}

/// Blocks the LLM request before invoking the provider driver (`EPERM: HOOK_BLOCKED`) ([D-220]).
class LlmHookBlock extends LlmHookBeforeResult {
  const LlmHookBlock({
    required this.reason,
    required this.message,
    this.hint,
  });

  final String reason;
  final String message;
  final String? hint;
}

/// Decision returned by [LlmHook.afterLlmResponse] ([D-220]).
///
/// TCB invariant: none of these variants permit modifying or reducing [LlmUsageTelemetry] quota consumption.
sealed class LlmHookAfterResult {
  const LlmHookAfterResult();
}

/// Keeps the LLM response content unchanged.
class LlmHookAfterKeep extends LlmHookAfterResult {
  const LlmHookAfterKeep();
}

/// Replaces only the assistant text `content` of the LLM response while preserving actual token usage ([D-220]).
class LlmHookAfterReplaceText extends LlmHookAfterResult {
  const LlmHookAfterReplaceText(this.content);

  final String content;
}

/// Blocks returning the LLM response (`EPERM: HOOK_BLOCKED`) while still accounting actual consumed quota ([D-220]).
class LlmHookAfterBlock extends LlmHookAfterResult {
  const LlmHookAfterBlock({
    required this.reason,
    required this.message,
    this.hint,
  });

  final String reason;
  final String message;
  final String? hint;
}

/// Pre/Post LLM inference hook executed in FIFO registration order inside `sys_llm_chat` ([D-203], [D-220]).
abstract interface class LlmHook {
  String get name;

  /// Invoked after [ContextPager] preparation and before provider dispatch.
  Future<LlmHookBeforeResult> beforeLlmRequest(LlmHookContext context);

  /// Invoked after the LLM stream finishes and before audit logging / returning to caller.
  Future<LlmHookAfterResult> afterLlmResponse(
    LlmHookContext context,
    LlmChatResponse response,
  );
}

/// Convenience base class providing default pass-through implementations for [LlmHook].
abstract class BaseLlmHook implements LlmHook {
  @override
  Future<LlmHookBeforeResult> beforeLlmRequest(LlmHookContext context) async =>
      const LlmHookAllow();

  @override
  Future<LlmHookAfterResult> afterLlmResponse(
    LlmHookContext context,
    LlmChatResponse response,
  ) async =>
      const LlmHookAfterKeep();
}
