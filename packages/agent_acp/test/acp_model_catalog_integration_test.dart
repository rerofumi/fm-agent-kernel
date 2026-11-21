import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_acp/agent_acp.dart';
import 'package:agent_acp/src/kanban/kanban_acp_bridge.dart';
import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ACP ModelCatalogService & ModelPolicy integration [D-407]..[D-410]',
      () {
    late Directory repoDir;

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('fm_acp_catalog_test_');
      final initRes = Process.runSync(
        'jj',
        const <String>['git', 'init'],
        workingDirectory: repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
      );
      expect(initRes.exitCode, equals(0), reason: '${initRes.stderr}');
      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('hello\n');
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test(
        'fetches model catalog once across multiple session/new calls and populates dynamic configOptions',
        () async {
      var ollamaHits = 0;
      var openAiHits = 0;
      var geminiHits = 0;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        if (req.uri.path == '/api/tags') {
          ollamaHits++;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'models': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'gemma4:12b',
                  'capabilities': <String>['completion'],
                },
                <String, dynamic>{
                  'name': 'embeddinggemma:latest',
                  'capabilities': <String>['embedding'],
                },
              ],
            }),
          );
        } else if (req.uri.path == '/v1/models') {
          openAiHits++;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{'id': 'gpt-4.1'},
                <String, dynamic>{'id': 'whisper-1'},
                <String, dynamic>{'id': 'gpt-4o-mini-tts'},
              ],
            }),
          );
        } else if (req.uri.path == '/v1beta/models') {
          geminiHits++;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, dynamic>{
              'models': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'models/gemini-2.5-pro',
                  'supportedGenerationMethods': <String>['generateContent'],
                },
                <String, dynamic>{
                  'name': 'models/gemini-embedding-001',
                  'supportedGenerationMethods': <String>['embedContent'],
                },
              ],
            }),
          );
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final baseUrl = 'http://127.0.0.1:${server.port}';
      final catalogService = ModelCatalogService(
        localOllamaBaseUrl: baseUrl,
        openAiBaseUrl: '$baseUrl/v1',
        geminiBaseUrl: baseUrl,
      );
      addTearDown(catalogService.close);

      final policy = ModelPolicy(
        config: ModelsConfig.defaults(),
        envLoader: LlmEnvLoader(
          processEnvironment: const <String, String>{
            'OPENAI_API_KEY': 'sk-test-openai',
            'GEMINI_API_KEY': 'test-gemini-key',
          },
        ),
      );

      final pair = _createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final acpServer = AcpServer(
        peer: serverPeer,
        config: AcpServerConfig(
          modelPolicy: policy,
          modelCatalogService: catalogService,
          bootstrapFactory: (cfg) => KernelBootstrap.create(
            KernelBootstrapConfig(
              workspaceHostRoot: cfg.workspaceHostRoot,
              sessionId: cfg.sessionId,
              startupModel: cfg.startupModel,
              modelPolicy: cfg.modelPolicy,
              approvalHandler: cfg.approvalHandler,
              hooks: cfg.hooks,
              llmDrivers: <LlmProviderId, LlmDriver>{
                LlmProviderId.localOllama: _NoopLlmDriver(
                  LlmProviderId.localOllama,
                ),
              },
            ),
          ),
        ),
      );
      addTearDown(() async {
        await acpServer.dispose();
        await pair.close();
      });

      final clientPeer = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
      );
      await clientPeer.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });

      final sess1 = Map<String, dynamic>.from(
        await clientPeer.sendRequest('session/new', <String, dynamic>{
          'cwd': repoDir.path,
          'mcpServers': const <Object>[],
        }) as Map,
      );
      final sess2 = Map<String, dynamic>.from(
        await clientPeer.sendRequest('session/new', <String, dynamic>{
          'cwd': repoDir.path,
          'mcpServers': const <Object>[],
        }) as Map,
      );

      // Startup 1-time fetch guarantee across multiple session/new calls.
      expect(ollamaHits, equals(1));
      expect(openAiHits, equals(1));
      expect(geminiHits, equals(1));

      for (final sess in <Map<String, dynamic>>[sess1, sess2]) {
        final opts = (sess['configOptions'] as List).first as Map;
        final values = (opts['options'] as List)
            .map((e) => (e as Map)['value'] as String)
            .toList(growable: false);
        expect(values, contains('local-ollama/gemma4:12b'));
        expect(values, contains('openai/gpt-4.1'));
        expect(values, contains('gemini/gemini-2.5-pro'));
        expect(values, isNot(contains('local-ollama/embeddinggemma:latest')));
        expect(values, isNot(contains('openai/whisper-1')));
        expect(values, isNot(contains('openai/gpt-4o-mini-tts')));
        expect(values, isNot(contains('gemini/gemini-embedding-001')));
      }
    });

    test(
        'autoFetch: false skips external API, restricts session/set_config_option & modelOverride with Invalid params',
        () async {
      var httpHits = 0;
      final mockHttp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(mockHttp.close);
      mockHttp.listen((req) async {
        httpHits++;
        req.response.statusCode = 200;
        req.response.write('{}');
        await req.response.close();
      });

      final baseUrl = 'http://127.0.0.1:${mockHttp.port}';
      final catalogService = ModelCatalogService(
        localOllamaBaseUrl: baseUrl,
        openAiBaseUrl: '$baseUrl/v1',
      );
      addTearDown(catalogService.close);

      final policy = ModelPolicy(
        config: ModelsConfig(
          providers: <LlmProviderId, ProviderModelsConfig>{
            LlmProviderId.localOllama: ProviderModelsConfig(
              provider: LlmProviderId.localOllama,
              enable: true,
              autoFetch: false,
              models: const <String>['gemma4:12b'],
            ),
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
            'OPENAI_API_KEY': 'sk-test-openai',
          },
        ),
      );

      final pair = _createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final acpServer = AcpServer(
        peer: serverPeer,
        config: AcpServerConfig(
          modelPolicy: policy,
          modelCatalogService: catalogService,
          bootstrapFactory: (cfg) => KernelBootstrap.create(
            KernelBootstrapConfig(
              workspaceHostRoot: cfg.workspaceHostRoot,
              sessionId: cfg.sessionId,
              startupModel: cfg.startupModel,
              modelPolicy: cfg.modelPolicy,
              approvalHandler: cfg.approvalHandler,
              hooks: cfg.hooks,
              llmDrivers: <LlmProviderId, LlmDriver>{
                LlmProviderId.localOllama: _NoopLlmDriver(
                  LlmProviderId.localOllama,
                ),
                LlmProviderId.openai: _NoopLlmDriver(LlmProviderId.openai),
              },
            ),
          ),
        ),
      );
      addTearDown(() async {
        await acpServer.dispose();
        await pair.close();
      });

      final clientPeer = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
      );
      await clientPeer.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });
      final sess = Map<String, dynamic>.from(
        await clientPeer.sendRequest('session/new', <String, dynamic>{
          'cwd': repoDir.path,
          'mcpServers': const <Object>[],
        }) as Map,
      );
      final sessionId = sess['sessionId'] as String;

      // Zero external HTTP calls when autoFetch: false.
      expect(httpHits, equals(0));

      // Out-of-list model rejected in session/set_config_option.
      await expectLater(
        () => clientPeer.sendRequest('session/set_config_option', <String, dynamic>{
          'sessionId': sessionId,
          'configId': 'model',
          'value': 'openai/gpt-4o',
        }),
        throwsA(
          isA<JsonRpcException>().having(
            (e) => e.code,
            'code',
            JsonRpcErrorCodes.invalidParams,
          ),
        ),
      );

      // Out-of-list model rejected in _meta["fm_agent_os/modelOverride"].
      await expectLater(
        () => clientPeer.sendRequest('session/prompt', <String, dynamic>{
          'sessionId': sessionId,
          'prompt': const <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'hi'},
          ],
          '_meta': const <String, dynamic>{
            'fm_agent_os/modelOverride': 'openai/gpt-4o',
          },
        }),
        throwsA(
          isA<JsonRpcException>().having(
            (e) => e.code,
            'code',
            JsonRpcErrorCodes.invalidParams,
          ),
        ),
      );

      // Allowed manual model succeeds.
      final okSet = Map<String, dynamic>.from(
        await clientPeer.sendRequest('session/set_config_option', <String, dynamic>{
          'sessionId': sessionId,
          'configId': 'model',
          'value': 'openai/gpt-4.1',
        }) as Map,
      );
      final opts = (okSet['configOptions'] as List).first as Map;
      expect(opts['currentValue'], equals('openai/gpt-4.1'));
    });

    test(
        'rejects session/new with Invalid params when default model local-ollama/gemma4:12b is disabled and --model is omitted',
        () async {
      final agentOsDir = Directory(p.join(repoDir.path, '.agent_os'))
        ..createSync(recursive: true);
      File(p.join(agentOsDir.path, 'models.json')).writeAsStringSync('''
{
  "providers": {
    "local-ollama": {
      "enable": true,
      "autoFetch": false,
      "models": ["qwen3.8:27b"]
    }
  }
}
''');

      final pair = _createStreamPair();
      final serverPeer = JsonRpcPeer(
        input: pair.serverIn,
        output: pair.serverOut,
      );
      final acpServer = AcpServer(
        peer: serverPeer,
        config: AcpServerConfig(
          modelCatalogService: ModelCatalogService(),
        ),
      );
      addTearDown(() async {
        await acpServer.dispose();
        await pair.close();
      });

      final clientPeer = JsonRpcPeer(
        input: pair.clientIn,
        output: pair.clientOut,
      );
      await clientPeer.sendRequest('initialize', <String, dynamic>{
        'protocolVersion': 1,
      });

      await expectLater(
        () => clientPeer.sendRequest('session/new', <String, dynamic>{
          'cwd': repoDir.path,
          'mcpServers': const <Object>[],
        }),
        throwsA(
          isA<JsonRpcException>()
              .having((e) => e.code, 'code', JsonRpcErrorCodes.invalidParams)
              .having(
                (e) => e.message,
                'message',
                contains('local-ollama/gemma4:12b'),
              ),
        ),
      );
    });

    test(
        'agent_os_daemon exits 64 with empty stdout when default model is disabled or --model is disallowed, and KanbanAcpBridge receives dynamic availableModels',
        () async {
      final agentOsDir = Directory(p.join(repoDir.path, '.agent_os'))
        ..createSync(recursive: true);
      final modelsFile = File(p.join(agentOsDir.path, 'models.json'));
      modelsFile.writeAsStringSync('''
{
  "providers": {
    "local-ollama": {
      "enable": false
    }
  }
}
''');

      final daemonScript = p.normalize(
        p.join(
          Directory.current.path,
          'packages',
          'agent_acp',
          'bin',
          'agent_os_daemon.dart',
        ),
      );

      // 1. Default model disabled, no --model -> exit code 64, empty stdout.
      final noModelRes = await Process.run(
        Platform.resolvedExecutable,
        <String>['run', daemonScript],
        workingDirectory: repoDir.path,
        runInShell: false,
      );
      expect(noModelRes.exitCode, equals(64));
      expect(noModelRes.stdout, isEmpty);
      expect(
        noModelRes.stderr.toString(),
        contains('local-ollama/gemma4:12b'),
      );

      // 2. Disallowed --model -> exit code 64, empty stdout.
      final badModelRes = await Process.run(
        Platform.resolvedExecutable,
        <String>['run', daemonScript, '--model', 'local-ollama/gemma4:12b'],
        workingDirectory: repoDir.path,
        runInShell: false,
      );
      expect(badModelRes.exitCode, equals(64));
      expect(badModelRes.stdout, isEmpty);

      // 3. KanbanAcpBridge connects to daemon with loopback Ollama mock and gets dynamic availableModels.
      modelsFile.writeAsStringSync('''
{
  "providers": {
    "local-ollama": {
      "enable": true,
      "autoFetch": true,
      "models": ["gemma4:12b"]
    }
  }
}
''');
      final mockOllama = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(mockOllama.close);
      mockOllama.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, dynamic>{
            'models': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'gemma4:12b',
                'capabilities': <String>['completion'],
              },
              <String, dynamic>{
                'name': 'qwen3.8:27b',
                'capabilities': <String>['completion'],
              },
            ],
          }),
        );
        await req.response.close();
      });

      final bridge = await KanbanAcpBridge.spawn(
        executable: Platform.resolvedExecutable,
        arguments: <String>[
          'run',
          daemonScript,
          '--ollama-url',
          'http://127.0.0.1:${mockOllama.port}',
        ],
        cwd: repoDir.path,
      );
      addTearDown(bridge.dispose);
      await bridge.connect();

      final state = await bridge.getState();
      final session = state['session'] as Map<String, dynamic>;
      final available = (session['availableModels'] as List)
          .map((e) => (e as Map)['value'] as String)
          .toList(growable: false);
      expect(
        available,
        containsAll(<String>[
          'local-ollama/gemma4:12b',
          'local-ollama/qwen3.8:27b',
        ]),
      );
    });
  });
}

