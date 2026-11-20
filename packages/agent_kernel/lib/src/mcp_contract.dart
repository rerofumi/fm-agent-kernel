/// Environment variable entry for an MCP server process (ACP v1 `EnvVariable[]` compatible) ([D-318]).
class McpEnvVar {
  const McpEnvVar({
    required this.name,
    required this.value,
  });

  factory McpEnvVar.fromJson(Map<String, dynamic> json) {
    return McpEnvVar(
      name: json['name'] as String,
      value: (json['value'] as String?) ?? '',
    );
  }

  final String name;
  final String value;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'value': value,
    };
  }
}

/// Configuration specification for an external MCP server connection ([D-318]).
class McpServerSpec {
  McpServerSpec({
    required this.name,
    this.transportType = 'stdio',
    required this.command,
    List<String> args = const <String>[],
    List<McpEnvVar> env = const <McpEnvVar>[],
    this.cwd,
  }) : args = List<String>.unmodifiable(args),
       env = List<McpEnvVar>.unmodifiable(env);

  factory McpServerSpec.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['args'];
    final rawEnv = json['env'];
    return McpServerSpec(
      name: json['name'] as String,
      transportType: (json['transportType'] as String?) ?? 'stdio',
      command: json['command'] as String,
      args: rawArgs is List
          ? rawArgs.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
      env: rawEnv is List
          ? rawEnv
                .whereType<Map<dynamic, dynamic>>()
                .map((m) => McpEnvVar.fromJson(Map<String, dynamic>.from(m)))
                .toList(growable: false)
          : const <McpEnvVar>[],
      cwd: json['cwd'] as String?,
    );
  }

  final String name;
  final String transportType;
  final String command;
  final List<String> args;
  final List<McpEnvVar> env;
  final String? cwd;

  Map<String, dynamic> toJson({bool redactEnvValues = true}) {
    return <String, dynamic>{
      'name': name,
      'transportType': transportType,
      'command': command,
      'args': args,
      'env': env
          .map(
            (e) => redactEnvValues
                ? <String, dynamic>{'name': e.name, 'value': '<REDACTED>'}
                : e.toJson(),
          )
          .toList(growable: false),
      if (cwd != null) 'cwd': cwd,
    };
  }
}

/// Normalized descriptor of a tool discovered from an MCP server (`tools/list`) ([D-318]).
class McpToolDescriptor {
  McpToolDescriptor({
    required this.serverName,
    required this.name,
    this.title,
    this.description,
    Map<String, dynamic> inputSchema = const <String, dynamic>{},
  }) : inputSchema = Map<String, dynamic>.unmodifiable(inputSchema);

  final String serverName;
  final String name;
  final String? title;
  final String? description;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'serverName': serverName,
      'name': name,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      'inputSchema': inputSchema,
    };
  }
}

/// Structured outcome of an MCP `tools/call` invocation ([D-318], [D-319]).
class McpCallOutcome {
  McpCallOutcome({
    required this.serverName,
    required this.toolName,
    required this.isError,
    required this.contentText,
    List<Map<String, dynamic>> rawContent = const <Map<String, dynamic>>[],
    Map<String, dynamic>? structuredContent,
  }) : rawContent = List<Map<String, dynamic>>.unmodifiable(
         rawContent.map((e) => Map<String, dynamic>.unmodifiable(e)),
       ),
       structuredContent = structuredContent == null
           ? null
           : Map<String, dynamic>.unmodifiable(structuredContent);

  final String serverName;
  final String toolName;
  final bool isError;
  final String contentText;
  final List<Map<String, dynamic>> rawContent;
  final Map<String, dynamic>? structuredContent;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'server': serverName,
      'tool': toolName,
      'isError': isError,
      'content': contentText,
      'rawContent': rawContent,
      if (structuredContent != null) 'structuredContent': structuredContent,
    };
  }
}
