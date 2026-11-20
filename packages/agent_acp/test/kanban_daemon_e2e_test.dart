import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_acp/src/kanban/kanban_acp_bridge.dart';
import 'package:agent_acp/src/kanban/kanban_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _resolveRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(dir.path, 'packages', 'agent_acp', 'pubspec.yaml'))
        .existsSync()) {
      return p.normalize(dir.path);
    }
    dir = dir.parent;
  }
  throw StateError('Could not locate repo root from ${Directory.current.path}');
}

Future<Map<String, dynamic>> _httpJson(
  HttpClient client,
  String method,
  String url, {
  String? csrfToken,
  String? origin,
  Map<String, dynamic>? body,
}) async {
  final uri = Uri.parse(url);
  final req = await client.openUrl(method, uri);
  if (csrfToken != null) {
    req.headers.set('X-CSRF-Token', csrfToken);
  }
  if (origin != null) {
    req.headers.set('Origin', origin);
  }
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
  }
  final resp = await req.close();
  final raw = await utf8.decoder.bind(resp).join();
  final decoded = raw.trim().isEmpty
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  return <String, dynamic>{
    'status': resp.statusCode,
    'body': decoded,
  };
}

String _extractCsrfFromHtml(String html) {
  final match = RegExp(
    r'''<meta\s+name="csrf-token"\s+content="([^"]+)"\s*/?>''',
  ).firstMatch(html);
  if (match == null) {
    throw StateError('Missing <meta name="csrf-token"> in HTML');
  }
  return match.group(1)!;
}

