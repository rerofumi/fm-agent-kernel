import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'io_payload_capper.dart';
import 'pcb.dart';

/// Redacts API keys, Bearer tokens, and secret fields before logging or reporting ([D-004]).
class SecretRedactor {
  SecretRedactor({
    Iterable<String> initialSecrets = const <String>[],
  }) {
    for (final secret in initialSecrets) {
      registerSecret(secret);
    }
  }

  static const String redactedToken = '<REDACTED>';

  static final RegExp _bearerPattern =
      RegExp(r'Bearer\s+[A-Za-z0-9._\-~+/]+=*', caseSensitive: false);
  static final RegExp _openRouterKeyPattern =
      RegExp(r'sk-or-v1-[A-Za-z0-9_-]{8,}');
  static final RegExp _genericSkKeyPattern = RegExp(r'sk-[A-Za-z0-9_-]{16,}');
  static final RegExp _secretEnvKeyPattern = RegExp(
    r'^(OPENROUTER_API_KEY|OLLAMA_API_KEY|.*_(API_KEY|SECRET|TOKEN|PASSWORD))$',
    caseSensitive: false,
  );
  static const Set<String> _secretJsonFieldNames = <String>{
    'authorization',
    'x-api-key',
    'api_key',
    'apikey',
    'secret',
    'password',
    'access_token',
    'auth_token',
    'bearer_token',
  };

  final Set<String> _registeredSecrets = <String>{};

  /// Registers an explicit secret value to be masked across all outputs.
  void registerSecret(String? secret) {
    if (secret == null) {
      return;
    }
    final trimmed = secret.trim();
    if (trimmed.length >= 4) {
      _registeredSecrets.add(trimmed);
    }
  }

  /// Registers any secret environment variable values without exposing them.
  void registerFromEnvironment(Map<String, String> environment) {
    for (final entry in environment.entries) {
      if (_secretEnvKeyPattern.hasMatch(entry.key)) {
        registerSecret(entry.value);
      }
    }
  }

  /// Redacts all registered secrets and token patterns from [input].
  String redactString(String input) {
    if (input.isEmpty) {
      return input;
    }
    var result = input;
    if (_registeredSecrets.isNotEmpty) {
      final sorted = _registeredSecrets.toList(growable: false)
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final secret in sorted) {
        if (result.contains(secret)) {
          result = result.replaceAll(secret, redactedToken);
        }
      }
    }
    result = result.replaceAll(_bearerPattern, 'Bearer $redactedToken');
    result = result.replaceAll(_openRouterKeyPattern, redactedToken);
    result = result.replaceAll(_genericSkKeyPattern, redactedToken);
    return result;
  }

  /// Recursively redacts strings and known secret keys inside JSON-like structures.
  dynamic redactJson(dynamic value, {String? keyName}) {
    if (keyName != null &&
        _secretJsonFieldNames.contains(keyName.toLowerCase()) &&
        value is String &&
        value.trim().isNotEmpty) {
      if (keyName.toLowerCase() == 'authorization' &&
          value.trimLeft().toLowerCase().startsWith('bearer ')) {
        return 'Bearer $redactedToken';
      }
      return redactedToken;
    }

    if (value is String) {
      return redactString(value);
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        final k = entry.key.toString();
        out[k] = redactJson(entry.value, keyName: k);
      }
      return out;
    }
    if (value is List) {
      return value.map((item) => redactJson(item)).toList(growable: false);
    }
    return value;
  }
}

/// Decision value recorded in `syscalls.jsonl` ([D-010]).
enum AuditDecision {
  allowed('ALLOWED'),
  approvedByUser('APPROVED_BY_USER'),
  deniedByPolicy('DENIED_BY_POLICY'),
  deniedByUser('DENIED_BY_USER'),
  hookBlocked('HOOK_BLOCKED'),
  invalidArgs('INVALID_ARGS'),
  quotaExceeded('QUOTA_EXCEEDED');

  const AuditDecision(this.wireValue);

  final String wireValue;
}

/// Structured audit record written to `syscalls.jsonl` ([D-010], [D-215]).
class SyscallAuditRecord {
  const SyscallAuditRecord({
    required this.seq,
    required this.timestamp,
    required this.sessionId,
    required this.pid,
    this.parentPid,
    this.processName,
    required this.ring,
    required this.syscallName,
    required this.argsSummary,
    required this.approvalRequired,
    required this.decision,
    required this.ok,
    this.errorCode,
    this.errorReason,
    required this.truncated,
    required this.durationMs,
    this.jjChangeId,
    this.jjOpId,
  });

  final int seq;
  final DateTime timestamp;
  final String sessionId;
  final Pid pid;
  final Pid? parentPid;
  final String? processName;
  final ProtectionRing ring;
  final String syscallName;
  final Map<String, dynamic> argsSummary;
  final bool approvalRequired;
  final AuditDecision decision;
  final bool ok;
  final String? errorCode;
  final String? errorReason;
  final bool truncated;
  final int durationMs;
  final String? jjChangeId;
  final String? jjOpId;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'seq': seq,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'sessionId': sessionId,
      'pid': pid,
      'parentPid': parentPid,
      'processName': processName,
      'ring': ring.name,
      'syscallName': syscallName,
      'argsSummary': argsSummary,
      'approvalRequired': approvalRequired,
      'decision': decision.wireValue,
      'ok': ok,
      'errorCode': errorCode,
      'errorReason': errorReason,
      'truncated': truncated,
      'durationMs': durationMs,
      'jjChangeId': jjChangeId,
      'jjOpId': jjOpId,
    };
  }
}

