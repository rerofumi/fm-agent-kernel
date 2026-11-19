import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_acp/agent_acp.dart';
import 'package:agent_drivers/agent_drivers.dart';
import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ACP CLI Runner, PermissionPolicy, Wire Redaction, and Stdout Purity [D-018], [D-021]',
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

    setUp(() {
      repoDir = Directory.systemTemp.createTempSync('fm_wp8_cli_');
      final initRes = runJjSync(<String>['git', 'init', '--colocate']);
      expect(initRes.exitCode, equals(0), reason: '${initRes.stderr}');
      runJjSync(<String>['config', 'set', '--repo', 'user.name', 'WP8 CLI']);
      runJjSync(
          <String>['config', 'set', '--repo', 'user.email', 'cli@example.com']);
      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# sample\n');
      expect(runJjSync(<String>['describe', '-m', 'init']).exitCode, equals(0));
      expect(runJjSync(<String>['new', '-m', 'wip']).exitCode, equals(0));
    });

    tearDown(() {
      if (repoDir.existsSync()) {
        repoDir.deleteSync(recursive: true);
      }
    });

    test('CliPermissionPolicy parses interactive, fixed, sequence, and rule specs',
        () {
      final interactive = CliPermissionPolicy.parse('interactive');
      expect(interactive.isInteractive, isTrue);

      final promptAlias = CliPermissionPolicy.parse('prompt');
      expect(promptAlias.isInteractive, isTrue);

      final seq = CliPermissionPolicy.parse('reject_once,allow_once');
      expect(seq.isInteractive, isFalse);
      expect(
        seq.resolveAutomatic(title: 't1', kind: 'edit', contentText: ''),
        equals('reject_once'),
      );
      expect(
        seq.resolveAutomatic(title: 't2', kind: 'edit', contentText: ''),
        equals('allow_once'),
      );
      expect(
        seq.resolveAutomatic(title: 't3', kind: 'edit', contentText: ''),
        equals('allow_once'),
      );

      final rules = CliPermissionPolicy.parse(
        'squash=reject_once,execute=allow_once,default=reject_once',
      );
      expect(
        rules.resolveAutomatic(
          title: 'Squash working change into @- (1 files)',
          kind: 'edit',
          contentText: '',
        ),
        equals('reject_once'),
      );
      expect(
        rules.resolveAutomatic(
          title: 'Execute external command: dart pub get',
          kind: 'execute',
          contentText: '',
        ),
        equals('allow_once'),
      );
    });

    test('JsonRpcPeer redacts registered secrets and Bearer tokens on the wire',
        () async {
      final c2s = StreamController<List<int>>();
      final s2c = StreamController<List<int>>();
      addTearDown(() async {
        await c2s.close();
        await s2c.close();
      });

      final redactor = SecretRedactor(
        initialSecrets: const <String>['super-secret-ollama-key-999'],
      );
      final peer = JsonRpcPeer(
        input: c2s.stream,
        output: s2c.sink,
        redactor: redactor,
      );
      addTearDown(() => peer.close());

      final lines = <String>[];
      final completer = Completer<void>();
      final sub = s2c.stream
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen((line) {
        lines.add(line);
        if (!completer.isCompleted) {
          completer.complete();
        }
      });
      addTearDown(sub.cancel);

      peer.sendNotification('session/update', <String, dynamic>{
        'sessionId': 'sess_1',
        'update': <String, dynamic>{
          'sessionUpdate': 'agent_message_chunk',
          'content': <String, dynamic>{
            'type': 'text',
            'text': 'Authorization: Bearer sk-or-v1-secret12345678 and super-secret-ollama-key-999',
          },
        },
      });

      await completer.future.timeout(const Duration(seconds: 3));
      expect(lines.single, isNot(contains('super-secret-ollama-key-999')));
      expect(lines.single, isNot(contains('sk-or-v1-secret12345678')));
      expect(lines.single, contains('<REDACTED>'));
    });

    test('agent_os_daemon.dart maintains strict stdout NDJSON purity and clean EOF exit',
        () async {
      final daemonScript = p.normalize(
        p.join(
          Directory.current.path,
          'packages',
          'agent_acp',
          'bin',
          'agent_os_daemon.dart',
        ),
      );
      final proc = await Process.start(
        Platform.resolvedExecutable,
        <String>['run', daemonScript, '--model', 'local-ollama/qwen3.8:27b'],
        workingDirectory: repoDir.path,
        runInShell: false,
      );

      final stdoutLines = <String>[];
      final stdoutSub = proc.stdout
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen(stdoutLines.add);
      addTearDown(stdoutSub.cancel);

      proc.stdin.write(
        '${jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{'protocolVersion': 1},
        })}\n',
      );
      proc.stdin.write(
        '${jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'session/new',
          'params': <String, dynamic>{
            'cwd': repoDir.path,
            'mcpServers': const <Object>[],
          },
        })}\n',
      );
      proc.stdin.write('{invalid-json\n');
      proc.stdin.write(
        '${jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'nonexistent/method',
          'params': const <String, dynamic>{},
        })}\n',
      );
      await proc.stdin.flush();
      await proc.stdin.close();

      final code = await proc.exitCode.timeout(const Duration(seconds: 15));
      expect(code, equals(0));
      expect(stdoutLines, hasLength(4));

      // Every single stdout line must parse cleanly as JSON-RPC 2.0 NDJSON
      final frames = stdoutLines
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      final f1 = frames.firstWhere((f) => f['id'] == 1);
      final f2 = frames.firstWhere((f) => f['id'] == 2);
      final fParse = frames.firstWhere((f) => f['id'] == null);
      final f3 = frames.firstWhere((f) => f['id'] == 3);

      expect((f1['result'] as Map<String, dynamic>)['protocolVersion'], equals(1));
      expect((f2['result'] as Map<String, dynamic>)['sessionId'], startsWith('sess_'));
      expect((fParse['error'] as Map<String, dynamic>)['code'], equals(-32700));
      expect((f3['error'] as Map<String, dynamic>)['code'], equals(-32601));
    });

    test('AcpCliRunner batch commands execute /model, /status, and /quit over real daemon',
        () async {
      final outBuf = StringBuffer();
      final errBuf = StringBuffer();
      final runner = AcpCliRunner(
        out: outBuf,
        err: errBuf,
        useAnsiColor: false,
        stdinHasTerminal: false,
      );

      final exit = await runner.run(<String>[
        '--cwd',
        repoDir.path,
        '--model',
        'local-ollama/gemma4:12b',
        '--permission-policy',
        'allow_once',
        '--batch-commands',
        '/model local-ollama/qwen3.8:27b\n/status\n/quit',
      ]);

      expect(exit, equals(0), reason: 'stderr:\n$errBuf\nstdout:\n$outBuf');
      final outText = outBuf.toString();
      expect(outText, contains('[Model] Switched to local-ollama/qwen3.8:27b'));
      expect(outText, contains('[Status] session=sess_'));
      expect(outText, contains('model=local-ollama/qwen3.8:27b'));
    });
  });
}
