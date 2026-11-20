import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../json_rpc_peer.dart';
import '../wire/wire_command_splitter.dart';
import '../wire/wire_redactor.dart';

/// Parsed permission policy supporting interactive prompts, fixed decisions,
/// ordered sequences (`reject_once,allow_once`), and per-operation rules
/// (`squash=reject_once,exec=allow_once`) ([D-021]).
class CliPermissionPolicy {
  CliPermissionPolicy._({
    required this.rawSpec,
    this.isInteractive = false,
    List<String> sequence = const <String>[],
    Map<String, String> rules = const <String, String>{},
  })  : _sequence = List<String>.from(sequence),
        _rules = Map<String, String>.from(rules);

  final String rawSpec;
  final bool isInteractive;
  final List<String> _sequence;
  final Map<String, String> _rules;
  int _seqCursor = 0;

  /// Parses `--permission-policy` value (`interactive`, `allow_once`, `reject_once`, etc.).
  static CliPermissionPolicy parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty ||
        trimmed.toLowerCase() == 'interactive' ||
        trimmed.toLowerCase() == 'prompt') {
      return CliPermissionPolicy._(rawSpec: 'interactive', isInteractive: true);
    }

    final parts = trimmed
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      throw FormatException('Empty permission policy "$raw".');
    }

    if (parts.any((part) => part.contains('='))) {
      final rules = <String, String>{};
      for (final part in parts) {
        final eq = part.indexOf('=');
        if (eq <= 0 || eq == part.length - 1) {
          throw FormatException(
            'Invalid rule "$part" in permission policy "$raw". Expected key=decision.',
          );
        }
        final key = part.substring(0, eq).trim().toLowerCase();
        final decision = _normalizeOption(part.substring(eq + 1));
        rules[key] = decision;
      }
      return CliPermissionPolicy._(rawSpec: trimmed, rules: rules);
    }

    final seq = parts.map(_normalizeOption).toList(growable: false);
    return CliPermissionPolicy._(rawSpec: trimmed, sequence: seq);
  }

  /// Resolves a deterministic decision when [isInteractive] is `false`.
  String resolveAutomatic({
    required String title,
    required String kind,
    required String contentText,
  }) {
    if (_rules.isNotEmpty) {
      final hay = '${title.toLowerCase()} ${kind.toLowerCase()} ${contentText.toLowerCase()}';
      for (final entry in _rules.entries) {
        if (entry.key == 'default' || entry.key == '*') {
          continue;
        }
        if (hay.contains(entry.key)) {
          return entry.value;
        }
      }
      return _rules['default'] ?? _rules['*'] ?? 'reject_once';
    }

    if (_sequence.isEmpty) {
      return 'reject_once';
    }
    final idx = _seqCursor < _sequence.length ? _seqCursor : _sequence.length - 1;
    _seqCursor += 1;
    return _sequence[idx];
  }

  static String _normalizeOption(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'allow' || 'allow_once' || 'y' || 'yes' => 'allow_once',
      'allow_always' || 'always' || 'a' => 'allow_always',
      'deny' || 'reject' || 'reject_once' || 'n' || 'no' => 'reject_once',
      _ => throw FormatException(
          'Unknown permission decision "$raw". Expected interactive|allow_once|allow_always|reject_once.',
        ),
    };
  }
}

