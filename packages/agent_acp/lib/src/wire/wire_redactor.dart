/// Pure-Dart secret redactor interface for the engine-independent wire layer ([D-322]).
abstract interface class WireRedactor {
  String redactString(String input);
  dynamic redactJson(dynamic value, {String? keyName});
}

/// Pure-Dart secret redactor that masks API keys, Bearer tokens, and
/// explicitly registered secret strings without importing `agent_kernel` ([D-322]).
class WireSecretRedactor implements WireRedactor {
  WireSecretRedactor({
    Iterable<String> initialSecrets = const <String>[],
  }) {
    for (final secret in initialSecrets) {
      registerSecret(secret);
    }
  }

  static const String redactedToken = '<REDACTED>';

  static final RegExp _bearerPattern =
      RegExp(r'Bearer\s+[A-Za-z0-9._\-~+/]+=*', caseSensitive: false);
  static final RegExp _openRouterKeyPattern =
      RegExp(r'sk-or-v1-[A-Za-z0-9_-]{8,}');
  static final RegExp _genericSkKeyPattern = RegExp(r'sk-[A-Za-z0-9_-]{16,}');
  static final RegExp _secretEnvKeyPattern = RegExp(
    r'^(OPENROUTER_API_KEY|OLLAMA_API_KEY|.*_(API_KEY|SECRET|TOKEN|PASSWORD))$',
    caseSensitive: false,
  );
  static const Set<String> _secretJsonFieldNames = <String>{
    'authorization',
    'x-api-key',
    'api_key',
    'apikey',
    'secret',
    'password',
    'access_token',
    'auth_token',
    'bearer_token',
  };

  final Set<String> _registeredSecrets = <String>{};

  /// Registers an explicit secret value to be masked across all outputs.
  void registerSecret(String? secret) {
    if (secret == null) {
      return;
    }
    final trimmed = secret.trim();
    if (trimmed.length >= 4) {
      _registeredSecrets.add(trimmed);
    }
  }

  /// Registers any secret environment variable values without exposing them.
  void registerFromEnvironment(Map<String, String> environment) {
    for (final entry in environment.entries) {
      if (_secretEnvKeyPattern.hasMatch(entry.key)) {
        registerSecret(entry.value);
      }
    }
  }

  @override
  String redactString(String input) {
    if (input.isEmpty) {
      return input;
    }
    var result = input;
    if (_registeredSecrets.isNotEmpty) {
      final sorted = _registeredSecrets.toList(growable: false)
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final secret in sorted) {
        if (result.contains(secret)) {
          result = result.replaceAll(secret, redactedToken);
        }
      }
    }
    result = result.replaceAll(_bearerPattern, 'Bearer $redactedToken');
    result = result.replaceAll(_openRouterKeyPattern, redactedToken);
    result = result.replaceAll(_genericSkKeyPattern, redactedToken);
    return result;
  }

  @override
  dynamic redactJson(dynamic value, {String? keyName}) {
    if (keyName != null &&
        _secretJsonFieldNames.contains(keyName.toLowerCase()) &&
        value is String &&
        value.trim().isNotEmpty) {
      if (keyName.toLowerCase() == 'authorization' &&
          value.trimLeft().toLowerCase().startsWith('bearer ')) {
        return 'Bearer $redactedToken';
      }
      return redactedToken;
    }

    if (value is String) {
      return redactString(value);
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        final k = entry.key.toString();
        out[k] = redactJson(entry.value, keyName: k);
      }
      return out;
    }
    if (value is List) {
      return value.map((item) => redactJson(item)).toList(growable: false);
    }
    return value;
  }
}
