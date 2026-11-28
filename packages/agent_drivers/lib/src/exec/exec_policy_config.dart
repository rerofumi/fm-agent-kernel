import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Single allowlist rule parsed from `.agent_os/exec_policy.json` ([D-506]).
class ExecAllowRule {
  ExecAllowRule({
    required String command,
    List<List<String>>? argPrefixes,
    this.maxTimeoutMs = defaultMaxTimeoutMs,
  })  : command = command.trim(),
        normalizedCommand = normalizeCommandName(command),
        argPrefixes = argPrefixes == null
            ? null
            : List<List<String>>.unmodifiable(
                argPrefixes.map((prefix) => List<String>.unmodifiable(prefix)),
              );

  static const int minTimeoutMs = 100;
  static const int maxAllowedTimeoutMs = 600000;
  static const int defaultMaxTimeoutMs = 120000;

  final String command;
  final String normalizedCommand;
  final List<List<String>>? argPrefixes;
  final int maxTimeoutMs;

  /// Strips trailing `.exe` / `.cmd` / `.bat` / `.ps1` and lowercases [rawCommand].
  static String normalizeCommandName(String rawCommand) {
    final lower = rawCommand.trim().toLowerCase();
    for (final ext in const <String>['.exe', '.cmd', '.bat', '.ps1']) {
      if (lower.endsWith(ext)) {
        return lower.substring(0, lower.length - ext.length);
      }
    }
    return lower;
  }