/// Launch specification for the child `agent_os_daemon` process ([D-021], [D-022]).
class DaemonLaunchSpec {
  const DaemonLaunchSpec({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;
}

/// Interactive REPL and deterministic batch runner for `acp_cli_client` ([D-021]).
class AcpCliRunner {
  AcpCliRunner({
    StringSink? out,
    StringSink? err,
    Stream<List<int>>? stdinStream,
    bool? useAnsiColor,
    bool? stdinHasTerminal,
  })  : _out = out ?? stdout,
        _err = err ?? stderr,
        _stdinStream = stdinStream ?? stdin,
        _useAnsiColor = useAnsiColor ?? stdout.supportsAnsiEscapes,
        _stdinHasTerminal = stdinHasTerminal ?? stdin.hasTerminal;

  final StringSink _out;
  final StringSink _err;
  final Stream<List<int>> _stdinStream;
  final bool _useAnsiColor;
  final bool _stdinHasTerminal;

  /// Resolves the daemon executable path (`--daemon`, sibling `.exe`, `build/`, or dev `dart run`).
  static DaemonLaunchSpec? resolveDaemonLaunch({
    String? explicitDaemonPath,
    String? model,
    String? ollamaUrl,
    int? maxSteps,
    List<String> skillsDirs = const <String>[],
    int? maxContextTokens,
    List<String> mcpServerArgs = const <String>[],
  }) {
    final extraArgs = <String>[
      if (model != null && model.trim().isNotEmpty) ...<String>[
        '--model',
        model.trim(),
      ],
      if (ollamaUrl != null && ollamaUrl.trim().isNotEmpty) ...<String>[
        '--ollama-url',
        ollamaUrl.trim(),
      ],
      if (maxSteps != null) ...<String>['--max-steps', '$maxSteps'],
      for (final dir in skillsDirs)
        if (dir.trim().isNotEmpty) ...<String>['--skills-dir', dir.trim()],
      if (maxContextTokens != null) ...<String>[
        '--max-context-tokens',
        '$maxContextTokens',
      ],
      for (final spec in mcpServerArgs)
        if (spec.trim().isNotEmpty) ...<String>['--mcp-server', spec.trim()],
    ];

    if (explicitDaemonPath != null && explicitDaemonPath.trim().isNotEmpty) {
      final resolved = p.normalize(p.absolute(explicitDaemonPath.trim()));
      if (!File(resolved).existsSync()) {
        return null;
      }
      return DaemonLaunchSpec(executable: resolved, arguments: extraArgs);
    }

    final siblingExe = p.join(
      p.dirname(Platform.resolvedExecutable),
      'agent_os_daemon.exe',
    );
    if (File(siblingExe).existsSync()) {
      return DaemonLaunchSpec(executable: siblingExe, arguments: extraArgs);
    }

    final buildExe = p.join(
      Directory.current.path,
      'build',
      'agent_os_daemon.exe',
    );
    if (File(buildExe).existsSync()) {
      return DaemonLaunchSpec(executable: buildExe, arguments: extraArgs);
    }

    final devScript = p.join(
      Directory.current.path,
      'packages',
      'agent_acp',
      'bin',
      'agent_os_daemon.dart',
    );
    if (File(devScript).existsSync()) {
      return DaemonLaunchSpec(
        executable: Platform.resolvedExecutable,
        arguments: <String>['run', devScript, ...extraArgs],
      );
    }

    return null;
  }

  /// Builds the CLI [ArgParser] for `acp_cli_client`.
  static ArgParser buildArgParser() {
    return ArgParser()
      ..addOption(
        'cwd',
        abbr: 'c',
        help: 'Target Jujutsu (.jj) repository path (defaults to current directory).',
      )
      ..addOption(
        'daemon',
        help: 'Path to agent_os_daemon.exe (auto-discovers sibling/build .exe when omitted).',
      )
      ..addOption(
        'model',
        abbr: 'm',
        help: 'Initial model in <provider>/<model> format.',
      )
      ..addOption(
        'ollama-url',
        help: 'Override Local Ollama base URL passed to the daemon.',
      )
      ..addOption(
        'max-steps',
        defaultsTo: '32',
        help: 'Maximum ReAct steps per user turn.',
      )
      ..addMultiOption(
        'skills-dir',
        splitCommas: false,
        help:
            'External directory containing <skill>/SKILL.md packages passed to the daemon (repeatable).',
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
      ..addMultiOption(
        'batch-commands',
        splitCommas: false,
        help:
            'File path or inline prompt/slash command lines for deterministic batch verification.',
      )
      ..addOption(
        'permission-policy',
        defaultsTo: 'interactive',
        help:
            'Approval policy: interactive | allow_once | allow_always | reject_once | <comma-seq/rules>.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show verbose tool metadata and daemon stderr diagnostics.',
      )
      ..addFlag(
        'fail-on-error',
        negatable: false,
        help: 'Exit with code 1 if any turn or command fails.',
      )
      ..addFlag(
        'no-color',
        negatable: false,
        help: 'Disable ANSI escape colors in output.',
      )
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show usage information.',
      );
  }

  /// Runs `acp_cli_client` with [args] and returns the process exit code.
  Future<int> run(List<String> args) async {
    final parser = buildArgParser();
    final ArgResults parsed;
    try {
      parsed = parser.parse(args);
    } on FormatException catch (e) {
      _err.writeln('Argument error: ${e.message}');
      _err.writeln(parser.usage);
      return 64;
    }

    if (parsed.flag('help')) {
      _out.writeln('FM Agent OS — ACP v1 CLI Client (acp_cli_client)');
      _out.writeln(parser.usage);
      return 0;
    }

    final rawCwd = parsed.option('cwd');
    final cwd = rawCwd != null && rawCwd.trim().isNotEmpty
        ? p.normalize(p.absolute(rawCwd.trim()))
        : p.normalize(Directory.current.path);
    if (!Directory(cwd).existsSync()) {
      _err.writeln('Target cwd does not exist: $cwd');
      return 64;
    }

    final startupModel = parsed.option('model');
    if (startupModel != null && startupModel.trim().isNotEmpty) {
      final check = ModelIdentifier.parse(startupModel);
      if (!check.ok) {
        _err.writeln('Invalid --model "$startupModel": ${check.error!.message}');
        return 64;
      }
    }

    final maxSteps = int.tryParse(parsed.option('max-steps') ?? '32');
    if (maxSteps == null || maxSteps < 1) {
      _err.writeln('Invalid --max-steps: ${parsed.option('max-steps')}');
      return 64;
    }

    int? maxContextTokens;
    final rawMaxCtx = parsed.option('max-context-tokens');
    if (rawMaxCtx != null && rawMaxCtx.trim().isNotEmpty) {
      maxContextTokens = int.tryParse(rawMaxCtx.trim());
      if (maxContextTokens == null || maxContextTokens <= 0) {
        _err.writeln('Invalid --max-context-tokens: $rawMaxCtx');
        return 64;
      }
    }

    final wireRedactor = WireSecretRedactor();
    final mcpServerArgs = parsed
        .multiOption('mcp-server')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final mcpServers = <WireMcpServerSpec>[];
    for (final rawMcp in mcpServerArgs) {
      try {
        mcpServers.add(parseWireMcpServerSpec(rawMcp, redactor: wireRedactor));
      } on FormatException catch (e) {
        _err.writeln('Invalid --mcp-server: ${e.message}');
        return 64;
      }
    }

    var permissionPolicy = CliPermissionPolicy.parse('interactive');
    try {
      permissionPolicy = CliPermissionPolicy.parse(
        parsed.option('permission-policy') ?? 'interactive',
      );
    } on FormatException catch (e) {
      _err.writeln('Invalid --permission-policy: ${e.message}');
      return 64;
    }

    final batchInputs = <String>[];
    for (final item in parsed.multiOption('batch-commands')) {
      final trimmed = item.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final file = File(trimmed);
      if (file.existsSync()) {
        for (final line
            in const LineSplitter().convert(file.readAsStringSync())) {
          final clean = line.trim();
          if (clean.isNotEmpty) {
            batchInputs.add(clean);
          }
        }
      } else {
        for (final line in const LineSplitter().convert(item)) {
          final clean = line.trim();
          if (clean.isNotEmpty) {
            batchInputs.add(clean);
          }
        }
      }
    }

    final verbose = parsed.flag('verbose');
    final failOnError = parsed.flag('fail-on-error');
    final useColor = _useAnsiColor && !parsed.flag('no-color');
    final ollamaUrl = parsed.option('ollama-url');
    final skillsDirs = parsed
        .multiOption('skills-dir')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    final launchSpec = resolveDaemonLaunch(
      explicitDaemonPath: parsed.option('daemon'),
      model: startupModel,
      ollamaUrl: ollamaUrl,
      maxSteps: maxSteps,
      skillsDirs: skillsDirs,
      maxContextTokens: maxContextTokens,
      mcpServerArgs: mcpServerArgs,
    );
    if (launchSpec == null) {
      _err.writeln(
        'Could not locate agent_os_daemon executable. Pass --daemon <path>.',
      );
      return 64;
    }

    final childEnv = <String, String>{};
    if (ollamaUrl != null && ollamaUrl.trim().isNotEmpty) {
      childEnv['OLLAMA_HOST'] = ollamaUrl.trim();
    }

    final Process daemonProc;
    try {
      daemonProc = await Process.start(
        launchSpec.executable,
        launchSpec.arguments,
        workingDirectory: cwd,
        environment: childEnv.isEmpty ? null : childEnv,
        includeParentEnvironment: true,
        runInShell: false,
      );
    } catch (e) {
      _err.writeln('Failed to start daemon "${launchSpec.executable}": $e');
      return 1;
    }

    final stderrBuffer = StringBuffer();
    final stderrSub = daemonProc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (verbose) {
        _err.writeln('[daemon] $line');
      } else if (stderrBuffer.length < 4096) {
        stderrBuffer.writeln(line);
      }
    });

    final peer = JsonRpcPeer(
      input: daemonProc.stdout,
      output: daemonProc.stdin,
      onProtocolError: (msg) {
        if (verbose) {
          _err.writeln('[rpc] $msg');
        }
      },
    );

    final needStdinReader =
        batchInputs.isEmpty || permissionPolicy.isInteractive;
    final stdinRouter = needStdinReader ? _StdinLineRouter(_stdinStream) : null;

    final state = _CliSessionState(
      out: _out,
      err: _err,
      useColor: useColor,
      verbose: verbose,
      permissionPolicy: permissionPolicy,
      stdinRouter: stdinRouter,
    );

    peer.onNotification = (method, params) {
      if (method == 'session/update') {
        state.handleSessionUpdate(params);
      }
    };
    peer.onRequest = (method, params) async {
      if (method == 'session/request_permission') {
        return state.handlePermissionRequest(params);
      }
      throw JsonRpcException(
        JsonRpcErrorCodes.methodNotFound,
        'Client does not implement method: $method',
      );
    };

    StreamSubscription<ProcessSignal>? sigintSub;
    var exitAfterShutdown = false;
    try {
      try {
        sigintSub = ProcessSignal.sigint.watch().listen((_) {
          if (state.turnActive && state.sessionId != null) {
            _out.writeln('');
            _out.writeln('[Ctrl+C] Sending session/cancel...');
            peer.sendNotification('session/cancel', <String, dynamic>{
              'sessionId': state.sessionId,
            });
          } else {
            exitAfterShutdown = true;
            stdinRouter?.close();
          }
        });
      } catch (_) {
        // SIGINT watch may be unsupported in non-console test runners.
      }

      // 1. ACP initialize handshake
      final initRaw = await peer.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
        'clientInfo': <String, dynamic>{
          'name': 'acp_cli_client',
          'version': '0.1.0',
        },
        'clientCapabilities': const <String, dynamic>{},
      });
      final initMap = _asStringMap(initRaw);
      final agentInfo = _asStringMap(initMap['agentInfo']);

