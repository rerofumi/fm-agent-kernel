import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

/// Normalized representation of a `sys_exec` command invocation ([D-016], `40_specification.md` §2.3).
class NormalizedExecCommand {
  const NormalizedExecCommand({
    required this.command,
    required this.args,
    required this.hadShellMeta,
    required this.wasSplitFromSingleString,
  });

  final String command;
  final List<String> args;
  final bool hadShellMeta;
  final bool wasSplitFromSingleString;
}

/// Normalizes `sys_exec` `{command, args}` inputs prior to Stage 3/4/5 ([D-016]).
class SysExecCommandNormalizer {
  const SysExecCommandNormalizer._();

  static final RegExp _shellMetaPattern = RegExp(
    r'[&|;><`\r\n\x00%]|\$\(',
  );

  /// Returns true if [input] contains any shell metacharacter or control character.
  static bool containsShellMetacharacters(String input) =>
      _shellMetaPattern.hasMatch(input);

  /// Normalizes `{command, args}` inputs.
  ///
  /// When [args] is omitted (`null`) and [command] contains no shell metacharacters,
  /// splits [command] using quote-aware whitespace tokenization into `exe` and `args`.
  static NormalizedExecCommand normalize({
    required String command,
    List<String>? args,
  }) {
    final trimmedCommand = command.trim();
    if (args != null) {
      final hasMeta = containsShellMetacharacters(trimmedCommand) ||
          args.any(containsShellMetacharacters);
      return NormalizedExecCommand(
        command: trimmedCommand,
        args: List<String>.unmodifiable(args),
        hadShellMeta: hasMeta,
        wasSplitFromSingleString: false,
      );
    }

    if (containsShellMetacharacters(trimmedCommand)) {
      return NormalizedExecCommand(
        command: trimmedCommand,
        args: const <String>[],
        hadShellMeta: true,
        wasSplitFromSingleString: false,
      );
    }

    final tokens = splitQuotedCommand(trimmedCommand);
    if (tokens.isEmpty) {
      return const NormalizedExecCommand(
        command: '',
        args: <String>[],
        hadShellMeta: false,
        wasSplitFromSingleString: false,
      );
    }

    return NormalizedExecCommand(
      command: tokens.first,
      args: List<String>.unmodifiable(tokens.sublist(1)),
      hadShellMeta: false,
      wasSplitFromSingleString: tokens.length > 1,
    );
  }

  /// Splits [input] by whitespace while honoring `'...'` and `"..."` quotes.
  ///
  /// Preserves Windows backslashes outside escaped quote sequences (`\"`).
  /// Throws [FormatException] if a quote remains unterminated.
  static List<String> splitQuotedCommand(String input) {
    final tokens = <String>[];
    final current = StringBuffer();
    var inToken = false;
    String? activeQuote;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];

      if (activeQuote != null) {
        if (activeQuote == '"' && ch == r'\' && i + 1 < input.length) {
          final next = input[i + 1];
          if (next == '"') {
            current.write('"');
            i++;
            continue;
          }
        }
        if (ch == activeQuote) {
          activeQuote = null;
          continue;
        }
        current.write(ch);
        continue;
      }

      if (ch == '"' || ch == "'") {
        activeQuote = ch;
        inToken = true;
        continue;
      }

      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        if (inToken) {
          tokens.add(current.toString());
          current.clear();
          inToken = false;
        }
        continue;
      }

      current.write(ch);
      inToken = true;
    }

    if (activeQuote != null) {
      throw FormatException('Unterminated $activeQuote quote in command.');
    }

    if (inToken) {
      tokens.add(current.toString());
    }

    return tokens;
  }
}

/// Classification outcome produced by [SysExecClassifier] (`40_specification.md` §2.3).
class SysExecClassification {
  const SysExecClassification({
    required this.decision,
    required this.reason,
  });

  final RingDecision decision;
  final String reason;
}

/// Enforces the 5 mandatory Ring 2 immediate-allow conditions for `sys_exec` (`40_specification.md` §2.3).
class SysExecClassifier {
  SysExecClassifier({required this.namespace});

  final VfsNamespace namespace;

  static const int maxAutoAllowTimeoutMs = 120000;

