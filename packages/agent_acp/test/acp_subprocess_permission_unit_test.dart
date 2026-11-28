import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_acp/agent_acp.dart';
import 'package:agent_acp/src/kanban/kanban_acp_bridge.dart';
import 'package:agent_acp/src/kanban/kanban_server.dart';
import 'package:agent_acp/src/kanban/kanban_ui_assets.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _PeerPair {
  _PeerPair()
      : _c2s = StreamController<List<int>>(),
        _s2c = StreamController<List<int>>() {
    serverPeer = JsonRpcPeer(input: _c2s.stream, output: _s2c.sink);
    clientPeer = JsonRpcPeer(input: _s2c.stream, output: _c2s.sink);
  }

  final StreamController<List<int>> _c2s;
  final StreamController<List<int>> _s2c;
  late final JsonRpcPeer serverPeer;
  late final JsonRpcPeer clientPeer;

  Future<void> close() async {
    await serverPeer.close();
    await clientPeer.close();
    await _c2s.close();
    await _s2c.close();
  }
}

/// Lightweight mock ACP daemon script for testing [AcpCliRunner] and [KanbanAcpBridge]
/// subprocess permission flows, ID-matched `_fm_agent_os/permission_cancelled`, and `/cancel`.
const String _mockPermDaemonSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final stateDir = Platform.environment['MOCK_STATE_DIR'] ?? Directory.current.path;
  final logFile = File('$stateDir/daemon_events.jsonl');

  void record(Map<String, dynamic> event) {
    logFile.writeAsStringSync('${jsonEncode(event)}\n', mode: FileMode.append);
  }

  var reqSeq = 0;
  final pendingClientRequests = <String, Completer<Object?>>{};
  var turnCounter = 0;
  Completer<void>? activeCancel;

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

  void sendNotification(String method, Map<String, dynamic> params) {
    sendFrame({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
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
    final params =
        (msg['params'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};

    if (id == null) {
      record({'event': 'notification', 'method': method, 'params': params});
      if (method == 'session/cancel' &&
          activeCancel != null &&
          !activeCancel!.isCompleted) {
        activeCancel!.complete();
      }
      continue;
    }

    Future<void>(() async {
      Object? result;
      switch (method) {
        case 'initialize':
          result = {
            'protocolVersion': 1,
            'agentInfo': {'name': 'mock_perm_daemon', 'version': '0.1.0'},
          };
        case 'session/new':
          result = {
            'sessionId': 'sess_perm_1',
            'configOptions': [
              {
                'id': 'model',
                'currentValue': 'local-ollama/gemma4:12b',
                'options': [
                  {'value': 'local-ollama/gemma4:12b', 'name': 'gemma4:12b'},
                ],
              },
            ],
            '_meta': {
              'fm_agent_os/jj': {
                'jjChangeId': 'chg_0',
                'jjOpId': 'op_0',
                'txState': 'readOnly',
              },
            },
          };
        case '_fm_agent_os/processes':
          record({'event': 'processes_queried'});
          result = {
            'lead': {
              'pid': 1,
              'state': 'running',
              'isSuspended': false,
              'jjChangeId': 'chg_0',
              'jjOpId': 'op_0',
            },
            'processes': [
              {
                'pid': 2,
                'profile': 'workspace_worker',
                'state': 'waitingApproval',
                'model': 'local-ollama/gemma4:12b',
                'workspaceName': 'ws_2',
                'workingChangeId': 'chg_2',
                'heartbeat': {'currentStep': 1, 'maxSteps': 16, 'idleMs': 50, 'isPaused': true},
              },
            ],
          };
        case '_fm_agent_os/stack_list':
          result = {'tasks': <Map<String, dynamic>>[]};
        case 'session/prompt':
          turnCounter++;
          final promptList = params['prompt'] as List? ?? const [];
          final text = promptList.isNotEmpty && promptList.first is Map
              ? ((promptList.first as Map)['text'] as String? ?? '')
              : '';
          record({'event': 'prompt', 'turn': turnCounter, 'text': text});
          final sid = params['sessionId'] as String;
          activeCancel = Completer<void>();

          if (text == 'SCENARIO_MISMATCH_THEN_MATCH') {
            // Send subprocess permission for apr_2, then send stale cancel for apr_1 (must NOT cancel apr_2).
            final permFuture = sendClientRequest('session/request_permission', {
              'sessionId': sid,
              'toolCall': {
                'toolCallId': 'apr_2',
                'title': '[Subprocess pid=2 worker-b (workspace_worker)] Execute: where dart',
                'kind': 'execute',
                'status': 'pending',
                'content': [
                  {
                    'type': 'content',
                    'content': {
                      'type': 'text',
                      'text': 'Requester: pid=2, name=worker-b, profile=workspace_worker\nReason: Locate dart binary',
                    },
                  },
                ],
              },
              'options': [
                {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'allow_always', 'name': 'Allow for this process (pid=2)', 'kind': 'allow_always'},
                {'optionId': 'reject_once', 'name': 'Deny', 'kind': 'reject_once'},
              ],
              '_meta': {
                'fm_agent_os/approval': {
                  'requestId': 'apr_2',
                  'pid': 2,
                  'processName': 'worker-b',
                  'profile': 'workspace_worker',
                  'ring': 'ring3',
                  'syscallName': 'sys_exec',
                  'requestedVia': 'sys_request_approval',
                  'allowAlwaysScope': 'pid',
                  'reason': 'Locate dart binary',
                },
              },
            });
            await Future<void>.delayed(const Duration(milliseconds: 30));
            // Stale cancel for apr_1 — must be ignored!
            sendNotification('_fm_agent_os/permission_cancelled', {
              'sessionId': sid,
              'requestId': 'apr_1',
              'toolCallId': 'apr_1',
              'pid': 9,
            });
            final outcome = await permFuture;
            record({'event': 'perm_outcome', 'requestId': 'apr_2', 'outcome': outcome});
            result = {
              'stopReason': 'end_turn',
              '_meta': {'fm_agent_os/turnSummary': {'ok': true}},
            };
          } else if (text == 'SCENARIO_MATCH_CANCEL') {
            final permFuture = sendClientRequest('session/request_permission', {
              'sessionId': sid,
              'toolCall': {
                'toolCallId': 'apr_cancel_me',
                'title': '[Subprocess pid=3 worker-c (workspace_worker)] Execute: where dart',
                'kind': 'execute',
                'status': 'pending',
                'content': const [],
              },
              'options': [
                {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'allow_always', 'name': 'Allow for this process (pid=3)', 'kind': 'allow_always'},
                {'optionId': 'reject_once', 'name': 'Deny', 'kind': 'reject_once'},
              ],
              '_meta': {
                'fm_agent_os/approval': {
                  'requestId': 'apr_cancel_me',
                  'pid': 3,
                  'processName': 'worker-c',
                  'profile': 'workspace_worker',
                  'ring': 'ring3',
                  'syscallName': 'sys_exec',
                  'allowAlwaysScope': 'pid',
                },
              },
            });
            await Future<void>.delayed(const Duration(milliseconds: 40));
            sendNotification('_fm_agent_os/permission_cancelled', {
              'sessionId': sid,
              'requestId': 'apr_cancel_me',
              'toolCallId': 'apr_cancel_me',
              'pid': 3,
            });
            final outcome = await permFuture;
            record({'event': 'perm_outcome', 'requestId': 'apr_cancel_me', 'outcome': outcome});
            result = {
              'stopReason': 'end_turn',
              '_meta': {'fm_agent_os/turnSummary': {'ok': true}},
            };
          } else if (text == 'SCENARIO_WAIT_USER_CANCEL') {
            final permFuture = sendClientRequest('session/request_permission', {
              'sessionId': sid,
              'toolCall': {
                'toolCallId': 'apr_user_cancel',
                'title': '[Subprocess pid=4 worker-d (workspace_worker)] Execute: where dart',
                'kind': 'execute',
                'status': 'pending',
                'content': const [],
              },
              'options': [
                {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'allow_always', 'name': 'Allow for this process (pid=4)', 'kind': 'allow_always'},
                {'optionId': 'reject_once', 'name': 'Deny', 'kind': 'reject_once'},
              ],
              '_meta': {
                'fm_agent_os/approval': {
                  'requestId': 'apr_user_cancel',
                  'pid': 4,
                  'processName': 'worker-d',
                  'profile': 'workspace_worker',
                  'ring': 'ring3',
                  'syscallName': 'sys_exec',
                  'allowAlwaysScope': 'pid',
                },
              },
            });
            final outcome = await permFuture;
            record({'event': 'perm_outcome', 'requestId': 'apr_user_cancel', 'outcome': outcome});
            result = {
              'stopReason': 'cancelled',
              '_meta': {'fm_agent_os/turnSummary': {'ok': false}},
            };
          } else if (text == 'SCENARIO_CONSECUTIVE_TWO') {
            final o1 = await sendClientRequest('session/request_permission', {
              'sessionId': sid,
              'toolCall': {
                'toolCallId': 'apr_seq_1',
                'title': '[Subprocess pid=2 w1 (workspace_worker)] Execute: where dart',
                'kind': 'execute',
                'status': 'pending',
                'content': const [],
              },
              'options': [
                {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'allow_always', 'name': 'Allow for this process (pid=2)', 'kind': 'allow_always'},
                {'optionId': 'reject_once', 'name': 'Deny', 'kind': 'reject_once'},
              ],
              '_meta': {
                'fm_agent_os/approval': {
                  'requestId': 'apr_seq_1',
                  'pid': 2,
                  'allowAlwaysScope': 'pid',
                },
              },
            });
            final o2 = await sendClientRequest('session/request_permission', {
              'sessionId': sid,
              'toolCall': {
                'toolCallId': 'apr_seq_2',
                'title': '[Subprocess pid=3 w2 (conflict_resolver)] Execute: hostname',
                'kind': 'execute',
                'status': 'pending',
                'content': const [],
              },
              'options': [
                {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'allow_always', 'name': 'Allow for this process (pid=3)', 'kind': 'allow_always'},
                {'optionId': 'reject_once', 'name': 'Deny', 'kind': 'reject_once'},
              ],
              '_meta': {
                'fm_agent_os/approval': {
                  'requestId': 'apr_seq_2',
                  'pid': 3,
                  'allowAlwaysScope': 'pid',
                },
              },
            });
            record({'event': 'seq_outcomes', 'o1': o1, 'o2': o2});
            result = {
              'stopReason': 'end_turn',
              '_meta': {'fm_agent_os/turnSummary': {'ok': true}},
            };
          } else if (text == 'SCENARIO_STALE_ON_TURN_END') {
            // Fire a permission request without waiting for its response, then finish the prompt turn.
            unawaited(sendClientRequest('session/request_permission', {
              'sessionId': sid,
              'toolCall': {
                'toolCallId': 'apr_stale',
                'title': '[Subprocess pid=5 w5 (workspace_worker)] Execute: hostname',
                'kind': 'execute',
                'status': 'pending',
                'content': const [],
              },
              'options': [
                {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'allow_always', 'name': 'Allow for this process (pid=5)', 'kind': 'allow_always'},
                {'optionId': 'reject_once', 'name': 'Deny', 'kind': 'reject_once'},
              ],
              '_meta': {
                'fm_agent_os/approval': {
                  'requestId': 'apr_stale',
                  'pid': 5,
                  'profile': 'workspace_worker',
                  'allowAlwaysScope': 'pid',
                },
              },
            }).then((o) {
              record({'event': 'stale_outcome', 'outcome': o});
            }));
            await Future<void>.delayed(const Duration(milliseconds: 60));
            result = {
              'stopReason': 'end_turn',
              '_meta': {'fm_agent_os/turnSummary': {'ok': true}},
            };
          } else if (text == 'SCENARIO_OVERLAPPING_WAITERS') {
            // Send request A, then before A is answered send request B; A's stale waiter must safely complete as cancelled, and B can be answered.
            final fA = sendClientRequest('session/request_permission', {
              'sessionId': sid,
              'toolCall': {
                'toolCallId': 'apr_overlap_a',
                'title': '[Subprocess pid=2 wa (workspace_worker)] Execute: first',
                'kind': 'execute',
                'status': 'pending',
                'content': const [],
              },
              'options': [
                {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'allow_always', 'name': 'Allow for this process (pid=2)', 'kind': 'allow_always'},
                {'optionId': 'reject_once', 'name': 'Deny', 'kind': 'reject_once'},
              ],
              '_meta': {
                'fm_agent_os/approval': {
                  'requestId': 'apr_overlap_a',
                  'pid': 2,
                  'allowAlwaysScope': 'pid',
                },
              },
            });
            await Future<void>.delayed(const Duration(milliseconds: 30));
            final fB = sendClientRequest('session/request_permission', {
              'sessionId': sid,
              'toolCall': {
                'toolCallId': 'apr_overlap_b',
                'title': '[Subprocess pid=6 wb (workspace_worker)] Execute: second',
                'kind': 'execute',
                'status': 'pending',
                'content': const [],
              },
              'options': [
                {'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'allow_always', 'name': 'Allow for this process (pid=6)', 'kind': 'allow_always'},
                {'optionId': 'reject_once', 'name': 'Deny', 'kind': 'reject_once'},
              ],
              '_meta': {
                'fm_agent_os/approval': {
                  'requestId': 'apr_overlap_b',
                  'pid': 6,
                  'allowAlwaysScope': 'pid',
                },
              },
            });
            final oA = await fA;
            final oB = await fB;
            record({'event': 'overlap_outcomes', 'oA': oA, 'oB': oB});
            result = {
              'stopReason': 'end_turn',
              '_meta': {'fm_agent_os/turnSummary': {'ok': true}},
            };
          } else {
            record({'event': 'plain_turn', 'text': text});
            result = {
              'stopReason': 'end_turn',
              '_meta': {'fm_agent_os/turnSummary': {'ok': true}},
            };
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
}
''';

void main() {
  group('AcpApprovalHandler & AcpEventMapper Subprocess Isolation [D-704], [D-708], [D-709]',
      () {
    test('pid == 1 preserves exact correlation, title, content, and session scope',
        () async {
      final pair = _PeerPair();
      addTearDown(pair.close);

      Map<String, dynamic>? capturedParams;
      pair.clientPeer.onRequest = (method, params) async {
        expect(method, equals('session/request_permission'));
        capturedParams = params;
        return <String, dynamic>{
          'outcome': <String, dynamic>{
            'outcome': 'selected',
            'optionId': 'allow_once',
          },
        };
      };

      final handler = AcpApprovalHandler(
        peer: pair.serverPeer,
        activeToolCallIdProvider: () => 'sc_lead_001',
      );

      final diffBlock = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'diff',
          'path': '/workspace/lib/a.dart',
          'oldText': 'a',
          'newText': 'b',
        },
      ];
      final decision = await handler.requestApproval(
        ApprovalRequest(
          requestId: 'apr_lead_1',
          sessionId: 'sess_1',
          pid: 1,
          syscallName: 'sys_tx_squash',
          title: 'Squash working change into @-',
          kind: 'edit',
          argsSummary: const <String, dynamic>{},
          content: diffBlock,
        ),
      );

      expect(decision.option, equals(ApprovalOption.allowOnce));
      expect(capturedParams, isNotNull);
      expect(
        capturedParams!.keys.toSet(),
        equals(<String>{'sessionId', 'toolCall', 'options', '_meta'}),
      );

      final toolCall = capturedParams!['toolCall'] as Map<String, dynamic>;
      expect(
        toolCall.keys.toSet(),
        equals(<String>{'toolCallId', 'title', 'kind', 'status', 'content'}),
      );
      expect(toolCall['toolCallId'], equals('sc_lead_001'));
      expect(toolCall['title'], equals('Squash working change into @-'));
      expect(toolCall['content'], equals(diffBlock));

      final options = (capturedParams!['options'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      for (final opt in options) {
        expect(opt.keys.toSet(), equals(<String>{'optionId', 'name', 'kind'}));
      }
      final allowAlwaysOpt =
          options.firstWhere((o) => o['optionId'] == 'allow_always');
      expect(allowAlwaysOpt['name'], equals('Allow for session'));

      final meta = (capturedParams!['_meta']
          as Map<String, dynamic>)['fm_agent_os/approval'] as Map<String, dynamic>;
      expect(meta['requestId'], equals('apr_lead_1'));
      expect(meta['pid'], equals(1));
      expect(meta['allowAlwaysScope'], equals('session'));
      expect(meta.containsKey('profile'), isFalse);
      expect(meta.containsKey('reason'), isFalse);
    });

    test('pid != 1 isolates toolCallId, formats subprocess header/title/scope, and populates _meta',
        () async {
      final pair = _PeerPair();
      addTearDown(pair.close);

      Map<String, dynamic>? capturedParams;
      pair.clientPeer.onRequest = (method, params) async {
        expect(method, equals('session/request_permission'));
        capturedParams = params;
        return <String, dynamic>{
          'outcome': <String, dynamic>{
            'outcome': 'selected',
            'optionId': 'allow_always',
          },
        };
      };

      final handler = AcpApprovalHandler(
        peer: pair.serverPeer,
        activeToolCallIdProvider: () => 'sc_parent_sys_wait_99',
      );

      final decision = await handler.requestApproval(
        ApprovalRequest(
          requestId: 'apr_sess_01_14',
          sessionId: 'sess_01',
          pid: 2,
          processName: 'worker-a',
          profile: 'workspace_worker',
          ring: ProtectionRing.ring3,
          syscallName: 'sys_exec',
          requestedVia: 'sys_request_approval',
          agentReason: 'Run custom verification binary',
          title: 'Execute: where dart',
          kind: 'execute',
          argsSummary: const <String, dynamic>{'command': 'where', 'args': ['dart']},
        ),
      );

      expect(decision.option, equals(ApprovalOption.allowAlways));
      expect(capturedParams, isNotNull);
      expect(
        capturedParams!.keys.toSet(),
        equals(<String>{'sessionId', 'toolCall', 'options', '_meta'}),
      );

      final toolCall = capturedParams!['toolCall'] as Map<String, dynamic>;
      expect(
        toolCall.keys.toSet(),
        equals(<String>{'toolCallId', 'title', 'kind', 'status', 'content'}),
      );
      expect(toolCall['toolCallId'], equals('apr_sess_01_14'));
      expect(
        toolCall['title'],
        equals('[Subprocess pid=2 worker-a (workspace_worker)] Execute: where dart'),
      );

      final content = (toolCall['content'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(content.length, equals(2));
      final headerText =
          (content.first['content'] as Map<String, dynamic>)['text'] as String;
      expect(
        headerText,
        contains('Requester: pid=2, name=worker-a, profile=workspace_worker'),
      );
      expect(headerText, contains('Reason: Run custom verification binary'));

      final options = (capturedParams!['options'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final allowAlwaysOpt =
          options.firstWhere((o) => o['optionId'] == 'allow_always');
      expect(allowAlwaysOpt['name'], equals('Allow for this process (pid=2)'));

      final meta = (capturedParams!['_meta']
          as Map<String, dynamic>)['fm_agent_os/approval'] as Map<String, dynamic>;
      expect(meta['requestId'], equals('apr_sess_01_14'));
      expect(meta['pid'], equals(2));
      expect(meta['processName'], equals('worker-a'));
      expect(meta['profile'], equals('workspace_worker'));
      expect(meta['ring'], equals('ring3'));
      expect(meta['syscallName'], equals('sys_exec'));
      expect(meta['requestedVia'], equals('sys_request_approval'));
      expect(meta['allowAlwaysScope'], equals('pid'));
      expect(meta['reason'], equals('Run custom verification binary'));
    });

    test('ApprovalGate + AcpApprovalHandler emits permission_cancelled before next queued permission on cancel (RV-001)',
        () async {
      final pair = _PeerPair();
      addTearDown(pair.close);

      final wireOrder = <String>[];
      final req1Received = Completer<void>();
      final req2Completer = Completer<Map<String, dynamic>>();

      pair.clientPeer.onNotification = (method, params) {
        if (method == '_fm_agent_os/permission_cancelled') {
          wireOrder.add('cancelled:${params['requestId']}:pid=${params['pid']}');
        }
      };

      pair.clientPeer.onRequest = (method, params) async {
        expect(method, equals('session/request_permission'));
        final meta = (params['_meta']
            as Map<String, dynamic>)['fm_agent_os/approval'] as Map<String, dynamic>;
        final reqId = meta['requestId'] as String;
        wireOrder.add('request:$reqId:pid=${meta['pid']}');
        if (reqId == 'apr_fifo_1') {
          req1Received.complete();
          // Never responds; daemon cancels it.
          return Completer<Map<String, dynamic>>().future;
        }
        return req2Completer.future;
      };

      final handler = AcpApprovalHandler(peer: pair.serverPeer);
      final gate = ApprovalGate(handler: handler);
      final cancel1 = CancellationTokenSource();

      final f1 = gate.evaluate(
        ApprovalRequest(
          requestId: 'apr_fifo_1',
          sessionId: 'sess_1',
          pid: 2,
          processName: 'w1',
          profile: 'workspace_worker',
          syscallName: 'sys_exec',
          title: 'Run 1',
          kind: 'execute',
          argsSummary: const <String, dynamic>{},
        ),
        cancelToken: cancel1.token,
      );
      final f2 = gate.evaluate(
        ApprovalRequest(
          requestId: 'apr_fifo_2',
          sessionId: 'sess_1',
          pid: 3,
          processName: 'w2',
          profile: 'workspace_worker',
          syscallName: 'sys_exec',
          title: 'Run 2',
          kind: 'execute',
          argsSummary: const <String, dynamic>{},
        ),
      );

      await req1Received.future.timeout(const Duration(seconds: 3));
      cancel1.cancel('SIGKILL pid 2');

      final d1 = await f1.timeout(const Duration(seconds: 3));
      expect(d1.cancelled, isTrue);

      // Wait until second request arrives on wire, then approve it.
      for (var i = 0; i < 40 && wireOrder.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      req2Completer.complete(<String, dynamic>{
        'outcome': <String, dynamic>{
          'outcome': 'selected',
          'optionId': 'allow_once',
        },
      });
      final d2 = await f2.timeout(const Duration(seconds: 3));
      expect(d2.option, equals(ApprovalOption.allowOnce));

      expect(
        wireOrder,
        equals(<String>[
          'request:apr_fifo_1:pid=2',
          'cancelled:apr_fifo_1:pid=2',
          'request:apr_fifo_2:pid=3',
        ]),
      );
    });

    test('AcpEventMapper isolates child rejections, ignores isApprovalPrecheck, handles onGrantConsumed, and formats sys_request_approval',
        () async {
      final pair = _PeerPair();
      addTearDown(pair.close);

      final updates = <Map<String, dynamic>>[];
      pair.clientPeer.onNotification = (method, params) {
        if (method == 'session/update') {
          updates.add(Map<String, dynamic>.from(params['update'] as Map));
        }
      };

      final tempDir = Directory.systemTemp.createTempSync('fm_acp_mapper_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final mapper = AcpEventMapper(
        sessionId: 'sess_1',
        peer: pair.serverPeer,
        namespace: VfsNamespace(workspaceHostRoot: tempDir.path),
        jjContext: JjTxContext(),
      );
      final hook = AcpSyscallObserverHook(mapper);

      // formatToolTitle for sys_request_approval
      expect(
        AcpEventMapper.formatToolTitle(
          'sys_request_approval',
          const <String, dynamic>{'syscall': 'sys_exec'},
        ),
        equals('Request approval for sys_exec'),
      );

      // Parent starts sys_wait; child rejection must NOT pollute parent's audit decision.
      mapper.onAgentLoopEvent(
        AgentToolCallStartedEvent(
          sessionId: 'sess_1',
          turnIndex: 1,
          callId: 'sc_wait_1',
          toolName: 'sys_wait',
          arguments: const <String, dynamic>{'pids': <int>[2]},
        ),
      );
      mapper.recordApprovalResolution(
        ApprovalRequest(
          requestId: 'apr_child_2',
          sessionId: 'sess_1',
          pid: 2,
          syscallName: 'sys_exec',
          title: 'Child exec',
          kind: 'execute',
          argsSummary: const <String, dynamic>{},
        ),
        const ApprovalDecision.rejectOnce(),
      );
      // isApprovalPrecheck hook invocation must NOT overwrite active tool args.
      await hook.beforeSyscall(
        SyscallHookContext(
          pid: 1,
          ring: ProtectionRing.ring2,
          sessionId: 'sess_1',
          syscallName: 'sys_exec',
          args: const <String, dynamic>{'command': 'precheck_only'},
          jjContext: JjTxContext(),
          isApprovalPrecheck: true,
        ),
      );
      mapper.onAgentLoopEvent(
        const AgentToolCallCompletedEvent(
          sessionId: 'sess_1',
          turnIndex: 1,
          callId: 'sc_wait_1',
          toolName: 'sys_wait',
          ok: true,
        ),
      );

      // Parent consumes a one-time grant for sys_tx_squash -> decision APPROVED_BY_USER.
      mapper.onAgentLoopEvent(
        AgentToolCallStartedEvent(
          sessionId: 'sess_1',
          turnIndex: 1,
          callId: 'sc_sq_1',
          toolName: 'sys_tx_squash',
          arguments: const <String, dynamic>{},
        ),
      );
      mapper.recordGrantConsumed(
        ApprovalGrant(
          grantId: 'grt_1',
          pid: 1,
          syscallName: 'sys_tx_squash',
          canonicalArgsJson: '{}',
          decisionOption: ApprovalOption.allowOnce,
          preview: ApprovalPreview(
            title: 'Squash',
            kind: 'edit',
            content: const <Map<String, dynamic>>[
              <String, dynamic>{'type': 'diff', 'path': '/workspace/a.dart'},
            ],
          ),
        ),
      );
      // Child grant consumption must be ignored by parent mapper.
      mapper.recordGrantConsumed(
        const ApprovalGrant(
          grantId: 'grt_2',
          pid: 2,
          syscallName: 'sys_exec',
          canonicalArgsJson: '{}',
          decisionOption: ApprovalOption.rejectOnce,
        ),
      );
      mapper.onAgentLoopEvent(
        const AgentToolCallCompletedEvent(
          sessionId: 'sess_1',
          turnIndex: 1,
          callId: 'sc_sq_1',
          toolName: 'sys_tx_squash',
          ok: true,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final waitUpdate = updates.firstWhere(
        (u) => u['sessionUpdate'] == 'tool_call_update' && u['toolCallId'] == 'sc_wait_1',
      );
      expect(waitUpdate['status'], equals('completed'));
      expect(
        ((waitUpdate['_meta'] as Map)['fm_agent_os/jj'] as Map)['decision'],
        equals('ALLOWED'),
      );

      final sqUpdate = updates.firstWhere(
        (u) => u['sessionUpdate'] == 'tool_call_update' && u['toolCallId'] == 'sc_sq_1',
      );
      expect(
        ((sqUpdate['_meta'] as Map)['fm_agent_os/jj'] as Map)['decision'],
        equals('APPROVED_BY_USER'),
      );
      expect((sqUpdate['content'] as List).first['type'], equals('diff'));
    });
  });

  group('AcpCliRunner Interactive & Policy Subprocess Approval Tests [D-709]', () {
    late Directory binDir;
    late File compiledMockDaemon;
    late Directory tempDir;
    late Directory repoDir;

    setUpAll(() {
      binDir = Directory.systemTemp.createTempSync('fm_wp3_mock_bin_');
      final src = File(p.join(binDir.path, 'mock_perm_daemon.dart'))
        ..writeAsStringSync(_mockPermDaemonSource);
      final exe = File(p.join(binDir.path, 'mock_perm_daemon.exe'));
      final res = Process.runSync(
        Platform.resolvedExecutable,
        <String>['compile', 'exe', src.path, '-o', exe.path],
        runInShell: false,
      );
      expect(res.exitCode, equals(0), reason: 'compile failed: ${res.stderr}');
      compiledMockDaemon = exe;
    });

    tearDownAll(() {
      if (binDir.existsSync()) {
        binDir.deleteSync(recursive: true);
      }
    });

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fm_wp3_cli_');
      repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync();
      Directory(p.join(repoDir.path, '.jj')).createSync();
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    List<Map<String, dynamic>> readDaemonEvents() {
      final f = File(p.join(repoDir.path, 'daemon_events.jsonl'));
      if (!f.existsSync()) return const [];
      return const LineSplitter()
          .convert(f.readAsStringSync())
          .where((l) => l.trim().isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
    }

    test('Interactive CLI displays pid prompt, ignores mismatched permission_cancelled (RV-001), allows /ps mid-wait, and clears on matching cancel & /cancel',
        () async {
      final outBuf = StringBuffer();
      final errBuf = StringBuffer();
      final stdinCtrl = StreamController<List<int>>();

      void sendStdin(String line) {
        stdinCtrl.add(utf8.encode('$line\n'));
      }

      Future<void> waitForOut(String needle) async {
        for (var i = 0; i < 100; i++) {
          if (outBuf.toString().contains(needle)) return;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        fail('Timed out waiting for "$needle" in:\n$outBuf\nstderr:\n$errBuf');
      }

      final runner = AcpCliRunner(
        out: outBuf,
        err: errBuf,
        stdinStream: stdinCtrl.stream,
        useAnsiColor: false,
        stdinHasTerminal: false,
      );

      final runFuture = runner.run(<String>[
        '--cwd',
        repoDir.path,
        '--daemon',
        compiledMockDaemon.path,
        '--permission-policy',
        'interactive',
      ]);

      await waitForOut('=== FM Agent OS — ACP CLI Client ===');

      // 1. Subprocess permission prompt (pid=2): daemon sends stale cancel for apr_1 (must NOT cancel apr_2).
      // Also run /ps mid-wait, then answer 'a' (allow_always).
      sendStdin('SCENARIO_MISMATCH_THEN_MATCH');
      await waitForOut('Allow? [y] once / [a] process (pid=2) / [n] deny: ');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(outBuf.toString(), isNot(contains('[Approval cancelled]')));

      sendStdin('/ps');
      await waitForOut('state=waitingApproval');

      sendStdin('a');
      // Wait for daemon to record outcome for apr_2.
      for (var i = 0; i < 60; i++) {
        if (readDaemonEvents().any(
            (e) => e['event'] == 'perm_outcome' && e['requestId'] == 'apr_2')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      // 2. Matching _fm_agent_os/permission_cancelled for apr_cancel_me clears waiter and prints [Approval cancelled].
      sendStdin('SCENARIO_MATCH_CANCEL');
      await waitForOut('[Approval cancelled]');

      // 3. User types /cancel during permission wait -> sends session/cancel, clears waiter, and next REPL line is NOT stolen!
      sendStdin('SCENARIO_WAIT_USER_CANCEL');
      await waitForOut('Allow? [y] once / [a] process (pid=4) / [n] deny: ');
      sendStdin('/cancel');
      await waitForOut('[Turn ended: stopReason=cancelled]');

      // Next turn must be delivered intact as a normal prompt.
      sendStdin('NEXT_TURN_AFTER_CANCEL');
      for (var i = 0; i < 60; i++) {
        if (readDaemonEvents().any(
            (e) => e['event'] == 'plain_turn' && e['text'] == 'NEXT_TURN_AFTER_CANCEL')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      // 4. Overlapping permission request safely completes previous uncompleted waiter (RV-001).
      sendStdin('SCENARIO_OVERLAPPING_WAITERS');
      await waitForOut('Allow? [y] once / [a] process (pid=6) / [n] deny: ');
      sendStdin('y');
      for (var i = 0; i < 60; i++) {
        if (readDaemonEvents().any((e) => e['event'] == 'overlap_outcomes')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      sendStdin('/quit');
      await stdinCtrl.close();

      final exitCode = await runFuture.timeout(const Duration(seconds: 10));
      expect(exitCode, equals(0), reason: 'stderr:\n$errBuf\nstdout:\n$outBuf');

      final events = readDaemonEvents();
      final overlap = events.firstWhere((e) => e['event'] == 'overlap_outcomes');
      expect(
        ((overlap['oA'] as Map)['outcome'] as Map)['outcome'],
        equals('cancelled'),
      );
      expect(
        ((overlap['oB'] as Map)['outcome'] as Map)['optionId'],
        equals('allow_once'),
      );
      final apr2 = events.firstWhere(
        (e) => e['event'] == 'perm_outcome' && e['requestId'] == 'apr_2',
      );
      expect(
        ((apr2['outcome'] as Map)['outcome'] as Map)['optionId'],
        equals('allow_always'),
      );

      final aprCancelMe = events.firstWhere(
        (e) => e['event'] == 'perm_outcome' && e['requestId'] == 'apr_cancel_me',
      );
      expect(
        ((aprCancelMe['outcome'] as Map)['outcome'] as Map)['outcome'],
        equals('cancelled'),
      );

      final aprUserCancel = events.firstWhere(
        (e) => e['event'] == 'perm_outcome' && e['requestId'] == 'apr_user_cancel',
      );
      expect(
        ((aprUserCancel['outcome'] as Map)['outcome'] as Map)['outcome'],
        equals('cancelled'),
      );

      expect(
        events.any(
          (e) =>
              e['event'] == 'plain_turn' &&
              e['text'] == 'NEXT_TURN_AFTER_CANCEL',
        ),
        isTrue,
      );
    });

    test('Non-interactive --permission-policy comma sequence resolves consecutive subprocess requests',
        () async {
      final outBuf = StringBuffer();
      final errBuf = StringBuffer();
      final runner = AcpCliRunner(
        out: outBuf,
        err: errBuf,
        useAnsiColor: false,
        stdinHasTerminal: false,
      );

      final exitCode = await runner.run(<String>[
        '--cwd',
        repoDir.path,
        '--daemon',
        compiledMockDaemon.path,
        '--permission-policy',
        'allow_once,reject_once',
        '--batch-commands',
        'SCENARIO_CONSECUTIVE_TWO\n/quit',
      ]);

      expect(exitCode, equals(0), reason: 'stderr:\n$errBuf\nstdout:\n$outBuf');
      final events = readDaemonEvents();
      final seq = events.firstWhere((e) => e['event'] == 'seq_outcomes');
      expect(
        ((seq['o1'] as Map)['outcome'] as Map)['optionId'],
        equals('allow_once'),
      );
      expect(
        ((seq['o2'] as Map)['outcome'] as Map)['optionId'],
        equals('reject_once'),
      );
    });
  });

  group('KanbanAcpBridge, KanbanServer & UI Assets Subprocess Approval Tests [D-709], [D-710]',
      () {
    late Directory tempDir;
    late Directory repoDir;
    late File mockDaemonFile;
    late KanbanAcpBridge bridge;
    late KanbanServer server;
    late StringBuffer outBuf;
    late StringBuffer errBuf;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('fm_wp3_kanban_');
      repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync();
      Directory(p.join(repoDir.path, '.jj')).createSync();
      mockDaemonFile = File(p.join(tempDir.path, 'mock_perm_daemon.dart'))
        ..writeAsStringSync(_mockPermDaemonSource);

      outBuf = StringBuffer();
      errBuf = StringBuffer();

      bridge = await KanbanAcpBridge.spawn(
        executable: Platform.resolvedExecutable,
        arguments: <String>[mockDaemonFile.path],
        cwd: repoDir.path,
        environment: <String, String>{'MOCK_STATE_DIR': tempDir.path},
        onDaemonStderr: (line) => errBuf.writeln(line),
      );
      await bridge.connect();
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

    Future<({int status, String body})> httpCall(
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
        return (status: res.statusCode, body: body);
      } finally {
        client.close(force: true);
      }
    }

    test('Kanban exposes approvalMeta, supports all 3 options, rejects invalid optionId, and clears on permission_cancelled & turn end',
        () async {
      final csrf = <String, String>{'X-CSRF-Token': server.csrfToken};
      final ws = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws?token=${server.csrfToken}',
      );
      final wsEvents = <Map<String, dynamic>>[];
      final wsSub = ws.listen((raw) {
        wsEvents.add(jsonDecode(raw as String) as Map<String, dynamic>);
      });
      addTearDown(() async {
        await wsSub.cancel();
        await ws.close();
      });

      // 1. Subprocess permission with stale mismatched cancel -> remains pending, responds with allow_always.
      final run1 = bridge.enqueueRun(
        taskId: 't_perm_1',
        prompt: 'SCENARIO_MISMATCH_THEN_MATCH',
      );

      Map<String, dynamic>? pending1;
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final stRes = await httpCall('GET', '/api/state', headers: csrf);
        final st = jsonDecode(stRes.body) as Map<String, dynamic>;
        final perms = (st['pendingPermissions'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        if (perms.isNotEmpty) {
          pending1 = perms.first;
          break;
        }
      }
      expect(pending1, isNotNull);
      final meta1 = pending1!['approvalMeta'] as Map<String, dynamic>;
      expect(meta1['pid'], equals(2));
      expect(meta1['profile'], equals('workspace_worker'));
      expect(meta1['reason'], equals('Locate dart binary'));
      expect(meta1['allowAlwaysScope'], equals('pid'));

      // Wait briefly so the daemon's mismatched cancel for apr_1 is processed.
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Invalid optionId must be rejected with 400 and leave permission pending.
      final badOpt = await httpCall(
        'POST',
        '/api/permissions/respond',
        headers: csrf,
        jsonBody: <String, dynamic>{
          'requestId': pending1['requestId'],
          'optionId': 'invalid_choice',
        },
      );
      expect(badOpt.status, equals(400));

      // Valid allow_always resolves the pending permission.
      final okOpt = await httpCall(
        'POST',
        '/api/permissions/respond',
        headers: csrf,
        jsonBody: <String, dynamic>{
          'requestId': pending1['requestId'],
          'optionId': 'allow_always',
        },
      );
      expect(okOpt.status, equals(200));
      final r1 = await run1.timeout(const Duration(seconds: 5));
      expect(r1['stopReason'], equals('end_turn'));

      // 2. Matching _fm_agent_os/permission_cancelled clears pendingPermissions and broadcasts WS event.
      final run2 = bridge.enqueueRun(
        taskId: 't_perm_2',
        prompt: 'SCENARIO_MATCH_CANCEL',
      );
      await run2.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        wsEvents.any((e) => e['type'] == 'permission_cancelled'),
        isTrue,
      );
      final stAfterCancel =
          jsonDecode((await httpCall('GET', '/api/state', headers: csrf)).body)
              as Map<String, dynamic>;
      expect(stAfterCancel['pendingPermissions'], isEmpty);

      // 3. Stale pending permission still open when session/prompt finishes is cleared in finally.
      final run3 = bridge.enqueueRun(
        taskId: 't_perm_3',
        prompt: 'SCENARIO_STALE_ON_TURN_END',
      );
      await run3.timeout(const Duration(seconds: 5));
      final stAfterTurn =
          jsonDecode((await httpCall('GET', '/api/state', headers: csrf)).body)
              as Map<String, dynamic>;
      expect(stAfterTurn['pendingPermissions'], isEmpty);
    });

    test('kanban_ui_assets.dart renders #global-permissions and 3 options with 0 http(s):// URLs',
        () {
      expect(
        RegExp(r'https?://', caseSensitive: false).allMatches(kanbanIndexHtml),
        isEmpty,
      );
      expect(kanbanIndexHtml, contains('id="global-permissions"'));
      expect(kanbanIndexHtml, contains('function buildPermissionBox(perm)'));
      expect(kanbanIndexHtml, contains('Subprocess PID '));
      expect(kanbanIndexHtml, contains("optionId: 'allow_always'"));
      expect(kanbanIndexHtml, contains('/api/permissions/respond'));
    });
  });
}
