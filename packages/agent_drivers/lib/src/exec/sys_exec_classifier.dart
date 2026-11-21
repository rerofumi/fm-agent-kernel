import 'dart:io';

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

  static const Set<String> _externalNetworkCommands = <String>{
    'curl',
    'wget',
    'invoke-webrequest',
    'iwr',
    'invoke-restmethod',
    'irm',
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
    if (_externalNetworkCommands.contains(normalizedBase)) {
      return const SysExecClassification(
        decision: RingDecision.askUser,
        reason:
            'EXTERNAL_NETWORK_COMMAND: Direct network command via sys_exec (prefer delegating web lookup to web_researcher).',
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