  static const Set<String> _shellWrappers = <String>{
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

  static final RegExp _drivePrefixPattern = RegExp(r'^[a-zA-Z]:');
  static final RegExp _concurrencyEqualsPattern =
      RegExp(r'^--concurrency=([1-8])$');

  static const Set<String> _dartTestFlagOnly = <String>{
    '--fail-fast',
  };

  static const Set<String> _dartTestValueOptions = <String>{
    '-r',
    '--reporter',
    '-n',
    '--name',
    '-N',
    '--plain-name',
    '-t',
    '--tags',
    '-x',
    '--exclude-tags',
  };

  static const Set<String> _dartTestEqualsPrefixes = <String>{
    '--reporter=',
    '--name=',
    '--plain-name=',
    '--tags=',
    '--exclude-tags=',
  };

  static const Set<String> _dartAnalyzeFlagOnly = <String>{
    '--fatal-infos',
    '--fatal-warnings',
  };

  /// Evaluates whether the normalized command satisfies all 5 conditions for `RingDecision.allow`.
  SysExecClassification classify({
    required String command,
    required List<String> args,
    String? workingDir,
    int timeoutMs = 60000,
    VfsNamespace? namespaceOverride,
  }) {
    if (namespaceOverride != null && !identical(namespaceOverride, namespace)) {
      return SysExecClassifier(namespace: namespaceOverride).classify(
        command: command,
        args: args,
        workingDir: workingDir,
        timeoutMs: timeoutMs,
      );
    }
    // Condition 5: Timeout within 120,000 ms.
    if (timeoutMs > maxAutoAllowTimeoutMs) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'TIMEOUT_EXCEEDS_AUTO_ALLOW_LIMIT',
      );
    }

