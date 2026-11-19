import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'cwd',
      abbr: 'c',
      help: 'Target workspace directory (defaults to current working directory).',
    )
    ..addOption(
      'model',
      abbr: 'm',
      help: 'Initial model in <provider>/<model> format (default: ${ModelResolver.stage1DefaultModelId}).',
    )
    ..addMultiOption(
      'prompt',
      abbr: 'p',
      splitCommas: false,
      help: 'Prompt or slash command (/model ..., /status, /quit) to execute sequentially in batch mode.',
    )
    ..addOption(
      'commands-file',
      help: 'Path to a UTF-8 file containing sequential prompts or slash commands (one per line).',
    )
    ..addOption(
      'session-id',
      help: 'Explicit session identifier for .agent_os/logs/<sessionId>/.',
    )
    ..addOption(
      'system-file',
      help: 'Optional UTF-8 file appended to the immutable Segment 0 system instruction.',
    )
    ..addOption(
      'ollama-url',
      help: 'Override Local Ollama base URL (e.g. http://192.168.0.5:11434/v1).',
    )
    ..addOption(
      'max-steps',
      defaultsTo: '32',
      help: 'Maximum ReAct steps per user turn.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Print reasoning/thought deltas and full tool arguments.',
    )
    ..addFlag(
      'fail-on-error',
      negatable: false,
      help: 'Exit with code 1 if any turn fails.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
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
    stdout.writeln('FM Agent OS — Step 1-1 Verification Harness');
    stdout.writeln(parser.usage);
    return;
  }

  final rawCwd = parsed.option('cwd');
  final workspaceHostRoot = rawCwd != null && rawCwd.trim().isNotEmpty
      ? p.normalize(p.absolute(rawCwd.trim()))
      : Directory.current.path;

  if (!Directory(workspaceHostRoot).existsSync()) {
    stderr.writeln('Workspace directory does not exist: $workspaceHostRoot');
    exitCode = 64;
    return;
  }

  final maxSteps = int.tryParse(parsed.option('max-steps') ?? '32');
  if (maxSteps == null || maxSteps < 1) {
    stderr.writeln('Invalid --max-steps value: ${parsed.option('max-steps')}');
    exitCode = 64;
    return;
  }

  var systemInstruction = KernelBootstrap.defaultStep1Instruction;
  final systemFile = parsed.option('system-file');
  if (systemFile != null && systemFile.trim().isNotEmpty) {
    final file = File(p.normalize(p.absolute(systemFile.trim())));
    if (!file.existsSync()) {
      stderr.writeln('System instruction file not found: ${file.path}');
      exitCode = 64;
      return;
    }
    final extra = file.readAsStringSync().trim();
    if (extra.isNotEmpty) {
      systemInstruction = '$systemInstruction\n\n$extra';
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

  final verbose = parsed.flag('verbose');
  final failOnError = parsed.flag('fail-on-error');

  final bootstrap = KernelBootstrap.create(
    KernelBootstrapConfig(
      workspaceHostRoot: workspaceHostRoot,
      sessionId: parsed.option('session-id'),
      startupModel: startupModel,
      systemInstruction: systemInstruction,
      localOllamaBaseUrl: parsed.option('ollama-url'),
      maxStepsPerTurn: maxSteps,
    ),
  );

  final batchInputs = <String>[
    ...parsed.multiOption('prompt'),
  ];
  final commandsFile = parsed.option('commands-file');
  if (commandsFile != null && commandsFile.trim().isNotEmpty) {
    final file = File(p.normalize(p.absolute(commandsFile.trim())));
    if (!file.existsSync()) {
      stderr.writeln('Commands file not found: ${file.path}');
      await bootstrap.dispose();
      exitCode = 64;
      return;
    }
    for (final line in const LineSplitter().convert(file.readAsStringSync())) {
      if (line.trim().isNotEmpty) {
        batchInputs.add(line.trim());
      }
    }
  }

  final printer = _HarnessEventPrinter(verbose: verbose);
  final eventSub = bootstrap.processRunner.events.listen(printer.onEvent);

  try {
    await _printBanner(bootstrap);

    var anyFailure = false;
    if (batchInputs.isNotEmpty) {
      for (final rawInput in batchInputs) {
        final action = await _handleInputLine(
          rawInput,
          bootstrap: bootstrap,
          printer: printer,
        );
        if (action.turnFailed) {
          anyFailure = true;
        }
        if (action.shouldQuit) {
          break;
        }
      }
    } else {
      final isTty = stdin.hasTerminal;
      if (isTty) {
        stdout.writeln('Type a prompt or /help for commands (/quit to exit).');
        stdout.write('> ');
      }
      await for (final line
          in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          if (isTty) {
            stdout.write('> ');
          }
          continue;
        }
        final action = await _handleInputLine(
          trimmed,
          bootstrap: bootstrap,
          printer: printer,
        );
        if (action.turnFailed) {
          anyFailure = true;
        }
        if (action.shouldQuit) {
          break;
        }
        if (isTty) {
          stdout.write('> ');
        }
      }
    }

    if (failOnError && anyFailure) {
      exitCode = 1;
    }
  } finally {
    await eventSub.cancel();
    await bootstrap.dispose();
    stdout.writeln('');
    stdout.writeln('=== Session Logs ===');
    stdout.writeln('Directory : ${bootstrap.auditLogger.sessionLogDirPath}');
    stdout.writeln('Syscalls  : ${bootstrap.auditLogger.syscallsLogPath}');
    stdout.writeln('LLM I/O   : ${bootstrap.auditLogger.llmIoLogPath}');
  }
}