  /// Strips any leading directory path (`/` or `\`) and then normalizes extension/case.
  static String normalizeCommandBasename(String rawToken) {
    final normalized = rawToken.trim().replaceAll('/', r'\');
    final slashIdx = normalized.lastIndexOf(r'\');
    final base = slashIdx >= 0 ? normalized.substring(slashIdx + 1) : normalized;
    return normalizeCommandName(base);
  }

  /// Returns whether [args] matches this rule's prefix constraint (`true` if `argPrefixes == null`).
  bool matchesArgs(List<String> args) {
    final prefixes = argPrefixes;
    if (prefixes == null) {
      return true;
    }
    for (final prefix in prefixes) {
      if (args.length < prefix.length) {
        continue;
      }
      var matched = true;
      for (var i = 0; i < prefix.length; i++) {
        if (args[i].trim() != prefix[i]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return true;
      }
    }
    return false;
  }

  /// Formats a deterministic one-line prompt summary for [AgentPrompts] and tool schemas ([D-509]).
  String toPromptSummary() {
    if (argPrefixes == null) {
      return '`$normalizedCommand` (any safe workspace args; maxTimeoutMs: $maxTimeoutMs)';
    }
    final formattedPrefixes =
        argPrefixes!.map((prefix) => '`${prefix.join(' ')}`').join(', ');
    return '`$normalizedCommand` (allowed prefixes: $formattedPrefixes; maxTimeoutMs: $maxTimeoutMs)';
  }
}

/// Parsed `.agent_os/exec_policy.json` configuration ([D-506], [D-509]).
class ExecPolicyConfig {
  ExecPolicyConfig({
    List<ExecAllowRule> allow = const <ExecAllowRule>[],
  }) : allow = List<ExecAllowRule>.unmodifiable(allow);

  /// Default policy with no additional allowlisted direct commands.
  factory ExecPolicyConfig.defaults() => ExecPolicyConfig();

  final List<ExecAllowRule> allow;

  static final RegExp _shellMetaPattern = RegExp(
    r'[&|;><`\r\n\x00%]|\$\(',
  );
  static final RegExp _whitespacePattern = RegExp(r'\s');

  static const Set<String> _allowedRuleKeys = <String>{
    'command',
    'allowedSubcommands',
    'allowedArgPrefixes',
    'maxTimeoutMs',
  };

  /// Shell wrapper executables that are unconditionally forbidden in `exec_policy.json` ([D-506]).
  static const Set<String> shellWrappers = <String>{
    'cmd',
    'powershell',
    'pwsh',
    'sh',
    'bash',
    'wsl',
    'zsh',
    'fish',
    'ash',
    'dash',
  };

  /// Raw VCS executables unconditionally forbidden in `exec_policy.json` ([D-506]).
  static const Set<String> blockedVcsCommands = <String>{
    'git',
    'jj',
  };

  /// Direct network retrieval commands unconditionally forbidden from auto-allow ([D-506]).
  static const Set<String> externalNetworkCommands = <String>{
    'curl',
    'wget',
    'invoke-webrequest',
    'iwr',
    'invoke-restmethod',
    'irm',
  };

  /// Union of all executables forbidden in `.agent_os/exec_policy.json`.
  static final Set<String> forbiddenCommands = Set<String>.unmodifiable(<String>{
    ...shellWrappers,
    ...blockedVcsCommands,
    ...externalNetworkCommands,
  });

  /// Returns true if [input] contains any shell metacharacter or control character.
  static bool containsShellMetacharacters(String input) =>
      _shellMetaPattern.hasMatch(input);

  /// Returns all configured rules matching [normalizedCommand].
  List<ExecAllowRule> rulesForCommand(String normalizedCommand) {
    final target = ExecAllowRule.normalizeCommandName(normalizedCommand);
    return allow
        .where((rule) => rule.normalizedCommand == target)
        .toList(growable: false);
  }

  /// Returns deterministic one-line summaries for prompt and schema injection ([D-509]).
  List<String> toPromptRuleSummaries() {
    if (allow.isEmpty) {
      return const <String>[];
    }
    return List<String>.unmodifiable(
      allow.map((rule) => rule.toPromptSummary()),
    );
  }

  /// Parses [rawJson] into an [ExecPolicyLoadResult] using Fail-Closed validation ([D-506]).
  static ExecPolicyLoadResult parseJsonString(
    String rawJson, {
    String? sourcePath,
  }) {
    final label = sourcePath ?? 'exec_policy.json';
    final warnings = <String>[];

    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException catch (e) {
      warnings.add(
        'Invalid JSON syntax in $label: ${e.message}. Falling back to defaults.',
      );
      return ExecPolicyLoadResult(
        config: ExecPolicyConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    } catch (e) {
      warnings.add(
        'Failed to decode $label: $e. Falling back to defaults.',
      );
      return ExecPolicyLoadResult(
        config: ExecPolicyConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    }

    if (decoded is! Map) {
      warnings.add(
        'Root of $label must be a JSON object. Falling back to defaults.',
      );
      return ExecPolicyLoadResult(
        config: ExecPolicyConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    }

    for (final rawKey in decoded.keys) {
      final key = rawKey.toString();
      if (key != 'allow') {
        warnings.add('Unknown root key "$key" in $label; ignoring.');
      }
    }

    if (!decoded.containsKey('allow')) {
      return ExecPolicyLoadResult(
        config: ExecPolicyConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    }

    final rawAllow = decoded['allow'];
    if (rawAllow is! List) {
      warnings.add(
        '"allow" in $label must be a JSON array. Falling back to defaults.',
      );
      return ExecPolicyLoadResult(
        config: ExecPolicyConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    }

    final rules = <ExecAllowRule>[];
    for (var i = 0; i < rawAllow.length; i++) {
      final parsedRule = _parseRule(
        rawAllow[i],
        index: i,
        label: label,
        warnings: warnings,
      );
      if (parsedRule != null) {
        rules.add(parsedRule);
      }
    }

    return ExecPolicyLoadResult(
      config: ExecPolicyConfig(allow: rules),
      sourcePath: sourcePath,
      warnings: warnings,
    );
  }

  static ExecAllowRule? _parseRule(
    Object? rawItem, {
    required int index,
    required String label,
    required List<String> warnings,
  }) {
    if (rawItem is! Map) {
      warnings.add(
        'Entry allow[$index] in $label must be a JSON object; skipping rule.',
      );
      return null;
    }

    for (final rawKey in rawItem.keys) {
      final key = rawKey.toString();
      if (!_allowedRuleKeys.contains(key)) {
        warnings.add(
          'Entry allow[$index] in $label contains unknown key "$key"; skipping rule (fail-closed).',
        );
        return null;
      }
    }

    final rawCommand = rawItem['command'];
    if (rawCommand is! String) {
      warnings.add(
        'Entry allow[$index].command in $label must be a string; skipping rule.',
      );
      return null;
    }
    final trimmedCommand = rawCommand.trim();
    if (trimmedCommand.isEmpty ||
        _whitespacePattern.hasMatch(trimmedCommand) ||
        trimmedCommand.contains('/') ||
        trimmedCommand.contains(r'\') ||
        trimmedCommand.contains(':') ||
        containsShellMetacharacters(trimmedCommand)) {
      warnings.add(
        'Entry allow[$index].command "$rawCommand" in $label is empty or contains disallowed path/whitespace/metacharacters; skipping rule.',
      );
      return null;
    }

    final normalizedCommand = ExecAllowRule.normalizeCommandName(trimmedCommand);
    if (normalizedCommand.isEmpty ||
        forbiddenCommands.contains(normalizedCommand)) {
      warnings.add(
        'Entry allow[$index].command "$rawCommand" ($normalizedCommand) in $label is forbidden by kernel policy; skipping rule.',
      );
      return null;
    }

    List<String>? subcommands;
    if (rawItem.containsKey('allowedSubcommands')) {
      final rawSubs = rawItem['allowedSubcommands'];
      if (rawSubs is! List || rawSubs.isEmpty) {
        warnings.add(
          'Entry allow[$index].allowedSubcommands in $label must be a non-empty array of strings; skipping rule.',
        );
        return null;
      }
      final parsedSubs = <String>[];
      for (var j = 0; j < rawSubs.length; j++) {
        final item = rawSubs[j];
        if (item is! String) {
          warnings.add(
            'Entry allow[$index].allowedSubcommands[$j] in $label must be a string; skipping rule.',
          );
          return null;
        }
        final trimmed = item.trim();
        if (trimmed.isEmpty || containsShellMetacharacters(item)) {
          warnings.add(
            'Entry allow[$index].allowedSubcommands[$j] in $label is empty or contains shell metacharacters; skipping rule.',
          );
          return null;
        }
        parsedSubs.add(trimmed);
      }
      subcommands = parsedSubs;
    }

    List<List<String>>? argPrefixes;
    if (rawItem.containsKey('allowedArgPrefixes')) {
      final rawPrefixes = rawItem['allowedArgPrefixes'];
      if (rawPrefixes is! List || rawPrefixes.isEmpty) {
        warnings.add(
          'Entry allow[$index].allowedArgPrefixes in $label must be a non-empty array of string arrays; skipping rule.',
        );
        return null;
      }
      final parsedPrefixes = <List<String>>[];
      for (var j = 0; j < rawPrefixes.length; j++) {
        final rawPrefix = rawPrefixes[j];
        if (rawPrefix is! List || rawPrefix.isEmpty) {
          warnings.add(
            'Entry allow[$index].allowedArgPrefixes[$j] in $label must be a non-empty array of strings; skipping rule.',
          );
          return null;
        }
        final tokens = <String>[];
        for (var k = 0; k < rawPrefix.length; k++) {
          final tok = rawPrefix[k];
          if (tok is! String) {
            warnings.add(
              'Entry allow[$index].allowedArgPrefixes[$j][$k] in $label must be a string; skipping rule.',
            );
            return null;
          }
          final trimmed = tok.trim();
          if (trimmed.isEmpty || containsShellMetacharacters(tok)) {
            warnings.add(
              'Entry allow[$index].allowedArgPrefixes[$j][$k] in $label is empty or contains shell metacharacters; skipping rule.',
            );
            return null;
          }
          tokens.add(trimmed);
        }
        parsedPrefixes.add(tokens);
      }
      argPrefixes = parsedPrefixes;
    }

    var maxTimeoutMs = ExecAllowRule.defaultMaxTimeoutMs;
    if (rawItem.containsKey('maxTimeoutMs')) {
      final rawTimeout = rawItem['maxTimeoutMs'];
      if (rawTimeout is! int ||
          rawTimeout < ExecAllowRule.minTimeoutMs ||
          rawTimeout > ExecAllowRule.maxAllowedTimeoutMs) {
        warnings.add(
          'Entry allow[$index].maxTimeoutMs in $label must be an integer between ${ExecAllowRule.minTimeoutMs} and ${ExecAllowRule.maxAllowedTimeoutMs}; skipping rule.',
        );
        return null;
      }
      maxTimeoutMs = rawTimeout;
    }

    List<List<String>>? mergedPrefixes;
    if (subcommands != null || argPrefixes != null) {
      mergedPrefixes = <List<String>>[];
      final seen = <String>{};
      void addPrefix(List<String> prefix) {
        final key = prefix.join('\u0000');
        if (seen.add(key)) {
          mergedPrefixes!.add(prefix);
        }
      }

      if (subcommands != null) {
        for (final sub in subcommands) {
          addPrefix(<String>[sub]);
        }
      }
      if (argPrefixes != null) {
        for (final prefix in argPrefixes) {
          addPrefix(prefix);
        }
      }
    }

    return ExecAllowRule(
      command: normalizedCommand,
      argPrefixes: mergedPrefixes,
      maxTimeoutMs: maxTimeoutMs,
    );
  }
}

/// Result of loading `.agent_os/exec_policy.json`, including non-fatal structured warnings ([D-506]).
class ExecPolicyLoadResult {
  ExecPolicyLoadResult({
    required this.config,
    required this.sourcePath,
    List<String> warnings = const <String>[],
  }) : warnings = List<String>.unmodifiable(warnings);

  final ExecPolicyConfig config;
  final String? sourcePath;
  final List<String> warnings;

  bool get hasWarnings => warnings.isNotEmpty;
  bool get loadedFromFile => sourcePath != null;
}

/// Loads `.agent_os/exec_policy.json` in precedence order ([D-506]):
/// 1. `<sessionCwd>/.agent_os/exec_policy.json`
/// 2. `<Directory.current>/.agent_os/exec_policy.json`
/// 3. Built-in defaults when absent.
class ExecPolicyConfigLoader {
  ExecPolicyConfigLoader({
    this.sessionCwd,
    String? currentDirectoryPath,
  }) : _currentDirectoryPath = currentDirectoryPath ?? Directory.current.path;

  final String? sessionCwd;
  final String _currentDirectoryPath;

  /// Resolves and parses `.agent_os/exec_policy.json` without throwing on missing or invalid files.
  ExecPolicyLoadResult load() {
    final candidates = <String>[];
    if (sessionCwd != null && sessionCwd!.trim().isNotEmpty) {
      candidates.add(
        p.normalize(
          p.join(sessionCwd!.trim(), '.agent_os', 'exec_policy.json'),
        ),
      );
    }
    final cwdCandidate = p.normalize(
      p.join(_currentDirectoryPath, '.agent_os', 'exec_policy.json'),
    );
    if (candidates.isEmpty || !_pathsEqual(candidates.first, cwdCandidate)) {
      candidates.add(cwdCandidate);
    }

    for (final candidate in candidates) {
      final file = File(candidate);
      if (!file.existsSync()) {
        continue;
      }
      try {
        final content = file.readAsStringSync();
        return ExecPolicyConfig.parseJsonString(content, sourcePath: candidate);
      } catch (e) {
        return ExecPolicyLoadResult(
          config: ExecPolicyConfig.defaults(),
          sourcePath: candidate,
          warnings: <String>[
            'Failed to read $candidate: $e. Falling back to defaults.',
          ],
        );
      }
    }

    return ExecPolicyLoadResult(
      config: ExecPolicyConfig.defaults(),
      sourcePath: null,
    );
  }

  static bool _pathsEqual(String a, String b) {
    if (Platform.isWindows) {
      return a.toLowerCase() == b.toLowerCase();
    }
    return a == b;
  }
}
