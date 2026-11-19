import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';

/// Stage 3 `beforeSyscall` Hook blocking raw `git` / `jj` CLI execution via `sys_exec` ([D-017]).
///
/// Executes BEFORE Stage 4 Ring 2 approval gating ([D-002]) so habits like
/// `git status`, `echo ok && git diff`, `powershell -c "jj squash"`, and
/// `cmd /c git checkout .` are immediately intercepted with `HOOK_BLOCKED`
/// (`EPERM`) and guided to dedicated `sys_jj_*` / `sys_tx_*` syscalls without
/// prompting the user.
class AntiGitHabitGuardHook extends BaseSyscallHook {
  AntiGitHabitGuardHook();

  static const int _maxRecursionDepth = 10;

  static const Set<String> _blockedVcsCommands = <String>{
    'git',
    'jj',
  };

  static const Set<String> _shellWrappers = <String>{
    'cmd',
    'powershell',
    'pwsh',
    'sh',
    'bash',
    'zsh',
    'fish',
    'ash',
    'dash',
    'wsl',
  };

  static final RegExp _envAssignPattern =
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=.*$');
  static final RegExp _shellMetaSplitCandidate = RegExp(
    r'[&|;\r\n`]|\$\(',
  );

  /// Standard guidance message returned on block ([D-017]).
  static const String guidanceMessage =
      "[HOOK_BLOCKED: AntiGitHabitGuard] Raw 'git' / 'jj' CLI execution via sys_exec is prohibited in this Jujutsu (jj) managed kernel. Use dedicated kernel syscalls instead: sys_jj_status, sys_jj_log, sys_jj_diff (for inspection), or sys_tx_begin, sys_tx_describe, sys_tx_squash, sys_tx_rollback (for change management).";

  @override
  String get name => 'anti_git_habit_guard';

  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async {
    if (context.syscallName != 'sys_exec') {
      return const HookAllow();
    }

    final rawCommand = context.args['command'];
    if (rawCommand is! String || rawCommand.trim().isEmpty) {
      return const HookAllow();
    }

    final rawArgs = context.args['args'];
    final args = rawArgs is List<dynamic>
        ? rawArgs.whereType<String>().toList(growable: false)
        : const <String>[];

    final detectedCmd = _detectBlockedVcsCommand(
      command: rawCommand,
      args: args,
    );
    if (detectedCmd != null) {
      return const HookBlock(
        reason: 'ANTI_GIT_HABIT_GUARD',
        message: guidanceMessage,
        hint:
            'Replace raw git/jj CLI calls with sys_jj_status, sys_jj_log, sys_jj_diff, sys_tx_begin, sys_tx_describe, sys_tx_squash, or sys_tx_rollback.',
      );
    }

    return const HookAllow();
  }

  /// Returns the matched blocked command (`'git'` or `'jj'`) if detected, else `null`.
  String? _detectBlockedVcsCommand({
    required String command,
    required List<String> args,
  }) {
    if (args.isEmpty) {
      return _inspectShellString(command, depth: 0);
    }

    if (_shellMetaSplitCandidate.hasMatch(command)) {
      final fromCmd = _inspectShellString(command, depth: 0);
      if (fromCmd != null) {
        return fromCmd;
      }
    }

    final fromTokens = _inspectTokens(<String>[command, ...args], depth: 0);
    if (fromTokens != null) {
      return fromTokens;
    }

    // If any argument contains unparsed shell chaining/substitution metacharacters
    // that would trigger shell evaluation, inspect the joined command string as well.
    if (args.any(_shellMetaSplitCandidate.hasMatch)) {
      final combined = '$command ${args.join(' ')}';
      return _inspectShellString(combined, depth: 0);
    }

    return null;
  }

  String? _inspectShellString(String script, {required int depth}) {
    if (depth > _maxRecursionDepth) {
      return null;
    }
    final trimmed = script.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final subCommands = _splitSubCommandsAndSubstitutions(trimmed);
    for (final sub in subCommands) {
      final tokens = _tokenizeCommand(sub);
      if (tokens.isEmpty) {
        continue;
      }
      final hit = _inspectTokens(tokens, depth: depth);
      if (hit != null) {
        return hit;
      }
    }
    return null;
  }

