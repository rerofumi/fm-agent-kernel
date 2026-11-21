import 'dart:async';
import 'dart:io';

import 'package:agent_acp/agent_acp.dart';
import 'package:agent_acp/src/wire/wire_command_splitter.dart';
import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
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
      'openai-url',
      help: 'Override OpenAI base URL.',
    )
    ..addOption(
      'gemini-url',
      help: 'Override Gemini base URL.',
    )
    ..addOption(
      'nous-url',
      help: 'Override Nous Portal base URL.',
    )
    ..addOption(
      'openai-compat-url',
      help: 'Override OpenAI-compatible local LLM base URL.',
    )
    ..addOption(
      'system-file',
      help: 'Optional UTF-8 file appended to Segment 0 system instruction.',
    )
    ..addOption(
      'max-steps',
      defaultsTo: '64',
      help: 'Maximum ReAct steps per turn.',
    )
    ..addOption(
      'max-syscalls',
      help:
          'Maximum total syscalls per LeadAgent turn (positive integer; defaults to max(256, maxSteps * 8)).',
    )
    ..addMultiOption(
      'skills-dir',
      splitCommas: false,
      help:
          'External directory containing <skill>/SKILL.md packages (repeatable; earlier entries win).',
    )
    ..addOption(
      'max-context-tokens',
      help: 'Session-wide effective context window cap (positive integer).',
    )
    ..addMultiOption(
      'mcp-server',
      splitCommas: false,
      help:
          'Register a stdio MCP server (JSON object or "name=command [args...]").',
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

  final maxSteps = int.tryParse(parsed.option('max-steps') ?? '64');
  if (maxSteps == null || maxSteps < 1) {
    stderr.writeln('Invalid --max-steps: ${parsed.option('max-steps')}');
    exitCode = 64;
    return;
  }

  int? maxSyscalls;
  final rawMaxSyscalls = parsed.option('max-syscalls');
  if (rawMaxSyscalls != null && rawMaxSyscalls.trim().isNotEmpty) {
    maxSyscalls = int.tryParse(rawMaxSyscalls.trim());
    if (maxSyscalls == null || maxSyscalls < 1) {
      stderr.writeln('Invalid --max-syscalls: $rawMaxSyscalls');
      exitCode = 64;
      return;
    }
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
  final envLoader = LlmEnvLoader(redactor: redactor);
  final modelsLoadResult = ModelsConfigLoader().load();
  for (final warning in modelsLoadResult.warnings) {
    stderr.writeln('[models_config] $warning');
  }

  final openAiCompatUrl = parsed.option('openai-compat-url');
  final startupPolicy = ModelPolicy(
    config: modelsLoadResult.config,
    envLoader: envLoader,
    explicitOpenAiCompatBaseUrl: openAiCompatUrl,
  );

  final hasStartupModel = startupModel != null && startupModel.trim().isNotEmpty;
  final targetStartupModel = hasStartupModel
      ? ModelIdentifier.parse(startupModel).value!
      : ModelIdentifier.parse(ModelResolver.stage1DefaultModelId).value!;
  final startupPolicyErr = startupPolicy.validateModel(targetStartupModel);
  if (startupPolicyErr != null) {
    if (hasStartupModel) {
      stderr.writeln('Invalid --model "$startupModel": ${startupPolicyErr.message}');
    } else {
      stderr.writeln(
        'Default startup model "${ModelResolver.stage1DefaultModelId}" is disabled or excluded by .agent_os/models.json. Specify an allowed model via --model <providerId>/<modelName>.',
      );
    }
    exitCode = 64;
    return;
  }

  int? maxContextTokens;
  final rawMaxCtx = parsed.option('max-context-tokens');
  if (rawMaxCtx != null && rawMaxCtx.trim().isNotEmpty) {
    maxContextTokens = int.tryParse(rawMaxCtx.trim());
    if (maxContextTokens == null || maxContextTokens <= 0) {
      stderr.writeln('Invalid --max-context-tokens: $rawMaxCtx');
      exitCode = 64;
      return;
    }
  }

  final mcpServers = <McpServerSpec>[];
  for (final rawMcp in parsed.multiOption('mcp-server')) {
    if (rawMcp.trim().isEmpty) {
      continue;
    }
    try {
      final wireSpec = parseWireMcpServerSpec(rawMcp);
      for (final envVar in wireSpec.env) {
        redactor.registerSecret(envVar.value);
      }
      mcpServers.add(
        McpServerSpec(
          name: wireSpec.name,
          command: wireSpec.command,
          args: wireSpec.args,
          env: wireSpec.env
              .map((e) => McpEnvVar(name: e.name, value: e.value))
              .toList(growable: false),
        ),
      );
    } on FormatException catch (e) {
      stderr.writeln('Invalid --mcp-server: ${e.message}');
      exitCode = 64;
      return;
    }
  }

  final catalogService = ModelCatalogService(
    redactor: redactor,
    localOllamaBaseUrl: parsed.option('ollama-url'),
    ollamaCloudBaseUrl: parsed.option('ollama-cloud-url'),
    openRouterBaseUrl: parsed.option('openrouter-url'),
    openAiBaseUrl: parsed.option('openai-url'),
    geminiBaseUrl: parsed.option('gemini-url'),
    nousPortalBaseUrl: parsed.option('nous-url'),
    openAiCompatBaseUrl: openAiCompatUrl,
    onWarning: (msg) => stderr.writeln('[model_catalog] $msg'),
  );

  // JsonRpcPeer is the ONLY component holding `stdout` ([D-018]).
  final peer = JsonRpcPeer(
    input: stdin,
    output: stdout,
    redactor: redactor,
    onProtocolError: (msg) => stderr.writeln('[acp-rpc] $msg'),
  );

  final skillsDirs = parsed
      .multiOption('skills-dir')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);

  final server = AcpServer(
    peer: peer,
    config: AcpServerConfig(
      startupModel: startupModel,
      systemInstruction: systemInstruction,
      localOllamaBaseUrl: parsed.option('ollama-url'),
      ollamaCloudBaseUrl: parsed.option('ollama-cloud-url'),
      openRouterBaseUrl: parsed.option('openrouter-url'),
      openAiBaseUrl: parsed.option('openai-url'),
      geminiBaseUrl: parsed.option('gemini-url'),
      nousPortalBaseUrl: parsed.option('nous-url'),
      openAiCompatBaseUrl: openAiCompatUrl,
      modelCatalogService: catalogService,
      maxStepsPerTurn: maxSteps,
      maxSyscallsPerTurn: maxSyscalls,
      skillsDirs: skillsDirs,
      skillsDirEnv: Platform.environment['AGENT_OS_SKILLS_DIR'],
      maxContextTokens: maxContextTokens,
      mcpServers: mcpServers,
    ),
  );

  // Warm the in-memory model catalog once at startup after AcpServer handlers are wired.
  await catalogService.resolveOptions(startupPolicy);

  await peer.done;
  server.cancelActiveTurns('stdin EOF');
  await peer.waitForInFlightHandlers();
  await server.dispose();
  catalogService.close();
  await peer.close();
  await stdout.flush();
  await stderr.flush();
  exitCode = 0;
}