      // 2. ACP session/new
      final newRaw = await peer.sendRequest('session/new', <String, dynamic>{
        'cwd': cwd,
        'mcpServers': mcpServers.map((s) => s.toJson()).toList(growable: false),
        if (maxContextTokens != null)
          '_meta': <String, dynamic>{
            'fm_agent_os/maxContextTokens': maxContextTokens,
          },
      });
      final newMap = _asStringMap(newRaw);
      state.sessionId = newMap['sessionId'] as String?;
      state.updateConfigOptions(newMap['configOptions']);
      state.updateJjMeta(_asStringMap(_asStringMap(newMap['_meta'])['fm_agent_os/jj']));

      if (startupModel != null && startupModel.trim().isNotEmpty) {
        final cfgRaw = await peer.sendRequest(
          'session/set_config_option',
          <String, dynamic>{
            'sessionId': state.sessionId,
            'configId': 'model',
            'value': startupModel.trim(),
          },
        );
        final cfgMap = _asStringMap(cfgRaw);
        state.updateConfigOptions(cfgMap['configOptions']);
      }

      _printBanner(
        agentName: (agentInfo['name'] as String?) ?? 'fm-agent-os',
        agentVersion: (agentInfo['version'] as String?) ?? '0.1.0',
        daemonExe: launchSpec.executable,
        cwd: cwd,
        state: state,
      );

      var anyFailure = false;
      if (batchInputs.isNotEmpty) {
        for (final input in batchInputs) {
          if (exitAfterShutdown) {
            break;
          }
          final action = await _dispatchLine(
            input,
            peer: peer,
            state: state,
          );
          if (action.failed) {
            anyFailure = true;
          }
          if (action.shouldQuit) {
            break;
          }
        }
      } else {
        if (_stdinHasTerminal) {
          _out.writeln('Type a prompt or /help for commands (/quit to exit).');
          _out.write('> ');
        }
        while (!exitAfterShutdown) {
          final line = await stdinRouter!.readReplLine();
          if (line == null) {
            break;
          }
          final trimmed = line.trim();
          if (trimmed.isEmpty) {
            if (_stdinHasTerminal) {
              _out.write('> ');
            }
            continue;
          }
          final action = await _dispatchLine(
            trimmed,
            peer: peer,
            state: state,
          );
          if (action.failed) {
            anyFailure = true;
          }
          if (action.shouldQuit) {
            break;
          }
          if (_stdinHasTerminal) {
            _out.write('> ');
          }
        }
      }