void main() {
  final repoRoot = _resolveRepoRoot();
  final daemonScript = p.join(
    repoRoot,
    'packages',
    'agent_acp',
    'bin',
    'agent_os_daemon.dart',
  );

  group('WP-8 KanbanServer x Real agent_os_daemon E2E [REQ-05, REQ-09, REQ-11]',
      () {
    late Directory tempRepo;
    late HttpServer mockOllama;
    late String ollamaBaseUrl;

    ProcessResult runJj(List<String> args, {String? cwd}) {
      return Process.runSync(
        'jj',
        <String>['--no-pager', ...args],
        workingDirectory: cwd ?? tempRepo.path,
        runInShell: false,
        environment: <String, String>{
          'JJ_CONFIG': '',
          'JJ_USER': 'WP8 Tester',
          'JJ_EMAIL': 'wp8@example.com',
        },
      );
    }

    setUp(() async {
      tempRepo = Directory.systemTemp.createTempSync('fm_wp8_e2e_');
      expect(runJj(<String>['git', 'init', '--colocate']).exitCode, 0);
      runJj(<String>['config', 'set', '--repo', 'user.name', 'WP8 Tester']);
      runJj(
          <String>['config', 'set', '--repo', 'user.email', 'wp8@example.com']);
      Directory(p.join(tempRepo.path, 'lib')).createSync(recursive: true);
      File(p.join(tempRepo.path, 'lib', 'calc.dart'))
          .writeAsStringSync('int calc() => 1;\n');
      expect(runJj(<String>['describe', '-m', 'base']).exitCode, 0);
      expect(runJj(<String>['new', '-m', 'wip']).exitCode, 0);
    });

    tearDown(() async {
      if (tempRepo.existsSync()) {
        try {
          tempRepo.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test(
        'KANBAN_READY, CSRF 403, Stacked c_A->c_B inheritance, FIFO queue (no -32000), model switch, diff, Ring 2 reject/approve squash, stack_edit auto-rebase, and chained shutdown',
        () async {
      var taskATurn = 0;
      mockOllama = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      ollamaBaseUrl = 'http://127.0.0.1:${mockOllama.port}/v1';
      addTearDown(() => mockOllama.close(force: true));

      mockOllama.listen((HttpRequest req) async {
        if (req.uri.path == '/api/chat' && req.method == 'POST') {
          final bodyStr = await utf8.decoder.bind(req).join();
          final reqJson = jsonDecode(bodyStr) as Map<String, dynamic>;
          final messages =
              (reqJson['messages'] as List).cast<Map<dynamic, dynamic>>();
          final userText = messages
              .where((m) => m['role'] == 'user')
              .map((m) => m['content']?.toString() ?? '')
              .join('\n');

          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType =
              ContentType('application', 'x-ndjson', charset: 'utf-8');

          if (userText.contains('TASK_A_WRITE_CALC') && taskATurn == 0) {
            taskATurn++;
            req.response.writeln(jsonEncode(<String, dynamic>{
              'model': reqJson['model'],
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'function': <String, dynamic>{
                      'name': 'sys_read_lines',
                      'arguments': <String, dynamic>{
                        'path': '/workspace/lib/calc.dart',
                        'startLine': 1,
                        'endLine': 20,
                      },
                    },
                  },
                ],
              },
              'done': true,
              'prompt_eval_count': 40,
              'eval_count': 15,
            }));
          } else if (userText.contains('TASK_A_WRITE_CALC') && taskATurn == 1) {
            taskATurn++;
            final toolMsg = messages.lastWhere((m) => m['role'] == 'tool');
            final toolJson =
                jsonDecode(toolMsg['content'].toString()) as Map<String, dynamic>;
            final sha = toolJson['sha256'] as String;
            req.response.writeln(jsonEncode(<String, dynamic>{
              'model': reqJson['model'],
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'function': <String, dynamic>{
                      'name': 'sys_write_file',
                      'arguments': <String, dynamic>{
                        'path': '/workspace/lib/calc.dart',
                        'content': 'int calc() => 10;\n',
                        'expectedSha256': sha,
                        'createOnly': false,
                      },
                    },
                  },
                ],
              },
              'done': true,
              'prompt_eval_count': 40,
              'eval_count': 15,
            }));
          } else {
            req.response.writeln(jsonEncode(<String, dynamic>{
              'model': reqJson['model'],
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': 'Completed: ${userText.split('\n').last}',
              },
              'done': true,
              'prompt_eval_count': 30,
              'eval_count': 10,
            }));
          }
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final bridge = await KanbanAcpBridge.spawn(
        executable: Platform.resolvedExecutable,
        arguments: <String>[
          'run',
          daemonScript,
          '--model',
          'local-ollama/gemma4:12b',
          '--ollama-url',
          ollamaBaseUrl,
        ],
        cwd: tempRepo.path,
        permissionPolicy: 'interactive',
      );
      await bridge.connect();

      final outBuf = StringBuffer();
      final errBuf = StringBuffer();
      final server = await KanbanServer.start(
        bridge: bridge,
        port: 0,
        out: outBuf,
        err: errBuf,
      );
      addTearDown(() => server.shutdown());

      // 1. KANBAN_READY & CSRF non-exposure
      expect(
        outBuf.toString().trim(),
        equals('KANBAN_READY url=http://127.0.0.1:${server.port}/'),
      );
      expect(outBuf.toString(), isNot(contains(server.csrfToken)));
      expect(errBuf.toString(), isNot(contains(server.csrfToken)));

      final http = HttpClient();
      addTearDown(() => http.close(force: true));

      // 2. GET / HTML & CSRF 403 checks
      final htmlReq = await http.getUrl(Uri.parse(server.url));
      final htmlResp = await htmlReq.close();
      expect(htmlResp.statusCode, HttpStatus.ok);
      final html = await utf8.decoder.bind(htmlResp).join();
      final csrf = _extractCsrfFromHtml(html);
      expect(csrf, equals(server.csrfToken));

      final noTokenRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/cards',
        body: <String, dynamic>{'title': 'Blocked'},
      );
      expect(noTokenRes['status'], HttpStatus.forbidden);

      final foreignOriginRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/cards',
        csrfToken: csrf,
        origin: 'http://evil.example:9999',
        body: <String, dynamic>{'title': 'Blocked'},
      );
      expect(foreignOriginRes['status'], HttpStatus.forbidden);

      // 3. WebSocket connection & initial snapshot
      final wsEvents = <Map<String, dynamic>>[];
      final ws = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws?token=$csrf',
        headers: <String, dynamic>{
          'Origin': 'http://127.0.0.1:${server.port}',
        },
      );
      ws.listen((dynamic raw) {
        if (raw is String) {
          wsEvents.add(
              Map<String, dynamic>.from(jsonDecode(raw) as Map));
        }
      });
      addTearDown(() => ws.close());

      for (var i = 0; i < 40; i++) {
        if (wsEvents.any((e) => e['type'] == 'snapshot')) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(wsEvents.any((e) => e['type'] == 'snapshot'), isTrue);

      // 4. Create card A and Stacked child card B
      final createA = await _httpJson(
        http,
        'POST',
        '${server.url}api/cards',
        csrfToken: csrf,
        body: <String, dynamic>{
          'taskId': 'task_a',
          'title': 'Task A Base Calc',
          'description': 'TASK_A_WRITE_CALC',
        },
      );
      expect(createA['status'], HttpStatus.ok);

      final createB = await _httpJson(
        http,
        'POST',
        '${server.url}api/cards',
        csrfToken: csrf,
        body: <String, dynamic>{
          'taskId': 'task_b',
          'title': 'Task B Stacked Child',
          'description': 'TASK_B_VERIFY',
          'parentTaskId': 'task_a',
        },
      );
      expect(createB['status'], HttpStatus.ok);

      // 5. Model switch on card B
      final modelRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/model',
        csrfToken: csrf,
        body: <String, dynamic>{
          'taskId': 'task_b',
          'model': 'local-ollama/qwen3.8:27b',
        },
      );
      expect(modelRes['status'], HttpStatus.ok);

      // 6. Back-to-back POST /api/cards/run -> FIFO queue (no -32000 error!)
      final runResults = await Future.wait(<Future<Map<String, dynamic>>>[
        _httpJson(
          http,
          'POST',
          '${server.url}api/cards/run',
          csrfToken: csrf,
          body: <String, dynamic>{
            'taskId': 'task_a',
            'prompt': 'TASK_A_WRITE_CALC',
          },
        ),
        _httpJson(
          http,
          'POST',
          '${server.url}api/cards/run',
          csrfToken: csrf,
          body: <String, dynamic>{
            'taskId': 'task_b',
            'prompt': 'TASK_B_VERIFY',
          },
        ),
      ]);
      expect(runResults[0]['status'], HttpStatus.ok);
      expect(runResults[1]['status'], HttpStatus.ok);

      // Wait for both cards to reach review state
      Map<String, dynamic>? cardA;
      Map<String, dynamic>? cardB;
      for (var i = 0; i < 60; i++) {
        final st = await _httpJson(
          http,
          'GET',
          '${server.url}api/state',
          csrfToken: csrf,
        );
        final cards = (st['body']['cards'] as List).cast<Map<dynamic, dynamic>>();
        cardA = cards
            .cast<Map<String, dynamic>>()
            .firstWhere((c) => c['taskId'] == 'task_a');
        cardB = cards
            .cast<Map<String, dynamic>>()
            .firstWhere((c) => c['taskId'] == 'task_b');
        if (cardA['state'] == 'review' && cardB['state'] == 'review') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      expect(cardA!['state'], equals('review'));
      expect(cardB!['state'], equals('review'));

      // Verify c_A change was inherited into task_b workspace
      final wsBRoot = cardB['workspaceRoot'] as String;
      expect(
        File(p.join(wsBRoot, 'lib', 'calc.dart')).readAsStringSync(),
        contains('int calc() => 10;'),
      );

      // 7. Diff check
      final diffRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/diff',
        csrfToken: csrf,
        body: <String, dynamic>{'taskId': 'task_a'},
      );
      expect(diffRes['status'], HttpStatus.ok);
      expect(diffRes['body']['diff'] as String, contains('int calc() => 10;'));
      expect(diffRes['body']['conflictedFiles'], isEmpty);

      // 8. Ring 2 request_permission reject -> then allow_once squash
      wsEvents.clear();
      final rejectSquashFut = _httpJson(
        http,
        'POST',
        '${server.url}api/squash',
        csrfToken: csrf,
        body: <String, dynamic>{'taskId': 'task_a', 'message': 'squash A'},
      );

      Map<String, dynamic>? permReq1;
      for (var i = 0; i < 30; i++) {
        permReq1 = wsEvents
            .where((e) => e['type'] == 'permission_requested')
            .firstOrNull;
        if (permReq1 != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(permReq1, isNotNull);
      final reqId1 = permReq1!['permission']['requestId'] as String;

      final rejectResp = await _httpJson(
        http,
        'POST',
        '${server.url}api/permissions/respond',
        csrfToken: csrf,
        body: <String, dynamic>{
          'requestId': reqId1,
          'optionId': 'reject_once',
        },
      );
      expect(rejectResp['status'], HttpStatus.ok);
      final rejectSquashRes = await rejectSquashFut;
      expect(rejectSquashRes['status'], isNot(HttpStatus.ok));

      // Now approve squash
      wsEvents.clear();
      final approveSquashFut = _httpJson(
        http,
        'POST',
        '${server.url}api/squash',
        csrfToken: csrf,
        body: <String, dynamic>{'taskId': 'task_a', 'message': 'squash A'},
      );

      Map<String, dynamic>? permReq2;
      for (var i = 0; i < 30; i++) {
        permReq2 = wsEvents
            .where((e) => e['type'] == 'permission_requested')
            .firstOrNull;
        if (permReq2 != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(permReq2, isNotNull);
      final reqId2 = permReq2!['permission']['requestId'] as String;

      await _httpJson(
        http,
        'POST',
        '${server.url}api/permissions/respond',
        csrfToken: csrf,
        body: <String, dynamic>{
          'requestId': reqId2,
          'optionId': 'allow_once',
        },
      );
      final approveSquashRes = await approveSquashFut;
      expect(approveSquashRes['status'], HttpStatus.ok);
      expect(approveSquashRes['body']['task']['state'], equals('done'));

      // 9. Parent edit -> child auto-rebase cascade
      final editRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/cards/edit',
        csrfToken: csrf,
        body: <String, dynamic>{
          'taskId': 'task_a',
          'relativePath': 'lib/calc.dart',
          'content': 'int calc() => 42;\n',
        },
      );
      expect(editRes['status'], HttpStatus.ok);
      final cascaded = (editRes['body']['cascadedTasks'] as List);
      expect(cascaded, isNotEmpty);
      expect(
        File(p.join(wsBRoot, 'lib', 'calc.dart')).readAsStringSync(),
        contains('int calc() => 42;'),
      );

      // 10. Chained shutdown -> 0 surviving daemon
      final shutdownRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/shutdown',
        csrfToken: csrf,
        body: <String, dynamic>{},
      );
      expect(shutdownRes['status'], HttpStatus.ok);
      await server.done.timeout(const Duration(seconds: 6));
      final daemonExit =
          await bridge.daemonExitCode.timeout(const Duration(seconds: 6));
      expect(daemonExit, equals(0));
    });

    test('SIGSTOP -> SIGCONT constraint injection and SIGKILL via KanbanServer',
        () async {
      var turnCount = 0;
      String? observedConstraintPrompt;

      mockOllama = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      ollamaBaseUrl = 'http://127.0.0.1:${mockOllama.port}/v1';
      addTearDown(() => mockOllama.close(force: true));

      mockOllama.listen((HttpRequest req) async {
        if (req.uri.path == '/api/chat' && req.method == 'POST') {
          final bodyStr = await utf8.decoder.bind(req).join();
          final reqJson = jsonDecode(bodyStr) as Map<String, dynamic>;
          final messages =
              (reqJson['messages'] as List).cast<Map<dynamic, dynamic>>();
          final allText =
              messages.map((m) => m['content']?.toString() ?? '').join('\n');

          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType =
              ContentType('application', 'x-ndjson', charset: 'utf-8');

          turnCount++;
          if (turnCount == 1) {
            // Delay slightly so test can send SIGSTOP mid-turn.
            await Future<void>.delayed(const Duration(milliseconds: 200));
            req.response.writeln(jsonEncode(<String, dynamic>{
              'model': reqJson['model'],
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'function': <String, dynamic>{
                      'name': 'sys_read_lines',
                      'arguments': <String, dynamic>{
                        'path': '/workspace/lib/calc.dart',
                        'startLine': 1,
                        'endLine': 10,
                      },
                    },
                  },
                ],
              },
              'done': true,
              'prompt_eval_count': 20,
              'eval_count': 10,
            }));
          } else {
            if (allText.contains('CONSTRAINT_WP8_SIGCONT')) {
              observedConstraintPrompt = allText;
            }
            // If turn 3 (kill test), delay briefly so SIGKILL hits mid-turn,
            // while still finishing well within the 5s shutdown timeout.
            if (allText.contains('KILL_ME_CARD')) {
              await Future<void>.delayed(const Duration(milliseconds: 1200));
            }
            req.response.writeln(jsonEncode(<String, dynamic>{
              'model': reqJson['model'],
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': 'Done after signal',
              },
              'done': true,
              'prompt_eval_count': 20,
              'eval_count': 10,
            }));
          }
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      final daemonStderr = <String>[];
      final bridge = await KanbanAcpBridge.spawn(
        executable: Platform.resolvedExecutable,
        arguments: <String>[
          'run',
          daemonScript,
          '--model',
          'local-ollama/gemma4:12b',
          '--ollama-url',
          ollamaBaseUrl,
        ],
        cwd: tempRepo.path,
        permissionPolicy: 'allow_once',
        onDaemonStderr: daemonStderr.add,
      );
      await bridge.connect();

      final server = await KanbanServer.start(
        bridge: bridge,
        port: 0,
        out: StringBuffer(),
        err: StringBuffer(),
      );
      addTearDown(() => server.shutdown());

      final http = HttpClient();
      addTearDown(() => http.close(force: true));

      await _httpJson(
        http,
        'POST',
        '${server.url}api/cards',
        csrfToken: server.csrfToken,
        body: <String, dynamic>{'taskId': 'sig_card', 'title': 'Signal Card'},
      );
      await _httpJson(
        http,
        'POST',
        '${server.url}api/cards/run',
        csrfToken: server.csrfToken,
        body: <String, dynamic>{
          'taskId': 'sig_card',
          'prompt': 'Run signal test',
        },
      );

      // Wait briefly for turn to start, then SIGSTOP
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final stopRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/signal',
        csrfToken: server.csrfToken,
        body: <String, dynamic>{'signal': 'SIGSTOP', 'taskId': 'sig_card'},
      );
      expect(stopRes['status'], HttpStatus.ok);
      expect(stopRes['body']['leadState'], equals('stopped'));

      // Wait for step boundary to settle, then SIGCONT with constraint
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final contRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/signal',
        csrfToken: server.csrfToken,
        body: <String, dynamic>{
          'signal': 'SIGCONT',
          'taskId': 'sig_card',
          'constraintMessage': 'CONSTRAINT_WP8_SIGCONT',
        },
      );
      expect(contRes['status'], HttpStatus.ok);

      for (var i = 0; i < 40; i++) {
        if (observedConstraintPrompt != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(observedConstraintPrompt, contains('CONSTRAINT_WP8_SIGCONT'));

      // Wait for sig_card to finish
      for (var i = 0; i < 40; i++) {
        if (!bridge.hasActiveRun) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      // Now test SIGKILL on a running card
      await _httpJson(
        http,
        'POST',
        '${server.url}api/cards',
        csrfToken: server.csrfToken,
        body: <String, dynamic>{'taskId': 'kill_card', 'title': 'Kill Card'},
      );
      await _httpJson(
        http,
        'POST',
        '${server.url}api/cards/run',
        csrfToken: server.csrfToken,
        body: <String, dynamic>{
          'taskId': 'kill_card',
          'prompt': 'KILL_ME_CARD',
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final killRes = await _httpJson(
        http,
        'POST',
        '${server.url}api/signal',
        csrfToken: server.csrfToken,
        body: <String, dynamic>{'signal': 'SIGKILL', 'taskId': 'kill_card'},
      );
      expect(killRes['status'], HttpStatus.ok);

      await server.shutdown();
      final exitCode =
          await bridge.daemonExitCode.timeout(const Duration(seconds: 6));
      expect(exitCode, equals(0), reason: 'Daemon stderr: ${daemonStderr.join('\n')}');
    });
  });
}
