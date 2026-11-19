/// ACP v1 stdio server, permission broker, and CLI client package ([D-018]..[D-022]).
library;

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';

export 'src/acp_approval_handler.dart';
export 'src/acp_event_mapper.dart';
export 'src/acp_server.dart';
export 'src/cli/acp_cli_runner.dart';
export 'src/json_rpc_peer.dart';

/// Workspace dependency resolution banner.
String agentAcpWorkspaceBanner() =>
    'agent_acp:0.1.0 -> ${agentRuntimeWorkspaceBanner()} (${agentDriversWorkspaceBanner()}, $agentKernelPackageVersion)';