class _NoopLlmDriver implements LlmDriver {
  _NoopLlmDriver(this.providerId);

  @override
  final LlmProviderId providerId;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    yield const LlmTextDelta('ok');
    yield LlmDoneEvent(
      LlmChatResponse(
        content: 'ok',
        usage: const LlmUsageTelemetry(
          promptTokens: 1,
          completionTokens: 1,
          cachedTokens: 0,
          durationMs: 1,
        ),
      ),
    );
  }
}

class _StreamPair {
  _StreamPair({
    required this.serverIn,
    required this.serverOut,
    required this.clientIn,
    required this.clientOut,
    required Future<void> Function() onClose,
  }) : _onClose = onClose;

  final Stream<List<int>> serverIn;
  final StreamSink<List<int>> serverOut;
  final Stream<List<int>> clientIn;
  final StreamSink<List<int>> clientOut;
  final Future<void> Function() _onClose;

  Future<void> close() => _onClose();
}

_StreamPair _createStreamPair() {
  final c2s = StreamController<List<int>>();
  final s2c = StreamController<List<int>>();
  return _StreamPair(
    serverIn: c2s.stream,
    serverOut: s2c.sink,
    clientIn: s2c.stream,
    clientOut: c2s.sink,
    onClose: () async {
      await c2s.close();
      await s2c.close();
    },
  );
}
