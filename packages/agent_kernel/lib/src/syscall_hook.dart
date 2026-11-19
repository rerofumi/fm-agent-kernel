import 'pcb.dart';
import 'syscall_error.dart';

/// Read-only context supplied to [SyscallHook] callbacks ([D-017]).
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

/// Decision returned by [SyscallHook.beforeSyscall] ([D-017]).
sealed class HookBeforeResult {
  const HookBeforeResult();
}

/// Permits syscall execution to proceed to Stage 4.
class HookAllow extends HookBeforeResult {
  const HookAllow();
}

/// Blocks syscall execution before Stage 4 approval and Stage 5 driver invocation ([D-002], [D-017]).
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

/// Kernel syscall hook interface executed at Stage 3 and Stage 6 ([D-002], [D-017]).
abstract interface class SyscallHook {
  String get name;

  /// Invoked at Stage 3 prior to Ring 2 approval gating.
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context);

  /// Invoked at Stage 6 after Stage 5 driver execution completes.
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  );
}

/// Convenience base class providing default allow/no-op implementations for [SyscallHook].
abstract class BaseSyscallHook implements SyscallHook {
  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async =>
      const HookAllow();

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {}
}
