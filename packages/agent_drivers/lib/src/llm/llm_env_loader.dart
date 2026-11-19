import 'dart:collection';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

/// Loads environment configuration and API keys in precedence order ([D-004], [D-008], [D-009]):
/// 1. Process environment variables
/// 2. `<sessionCwd>/.agent_os/.env`
/// 3. `<Directory.current>/.agent_os/.env`
///
/// All discovered secret values are immediately registered in [redactor] and never exposed.
class LlmEnvLoader {
  LlmEnvLoader({
    Map<String, String>? processEnvironment,
    this.sessionCwd,
    String? currentDirectoryPath,
    SecretRedactor? redactor,
  })  : _processEnvironment = Map<String, String>.from(
          processEnvironment ?? Platform.environment,
        ),
        _currentDirectoryPath = currentDirectoryPath ?? Directory.current.path,
        redactor = redactor ?? SecretRedactor() {
    _load();
  }

  final Map<String, String> _processEnvironment;
  final String? sessionCwd;
  final String _currentDirectoryPath;
  final SecretRedactor redactor;

  final Map<String, String> _resolved = <String, String>{};
  final List<String> _loadedFiles = <String>[];

  static final RegExp _secretKeyPattern = RegExp(
    r'^(OPENROUTER_API_KEY|OLLAMA_API_KEY|.*_(API_KEY|SECRET|TOKEN|PASSWORD))$',
    caseSensitive: false,
  );

  /// Paths of `.agent_os/.env` files that existed and were loaded.
  UnmodifiableListView<String> get loadedEnvFiles =>
      UnmodifiableListView<String>(_loadedFiles);

  /// Returns the resolved value for [key], or `null` if unset or empty.
  String? get(String key) {
    final value = _resolved[key];
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }

  /// Returns `true` if [key] has a non-empty value without exposing the secret itself.
  bool isConfigured(String key) => get(key) != null;

  /// Returns configuration booleans for [keys] suitable for safe logging/status output.
  Map<String, bool> configuredStatus(Iterable<String> keys) {
    return <String, bool>{
      for (final key in keys) key: isConfigured(key),
    };
  }

  /// Parses `.env` file text into key-value pairs.
  static Map<String, String> parseDotEnv(String content) {
    final result = <String, String>{};
    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      var line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      if (line.startsWith('export ')) {
        line = line.substring('export '.length).trimLeft();
      }
      final eqIdx = line.indexOf('=');
      if (eqIdx <= 0) {
        continue;
      }
      final key = line.substring(0, eqIdx).trim();
      if (key.isEmpty) {
        continue;
      }
      var value = line.substring(eqIdx + 1).trim();
      if (value.length >= 2) {
        final first = value[0];
        final last = value[value.length - 1];
        if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
          value = value.substring(1, value.length - 1);
          if (first == '"') {
            value = value
                .replaceAll(r'\n', '\n')
                .replaceAll(r'\r', '\r')
                .replaceAll(r'\t', '\t')
                .replaceAll(r'\"', '"')
                .replaceAll(r'\\', r'\');
          }
        }
      }
      result[key] = value;
    }
    return result;
  }

  void _load() {
    final layers = <Map<String, String>>[];

    // Priority 3 (lowest): <Directory.current>/.agent_os/.env
    final cwdEnvPath = p.normalize(
      p.join(_currentDirectoryPath, '.agent_os', '.env'),
    );
    final sessionEnvPath = sessionCwd == null || sessionCwd!.trim().isEmpty
        ? null
        : p.normalize(p.join(sessionCwd!, '.agent_os', '.env'));

    if (sessionEnvPath != null) {
      final m = _tryLoadFile(sessionEnvPath);
      if (m != null) {
        layers.add(m);
      }
    }
    if (sessionEnvPath == null || !_pathsEqual(cwdEnvPath, sessionEnvPath)) {
      final m = _tryLoadFile(cwdEnvPath);
      if (m != null) {
        layers.add(m);
      }
    }

    // Apply lowest priority first, then higher priorities overwrite.
    for (final layer in layers.reversed) {
      _mergeLayer(layer);
    }

    // Priority 1 (highest): Process environment variables.
    _mergeLayer(_processEnvironment);
  }

  Map<String, String>? _tryLoadFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      return null;
    }
    try {
      final content = file.readAsStringSync();
      _loadedFiles.add(filePath);
      return parseDotEnv(content);
    } catch (_) {
      return null;
    }
  }

  void _mergeLayer(Map<String, String> source) {
    for (final entry in source.entries) {
      final value = entry.value.trim();
      if (value.isEmpty) {
        continue;
      }
      _resolved[entry.key] = value;
      if (_secretKeyPattern.hasMatch(entry.key)) {
        redactor.registerSecret(value);
      }
    }
  }

  static bool _pathsEqual(String a, String b) {
    if (Platform.isWindows) {
      return a.toLowerCase() == b.toLowerCase();
    }
    return a == b;
  }

  @override
  String toString() {
    final keys = _resolved.keys.where((k) => !_secretKeyPattern.hasMatch(k));
    return 'LlmEnvLoader(files: ${_loadedFiles.length}, nonSecretKeys: ${keys.length})';
  }
}