      // Close daemon stdin so daemon detects EOF and shuts down cleanly.
      await peer.close(closeOutput: true);
      final procCode = await daemonProc.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          daemonProc.kill();
          return -1;
        },
      );
      if (procCode != 0) {
        _err.writeln('Daemon exited with code $procCode.');
        if (stderrBuffer.isNotEmpty && !verbose) {
          _err.writeln(stderrBuffer.toString().trimRight());
        }
        return procCode > 0 ? procCode : 1;
      }
      if (failOnError && anyFailure) {
        return 1;
      }
      return 0;
    } on JsonRpcException catch (e) {
      _err.writeln('[ACP Error ${e.code}] ${e.message}');
      await peer.close(closeOutput: true);
      await daemonProc.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          daemonProc.kill();
          return 1;
        },
      );
      return 1;
    } finally {
      await sigintSub?.cancel();
      await stdinRouter?.close();
      await stderrSub.cancel();
    }
  }

  void _printBanner({
    required String agentName,
    required String agentVersion,
    required String daemonExe,
    required String cwd,
    required _CliSessionState state,
  }) {
    _out.writeln('=== FM Agent OS — ACP CLI Client ===');
    _out.writeln('Agent      : $agentName $agentVersion');
    _out.writeln('Daemon     : $daemonExe');
    _out.writeln('Workspace  : $cwd');
    _out.writeln('Session ID : ${state.sessionId ?? '(none)'}');
    _out.writeln('Model      : ${state.currentModel ?? '(default)'}');
    _out.writeln(
      'jj Head    : change=${state.jjChangeId ?? '(none)'} op=${state.jjOpId ?? '(none)'} tx=${state.txState ?? 'readOnly'}',
    );
    _out.writeln('Policy     : ${state.permissionPolicy.rawSpec}');
    _out.writeln('====================================');
  }

  Future<_LineAction> _dispatchLine(
    String line, {
    required JsonRpcPeer peer,
    required _CliSessionState state,
  }) async {
    final trimmed = line.trim();
    if (trimmed == '/quit' || trimmed == '/exit') {
      return const _LineAction(shouldQuit: true);
    }

    if (trimmed == '/help') {
      _out.writeln(
        'Commands: /model [<provider>/<model>] | /models | /rollback [opId] | '
        '/status | /cancel | /pause | /resume [msg] | /kill [pid] | /ps | '
        '/stack list|create|edit|sync | /diff [revOrTaskId] | /permission <policy> | /quit',
      );
      return const _LineAction();
    }

    if (trimmed == '/model' || trimmed == '/models') {
      _out.writeln('Current model: ${state.currentModel ?? '(unset)'}');
      _out.writeln('Available models:');
      for (final opt in state.modelOptions) {
        final marker = opt['value'] == state.currentModel ? '*' : ' ';
        _out.writeln('  $marker ${opt['value']} (${opt['name']})');
      }
      return const _LineAction();
    }

    if (trimmed.startsWith('/model ')) {
      final target = trimmed.substring('/model '.length).trim();
      try {
        final raw = await peer.sendRequest(
          'session/set_config_option',
          <String, dynamic>{
            'sessionId': state.sessionId,
            'configId': 'model',
            'value': target,
          },
        );
        final map = _asStringMap(raw);
        state.updateConfigOptions(map['configOptions']);
        _out.writeln('[Model] Switched to ${state.currentModel}');
        return const _LineAction();
      } on JsonRpcException catch (e) {
        _out.writeln('[Model Error] (${e.code}) ${e.message}');
        return const _LineAction(failed: true);
      }
    }

    if (trimmed == '/permission' || trimmed.startsWith('/permission ')) {
      if (trimmed == '/permission') {
        _out.writeln('Current permission policy: ${state.permissionPolicy.rawSpec}');
        return const _LineAction();
      }
      final spec = trimmed.substring('/permission '.length).trim();
      try {
        state.permissionPolicy = CliPermissionPolicy.parse(spec);
        _out.writeln(
          '[Permission] Policy set to ${state.permissionPolicy.rawSpec}',
        );
        return const _LineAction();
      } on FormatException catch (e) {
        _out.writeln('[Permission Error] ${e.message}');
        return const _LineAction(failed: true);
      }
    }

    if (trimmed == '/rollback' || trimmed.startsWith('/rollback ')) {
      final targetOpId = trimmed == '/rollback'
          ? null
          : trimmed.substring('/rollback '.length).trim();
      try {
        final raw = await peer.sendRequest(
          '_fm_agent_os/tx_rollback',
          <String, dynamic>{
            'sessionId': state.sessionId,
            if (targetOpId != null && targetOpId.isNotEmpty)
              'targetOpId': targetOpId,
          },
        );
        final map = _asStringMap(raw);
        state.jjOpId = map['currentOpId'] as String?;
        state.jjChangeId = map['workingChangeId'] as String?;
        state.txState = map['state'] as String?;
        _out.writeln(
          '[Rollback] restoredOpId=${map['restoredOpId']} '
          'currentOpId=${map['currentOpId']} '
          'change=${map['workingChangeId']} '
          'tx=${map['state']}',
        );
        return const _LineAction();
      } on JsonRpcException catch (e) {
        _out.writeln('[Rollback Error] (${e.code}) ${e.message}');
        return const _LineAction(failed: true);
      }
    }

    if (trimmed == '/status') {
      try {
        final raw = await peer.sendRequest(
          '_fm_agent_os/status',
          <String, dynamic>{'sessionId': state.sessionId},
        );
        final map = _asStringMap(raw);
        state.jjChangeId = map['jjChangeId'] as String?;
        state.jjOpId = map['jjOpId'] as String?;
        state.txState = map['txState'] as String?;
        state.totalTokensUsed =
            (map['totalTokensUsed'] as num?)?.toInt() ?? state.totalTokensUsed;
        _out.writeln(
          '[Status] session=${map['sessionId']} '
          'model=${map['model']} '
          'jjChange=${map['jjChangeId'] ?? '(none)'} '
          'jjOp=${map['jjOpId'] ?? '(none)'} '
          'tx=${map['txState']} '
          'totalTokens=${map['totalTokensUsed']} '
          '${state.lastUsageSummary ?? ''}',
        );
        return const _LineAction();
      } on JsonRpcException {
        _out.writeln(
          '[Status] session=${state.sessionId} '
          'model=${state.currentModel} '
          'jjChange=${state.jjChangeId ?? '(none)'} '
          'jjOp=${state.jjOpId ?? '(none)'} '
          'tx=${state.txState ?? 'unknown'} '
          'totalTokens=${state.totalTokensUsed} '
          '${state.lastUsageSummary ?? ''}',
        );
        return const _LineAction();
      }
    }

    if (trimmed == '/cancel') {
      peer.sendNotification('session/cancel', <String, dynamic>{
        'sessionId': state.sessionId,
      });
      _out.writeln('[Cancel] Sent session/cancel.');
      return const _LineAction();
    }

    final signalOrPs = await _tryHandleSignalOrPsCommand(
      trimmed,
      peer: peer,
      state: state,
    );
    if (signalOrPs != null) {
      return signalOrPs;
    }

    if (trimmed == '/stack' || trimmed.startsWith('/stack ')) {
      return _handleStackCommand(trimmed, peer: peer, state: state);
    }

    if (trimmed == '/diff' || trimmed.startsWith('/diff ')) {
      return _handleDiffCommand(trimmed, peer: peer, state: state);
    }

    // Send prompt turn
    state.resetTurnDisplay();
    state.turnActive = true;
    state.stdinRouter?.setMidTurnCommandHandler((cmdLine) {
      final cmdTrimmed = cmdLine.trim();
      if (cmdTrimmed == '/cancel') {
        peer.sendNotification('session/cancel', <String, dynamic>{
          'sessionId': state.sessionId,
        });
        _out.writeln('[Cancel] Sent session/cancel.');
        return true;
      }
      if (_isMidTurnControlCommand(cmdTrimmed)) {
        unawaited(
          _tryHandleSignalOrPsCommand(cmdTrimmed, peer: peer, state: state),
        );
        return true;
      }
      return false;
    });

    try {
      final raw = await peer.sendRequest('session/prompt', <String, dynamic>{
        'sessionId': state.sessionId,
        'prompt': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'text',
            'text': trimmed,
          },
        ],
      });
      state.finishTurnDisplay();
      final map = _asStringMap(raw);
      final stopReason = (map['stopReason'] as String?) ?? 'end_turn';
      final meta = _asStringMap(map['_meta']);
      final summary = _asStringMap(meta['fm_agent_os/turnSummary']);
      if (summary.isNotEmpty) {
        state.jjChangeId = (summary['jjChangeId'] as String?) ?? state.jjChangeId;
        state.jjOpId = (summary['jjOpId'] as String?) ?? state.jjOpId;
        state.txState = (summary['txState'] as String?) ?? state.txState;
        state.totalTokensUsed =
            (summary['totalTokensUsed'] as num?)?.toInt() ?? state.totalTokensUsed;
      }
      if (stopReason != 'end_turn') {
        _out.writeln('[Turn ended: stopReason=$stopReason]');
      }
      final ok = (summary['ok'] as bool?) ?? (stopReason == 'end_turn');
      return _LineAction(failed: !ok);
    } on JsonRpcException catch (e) {
      state.finishTurnDisplay();
      _out.writeln('[Prompt Error ${e.code}] ${e.message}');
      return const _LineAction(failed: true);
    } finally {
      state.turnActive = false;
      state.stdinRouter?.setMidTurnCommandHandler(null);
    }
  }

  static bool _isMidTurnControlCommand(String cmd) {
    return cmd == '/pause' ||
        cmd == '/stop' ||
        cmd == '/resume' ||
        cmd.startsWith('/resume ') ||
        cmd == '/cont' ||
        cmd.startsWith('/cont ') ||
        cmd == '/kill' ||
        cmd.startsWith('/kill ') ||
        cmd == '/ps';
  }

  Future<_LineAction?> _tryHandleSignalOrPsCommand(
    String trimmed, {
    required JsonRpcPeer peer,
    required _CliSessionState state,
  }) async {
    if (trimmed == '/pause' || trimmed == '/stop') {
      try {
        await peer.sendRequest('_fm_agent_os/signal', <String, dynamic>{
          'sessionId': state.sessionId,
          'signal': 'SIGSTOP',
        });
        _out.writeln('[Signal] Sent SIGSTOP.');
        return const _LineAction();
      } on JsonRpcException catch (e) {
        _out.writeln('[Signal Error] (${e.code}) ${e.message}');
        return const _LineAction(failed: true);
      }
    }

    if (trimmed == '/resume' ||
        trimmed.startsWith('/resume ') ||
        trimmed == '/cont' ||
        trimmed.startsWith('/cont ')) {
      final prefix = trimmed.startsWith('/resume') ? '/resume' : '/cont';
      final msg = trimmed.length > prefix.length
          ? trimmed.substring(prefix.length).trim()
          : '';
      try {
        await peer.sendRequest('_fm_agent_os/signal', <String, dynamic>{
          'sessionId': state.sessionId,
          'signal': 'SIGCONT',
          if (msg.isNotEmpty) 'constraintMessage': msg,
        });
        _out.writeln('[Signal] Sent SIGCONT.');
        return const _LineAction();
      } on JsonRpcException catch (e) {
        _out.writeln('[Signal Error] (${e.code}) ${e.message}');
        return const _LineAction(failed: true);
      }
    }

    if (trimmed == '/kill' || trimmed.startsWith('/kill ')) {
      final arg = trimmed == '/kill'
          ? ''
          : trimmed.substring('/kill '.length).trim();
      int? targetPid;
      if (arg.isNotEmpty) {
        targetPid = int.tryParse(arg);
        if (targetPid == null || targetPid < 1) {
          _out.writeln('[Kill Error] Invalid pid "$arg".');
          return const _LineAction(failed: true);
        }
      }
      try {
        final raw = await peer.sendRequest('_fm_agent_os/signal', <String, dynamic>{
          'sessionId': state.sessionId,
          'signal': 'SIGKILL',
          'pid': ?targetPid,
        });
        final map = _asStringMap(raw);
        _out.writeln(
          '[Signal] Sent SIGKILL (affectedPids=${map['affectedPids']}).',
        );
        return const _LineAction();
      } on JsonRpcException catch (e) {
        _out.writeln('[Signal Error] (${e.code}) ${e.message}');
        return const _LineAction(failed: true);
      }
    }

    if (trimmed == '/ps') {
      try {
        final raw = await peer.sendRequest('_fm_agent_os/processes', <String, dynamic>{
          'sessionId': state.sessionId,
        });
        final map = _asStringMap(raw);
        final lead = _asStringMap(map['lead']);
        final procs = map['processes'] is List
            ? (map['processes'] as List).whereType<Map<dynamic, dynamic>>()
            : const Iterable<Map<dynamic, dynamic>>.empty();
        _out.writeln(
          '[PS] lead pid=${lead['pid']} state=${lead['state']} '
          'suspended=${lead['isSuspended']} change=${lead['jjChangeId']}',
        );
        for (final pItem in procs) {
          _out.writeln(
            '  pid=${pItem['pid']} profile=${pItem['profile']} '
            'state=${pItem['state']} model=${pItem['model']} '
            'ws=${pItem['workspaceName'] ?? '(none)'} '
            'change=${pItem['workingChangeId'] ?? '(none)'}',
          );
        }
        return const _LineAction();
      } on JsonRpcException catch (e) {
        _out.writeln('[PS Error] (${e.code}) ${e.message}');
        return const _LineAction(failed: true);
      }
    }

    return null;
  }

  Future<_LineAction> _handleStackCommand(
    String trimmed, {
    required JsonRpcPeer peer,
    required _CliSessionState state,
  }) async {
    final rest = trimmed == '/stack'
        ? 'list'
        : trimmed.substring('/stack '.length).trim();
    final tokens = splitWireCommandArgs(rest);
    final sub = tokens.isEmpty ? 'list' : tokens.first.toLowerCase();

    try {
      switch (sub) {
        case 'list':
          final raw = await peer.sendRequest(
            '_fm_agent_os/stack_list',
            <String, dynamic>{'sessionId': state.sessionId},
          );
          final map = _asStringMap(raw);
          final tasks = map['tasks'] is List
              ? (map['tasks'] as List).whereType<Map<dynamic, dynamic>>()
              : const Iterable<Map<dynamic, dynamic>>.empty();
          _out.writeln('[Stack] tasks:');
          for (final t in tasks) {
            _out.writeln(
              '  ${t['taskId']} [${t['state']}] '
              'parent=${t['parentTaskId'] ?? '(root)'} '
              'change=${t['workingChangeId']} '
              'conflicts=${t['hasConflicts']} '
              'title="${t['title']}"',
            );
          }
          return const _LineAction();

        case 'create':
          if (tokens.length < 2) {
            _out.writeln(
              '[Stack Error] Usage: /stack create <taskId> [--parent <parentId>] [--model <m>] <title>',
            );
            return const _LineAction(failed: true);
          }
          final taskId = tokens[1];
          String? parentId;
          String? model;
          final titleParts = <String>[];
          for (var i = 2; i < tokens.length; i++) {
            if (tokens[i] == '--parent' && i + 1 < tokens.length) {
              parentId = tokens[++i];
            } else if (tokens[i] == '--model' && i + 1 < tokens.length) {
              model = tokens[++i];
            } else {
              titleParts.add(tokens[i]);
            }
          }
          final title = titleParts.isEmpty ? taskId : titleParts.join(' ');
          final raw = await peer.sendRequest(
            '_fm_agent_os/stack_create',
            <String, dynamic>{
              'sessionId': state.sessionId,
              'taskId': taskId,
              'title': title,
              'parentTaskId': ?parentId,
              'model': ?model,
            },
          );
          final map = _asStringMap(raw);
          final task = _asStringMap(map['task']);
          _out.writeln(
            '[Stack Create] taskId=${task['taskId']} '
            'change=${task['workingChangeId']} ws=${task['workspaceName']}',
          );
          return const _LineAction();

        case 'edit':
          if (tokens.length < 4) {
            _out.writeln(
              '[Stack Error] Usage: /stack edit <taskId> <relativePath> <newContent>',
            );
            return const _LineAction(failed: true);
          }
          final taskId = tokens[1];
          final relPath = tokens[2];
          final rawContent = tokens.sublist(3).join(' ');
          final content = rawContent.replaceAll(r'\n', '\n');
          final raw = await peer.sendRequest(
            '_fm_agent_os/stack_edit',
            <String, dynamic>{
              'sessionId': state.sessionId,
              'taskId': taskId,
              'relativePath': relPath,
              'content': content,
            },
          );
          final map = _asStringMap(raw);
          final cascaded = map['cascadedTasks'] is List
              ? (map['cascadedTasks'] as List).length
              : 0;
          _out.writeln(
            '[Stack Edit] taskId=$taskId cascaded=$cascaded jjOpId=${map['jjOpId']}',
          );
          return const _LineAction();

        case 'sync':
          final taskId = tokens.length >= 2 ? tokens[1] : null;
          final raw = await peer.sendRequest(
            '_fm_agent_os/stack_sync',
            <String, dynamic>{
              'sessionId': state.sessionId,
              'taskId': ?taskId,
            },
          );
          final map = _asStringMap(raw);
          final cascaded = map['cascadedTasks'] is List
              ? (map['cascadedTasks'] as List).length
              : 0;
          _out.writeln('[Stack Sync] cascaded=$cascaded jjOpId=${map['jjOpId']}');
          return const _LineAction();

        default:
          _out.writeln('[Stack Error] Unknown subcommand "$sub".');
          return const _LineAction(failed: true);
      }
    } on JsonRpcException catch (e) {
      _out.writeln('[Stack Error] (${e.code}) ${e.message}');
      return const _LineAction(failed: true);
    }
  }

  Future<_LineAction> _handleDiffCommand(
    String trimmed, {
    required JsonRpcPeer peer,
    required _CliSessionState state,
  }) async {
    final arg = trimmed == '/diff'
        ? ''
        : trimmed.substring('/diff '.length).trim();
    try {
      final raw = await peer.sendRequest(
        '_fm_agent_os/jj_diff',
        <String, dynamic>{
          'sessionId': state.sessionId,
          if (arg.isNotEmpty) 'taskId': arg,
        },
      );
      final map = _asStringMap(raw);
      final diffText = (map['diff'] as String?) ?? '';
      _out.writeln('[Diff] rev=${map['rev'] ?? arg} conflicts=${map['hasConflicts'] ?? false}');
      if (diffText.isNotEmpty) {
        _out.writeln(diffText.trimRight());
      }
      return const _LineAction();
    } on JsonRpcException catch (e) {
      _out.writeln('[Diff Error] (${e.code}) ${e.message}');
      return const _LineAction(failed: true);
    }
  }
}

