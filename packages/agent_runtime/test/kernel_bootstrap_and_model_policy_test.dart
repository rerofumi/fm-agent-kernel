import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('KernelBootstrap 7-provider wiring & ModelPolicy [D-402], [D-407]', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('fm_kb_policy_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('registers all 7 LLM providers and applies base URL overrides', () {
      final envLoader = LlmEnvLoader(
        sessionCwd: tempRoot.path,
        processEnvironment: const <String, String>{
          'OPENAI_API_KEY': 'sk-openai-test',
          'GEMINI_API_KEY': 'gemini-test-key',
          'NOUS_API_KEY': 'nous-test-key',
          'OPENROUTER_API_KEY': 'or-test-key',
          'OLLAMA_API_KEY': 'ollama-cloud-test-key',
          'OPENAI_COMPAT_BASE_URL': 'http://127.0.0.1:9999/v1',
        },
      );

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: tempRoot.path,
          envLoader: envLoader,
          openAiBaseUrl: 'http://127.0.0.1:4101/v1',
          geminiBaseUrl: 'http://127.0.0.1:4102',
          nousPortalBaseUrl: 'http://127.0.0.1:4103/v1',
          openAiCompatBaseUrl: 'http://127.0.0.1:4104/v1',
        ),
      );
      addTearDown(bootstrap.dispose);

      for (final provider in LlmProviderId.values) {
        expect(
          bootstrap.llmRouter.driverFor(provider),
          isNotNull,
          reason: 'Expected driver registered for ${provider.id}',
        );
      }

      final openAiDriver =
          bootstrap.llmRouter.driverFor(LlmProviderId.openai) as OpenAiDriver;
      expect(
        openAiDriver.resolveEndpoint().toString(),
        equals('http://127.0.0.1:4101/v1/chat/completions'),
      );

      final nousDriver = bootstrap.llmRouter.driverFor(LlmProviderId.nousPortal)
          as NousPortalDriver;
      expect(
        nousDriver.resolveEndpoint().toString(),
        equals('http://127.0.0.1:4103/v1/chat/completions'),
      );

      final compatDriver =
          bootstrap.llmRouter.driverFor(LlmProviderId.openaiCompat)
              as LocalOpenAiCompatDriver;
      expect(
        compatDriver.resolveEndpoint().toString(),
        equals('http://127.0.0.1:4104/v1/chat/completions'),
      );
    });

    test('resolves openai-compat baseUrl: explicit > env > models.json', () {
      final agentOsDir = Directory(p.join(tempRoot.path, '.agent_os'))
        ..createSync(recursive: true);
      File(p.join(agentOsDir.path, 'models.json')).writeAsStringSync('''
{
  "providers": {
    "openai-compat": {
      "enable": true,
      "baseUrl": "http://127.0.0.1:5001/v1"
    }
  }
}
''');

      // 1. models.json baseUrl used when env and explicit are absent.
      final bJson = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: tempRoot.path,
          envLoader: LlmEnvLoader(
            sessionCwd: tempRoot.path,
            currentDirectoryPath: tempRoot.path,
            processEnvironment: const <String, String>{},
          ),
        ),
      );
      addTearDown(bJson.dispose);
      expect(
        (bJson.llmRouter.driverFor(LlmProviderId.openaiCompat)
                as LocalOpenAiCompatDriver)
            .resolveEndpoint()
            .toString(),
        equals('http://127.0.0.1:5001/v1/chat/completions'),
      );

      // 2. OPENAI_COMPAT_BASE_URL overrides models.json baseUrl.
      final bEnv = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: tempRoot.path,
          envLoader: LlmEnvLoader(
            sessionCwd: tempRoot.path,
            currentDirectoryPath: tempRoot.path,
            processEnvironment: const <String, String>{
              'OPENAI_COMPAT_BASE_URL': 'http://127.0.0.1:5002/v1',
            },
          ),
        ),
      );
      addTearDown(bEnv.dispose);
      expect(
        (bEnv.llmRouter.driverFor(LlmProviderId.openaiCompat)
                as LocalOpenAiCompatDriver)
            .resolveEndpoint()
            .toString(),
        equals('http://127.0.0.1:5002/v1/chat/completions'),
      );
    });

    test('ModelResolver enforces ModelPolicy with EINVAL on disabled/excluded models',
        () {
      final config = ModelsConfig(
        providers: <LlmProviderId, ProviderModelsConfig>{
          LlmProviderId.localOllama: ProviderModelsConfig(
            provider: LlmProviderId.localOllama,
            enable: false,
          ),
          LlmProviderId.openai: ProviderModelsConfig(
            provider: LlmProviderId.openai,
            enable: true,
            autoFetch: false,
            models: const <String>['gpt-4.1'],
          ),
        },
      );
      final policy = ModelPolicy(
        config: config,
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{
            'OPENAI_API_KEY': 'sk-test-key',
          },
        ),
      );

      final resolver = ModelResolver(
        startupModel: 'openai/gpt-4.1',
        modelValidator: policy.validateModel,
      );

      // Allowed model succeeds.
      expect(resolver.resolveForTurn().ok, isTrue);
      expect(resolver.setSessionModel('openai/gpt-4.1').ok, isTrue);

      // Disabled provider rejected with EINVAL.
      final disabledRes = resolver.setSessionModel('local-ollama/gemma4:12b');
      expect(disabledRes.ok, isFalse);
      expect(disabledRes.error!.code, equals(SyscallErrorCode.einval));
      expect(disabledRes.error!.reason, equals('PROVIDER_DISABLED'));

      // Model not in allowlist when autoFetch: false rejected with EINVAL.
      final notAllowedRes = resolver.setSessionModel('openai/gpt-4o');
      expect(notAllowedRes.ok, isFalse);
      expect(notAllowedRes.error!.code, equals(SyscallErrorCode.einval));
      expect(notAllowedRes.error!.reason, equals('MODEL_NOT_ALLOWED'));

      // Session model remains unchanged after failed setSessionModel.
      expect(resolver.sessionSelectedModel, equals('openai/gpt-4.1'));

      // Turn override outside allowlist rejected with EINVAL.
      final overrideRes =
          resolver.resolveForTurn(turnOverride: 'openai/gpt-4o');
      expect(overrideRes.ok, isFalse);
      expect(overrideRes.error!.code, equals(SyscallErrorCode.einval));
      expect(overrideRes.error!.reason, equals('MODEL_NOT_ALLOWED'));
    });

    test('KernelBootstrap wires ModelPolicy into ModelResolver', () {
      final policy = ModelPolicy(
        config: ModelsConfig(
          providers: <LlmProviderId, ProviderModelsConfig>{
            LlmProviderId.openai: ProviderModelsConfig(
              provider: LlmProviderId.openai,
              enable: true,
              autoFetch: false,
              models: const <String>['gpt-4.1'],
            ),
          },
        ),
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{
            'OPENAI_API_KEY': 'sk-test-key',
          },
        ),
      );

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: tempRoot.path,
          startupModel: 'openai/gpt-4.1',
          modelPolicy: policy,
        ),
      );
      addTearDown(bootstrap.dispose);

      final badSet = bootstrap.processRunner.setSessionModel('openai/gpt-4o');
      expect(badSet.ok, isFalse);
      expect(badSet.error!.code, equals(SyscallErrorCode.einval));
    });
  });
}
