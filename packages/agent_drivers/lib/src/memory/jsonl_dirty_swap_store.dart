import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:path/path.dart' as p;

/// JSONL-backed [DirtySwapBackend] persisting evicted Dirty Page Turn Groups
/// under `.agent_os/swap/<safeSessionId>/pid_<effectivePid>/pages.jsonl` ([D-317]).
class JsonlDirtySwapStore implements DirtySwapBackend {
  JsonlDirtySwapStore({
    required this.workspaceHostRoot,
    SecretRedactor? redactor,
  }) : redactor = redactor ?? SecretRedactor();

  final String workspaceHostRoot;
  final SecretRedactor redactor;

  static final RegExp _unsafeSessionChars = RegExp(r'[^a-zA-Z0-9_.-]');

  Future<void> _writeChain = Future<void>.value();

  /// Resolves the sanitized session directory name.
  static String safeSessionId(String sessionId) {
    final cleaned = sessionId.trim().replaceAll(_unsafeSessionChars, '_');
    return cleaned.isEmpty ? 'session' : cleaned;
  }

  /// Resolves the host path to `.agent_os/swap/<safeSessionId>/pid_<pid>/pages.jsonl`.
  String swapFilePath({
    required String sessionId,
    required Pid pid,
  }) {
    return p.join(
      workspaceHostRoot,
      '.agent_os',
      'swap',
      safeSessionId(sessionId),
      'pid_$pid',
      'pages.jsonl',
    );
  }

  @override
  Future<SyscallResult<void>> writeBackTurnGroups({
    required String sessionId,
    Pid pid = 1,
    ProcessControlBlock? pcb,
    required String swapBatchId,
    required String summaryPageId,
    required List<DirtySwapRecord> records,
  }) async {
    if (records.isEmpty) {
      return const SyscallResult<void>.success(null);
    }

    final effectivePid = pcb?.pid ?? pid;
    final targetPath = swapFilePath(sessionId: sessionId, pid: effectivePid);

    final linesBuffer = StringBuffer();
    for (final record in records) {
      final redacted =
          redactor.redactJson(record.toJson()) as Map<String, dynamic>;
      linesBuffer.writeln(jsonEncode(redacted));
    }
    final payload = linesBuffer.toString();

    final completer = Completer<SyscallResult<void>>();
    _writeChain = _writeChain.then((_) async {
      try {
        ensureAgentOsGitignoreSync(workspaceHostRoot);
        final file = File(targetPath);
        if (!file.parent.existsSync()) {
          await file.parent.create(recursive: true);
        }
        await file.writeAsString(
          payload,
          mode: FileMode.append,
          encoding: utf8,
          flush: true,
        );
        completer.complete(const SyscallResult<void>.success(null));
      } on FileSystemException catch (e) {
        completer.complete(
          SyscallResult<void>.failure(
            SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'SWAP_WRITE_FAILED',
              message:
                  'Failed to persist Dirty Page Swap batch $swapBatchId: ${e.message}',
              recoverable: true,
            ),
          ),
        );
      } catch (e) {
        completer.complete(
          SyscallResult<void>.failure(
            SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'SWAP_WRITE_FAILED',
              message:
                  'Failed to persist Dirty Page Swap batch $swapBatchId: $e',
              recoverable: true,
            ),
          ),
        );
      }
    });

    return completer.future;
  }

  @override
  Future<SyscallResult<List<DirtySwapRecord>>> readSwappedPages({
    required String sessionId,
    Pid pid = 1,
    ProcessControlBlock? pcb,
    String? pageId,
    String? swapBatchId,
  }) async {
    // Ensure any pending writes on this store have flushed before reading.
    await _writeChain;

    final effectivePid = pcb?.pid ?? pid;
    final targetPath = swapFilePath(sessionId: sessionId, pid: effectivePid);
    final file = File(targetPath);

    if (!file.existsSync()) {
      return SyscallResult<List<DirtySwapRecord>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'SWAP_RECORD_NOT_FOUND',
          message:
              'Swap store file for session "$sessionId" (pid=$effectivePid) was not found.',
          recoverable: true,
        ),
      );
    }

    final List<String> lines;
    try {
      lines = await file.readAsLines(encoding: utf8);
    } on FileSystemException catch (e) {
      return SyscallResult<List<DirtySwapRecord>>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'SWAP_CORRUPTED',
          message: 'Failed to read swap store file: ${e.message}',
          recoverable: true,
        ),
      );
    }

    final matched = <DirtySwapRecord>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          return SyscallResult<List<DirtySwapRecord>>.failure(
            SyscallError(
              code: SyscallErrorCode.eio,
              reason: 'SWAP_CORRUPTED',
              message:
                  'Swap store line ${i + 1} is not a JSON object.',
              recoverable: false,
            ),
          );
        }
        final record = DirtySwapRecord.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        if (pageId != null && record.pageId != pageId) {
          continue;
        }
        if (swapBatchId != null && record.swapBatchId != swapBatchId) {
          continue;
        }
        matched.add(record);
      } catch (e) {
        return SyscallResult<List<DirtySwapRecord>>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'SWAP_CORRUPTED',
            message: 'Corrupted swap store record at line ${i + 1}: $e',
            recoverable: false,
          ),
        );
      }
    }

    if (matched.isEmpty) {
      return SyscallResult<List<DirtySwapRecord>>.failure(
        SyscallError(
          code: SyscallErrorCode.enoent,
          reason: 'SWAP_RECORD_NOT_FOUND',
          message:
              'No swapped Dirty Page record matched pageId="$pageId", swapBatchId="$swapBatchId".',
          recoverable: true,
        ),
      );
    }

    return SyscallResult<List<DirtySwapRecord>>.success(
      List<DirtySwapRecord>.unmodifiable(matched),
    );
  }
}