Future<void> _printBanner(KernelBootstrap bootstrap) async {
  final jjInfo = await bootstrap.jjDriver.getAuditInfo();
  final envStatus = bootstrap.envLoader.configuredStatus(const <String>[
    'OPENROUTER_API_KEY',
    'OLLAMA_API_KEY',
  ]);
  final ollamaEndpoint = bootstrap.localOllamaEndpoint;

  stdout.writeln('=== FM Agent OS — Step 1-1 Harness ===');
  stdout.writeln('Session ID   : ${bootstrap.sessionId}');
  stdout.writeln('Workspace    : ${bootstrap.workspaceHostRoot}');
  stdout.writeln(
    'Active Model : ${bootstrap.modelResolver.effectiveModelString()}',
  );
  if (ollamaEndpoint != null) {
    stdout.writeln('Local Ollama : $ollamaEndpoint');
  }
  stdout.writeln(
    'Env Keys     : OPENROUTER_API_KEY=${envStatus['OPENROUTER_API_KEY'] == true ? 'configured' : 'unset'}, '
    'OLLAMA_API_KEY=${envStatus['OLLAMA_API_KEY'] == true ? 'configured' : 'unset'}',
  );
  stdout.writeln(
    'jj Head      : change=${jjInfo.jjChangeId ?? '(none)'} op=${jjInfo.jjOpId ?? '(none)'}',
  );
  stdout.writeln('Logs Dir     : ${bootstrap.auditLogger.sessionLogDirPath}');
  stdout.writeln('======================================');
}

class _InputAction {
  const _InputAction({
    this.shouldQuit = false,
    this.turnFailed = false,
  });

  final bool shouldQuit;
  final bool turnFailed;
}

Future<_InputAction> _handleInputLine(
  String rawInput, {
  required KernelBootstrap bootstrap,
  required _HarnessEventPrinter printer,
}) async {
  final trimmed = rawInput.trim();
  if (trimmed.isEmpty) {
    return const _InputAction();
  }

  if (trimmed == '/quit' || trimmed == '/exit') {
    return const _InputAction(shouldQuit: true);
  }

  if (trimmed == '/help') {
    stdout.writeln(
      'Commands: /model <provider>/<model> | /models | /status | /quit',
    );
    return const _InputAction();
  }

  if (trimmed == '/models' || trimmed == '/model') {
    stdout.writeln(
      'Current model: ${bootstrap.modelResolver.effectiveModelString()}',
    );
    stdout.writeln(
      'Providers: local-ollama/<model>, ollama-cloud/<model>, openrouter/<model>',
    );
    return const _InputAction();
  }

  if (trimmed.startsWith('/model ')) {
    final target = trimmed.substring('/model '.length).trim();
    final res = bootstrap.processRunner.setSessionModel(target);
    if (!res.ok) {
      stdout.writeln(
        '[Model Error] ${res.error!.code.codeName} (${res.error!.reason}): ${res.error!.message}',
      );
      return const _InputAction(turnFailed: true);
    }
    stdout.writeln('[Model] Switched to ${res.value!.canonicalId}');
    return const _InputAction();
  }

  if (trimmed == '/status') {
    final jjInfo = await bootstrap.jjDriver.getAuditInfo();
    final quota = bootstrap.pcb.quotaUsage;
    stdout.writeln(
      '[Status] session=${bootstrap.sessionId} '
      'model=${bootstrap.modelResolver.effectiveModelString()} '
      'tokens=${quota.totalTokensUsed} '
      'jjChange=${jjInfo.jjChangeId ?? '(none)'} '
      'jjOp=${jjInfo.jjOpId ?? '(none)'} '
      'logs=${bootstrap.auditLogger.sessionLogDirPath}',
    );
    return const _InputAction();
  }

  printer.resetTurn();
  final result = await bootstrap.processRunner.submitPrompt(userInput: trimmed);
  printer.finishTurn(result);
  return _InputAction(turnFailed: !result.ok);
}

