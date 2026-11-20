/// Ring 0 TCB kernel library for FM Agent OS ([D-001]..[D-008], [D-010], [D-011], [D-017], [D-020]).
library;

export 'src/approval_gate.dart';
export 'src/audit_logger.dart';
export 'src/cancellation.dart';
export 'src/capability.dart';
export 'src/context_memory.dart';
export 'src/context_pager.dart';
export 'src/dirty_swap.dart';
export 'src/io_payload_capper.dart';
export 'src/llm_driver.dart';
export 'src/mailbox.dart';
export 'src/mcp_contract.dart';
export 'src/pcb.dart';
export 'src/process_profile.dart';
export 'src/quota.dart';
export 'src/skill_registry.dart';
export 'src/stacked_task.dart';
export 'src/supervision.dart';
export 'src/syscall_error.dart';
export 'src/syscall_gate.dart';
export 'src/syscall_hook.dart';
export 'src/vfs_namespace.dart';
export 'src/web_driver.dart';

/// Package version marker.
const String agentKernelPackageVersion = '0.1.0';
