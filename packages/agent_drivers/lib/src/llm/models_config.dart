import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

import 'llm_env_loader.dart';

/// Per-provider configuration loaded from `.agent_os/models.json` ([D-406], [D-407]).
class ProviderModelsConfig {
  ProviderModelsConfig({
    required this.provider,
    this.enable = true,
    this.autoFetch = true,
    List<String> models = const <String>[],
    String? baseUrl,
  })  : models = List<String>.unmodifiable(models),
        baseUrl = _normalizeOptionalString(baseUrl);

  /// Returns the default configuration for [provider] (`enable: true`, `autoFetch: true`, `models: []`).
  factory ProviderModelsConfig.defaults(LlmProviderId provider) {
    return ProviderModelsConfig(provider: provider);
  }

  final LlmProviderId provider;
  final bool enable;
  final bool autoFetch;
  final List<String> models;
  final String? baseUrl;

  /// Normalizes a manual model entry by stripping a leading `<provider.id>/` prefix if present ([D-406]).
  static String normalizeModelName(LlmProviderId provider, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final prefix = '${provider.id}/';
    if (trimmed.startsWith(prefix)) {
      return trimmed.substring(prefix.length).trim();
    }
    return trimmed;
  }

  static String? _normalizeOptionalString(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Parsed `.agent_os/models.json` configuration across all supported providers ([D-406]).
class ModelsConfig {
  ModelsConfig({
    Map<LlmProviderId, ProviderModelsConfig> providers =
        const <LlmProviderId, ProviderModelsConfig>{},
  }) : _providers = Map<LlmProviderId, ProviderModelsConfig>.unmodifiable(
          <LlmProviderId, ProviderModelsConfig>{
            for (final id in LlmProviderId.values)
              id: providers[id] ?? ProviderModelsConfig.defaults(id),
          },
        );

  /// Default configuration where all providers have `enable: true`, `autoFetch: true`, `models: []`.
  factory ModelsConfig.defaults() => ModelsConfig();

  final Map<LlmProviderId, ProviderModelsConfig> _providers;

  UnmodifiableMapView<LlmProviderId, ProviderModelsConfig> get providers =>
      UnmodifiableMapView<LlmProviderId, ProviderModelsConfig>(_providers);

  /// Returns the configuration for [provider].
  ProviderModelsConfig forProvider(LlmProviderId provider) =>
      _providers[provider] ?? ProviderModelsConfig.defaults(provider);

  /// Parses [rawJson] into a [ModelsConfigLoadResult] without throwing on syntax or schema errors ([D-406]).
  static ModelsConfigLoadResult parseJsonString(
    String rawJson, {
    String? sourcePath,
  }) {
    final warnings = <String>[];
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException catch (e) {
      warnings.add(
        'Invalid JSON syntax in ${sourcePath ?? 'models.json'}: ${e.message}. Falling back to defaults.',
      );
      return ModelsConfigLoadResult(
        config: ModelsConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    } catch (e) {
      warnings.add(
        'Failed to decode ${sourcePath ?? 'models.json'}: $e. Falling back to defaults.',
      );
      return ModelsConfigLoadResult(
        config: ModelsConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    }

    if (decoded is! Map) {
      warnings.add(
        'Root of ${sourcePath ?? 'models.json'} must be a JSON object. Falling back to defaults.',
      );
      return ModelsConfigLoadResult(
        config: ModelsConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    }

    final rawProviders = decoded['providers'];
    if (rawProviders == null) {
      return ModelsConfigLoadResult(
        config: ModelsConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    }
    if (rawProviders is! Map) {
      warnings.add(
        '"providers" in ${sourcePath ?? 'models.json'} must be a JSON object. Falling back to defaults.',
      );
      return ModelsConfigLoadResult(
        config: ModelsConfig.defaults(),
        sourcePath: sourcePath,
        warnings: warnings,
      );
    }

    final parsedProviders = <LlmProviderId, ProviderModelsConfig>{};
    for (final entry in rawProviders.entries) {
      final rawKey = entry.key.toString();
      final providerId = LlmProviderId.tryParse(rawKey);
      if (providerId == null) {
        warnings.add(
          'Unknown provider "$rawKey" in ${sourcePath ?? 'models.json'}; ignoring.',
        );
        continue;
      }

      final rawCfg = entry.value;
      if (rawCfg is! Map) {
        warnings.add(
          'Configuration for provider "$rawKey" in ${sourcePath ?? 'models.json'} must be a JSON object; ignoring.',
        );
        continue;
      }

      var enable = true;
      final rawEnable = rawCfg['enable'];
      if (rawEnable != null) {
        if (rawEnable is bool) {
          enable = rawEnable;
        } else {
          warnings.add(
            'Field "providers.$rawKey.enable" must be a boolean; defaulting to true.',
          );
        }
      }

      var autoFetch = true;
      final rawAutoFetch = rawCfg['autoFetch'];
      if (rawAutoFetch != null) {
        if (rawAutoFetch is bool) {
          autoFetch = rawAutoFetch;
        } else {
          warnings.add(
            'Field "providers.$rawKey.autoFetch" must be a boolean; defaulting to true.',
          );
        }
      }

      String? baseUrl;
      final rawBaseUrl = rawCfg['baseUrl'];
      if (rawBaseUrl != null) {
        if (rawBaseUrl is String) {
          final trimmed = rawBaseUrl.trim();
          if (trimmed.isNotEmpty) {
            baseUrl = trimmed;
          }
        } else {
          warnings.add(
            'Field "providers.$rawKey.baseUrl" must be a string; ignoring.',
          );
        }
      }

      final normalizedModels = <String>[];
      final seenModels = <String>{};
      final rawModels = rawCfg['models'];
      if (rawModels != null) {
        if (rawModels is List) {
          for (var i = 0; i < rawModels.length; i++) {
            final item = rawModels[i];
            if (item is! String) {
              warnings.add(
                'Entry "providers.$rawKey.models[$i]" must be a string; ignoring.',
              );
              continue;
            }
            final normalized =
                ProviderModelsConfig.normalizeModelName(providerId, item);
            if (normalized.isNotEmpty && seenModels.add(normalized)) {
              normalizedModels.add(normalized);
            }
          }
        } else {
          warnings.add(
            'Field "providers.$rawKey.models" must be an array of strings; defaulting to [].',
          );
        }
      }

      parsedProviders[providerId] = ProviderModelsConfig(
        provider: providerId,
        enable: enable,
        autoFetch: autoFetch,
        models: normalizedModels,
        baseUrl: baseUrl,
      );
    }

    return ModelsConfigLoadResult(
      config: ModelsConfig(providers: parsedProviders),
      sourcePath: sourcePath,
      warnings: warnings,
    );
  }
}

/// Result of loading `.agent_os/models.json`, including non-fatal structured warnings ([D-406]).
class ModelsConfigLoadResult {
  ModelsConfigLoadResult({
    required this.config,
    required this.sourcePath,
    List<String> warnings = const <String>[],
  }) : warnings = List<String>.unmodifiable(warnings);

  final ModelsConfig config;
  final String? sourcePath;
  final List<String> warnings;

  bool get hasWarnings => warnings.isNotEmpty;
  bool get loadedFromFile => sourcePath != null;
}

/// Loads `.agent_os/models.json` in precedence order ([D-406]):
/// 1. `<sessionCwd>/.agent_os/models.json`
/// 2. `<Directory.current>/.agent_os/models.json`
/// 3. Built-in defaults when absent.
class ModelsConfigLoader {
  ModelsConfigLoader({
    this.sessionCwd,
    String? currentDirectoryPath,
  }) : _currentDirectoryPath = currentDirectoryPath ?? Directory.current.path;

  final String? sessionCwd;
  final String _currentDirectoryPath;

  /// Resolves and parses `.agent_os/models.json` without throwing on missing or invalid files.
  ModelsConfigLoadResult load() {
    final candidates = <String>[];
    if (sessionCwd != null && sessionCwd!.trim().isNotEmpty) {
      candidates.add(
        p.normalize(p.join(sessionCwd!.trim(), '.agent_os', 'models.json')),
      );
    }
    final cwdCandidate = p.normalize(
      p.join(_currentDirectoryPath, '.agent_os', 'models.json'),
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
        return ModelsConfig.parseJsonString(content, sourcePath: candidate);
      } catch (e) {
        return ModelsConfigLoadResult(
          config: ModelsConfig.defaults(),
          sourcePath: candidate,
          warnings: <String>[
            'Failed to read $candidate: $e. Falling back to defaults.',
          ],
        );
      }
    }

    return ModelsConfigLoadResult(
      config: ModelsConfig.defaults(),
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

/// Evaluates provider enablement and model allowlists ([D-407]).
class ModelPolicy {
  ModelPolicy({
    required this.config,
    required this.envLoader,
    String? explicitOpenAiCompatBaseUrl,
  }) : explicitOpenAiCompatBaseUrl =
            ProviderModelsConfig._normalizeOptionalString(
          explicitOpenAiCompatBaseUrl,
        );

  /// Convenience factory loading `.agent_os/models.json` and `.env` for [sessionCwd].
  factory ModelPolicy.fromEnvironment({
    ModelsConfig? config,
    LlmEnvLoader? envLoader,
    String? sessionCwd,
    String? currentDirectoryPath,
    String? explicitOpenAiCompatBaseUrl,
  }) {
    final effectiveConfig = config ??
        ModelsConfigLoader(
          sessionCwd: sessionCwd,
          currentDirectoryPath: currentDirectoryPath,
        ).load().config;
    final effectiveEnv = envLoader ??
        LlmEnvLoader(
          sessionCwd: sessionCwd,
          currentDirectoryPath: currentDirectoryPath,
        );
    return ModelPolicy(
      config: effectiveConfig,
      envLoader: effectiveEnv,
      explicitOpenAiCompatBaseUrl: explicitOpenAiCompatBaseUrl,
    );
  }

  final ModelsConfig config;
  final LlmEnvLoader envLoader;
  final String? explicitOpenAiCompatBaseUrl;

  /// Returns the [ProviderModelsConfig] for [provider].
  ProviderModelsConfig configFor(LlmProviderId provider) =>
      config.forProvider(provider);

  /// Resolves `openai-compat` baseUrl by precedence:
  /// explicit arg > `OPENAI_COMPAT_BASE_URL` > `models.json` `baseUrl`.
  String? resolveOpenAiCompatBaseUrl() {
    if (explicitOpenAiCompatBaseUrl != null) {
      return explicitOpenAiCompatBaseUrl;
    }
    final envUrl = envLoader.get('OPENAI_COMPAT_BASE_URL');
    if (envUrl != null) {
      return envUrl;
    }
    return configFor(LlmProviderId.openaiCompat).baseUrl;
  }

  /// Returns whether [provider] is enabled after applying `enable` and credential/URL rules ([D-407]).
  bool isProviderEnabled(LlmProviderId provider) {
    if (!configFor(provider).enable) {
      return false;
    }
    switch (provider) {
      case LlmProviderId.localOllama:
        return true;
      case LlmProviderId.ollamaCloud:
        return envLoader.isConfigured('OLLAMA_API_KEY') ||
            envLoader.isConfigured('OLLAMA_CLOUD_API_KEY');
      case LlmProviderId.openRouter:
        return envLoader.isConfigured('OPENROUTER_API_KEY');
      case LlmProviderId.openai:
        return envLoader.isConfigured('OPENAI_API_KEY');
      case LlmProviderId.gemini:
        return envLoader.isConfigured('GEMINI_API_KEY') ||
            envLoader.isConfigured('GOOGLE_API_KEY');
      case LlmProviderId.nousPortal:
        return envLoader.isConfigured('NOUS_API_KEY');
      case LlmProviderId.openaiCompat:
        return resolveOpenAiCompatBaseUrl() != null;
    }
  }

  /// Validates whether [model] is allowed under this policy, returning `EINVAL` if rejected ([D-407]).
  SyscallError? validateModel(ModelIdentifier model) {
    if (!isProviderEnabled(model.provider)) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'PROVIDER_DISABLED',
        message:
            'Provider "${model.provider.id}" is disabled or missing credentials/baseUrl.',
        recoverable: true,
      );
    }
    final providerCfg = configFor(model.provider);
    if (!providerCfg.autoFetch &&
        !providerCfg.models.contains(model.modelName)) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'MODEL_NOT_ALLOWED',
        message:
            'Model "${model.canonicalId}" is not in the configured models list for "${model.provider.id}".',
        recoverable: true,
      );
    }
    return null;
  }

  /// Merges [manualEntries] first followed by non-duplicate [fetchedEntries] ([D-407]).
  ///
  /// When [provider] is disabled, returns an empty list. When `autoFetch` is `false`,
  /// [fetchedEntries] are ignored.
  List<T> mergeCatalogEntries<T>({
    required LlmProviderId provider,
    required List<T> manualEntries,
    required List<T> fetchedEntries,
    required String Function(T entry) canonicalIdOf,
  }) {
    if (!isProviderEnabled(provider)) {
      return <T>[];
    }
    final result = <T>[];
    final seenIds = <String>{};
    for (final entry in manualEntries) {
      if (seenIds.add(canonicalIdOf(entry))) {
        result.add(entry);
      }
    }
    if (configFor(provider).autoFetch) {
      for (final entry in fetchedEntries) {
        if (seenIds.add(canonicalIdOf(entry))) {
          result.add(entry);
        }
      }
    }
    return result;
  }
}
