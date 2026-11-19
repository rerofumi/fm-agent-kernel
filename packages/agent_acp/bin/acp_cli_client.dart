import 'dart:io';

import 'package:agent_acp/agent_acp.dart';

Future<void> main(List<String> args) async {
  final runner = AcpCliRunner();
  exitCode = await runner.run(args);
}
