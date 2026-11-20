import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_acp/src/kanban/kanban_acp_bridge.dart';
import 'package:agent_acp/src/kanban/kanban_cli_runner.dart';
import 'package:agent_acp/src/kanban/kanban_server.dart';
import 'package:agent_acp/src/wire/wire_command_splitter.dart';
import 'package:agent_acp/src/wire/wire_redactor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _resolvePackageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final candidate = p.join(dir.path, 'packages', 'agent_acp', 'pubspec.yaml');
    if (File(candidate).existsSync()) {
      return p.normalize(p.join(dir.path, 'packages', 'agent_acp'));
    }
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        p.basename(dir.path) == 'agent_acp') {
      return p.normalize(dir.path);
    }
    dir = dir.parent;
  }
  throw StateError('Could not locate packages/agent_acp from ${Directory.current.path}');
}

const String _mockDaemonSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final stateDir = Platform.environment['MOCK_STATE_DIR']!;
  final logFile = File('$stateDir/daemon_events.jsonl');
  final exitMarker = File('$stateDir/daemon_exited.txt');

  void record(Map<String, dynamic> event) {
    logFile.writeAsStringSync('${jsonEncode(event)}\n', mode: FileMode.append);
  }

  record({'event': 'started', 'pid': pid, 'args': args});

  var activePrompt = false;
  var reqSeq = 0;
  final pendingClientRequests = <String, Completer<Object?>>{};
  final tasks = <Map<String, dynamic>>[];

  void sendFrame(Map<String, dynamic> frame) {
    stdout.writeln(jsonEncode(frame));
  }

  Future<Object?> sendClientRequest(String method, Map<String, dynamic> params) {
    final id = 'srv_${++reqSeq}';
    final c = Completer<Object?>();
    pendingClientRequests[id] = c;
    sendFrame({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return c.future;
  }

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final msg = jsonDecode(line) as Map<String, dynamic>;
    if (!msg.containsKey('method')) {
      final id = msg['id']?.toString();
      if (id != null && pendingClientRequests.containsKey(id)) {
        pendingClientRequests.remove(id)!.complete(msg['result']);
      }
      continue;
    }

    final method = msg['method'] as String;
    final id = msg['id'];
    final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};

    if (id == null) {
      record({'event': 'notification', 'method': method, 'params': params});
      continue;
    }

    Future<void>(() async {
      Object? result;
      switch (method) {
        case 'initialize':
          result = {'protocolVersion': 1, 'serverInfo': {'name': 'mock_daemon'}};
        case 'session/new':
          record({'event': 'session_new', 'params': params});
          result = {
            'sessionId': 'sess_mock_1',
            'configOptions': [
              {
                'id': 'model',
                'currentValue': 'local-ollama/gemma4:12b',
                'options': [
                  {'value': 'local-ollama/gemma4:12b', 'name': 'gemma4:12b'},
                  {'value': 'local-ollama/qwen3.8:27b', 'name': 'qwen3.8:27b'},
                ],
              }
            ],
          };
        case '_fm_agent_os/stack_create':
          final taskId = (params['taskId'] as String?) ?? 'task_${tasks.length + 1}';
          final node = {
            'taskId': taskId,
            'title': params['title'],
            'description': params['description'],
            'parentTaskId': params['parentTaskId'],
            'state': 'todo',
            'workingChangeId': 'chg_$taskId',
            'hasConflicts': false,
            'conflictedFiles': <String>[],
          };
          tasks.add(node);
          result = {'task': node};
        case '_fm_agent_os/stack_list':
          result = {'tasks': tasks};
        case '_fm_agent_os/processes':
          result = {
            'lead': {'pid': 1, 'state': 'idle', 'jjChangeId': 'chg_lead', 'jjOpId': 'op_1'},
            'processes': <Map<String, dynamic>>[],
          };
        case '_fm_agent_os/stack_update':
          final taskId = params['taskId'];
          for (final t in tasks) {
            if (t['taskId'] == taskId && params['model'] != null) {
              t['assignedModel'] = params['model'];
            }
          }
          result = {'ok': true, 'taskId': taskId};
        case 'session/set_config_option':
          record({'event': 'set_config_option', 'params': params});
          result = {'ok': true};
        case '_fm_agent_os/stack_edit':
          record({'event': 'stack_edit', 'params': params});
          result = {'task': {'taskId': params['taskId']}, 'cascadedTasks': <String>[]};
        case '_fm_agent_os/signal':
          record({'event': 'signal', 'params': params});
          result = {
            'ok': true,
            'signal': params['signal'],
            'affectedPids': [1],
            'leadState': params['signal'] == 'SIGSTOP' ? 'stopped' : 'running',
          };
        case '_fm_agent_os/jj_diff':
          result = {
            'diff': 'diff --git a/foo.dart b/foo.dart\n+hello',
            'conflictedFiles': <String>[],
          };
        case '_fm_agent_os/tx_squash':
          record({'event': 'tx_squash', 'params': params});
          final permResult = await sendClientRequest('session/request_permission', {
            'sessionId': params['sessionId'],
            'toolCall': {'title': 'Squash changes', 'kind': 'edit'},
            'options': [
              {'optionId': 'allow_once', 'name': 'Allow Once'},
              {'optionId': 'reject_once', 'name': 'Reject'},
            ],
          });
          record({'event': 'permission_outcome', 'outcome': permResult});
          result = {'ok': true, 'squashed': true};
        case '_fm_agent_os/stack_sync':
          result = {'tasks': tasks};
        case 'session/prompt':
          if (activePrompt) {
            sendFrame({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32000, 'message': 'Concurrent prompt rejected'},
            });
            return;
          }
          activePrompt = true;
          try {
            final meta = (params['_meta'] as Map?)?.cast<String, dynamic>() ?? {};
            final taskId = meta['fm_agent_os/taskId'];
            record({'event': 'prompt_start', 'taskId': taskId, 'meta': meta});
            sendFrame({
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': {
                'sessionId': params['sessionId'],
                'update': {
                  'sessionUpdate': 'agent_message_chunk',
                  'content': {'type': 'text', 'text': 'Working on $taskId'},
                },
              },
            });
            await Future<void>.delayed(const Duration(milliseconds: 120));
            for (final t in tasks) {
              if (t['taskId'] == taskId) {
                t['state'] = 'review';
              }
            }
            record({'event': 'prompt_end', 'taskId': taskId});
            result = {'stopReason': 'end_turn'};
          } finally {
            activePrompt = false;
          }
        default:
          sendFrame({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'Method not found: $method'},
          });
          return;
      }

      sendFrame({'jsonrpc': '2.0', 'id': id, 'result': result});
    });
  }

  exitMarker.writeAsStringSync('exited:$pid');
  record({'event': 'exited', 'pid': pid});
}
''';

void main() {
  final pkgRoot = _resolvePackageRoot();

  group('E3 Structural Boundary Checks [D-301], [D-322], [D-323]', () {
    test(
        'bin/acp_kanban_app.dart transitive import graph has 0 engine or agent_acp.dart imports',
        () {
      final entry = p.normalize(p.join(pkgRoot, 'bin', 'acp_kanban_app.dart'));
      expect(File(entry).existsSync(), isTrue);

      final visited = <String>{};
      final queue = <String>[entry];
      final forbiddenHits = <String>[];
      final directiveRegex = RegExp(
        r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
        multiLine: true,
      );

      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        if (!visited.add(current)) {
          continue;
        }
        final source = File(current).readAsStringSync();
        for (final match in directiveRegex.allMatches(source)) {
          final uri = match.group(1)!;
          if (uri.startsWith('package:agent_kernel') ||
              uri.startsWith('package:agent_drivers') ||
              uri.startsWith('package:agent_runtime') ||
              uri == 'package:agent_acp/agent_acp.dart') {
            forbiddenHits.add('$current -> $uri');
            continue;
          }
          String? nextPath;
          if (uri.startsWith('package:agent_acp/')) {
            final rel = uri.substring('package:agent_acp/'.length);
            nextPath = p.normalize(p.join(pkgRoot, 'lib', rel));
          } else if (!uri.contains(':')) {
            nextPath = p.normalize(p.join(p.dirname(current), uri));
          }
          if (nextPath != null && File(nextPath).existsSync()) {
            queue.add(nextPath);
          }
        }
      }

      expect(
        visited.length,
        greaterThanOrEqualTo(8),
        reason: 'Expected to traverse bin + kanban + wire files.',
      );
      expect(
        forbiddenHits,
        isEmpty,
        reason: 'Forbidden engine/barrel imports detected: $forbiddenHits',
      );
    });

    test('kanban_ui_assets.dart has 0 external http:// or https:// references',
        () {
      final assetsFile = File(
        p.join(pkgRoot, 'lib', 'src', 'kanban', 'kanban_ui_assets.dart'),
      );
      expect(assetsFile.existsSync(), isTrue);
      final content = assetsFile.readAsStringSync();
      expect(
        RegExp(r'https?://', caseSensitive: false).allMatches(content),
        isEmpty,
        reason: 'External CDN/URL references are forbidden in kanban_ui_assets.dart',
      );
    });

    test('kanban_server.dart binds strictly to InternetAddress.loopbackIPv4',
        () {
      final serverFile = File(
        p.join(pkgRoot, 'lib', 'src', 'kanban', 'kanban_server.dart'),
      );
      expect(serverFile.existsSync(), isTrue);
      final content = serverFile.readAsStringSync();
      expect(content, contains('InternetAddress.loopbackIPv4'));
      expect(content, isNot(contains('anyIPv4')));
      expect(content, isNot(contains('0.0.0.0')));
    });
  });

  group('Pure Wire Layer Unit Tests [D-321], [D-322]', () {
    test('splitWireCommandArgs handles quotes and Windows backslash paths', () {
      expect(
        splitWireCommandArgs(r'C:\tools\demo_mcp.exe --stdio "arg with spaces"'),
        equals(<String>[
          r'C:\tools\demo_mcp.exe',
          '--stdio',
          'arg with spaces',
        ]),
      );
      expect(
        splitWireCommandArgs("python -c 'print(1)'"),
        equals(<String>['python', '-c', 'print(1)']),
      );
      expect(
        () => splitWireCommandArgs('unclosed "quote'),
        throwsFormatException,
      );
    });

    test('parseWireMcpServerSpec parses JSON and name=cmd notations & redacts env',
        () {
      final redactor = WireSecretRedactor();
      final fromJson = parseWireMcpServerSpec(
        '{"name":"demo","command":"dart","args":["run","srv.dart"],"env":[{"name":"API_KEY","value":"secret-mcp-val-123"}]}',
        redactor: redactor,
      );
      expect(fromJson.name, equals('demo'));
      expect(fromJson.command, equals('dart'));
      expect(fromJson.args, equals(<String>['run', 'srv.dart']));
      expect(
        redactor.redactString('leaked secret-mcp-val-123 here'),
        equals('leaked <REDACTED> here'),
      );

      final fromEq = parseWireMcpServerSpec(
        r'local=C:\tools\mcp.exe --flag "two words"',
      );
      expect(fromEq.name, equals('local'));
      expect(fromEq.command, equals(r'C:\tools\mcp.exe'));
      expect(fromEq.args, equals(<String>['--flag', 'two words']));

      expect(
        () => parseWireMcpServerSpec('{"type":"http","name":"x","command":"y"}'),
        throwsFormatException,
      );
      expect(
        () => parseWireMcpServerSpec('invalid_no_equals'),
        throwsFormatException,
      );
    });
  });

  group('KanbanServer & KanbanAcpBridge Security, FIFO Queue, and API Tests [D-322], [D-323]',
      () {
    late Directory tempDir;
    late Directory repoDir;
    late File mockDaemonFile;
    late KanbanAcpBridge bridge;
    late KanbanServer server;
    late StringBuffer outBuf;
    late StringBuffer errBuf;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('fm_wp6_kanban_');
      repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync();
      Directory(p.join(repoDir.path, '.jj')).createSync();
      mockDaemonFile = File(p.join(tempDir.path, 'mock_daemon.dart'))
        ..writeAsStringSync(_mockDaemonSource);

      outBuf = StringBuffer();
      errBuf = StringBuffer();

      bridge = await KanbanAcpBridge.spawn(
        executable: Platform.resolvedExecutable,
        arguments: <String>[mockDaemonFile.path],
        cwd: repoDir.path,
        environment: <String, String>{'MOCK_STATE_DIR': tempDir.path},
        onDaemonStderr: (line) => errBuf.writeln(line),
      );
      try {
        await bridge.connect();
      } catch (e) {
        fail('bridge.connect() failed: $e\nstderr:\n$errBuf');
      }

      server = await KanbanServer.start(
        bridge: bridge,
        port: 0,
        out: outBuf,
        err: errBuf,
      );
    });

    tearDown(() async {
      await server.shutdown();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<({int status, String body, HttpHeaders headers})> httpCall(
      String method,
      String path, {
      Map<String, String>? headers,
      Object? jsonBody,
    }) async {
      final client = HttpClient();
      try {
        final req = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${server.port}$path'),
        );
        headers?.forEach((k, v) => req.headers.set(k, v));
        if (jsonBody != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(jsonBody));
        }
        final res = await req.close();
        final body = await utf8.decoder.bind(res).join();
        return (status: res.statusCode, body: body, headers: res.headers);
      } finally {
        client.close(force: true);
      }
    }

    test('KANBAN_READY output hides CSRF token and GET / distributes meta tag & CSP',
        () async {
      final readyLine = outBuf.toString().trim();
      expect(
        readyLine,
        equals('KANBAN_READY url=http://127.0.0.1:${server.port}/'),
      );
      expect(readyLine, isNot(contains(server.csrfToken)));
      expect(errBuf.toString(), isNot(contains(server.csrfToken)));

      final res = await httpCall('GET', '/');
      expect(res.status, equals(200));
      expect(
        res.body,
        contains('<meta name="csrf-token" content="${server.csrfToken}"'),
      );
      expect(res.headers.value('x-frame-options'), equals('DENY'));
      expect(res.headers.value('cache-control'), equals('no-store'));
      expect(
        res.headers.value('content-security-policy'),
        contains("connect-src 'self' ws://127.0.0.1:${server.port}"),
      );
    });

    test('Rejects missing/wrong CSRF token and foreign Origin with 403 on HTTP and WS',
        () async {
      final missingTok = await httpCall(
        'POST',
        '/api/cards',
        jsonBody: <String, dynamic>{'title': 'Bad'},
      );
      expect(missingTok.status, equals(403));

      final wrongTok = await httpCall(
        'POST',
        '/api/cards',
        headers: <String, String>{'X-CSRF-Token': 'wrong-token'},
        jsonBody: <String, dynamic>{'title': 'Bad'},
      );
      expect(wrongTok.status, equals(403));

      final foreignOrigin = await httpCall(
        'POST',
        '/api/cards',
        headers: <String, String>{
          'X-CSRF-Token': server.csrfToken,
          'Origin': 'http://evil.example',
        },
        jsonBody: <String, dynamic>{'title': 'Bad'},
      );
      expect(foreignOrigin.status, equals(403));

      final stateNoTok = await httpCall('GET', '/api/state');
      expect(stateNoTok.status, equals(403));

      await expectLater(
        WebSocket.connect('ws://127.0.0.1:${server.port}/ws'),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:${server.port}/ws?token=${server.csrfToken}',
          headers: <String, dynamic>{'Origin': 'http://evil.example'},
        ),
        throwsA(isA<WebSocketException>()),
      );
    });

    test('FIFO run queue serializes concurrent runs, attaches _meta, and removes SIGKILLed queued card',
        () async {
      final csrf = <String, String>{'X-CSRF-Token': server.csrfToken};

      await httpCall('POST', '/api/cards', headers: csrf, jsonBody: {
        'taskId': 't1',
        'title': 'Task 1',
      });
      await httpCall('POST', '/api/cards', headers: csrf, jsonBody: {
        'taskId': 't2',
        'title': 'Task 2',
        'parentTaskId': 't1',
      });
      await httpCall('POST', '/api/cards', headers: csrf, jsonBody: {
        'taskId': 't3',
        'title': 'Task 3',
      });

      final r1 = await httpCall('POST', '/api/cards/run', headers: csrf, jsonBody: {
        'taskId': 't1',
        'model': 'local-ollama/qwen3.8:27b',
        'executionMode': 'parallel_team',
      });
      final r2 = await httpCall('POST', '/api/cards/run', headers: csrf, jsonBody: {
        'taskId': 't2',
      });
      final r3 = await httpCall('POST', '/api/cards/run', headers: csrf, jsonBody: {
        'taskId': 't3',
      });
      expect(r1.status, equals(200));
      expect(r2.status, equals(200));
      expect(r3.status, equals(200));

      // Cancel t3 while it is still waiting in the FIFO queue.
      final killQueued = await httpCall('POST', '/api/signal', headers: csrf, jsonBody: {
        'signal': 'SIGKILL',
        'taskId': 't3',
      });
      expect(killQueued.status, equals(200));
      expect(jsonDecode(killQueued.body)['removedFromQueue'], isTrue);

      // Wait for t1 and t2 to finish sequentially.
      final logFile = File(p.join(tempDir.path, 'daemon_events.jsonl'));
      var events = <Map<String, dynamic>>[];
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (logFile.existsSync()) {
          events = const LineSplitter()
              .convert(logFile.readAsStringSync())
              .where((l) => l.trim().isNotEmpty)
              .map((l) => jsonDecode(l) as Map<String, dynamic>)
              .toList();
          final ends = events.where((e) => e['event'] == 'prompt_end').toList();
          if (ends.length >= 2) {
            break;
          }
        }
      }

      final starts = events.where((e) => e['event'] == 'prompt_start').toList();
      final ends = events.where((e) => e['event'] == 'prompt_end').toList();
      expect(starts.map((e) => e['taskId']).toList(), equals(['t1', 't2']));
      expect(ends.map((e) => e['taskId']).toList(), equals(['t1', 't2']));
      expect(
        starts.first['meta'],
        equals({
          'fm_agent_os/taskId': 't1',
          'fm_agent_os/executionMode': 'parallel_team',
          'fm_agent_os/modelOverride': 'local-ollama/qwen3.8:27b',
        }),
      );
      // Ensure t1 ended before t2 started (strict FIFO, no -32000).
      final t1EndIdx = events.indexWhere(
          (e) => e['event'] == 'prompt_end' && e['taskId'] == 't1');
      final t2StartIdx = events.indexWhere(
          (e) => e['event'] == 'prompt_start' && e['taskId'] == 't2');
      expect(t1EndIdx, lessThan(t2StartIdx));
    });

    test('Full REST + WebSocket round-trip and chained clean shutdown', () async {
      final csrf = <String, String>{'X-CSRF-Token': server.csrfToken};

      final ws = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws?token=${server.csrfToken}',
      );
      final wsMessages = <Map<String, dynamic>>[];
      final permCompleter = Completer<String>();
      final wsSub = ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        wsMessages.add(msg);
        if (msg['type'] == 'permission_requested' && !permCompleter.isCompleted) {
          final perm = msg['permission'] as Map<String, dynamic>;
          permCompleter.complete(perm['requestId'] as String);
        }
      });
      addTearDown(() async {
        await wsSub.cancel();
        await ws.close();
      });

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(wsMessages.first['type'], equals('snapshot'));

      await httpCall('POST', '/api/cards', headers: csrf, jsonBody: {
        'taskId': 'card_a',
        'title': 'Card A',
      });
      final editRes = await httpCall('POST', '/api/cards/edit', headers: csrf, jsonBody: {
        'taskId': 'card_a',
        'relativePath': 'lib/a.dart',
        'content': 'int a() => 1;',
      });
      expect(editRes.status, equals(200));

      final modelRes = await httpCall('POST', '/api/model', headers: csrf, jsonBody: {
        'model': 'local-ollama/qwen3.8:27b',
      });
      expect(modelRes.status, equals(200));

      final sigRes = await httpCall('POST', '/api/signal', headers: csrf, jsonBody: {
        'signal': 'SIGCONT',
        'constraintMessage': 'Use strict types',
      });
      expect(sigRes.status, equals(200));

      final diffRes = await httpCall('POST', '/api/diff', headers: csrf, jsonBody: {
        'taskId': 'card_a',
      });
      expect(diffRes.status, equals(200));
      expect(jsonDecode(diffRes.body)['diff'], contains('+hello'));

      // Trigger squash -> daemon sends session/request_permission -> approve via HTTP.
      final squashFuture = httpCall('POST', '/api/squash', headers: csrf, jsonBody: {
        'taskId': 'card_a',
      });
      final reqId = await permCompleter.future.timeout(const Duration(seconds: 3));
      final permRes = await httpCall('POST', '/api/permissions/respond', headers: csrf, jsonBody: {
        'requestId': reqId,
        'optionId': 'allow_once',
      });
      expect(permRes.status, equals(200));

      final squashRes = await squashFuture;
      expect(squashRes.status, equals(200));
      expect(jsonDecode(squashRes.body)['squashed'], isTrue);

      // Chained shutdown via POST /api/shutdown
      final shutRes = await httpCall('POST', '/api/shutdown', headers: csrf, jsonBody: {});
      expect(shutRes.status, equals(200));
      await server.done.timeout(const Duration(seconds: 5));

      final exitMarker = File(p.join(tempDir.path, 'daemon_exited.txt'));
      expect(exitMarker.existsSync(), isTrue);
    });

    test('KanbanCliRunner rejects invalid port and non-jj cwd with exit code 64',
        () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final runner = KanbanCliRunner(out: out, err: err);

      expect(
        await runner.run(<String>['--cwd', tempDir.path, '--port', '99999']),
        equals(64),
      );
      expect(
        await runner.run(<String>['--cwd', repoDir.path, '--max-context-tokens', '0']),
        equals(64),
      );
    });
  });
}