class _LineAction {
  const _LineAction({
    this.shouldQuit = false,
    this.failed = false,
  });

  final bool shouldQuit;
  final bool failed;
}

class _CliSessionState {
  _CliSessionState({
    required this.out,
    required this.err,
    required this.useColor,
    required this.verbose,
    required this.permissionPolicy,
    this.stdinRouter,
  });

  final StringSink out;
  final StringSink err;
  final bool useColor;
  final bool verbose;
  CliPermissionPolicy permissionPolicy;
  final _StdinLineRouter? stdinRouter;

  String? sessionId;
  String? currentModel;
  List<Map<String, dynamic>> modelOptions = <Map<String, dynamic>>[];
  String? jjChangeId;
  String? jjOpId;
  String? txState;
  int totalTokensUsed = 0;
  String? lastUsageSummary;
  bool turnActive = false;

  bool _wroteThought = false;
  bool _wroteText = false;

  void resetTurnDisplay() {
    _wroteThought = false;
    _wroteText = false;
  }

  void finishTurnDisplay() {
    if (_wroteThought) {
      if (useColor) {
        out.write('\x1b[0m');
      }
      out.writeln('');
      _wroteThought = false;
    }
    if (_wroteText) {
      out.writeln('');
      _wroteText = false;
    }
  }

