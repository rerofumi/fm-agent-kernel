/// User-space ProcessRunner, LeadAgent loop, and compile-time bootstrap.
library;

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';

/// Placeholder marker confirming workspace linkage to kernel and drivers.
String agentRuntimeWorkspaceBanner() =>
    'agent_runtime:0.1.0 -> (${agentDriversWorkspaceBanner()}, $agentKernelPackageVersion)';
