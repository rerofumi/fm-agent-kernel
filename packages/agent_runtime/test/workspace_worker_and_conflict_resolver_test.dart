import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorkspaceWorker Step 3-1 Integration ([D-306]..[D-308])', () {
    late Directory repoDir;

    ProcessResult runCmdSync(String exe, List<String> args, {String? cwd}) {
      final res = Process.runSync(
        exe,
        args,
        workingDirectory: cwd ?? repoDir.path,
        runInShell: false,
        environment: JjDriver.buildNonInteractiveEnvironment(),
      );
      if (res.exitCode != 0) {
        throw StateError(
          '$exe ${args.join(' ')} failed (${res.exitCode}): ${res.stderr}',
        );
      }
      return res;
    }

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('fm_wp2_ws_worker_');
      runCmdSync('jj', <String>['git', 'init', '--colocate', '.']);
      runCmdSync('jj', <String>['config', 'set', '--repo', 'user.name', 'WP2']);
      runCmdSync(
        'jj',
        <String>['config', 'set', '--repo', 'user.email', 'wp2@example.com'],
      );

      File(p.join(repoDir.path, '.gitignore')).writeAsStringSync(
        '.dart_tool/\n.agent_os/\n',
      );
      File(p.join(repoDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: wp2_workspace_root
publish_to: none
environment:
  sdk: ^3.10.0
workspace:
  - packages/pkg_a
  - packages/pkg_b
''');

      final pkgALib = Directory(p.join(repoDir.path, 'packages', 'pkg_a', 'lib'))
        ..createSync(recursive: true);
      File(p.join(repoDir.path, 'packages', 'pkg_a', 'pubspec.yaml'))
          .writeAsStringSync('''
name: pkg_a
publish_to: none
environment:
  sdk: ^3.10.0
resolution: workspace
''');
      File(p.join(pkgALib.path, 'pkg_a.dart')).writeAsStringSync('''
String baseGreeting() => 'hello';
''');

      final pkgBLib = Directory(p.join(repoDir.path, 'packages', 'pkg_b', 'lib'))
        ..createSync(recursive: true);
      final pkgBTest =
          Directory(p.join(repoDir.path, 'packages', 'pkg_b', 'test'))
            ..createSync(recursive: true);
      File(p.join(repoDir.path, 'packages', 'pkg_b', 'pubspec.yaml'))
          .writeAsStringSync('''
name: pkg_b
publish_to: none
environment:
  sdk: ^3.10.0
resolution: workspace
dependencies:
  pkg_a: any
dev_dependencies:
  test: any
''');
      File(p.join(pkgBLib.path, 'pkg_b.dart')).writeAsStringSync('''
import 'package:pkg_a/pkg_a.dart';
String callBase() => baseGreeting();
''');
      File(p.join(pkgBTest.path, 'pkg_b_test.dart')).writeAsStringSync('''
import 'package:pkg_b/pkg_b.dart';
import 'package:test/test.dart';

void main() {
  test('baseGreeting works', () {
    expect(callBase(), 'hello');
  });
}
''');

      // Seed offline pub resolution in base repo, then commit user baseline
      runCmdSync('dart', <String>['pub', 'get', '--offline']);
      runCmdSync('jj', <String>['describe', '-m', 'user baseline']);
      runCmdSync('jj', <String>['new', '-m', 'user wip']);
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        for (var i = 0; i < 3; i++) {
          try {
            repoDir.deleteSync(recursive: true);
            break;
          } on FileSystemException {
            sleep(const Duration(milliseconds: 50));
          }
        }
      }
    });

    test(
      'parallel Isolate WorkspaceWorkers edit Pub Workspaces independently, pass dart analyze/test, attribute jjChangeId, and clean up',
      () async {
        final userAtBefore = (runCmdSync('jj', <String>[
          '--no-pager',
          'log',
          '--no-graph',
          '-r',
          '@',
          '--ignore-working-copy',
          '-T',
          'change_id.short(12)',
        ]).stdout as String)
            .trim();

        var leadStep = 0;
        var w1Step = 0;
        var w2Step = 0;

        const usage = LlmUsageTelemetry(
          promptTokens: 50,
          completionTokens: 20,
          durationMs: 10,
        );

        final fakeLlm = _ScriptedLlmDriver((req) {
          final sys = req.prompt.messages.first.content;
          if (!sys.contains('Ring 3 WorkspaceWorker')) {
            leadStep++;
            if (leadStep == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'sp_1',
                    name: 'sys_spawn',
                    arguments: const <String, dynamic>{
                      'profile': 'workspace_worker',
                      'name': 'w-pkg-a-b',
                      'logicalTaskId': 'task_ab',
                      'taskPrompt': 'Add greetFromWorker1 and test it in pkg_b',
                    },
                  ),
                  LlmToolCallSpec(
                    id: 'sp_2',
                    name: 'sys_spawn',
                    arguments: const <String, dynamic>{
                      'profile': 'workspace_worker',
                      'name': 'w-extra',
                      'logicalTaskId': 'task_extra',
                      'taskPrompt': 'Add extra.dart and run dart analyze',
                    },
                  ),
                ],
                usage: usage,
              );
            }
            if (leadStep == 2) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'wait_1',
                    name: 'sys_wait',
                    arguments: const <String, dynamic>{'timeoutMs': 120000},
                  ),
                ],
                usage: usage,
              );
            }
            return LlmChatResponse(
              content: 'Both WorkspaceWorkers finished.',
              toolCalls: const <LlmToolCallSpec>[],
              usage: usage,
            );
          }

          final userTask = req.prompt.messages
              .firstWhere((m) => m.role == ProjectedRole.user)
              .content;
          if (userTask.contains('greetFromWorker1')) {
            w1Step++;
            if (w1Step == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'w1_write_a',
                    name: 'sys_write_file',
                    arguments: const <String, dynamic>{
                      'path': '/workspace/packages/pkg_a/lib/w1_feature.dart',
                      'createOnly': true,
                      'content': "String greetFromWorker1() => 'w1';\n",
                    },
                  ),
                  LlmToolCallSpec(
                    id: 'w1_write_b',
                    name: 'sys_write_file',
                    arguments: const <String, dynamic>{
                      'path': '/workspace/packages/pkg_b/test/w1_feature_test.dart',
                      'createOnly': true,
                      'content': '''
import 'package:pkg_a/w1_feature.dart';
import 'package:test/test.dart';

void main() {
  test('greetFromWorker1', () {
    expect(greetFromWorker1(), 'w1');
  });
}
''',
                    },
                  ),
                ],
                usage: usage,
              );
            }
            if (w1Step == 2) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'w1_analyze',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'dart',
                      'args': <String>['analyze'],
                    },
                  ),
                  LlmToolCallSpec(
                    id: 'w1_test',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'dart',
                      'args': <String>['test', 'packages/pkg_b'],
                    },
                  ),
                ],
                usage: usage,
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'w1_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'Added greetFromWorker1 and verified tests',
                  },
                ),
              ],
              usage: usage,
            );
          } else {
            w2Step++;
            if (w2Step == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'w2_write',
                    name: 'sys_write_file',
                    arguments: const <String, dynamic>{
                      'path': '/workspace/packages/pkg_a/lib/extra.dart',
                      'createOnly': true,
                      'content': 'int extraValue() => 42;\n',
                    },
                  ),
                  LlmToolCallSpec(
                    id: 'w2_analyze',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'dart',
                      'args': <String>['analyze'],
                    },
                  ),
                ],
                usage: usage,
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'w2_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'Added extra.dart and ran dart analyze',
                  },
                ),
              ],
              usage: usage,
            );
          }
        });

        var approvalCalls = 0;
        final runtime = KernelBootstrap.create(
          KernelBootstrapConfig(
            workspaceHostRoot: repoDir.path,
            sessionId: 'wp2_parallel_test',
            enableStage2Multiprocess: true,
            startupModel: 'local-ollama/gemma4:12b',
            llmDrivers: <LlmProviderId, LlmDriver>{
              LlmProviderId.localOllama: fakeLlm,
            },
            contextWindowSource: _StaticWindowSource(32768),
            approvalHandler: _CountingApprovalHandler((_) async {
              approvalCalls++;
              return const ApprovalDecision.allowOnce();
            }),
            childWorkerBackend: const IsolateChildWorkerBackend(),
          ),
        );

        try {
          final outcome = await runtime.processRunner.submitPrompt(
            userInput: 'Run two WorkspaceWorkers in parallel.',
          );
          expect(outcome.ok, isTrue, reason: outcome.error?.message);
          expect(approvalCalls, 0);

          // Verify syscalls.jsonl has distinct child jjChangeIds matching sys_spawn/sys_wait
          final syscallsFile = File(runtime.auditLogger.syscallsLogPath);
          final records = LineSplitter.split(syscallsFile.readAsStringSync())
              .where((l) => l.trim().isNotEmpty)
              .map((l) => jsonDecode(l) as Map<String, dynamic>)
              .toList();

          final spawnRecords = records
              .where(
                (r) => r['syscallName'] == 'sys_spawn' && r['ok'] == true,
              )
              .toList();
          expect(spawnRecords.length, 2);

          final spawnedChildChangeIds = <int, String>{};
          for (final sr in spawnRecords) {
            final summary = sr['resultSummary'] as Map<String, dynamic>;
            final childPid = summary['childPid'] as int;
            final changeId = summary['workingChangeId'] as String;
            expect(changeId, isNotEmpty);
            expect(changeId, isNot(equals(userAtBefore)));
            spawnedChildChangeIds[childPid] = changeId;

            // --no-colocate check: no .git/worktrees/ws-<pid>
            expect(
              Directory(
                p.join(repoDir.path, '.git', 'worktrees', 'ws-$childPid'),
              ).existsSync(),
              isFalse,
            );
          }
          expect(spawnedChildChangeIds.values.toSet().length, 2);

          // Child syscalls must carry child's own jjChangeId
          for (final entry in spawnedChildChangeIds.entries) {
            final childPid = entry.key;
            final expectedChangeId = entry.value;
            final childCalls =
                records.where((r) => r['pid'] == childPid).toList();
            expect(childCalls, isNotEmpty);
            for (final call in childCalls) {
              expect(call['jjChangeId'], expectedChangeId);
            }
          }

          // Workspaces cleaned up, no .agent_os/ws/<pid> left
          final wsBaseDir = Directory(p.join(repoDir.path, '.agent_os', 'ws'));
          if (wsBaseDir.existsSync()) {
            expect(wsBaseDir.listSync(), isEmpty);
          }

          final wsList = await runtime.jjDriver.listWorkspaces();
          expect(wsList.ok, isTrue);
          expect(
            wsList.value!.map((e) => e['name']).toList(),
            equals(<String>['default']),
          );

          // Both worker Change IDs remain in jj log
          for (final changeId in spawnedChildChangeIds.values) {
            final logRes = await runtime.jjDriver.log(revset: changeId);
            expect(logRes.ok, isTrue);
            expect((logRes.value!['commits'] as List).length, 1);
          }

          // User's original @- untouched
          final mainDiff = await runtime.jjDriver.diff(
            rev: userAtBefore,
            forceIgnoreWorkingCopy: true,
          );
          expect(mainDiff.ok, isTrue);
          expect((mainDiff.value!['diff'] as String).trim(), isEmpty);

          // jj op log strictly linear (parent count == 1 for all ops except initial root 0)
          final opLogOut = runCmdSync('jj', <String>[
            '--no-pager',
            'op',
            'log',
            '--no-graph',
            '-T',
            r'json(self.parents().len()) ++ "\n"',
          ]).stdout as String;
          final parentCounts = LineSplitter.split(opLogOut)
              .where((l) => l.trim().isNotEmpty)
              .map((l) => int.parse(l.trim()))
              .toList();
          expect(parentCounts.last, 0);
          for (var i = 0; i < parentCounts.length - 1; i++) {
            expect(parentCounts[i], 1);
          }
        } finally {
          await runtime.dispose();
        }
      },
    );

    test(
      'WorkspaceWorker blocks path escapes (EACCES) and Ring 3 approval-requiring ops (EPERM, ApprovalHandler 0 calls)',
      () async {
        var leadStep = 0;
        var workerStep = 0;
        final observedErrors = <String, String>{};
        const usage = LlmUsageTelemetry(
          promptTokens: 30,
          completionTokens: 15,
          durationMs: 5,
        );

        final fakeLlm = _ScriptedLlmDriver((req) {
          final sys = req.prompt.messages.first.content;
          if (!sys.contains('Ring 3 WorkspaceWorker')) {
            leadStep++;
            if (leadStep == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'sp_sec',
                    name: 'sys_spawn',
                    arguments: const <String, dynamic>{
                      'profile': 'workspace_worker',
                      'name': 'w-sec',
                      'taskPrompt': 'Test security boundaries',
                    },
                  ),
                ],
                usage: usage,
              );
            }
            if (leadStep == 2) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'wait_sec',
                    name: 'sys_wait',
                    arguments: const <String, dynamic>{'timeoutMs': 60000},
                  ),
                ],
                usage: usage,
              );
            }
            return LlmChatResponse(
              content: 'Security test done.',
              toolCalls: const <LlmToolCallSpec>[],
              usage: usage,
            );
          }

          workerStep++;
          if (workerStep == 1) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'esc_read',
                  name: 'sys_read_lines',
                  arguments: const <String, dynamic>{
                    'path': '/workspace/../../outside.txt',
                  },
                ),
                LlmToolCallSpec(
                  id: 'tty_pub',
                  name: 'sys_exec',
                  arguments: const <String, dynamic>{
                    'command': 'dart',
                    'args': <String>['pub', 'get'],
                  },
                ),
                LlmToolCallSpec(
                  id: 'tty_git',
                  name: 'sys_exec',
                  arguments: const <String, dynamic>{
                    'command': 'git',
                    'args': <String>['status'],
                  },
                ),
                LlmToolCallSpec(
                  id: 'tty_squash',
                  name: 'sys_tx_squash',
                  arguments: const <String, dynamic>{},
                ),
              ],
              usage: usage,
            );
          }

          for (final msg in req.prompt.messages) {
            if (msg.role == ProjectedRole.tool && msg.toolCallId != null) {
              observedErrors[msg.toolCallId!] = msg.content;
            }
          }
          return LlmChatResponse(
            content: '',
            toolCalls: <LlmToolCallSpec>[
              LlmToolCallSpec(
                id: 'sec_exit',
                name: 'sys_exit',
                arguments: const <String, dynamic>{
                  'exitCode': 0,
                  'summary': 'Security boundaries verified',
                },
              ),
            ],
            usage: usage,
          );
        });

        var approvalCalls = 0;
        final runtime = KernelBootstrap.create(
          KernelBootstrapConfig(
            workspaceHostRoot: repoDir.path,
            sessionId: 'wp2_sec_test',
            enableStage2Multiprocess: true,
            startupModel: 'local-ollama/gemma4:12b',
            llmDrivers: <LlmProviderId, LlmDriver>{
              LlmProviderId.localOllama: fakeLlm,
            },
            contextWindowSource: _StaticWindowSource(32768),
            approvalHandler: _CountingApprovalHandler((_) async {
              approvalCalls++;
              return const ApprovalDecision.allowOnce();
            }),
            childWorkerBackend: const IsolateChildWorkerBackend(),
          ),
        );

        try {
          final outcome = await runtime.processRunner.submitPrompt(
            userInput: 'Check boundaries',
          );
          expect(outcome.ok, isTrue, reason: outcome.error?.message);
          expect(approvalCalls, 0);

          final syscallsFile = File(runtime.auditLogger.syscallsLogPath);
          final records = LineSplitter.split(syscallsFile.readAsStringSync())
              .where((l) => l.trim().isNotEmpty)
              .map((l) => jsonDecode(l) as Map<String, dynamic>)
              .toList();
          final childErrs = records
              .where((r) => (r['pid'] as int) > 1 && r['ok'] == false)
              .toList();
          expect(
            childErrs.any((r) =>
                r['syscallName'] == 'sys_read_lines' &&
                r['errorCode'] == 'EACCES'),
            isTrue,
            reason: 'childErrs=$childErrs, observedErrors=$observedErrors',
          );
          expect(
            childErrs
                .where((r) =>
                    r['syscallName'] == 'sys_exec' && r['errorCode'] == 'EPERM')
                .length,
            2,
            reason: 'childErrs=$childErrs',
          );
          expect(
            childErrs.any((r) =>
                r['syscallName'] == 'sys_tx_squash' &&
                r['errorCode'] == 'EPERM'),
            isTrue,
            reason: 'childErrs=$childErrs',
          );
        } finally {
          await runtime.dispose();
        }
      },
    );

    test(
      'Path A: LeadAgent merges conflicting WorkspaceWorkers with sys_jj_merge, resolves directly, passes dart test, integrates, and squashes',
      () async {
        var leadStep = 0;
        var w1Step = 0;
        var w2Step = 0;
        final workerChangeIds = <String>[];
        String? conflictedFileContent;

        const usage = LlmUsageTelemetry(
          promptTokens: 50,
          completionTokens: 20,
          durationMs: 10,
        );

        final fakeLlm = _ScriptedLlmDriver((req) {
          final sys = req.prompt.messages.first.content;
          if (sys.contains('Ring 3 WorkspaceWorker')) {
            final lastUser = req.prompt.messages.firstWhere(
              (m) => m.role.name == 'user',
            );
            final isWorker1 = lastUser.content.contains('WORKER_1');
            if (isWorker1) {
              w1Step++;
              if (w1Step == 1) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'w1_r',
                      name: 'sys_read_lines',
                      arguments: const <String, dynamic>{
                        'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                        'startLine': 1,
                        'endLine': 10,
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
              if (w1Step == 2) {
                final toolJson = jsonDecode(req.prompt.messages.last.content)
                    as Map<String, dynamic>;
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'w1_e',
                      name: 'sys_edit_block',
                      arguments: <String, dynamic>{
                        'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                        'expectedSha256': toolJson['sha256'],
                        'oldBlock': "String baseGreeting() => 'hello';",
                        'newBlock': "String baseGreeting() => 'hello-A';",
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'w1_x',
                    name: 'sys_exit',
                    arguments: const <String, dynamic>{
                      'exitCode': 0,
                      'summary': 'Worker 1 updated baseGreeting to hello-A',
                    },
                  ),
                ],
                usage: usage,
              );
            } else {
              w2Step++;
              if (w2Step == 1) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'w2_r',
                      name: 'sys_read_lines',
                      arguments: const <String, dynamic>{
                        'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                        'startLine': 1,
                        'endLine': 10,
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
              if (w2Step == 2) {
                final toolJson = jsonDecode(req.prompt.messages.last.content)
                    as Map<String, dynamic>;
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'w2_e',
                      name: 'sys_edit_block',
                      arguments: <String, dynamic>{
                        'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                        'expectedSha256': toolJson['sha256'],
                        'oldBlock': "String baseGreeting() => 'hello';",
                        'newBlock': "String baseGreeting() => 'hello-B';",
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'w2_x',
                    name: 'sys_exit',
                    arguments: const <String, dynamic>{
                      'exitCode': 0,
                      'summary': 'Worker 2 updated baseGreeting to hello-B',
                    },
                  ),
                ],
                usage: usage,
              );
            }
          }

          // LeadAgent (pid=1)
          leadStep++;
          if (leadStep == 1) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'sp1',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'workspace_worker',
                    'name': 'w1',
                    'taskPrompt': 'WORKER_1 edit pkg_a',
                  },
                ),
                LlmToolCallSpec(
                  id: 'sp2',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'workspace_worker',
                    'name': 'w2',
                    'taskPrompt': 'WORKER_2 edit pkg_a',
                  },
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 2) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'wt',
                  name: 'sys_wait',
                  arguments: const <String, dynamic>{},
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 3) {
            final waitJson = jsonDecode(req.prompt.messages.last.content)
                as Map<String, dynamic>;
            for (final c in waitJson['children'] as List<dynamic>) {
              workerChangeIds.add((c as Map)['workingChangeId'] as String);
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'mg',
                  name: 'sys_jj_merge',
                  arguments: <String, dynamic>{
                    'changeIds': workerChangeIds,
                    'message': 'merge conflicting workers',
                  },
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 4) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'cf1',
                  name: 'sys_jj_conflicts',
                  arguments: const <String, dynamic>{},
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 5) {
            final confJson = jsonDecode(
              req.prompt.messages
                  .lastWhere((m) => m.role.name == 'tool')
                  .content,
            ) as Map<String, dynamic>;
            final filePath = (confJson['files'] as List).first as String;
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'rd',
                  name: 'sys_read_lines',
                  arguments: <String, dynamic>{
                    'path': filePath,
                    'startLine': 1,
                    'endLine': 50,
                  },
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 6) {
            final readJson = jsonDecode(
              req.prompt.messages
                  .lastWhere((m) => m.role.name == 'tool')
                  .content,
            ) as Map<String, dynamic>;
            conflictedFileContent = readJson['content'] as String;
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'ed',
                  name: 'sys_edit_block',
                  arguments: <String, dynamic>{
                    'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                    'expectedSha256': readJson['sha256'],
                    'oldBlock': conflictedFileContent,
                    'newBlock': "String baseGreeting() => 'hello'; // A+B\n",
                  },
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 7) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'cf2',
                  name: 'sys_jj_conflicts',
                  arguments: const <String, dynamic>{},
                ),
                LlmToolCallSpec(
                  id: 'tst',
                  name: 'sys_exec',
                  arguments: const <String, dynamic>{
                    'command': 'dart',
                    'args': <String>['test', 'packages/pkg_b'],
                  },
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 8) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'int1',
                  name: 'sys_jj_integrate',
                  arguments: const <String, dynamic>{},
                ),
                LlmToolCallSpec(
                  id: 'sq1',
                  name: 'sys_tx_squash',
                  arguments: const <String, dynamic>{
                    'message': 'resolved path A',
                  },
                ),
              ],
              usage: usage,
            );
          }
          return LlmChatResponse(
            content: 'Path A resolved and squashed.',
            usage: usage,
          );
        });

        final runtime = KernelBootstrap.create(
          KernelBootstrapConfig(
            workspaceHostRoot: repoDir.path,
            sessionId: 'sess_step32_path_a',
            enableStage2Multiprocess: true,
            startupModel: 'local-ollama/gemma4:12b',
            llmDrivers: <LlmProviderId, LlmDriver>{
              LlmProviderId.localOllama: fakeLlm,
            },
            contextWindowSource: _StaticWindowSource(16384),
            approvalHandler: _CountingApprovalHandler(
              (_) async => const ApprovalDecision.allowOnce(),
            ),
            childWorkerBackend: const IsolateChildWorkerBackend(),
          ),
        );

        try {
          final outcome = await runtime.processRunner.submitPrompt(
            userInput: 'Merge two conflicting workers and resolve directly',
          );
          expect(outcome.ok, isTrue, reason: outcome.error?.message);
          expect(conflictedFileContent, contains('<<<<<<<'));
          expect(conflictedFileContent, contains('>>>>>>>'));
          expect(
            File(p.join(repoDir.path, 'packages', 'pkg_a', 'lib', 'pkg_a.dart'))
                .readAsStringSync(),
            contains('// A+B'),
          );
        } finally {
          await runtime.dispose();
        }
      },
    );

    test(
      'Path B: LeadAgent delegates conflict resolution to ConflictResolver child Isolate on <M>, then integrates and squashes',
      () async {
        var leadStep = 0;
        var w1Step = 0;
        var w2Step = 0;
        var crStep = 0;
        final workerChangeIds = <String>[];
        String? mergeChangeId;
        String? resolverChangeId;
        List<String>? resolverToolNames;
        String? resolverMarkers;
        String? crLastMsg;

        const usage = LlmUsageTelemetry(
          promptTokens: 50,
          completionTokens: 20,
          durationMs: 10,
        );

        final fakeLlm = _ScriptedLlmDriver((req) {
          final sys = req.prompt.messages.first.content;
          if (sys.contains('Ring 3 ConflictResolver')) {
            resolverToolNames = req.prompt.tools.map((t) => t.name).toList();
            crStep++;
            if (crStep == 1) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'cr_cf1',
                    name: 'sys_jj_conflicts',
                    arguments: const <String, dynamic>{},
                  ),
                ],
                usage: usage,
              );
            }
            if (crStep == 2) {
              crLastMsg = req.prompt.messages
                  .lastWhere((m) => m.role.name == 'tool')
                  .content;
              final confJson = jsonDecode(crLastMsg!)
                  as Map<String, dynamic>;
              final filePath = (confJson['files'] as List).first as String;
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'cr_rd',
                    name: 'sys_read_lines',
                    arguments: <String, dynamic>{
                      'path': filePath,
                      'startLine': 1,
                      'endLine': 50,
                    },
                  ),
                ],
                usage: usage,
              );
            }
            if (crStep == 3) {
              final readJson = jsonDecode(
                req.prompt.messages
                    .lastWhere((m) => m.role.name == 'tool')
                    .content,
              ) as Map<String, dynamic>;
              resolverMarkers = readJson['content'] as String;
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'cr_ed',
                    name: 'sys_edit_block',
                    arguments: <String, dynamic>{
                      'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                      'expectedSha256': readJson['sha256'],
                      'oldBlock': resolverMarkers,
                      'newBlock': "String baseGreeting() => 'hello'; // CR-resolved\n",
                    },
                  ),
                ],
                usage: usage,
              );
            }
            if (crStep == 4) {
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'cr_cf2',
                    name: 'sys_jj_conflicts',
                    arguments: const <String, dynamic>{},
                  ),
                  LlmToolCallSpec(
                    id: 'cr_tst',
                    name: 'sys_exec',
                    arguments: const <String, dynamic>{
                      'command': 'dart',
                      'args': <String>['test', 'packages/pkg_b'],
                    },
                  ),
                ],
                usage: usage,
              );
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'cr_exit',
                  name: 'sys_exit',
                  arguments: const <String, dynamic>{
                    'exitCode': 0,
                    'summary': 'ConflictResolver resolved pkg_a.dart and passed tests',
                  },
                ),
              ],
              usage: usage,
            );
          }

          if (sys.contains('Ring 3 WorkspaceWorker')) {
            final lastUser = req.prompt.messages.firstWhere(
              (m) => m.role.name == 'user',
            );
            final isWorker1 = lastUser.content.contains('WORKER_1');
            if (isWorker1) {
              w1Step++;
              if (w1Step == 1) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'w1_r',
                      name: 'sys_read_lines',
                      arguments: const <String, dynamic>{
                        'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                        'startLine': 1,
                        'endLine': 10,
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
              if (w1Step == 2) {
                final toolJson = jsonDecode(req.prompt.messages.last.content)
                    as Map<String, dynamic>;
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'w1_e',
                      name: 'sys_edit_block',
                      arguments: <String, dynamic>{
                        'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                        'expectedSha256': toolJson['sha256'],
                        'oldBlock': "String baseGreeting() => 'hello';",
                        'newBlock': "String baseGreeting() => 'hello-1';",
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'w1_x',
                    name: 'sys_exit',
                    arguments: const <String, dynamic>{
                      'exitCode': 0,
                      'summary': 'W1 done',
                    },
                  ),
                ],
                usage: usage,
              );
            } else {
              w2Step++;
              if (w2Step == 1) {
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'w2_r',
                      name: 'sys_read_lines',
                      arguments: const <String, dynamic>{
                        'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                        'startLine': 1,
                        'endLine': 10,
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
              if (w2Step == 2) {
                final toolJson = jsonDecode(req.prompt.messages.last.content)
                    as Map<String, dynamic>;
                return LlmChatResponse(
                  content: '',
                  toolCalls: <LlmToolCallSpec>[
                    LlmToolCallSpec(
                      id: 'w2_e',
                      name: 'sys_edit_block',
                      arguments: <String, dynamic>{
                        'path': '/workspace/packages/pkg_a/lib/pkg_a.dart',
                        'expectedSha256': toolJson['sha256'],
                        'oldBlock': "String baseGreeting() => 'hello';",
                        'newBlock': "String baseGreeting() => 'hello-2';",
                      },
                    ),
                  ],
                  usage: usage,
                );
              }
              return LlmChatResponse(
                content: '',
                toolCalls: <LlmToolCallSpec>[
                  LlmToolCallSpec(
                    id: 'w2_x',
                    name: 'sys_exit',
                    arguments: const <String, dynamic>{
                      'exitCode': 0,
                      'summary': 'W2 done',
                    },
                  ),
                ],
                usage: usage,
              );
            }
          }

          // LeadAgent (pid=1)
          leadStep++;
          if (leadStep == 1) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'sp1',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'workspace_worker',
                    'name': 'w1',
                    'taskPrompt': 'WORKER_1',
                  },
                ),
                LlmToolCallSpec(
                  id: 'sp2',
                  name: 'sys_spawn',
                  arguments: const <String, dynamic>{
                    'profile': 'workspace_worker',
                    'name': 'w2',
                    'taskPrompt': 'WORKER_2',
                  },
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 2) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'wt1',
                  name: 'sys_wait',
                  arguments: const <String, dynamic>{},
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 3) {
            final waitJson = jsonDecode(req.prompt.messages.last.content)
                as Map<String, dynamic>;
            for (final c in waitJson['children'] as List<dynamic>) {
              workerChangeIds.add((c as Map)['workingChangeId'] as String);
            }
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'mg1',
                  name: 'sys_jj_merge',
                  arguments: <String, dynamic>{
                    'changeIds': workerChangeIds,
                  },
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 4) {
            final mergeJson = jsonDecode(req.prompt.messages.last.content)
                as Map<String, dynamic>;
            mergeChangeId = mergeJson['mergeChangeId'] as String;
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'sp_cr',
                  name: 'sys_spawn',
                  arguments: <String, dynamic>{
                    'profile': 'conflict_resolver',
                    'name': 'resolver',
                    'baseChangeId': mergeChangeId,
                    'taskPrompt': 'Resolve conflicts on $mergeChangeId',
                  },
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 5) {
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'wt_cr',
                  name: 'sys_wait',
                  arguments: const <String, dynamic>{},
                ),
              ],
              usage: usage,
            );
          }
          if (leadStep == 6) {
            final waitJson = jsonDecode(req.prompt.messages.last.content)
                as Map<String, dynamic>;
            final crChild = (waitJson['children'] as List).first as Map;
            resolverChangeId = crChild['workingChangeId'] as String;
            return LlmChatResponse(
              content: '',
              toolCalls: <LlmToolCallSpec>[
                LlmToolCallSpec(
                  id: 'int_cr',
                  name: 'sys_jj_integrate',
                  arguments: <String, dynamic>{
                    'sourceRev': resolverChangeId,
                    'abandonChangeIds': <String>[
                      ...workerChangeIds,
                      mergeChangeId!,
                      resolverChangeId!,
                    ],
                  },
                ),
                LlmToolCallSpec(
                  id: 'sq_cr',
                  name: 'sys_tx_squash',
                  arguments: const <String, dynamic>{
                    'message': 'resolved via ConflictResolver',
                  },
                ),
              ],
              usage: usage,
            );
          }
          return LlmChatResponse(
            content: 'Path B ConflictResolver completed and squashed.',
            usage: usage,
          );
        });

        final runtime = KernelBootstrap.create(
          KernelBootstrapConfig(
            workspaceHostRoot: repoDir.path,
            sessionId: 'sess_step32_path_b',
            enableStage2Multiprocess: true,
            startupModel: 'local-ollama/gemma4:12b',
            llmDrivers: <LlmProviderId, LlmDriver>{
              LlmProviderId.localOllama: fakeLlm,
            },
            contextWindowSource: _StaticWindowSource(16384),
            approvalHandler: _CountingApprovalHandler(
              (_) async => const ApprovalDecision.allowOnce(),
            ),
            childWorkerBackend: const IsolateChildWorkerBackend(),
          ),
        );

        try {
          final outcome = await runtime.processRunner.submitPrompt(
            userInput:
                'Merge two conflicting workers and delegate to ConflictResolver',
          );
          expect(outcome.ok, isTrue, reason: outcome.error?.message);
          expect(
            resolverMarkers,
            contains('<<<<<<<'),
            reason:
                'crStep=$crStep, crLastMsg=$crLastMsg, mergeChangeId=$mergeChangeId, resolverChangeId=$resolverChangeId, resolverToolNames=$resolverToolNames',
          );
          expect(resolverMarkers, contains('>>>>>>>'));
          expect(resolverToolNames, contains('sys_jj_conflicts'));
          expect(resolverToolNames, isNot(contains('sys_jj_merge')));
          expect(resolverToolNames, isNot(contains('sys_jj_integrate')));
          expect(resolverToolNames, isNot(contains('sys_tx_squash')));
          expect(
            File(p.join(repoDir.path, 'packages', 'pkg_a', 'lib', 'pkg_a.dart'))
                .readAsStringSync(),
            contains('// CR-resolved'),
          );

          // Verify syscalls.jsonl records resultSummary and ConflictResolver's own jjChangeId
          final auditPath = p.join(
            repoDir.path,
            '.agent_os',
            'logs',
            'sess_step32_path_b',
            'syscalls.jsonl',
          );
          final records = File(auditPath)
              .readAsLinesSync()
              .where((l) => l.trim().isNotEmpty)
              .map((l) => jsonDecode(l) as Map<String, dynamic>)
              .toList();
          final mergeAudit =
              records.firstWhere((r) => r['syscallName'] == 'sys_jj_merge');
          expect(mergeAudit['resultSummary']?['hasConflicts'], isTrue);
          final crAudits = records
              .where((r) =>
                  r['jjChangeId'] == resolverChangeId &&
                  r['syscallName'] == 'sys_jj_conflicts')
              .toList();
          expect(crAudits.length, 2);
          expect(crAudits.last['resultSummary']?['hasConflicts'], isFalse);
        } finally {
          await runtime.dispose();
        }
      },
    );
  });
}

class _StaticWindowSource implements ContextWindowSource {
  _StaticWindowSource(this.windowTokens);
  final int windowTokens;

  @override
  Future<ContextWindowSpec> resolve(
    ModelIdentifier model, {
    bool forceRefreshPs = false,
  }) async {
    return ContextWindowSpec(
      contextWindowTokens: windowTokens,
      source: 'test_static',
      isLoadedExact: true,
    );
  }
}

class _CountingApprovalHandler implements ApprovalHandler {
  _CountingApprovalHandler(this._handler);
  final Future<ApprovalDecision> Function(ApprovalRequest req) _handler;

  @override
  Future<ApprovalDecision> requestApproval(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) =>
      _handler(request);
}

class _ScriptedLlmDriver implements LlmDriver {
  _ScriptedLlmDriver(this._onRequest);

  final LlmChatResponse Function(LlmChatRequest request) _onRequest;

  @override
  LlmProviderId get providerId => LlmProviderId.localOllama;

  @override
  Stream<LlmStreamEvent> chatStream(
    LlmChatRequest request, {
    CancellationToken? cancelToken,
  }) async* {
    final resp = _onRequest(request);
    if (resp.content.isNotEmpty) {
      yield LlmTextDelta(resp.content);
    }
    for (final tc in resp.toolCalls) {
      yield LlmToolCallEvent(tc);
    }
    yield LlmDoneEvent(resp);
  }
}