  void updateConfigOptions(Object? rawOptions) {
    if (rawOptions is! List) {
      return;
    }
    for (final item in rawOptions) {
      if (item is! Map) {
        continue;
      }
      final opt = Map<String, dynamic>.from(item);
      if (opt['id'] == 'model') {
        currentModel = opt['currentValue'] as String?;
        final rawList = opt['options'];
        if (rawList is List) {
          modelOptions = rawList
              .whereType<Map<dynamic, dynamic>>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList(growable: false);
        }
      }
    }
  }

  void updateJjMeta(Map<String, dynamic> meta) {
    if (meta.isEmpty) {
      return;
    }
    jjChangeId = (meta['jjChangeId'] as String?) ?? jjChangeId;
    jjOpId = (meta['jjOpId'] as String?) ?? jjOpId;
    txState = (meta['txState'] as String?) ?? txState;
  }

  void handleSessionUpdate(Map<String, dynamic> params) {
    final update = _asStringMap(params['update']);
    final kind = update['sessionUpdate'] as String?;
    switch (kind) {
      case 'agent_thought_chunk':
        final content = _asStringMap(update['content']);
        final text = (content['text'] as String?) ?? '';
        if (text.isEmpty) {
          return;
        }
        if (!_wroteThought) {
          if (useColor) {
            out.write('\x1b[2m[Thought] ');
          } else {
            out.write('[Thought] ');
          }
          _wroteThought = true;
        }
        out.write(text);

      case 'agent_message_chunk':
        final content = _asStringMap(update['content']);
        final text = (content['text'] as String?) ?? '';
        if (text.isEmpty) {
          return;
        }
        if (_wroteThought) {
          if (useColor) {
            out.write('\x1b[0m');
          }
          out.writeln('');
          _wroteThought = false;
        }
        out.write(text);
        _wroteText = true;

      case 'tool_call':
        finishTurnDisplay();
        final id = update['toolCallId'] ?? '';
        final title = update['title'] ?? '';
        final toolKind = update['kind'] ?? 'other';
        out.writeln('[Tool ->] $title ($toolKind) [$id]');

      case 'tool_call_update':
        finishTurnDisplay();
        final id = update['toolCallId'] ?? '';
        final status = update['status'] ?? '';
        final jjMeta = _asStringMap(
          _asStringMap(update['_meta'])['fm_agent_os/jj'],
        );
        updateJjMeta(jjMeta);
        final changeId = jjMeta['jjChangeId'] ?? '(none)';
        final opId = jjMeta['jjOpId'] ?? '(none)';
        final decision = jjMeta['decision'] ?? '';
        out.writeln(
          '[Tool <-] $status [$id] (change=$changeId op=$opId decision=$decision)',
        );
        _renderContentList(update['content']);

      case 'usage_update':
        finishTurnDisplay();
        final meta = _asStringMap(
          _asStringMap(update['_meta'])['fm_agent_os/llmTelemetry'],
        );
        final provider = meta['provider'] ?? 'unknown';
        final model = meta['model'] ?? 'unknown';
        final prompt = (meta['promptTokens'] as num?)?.toInt() ?? 0;
        final completion = (meta['completionTokens'] as num?)?.toInt() ?? 0;
        final cached = meta['cachedTokens'];
        final hitRate = meta['cacheHitRate'] as num?;
        final durationMs = (meta['durationMs'] as num?)?.toInt() ?? 0;
        final cachedStr = cached == null ? 'null' : '$cached';
        final pctStr = hitRate != null
            ? '${(hitRate * 100).toStringAsFixed(2)}%'
            : 'n/a';
        final costMap = _asStringMap(update['cost']);
        final costAmt = costMap['amount'];
        final costPart = costAmt != null ? ' | cost=\$$costAmt' : '';
        final line =
            '[Usage] $provider/$model | prompt=$prompt (cached=$cachedStr, $pctStr) | completion=$completion | ${durationMs}ms$costPart';
        lastUsageSummary = line;
        out.writeln(line);

      case 'config_option_update':
        updateConfigOptions(update['configOptions']);
    }
  }

