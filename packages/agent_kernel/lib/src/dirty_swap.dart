import 'audit_logger.dart';
import 'context_memory.dart';
import 'pcb.dart';
import 'syscall_error.dart';

/// Metadata linking a swapped Dirty Page or its Summary Page to the Swap Store ([D-317]).
class DirtySwapMeta {
  const DirtySwapMeta({
    required this.swapBatchId,
    required this.summaryPageId,
    required this.pid,
  });

  final String swapBatchId;
  final String summaryPageId;
  final Pid pid;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'swapBatchId': swapBatchId,
      'summaryPageId': summaryPageId,
      'pid': pid,
    };
  }
}

/// Atomic range of Segment 1 turns that must be swapped together to preserve `tool_call_id` pairing ([D-316]).
class TurnGroupRange {
  const TurnGroupRange({
    required this.startTurnIndex,
    required this.endTurnIndexInclusive,
    required this.isToolStep,
  }) : assert(startTurnIndex >= 0),
       assert(endTurnIndexInclusive >= startTurnIndex);

  final int startTurnIndex;
  final int endTurnIndexInclusive;
  final bool isToolStep;

  int get length => endTurnIndexInclusive - startTurnIndex + 1;
}

/// JSONL record representing a single Dirty Page persisted to the Swap Store ([D-317]).
class DirtySwapRecord {
  DirtySwapRecord({
    required this.swapBatchId,
    required this.summaryPageId,
    required this.pageId,
    required this.sessionId,
    required this.pid,
    required this.createdAtTurn,
    required this.turnType,
    this.originProvider,
    this.originModel,
    required this.content,
    this.thoughtText,
    List<Map<String, dynamic>> toolCalls = const <Map<String, dynamic>>[],
    this.canonicalCallId,
    this.toolName,
    this.isError = false,
    required this.originalTokens,
    required this.swappedAtUtc,
  }) : toolCalls = List<Map<String, dynamic>>.unmodifiable(
         toolCalls.map((e) => Map<String, dynamic>.unmodifiable(e)),
       );

  factory DirtySwapRecord.fromJson(Map<String, dynamic> json) {
    final rawCalls = json['toolCalls'];
    final calls = rawCalls is List
        ? rawCalls
              .whereType<Map<dynamic, dynamic>>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];

    return DirtySwapRecord(
      swapBatchId: json['swapBatchId'] as String,
      summaryPageId: json['summaryPageId'] as String,
      pageId: json['pageId'] as String,
      sessionId: json['sessionId'] as String,
      pid: json['pid'] as int,
      createdAtTurn: json['createdAtTurn'] as int,
      turnType: json['turnType'] as String,
      originProvider: json['originProvider'] as String?,
      originModel: json['originModel'] as String?,
      content: (json['content'] as String?) ?? '',
      thoughtText: json['thoughtText'] as String?,
      toolCalls: calls,
      canonicalCallId: json['canonicalCallId'] as String?,
      toolName: json['toolName'] as String?,
      isError: (json['isError'] as bool?) ?? false,
      originalTokens: (json['originalTokens'] as int?) ?? 0,
      swappedAtUtc: DateTime.parse(json['swappedAtUtc'] as String).toUtc(),
    );
  }

  final String swapBatchId;
  final String summaryPageId;
  final String pageId;
  final String sessionId;
  final Pid pid;
  final int createdAtTurn;
  final String turnType;
  final String? originProvider;
  final String? originModel;
  final String content;
  final String? thoughtText;
  final List<Map<String, dynamic>> toolCalls;
  final String? canonicalCallId;
  final String? toolName;
  final bool isError;
  final int originalTokens;
  final DateTime swappedAtUtc;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'swapBatchId': swapBatchId,
      'summaryPageId': summaryPageId,
      'pageId': pageId,
      'sessionId': sessionId,
      'pid': pid,
      'createdAtTurn': createdAtTurn,
      'turnType': turnType,
      'originProvider': originProvider,
      'originModel': originModel,
      'content': content,
      'thoughtText': thoughtText,
      'toolCalls': toolCalls,
      'canonicalCallId': canonicalCallId,
      'toolName': toolName,
      'isError': isError,
      'originalTokens': originalTokens,
      'swappedAtUtc': swappedAtUtc.toUtc().toIso8601String(),
    };
  }
}

/// Ring 0 persistence contract for Dirty Page Swap Store write-back and `sys_mem_pagein` reload ([D-317]).
abstract interface class DirtySwapBackend {
  Future<SyscallResult<void>> writeBackTurnGroups({
    required String sessionId,
    Pid pid = 1,
    ProcessControlBlock? pcb,
    required String swapBatchId,
    required String summaryPageId,
    required List<DirtySwapRecord> records,
  });

