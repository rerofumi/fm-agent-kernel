import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _resolveRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(dir.path, 'packages', 'agent_acp')).existsSync()) {
      return p.normalize(dir.path);
    }
    dir = dir.parent;
  }
  throw StateError(
    'Could not locate repository root from ${Directory.current.path}',
  );
}

List<File> _dartFilesIn(Directory dir) {
  if (!dir.existsSync()) {
    return const <File>[];
  }
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList(growable: false);
}

String _stripLineComments(String source) {
  final out = StringBuffer();
  for (final line in const LineSplitter().convert(source)) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//') || trimmed.startsWith('///')) {
      continue;
    }
    out.writeln(line);
  }
  return out.toString();
}

Map<String, String> _buildSdkExcludedEnv() {
  final env = Map<String, String>.from(Platform.environment);
  env.remove('OPENROUTER_API_KEY');

  final jjWhich = Process.runSync('where.exe', const <String>['jj']);
  final jjDirs = <String>{};
  if (jjWhich.exitCode == 0) {
    for (final line
        in const LineSplitter().convert(jjWhich.stdout as String)) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        final resolved = File(trimmed).resolveSymbolicLinksSync();
        jjDirs.add(p.dirname(resolved));
      }
    }
  }

  final sysRoot = env['SystemRoot'] ?? r'C:\Windows';
  final cleanPathEntries = <String>[
    p.join(sysRoot, 'System32'),
    sysRoot,
    p.join(sysRoot, 'System32', 'Wbem'),
    ...jjDirs.where(
      (d) =>
          !d.toLowerCase().contains('mise') &&
          !d.toLowerCase().contains('dart'),
    ),
  ];
  env['PATH'] = cleanPathEntries.join(';');
  return env;
}

