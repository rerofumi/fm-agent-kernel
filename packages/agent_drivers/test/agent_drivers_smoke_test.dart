import 'package:agent_drivers/agent_drivers.dart';
import 'package:test/test.dart';

void main() {
  test('agent_drivers resolves agent_kernel dependency', () {
    expect(
      agentDriversWorkspaceBanner(),
      equals('agent_drivers:0.1.0 -> agent_kernel:0.1.0'),
    );
  });
}
