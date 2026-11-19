import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WP-7 Step 1-2 Integration Gate [D-002], [D-006], [D-016], [D-017], [D-022]',
      () {
    late Directory repoDir;

    ProcessResult runJjSync(List<String> args) {
      return Process.runSync(
        'jj',
        <String>['--no-pager', ...args],
        workingDirectory: repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
      );
    }

    String readHeadOpId() {
      final res = runJjSync(<String>[
        'op',
        'log',
        '--no-graph',
        '--limit',
        '1',
        '--ignore-working-copy',
        '-T',
        'self.id()',
      ]);
      expect(res.exitCode, equals(0), reason: 'jj op log failed: ${res.stderr}');
      return (res.stdout as String).trim();
    }

    String readCommitId(String rev) {
      final res = runJjSync(<String>[
        'log',
        '--no-graph',
        '-r',
        rev,
        '--ignore-working-copy',
        '-T',
        'commit_id',
      ]);
      expect(res.exitCode, equals(0), reason: 'jj log failed: ${res.stderr}');
      return (res.stdout as String).trim();
    }

    List<int> readFileBytesAtRev(String rev, String relPath) {
      final res = Process.runSync(
        'jj',
        <String>[
          '--no-pager',
          'file',
          'show',
          '-r',
          rev,
          '--ignore-working-copy',
          relPath,
        ],
        workingDirectory: repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
        stdoutEncoding: null,
      );
      expect(
        res.exitCode,
        equals(0),
        reason: 'jj file show $rev:$relPath failed: ${res.stderr}',
      );
      return res.stdout as List<int>;
    }

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('fm_wp7_it_');
      final initRes = runJjSync(<String>['git', 'init', '--colocate']);
      expect(initRes.exitCode, equals(0), reason: '${initRes.stderr}');
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP7 Tester']);
      runJjSync(
          <String>['config', 'set', '--repo', 'user.email', 'wp7@example.com']);

      Directory(p.join(repoDir.path, 'lib')).createSync(recursive: true);
      File(p.join(repoDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: wp7_sample
version: 0.1.0
environment:
  sdk: ^3.10.0
''');
      File(p.join(repoDir.path, 'lib', 'calc.dart')).writeAsStringSync(
        'int add(int a, int b) => a + b;\n',
      );
      expect(
        runJjSync(<String>['describe', '-m', 'base commit']).exitCode,
        equals(0),
      );
      expect(
        runJjSync(<String>['new', '-m', 'human wip']).exitCode,
        equals(0),
      );

      // Snapshotted human WIP + unsnapshotted human edit.
      File(p.join(repoDir.path, 'human_notes.txt'))
          .writeAsStringSync('human snapshotted note\n');
      expect(runJjSync(<String>['status']).exitCode, equals(0));
      File(p.join(repoDir.path, 'human_notes.txt'))
          .writeAsStringSync('human unsnapshotted wip edit\n');
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test(
        'KernelBootstrap registers all 13 Step 1-1/1-2 tool schemas sorted by name and wires AntiGitHabitGuardHook',
        () {
      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(workspaceHostRoot: repoDir.path),
      );
      addTearDown(bootstrap.dispose);

      final toolNames = bootstrap.pcb.memory.systemSegment.pinned.tools
          .map((t) => t.name)
          .toList();
      final expectedSorted = <String>[
        'sys_edit_block',
        'sys_exec',
        'sys_glob',
        'sys_grep',
        'sys_jj_diff',
        'sys_jj_log',
        'sys_jj_status',
        'sys_mem_pagein',
        'sys_read_lines',
        'sys_tx_begin',
        'sys_tx_describe',
        'sys_tx_rollback',
        'sys_tx_squash',
        'sys_write_file',
      ];
      expect(toolNames, equals(expectedSorted));
    });

    test(
        'Event 1-2-1: separates @ for agent CAS edits + allowlisted dart analyze without dirtying @- bytes',
        () async {
      final expectedHumanBytes =
          File(p.join(repoDir.path, 'human_notes.txt')).readAsBytesSync();
      final calcInitialBytes =
          File(p.join(repoDir.path, 'lib', 'calc.dart')).readAsBytesSync();
      final calcReadRes = await HostFsDriver.forWorkspace(repoDir.path)
          .readLines(path: '/workspace/lib/calc.dart');
      expect(calcReadRes.ok, isTrue);
      final calcSha = calcReadRes.value!['sha256'] as String;
      final approvalSpy = PolicyApprovalHandler.alwaysReject();

      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => localServer.close(force: true));

      var step = 0;
      localServer.listen((req) async {
        if (req.uri.path != '/api/chat') {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        await utf8.decoder.bind(req).drain<void>();
        step += 1;

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (step == 1) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'c1',
                        'function': <String, dynamic>{
                          'name': 'sys_read_lines',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/lib/calc.dart',
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 400,
                  'eval_count': 20,
                })}\n',
          );
        } else if (step == 2) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'c2',
                        'function': <String, dynamic>{
                          'name': 'sys_edit_block',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/lib/calc.dart',
                            'expectedSha256': calcSha,
                            'oldBlock': 'int add(int a, int b) => a + b;',
                            'newBlock':
                                'int add(int a, int b) => a + b;\nint mul(int a, int b) => a * b;',
                          },
                        },
                      },
                      <String, dynamic>{
                        'id': 'c3',
                        'function': <String, dynamic>{
                          'name': 'sys_exec',
                          'arguments': <String, dynamic>{
                            'command': 'dart analyze',
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 600,
                  'eval_count': 30,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': 'Added mul() in isolated @ and dart analyze passed.',
                  },
                  'done': true,
                  'prompt_eval_count': 800,
                  'eval_count': 15,
                })}\n',
          );
        }
        await req.response.close();
      });

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          sessionId: 'wp7_e121',
          startupModel: 'local-ollama/gemma4:12b',
          approvalHandler: approvalSpy,
          localOllamaBaseUrl: 'http://127.0.0.1:${localServer.port}',
        ),
      );
      addTearDown(bootstrap.dispose);

      final res = await bootstrap.processRunner.submitPrompt(
        userInput: 'Add mul() to lib/calc.dart and run dart analyze.',
      );

      expect(res.ok, isTrue, reason: '${res.error}');
      expect(res.toolCallsExecuted, equals(3));
      // All syscalls (read, edit_block, dart analyze) ran with 0 user approval prompts!
      expect(approvalSpy.recordedRequests, isEmpty);
      expect(bootstrap.pcb.jjContext.state, equals(TxState.active));

      // @- must hold exact human unsnapshotted bytes untouched (0 bytes modified).
      expect(
        readFileBytesAtRev('@-', 'human_notes.txt'),
        equals(expectedHumanBytes),
      );
      expect(
        readFileBytesAtRev('@-', 'lib/calc.dart'),
        equals(calcInitialBytes),
      );
      expect(
        utf8.decode(readFileBytesAtRev('@', 'lib/calc.dart')),
        contains('int mul(int a, int b)'),
      );
      expect(
        readCommitId('@'),
        isNot(equals(readCommitId('@-'))),
      );
    });

    test(
        'Event 1-2-2: multi-file edits + failed sys_exec followed by 1-shot sys_tx_rollback restores exact pre-task bytes and keeps logs',
        () async {
      final beforeHuman =
          File(p.join(repoDir.path, 'human_notes.txt')).readAsBytesSync();
      final beforeCalc =
          File(p.join(repoDir.path, 'lib', 'calc.dart')).readAsBytesSync();
      final beforeCalcRead = await HostFsDriver.forWorkspace(repoDir.path)
          .readLines(path: '/workspace/lib/calc.dart');
      expect(beforeCalcRead.ok, isTrue);
      final beforeCalcSha = beforeCalcRead.value!['sha256'] as String;
      final opBefore = readHeadOpId();

      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => localServer.close(force: true));

      var step = 0;
      localServer.listen((req) async {
        if (req.uri.path != '/api/chat') {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        await utf8.decoder.bind(req).drain<void>();
        step += 1;
        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (step == 1) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'e1',
                        'function': <String, dynamic>{
                          'name': 'sys_edit_block',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/lib/calc.dart',
                            'expectedSha256': beforeCalcSha,
                            'oldBlock': 'int add(int a, int b) => a + b;',
                            'newBlock': 'broken syntax !!!',
                          },
                        },
                      },
                      <String, dynamic>{
                        'id': 'e2',
                        'function': <String, dynamic>{
                          'name': 'sys_write_file',
                          'arguments': <String, dynamic>{
                            'path': '/workspace/lib/extra.dart',
                            'content': 'int extra() => 42;\n',
                            'createOnly': true,
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 400,
                  'eval_count': 30,
                })}\n',
          );
        } else if (step == 2) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'e3',
                        'function': <String, dynamic>{
                          'name': 'sys_exec',
                          'arguments': <String, dynamic>{
                            'command': 'dart analyze',
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 600,
                  'eval_count': 20,
                })}\n',
          );
        } else if (step == 3) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'e4',
                        'function': <String, dynamic>{
                          'name': 'sys_tx_rollback',
                          'arguments': <String, dynamic>{},
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 700,
                  'eval_count': 15,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content':
                        'dart analyze failed; rolled back all changes cleanly.',
                  },
                  'done': true,
                  'prompt_eval_count': 800,
                  'eval_count': 12,
                })}\n',
          );
        }
        await req.response.close();
      });

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          sessionId: 'wp7_e122',
          startupModel: 'local-ollama/gemma4:12b',
          localOllamaBaseUrl: 'http://127.0.0.1:${localServer.port}',
        ),
      );
      addTearDown(bootstrap.dispose);

      final res = await bootstrap.processRunner.submitPrompt(
        userInput: 'Modify calc.dart, add extra.dart, verify, and rollback if broken.',
      );

      expect(res.ok, isTrue, reason: '${res.error}');
      expect(bootstrap.pcb.jjContext.state, equals(TxState.readOnly));

      // Verify exact byte-for-byte restoration and removal of newly created file.
      expect(
        File(p.join(repoDir.path, 'human_notes.txt')).readAsBytesSync(),
        equals(beforeHuman),
      );
      expect(
        File(p.join(repoDir.path, 'lib', 'calc.dart')).readAsBytesSync(),
        equals(beforeCalc),
      );
      expect(File(p.join(repoDir.path, 'lib', 'extra.dart')).existsSync(), isFalse);

      // Verify audit logs survive rollback and record sys_tx_rollback.
      await bootstrap.auditLogger.flush();
      expect(File(bootstrap.auditLogger.syscallsLogPath).existsSync(), isTrue);
      final records = const LineSplitter()
          .convert(File(bootstrap.auditLogger.syscallsLogPath).readAsStringSync())
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      final rollbackRec = records.firstWhere(
        (r) => r['syscallName'] == 'sys_tx_rollback',
      );
      expect(rollbackRec['ok'], isTrue);
      expect(readHeadOpId(), isNot(equals(opBefore)));
    });

    test(
        'Event 1-2-3: timed-out grandchild script leaves 0 OS PIDs alive, returns ETIMEDOUT, and agent continues',
        () async {
      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => localServer.close(force: true));
      final k32 = Win32Kernel32();
      final capturedToolOutputs = <String>[];

      const psScript = r'''
$p = Start-Process -FilePath "ping.exe" -ArgumentList "-n","60","127.0.0.1" -WindowStyle Hidden -PassThru
Write-Output ("GRANDCHILD_PID=" + $p.Id)
[Console]::Out.Flush()
Start-Sleep -Seconds 60
''';

      var step = 0;
      localServer.listen((req) async {
        if (req.uri.path != '/api/chat') {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final body = jsonDecode(await utf8.decoder.bind(req).join())
            as Map<String, dynamic>;
        step += 1;

        if (step == 2) {
          final msgs = (body['messages'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          for (final m in msgs) {
            if (m['role'] == 'tool') {
              capturedToolOutputs.add(m['content'] as String);
            }
          }
        }

        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (step == 1) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 't1',
                        'function': <String, dynamic>{
                          'name': 'sys_exec',
                          'arguments': <String, dynamic>{
                            'command': 'powershell.exe',
                            'args': <String>[
                              '-NoProfile',
                              '-NonInteractive',
                              '-Command',
                              psScript,
                            ],
                            'timeoutMs': 1500,
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 400,
                  'eval_count': 20,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content':
                        'Observed ETIMEDOUT after process tree termination and recovered control.',
                  },
                  'done': true,
                  'prompt_eval_count': 600,
                  'eval_count': 15,
                })}\n',
          );
        }
        await req.response.close();
      });

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          sessionId: 'wp7_e123',
          startupModel: 'local-ollama/gemma4:12b',
          approvalHandler: PolicyApprovalHandler.alwaysAllow(),
          localOllamaBaseUrl: 'http://127.0.0.1:${localServer.port}',
        ),
      );
      addTearDown(bootstrap.dispose);

      final res = await bootstrap.processRunner.submitPrompt(
        userInput: 'Run long grandchild script with short timeout.',
      );

      expect(res.ok, isTrue, reason: '${res.error}');
      expect(res.finalText, contains('ETIMEDOUT'));
      expect(capturedToolOutputs, hasLength(1));

      final toolJson =
          jsonDecode(capturedToolOutputs.first) as Map<String, dynamic>;
      expect(toolJson['code'], equals('ETIMEDOUT'));
      final stdoutText = toolJson['details']['stdout'] as String;
      final match = RegExp(r'GRANDCHILD_PID=(\d+)').firstMatch(stdoutText);
      expect(match, isNotNull, reason: 'stdout was: $stdoutText');
      final grandchildPid = int.parse(match!.group(1)!);

      expect(k32.isProcessAlive(grandchildPid), isFalse);
    });

    test(
        'Event 1-2-4: raw git attempt is blocked at Stage 3 (0 approval prompts) and agent switches to sys_jj_status/diff in syscalls.jsonl',
        () async {
      final approvalSpy = PolicyApprovalHandler.alwaysAllow();
      final localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => localServer.close(force: true));

      var step = 0;
      localServer.listen((req) async {
        if (req.uri.path != '/api/chat') {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        await utf8.decoder.bind(req).drain<void>();
        step += 1;
        req.response.statusCode = 200;
        req.response.headers.contentType =
            ContentType('application', 'x-ndjson');

        if (step == 1) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'g1',
                        'function': <String, dynamic>{
                          'name': 'sys_exec',
                          'arguments': <String, dynamic>{
                            'command': 'git status',
                          },
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 400,
                  'eval_count': 15,
                })}\n',
          );
        } else if (step == 2) {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'g2',
                        'function': <String, dynamic>{
                          'name': 'sys_jj_status',
                          'arguments': <String, dynamic>{},
                        },
                      },
                      <String, dynamic>{
                        'id': 'g3',
                        'function': <String, dynamic>{
                          'name': 'sys_jj_diff',
                          'arguments': <String, dynamic>{'rev': '@'},
                        },
                      },
                    ],
                  },
                  'done': true,
                  'prompt_eval_count': 600,
                  'eval_count': 20,
                })}\n',
          );
        } else {
          req.response.write(
            '${jsonEncode(<String, dynamic>{
                  'message': <String, dynamic>{
                    'role': 'assistant',
                    'content':
                        'Switched from blocked git status to sys_jj_status and sys_jj_diff.',
                  },
                  'done': true,
                  'prompt_eval_count': 800,
                  'eval_count': 15,
                })}\n',
          );
        }
        await req.response.close();
      });

      final bootstrap = KernelBootstrap.create(
        KernelBootstrapConfig(
          workspaceHostRoot: repoDir.path,
          sessionId: 'wp7_e124',
          startupModel: 'local-ollama/gemma4:12b',
          approvalHandler: approvalSpy,
          localOllamaBaseUrl: 'http://127.0.0.1:${localServer.port}',
        ),
      );
      addTearDown(bootstrap.dispose);

      final res = await bootstrap.processRunner.submitPrompt(
        userInput: 'Check repository status and diff.',
      );

      expect(res.ok, isTrue, reason: '${res.error}');
      expect(res.toolCallsExecuted, equals(3));
      expect(approvalSpy.recordedRequests, isEmpty);

      await bootstrap.auditLogger.flush();
      final records = const LineSplitter()
          .convert(File(bootstrap.auditLogger.syscallsLogPath).readAsStringSync())
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();

      final blockedIdx = records.indexWhere(
        (r) =>
            r['syscallName'] == 'sys_exec' && r['decision'] == 'HOOK_BLOCKED',
      );
      expect(blockedIdx, greaterThanOrEqualTo(0));
      expect(records[blockedIdx]['approvalRequired'], isFalse);
      expect(records[blockedIdx]['errorCode'], equals('EPERM'));

      final statusIdx = records.indexWhere(
        (r) => r['syscallName'] == 'sys_jj_status' && r['ok'] == true,
      );
      final diffIdx = records.indexWhere(
        (r) => r['syscallName'] == 'sys_jj_diff' && r['ok'] == true,
      );
      expect(statusIdx, greaterThan(blockedIdx));
      expect(diffIdx, greaterThan(blockedIdx));
    });
  });
}
