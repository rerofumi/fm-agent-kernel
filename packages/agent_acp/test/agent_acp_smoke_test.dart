import 'package:agent_acp/agent_acp.dart';
import 'package:test/test.dart';

void main() {
  test('agent_acp resolves workspace package dependencies', () {
    expect(agentAcpWorkspaceBanner(), startsWith('agent_acp:0.1.0'));
  });
}