  Future<Map<String, dynamic>> handlePermissionRequest(
    Map<String, dynamic> params,
  ) async {
    finishTurnDisplay();
    final toolCall = _asStringMap(params['toolCall']);
    final title = (toolCall['title'] as String?) ?? 'Approve action';
    final kind = (toolCall['kind'] as String?) ?? 'other';
    final content = toolCall['content'];

    out.writeln('');
    out.writeln('=== [RING 2 APPROVAL REQUIRED] ===');
    out.writeln('Title : $title');
    out.writeln('Kind  : $kind');
    final buffer = StringBuffer();
    _renderContentList(content, captureTo: buffer);

    final String chosenOptionId;
    if (!permissionPolicy.isInteractive) {
      chosenOptionId = permissionPolicy.resolveAutomatic(
        title: title,
        kind: kind,
        contentText: buffer.toString(),
      );
      out.writeln(
        '[Policy:${permissionPolicy.rawSpec}] -> $chosenOptionId',
      );
    } else {
      out.write('Allow? [y] once / [a] session / [n] deny: ');
      final answer = await stdinRouter!.readPermissionAnswer();
      if (answer == null) {
        return <String, dynamic>{
          'outcome': <String, dynamic>{'outcome': 'cancelled'},
        };
      }
      final norm = answer.trim().toLowerCase();
      chosenOptionId = switch (norm) {
        'y' || 'yes' => 'allow_once',
        'a' || 'always' => 'allow_always',
        _ => 'reject_once',
      };
    }

    return <String, dynamic>{
      'outcome': <String, dynamic>{
        'outcome': 'selected',
        'optionId': chosenOptionId,
      },
    };
  }

