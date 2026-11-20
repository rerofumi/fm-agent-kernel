import 'dart:convert';

import 'wire_redactor.dart';

/// Environment variable entry for a wire `stdio` MCP server spec ([D-321], [D-322]).
class WireMcpEnvVar {
  const WireMcpEnvVar({
    required this.name,
    required this.value,
  });

  final String name;
  final String value;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'value': value,
    };
  }
}

/// Pure-Dart wire representation of an ACP `mcpServers` `stdio` entry ([D-321], [D-322]).
class WireMcpServerSpec {
  const WireMcpServerSpec({
    required this.name,
    required this.command,
    this.args = const <String>[],
    this.env = const <WireMcpEnvVar>[],
  });

  final String name;
  final String command;
  final List<String> args;
  final List<WireMcpEnvVar> env;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'stdio',
      'name': name,
      'command': command,
      'args': args,
      if (env.isNotEmpty)
        'env': env.map((e) => e.toJson()).toList(growable: false),
    };
  }
}

/// Splits a command line string into arguments, respecting single and double quotes
/// while preserving Windows backslash paths ([D-321] §2.1, [D-322] §3.1).
List<String> splitWireCommandArgs(String commandLine) {
  final trimmed = commandLine.trim();
  if (trimmed.isEmpty) {
    return const <String>[];
  }

  final args = <String>[];
  final current = StringBuffer();
  var inSingleQuote = false;
  var inDoubleQuote = false;
  var hasToken = false;

  for (var i = 0; i < trimmed.length; i++) {
    final ch = trimmed[i];

    if (inSingleQuote) {
      if (ch == "'") {
        inSingleQuote = false;
      } else {
        current.write(ch);
      }
      hasToken = true;
      continue;
    }

    if (inDoubleQuote) {
      if (ch == '\\' && i + 1 < trimmed.length) {
        final next = trimmed[i + 1];
        if (next == '"' || next == '\\') {
          current.write(next);
          i++;
          hasToken = true;
          continue;
        }
      }
      if (ch == '"') {
        inDoubleQuote = false;
      } else {
        current.write(ch);
      }
      hasToken = true;
      continue;
    }

    if (ch == "'") {
      inSingleQuote = true;
      hasToken = true;
      continue;
    }
    if (ch == '"') {
      inDoubleQuote = true;
      hasToken = true;
      continue;
    }
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
      if (hasToken) {
        args.add(current.toString());
        current.clear();
        hasToken = false;
      }
      continue;
    }

    current.write(ch);
    hasToken = true;
  }

  if (inSingleQuote || inDoubleQuote) {
    throw const FormatException('Unclosed quote in command line.');
  }
  if (hasToken) {
    args.add(current.toString());
  }
  return args;
}

/// Parses `--mcp-server <spec>` in either JSON object notation or `name=command [args...]`
/// notation into a [WireMcpServerSpec], registering any env secrets in [redactor] ([D-321]).
WireMcpServerSpec parseWireMcpServerSpec(
  String raw, {
  WireSecretRedactor? redactor,
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Empty --mcp-server specification.');
  }

  if (trimmed.startsWith('{')) {
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (e) {
      throw FormatException('Invalid JSON in --mcp-server: ${e.message}');
    }
    if (decoded is! Map) {
      throw const FormatException('--mcp-server JSON must be an object.');
    }
    final map = Map<String, dynamic>.from(decoded);
    final rawType = map['type'];
    if (rawType != null && rawType != 'stdio') {
      throw FormatException('Unsupported MCP transport type "$rawType".');
    }
    final name = (map['name'] as String?)?.trim() ?? '';
    final command = (map['command'] as String?)?.trim() ?? '';
    if (name.isEmpty || command.isEmpty) {
      throw const FormatException(
        '--mcp-server JSON requires non-empty "name" and "command".',
      );
    }
    final args = <String>[];
    final rawArgs = map['args'];
    if (rawArgs != null) {
      if (rawArgs is! List) {
        throw const FormatException('--mcp-server "args" must be a string list.');
      }
      for (final item in rawArgs) {
        if (item is! String) {
          throw const FormatException(
            '--mcp-server "args" entries must be strings.',
          );
        }
        args.add(item);
      }
    }
    final env = <WireMcpEnvVar>[];
    final rawEnv = map['env'];
    if (rawEnv != null) {
      if (rawEnv is! List) {
        throw const FormatException('--mcp-server "env" must be a list.');
      }
      for (final entry in rawEnv) {
        if (entry is! Map) {
          throw const FormatException(
            '--mcp-server "env" items must be objects.',
          );
        }
        final eName = (entry['name'] as String?)?.trim() ?? '';
        final eVal = entry['value'];
        if (eName.isEmpty || eVal is! String) {
          throw const FormatException(
            '--mcp-server "env" items require "name" and string "value".',
          );
        }
        redactor?.registerSecret(eVal);
        env.add(WireMcpEnvVar(name: eName, value: eVal));
      }
    }
    return WireMcpServerSpec(
      name: name,
      command: command,
      args: args,
      env: env,
    );
  }

  final eqIdx = trimmed.indexOf('=');
  if (eqIdx <= 0 || eqIdx == trimmed.length - 1) {
    throw const FormatException(
      'Invalid --mcp-server syntax. Expected JSON or "name=command [args...]".',
    );
  }
  final name = trimmed.substring(0, eqIdx).trim();
  final cmdLine = trimmed.substring(eqIdx + 1).trim();
  if (name.isEmpty || cmdLine.isEmpty) {
    throw const FormatException(
      'Invalid --mcp-server syntax. Name and command must be non-empty.',
    );
  }
  final tokens = splitWireCommandArgs(cmdLine);
  if (tokens.isEmpty) {
    throw const FormatException(
      'Invalid --mcp-server syntax. Missing command.',
    );
  }
  return WireMcpServerSpec(
    name: name,
    command: tokens.first,
    args: tokens.sublist(1),
  );
}