void main() {
  final repoRoot = _resolveRepoRoot();
  final buildDir = p.join(repoRoot, 'build');
  final daemonExe = p.join(buildDir, 'agent_os_daemon.exe');
  final cliExe = p.join(buildDir, 'acp_cli_client.exe');
  final kanbanExe = p.join(buildDir, 'acp_kanban_app.exe');

  group('Stage 3 E3 Automated Architecture & Purity Checks [D-301]..[D-324]',
      () {
    test(
        'E3-1 [D-301]: packages/agent_kernel has 0 forbidden deps and 0 stdout refs',
        () {
      final kernelDir = Directory(p.join(repoRoot, 'packages', 'agent_kernel'));
      final pubspec =
          File(p.join(kernelDir.path, 'pubspec.yaml')).readAsStringSync();
      for (final forbiddenDep in const <String>[
        'http:',
        'win32:',
        'yaml:',
        'html:',
        'agent_drivers:',
        'agent_runtime:',
        'agent_acp:',
      ]) {
        expect(
          pubspec,
          isNot(contains(forbiddenDep)),
          reason: 'agent_kernel pubspec.yaml must not depend on $forbiddenDep',
        );
      }

      final forbiddenPatterns = <RegExp>[
        RegExp(r"import\s+'dart:ffi'"),
        RegExp(r"import\s+'dart:mirrors'"),
        RegExp(r"import\s+'package:http/"),
        RegExp(r"import\s+'package:win32/"),
        RegExp(r"import\s+'package:yaml/"),
        RegExp(r"import\s+'package:html/"),
        RegExp(r"import\s+'package:agent_drivers/"),
        RegExp(r"import\s+'package:agent_runtime/"),
        RegExp(r"import\s+'package:agent_acp/"),
        RegExp(r'\bHttpClient\b|\bHttpServer\b'),
        RegExp(r"(?<![.\w'])\bstdout\b(?![\w'])"),
      ];

      final violations = <String>[];
      for (final file
          in _dartFilesIn(Directory(p.join(kernelDir.path, 'lib')))) {
        final code = _stripLineComments(file.readAsStringSync());
        for (final pat in forbiddenPatterns) {
          if (pat.hasMatch(code)) {
            violations.add('${p.relative(file.path, from: repoRoot)}: ${pat.pattern}');
          }
        }
      }
      expect(violations, isEmpty, reason: 'E3-1 violations: $violations');
    });

    test(
        'E3-2 [D-308]: child Isolate code does not replicate JjDriver; host owns single JjDriver._mutex',
        () {
      final childBootstrap = File(
        p.join(
          repoRoot,
          'packages',
          'agent_runtime',
          'lib',
          'src',
          'child_isolate_bootstrap.dart',
        ),
      ).readAsStringSync();
      final subAgentWorker = File(
        p.join(
          repoRoot,
          'packages',
          'agent_runtime',
          'lib',
          'src',
          'sub_agent_worker.dart',
        ),
      ).readAsStringSync();

      expect(childBootstrap, isNot(contains('JjDriver')));
      expect(childBootstrap, isNot(contains('jj_driver')));
      expect(subAgentWorker, isNot(contains('JjDriver')));
      expect(subAgentWorker, isNot(contains('jj_driver')));

      final jjDriver = File(
        p.join(
          repoRoot,
          'packages',
          'agent_drivers',
          'lib',
          'src',
          'jj',
          'jj_driver.dart',
        ),
      ).readAsStringSync();
      final mutexDeclMatches =
          RegExp(r'final\s+AsyncMutex\s+_mutex\b').allMatches(jjDriver).toList();
      expect(
        mutexDeclMatches,
        hasLength(1),
        reason: 'JjDriver must own exactly one AsyncMutex _mutex',
      );
    });

    test(
        'E3-3 [D-324]: daemon/engine path has 0 direct stdout refs outside JsonRpcPeer/WireJsonRpcPeer',
        () {
      final allowedStdoutFiles = <String>{
        p.normalize(
          p.join(
            repoRoot,
            'packages',
            'agent_acp',
            'lib',
            'src',
            'json_rpc_peer.dart',
          ),
        ),
        p.normalize(
          p.join(
            repoRoot,
            'packages',
            'agent_acp',
            'lib',
            'src',
            'wire',
            'wire_json_rpc_peer.dart',
          ),
        ),
      };
      final daemonEntry = p.normalize(
        p.join(repoRoot, 'packages', 'agent_acp', 'bin', 'agent_os_daemon.dart'),
      );

      final engineDirs = <Directory>[
        Directory(p.join(repoRoot, 'packages', 'agent_kernel', 'lib')),
        Directory(p.join(repoRoot, 'packages', 'agent_drivers', 'lib')),
        Directory(p.join(repoRoot, 'packages', 'agent_runtime', 'lib')),
      ];

      final acpEngineFiles = <File>[
        ..._dartFilesIn(Directory(p.join(repoRoot, 'packages', 'agent_acp', 'lib')))
            .where(
          (f) =>
              !f.path.contains('${p.separator}cli${p.separator}') &&
              !f.path.contains('${p.separator}kanban${p.separator}'),
        ),
        File(daemonEntry),
      ];

      // Match direct dart:io `stdout` sink usage (not `proc.stdout`, `'...stdout...'` strings).
      final directStdoutSink = RegExp(
        r'\bstdout\s*\.\s*(write|writeln|add|addStream|flush|close)\b|:\s*stdout\b',
      );
      final violations = <String>[];

      for (final file in <File>[
        for (final d in engineDirs) ..._dartFilesIn(d),
        ...acpEngineFiles,
      ]) {
        final norm = p.normalize(file.path);
        if (allowedStdoutFiles.contains(norm)) {
          continue;
        }
        final code = _stripLineComments(file.readAsStringSync());
        if (norm == daemonEntry) {
          // Only `output: stdout,` (passed to JsonRpcPeer) and `await stdout.flush();` are permitted.
          for (final line in const LineSplitter().convert(code)) {
            if (directStdoutSink.hasMatch(line) &&
                !line.contains('output: stdout') &&
                !line.contains('stdout.flush()')) {
              violations.add('agent_os_daemon.dart: $line');
            }
          }
          continue;
        }
        if (directStdoutSink.hasMatch(code)) {
          violations.add(p.relative(norm, from: repoRoot));
        }
      }
      expect(violations, isEmpty, reason: 'E3-3 stdout violations: $violations');
    });

    test(
        'E3-4 [D-322], [D-323]: kanban transitive import graph has 0 engine imports, 0 external CDN URLs, loopbackIPv4 only',
        () {
      final acpPkgRoot = p.join(repoRoot, 'packages', 'agent_acp');
      final queue = <String>[
        p.normalize(p.join(acpPkgRoot, 'bin', 'acp_kanban_app.dart')),
        ..._dartFilesIn(Directory(p.join(acpPkgRoot, 'lib', 'src', 'kanban')))
            .map((f) => p.normalize(f.path)),
      ];
      final visited = <String>{};
      final forbiddenHits = <String>[];
      final importRegex = RegExp(r'''import\s+['"]([^'"]+)['"]''');

      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        if (!visited.add(current)) {
          continue;
        }
        final content = File(current).readAsStringSync();
        for (final m in importRegex.allMatches(content)) {
          final uri = m.group(1)!;
          if (uri.startsWith('package:agent_kernel') ||
              uri.startsWith('package:agent_drivers') ||
              uri.startsWith('package:agent_runtime') ||
              uri == 'package:agent_acp/agent_acp.dart') {
            forbiddenHits.add('${p.relative(current, from: repoRoot)} -> $uri');
            continue;
          }
          String? nextPath;
          if (uri.startsWith('package:agent_acp/')) {
            nextPath = p.normalize(
              p.join(acpPkgRoot, 'lib', uri.substring('package:agent_acp/'.length)),
            );
          } else if (!uri.contains(':')) {
            nextPath = p.normalize(p.join(p.dirname(current), uri));
          }
          if (nextPath != null && File(nextPath).existsSync()) {
            queue.add(nextPath);
          }
        }
      }

      expect(visited.length, greaterThanOrEqualTo(8));
      expect(forbiddenHits, isEmpty);

      final uiAssets = File(
        p.join(acpPkgRoot, 'lib', 'src', 'kanban', 'kanban_ui_assets.dart'),
      ).readAsStringSync();
      expect(RegExp(r'https?://', caseSensitive: false).allMatches(uiAssets), isEmpty);

      final serverCode = File(
        p.join(acpPkgRoot, 'lib', 'src', 'kanban', 'kanban_server.dart'),
      ).readAsStringSync();
      expect(serverCode, contains('InternetAddress.loopbackIPv4'));
      expect(serverCode, isNot(contains('anyIPv4')));
      expect(serverCode, isNot(contains('0.0.0.0')));
    });

    test(
        'E3-5 [D-315], [D-324]: production 3 binary CLIs have 0 SSRF relaxation flags or crash-injection backdoors',
        () {
      final cliFiles = <File>[
        File(p.join(repoRoot, 'packages', 'agent_acp', 'bin', 'agent_os_daemon.dart')),
        File(p.join(repoRoot, 'packages', 'agent_acp', 'bin', 'acp_cli_client.dart')),
        File(p.join(repoRoot, 'packages', 'agent_acp', 'bin', 'acp_kanban_app.dart')),
        File(p.join(repoRoot, 'packages', 'agent_acp', 'lib', 'src', 'cli', 'acp_cli_runner.dart')),
        File(p.join(repoRoot, 'packages', 'agent_acp', 'lib', 'src', 'kanban', 'kanban_cli_runner.dart')),
      ];
      final backdoorPatterns = <RegExp>[
        RegExp(r'allow[-_]?private[-_]?ip', caseSensitive: false),
        RegExp(r'disable[-_]?ssrf', caseSensitive: false),
        RegExp(r'no[-_]?ssrf', caseSensitive: false),
        RegExp(r'inject[-_]?crash', caseSensitive: false),
        RegExp(r'fault[-_]?inject', caseSensitive: false),
        RegExp(r'crash[-_]?inject', caseSensitive: false),
      ];
      final hits = <String>[];
      for (final file in cliFiles) {
        final content = file.readAsStringSync();
        for (final pat in backdoorPatterns) {
          if (pat.hasMatch(content)) {
            hits.add('${p.basename(file.path)}: ${pat.pattern}');
          }
        }
      }
      expect(hits, isEmpty, reason: 'Backdoor flags detected: $hits');
    });
  });

  group('Stage 3 E1 AOT 3-Binary Standalone & NDJSON Purity [D-324]', () {
    test(
        'all 3 built .exe binaries start standalone with dart/mise excluded from PATH',
        () async {
      expect(File(daemonExe).existsSync(), isTrue, reason: 'Missing $daemonExe');
      expect(File(cliExe).existsSync(), isTrue, reason: 'Missing $cliExe');
      expect(File(kanbanExe).existsSync(), isTrue, reason: 'Missing $kanbanExe');

      final sdkExcludedEnv = _buildSdkExcludedEnv();
      // Confirm dart & mise are genuinely unreachable in sdkExcludedEnv.
      expect(
        Process.runSync(
          'where.exe',
          const <String>['dart'],
          environment: sdkExcludedEnv,
          includeParentEnvironment: false,
        ).exitCode,
        isNot(equals(0)),
      );
      expect(
        Process.runSync(
          'where.exe',
          const <String>['mise'],
          environment: sdkExcludedEnv,
          includeParentEnvironment: false,
        ).exitCode,
        isNot(equals(0)),
      );

      // 1. --help on all 3 binaries
      for (final exe in <String>[daemonExe, cliExe, kanbanExe]) {
        final helpRes = Process.runSync(
          exe,
          const <String>['--help'],
          environment: sdkExcludedEnv,
          includeParentEnvironment: false,
        );
        expect(
          helpRes.exitCode,
          equals(0),
          reason: '$exe --help failed: ${helpRes.stderr}',
        );
      }

      // 2. agent_os_daemon.exe initialize roundtrip
      final daemonProc = await Process.start(
        daemonExe,
        const <String>[],
        environment: sdkExcludedEnv,
        includeParentEnvironment: false,
      );
      final daemonStdout = <String>[];
      daemonProc.stdout
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen(daemonStdout.add);
      daemonProc.stdin.writeln(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{'protocolVersion': 1},
        }),
      );
      await daemonProc.stdin.flush();
      await daemonProc.stdin.close();
      expect(
        await daemonProc.exitCode.timeout(const Duration(seconds: 10)),
        equals(0),
      );
      expect(daemonStdout, hasLength(1));
      final initFrame = jsonDecode(daemonStdout.single) as Map<String, dynamic>;
      expect((initFrame['result'] as Map<String, dynamic>)['protocolVersion'], 1);

      // 3. acp_kanban_app.exe KANBAN_READY roundtrip with sibling agent_os_daemon.exe
      final tempRepo = Directory.systemTemp.createTempSync('fm_wp9_sdk_excl_');
      addTearDown(() {
        if (tempRepo.existsSync()) {
          tempRepo.deleteSync(recursive: true);
        }
      });
      final jjInit = Process.runSync(
        'jj',
        const <String>['--no-pager', 'git', 'init', '--colocate'],
        workingDirectory: tempRepo.path,
        environment: sdkExcludedEnv,
        includeParentEnvironment: false,
      );
      expect(jjInit.exitCode, equals(0), reason: '${jjInit.stderr}');

      final kanbanProc = await Process.start(
        kanbanExe,
        <String>[
          '--cwd',
          tempRepo.path,
          '--port',
          '0',
          '--no-open-browser',
        ],
        environment: sdkExcludedEnv,
        includeParentEnvironment: false,
      );
      final readyCompleter = Completer<String>();
      final kanbanOut = kanbanProc.stdout
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('KANBAN_READY ') && !readyCompleter.isCompleted) {
          readyCompleter.complete(line);
        }
      });
      addTearDown(kanbanOut.cancel);

      final readyLine =
          await readyCompleter.future.timeout(const Duration(seconds: 15));
      expect(readyLine, startsWith('KANBAN_READY url=http://127.0.0.1:'));

      await kanbanProc.stdin.close();
      expect(
        await kanbanProc.exitCode.timeout(const Duration(seconds: 15)),
        equals(0),
      );
    });

    test(
        'AOT agent_os_daemon.exe maintains 100% NDJSON stdout purity under parallel WorkspaceWorkers + stdio MCP subprocess + secret redaction',
        () async {
      expect(File(daemonExe).existsSync(), isTrue);

      final tempDir = Directory.systemTemp.createTempSync('fm_wp9_aot_purity_');
      addTearDown(() async {
        for (var i = 0; i < 10 && tempDir.existsSync(); i++) {
          try {
            tempDir.deleteSync(recursive: true);
            break;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      });

      final tempRepo = Directory(p.join(tempDir.path, 'repo'))..createSync();
      Process.runSync(
        'jj',
        const <String>['--no-pager', 'git', 'init', '--colocate'],
        workingDirectory: tempRepo.path,
      );
      Process.runSync(
        'jj',
        const <String>['--no-pager', 'config', 'set', '--repo', 'user.name', 'WP9'],
        workingDirectory: tempRepo.path,
      );
      Process.runSync(
        'jj',
        const <String>['--no-pager', 'config', 'set', '--repo', 'user.email', 'wp9@example.com'],
        workingDirectory: tempRepo.path,
      );
      File(p.join(tempRepo.path, 'pubspec.yaml')).writeAsStringSync('''
name: wp9_purity_sample
environment:
  sdk: ^3.10.0
''');
      File(p.join(tempRepo.path, 'lib', 'a.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('int a() => 1;\n');
      File(p.join(tempRepo.path, 'lib', 'b.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('int b() => 2;\n');
      Process.runSync(
        'jj',
        const <String>['--no-pager', 'describe', '-m', 'seed'],
        workingDirectory: tempRepo.path,
      );
      Process.runSync(
        'jj',
        const <String>['--no-pager', 'new', '-m', 'wip'],
        workingDirectory: tempRepo.path,
      );

      // Local mock OpenAI-compatible Ollama server driving parallel WorkspaceWorkers + stdio MCP call.
      var leadStep = 0;
      final workerSteps = <String, int>{};
      final mockOllama = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => mockOllama.close(force: true));

      mockOllama.listen((req) async {
        final path = req.uri.path;
        if (!path.endsWith('/chat')) {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('{}');
          await req.response.close();
          return;
        }

        final bodyStr = await utf8.decoder.bind(req).join();
        final body = jsonDecode(bodyStr) as Map<String, dynamic>;
        final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
        final sysText = messages.first['content']?.toString() ?? '';

        Map<String, dynamic> replyMessage;
        if (sysText.contains('WorkspaceWorker')) {
          final userText = messages
              .firstWhere((m) => m['role'] == 'user')['content']
              .toString();
          final key = userText.contains('worker1') ? 'w1' : 'w2';
          final step = (workerSteps[key] ?? 0) + 1;
          workerSteps[key] = step;
          final targetFile =
              key == 'w1' ? '/workspace/lib/a.dart' : '/workspace/lib/b.dart';
          if (step == 1) {
            replyMessage = {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'tc_${key}_1',
                  'type': 'function',
                  'function': {
                    'name': 'sys_write_file',
                    'arguments': {
                      'path': targetFile,
                      'content': 'int $key() => 42;\n',
                    },
                  },
                },
              ],
            };
          } else if (step == 2) {
            replyMessage = {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'tc_${key}_2',
                  'type': 'function',
                  'function': {
                    'name': 'sys_exec',
                    'arguments': {
                      'command': 'dart analyze',
                    },
                  },
                },
              ],
            };
          } else {
            replyMessage = {
              'role': 'assistant',
              'content': 'Worker $key completed.',
            };
          }
        } else {
          leadStep += 1;
          if (leadStep == 1) {
            replyMessage = {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'lead_sp1',
                  'type': 'function',
                  'function': {
                    'name': 'sys_spawn',
                    'arguments': {
                      'profile': 'workspace_worker',
                      'name': 'worker1',
                      'taskPrompt': 'Edit worker1 file',
                    },
                  },
                },
                {
                  'id': 'lead_sp2',
                  'type': 'function',
                  'function': {
                    'name': 'sys_spawn',
                    'arguments': {
                      'profile': 'workspace_worker',
                      'name': 'worker2',
                      'taskPrompt': 'Edit worker2 file',
                    },
                  },
                },
              ],
            };
          } else if (leadStep == 2) {
            replyMessage = {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'lead_wait',
                  'type': 'function',
                  'function': {
                    'name': 'sys_wait',
                    'arguments': {'timeoutMs': 20000},
                  },
                },
              ],
            };
          } else if (leadStep == 3) {
            replyMessage = {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'lead_mcp',
                  'type': 'function',
                  'function': {
                    'name': 'sys_mcp_call',
                    'arguments': {
                      'server': 'mock_mcp',
                      'tool': 'echo_secret_check',
                      'arguments': {'text': 'wp9_purity_ping'},
                    },
                  },
                },
              ],
            };
          } else {
            replyMessage = {
              'role': 'assistant',
              'content': 'All parallel WorkspaceWorkers and MCP completed.',
            };
          }
        }

        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'x-ndjson')
          ..writeln(jsonEncode({
            'model': 'gemma4:12b',
            'message': replyMessage,
            'done': true,
            'prompt_eval_count': 100,
            'eval_count': 20,
          }));
        await req.response.close();
      });

      final mcpFixture = p.join(
        repoRoot,
        'packages',
        'agent_drivers',
        'test',
        'fixtures',
        'mock_stdio_mcp_server.dart',
      );
      expect(File(mcpFixture).existsSync(), isTrue);

      final daemonProc = await Process.start(
        daemonExe,
        <String>[
          '--model',
          'local-ollama/gemma4:12b',
          '--ollama-url',
          'http://127.0.0.1:${mockOllama.port}/v1',
        ],
        workingDirectory: tempRepo.path,
        runInShell: false,
      );

      final rawStdoutBytes = <int>[];
      final rawStderrBytes = <int>[];
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      daemonProc.stdout.listen(
        rawStdoutBytes.addAll,
        onDone: () {
          if (!stdoutDone.isCompleted) stdoutDone.complete();
        },
      );
      daemonProc.stderr.listen(
        rawStderrBytes.addAll,
        onDone: () {
          if (!stderrDone.isCompleted) stderrDone.complete();
        },
      );

      final rpcResponses = <Object?, Map<String, dynamic>>{};
      final promptCompleter = Completer<Map<String, dynamic>>();

      // Monitor stdout incrementally for permission requests and prompt completion.
      var parsedOffset = 0;
      Timer.periodic(const Duration(milliseconds: 30), (timer) {
        if (rawStdoutBytes.length > parsedOffset) {
          final text = utf8.decode(rawStdoutBytes, allowMalformed: true);
          final lines = const LineSplitter().convert(text);
          parsedOffset = rawStdoutBytes.length;
          for (final line in lines) {
            if (line.trim().isEmpty) continue;
            final frame = jsonDecode(line) as Map<String, dynamic>;
            if (frame['method'] == 'session/request_permission' &&
                frame.containsKey('id')) {
              daemonProc.stdin.writeln(jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {
                  'outcome': {'outcome': 'selected', 'optionId': 'allow_once'},
                },
              }));
            } else if (frame.containsKey('id') && !frame.containsKey('method')) {
              rpcResponses[frame['id']] = frame;
              if (frame['id'] == 3 && !promptCompleter.isCompleted) {
                promptCompleter.complete(frame);
                timer.cancel();
              }
            }
          }
        }
        if (promptCompleter.isCompleted) {
          timer.cancel();
        }
      });

      daemonProc.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': 1},
      }));
      daemonProc.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'session/new',
        'params': {
          'cwd': tempRepo.path,
          'mcpServers': [
            {
              'name': 'mock_mcp',
              'command': Platform.resolvedExecutable,
              'args': ['run', mcpFixture],
              'env': [
                {'name': 'MCP_SECRET_TOKEN', 'value': 'wp9-super-secret-mcp-999'},
              ],
            },
          ],
        },
      }));
      // Wait briefly for session/new response.
      for (var i = 0; i < 100 && !rpcResponses.containsKey(2); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(rpcResponses[2], isNotNull);
      final sessionId =
          (rpcResponses[2]!['result'] as Map<String, dynamic>)['sessionId']
              as String;

      daemonProc.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'session/prompt',
        'params': {
          'sessionId': sessionId,
          'prompt': [
            {'type': 'text', 'text': 'Run parallel workers and MCP tool'},
          ],
        },
      }));

      final promptRes =
          await promptCompleter.future.timeout(const Duration(seconds: 45));
      expect(promptRes['error'], isNull);

      await daemonProc.stdin.close();
      expect(
        await daemonProc.exitCode.timeout(const Duration(seconds: 15)),
        equals(0),
      );
      await Future.wait(<Future<void>>[stdoutDone.future, stderrDone.future]);

      // Verify EVERY single byte/line on stdout is valid JSON-RPC 2.0 NDJSON and contains 0 secrets!
      final stdoutText = utf8.decode(rawStdoutBytes);
      expect(stdoutText, isNot(contains('wp9-super-secret-mcp-999')));
      final lines = const LineSplitter()
          .convert(stdoutText)
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines.length, greaterThanOrEqualTo(4));
      for (final line in lines) {
        final decoded = jsonDecode(line);
        expect(decoded, isA<Map<String, dynamic>>());
        expect((decoded as Map<String, dynamic>)['jsonrpc'], equals('2.0'));
      }
    });

    test(
        'Child Isolate intentional print() and uncaught exception redirect to stderr with 0 stdout bytes',
        () async {
      final hostPort = ReceivePort();
      addTearDown(hostPort.close);
      final fatalCompleter = Completer<Map<String, dynamic>>();
      hostPort.listen((dynamic msg) {
        if (msg is Map &&
            msg['type'] == 'worker_fatal' &&
            !fatalCompleter.isCompleted) {
          fatalCompleter.complete(msg.cast<String, dynamic>());
        }
      });

      final outBuf = StringBuffer();
      await runZoned(
        () async {
          await Isolate.spawn<Map<String, Object?>>(
            childIsolateEntryPoint,
            <String, Object?>{
              'hostPort': hostPort.sendPort,
              'pid': 99,
              'diagnosticMode': 'print_and_throw',
            },
          );
          final fatal =
              await fatalCompleter.future.timeout(const Duration(seconds: 10));
          expect(fatal['pid'], equals(99));
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            outBuf.writeln(line);
          },
        ),
      );
      expect(outBuf.toString(), isEmpty);
    });
  });
}