    // Condition 1: Zero shell metacharacters or control characters.
    if (SysExecCommandNormalizer.containsShellMetacharacters(command) ||
        args.any(SysExecCommandNormalizer.containsShellMetacharacters)) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'SHELL_METACHARS_PRESENT',
      );
    }

    // Condition 2: No shell wrappers; must directly invoke `dart` without path separators.
    final trimmedExe = command.trim();
    if (trimmedExe.contains('/') || trimmedExe.contains(r'\')) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'EXECUTABLE_PATH_NOT_ALLOWLISTED',
      );
    }
    final normalizedBase = _normalizeExeBase(trimmedExe);
    if (_shellWrappers.contains(normalizedBase)) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'SHELL_WRAPPER_NOT_ALLOWLISTED',
      );
    }
    if (normalizedBase != 'dart') {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'NON_ALLOWLISTED_EXECUTABLE',
      );
    }

    // Condition 3 (part 1): workingDir must resolve cleanly inside /workspace.
    final effectiveWorkingDir =
        (workingDir == null || workingDir.trim().isEmpty)
            ? VfsNamespace.virtualRoot
            : workingDir.trim();
    final wdRes = namespace.resolveVirtualPath(
      effectiveWorkingDir,
      allowRoot: true,
      checkProtected: true,
      checkSymlinks: true,
    );
    if (!wdRes.ok) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'WORKING_DIR_OUT_OF_SCOPE',
      );
    }

    // Condition 4: Must match allowlisted `dart test`, `dart analyze`, or `dart format --output=none`.
    if (args.isEmpty) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'MISSING_DART_SUBCOMMAND',
      );
    }

    final subcommand = args.first;
    final rest = args.sublist(1);
    return switch (subcommand) {
      'test' => _classifyDartTest(rest),
      'analyze' => _classifyDartAnalyze(rest),
      'format' => _classifyDartFormat(rest),
      _ => const SysExecClassification(
          decision: RingDecision.askUser,
          reason: 'NON_ALLOWLISTED_DART_SUBCOMMAND',
        ),
    };
  }

  SysExecClassification _classifyDartTest(List<String> rest) {
    var i = 0;
    while (i < rest.length) {
      final arg = rest[i];
      if (_dartTestFlagOnly.contains(arg) ||
          _concurrencyEqualsPattern.hasMatch(arg)) {
        i++;
        continue;
      }
      if (_dartTestEqualsPrefixes.any((prefix) => arg.startsWith(prefix))) {
        final eqIdx = arg.indexOf('=');
        if (eqIdx < 0 || eqIdx == arg.length - 1) {
          return const SysExecClassification(
            decision: RingDecision.askUser,
            reason: 'EMPTY_DART_TEST_OPTION_VALUE',
          );
        }
        i++;
        continue;
      }
      if (_dartTestValueOptions.contains(arg)) {
        if (i + 1 >= rest.length) {
          return const SysExecClassification(
            decision: RingDecision.askUser,
            reason: 'MISSING_DART_TEST_OPTION_VALUE',
          );
        }
        final value = rest[i + 1];
        if (value.isEmpty || value.startsWith('-')) {
          return const SysExecClassification(
            decision: RingDecision.askUser,
            reason: 'INVALID_DART_TEST_OPTION_VALUE',
          );
        }
        i += 2;
        continue;
      }
      if (arg.startsWith('-')) {
        return const SysExecClassification(
          decision: RingDecision.askUser,
          reason: 'UNALLOWED_DART_TEST_OPTION',
        );
      }
      if (!_isSafeWorkspacePathArg(arg)) {
        return const SysExecClassification(
          decision: RingDecision.askUser,
          reason: 'UNSAFE_PATH_ARGUMENT',
        );
      }
      i++;
    }

    return const SysExecClassification(
      decision: RingDecision.allow,
      reason: 'ALLOWLISTED_DART_TEST',
    );
  }

  SysExecClassification _classifyDartAnalyze(List<String> rest) {
    var i = 0;
    while (i < rest.length) {
      final arg = rest[i];
      if (_dartAnalyzeFlagOnly.contains(arg)) {
        i++;
        continue;
      }
      if (arg.startsWith('--format=')) {
        final fmtVal = arg.substring('--format='.length);
        if (fmtVal.isEmpty) {
          return const SysExecClassification(
            decision: RingDecision.askUser,
            reason: 'EMPTY_DART_ANALYZE_FORMAT',
          );
        }
        i++;
        continue;
      }
      if (arg == '--format') {
        if (i + 1 >= rest.length ||
            rest[i + 1].isEmpty ||
            rest[i + 1].startsWith('-')) {
          return const SysExecClassification(
            decision: RingDecision.askUser,
            reason: 'INVALID_DART_ANALYZE_FORMAT',
          );
        }
        i += 2;
        continue;
      }
      if (arg.startsWith('-')) {
        return const SysExecClassification(
          decision: RingDecision.askUser,
          reason: 'UNALLOWED_DART_ANALYZE_OPTION',
        );
      }
      if (!_isSafeWorkspacePathArg(arg)) {
        return const SysExecClassification(
          decision: RingDecision.askUser,
          reason: 'UNSAFE_PATH_ARGUMENT',
        );
      }
      i++;
    }

    return const SysExecClassification(
      decision: RingDecision.allow,
      reason: 'ALLOWLISTED_DART_ANALYZE',
    );
  }

  SysExecClassification _classifyDartFormat(List<String> rest) {
    var hasOutputNone = false;
    for (final arg in rest) {
      if (arg == '--output=none') {
        hasOutputNone = true;
        continue;
      }
      if (arg == '--set-exit-if-changed') {
        continue;
      }
      if (arg.startsWith('-')) {
        return const SysExecClassification(
          decision: RingDecision.askUser,
          reason: 'UNALLOWED_DART_FORMAT_OPTION',
        );
      }
      if (!_isSafeWorkspacePathArg(arg)) {
        return const SysExecClassification(
          decision: RingDecision.askUser,
          reason: 'UNSAFE_PATH_ARGUMENT',
        );
      }
    }

    if (!hasOutputNone) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'DART_FORMAT_WITHOUT_OUTPUT_NONE',
      );
    }

    return const SysExecClassification(
      decision: RingDecision.allow,
      reason: 'ALLOWLISTED_DART_FORMAT_CHECK',
    );
  }

  /// Verifies Condition 3 for a path argument: no `..`, no external absolute/UNC/drive paths,
  /// and resolves cleanly within `/workspace` (excluding protected internal paths).
  bool _isSafeWorkspacePathArg(String rawArg) {
    final trimmed = rawArg.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (trimmed.startsWith(r'\\') ||
        trimmed.startsWith('//') ||
        _drivePrefixPattern.hasMatch(trimmed)) {
      return false;
    }

    final forward = trimmed.replaceAll('\\', '/');
    if (forward.split('/').any((seg) => seg == '..')) {
      return false;
    }
    if (forward.startsWith('/') &&
        forward != VfsNamespace.virtualRoot &&
        !forward.startsWith('${VfsNamespace.virtualRoot}/')) {
      return false;
    }

    final resolved = namespace.resolveVirtualPath(
      forward,
      allowRoot: true,
      checkProtected: true,
      checkSymlinks: true,
    );
    return resolved.ok;
  }

  /// Resolves a safe `/workspace/...` argument to a relative path from [hostWorkingDir] for host execution.
  static String resolveHostCommandArg(
    VfsNamespace namespace,
    String hostWorkingDir,
    String rawArg,
  ) {
    final forward = rawArg.trim().replaceAll('\\', '/');
    if (forward == VfsNamespace.virtualRoot ||
        forward.startsWith('${VfsNamespace.virtualRoot}/')) {
      final resolved = namespace.resolveVirtualPath(
        forward,
        allowRoot: true,
        checkProtected: true,
        checkSymlinks: true,
      );
      if (resolved.ok) {
        final rel = p.relative(resolved.value!.hostPath, from: hostWorkingDir);
        return rel == '.' ? '.' : rel.replaceAll('\\', '/');
      }
    }
    return rawArg;
  }

  static String _normalizeExeBase(String rawExe) {
    final lower = rawExe.trim().toLowerCase();
    for (final ext in const <String>['.exe', '.cmd', '.bat']) {
      if (lower.endsWith(ext)) {
        return lower.substring(0, lower.length - ext.length);
      }
    }
    return lower;
  }
}
