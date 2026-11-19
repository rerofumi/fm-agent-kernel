import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SecretRedactor [D-004]', () {
    test('redacts Bearer tokens, registered API keys, and secret JSON fields to <REDACTED>', () {
      final redactor = SecretRedactor()
        ..registerFromEnvironment(<String, String>{
          'OPENROUTER_API_KEY': 'sk-or-v1-secret-openrouter-value',
          'OLLAMA_API_KEY': 'ollama_live_token_987654',
          'PATH': r'C:\Windows\System32',
        });

      final rawMsg =
          'HTTP 401 Authorization: Bearer sk-or-v1-secret-openrouter-value '
          'and key ollama_live_token_987654 failed';
      final masked = redactor.redactString(rawMsg);
      expect(masked, isNot(contains('sk-or-v1-secret-openrouter-value')));
      expect(masked, isNot(contains('ollama_live_token_987654')));
      expect(masked, contains('<REDACTED>'));

      final bearerFallback = redactor.redactString(
        'Header Authorization: Bearer some_unregistered_bearer_xyz123',
      );
      expect(bearerFallback, isNot(contains('some_unregistered_bearer_xyz123')));
      expect(bearerFallback, contains('Bearer <REDACTED>'));

      final maskedJson = redactor.redactJson(<String, dynamic>{
        'headers': <String, dynamic>{
          'Authorization': 'Bearer another-secret-jwt',
          'x-api-key': 'raw-secret-key',
        },
        'promptTokens': 1200,
        'cachedTokens': 900,
      }) as Map<String, dynamic>;

      final headers = maskedJson['headers'] as Map<String, dynamic>;
      expect(headers['Authorization'], equals('Bearer <REDACTED>'));
      expect(headers['x-api-key'], equals('<REDACTED>'));
      expect(maskedJson['promptTokens'], equals(1200));
      expect(maskedJson['cachedTokens'], equals(900));
    });
  });

  group('AuditLogger & .agent_os/.gitignore [D-003], [D-010]', () {
    late Directory workspaceDir;

    setUp(() {
      workspaceDir = Directory.systemTemp.createTempSync('audit_ws_');
    });

    tearDown(() {
      if (workspaceDir.existsSync()) {
        workspaceDir.deleteSync(recursive: true);
      }
    });

    test('creates .agent_os/.gitignore (*\\n) and writes redacted syscalls.jsonl & llm_io.jsonl', () async {
      final redactor = SecretRedactor()..registerSecret('my-secret-ollama-key');
      final logger = AuditLogger(
        workspaceHostRoot: workspaceDir.path,
        sessionId: 'sess_audit_01',
        redactor: redactor,
      );

      final gitignore = File(p.join(workspaceDir.path, '.agent_os', '.gitignore'));
      expect(gitignore.existsSync(), isTrue);
      expect(gitignore.readAsStringSync(), equals('*\n'));

      await logger.logSyscall(
        SyscallAuditRecord(
          seq: 1,
          timestamp: DateTime.utc(2026, 11, 19, 12, 0, 0),
          sessionId: 'sess_audit_01',
          pid: 1,
          ring: ProtectionRing.ring2,
          syscallName: 'sys_exec',
          argsSummary: const <String, dynamic>{
            'command': 'curl -H "Authorization: Bearer my-secret-ollama-key"',
          },
          approvalRequired: false,
          decision: AuditDecision.allowed,
          ok: true,
          truncated: false,
          durationMs: 12,
          jjChangeId: 'vnzyzqllrmrm',
          jjOpId: 'de3a916ace23',
        ),
      );

      await logger.logLlmIo(
        LlmIoAuditRecord(
          seq: 1,
          turnIndex: 0,
          timestamp: DateTime.utc(2026, 11, 19, 12, 0, 1),
          sessionId: 'sess_audit_01',
          provider: 'ollama-cloud',
          model: 'gpt-oss:120b',
          endpoint: 'https://ollama.com/api/chat',
          ok: false,
          errorCode: 'EPROVIDER',
          promptTokens: 0,
          completionTokens: 0,
          totalTokens: 0,
          cachedTokens: null,
          durationMs: 35,
          toolCallsCount: 0,
          requestDebug: const <String, dynamic>{
            'authHeader': 'Bearer my-secret-ollama-key',
          },
        ),
      );
      await logger.flush();

      final syscallsLines = File(logger.syscallsLogPath).readAsLinesSync();
      expect(syscallsLines, hasLength(1));
      expect(syscallsLines.first, isNot(contains('my-secret-ollama-key')));
      expect(syscallsLines.first, contains('<REDACTED>'));
      final parsedSyscall =
          jsonDecode(syscallsLines.first) as Map<String, dynamic>;
      expect(parsedSyscall['decision'], equals('ALLOWED'));
      expect(parsedSyscall['jjChangeId'], equals('vnzyzqllrmrm'));
      expect(parsedSyscall['jjOpId'], equals('de3a916ace23'));

      final llmLines = File(logger.llmIoLogPath).readAsLinesSync();
      expect(llmLines, hasLength(1));
      expect(llmLines.first, isNot(contains('my-secret-ollama-key')));
      expect(llmLines.first, contains('<REDACTED>'));
      final parsedLlm = jsonDecode(llmLines.first) as Map<String, dynamic>;
      expect(parsedLlm['cachedTokens'], isNull);
      expect(parsedLlm['errorCode'], equals('EPROVIDER'));
    });
  });
}
