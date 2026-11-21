import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../wire/wire_command_splitter.dart';
import '../wire/wire_redactor.dart';
import 'kanban_acp_bridge.dart';
import 'kanban_server.dart';

/// Launch specification for the child `agent_os_daemon` process ([D-322] §3.2).
class KanbanDaemonLaunchSpec {
  const KanbanDaemonLaunchSpec({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;
}

/// CLI entrypoint runner for `acp_kanban_app` ([D-322] §3.1–3.2).
/// Strictly imports ONLY Dart standard libraries, `package:args`, `package:path`,
/// `src/wire/*`, and `src/kanban/*` (ZERO engine package imports).
class KanbanCliRunner {
  KanbanCliRunner({
    StringSink? out,
    StringSink? err,
    Stream<List<int>>? stdinStream,
  })  : _out = out ?? stdout,
        _err = err ?? stderr,
        _stdinStream = stdinStream;

  final StringSink _out;
  final StringSink _err;
  final Stream<List<int>>? _stdinStream;

  /// Resolves the daemon executable (`--daemon`, sibling `.exe`, `build/`, or dev `dart run`).
  static KanbanDaemonLaunchSpec? resolveDaemonLaunch({
    String? explicitDaemonPath,
    String? model,
    String? ollamaUrl,
    int? maxSteps,
    int? maxSyscalls,
    List<String> skillsDirs = const <String>[],
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
      if (maxSyscalls != null) ...<String>['--max-syscalls', '$maxSyscalls'],
      for (final dir in skillsDirs)
        if (dir.trim().isNotEmpty) ...<String>['--skills-dir', dir.trim()],
    ];

    if (explicitDaemonPath != null && explicitDaemonPath.trim().isNotEmpty) {
      final resolved = p.normalize(p.absolute(explicitDaemonPath.trim()));
      if (!File(resolved).existsSync()) {
        return null;
      }
      return KanbanDaemonLaunchSpec(executable: resolved, arguments: extraArgs);
    }

    final siblingExe = p.join(
      p.dirname(Platform.resolvedExecutable),
      'agent_os_daemon.exe',
    );
    if (File(siblingExe).existsSync()) {
      return KanbanDaemonLaunchSpec(
          executable: siblingExe, arguments: extraArgs);
    }

    final buildExe = p.join(
      Directory.current.path,
      'build',
      'agent_os_daemon.exe',
    );
    if (File(buildExe).existsSync()) {
      return KanbanDaemonLaunchSpec(executable: buildExe, arguments: extraArgs);
    }

    final devScript = p.join(
      Directory.current.path,
      'packages',
      'agent_acp',
      'bin',
      'agent_os_daemon.dart',
    );
    if (File(devScript).existsSync()) {
      return KanbanDaemonLaunchSpec(
        executable: Platform.resolvedExecutable,
        arguments: <String>['run', devScript, ...extraArgs],
      );
    }

    return null;
  }

  /// Builds the CLI [ArgParser] for `acp_kanban_app`.
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
        'port',
        defaultsTo: '8765',
        help: 'Loopback HTTP port (0 assigns an ephemeral free port).',
      )
      ..addFlag(
        'no-open-browser',
        negatable: false,
        help: 'Suppress automatic browser launch on startup.',
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
        help: 'External directory containing <skill>/SKILL.md packages (repeatable).',
      )
      ..addMultiOption(
        'mcp-server',
        splitCommas: false,
        help: 'stdio MCP server spec (JSON object or "name=command [args...]").',
      )
      ..addOption(
        'max-context-tokens',
        help: 'Effective context window cap in tokens.',
      )
      ..addOption(
        'permission-policy',
        defaultsTo: 'interactive',
        help: 'Approval policy: interactive | allow_once | allow_always | reject_once.',
      )
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show usage information.',
      );
  }

  /// Runs `acp_kanban_app` with [args] and returns the process exit code.
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
      _out.writeln('FM Agent OS — Local Web Kanban GUI (acp_kanban_app)');
      _out.writeln(parser.usage);
      return 0;
    }

    final rawCwd = parsed.option('cwd');
    final cwd = rawCwd != null && rawCwd.trim().isNotEmpty
        ? p.normalize(p.absolute(rawCwd.trim()))
        : p.normalize(Directory.current.path);
    if (!Directory(cwd).existsSync() ||
        !Directory(p.join(cwd, '.jj')).existsSync()) {
      _err.writeln('Target --cwd must be an existing .jj repository: $cwd');
      return 64;
    }

    final port = int.tryParse(parsed.option('port') ?? '8765');
    if (port == null || port < 0 || port > 65535) {
      _err.writeln('Invalid --port: ${parsed.option('port')}');
      return 64;
    }

    final maxSteps = int.tryParse(parsed.option('max-steps') ?? '64');
    if (maxSteps == null || maxSteps < 1) {
      _err.writeln('Invalid --max-steps: ${parsed.option('max-steps')}');
      return 64;
    }

    int? maxSyscalls;
    final rawMaxSyscalls = parsed.option('max-syscalls');
    if (rawMaxSyscalls != null && rawMaxSyscalls.trim().isNotEmpty) {
      maxSyscalls = int.tryParse(rawMaxSyscalls.trim());
      if (maxSyscalls == null || maxSyscalls < 1) {
        _err.writeln('Invalid --max-syscalls: $rawMaxSyscalls');
        return 64;
      }
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

    final redactor = WireSecretRedactor()
      ..registerFromEnvironment(Platform.environment);

    final mcpServers = <WireMcpServerSpec>[];
    for (final rawMcp in parsed.multiOption('mcp-server')) {
      try {
        mcpServers.add(parseWireMcpServerSpec(rawMcp, redactor: redactor));
      } on FormatException catch (e) {
        _err.writeln('Invalid --mcp-server: ${e.message}');
        return 64;
      }
    }

    final startupModel = parsed.option('model');
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
      maxSyscalls: maxSyscalls,
      skillsDirs: skillsDirs,
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

    final KanbanAcpBridge bridge;
    try {
      bridge = await KanbanAcpBridge.spawn(
        executable: launchSpec.executable,
        arguments: launchSpec.arguments,
        cwd: cwd,
        environment: childEnv.isEmpty ? null : childEnv,
        redactor: redactor,
        permissionPolicy: parsed.option('permission-policy') ?? 'interactive',
        mcpServers: mcpServers,
        maxContextTokens: maxContextTokens,
        onDaemonStderr: (line) => _err.writeln('[daemon] $line'),
      );
      await bridge.connect();
    } catch (e) {
      _err.writeln('Failed to start/connect agent_os_daemon: ${redactor.redactString(e.toString())}');
      return 1;
    }

    final server = await KanbanServer.start(
      bridge: bridge,
      port: port,
      out: _out,
      err: _err,
      stdinEofStream: _stdinStream,
      watchStdinEof: true,
      watchProcessSignals: true,
    );

    if (!parsed.flag('no-open-browser')) {
      unawaited(_openBrowser(server.url));
    }

    await server.done;
    return 0;
  }

  Future<void> _openBrowser(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.start(
          'cmd',
          <String>['/c', 'start', '', url],
          runInShell: false,
        );
      } else if (Platform.isMacOS) {
        await Process.start('open', <String>[url], runInShell: false);
      } else {
        await Process.start('xdg-open', <String>[url], runInShell: false);
      }
    } catch (_) {
      // Best-effort browser launch.
    }
  }
}
