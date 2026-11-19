/// ACP v1 stdio server, permission broker, and CLI client package.
library;

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';

/// Placeholder marker confirming full workspace dependency resolution.
String agentAcpWorkspaceBanner() =>
    'agent_acp:0.1.0 -> ${agentRuntimeWorkspaceBanner()} (${agentDriversWorkspaceBanner()}, $agentKernelPackageVersion)';
