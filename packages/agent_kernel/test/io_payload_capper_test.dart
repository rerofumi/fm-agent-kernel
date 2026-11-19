import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('IoPayloadCapper [D-006]', () {
    late Directory workspaceDir;
    late IoPayloadCapper capper;

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('io_cap_ws_');
      capper = IoPayloadCapper(workspaceHostRoot: workspaceDir.path);
    });

    tearDown(() {
      if (workspaceDir.existsSync()) {
        workspaceDir.deleteSync(recursive: true);
      }
    });

    test('returns text unmodified when below or exactly at 200 lines and 16384 bytes', () async {
      final exactLines = List<String>.generate(200, (i) => 'line_${i + 1}').join('\n');
      final res = await capper.capText(
        text: exactLines,
        sessionId: 'sess_exact',
        syscallSeq: 1,
        syscallName: 'sys_read_lines',
      );

      expect(res.truncated, isFalse);
      expect(res.text, equals(exactLines));
      expect(res.originalLines, equals(200));
      expect(res.omittedLines, equals(0));
      expect(res.spillPath, isNull);
      expect(
        Directory(p.join(workspaceDir.path, '.agent_os', 'io_spill')).existsSync(),
        isFalse,
      );

      final exactBytes = 'a' * 16384;
      final byteRes = await capper.capText(
        text: exactBytes,
        sessionId: 'sess_exact',
        syscallSeq: 2,
        syscallName: 'sys_read_lines',
      );
      expect(byteRes.truncated, isFalse);
      expect(byteRes.text, equals(exactBytes));
      expect(byteRes.originalBytes, equals(16384));
    });

    test('truncates >10,000 lines keeping head 140 + tail 60 and spills full payload', () async {
      final lines = List<String>.generate(10050, (i) => 'row_${i + 1}');
      final hugeText = lines.join('\n');

      final res = await capper.capText(
        text: hugeText,
        sessionId: 'sess_huge',
        syscallSeq: 7,
        syscallName: 'sys_read_lines',
      );

      expect(res.truncated, isTrue);
      expect(res.originalLines, equals(10050));
      expect(res.omittedLines, equals(9850));
      expect(res.text, contains('row_1'));
      expect(res.text, contains('row_140'));
      expect(res.text, isNot(contains('row_141\n')));
      expect(res.text, contains('row_9991'));
      expect(res.text, contains('row_10050'));
      expect(
        res.text,
        contains('... [KERNEL I/O CAP: omitted 9850 lines'),
      );
      expect(
        res.spillPath,
        equals('/workspace/.agent_os/io_spill/sess_huge/7_sys_read_lines.txt'),
      );

      final spillFile = File(
        p.join(workspaceDir.path, '.agent_os', 'io_spill', 'sess_huge', '7_sys_read_lines.txt'),
      );
      expect(spillFile.existsSync(), isTrue);
      expect(spillFile.readAsStringSync(), equals(hugeText));

      final gitignore = File(p.join(workspaceDir.path, '.agent_os', '.gitignore'));
      expect(gitignore.existsSync(), isTrue);
      expect(gitignore.readAsStringSync(), equals('*\n'));
    });

    test('truncates ultra-long single line UTF-8 multibyte text cleanly at rune boundaries', () async {
      // 7000 Japanese characters ('あ' = 3 UTF-8 bytes) = 21,000 bytes > 16,384 bytes on 1 line.
      final longMultibyte = 'あ😀' * 3500;
      final originalBytes = utf8.encode(longMultibyte).length;
      expect(originalBytes, greaterThan(16384));

      final res = await capper.capText(
        text: longMultibyte,
        sessionId: 'sess_utf8',
        syscallSeq: 3,
        syscallName: 'sys_exec',
      );

      expect(res.truncated, isTrue);
      expect(res.originalLines, equals(1));
      expect(res.originalBytes, equals(originalBytes));
      expect(res.omittedBytes, greaterThan(0));
      // Must re-encode/decode cleanly without any replacement characters or FormatException.
      final roundTrip = utf8.decode(utf8.encode(res.text), allowMalformed: false);
      expect(roundTrip, equals(res.text));
      expect(res.text, isNot(contains('\uFFFD')));
    });

    test('capStructuredPayload caps text fields while preserving sha256, totalLines, and exitCode', () async {
      final hugeContent = List<String>.generate(300, (i) => 'line $i').join('\n');
      final readResult = <String, dynamic>{
        'path': '/workspace/big.dart',
        'sha256': 'a' * 64,
        'totalLines': 300,
        'startLine': 1,
        'endLine': 300,
        'content': hugeContent,
      };

      final cappedRead = await capper.capStructuredPayload(
        payload: readResult,
        textFields: const <String>['content'],
        sessionId: 'sess_meta',
        syscallSeq: 4,
        syscallName: 'sys_read_lines',
      );

      expect(cappedRead.truncated, isTrue);
      expect(cappedRead.payload['sha256'], equals('a' * 64));
      expect(cappedRead.payload['totalLines'], equals(300));
      expect(cappedRead.payload['truncated'], isTrue);
      expect(cappedRead.payload['content'], contains('KERNEL I/O CAP'));

      final execResult = <String, dynamic>{
        'exitCode': 1,
        'timedOut': false,
        'durationMs': 42,
        'stdout': hugeContent,
        'stderr': 'small error',
      };
      final cappedExec = await capper.capStructuredPayload(
        payload: execResult,
        textFields: const <String>['stdout', 'stderr'],
        sessionId: 'sess_meta',
        syscallSeq: 5,
        syscallName: 'sys_exec',
      );

      expect(cappedExec.truncated, isTrue);
      expect(cappedExec.payload['exitCode'], equals(1));
      expect(cappedExec.payload['truncatedStdout'], isTrue);
      expect(cappedExec.payload['truncatedStderr'], isFalse);
      expect(cappedExec.payload['stderr'], equals('small error'));
    });
  });
}