class _HarnessEventPrinter {
  _HarnessEventPrinter({required this.verbose});

  final bool verbose;
  bool _wroteStreamText = false;
  bool _wroteThoughtHeader = false;

  void resetTurn() {
    _wroteStreamText = false;
    _wroteThoughtHeader = false;
  }

  void onEvent(AgentLoopEvent event) {
    switch (event) {
      case AgentTurnStartedEvent():
        stdout.writeln('');
        stdout.writeln(
          '[Turn ${event.turnIndex}] model=${event.model.canonicalId}',
        );
      case AgentThoughtDeltaEvent():
        if (verbose) {
          if (!_wroteThoughtHeader) {
            stdout.write('[Thought] ');
            _wroteThoughtHeader = true;
          }
          stdout.write(event.text);
        }
      case AgentTextDeltaEvent():
        if (_wroteThoughtHeader) {
          stdout.writeln('');
          _wroteThoughtHeader = false;
        }
        stdout.write(event.text);
        _wroteStreamText = true;
      case AgentToolCallStartedEvent():
        if (_wroteThoughtHeader) {
          stdout.writeln('');
          _wroteThoughtHeader = false;
        }
        if (_wroteStreamText) {
          stdout.writeln('');
          _wroteStreamText = false;
        }
        final argsText = verbose
            ? jsonEncode(event.arguments)
            : _summarizeArgs(event.arguments);
        stdout.writeln('[Tool ->] ${event.toolName}($argsText)');
      case AgentToolCallCompletedEvent():
        final errPart =
            event.errorCode != null ? ' error=${event.errorCode}' : '';
        stdout.writeln(
          '[Tool <-] ${event.toolName} ok=${event.ok}$errPart',
        );
      case AgentTurnCompletedEvent():
        if (_wroteThoughtHeader) {
          stdout.writeln('');
          _wroteThoughtHeader = false;
        }
        if (_wroteStreamText) {
          stdout.writeln('');
          _wroteStreamText = false;
        } else if (event.finalText.isNotEmpty) {
          stdout.writeln(event.finalText);
        }
      case AgentTurnFailedEvent():
        if (_wroteThoughtHeader) {
          stdout.writeln('');
          _wroteThoughtHeader = false;
        }
        if (_wroteStreamText) {
          stdout.writeln('');
          _wroteStreamText = false;
        }
    }
  }

  void finishTurn(AgentTurnResult result) {
    if (!result.ok) {
      final err = result.error!;
      stdout.writeln(
        '[Error] ${err.code.codeName} (${err.reason}): ${err.message}',
      );
      return;
    }

    final usage = result.usage;
    if (usage != null) {
      final cachedStr = usage.cachedTokens?.toString() ?? 'null';
      final hitRateStr = usage.cacheHitRate != null
          ? '${(usage.cacheHitRate! * 100).toStringAsFixed(2)}%'
          : 'n/a';
      final costStr = usage.costMicroUsd != null
          ? ' cost=\$${(usage.costMicroUsd! / 1e6).toStringAsFixed(6)}'
          : '';
      stdout.writeln(
        '[Usage] ${result.model?.canonicalId} | '
        'prompt=${usage.promptTokens} (cached=$cachedStr, hit=$hitRateStr) | '
        'completion=${usage.completionTokens} | total=${usage.totalTokens} | '
        'steps=${result.steps} | tools=${result.toolCallsExecuted} | '
        '${usage.durationMs}ms$costStr',
      );
    }
  }

  static String _summarizeArgs(Map<String, dynamic> args) {
    final encoded = jsonEncode(args);
    if (encoded.length <= 120) {
      return encoded;
    }
    return '${encoded.substring(0, 117)}...';
  }
}