/// Structured telemetry record written to `llm_io.jsonl` ([D-010], [D-207], [D-215]).
class LlmIoAuditRecord {
  const LlmIoAuditRecord({
    required this.seq,
    required this.turnIndex,
    required this.timestamp,
    required this.sessionId,
    this.pid = 1,
    this.parentPid,
    this.processName,
    this.ring = ProtectionRing.ring2,
    required this.provider,
    required this.model,
    this.endpoint,
    required this.ok,
    this.errorCode,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    this.cachedTokens,
    this.cacheWriteTokens,
    this.cacheHitRate,
    this.costMicroUsd,
    this.ttftMs,
    required this.durationMs,
    required this.toolCallsCount,
    this.effectiveWindowTokens,
    this.evictedPagesInStep = 0,
    this.residentCleanPages = 0,
    this.evictedCleanPages = 0,
    this.stalePagesCount = 0,
    this.requestDebug,
    this.responseDebug,
  });

  final int seq;
  final int turnIndex;
  final DateTime timestamp;
  final String sessionId;
  final Pid pid;
  final Pid? parentPid;
  final String? processName;
  final ProtectionRing ring;
  final String provider;
  final String model;
  final String? endpoint;
  final bool ok;
  final String? errorCode;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int? cachedTokens;
  final int? cacheWriteTokens;
  final double? cacheHitRate;
  final int? costMicroUsd;
  final int? ttftMs;
  final int durationMs;
  final int toolCallsCount;
  final int? effectiveWindowTokens;
  final int evictedPagesInStep;
  final int residentCleanPages;
  final int evictedCleanPages;
  final int stalePagesCount;
  final Map<String, dynamic>? requestDebug;
  final Map<String, dynamic>? responseDebug;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'seq': seq,
      'turnIndex': turnIndex,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'sessionId': sessionId,
      'pid': pid,
      'parentPid': parentPid,
      'processName': processName,
      'ring': ring.name,
      'provider': provider,
      'model': model,
      'endpoint': endpoint,
      'ok': ok,
      'errorCode': errorCode,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'totalTokens': totalTokens,
      'cachedTokens': cachedTokens,
      'cacheWriteTokens': cacheWriteTokens,
      'cacheHitRate': cacheHitRate,
      'costMicroUsd': costMicroUsd,
      'ttftMs': ttftMs,
      'durationMs': durationMs,
      'toolCallsCount': toolCallsCount,
      'effectiveWindowTokens': effectiveWindowTokens,
      'evictedPagesInStep': evictedPagesInStep,
      'residentCleanPages': residentCleanPages,
      'evictedCleanPages': evictedCleanPages,
      'stalePagesCount': stalePagesCount,
      if (requestDebug != null) 'requestDebug': requestDebug,
      if (responseDebug != null) 'responseDebug': responseDebug,
    };
  }
}

/// Writes redacted JSONL audit records to `.agent_os/logs/<sessionId>/` ([D-003], [D-010]).
class AuditLogger {
  AuditLogger({
    required this.workspaceHostRoot,
    required this.sessionId,
    SecretRedactor? redactor,
  }) : redactor = redactor ?? SecretRedactor() {
    ensureAgentOsGitignoreSync(workspaceHostRoot);
  }

  final String workspaceHostRoot;
  final String sessionId;
  final SecretRedactor redactor;

  static final RegExp _unsafeSessionChars = RegExp(r'[^a-zA-Z0-9_.-]');

  Future<void> _writeChain = Future<void>.value();

  String get _safeSessionId => sessionId.replaceAll(_unsafeSessionChars, '_');

  /// Directory containing `syscalls.jsonl` and `llm_io.jsonl` for this session.
  String get sessionLogDirPath =>
      p.join(workspaceHostRoot, '.agent_os', 'logs', _safeSessionId);

  /// Full host path to `syscalls.jsonl`.
  String get syscallsLogPath => p.join(sessionLogDirPath, 'syscalls.jsonl');

  /// Full host path to `llm_io.jsonl`.
  String get llmIoLogPath => p.join(sessionLogDirPath, 'llm_io.jsonl');

  /// Appends a redacted [SyscallAuditRecord] to `syscalls.jsonl`.
  Future<void> logSyscall(SyscallAuditRecord record) {
    final redacted = redactor.redactJson(record.toJson()) as Map<String, dynamic>;
    return _enqueueAppend(syscallsLogPath, jsonEncode(redacted));
  }

  /// Appends a redacted [LlmIoAuditRecord] to `llm_io.jsonl`.
  Future<void> logLlmIo(LlmIoAuditRecord record) {
    final redacted = redactor.redactJson(record.toJson()) as Map<String, dynamic>;
    return _enqueueAppend(llmIoLogPath, jsonEncode(redacted));
  }

  /// Waits for all queued JSONL writes to finish flushing to disk.
  Future<void> flush() => _writeChain;

  Future<void> _enqueueAppend(String filePath, String jsonLine) {
    _writeChain = _writeChain.then((_) async {
      ensureAgentOsGitignoreSync(workspaceHostRoot);
      final dir = Directory(sessionLogDirPath);
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      final file = File(filePath);
      await file.writeAsString(
        '$jsonLine\n',
        mode: FileMode.append,
        encoding: utf8,
        flush: true,
      );
    });
    return _writeChain;
  }
}
