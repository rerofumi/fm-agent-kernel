import 'dart:io';

import 'package:agent_acp/src/kanban/kanban_cli_runner.dart';

Future<void> main(List<String> args) async {
  final runner = KanbanCliRunner();
  exitCode = await runner.run(args);
}