  Future<SyscallResult<List<DirtySwapRecord>>> readSwappedPages({
    required String sessionId,
    Pid pid = 1,
    ProcessControlBlock? pcb,
    String? pageId,
    String? swapBatchId,
  });
}

/// Abstract Ring 0 interface for generating structured `SummaryPage` text from evicted turns ([D-317]).
abstract interface class DirtyPageSummarizer {
  Future<String> summarize({
    required String summaryPageId,
    required String swapBatchId,
    required List<String> evictedPageIds,
    required int originalTokens,
    required List<CanonicalTurn> turns,
    SecretRedactor? redactor,
  });
}

/// Zero-token deterministic structured summarizer for Dirty Page Swap ([D-317], `B-02`).
class DeterministicDirtyPageSummarizer implements DirtyPageSummarizer {
  const DeterministicDirtyPageSummarizer();

  static const int maxSnippetChars = 240;
  static const int maxSyscallSummaries = 12;

  @override
  Future<String> summarize({
    required String summaryPageId,
    required String swapBatchId,
    required List<String> evictedPageIds,
    required int originalTokens,
    required List<CanonicalTurn> turns,
    SecretRedactor? redactor,
  }) async {
    String redact(String input) =>
        redactor == null ? input : redactor.redactString(input);

    String clip(String input) {
      final singleLine = input.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (singleLine.length <= maxSnippetChars) {
        return singleLine;
      }
      return '${singleLine.substring(0, maxSnippetChars)}...';
    }

    final pageRangeLabel = evictedPageIds.isEmpty
        ? 'none'
        : evictedPageIds.length == 1
            ? evictedPageIds.first
            : '${evictedPageIds.first}..${evictedPageIds.last}';

    final userRequests = <String>[];
    final syscallSummaries = <String>[];
    final assistantConclusions = <String>[];
    final callsById = <String, CanonicalToolCall>{};

    for (final turn in turns) {
      switch (turn) {
        case CanonicalUserTurn(:final text):
          final clean = clip(redact(text));
          if (clean.isNotEmpty) {
            userRequests.add('"$clean"');
          }
        case CanonicalSummaryTurn(:final text):
          final clean = clip(redact(text));
          if (clean.isNotEmpty) {
            assistantConclusions.add('"$clean"');
          }
        case CanonicalAssistantTurn():
          for (final tc in turn.toolCalls) {
            callsById[tc.canonicalCallId] = tc;
          }
          final clean = clip(redact(turn.content));
          if (clean.isNotEmpty) {
            assistantConclusions.add('"$clean"');
          }
        case CanonicalToolResultTurn():
          if (syscallSummaries.length < maxSyscallSummaries) {
            final call = callsById[turn.canonicalCallId];
            final target = _extractSyscallTarget(call?.arguments, redact);
            final status = turn.isError ? 'error' : 'ok';
            final label = target == null
                ? '${turn.toolName}($status)'
                : '${turn.toolName}($target -> $status)';
            syscallSummaries.add(label);
          }
      }
    }

    final lines = <String>[
      '[SummaryPage $summaryPageId | swap=$swapBatchId | evictedPages=$pageRangeLabel (${evictedPageIds.length} pages, orig: $originalTokens tokens)]',
    ];
    if (userRequests.isNotEmpty) {
      lines.add('- User requests: ${userRequests.take(3).join('; ')}');
    }
    if (syscallSummaries.isNotEmpty) {
      lines.add('- Executed syscalls: ${syscallSummaries.join(', ')}');
    }
    if (assistantConclusions.isNotEmpty) {
      lines.add(
        '- Assistant key conclusions: ${assistantConclusions.take(3).join('; ')}',
      );
    }
    lines.add(
      '- Reload full verbatim turns if needed: sys_mem_pagein({"pageId": "$summaryPageId"}) or specific pageId in $pageRangeLabel.',
    );
    return lines.join('\n');
  }

  static String? _extractSyscallTarget(
    Map<String, dynamic>? args,
    String Function(String) redact,
  ) {
    if (args == null || args.isEmpty) {
      return null;
    }
    final path = args['path'];
    if (path is String && path.isNotEmpty) {
      return redact(path);
    }
    final cmd = args['command'];
    if (cmd is String && cmd.isNotEmpty) {
      final rawArgs = args['args'];
      if (rawArgs is List && rawArgs.isNotEmpty) {
        return redact('$cmd ${rawArgs.join(' ')}');
      }
      return redact(cmd);
    }
    final server = args['server'];
    final tool = args['tool'];
    if (server is String && tool is String) {
      return redact('$server:$tool');
    }
    return null;
  }
}