  void _renderContentList(Object? rawContent, {StringBuffer? captureTo}) {
    if (rawContent is! List) {
      return;
    }
    for (final item in rawContent) {
      if (item is! Map) {
        continue;
      }
      final block = Map<String, dynamic>.from(item);
      final type = block['type'];
      if (type == 'diff') {
        final path = (block['path'] as String?) ?? '';
        final oldText = block['oldText'] as String?;
        final newText = (block['newText'] as String?) ?? '';
        _writeLine('--- $path (before)', captureTo);
        if (oldText != null) {
          for (final l in const LineSplitter().convert(oldText)) {
            _writeColoredLine('- $l', '\x1b[31m', captureTo);
          }
        } else {
          _writeLine('  (new file)', captureTo);
        }
        _writeLine('+++ $path (after)', captureTo);
        for (final l in const LineSplitter().convert(newText)) {
          _writeColoredLine('+ $l', '\x1b[32m', captureTo);
        }
      } else if (type == 'content') {
        final inner = _asStringMap(block['content']);
        final text = inner['text'];
        if (text is String && text.trim().isNotEmpty) {
          for (final l in const LineSplitter().convert(text.trimRight())) {
            if (l.startsWith('+') && !l.startsWith('+++')) {
              _writeColoredLine(l, '\x1b[32m', captureTo);
            } else if (l.startsWith('-') && !l.startsWith('---')) {
              _writeColoredLine(l, '\x1b[31m', captureTo);
            } else {
              _writeLine(l, captureTo);
            }
          }
        }
      }
    }
  }

  void _writeLine(String line, StringBuffer? captureTo) {
    out.writeln(line);
    captureTo?.writeln(line);
  }

  void _writeColoredLine(
    String line,
    String ansiColor,
    StringBuffer? captureTo,
  ) {
    if (useColor) {
      out.writeln('$ansiColor$line\x1b[0m');
    } else {
      out.writeln(line);
    }
    captureTo?.writeln(line);
  }
}

class _StdinLineRouter {
  _StdinLineRouter(Stream<List<int>> stream) {
    _sub = stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onDone: _onDone,
          onError: (_) => _onDone(),
        );
  }

  late final StreamSubscription<String> _sub;
  final List<String> _replBuffer = <String>[];
  Completer<String?>? _permissionWaiter;
  Completer<String?>? _replWaiter;
  bool Function(String line)? _midTurnCommandHandler;
  bool _closed = false;

  void setMidTurnCommandHandler(bool Function(String line)? handler) {
    _midTurnCommandHandler = handler;
  }

  void _onLine(String line) {
    if (_permissionWaiter != null && !_permissionWaiter!.isCompleted) {
      final w = _permissionWaiter!;
      _permissionWaiter = null;
      w.complete(line);
      return;
    }
    if (_midTurnCommandHandler != null && _midTurnCommandHandler!(line)) {
      return;
    }
    if (_replWaiter != null && !_replWaiter!.isCompleted) {
      final w = _replWaiter!;
      _replWaiter = null;
      w.complete(line);
      return;
    }
    _replBuffer.add(line);
  }

  void _onDone() {
    _closed = true;
    if (_permissionWaiter != null && !_permissionWaiter!.isCompleted) {
      _permissionWaiter!.complete(null);
      _permissionWaiter = null;
    }
    if (_replWaiter != null && !_replWaiter!.isCompleted) {
      _replWaiter!.complete(null);
      _replWaiter = null;
    }
  }

  Future<String?> readReplLine() {
    if (_replBuffer.isNotEmpty) {
      return Future<String?>.value(_replBuffer.removeAt(0));
    }
    if (_closed) {
      return Future<String?>.value(null);
    }
    final completer = Completer<String?>();
    _replWaiter = completer;
    return completer.future;
  }

  Future<String?> readPermissionAnswer() {
    if (_closed) {
      return Future<String?>.value(null);
    }
    final completer = Completer<String?>();
    _permissionWaiter = completer;
    return completer.future;
  }

  Future<void> close() async {
    _onDone();
    await _sub.cancel();
  }
}

Map<String, dynamic> _asStringMap(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}
