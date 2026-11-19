import 'package:agent_runtime/agent_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('agent_runtime resolves agent_kernel and agent_drivers', () {
    expect(
      agentRuntimeWorkspaceBanner(),
      contains('agent_drivers:0.1.0 -> agent_kernel:0.1.0'),
    );
  });
}
