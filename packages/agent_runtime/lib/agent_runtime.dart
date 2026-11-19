/// User-space ProcessRunner, LeadAgent loop, and compile-time bootstrap ([D-001], [D-005], [D-022]).
library;

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';

export 'src/kernel_bootstrap.dart';
export 'src/process_runner.dart';

/// Placeholder marker confirming workspace linkage to kernel and drivers.
String agentRuntimeWorkspaceBanner() =>
    'agent_runtime:0.1.0 -> (${agentDriversWorkspaceBanner()}, $agentKernelPackageVersion)';
