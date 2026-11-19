import 'dart:async';
import 'dart:io';

import 'package:agent_acp/agent_acp.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  await runZonedGuarded<Future<void>>(
    () => _runDaemon(args),
    (Object error, StackTrace stackTrace) {
      stderr.writeln('[agent_os_daemon] Unhandled error: $error');
      stderr.writeln(stackTrace);
      exitCode = 1;
    },
    zoneSpecification: ZoneSpecification(
      // Enforce strict stdout purity ([D-018]): redirect any print() to stderr.
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        stderr.writeln(line);
      },
    ),
  );
}

Future<void> _runDaemon(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Default startup model in <provider>/<model> format.',
    )
    ..addOption(
      'ollama-url',
      help: 'Override Local Ollama base URL (e.g. http://192.168.0.5:11434/v1).',
    )
    ..addOption(
      'openrouter-url',
      help: 'Override OpenRouter base URL.',
    )
    ..addOption(
      'ollama-cloud-url',
      help: 'Override Ollama Cloud base URL.',
    )
    ..addOption(
      'system-file',
      help: 'Optional UTF-8 file appended to Segment 0 system instruction.',
    )
    ..addOption(
      'max-steps',
      defaultsTo: '32',
      help: 'Maximum ReAct steps per turn.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print usage to stderr.',
    );

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('Argument error: ${e.message}');
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (parsed.flag('help')) {
    stderr.writeln('FM Agent OS — ACP v1 stdio Daemon (agent_os_daemon)');
    stderr.writeln(parser.usage);
    return;
  }

  final maxSteps = int.tryParse(parsed.option('max-steps') ?? '32');
  if (maxSteps == null || maxSteps < 1) {
    stderr.writeln('Invalid --max-steps: ${parsed.option('max-steps')}');
    exitCode = 64;
    return;
  }

  final startupModel = parsed.option('model');
  if (startupModel != null && startupModel.trim().isNotEmpty) {
    final check = ModelIdentifier.parse(startupModel);
    if (!check.ok) {
      stderr.writeln('Invalid --model "$startupModel": ${check.error!.message}');
      exitCode = 64;
      return;
    }
  }

  String? systemInstruction;
  final systemFile = parsed.option('system-file');
  if (systemFile != null && systemFile.trim().isNotEmpty) {
    final file = File(p.normalize(p.absolute(systemFile.trim())));
    if (!file.existsSync()) {
      stderr.writeln('System instruction file not found: ${file.path}');
      exitCode = 64;
      return;
    }
    systemInstruction = file.readAsStringSync().trim();
  }

  final redactor = SecretRedactor()..registerFromEnvironment(Platform.environment);

  // JsonRpcPeer is the ONLY component holding `stdout` ([D-018]).
  final peer = JsonRpcPeer(
    input: stdin,
    output: stdout,
    redactor: redactor,
    onProtocolError: (msg) => stderr.writeln('[acp-rpc] $msg'),
  );

  final server = AcpServer(
    peer: peer,
    config: AcpServerConfig(
      startupModel: startupModel,
      systemInstruction: systemInstruction,
      localOllamaBaseUrl: parsed.option('ollama-url'),
      ollamaCloudBaseUrl: parsed.option('ollama-cloud-url'),
      openRouterBaseUrl: parsed.option('openrouter-url'),
      maxStepsPerTurn: maxSteps,
    ),
  );

  await peer.done;
  server.cancelActiveTurns('stdin EOF');
  await peer.waitForInFlightHandlers();
  await server.dispose();
  await peer.close();
  await stdout.flush();
  await stderr.flush();
  exitCode = 0;
}
