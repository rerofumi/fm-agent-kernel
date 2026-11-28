import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

import 'exec_policy_config.dart';

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

  /// Returns true if [input] contains any shell metacharacter or control character.
  static bool containsShellMetacharacters(String input) =>
      ExecPolicyConfig.containsShellMetacharacters(input);

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

/// Enforces Ring 2/3 immediate-allow conditions and common hard guards for `sys_exec` ([D-016], [D-507]).
class SysExecClassifier {
  SysExecClassifier({
    required this.namespace,
    ExecPolicyConfig? policy,
  }) : policy = policy ?? ExecPolicyConfig.defaults();

  final VfsNamespace namespace;
  final ExecPolicyConfig policy;

  static const int maxAutoAllowTimeoutMs = 120000;

  static final RegExp _drivePrefixPattern = RegExp(r'^[a-zA-Z]:');
  static final RegExp _urlSchemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');
  static final RegExp _concurrencyEqualsPattern =
      RegExp(r'^--concurrency=([1-8])$');
  static final RegExp _envAssignPattern =
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=.*$');

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

  /// Evaluates whether the normalized command satisfies common hard guards and allowlist rules ([D-507], [D-705]).
  SysExecClassification classify({
    required String command,
    required List<String> args,
    String? workingDir,
    int timeoutMs = 60000,
    ProtectionRing callerRing = ProtectionRing.ring2,
    VfsNamespace? namespaceOverride,
  }) {
    if (namespaceOverride != null && !identical(namespaceOverride, namespace)) {
      return SysExecClassifier(
        namespace: namespaceOverride,
        policy: policy,
      ).classify(
        command: command,
        args: args,
        workingDir: workingDir,
        timeoutMs: timeoutMs,
        callerRing: callerRing,
      );
    }

    final isRing3 = callerRing == ProtectionRing.ring3;
    final hardGuardDecision =
        isRing3 ? RingDecision.deny : RingDecision.askUser;

    // Step 1: Common hard guards (always evaluated before built-in and custom rules).
    if (SysExecCommandNormalizer.containsShellMetacharacters(command) ||
        args.any(SysExecCommandNormalizer.containsShellMetacharacters)) {
      return SysExecClassification(
        decision: hardGuardDecision,
        reason: 'SHELL_METACHARS_PRESENT',
      );
    }

    final trimmedExe = command.trim();
    if (trimmedExe.isEmpty ||
        trimmedExe.contains('/') ||
        trimmedExe.contains(r'\') ||
        trimmedExe.contains(':')) {
      return SysExecClassification(
        decision: hardGuardDecision,
        reason: 'EXECUTABLE_PATH_NOT_ALLOWLISTED',
      );
    }

    final normalizedBase = _normalizeExeBase(trimmedExe);
    if (normalizedBase.isEmpty) {
      return SysExecClassification(
        decision: hardGuardDecision,
        reason: 'EXECUTABLE_PATH_NOT_ALLOWLISTED',
      );
    }
    if (ExecPolicyConfig.shellWrappers.contains(normalizedBase)) {
      return SysExecClassification(
        decision: hardGuardDecision,
        reason: 'SHELL_WRAPPER_NOT_ALLOWLISTED',
      );
    }
    if (ExecPolicyConfig.externalNetworkCommands.contains(normalizedBase)) {
      return SysExecClassification(
        decision: hardGuardDecision,
        reason:
            'EXTERNAL_NETWORK_COMMAND: Direct network command via sys_exec (prefer delegating web lookup to web_researcher).',
      );
    }
    if (ExecPolicyConfig.blockedVcsCommands.contains(normalizedBase)) {
      return SysExecClassification(
        decision: hardGuardDecision,
        reason: 'VCS_COMMAND_NOT_ALLOWLISTED',
      );
    }

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
    if (!wdRes.ok || wdRes.value!.isSkillsMount || wdRes.value!.isReadOnly) {
      return SysExecClassification(
        decision: hardGuardDecision,
        reason: 'WORKING_DIR_OUT_OF_SCOPE',
      );
    }
    final resolvedWorkingVirtualDir = wdRes.value!.virtualPath;

    SysExecClassification finalizeRing3(SysExecClassification result) {
      if (!isRing3 || result.decision != RingDecision.askUser) {
        return result;
      }
      final argsFailure = _validateCustomCommandArgs(
        args,
        workingVirtualDir: resolvedWorkingVirtualDir,
        violationDecision: RingDecision.deny,
      );
      if (argsFailure != null) {
        return argsFailure;
      }
      return result;
    }

    // Step 2: Built-in `dart` 3 rules (preserve existing timeout & reason codes).
    if (normalizedBase == 'dart') {
      final builtinResult = _classifyBuiltinDart(
        args: args,
        resolvedWorkingVirtualDir: resolvedWorkingVirtualDir,
        timeoutMs: timeoutMs,
      );
      if (builtinResult.decision == RingDecision.allow) {
        return builtinResult;
      }
      if (policy.rulesForCommand(normalizedBase).isNotEmpty) {
        final customResult = _classifyWithExecPolicy(
          normalizedBase: normalizedBase,
          args: args,
          resolvedWorkingVirtualDir: resolvedWorkingVirtualDir,
          timeoutMs: timeoutMs,
          violationDecision: hardGuardDecision,
        );
        if (customResult.decision == RingDecision.allow) {
          return customResult;
        }
      }
      return finalizeRing3(builtinResult);
    }

    // Step 3: Custom `.agent_os/exec_policy.json` rules.
    return finalizeRing3(
      _classifyWithExecPolicy(
        normalizedBase: normalizedBase,
        args: args,
        resolvedWorkingVirtualDir: resolvedWorkingVirtualDir,
        timeoutMs: timeoutMs,
        violationDecision: hardGuardDecision,
      ),
    );
  }

  SysExecClassification _classifyBuiltinDart({
    required List<String> args,
    required String resolvedWorkingVirtualDir,
    required int timeoutMs,
  }) {
    if (timeoutMs > maxAutoAllowTimeoutMs) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'TIMEOUT_EXCEEDS_AUTO_ALLOW_LIMIT',
      );
    }
    if (args.isEmpty) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'MISSING_DART_SUBCOMMAND',
      );
    }

    final subcommand = args.first;
    final rest = args.sublist(1);
    return switch (subcommand) {
      'test' => _classifyDartTest(rest, resolvedWorkingVirtualDir),
      'analyze' => _classifyDartAnalyze(rest, resolvedWorkingVirtualDir),
      'format' => _classifyDartFormat(rest, resolvedWorkingVirtualDir),
      _ => const SysExecClassification(
          decision: RingDecision.askUser,
          reason: 'NON_ALLOWLISTED_DART_SUBCOMMAND',
        ),
    };
  }

  SysExecClassification _classifyWithExecPolicy({
    required String normalizedBase,
    required List<String> args,
    required String resolvedWorkingVirtualDir,
    required int timeoutMs,
    RingDecision violationDecision = RingDecision.askUser,
  }) {
    final rules = policy.rulesForCommand(normalizedBase);
    if (rules.isEmpty) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'NON_ALLOWLISTED_EXECUTABLE',
      );
    }

    final argsFailure = _validateCustomCommandArgs(
      args,
      workingVirtualDir: resolvedWorkingVirtualDir,
      violationDecision: violationDecision,
    );
    if (argsFailure != null) {
      return argsFailure;
    }

    final matchingRules =
        rules.where((rule) => rule.matchesArgs(args)).toList(growable: false);
    if (matchingRules.isEmpty) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'NON_ALLOWLISTED_SUBCOMMAND',
      );
    }

    final allowsTimeout =
        matchingRules.any((rule) => timeoutMs <= rule.maxTimeoutMs);
    if (!allowsTimeout) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason: 'TIMEOUT_EXCEEDS_AUTO_ALLOW_LIMIT',
      );
    }

    return const SysExecClassification(
      decision: RingDecision.allow,
      reason: 'ALLOWLISTED_BY_EXEC_POLICY',
    );
  }

  SysExecClassification? _validateCustomCommandArgs(
    List<String> args, {
    required String workingVirtualDir,
    RingDecision violationDecision = RingDecision.askUser,
  }) {
    for (var i = 0; i < args.length; i++) {
      final trimmed = args[i].trim();
      if (trimmed.isEmpty) {
        return SysExecClassification(
          decision: violationDecision,
          reason: 'EMPTY_ARGUMENT',
        );
      }

      if (trimmed == '--' && i + 1 < args.length) {
        final targetBase = _resolveEffectiveWrappedCommand(
          args.sublist(i + 1),
        );
        if (targetBase != null &&
            ExecPolicyConfig.forbiddenCommands.contains(targetBase)) {
          return SysExecClassification(
            decision: violationDecision,
            reason: 'WRAPPER_TARGET_NOT_ALLOWLISTED',
          );
        }
      }

      if (trimmed.startsWith('-') && !trimmed.contains('=')) {
        if (_hasUnsafeFlagChars(trimmed)) {
          return SysExecClassification(
            decision: violationDecision,
            reason: 'UNSAFE_FLAG_ARGUMENT',
          );
        }
      } else if (trimmed.startsWith('-') && trimmed.contains('=')) {
        final eqIdx = trimmed.indexOf('=');
        final flagPart = trimmed.substring(0, eqIdx);
        final valuePart = trimmed.substring(eqIdx + 1).trim();
        if (flagPart == '-' ||
            flagPart == '--' ||
            _hasUnsafeFlagChars(flagPart)) {
          return SysExecClassification(
            decision: violationDecision,
            reason: 'UNSAFE_FLAG_ARGUMENT',
          );
        }
        if (valuePart.isEmpty ||
            !_isSafeWorkspaceToken(
              valuePart,
              workingVirtualDir: workingVirtualDir,
            )) {
          return SysExecClassification(
            decision: violationDecision,
            reason: 'UNSAFE_PATH_ARGUMENT',
          );
        }
      } else {
        if (!_isSafeWorkspaceToken(
          trimmed,
          workingVirtualDir: workingVirtualDir,
        )) {
          return SysExecClassification(
            decision: violationDecision,
            reason: 'UNSAFE_PATH_ARGUMENT',
          );
        }
      }
    }
    return null;
  }

  /// Resolves the first effective command token after `--`, skipping leading `env`,
  /// `KEY=VAL` assignments, and `env` flags, then normalizing with [ExecAllowRule.normalizeCommandBasename] ([D-705]).
  static String? _resolveEffectiveWrappedCommand(List<String> tokens) {
    var idx = 0;
    while (idx < tokens.length) {
      final tok = tokens[idx].trim();
      if (tok.isEmpty) {
        idx++;
        continue;
      }
      if (_envAssignPattern.hasMatch(tok)) {
        idx++;
        continue;
      }
      final base = ExecAllowRule.normalizeCommandBasename(tok);
      if (base == 'env') {
        idx++;
        while (idx < tokens.length) {
          final next = tokens[idx].trim();
          if (next == '-i' || next == '--ignore-environment') {
            idx++;
            continue;
          }
          if (next == '-u' ||
              next == '--unset' ||
              next == '-C' ||
              next == '--chdir') {
            idx += 2;
            continue;
          }
          if (next.startsWith('-') || _envAssignPattern.hasMatch(next)) {
            idx++;
            continue;
          }
          break;
        }
        continue;
      }
      return base;
    }
    return null;
  }

  static bool _hasUnsafeFlagChars(String flag) {
    final lower = flag.toLowerCase();
    return flag.contains('/') ||
        flag.contains(r'\') ||
        flag.contains(':') ||
        flag.contains('..') ||
        lower.contains('.jj') ||
        lower.contains('.git') ||
        lower.contains('.agent_os') ||
        lower.contains('.env');
  }

  SysExecClassification _classifyDartTest(
    List<String> rest,
    String workingVirtualDir,
  ) {
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
      if (!_isSafeWorkspacePathArg(
        arg,
        workingVirtualDir: workingVirtualDir,
      )) {
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

  SysExecClassification _classifyDartAnalyze(
    List<String> rest,
    String workingVirtualDir,
  ) {
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
      if (!_isSafeWorkspacePathArg(
        arg,
        workingVirtualDir: workingVirtualDir,
      )) {
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

  SysExecClassification _classifyDartFormat(
    List<String> rest,
    String workingVirtualDir,
  ) {
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
      if (!_isSafeWorkspacePathArg(
        arg,
        workingVirtualDir: workingVirtualDir,
      )) {
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

  /// Verifies path/value token safety for built-in and custom commands within `/workspace`.
  bool _isSafeWorkspaceToken(
    String rawToken, {
    required String workingVirtualDir,
  }) {
    final trimmed = rawToken.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (trimmed.startsWith(r'\\') ||
        trimmed.startsWith('//') ||
        _drivePrefixPattern.hasMatch(trimmed) ||
        trimmed.contains(':') ||
        _urlSchemePattern.hasMatch(trimmed)) {
      return false;
    }

    final forward = trimmed.replaceAll('\\', '/');
    for (final seg in forward.split('/')) {
      if (seg == '..' || VfsNamespace.isProtectedSegment(seg)) {
        return false;
      }
    }

    final String virtualCandidate;
    if (forward.startsWith('/')) {
      if (forward != VfsNamespace.virtualRoot &&
          !forward.startsWith('${VfsNamespace.virtualRoot}/')) {
        return false;
      }
      virtualCandidate = forward;
    } else {
      virtualCandidate = workingVirtualDir == VfsNamespace.virtualRoot
          ? '${VfsNamespace.virtualRoot}/$forward'
          : '$workingVirtualDir/$forward';
    }

    final resolved = namespace.resolveVirtualPath(
      virtualCandidate,
      allowRoot: true,
      checkProtected: true,
      checkSymlinks: true,
    );
    return resolved.ok;
  }

  /// Verifies Condition 3 for a path argument: no `..`, no external absolute/UNC/drive paths,
  /// and resolves cleanly within `/workspace` (excluding protected internal paths).
  bool _isSafeWorkspacePathArg(
    String rawArg, {
    String workingVirtualDir = VfsNamespace.virtualRoot,
  }) {
    return _isSafeWorkspaceToken(
      rawArg,
      workingVirtualDir: workingVirtualDir,
    );
  }

  /// Resolves a safe `/workspace/...` argument (or `--flag=/workspace/...`) to a relative path from [hostWorkingDir].
  static String resolveHostCommandArg(
    VfsNamespace namespace,
    String hostWorkingDir,
    String rawArg,
  ) {
    final trimmed = rawArg.trim();
    if (trimmed.startsWith('-') && trimmed.contains('=')) {
      final eqIdx = trimmed.indexOf('=');
      final prefix = trimmed.substring(0, eqIdx);
      final value = trimmed.substring(eqIdx + 1).trim();
      final resolvedValue = _resolveStandaloneVirtualArg(
        namespace,
        hostWorkingDir,
        value,
      );
      if (resolvedValue != null) {
        return '$prefix=$resolvedValue';
      }
      return rawArg;
    }
    return _resolveStandaloneVirtualArg(
          namespace,
          hostWorkingDir,
          trimmed,
        ) ??
        rawArg;
  }

  static String? _resolveStandaloneVirtualArg(
    VfsNamespace namespace,
    String hostWorkingDir,
    String arg,
  ) {
    final forward = arg.trim().replaceAll('\\', '/');
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
    return null;
  }

  static String _normalizeExeBase(String rawExe) =>
      ExecAllowRule.normalizeCommandName(rawExe);
}

/// Computes the Ring 2 `allow_always` approval signature and human-readable scope
/// for a `sys_exec` invocation ([D-001]).
class SysExecApprovalScope {
  const SysExecApprovalScope({
    required this.signature,
    required this.scopeDescription,
    required this.isOriginScoped,
  });

  final String signature;
  final String scopeDescription;
  final bool isOriginScoped;

  static final RegExp _otherSchemePattern =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');

  /// Builds an origin-scoped signature only when all strict read-only safety
  /// conditions hold; otherwise falls back to exact-command matching.
  static SysExecApprovalScope build({
    required String command,
    List<String>? args,
    String? workingDir,
  }) {
    final effectiveWorkingDir =
        (workingDir == null || workingDir.trim().isEmpty)
            ? VfsNamespace.virtualRoot
            : workingDir.trim();
    final rawArgsList = args ?? const <String>[];

    SysExecApprovalScope fallback() {
      return SysExecApprovalScope(
        signature:
            '$command\u0000${rawArgsList.join('\u0000')}\u0000$effectiveWorkingDir',
        scopeDescription: 'Exact command in $effectiveWorkingDir',
        isOriginScoped: false,
      );
    }

    final NormalizedExecCommand normalized;
    try {
      normalized = SysExecCommandNormalizer.normalize(
        command: command,
        args: args,
      );
    } on FormatException {
      return fallback();
    }

    if (normalized.hadShellMeta ||
        SysExecCommandNormalizer.containsShellMetacharacters(
          normalized.command,
        ) ||
        normalized.args.any(
          SysExecCommandNormalizer.containsShellMetacharacters,
        )) {
      return fallback();
    }

    final trimmedExe = normalized.command.trim();
    if (trimmedExe.isEmpty ||
        trimmedExe.contains('/') ||
        trimmedExe.contains(r'\')) {
      return fallback();
    }

    final lowerExe = trimmedExe.toLowerCase();
    final exeBase = lowerExe.endsWith('.exe')
        ? lowerExe.substring(0, lowerExe.length - 4)
        : lowerExe;
    if (exeBase != 'curl' && exeBase != 'wget') {
      return fallback();
    }

    if (exeBase == 'curl' && _hasDisallowedCurlOptions(normalized.args)) {
      return fallback();
    }
    if (exeBase == 'wget' && _hasDisallowedWgetOptions(normalized.args)) {
      return fallback();
    }

    final urls = <Uri>[];
    for (final arg in normalized.args) {
      final lowerArg = arg.toLowerCase();
      if (lowerArg.startsWith('http://') || lowerArg.startsWith('https://')) {
        final uri = Uri.tryParse(arg);
        if (uri == null ||
            (uri.scheme != 'http' && uri.scheme != 'https') ||
            !uri.hasAuthority ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          return fallback();
        }
        urls.add(uri);
      } else if (_otherSchemePattern.hasMatch(arg)) {
        return fallback();
      }
    }

    if (urls.length != 1) {
      return fallback();
    }

    final targetUri = urls.single;
    if (_isDisallowedOriginHost(targetUri.host)) {
      return fallback();
    }

    final origin = targetUri.origin;
    return SysExecApprovalScope(
      signature: 'exec:net_read:$exeBase\u0000$origin\u0000$effectiveWorkingDir',
      scopeDescription:
          'Read-only $exeBase requests to $origin (in $effectiveWorkingDir)',
      isOriginScoped: true,
    );
  }

  static bool _hasDisallowedCurlOptions(List<String> args) {
    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      if (arg == '-:' ||
          arg == ':' ||
          arg == '--next' ||
          arg.startsWith('--next=') ||
          arg == '--url' ||
          arg.startsWith('--url=')) {
        return true;
      }
      if (arg.startsWith('-d') ||
          arg == '--data' ||
          arg.startsWith('--data-') ||
          arg.startsWith('--data=') ||
          arg == '--json' ||
          arg.startsWith('--json=') ||
          arg.startsWith('-F') ||
          arg == '--form' ||
          arg.startsWith('--form-') ||
          arg.startsWith('--form=') ||
          arg.startsWith('-T') ||
          arg == '--upload-file' ||
          arg.startsWith('--upload-file=') ||
          arg.startsWith('-K') ||
          arg == '--config' ||
          arg.startsWith('--config=')) {
        return true;
      }
      if (arg == '-X' || arg == '--request') {
        if (i + 1 >= args.length) {
          return true;
        }
        final method = args[i + 1].toUpperCase();
        if (method != 'GET' && method != 'HEAD') {
          return true;
        }
        i += 2;
        continue;
      }
      if (arg.startsWith('--request=')) {
        final method = arg.substring('--request='.length).toUpperCase();
        if (method != 'GET' && method != 'HEAD') {
          return true;
        }
        i++;
        continue;
      }
      if (arg.startsWith('-X') && arg.length > 2) {
        final method = arg.substring(2).toUpperCase();
        if (method != 'GET' && method != 'HEAD') {
          return true;
        }
        i++;
        continue;
      }
      if (arg.startsWith('-') && !arg.startsWith('--') && arg.length > 1) {
        final flags = arg.substring(1);
        for (var j = 0; j < flags.length; j++) {
          final ch = flags[j];
          if (ch == 'd' || ch == 'F' || ch == 'T' || ch == 'K' || ch == 'X') {
            return true;
          }
        }
      }
      i++;
    }
    return false;
  }

  static bool _hasDisallowedWgetOptions(List<String> args) {
    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      if (arg == '--post-data' ||
          arg.startsWith('--post-data=') ||
          arg == '--post-file' ||
          arg.startsWith('--post-file=') ||
          arg == '--body-data' ||
          arg.startsWith('--body-data=') ||
          arg == '--body-file' ||
          arg.startsWith('--body-file=') ||
          arg.startsWith('-i') ||
          arg == '--input-file' ||
          arg.startsWith('--input-file=')) {
        return true;
      }
      if (arg == '--method') {
        if (i + 1 >= args.length) {
          return true;
        }
        final method = args[i + 1].toUpperCase();
        if (method != 'GET' && method != 'HEAD') {
          return true;
        }
        i += 2;
        continue;
      }
      if (arg.startsWith('--method=')) {
        final method = arg.substring('--method='.length).toUpperCase();
        if (method != 'GET' && method != 'HEAD') {
          return true;
        }
        i++;
        continue;
      }
      if (arg.startsWith('--method')) {
        return true;
      }
      if (arg.startsWith('-') && !arg.startsWith('--') && arg.length > 1) {
        if (arg.substring(1).contains('i')) {
          return true;
        }
      }
      i++;
    }
    return false;
  }

  static bool _isDisallowedOriginHost(String rawHost) {
    final host = rawHost.trim().toLowerCase();
    var noTrailingDot = host;
    while (noTrailingDot.endsWith('.')) {
      noTrailingDot = noTrailingDot.substring(0, noTrailingDot.length - 1);
    }
    if (noTrailingDot.isEmpty) {
      return true;
    }
    if (noTrailingDot == 'localhost' || noTrailingDot.endsWith('.localhost')) {
      return true;
    }
    if (host.contains('%')) {
      return true;
    }

    final ip = InternetAddress.tryParse(host);
    if (ip == null) {
      return false;
    }
    if (ip.isLoopback || ip.isLinkLocal) {
      return true;
    }

    final bytes = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return _isDisallowedIpv4Bytes(bytes[0], bytes[1], bytes[2], bytes[3]);
    }
    if (ip.type == InternetAddressType.IPv6 && bytes.length == 16) {
      final isAllZeroPrefix12 = bytes.take(12).every((b) => b == 0);
      if (isAllZeroPrefix12) {
        // Covers :: (all zeros), ::1 (loopback), and IPv4-compatible ::w.x.y.z
        if (bytes[12] == 0 && bytes[13] == 0 && bytes[14] == 0 && bytes[15] <= 1) {
          return true;
        }
        return _isDisallowedIpv4Bytes(bytes[12], bytes[13], bytes[14], bytes[15]);
      }
      // fc00::/7 (Unique Local Addresses)
      if ((bytes[0] & 0xfe) == 0xfc) {
        return true;
      }
      // fe80::/10 (Link-local)
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
        return true;
      }
      // ::ffff:0:0/96 (IPv4-mapped IPv6)
      final isIpv4Mapped = bytes.take(10).every((b) => b == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff;
      if (isIpv4Mapped) {
        return _isDisallowedIpv4Bytes(bytes[12], bytes[13], bytes[14], bytes[15]);
      }
    }
    return false;
  }

  static bool _isDisallowedIpv4Bytes(int b0, int b1, int b2, int b3) {
    if (b0 == 0) return true; // 0.0.0.0/8
    if (b0 == 127) return true; // 127.0.0.0/8
    if (b0 == 10) return true; // 10.0.0.0/8
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return true; // 172.16.0.0/12
    if (b0 == 192 && b1 == 168) return true; // 192.168.0.0/16
    if (b0 == 169 && b1 == 254) return true; // 169.254.0.0/16
    return false;
  }
}