  String? _inspectTokens(List<String> tokens, {required int depth}) {
    if (depth > _maxRecursionDepth || tokens.isEmpty) {
      return null;
    }

    // Inspect any command substitutions embedded inside tokens (`$(...)` or `` `...` ``).
    for (final tok in tokens) {
      for (final embedded in _extractSubstitutions(tok)) {
        final hit = _inspectShellString(embedded, depth: depth + 1);
        if (hit != null) {
          return hit;
        }
      }
    }

    var idx = 0;
    while (idx < tokens.length) {
      final tok = tokens[idx];
      if (_envAssignPattern.hasMatch(tok) ||
          tok == '&' ||
          tok == '.' ||
          tok.toLowerCase() == 'call') {
        idx++;
        continue;
      }
      final base = _normalizeExeBase(tok);
      if (base == 'env') {
        idx++;
        while (idx < tokens.length) {
          final next = tokens[idx];
          if (next == '-i' || next == '--ignore-environment') {
            idx++;
            continue;
          }
          if (next == '-u' || next == '--unset') {
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
      break;
    }

    if (idx >= tokens.length) {
      return null;
    }

    final exeBase = _normalizeExeBase(tokens[idx]);
    if (_blockedVcsCommands.contains(exeBase)) {
      return exeBase;
    }

    if (_shellWrappers.contains(exeBase)) {
      final wrapperArgs = tokens.sublist(idx + 1);
      final hit = _inspectShellWrapper(
        wrapper: exeBase,
        wrapperArgs: wrapperArgs,
        depth: depth + 1,
      );
      if (hit != null) {
        return hit;
      }
    }

    return null;
  }

  String? _inspectShellWrapper({
    required String wrapper,
    required List<String> wrapperArgs,
    required int depth,
  }) {
    if (depth > _maxRecursionDepth || wrapperArgs.isEmpty) {
      return null;
    }

    if (wrapper == 'cmd') {
      for (var i = 0; i < wrapperArgs.length; i++) {
        final lower = wrapperArgs[i].toLowerCase();
        if (lower == '/c' || lower == '/k') {
          if (i + 1 < wrapperArgs.length) {
            final inner = wrapperArgs.sublist(i + 1).join(' ');
            return _inspectShellString(inner, depth: depth);
          }
          return null;
        }
      }
      return null;
    }

    if (wrapper == 'powershell' || wrapper == 'pwsh') {
      for (var i = 0; i < wrapperArgs.length; i++) {
        final lower = wrapperArgs[i].toLowerCase();
        if (lower == '-c' ||
            lower == '-command' ||
            lower == '/c' ||
            lower == '/command') {
          if (i + 1 < wrapperArgs.length) {
            final rest = wrapperArgs.sublist(i + 1);
            final inner = rest.length == 1 ? rest.first : rest.join(' ');
            return _inspectShellString(inner, depth: depth);
          }
          return null;
        }
        if (lower == '-enc' || lower == '-encodedcommand') {
          if (i + 1 < wrapperArgs.length) {
            final decoded = _tryDecodePowerShellBase64(wrapperArgs[i + 1]);
            if (decoded != null) {
              return _inspectShellString(decoded, depth: depth);
            }
          }
          return null;
        }
        if (_powerShellValueFlags.contains(lower)) {
          i++; // Skip option value.
          continue;
        }
        if (!lower.startsWith('-') && !lower.startsWith('/')) {
          final inner = wrapperArgs.sublist(i).join(' ');
          return _inspectShellString(inner, depth: depth);
        }
      }
      return null;
    }

    if (wrapper == 'wsl') {
      for (var i = 0; i < wrapperArgs.length; i++) {
        final lower = wrapperArgs[i].toLowerCase();
        if (lower == '-e' || lower == '--exec' || lower == '--') {
          if (i + 1 < wrapperArgs.length) {
            return _inspectTokens(wrapperArgs.sublist(i + 1), depth: depth);
          }
          return null;
        }
        if (lower == '-d' ||
            lower == '--distribution' ||
            lower == '-u' ||
            lower == '--user' ||
            lower == '--cd') {
          i++;
          continue;
        }
        if (!lower.startsWith('-')) {
          return _inspectTokens(wrapperArgs.sublist(i), depth: depth);
        }
      }
      return null;
    }

    // POSIX-like shells: sh, bash, zsh, fish, ash, dash.
    for (var i = 0; i < wrapperArgs.length; i++) {
      final arg = wrapperArgs[i];
      if (arg == '-c' ||
          arg == '--command' ||
          (arg.startsWith('-') && !arg.startsWith('--') && arg.contains('c'))) {
        if (i + 1 < wrapperArgs.length) {
          final rest = wrapperArgs.sublist(i + 1);
          final inner = rest.length == 1 ? rest.first : rest.join(' ');
          return _inspectShellString(inner, depth: depth);
        }
        return null;
      }
    }

    return null;
  }

  static const Set<String> _powerShellValueFlags = <String>{
    '-executionpolicy',
    '-ep',
    '-windowstyle',
    '-w',
    '-inputformat',
    '-if',
    '-outputformat',
    '-of',
    '-file',
    '-f',
    '-configurationname',
    '-workingdirectory',
    '-wd',
  };

  /// Splits a shell string by chaining/pipe operators (`&&`, `||`, `;`, `|`, `&`, `\r`, `\n`)
  /// outside quotes and also extracts any `$(...)` or `` `...` `` command substitutions.
  static List<String> _splitSubCommandsAndSubstitutions(String input) {
    final segments = <String>[];
    final current = StringBuffer();
    String? activeQuote;

    void flushCurrent() {
      final text = current.toString().trim();
      if (text.isNotEmpty) {
        segments.add(text);
      }
      current.clear();
    }

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];

      if (activeQuote == "'") {
        if (ch == "'") {
          activeQuote = null;
        }
        current.write(ch);
        continue;
      }

      if (activeQuote == '"') {
        if (ch == r'\' && i + 1 < input.length) {
          current.write(ch);
          current.write(input[i + 1]);
          i++;
          continue;
        }
        if (ch == '"') {
          activeQuote = null;
          current.write(ch);
          continue;
        }
        if (ch == '`') {
          final end = _findClosingBacktick(input, i + 1);
          if (end > i) {
            segments.add(input.substring(i + 1, end));
            current.write(input.substring(i, end + 1));
            i = end;
            continue;
          }
        }
        if (ch == r'$' && i + 1 < input.length && input[i + 1] == '(') {
          final end = _findClosingParen(input, i + 2);
          if (end > i) {
            segments.add(input.substring(i + 2, end));
            current.write(input.substring(i, end + 1));
            i = end;
            continue;
          }
        }
        current.write(ch);
        continue;
      }

      // Unquoted context.
      if (ch == "'" || ch == '"') {
        activeQuote = ch;
        current.write(ch);
        continue;
      }

      if (ch == '`') {
        final end = _findClosingBacktick(input, i + 1);
        if (end > i) {
          segments.add(input.substring(i + 1, end));
          current.write(input.substring(i, end + 1));
          i = end;
          continue;
        }
      }

      if (ch == r'$' && i + 1 < input.length && input[i + 1] == '(') {
        final end = _findClosingParen(input, i + 2);
        if (end > i) {
          segments.add(input.substring(i + 2, end));
          current.write(input.substring(i, end + 1));
          i = end;
          continue;
        }
      }

      if (ch == '&') {
        flushCurrent();
        if (i + 1 < input.length && input[i + 1] == '&') {
          i++;
        }
        continue;
      }
      if (ch == '|') {
        flushCurrent();
        if (i + 1 < input.length && input[i + 1] == '|') {
          i++;
        }
        continue;
      }
      if (ch == ';' || ch == '\r' || ch == '\n') {
        flushCurrent();
        continue;
      }

      current.write(ch);
    }

    flushCurrent();
    return segments;
  }

  static List<String> _extractSubstitutions(String token) {
    final extracted = <String>[];
    for (var i = 0; i < token.length; i++) {
      final ch = token[i];
      if (ch == '`') {
        final end = _findClosingBacktick(token, i + 1);
        if (end > i) {
          extracted.add(token.substring(i + 1, end));
          i = end;
        }
      } else if (ch == r'$' && i + 1 < token.length && token[i + 1] == '(') {
        final end = _findClosingParen(token, i + 2);
        if (end > i) {
          extracted.add(token.substring(i + 2, end));
          i = end;
        }
      }
    }
    return extracted;
  }

  static int _findClosingBacktick(String s, int start) {
    for (var i = start; i < s.length; i++) {
      if (s[i] == r'\' && i + 1 < s.length) {
        i++;
        continue;
      }
      if (s[i] == '`') {
        return i;
      }
    }
    return -1;
  }

  static int _findClosingParen(String s, int start) {
    var depth = 1;
    String? quote;
    for (var i = start; i < s.length; i++) {
      final ch = s[i];
      if (quote != null) {
        if (quote == '"' && ch == r'\' && i + 1 < s.length) {
          i++;
          continue;
        }
        if (ch == quote) {
          quote = null;
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
        continue;
      }
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
        if (depth == 0) {
          return i;
        }
      }
    }
    return -1;
  }

  static List<String> _tokenizeCommand(String subCommand) {
    final tokens = <String>[];
    final current = StringBuffer();
    var inToken = false;
    String? activeQuote;

    for (var i = 0; i < subCommand.length; i++) {
      final ch = subCommand[i];
      if (activeQuote != null) {
        if (activeQuote == '"' && ch == r'\' && i + 1 < subCommand.length) {
          final next = subCommand[i + 1];
          if (next == '"' || next == r'$' || next == '`') {
            current.write(next);
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

      if (ch == ' ' || ch == '\t') {
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

    if (inToken) {
      tokens.add(current.toString());
    }
    return tokens;
  }

  static String _normalizeExeBase(String rawToken) {
    final normalized = rawToken.trim().replaceAll('/', r'\');
    final slashIdx = normalized.lastIndexOf(r'\');
    final base = slashIdx >= 0 ? normalized.substring(slashIdx + 1) : normalized;
    final lower = base.toLowerCase();
    for (final ext in const <String>['.exe', '.cmd', '.bat', '.ps1']) {
      if (lower.endsWith(ext)) {
        return lower.substring(0, lower.length - ext.length);
      }
    }
    return lower;
  }

  static String? _tryDecodePowerShellBase64(String encoded) {
    try {
      final bytes = base64Decode(encoded.trim());
      if (bytes.length < 2 || bytes.length.isOdd) {
        return null;
      }
      final units = <int>[];
      for (var i = 0; i < bytes.length; i += 2) {
        units.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(units);
    } on Object {
      return null;
    }
  }
}
