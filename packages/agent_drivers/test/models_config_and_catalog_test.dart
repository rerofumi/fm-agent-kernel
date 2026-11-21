import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/src/llm/llm_env_loader.dart';
import 'package:agent_drivers/src/llm/model_catalog_service.dart';
import 'package:agent_drivers/src/llm/models_config.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ModelsConfigLoader & ModelsConfig [D-406]', () {
    late Directory tempRoot;
    late Directory sessionDir;
    late Directory currentDir;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('models_config_test_');
      sessionDir = Directory(p.join(tempRoot.path, 'session'))..createSync();
      currentDir = Directory(p.join(tempRoot.path, 'current'))..createSync();
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('prioritizes <sessionCwd>/.agent_os/models.json over <Directory.current>/.agent_os/models.json', () {
      final sessionConfigDir = Directory(p.join(sessionDir.path, '.agent_os'))
        ..createSync();
      final currentConfigDir = Directory(p.join(currentDir.path, '.agent_os'))
        ..createSync();

      File(p.join(sessionConfigDir.path, 'models.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'local-ollama': <String, dynamic>{
              'enable': true,
              'autoFetch': false,
              'models': <String>['gemma4:12b'],
            },
          },
        }),
      );
      File(p.join(currentConfigDir.path, 'models.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'local-ollama': <String, dynamic>{
              'enable': false,
              'autoFetch': true,
              'models': <String>['other:7b'],
            },
          },
        }),
      );

      final result = ModelsConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();

      expect(result.loadedFromFile, isTrue);
      expect(
        result.sourcePath,
        equals(p.normalize(p.join(sessionConfigDir.path, 'models.json'))),
      );
      final ollama = result.config.forProvider(LlmProviderId.localOllama);
      expect(ollama.enable, isTrue);
      expect(ollama.autoFetch, isFalse);
      expect(ollama.models, equals(<String>['gemma4:12b']));
    });

    test('falls back to <Directory.current>/.agent_os/models.json and defaults when absent', () {
      final absentResult = ModelsConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();

      expect(absentResult.loadedFromFile, isFalse);
      expect(absentResult.hasWarnings, isFalse);
      for (final provider in LlmProviderId.values) {
        final cfg = absentResult.config.forProvider(provider);
        expect(cfg.enable, isTrue);
        expect(cfg.autoFetch, isTrue);
        expect(cfg.models, isEmpty);
      }

      final currentConfigDir = Directory(p.join(currentDir.path, '.agent_os'))
        ..createSync();
      File(p.join(currentConfigDir.path, 'models.json')).writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'openai': <String, dynamic>{'enable': false},
          },
        }),
      );

      final fallbackResult = ModelsConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();

      expect(fallbackResult.loadedFromFile, isTrue);
      expect(
        fallbackResult.config.forProvider(LlmProviderId.openai).enable,
        isFalse,
      );
    });

    test('does not crash on invalid JSON syntax or schema and records structured warnings', () {
      final sessionConfigDir = Directory(p.join(sessionDir.path, '.agent_os'))
        ..createSync();
      final file = File(p.join(sessionConfigDir.path, 'models.json'));
      file.writeAsStringSync('{ invalid json !!!');

      final syntaxResult = ModelsConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();

      expect(syntaxResult.hasWarnings, isTrue);
      expect(
        syntaxResult.config.forProvider(LlmProviderId.localOllama).enable,
        isTrue,
      );

      file.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'unknown-provider': <String, dynamic>{'enable': false},
            'openai': <String, dynamic>{
              'enable': 'not-a-bool',
              'models': <dynamic>['gpt-4o', 123],
            },
          },
        }),
      );

      final partialResult = ModelsConfigLoader(
        sessionCwd: sessionDir.path,
        currentDirectoryPath: currentDir.path,
      ).load();

      expect(partialResult.warnings.length, greaterThanOrEqualTo(3));
      final openaiCfg = partialResult.config.forProvider(LlmProviderId.openai);
      expect(openaiCfg.enable, isTrue);
      expect(openaiCfg.models, equals(<String>['gpt-4o']));
    });

    test('normalizes <providerId>/ prefix only when matching the provider id', () {
      final result = ModelsConfig.parseJsonString(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'local-ollama': <String, dynamic>{
              'models': <String>[
                'local-ollama/gemma4:12b',
                'gemma4:12b',
                'qwen3.8:27b',
              ],
            },
            'openrouter': <String, dynamic>{
              'models': <String>[
                'openrouter/anthropic/claude-sonnet-4',
                'openai/gpt-4.1',
              ],
            },
          },
        }),
      );

      expect(
        result.config.forProvider(LlmProviderId.localOllama).models,
        equals(<String>['gemma4:12b', 'qwen3.8:27b']),
      );
      expect(
        result.config.forProvider(LlmProviderId.openRouter).models,
        equals(<String>['anthropic/claude-sonnet-4', 'openai/gpt-4.1']),
      );
    });
  });

  group('ModelPolicy enablement & validateModel [D-407]', () {
    late Directory isolatedDir;

    setUp(() {
      isolatedDir = Directory.systemTemp.createTempSync('model_policy_test_');
    });

    tearDown(() {
      if (isolatedDir.existsSync()) {
        isolatedDir.deleteSync(recursive: true);
      }
    });

    test('enforces enable: false and API key / baseUrl matrix', () {
      final config = ModelsConfig.parseJsonString(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'openrouter': <String, dynamic>{'enable': false},
          },
        }),
      ).config;

      final emptyEnv = LlmEnvLoader(
        processEnvironment: const <String, String>{},
        currentDirectoryPath: isolatedDir.path,
      );
      final emptyPolicy = ModelPolicy(config: config, envLoader: emptyEnv);

      expect(emptyPolicy.isProviderEnabled(LlmProviderId.localOllama), isTrue);
      expect(emptyPolicy.isProviderEnabled(LlmProviderId.ollamaCloud), isFalse);
      expect(emptyPolicy.isProviderEnabled(LlmProviderId.openRouter), isFalse);
      expect(emptyPolicy.isProviderEnabled(LlmProviderId.openai), isFalse);
      expect(emptyPolicy.isProviderEnabled(LlmProviderId.gemini), isFalse);
      expect(emptyPolicy.isProviderEnabled(LlmProviderId.nousPortal), isFalse);
      expect(
        emptyPolicy.isProviderEnabled(LlmProviderId.openaiCompat),
        isFalse,
      );

      final fullEnv = LlmEnvLoader(
        processEnvironment: const <String, String>{
          'OLLAMA_API_KEY': 'ollama-secret',
          'OPENROUTER_API_KEY': 'or-secret',
          'OPENAI_API_KEY': 'oa-secret',
          'GOOGLE_API_KEY': 'goog-secret',
          'NOUS_API_KEY': 'nous-secret',
          'OPENAI_COMPAT_BASE_URL': 'http://127.0.0.1:8080/v1',
        },
        currentDirectoryPath: isolatedDir.path,
      );
      final fullPolicy = ModelPolicy(config: config, envLoader: fullEnv);

      expect(fullPolicy.isProviderEnabled(LlmProviderId.localOllama), isTrue);
      expect(fullPolicy.isProviderEnabled(LlmProviderId.ollamaCloud), isTrue);
      // enable: false overrides present API key
      expect(fullPolicy.isProviderEnabled(LlmProviderId.openRouter), isFalse);
      expect(fullPolicy.isProviderEnabled(LlmProviderId.openai), isTrue);
      expect(fullPolicy.isProviderEnabled(LlmProviderId.gemini), isTrue);
      expect(fullPolicy.isProviderEnabled(LlmProviderId.nousPortal), isTrue);
      expect(fullPolicy.isProviderEnabled(LlmProviderId.openaiCompat), isTrue);
    });

    test('enables openai-compat when models.json baseUrl is set without env var', () {
      final config = ModelsConfig.parseJsonString(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'openai-compat': <String, dynamic>{
              'baseUrl': 'http://127.0.0.1:18080/v1',
            },
          },
        }),
      ).config;
      final policy = ModelPolicy(
        config: config,
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{},
          currentDirectoryPath: isolatedDir.path,
        ),
      );

      expect(policy.isProviderEnabled(LlmProviderId.openaiCompat), isTrue);
      expect(
        policy.resolveOpenAiCompatBaseUrl(),
        equals('http://127.0.0.1:18080/v1'),
      );
    });

    test('validateModel returns EINVAL for disabled provider or unlisted model when autoFetch: false', () {
      final config = ModelsConfig.parseJsonString(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'local-ollama': <String, dynamic>{
              'autoFetch': false,
              'models': <String>['gemma4:12b'],
            },
            'openai': <String, dynamic>{'enable': false},
          },
        }),
      ).config;
      final policy = ModelPolicy(
        config: config,
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{
            'OPENAI_API_KEY': 'oa-secret',
          },
          currentDirectoryPath: isolatedDir.path,
        ),
      );

      final allowed = ModelIdentifier.parse('local-ollama/gemma4:12b').value!;
      expect(policy.validateModel(allowed), isNull);

      final unlisted = ModelIdentifier.parse('local-ollama/llama3:8b').value!;
      final unlistedErr = policy.validateModel(unlisted);
      expect(unlistedErr, isNotNull);
      expect(unlistedErr!.code, equals(SyscallErrorCode.einval));
      expect(unlistedErr.reason, equals('MODEL_NOT_ALLOWED'));

      final disabled = ModelIdentifier.parse('openai/gpt-4o').value!;
      final disabledErr = policy.validateModel(disabled);
      expect(disabledErr, isNotNull);
      expect(disabledErr!.code, equals(SyscallErrorCode.einval));
      expect(disabledErr.reason, equals('PROVIDER_DISABLED'));
    });
  });

  group('ModelCatalogService [D-407], [D-409]', () {
    late Directory isolatedDir;

    setUp(() {
      isolatedDir = Directory.systemTemp.createTempSync('model_catalog_test_');
    });

    tearDown(() {
      if (isolatedDir.existsSync()) {
        isolatedDir.deleteSync(recursive: true);
      }
    });

    test('makes 0 HTTP calls when autoFetch: false and returns only manual models', () async {
      var httpCalls = 0;
      final client = MockClient((request) async {
        httpCalls++;
        return http.Response('{}', 200);
      });

      final config = ModelsConfig.parseJsonString(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'local-ollama': <String, dynamic>{
              'autoFetch': false,
              'models': <String>['gemma4:12b', 'qwen3.8:27b'],
            },
          },
        }),
      ).config;
      final policy = ModelPolicy(
        config: config,
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{},
          currentDirectoryPath: isolatedDir.path,
        ),
      );

      final service = ModelCatalogService(httpClient: client);
      final entries = await service.resolveOptions(policy);

      expect(httpCalls, equals(0));
      expect(
        entries.map((e) => e.id).toList(),
        equals(<String>[
          'local-ollama/gemma4:12b',
          'local-ollama/qwen3.8:27b',
        ]),
      );
    });

    test('fetches once at startup across repeated and concurrent resolveOptions calls and merges manual models first', () async {
      final callCounts = <String, int>{};
      final client = MockClient((request) async {
        final key = request.url.host;
        callCounts[key] = (callCounts[key] ?? 0) + 1;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return http.Response(
          jsonEncode(<String, dynamic>{
            'models': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'gemma4:12b',
                'capabilities': <String>['completion'],
              },
              <String, dynamic>{
                'name': 'llama3.3:70b',
                'capabilities': <String>['completion'],
              },
            ],
          }),
          200,
        );
      });

      final config = ModelsConfig.parseJsonString(
        jsonEncode(<String, dynamic>{
          'providers': <String, dynamic>{
            'local-ollama': <String, dynamic>{
              'autoFetch': true,
              'models': <String>['custom-first:latest', 'gemma4:12b'],
            },
          },
        }),
      ).config;
      final policy = ModelPolicy(
        config: config,
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{},
          currentDirectoryPath: isolatedDir.path,
        ),
      );

      final service = ModelCatalogService(
        httpClient: client,
        localOllamaBaseUrl: 'http://ollama.local:11434',
      );

      final concurrent = await Future.wait<List<ModelCatalogEntry>>(<Future<List<ModelCatalogEntry>>>[
        service.resolveOptions(policy),
        service.resolveOptions(policy),
      ]);
      final third = await service.resolveOptions(policy);

      expect(callCounts['ollama.local'], equals(1));
      expect(
        concurrent[0].map((e) => e.id).toList(),
        equals(<String>[
          'local-ollama/custom-first:latest',
          'local-ollama/gemma4:12b',
          'local-ollama/llama3.3:70b',
        ]),
      );
      expect(third, equals(concurrent[0]));
    });

    test('filters non-chat models across all 7 providers and isolates partial failures', () async {
      String? capturedGeminiKeyHeader;
      Uri? capturedGeminiUri;

      final client = MockClient((request) async {
        final host = request.url.host;
        if (host == 'ollama-local.test') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'models': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'gemma4:12b',
                  'capabilities': <String>['completion', 'tools'],
                },
                <String, dynamic>{
                  'name': 'embeddinggemma:latest',
                  'capabilities': <String>['embedding'],
                },
                <String, dynamic>{
                  'name': 'nomic-embed-text',
                },
              ],
            }),
            200,
          );
        }
        if (host == 'ollama-cloud.test') {
          return http.Response('upstream error', 500);
        }
        if (host == 'openrouter.test') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'anthropic/claude-sonnet-4',
                  'architecture': <String, dynamic>{
                    'output_modalities': <String>['text'],
                  },
                },
                <String, dynamic>{
                  'id': 'openai/dall-e-3',
                  'architecture': <String, dynamic>{
                    'output_modalities': <String>['image'],
                  },
                },
              ],
            }),
            200,
          );
        }
        if (host == 'openai.test') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'gpt-4.1'},
                <String, dynamic>{'id': 'o3'},
                <String, dynamic>{'id': 'whisper-1'},
                <String, dynamic>{'id': 'tts-1'},
                <String, dynamic>{'id': 'gpt-4o-mini-tts'},
                <String, dynamic>{'id': 'dall-e-3'},
                <String, dynamic>{'id': 'text-embedding-3-small'},
                <String, dynamic>{'id': 'omni-moderation-latest'},
                <String, dynamic>{'id': 'gpt-image-1'},
                <String, dynamic>{'id': 'sora-1'},
                <String, dynamic>{'id': 'gpt-audio'},
                <String, dynamic>{'id': 'gpt-live-1'},
                <String, dynamic>{'id': 'gpt-4o-realtime-preview'},
                <String, dynamic>{'id': 'gpt-4o-transcribe'},
              ],
            }),
            200,
          );
        }
        if (host == 'gemini.test') {
          capturedGeminiKeyHeader = request.headers['x-goog-api-key'];
          capturedGeminiUri = request.url;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'models': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'models/gemini-2.5-flash',
                  'supportedGenerationMethods': <String>['generateContent'],
                },
                <String, dynamic>{
                  'name': 'models/gemini-embedding-001',
                  'supportedGenerationMethods': <String>['embedContent'],
                },
              ],
            }),
            200,
          );
        }
        if (host == 'nous.test') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'hermes-3-llama-3.1-70b',
                  'architecture': <String, dynamic>{
                    'output_modalities': <String>['text'],
                  },
                },
                <String, dynamic>{
                  'id': 'hermes-3-llama-3.1-70b:batch',
                  'architecture': <String, dynamic>{
                    'output_modalities': <String>['text'],
                  },
                },
                <String, dynamic>{
                  'id': 'baai/bge-m3',
                  'architecture': <String, dynamic>{
                    'output_modalities': <String>['embedding'],
                  },
                },
                <String, dynamic>{
                  'id': 'fallback-rerank-v1',
                },
              ],
            }),
            200,
          );
        }
        if (host == 'compat.test') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'qwen3-coder-30b'},
                <String, dynamic>{'id': 'bge-reranker-v2'},
                <String, dynamic>{'id': 'nomic-embed-v1'},
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final policy = ModelPolicy(
        config: ModelsConfig.defaults(),
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{
            'OLLAMA_API_KEY': 'secret-ollama',
            'OPENROUTER_API_KEY': 'secret-or',
            'OPENAI_API_KEY': 'secret-oa',
            'GEMINI_API_KEY': 'secret-gem',
            'NOUS_API_KEY': 'secret-nous',
            'OPENAI_COMPAT_BASE_URL': 'http://compat.test:8080/v1',
          },
        ),
      );

      final service = ModelCatalogService(
        httpClient: client,
        localOllamaBaseUrl: 'http://ollama-local.test:11434',
        ollamaCloudBaseUrl: 'https://ollama-cloud.test',
        openRouterBaseUrl: 'https://openrouter.test/api/v1',
        openAiBaseUrl: 'https://openai.test/v1',
        geminiBaseUrl: 'https://gemini.test',
        nousPortalBaseUrl: 'https://nous.test/v1',
      );

      final entries = await service.resolveOptions(policy);
      final ids = entries.map((e) => e.id).toList();

      expect(
        ids,
        equals(<String>[
          'local-ollama/gemma4:12b',
          'openrouter/anthropic/claude-sonnet-4',
          'openai/gpt-4.1',
          'openai/o3',
          'gemini/gemini-2.5-flash',
          'nous-portal/hermes-3-llama-3.1-70b',
          'openai-compat/qwen3-coder-30b',
        ]),
      );
      expect(capturedGeminiKeyHeader, equals('secret-gem'));
      expect(capturedGeminiUri?.queryParameters.containsKey('key'), isFalse);
      expect(service.warnings, hasLength(1));
      expect(service.warnings.first, contains('ollama-cloud'));
    });
  });

  group('VfsNamespace protection for .agent_os/models.json [D-406]', () {
    late Directory workspaceDir;

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('vfs_models_json_');
      Directory(p.join(workspaceDir.path, '.agent_os')).createSync();
      File(p.join(workspaceDir.path, '.agent_os', 'models.json'))
          .writeAsStringSync('{}');
    });

    tearDown(() {
      if (workspaceDir.existsSync()) {
        workspaceDir.deleteSync(recursive: true);
      }
    });

    test('rejects read/write access to /workspace/.agent_os/models.json with EACCES', () {
      final vfs = VfsNamespace(workspaceHostRoot: workspaceDir.path);

      final readRes = vfs.resolveVirtualPath('/workspace/.agent_os/models.json');
      expect(readRes.ok, isFalse);
      expect(readRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(readRes.error!.reason, equals('PROTECTED_INTERNAL_PATH'));

      final writeRes = vfs.resolveVirtualPath(
        '/workspace/.agent_os/models.json',
        forWrite: true,
      );
      expect(writeRes.ok, isFalse);
      expect(writeRes.error!.code, equals(SyscallErrorCode.eacces));
      expect(writeRes.error!.reason, equals('PROTECTED_INTERNAL_PATH'));
    });
  });
}
