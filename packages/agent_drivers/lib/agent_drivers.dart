/// Concrete I/O, VCS (jj), LLM, and Win32 Job Object drivers for FM Agent OS ([D-001], [D-022]).
library;

import 'package:agent_kernel/agent_kernel.dart';

export 'fs_jj_drivers.dart';
export 'llm_drivers.dart';

/// Placeholder marker confirming workspace linkage to [agent_kernel].
String agentDriversWorkspaceBanner() =>
    'agent_drivers:0.1.0 -> agent_kernel:$agentKernelPackageVersion';
