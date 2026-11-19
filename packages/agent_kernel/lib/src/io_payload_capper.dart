import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// Ensures `<workspaceHostRoot>/.agent_os/.gitignore` exists with `*\n` ([D-003]).
void ensureAgentOsGitignoreSync(String workspaceHostRoot) {
  final agentOsDir = Directory(p.join(workspaceHostRoot, '.agent_os'));
  if (!agentOsDir.existsSync()) {
    agentOsDir.createSync(recursive: true);
  }
  final gitignoreFile = File(p.join(agentOsDir.path, '.gitignore'));
  const expectedContent = '*\n';
  if (!gitignoreFile.existsSync() ||
      gitignoreFile.readAsStringSync() != expectedContent) {
    gitignoreFile.writeAsStringSync(expectedContent, flush: true);
  }
}

/// Configuration thresholds for [IoPayloadCapper] ([D-006]).
class IoCapConfig {
  const IoCapConfig({
    this.maxLines = 200,
    int? headLines,
    int? tailLines,
    this.maxUtf8Bytes = 16384,
    int? headUtf8Bytes,
    int? tailUtf8Bytes,
  })  : headLines = headLines ?? (maxLines == 200 ? 140 : (maxLines * 7) ~/ 10),
        tailLines = tailLines ??
            (maxLines == 200
                ? 60
                : maxLines - ((maxLines * 7) ~/ 10)),
        headUtf8Bytes = headUtf8Bytes ??
            (maxUtf8Bytes == 16384 ? 11264 : (maxUtf8Bytes * 11) ~/ 16),
        tailUtf8Bytes = tailUtf8Bytes ??
            (maxUtf8Bytes == 16384
                ? 4096
                : maxUtf8Bytes - ((maxUtf8Bytes * 11) ~/ 16)),
        assert(maxLines >= 2),
        assert(maxUtf8Bytes >= 64);

  final int maxLines;
  final int headLines;
  final int tailLines;
  final int maxUtf8Bytes;
  final int headUtf8Bytes;
  final int tailUtf8Bytes;
}

/// Result of applying [IoPayloadCapper] to a text payload ([D-006]).
class IoCapResult {
  const IoCapResult({
    required this.text,
    required this.truncated,
    required this.originalLines,
    required this.originalBytes,
    required this.omittedLines,
    required this.omittedBytes,
    this.spillPath,
  });

  final String text;
  final bool truncated;
  final int originalLines;
  final int originalBytes;
  final int omittedLines;
  final int omittedBytes;

  /// Virtual path (`/workspace/.agent_os/io_spill/...`) where the full payload was saved when truncated.
  final String? spillPath;
}

/// Deterministic kernel I/O output size capper preventing single-turn context overflow ([D-006]).
class IoPayloadCapper {
  IoPayloadCapper({
    this.config = const IoCapConfig(),
    this.workspaceHostRoot,
  });

  final IoCapConfig config;
  final String? workspaceHostRoot;

  static final RegExp _unsafeFileNameChars = RegExp(r'[^a-zA-Z0-9_.-]');

  /// Applies line and UTF-8 byte limits to [text], spilling full content on overflow ([D-006]).
  Future<IoCapResult> capText({
    required String text,
    required String sessionId,
    required int syscallSeq,
    required String syscallName,
    String fieldSuffix = '',
  }) async {
    final lines = text.isEmpty ? const <String>[] : const LineSplitter().convert(text);
    final originalLines = lines.length;
    final originalBytes = utf8.encode(text).length;

    if (originalLines <= config.maxLines && originalBytes <= config.maxUtf8Bytes) {
      return IoCapResult(
        text: text,
        truncated: false,
        originalLines: originalLines,
        originalBytes: originalBytes,
        omittedLines: 0,
        omittedBytes: 0,
        spillPath: null,
      );
    }

    final spillPath = await _writeSpillFile(
      text: text,
      sessionId: sessionId,
      syscallSeq: syscallSeq,
      syscallName: syscallName,
      fieldSuffix: fieldSuffix,
    );

    String headText;
    String tailText;
    int keptLines;

    if (originalLines > config.maxLines) {
      final safeHeadCount = math.min(config.headLines, originalLines);
      final safeTailCount =
          math.min(config.tailLines, math.max(0, originalLines - safeHeadCount));
      headText = lines.take(safeHeadCount).join('\n');
      tailText = safeTailCount > 0
          ? lines.skip(originalLines - safeTailCount).join('\n')
          : '';
      keptLines = safeHeadCount + safeTailCount;

      final combinedBytes =
          utf8.encode(headText).length + utf8.encode(tailText).length;
      if (combinedBytes > config.maxUtf8Bytes) {
        headText = _sliceUtf8Head(headText, config.headUtf8Bytes);
        tailText = _sliceUtf8Tail(tailText, config.tailUtf8Bytes);
        keptLines = _countLines(headText) + _countLines(tailText);
      }
    } else {
      // Single-line or few-line payload exceeding UTF-8 byte cap.
      headText = _sliceUtf8Head(text, config.headUtf8Bytes);
      tailText = _sliceUtf8Tail(text, config.tailUtf8Bytes);
      keptLines = originalLines <= 1
          ? originalLines
          : math.min(originalLines, _countLines(headText) + _countLines(tailText));
    }

    final keptBytes = utf8.encode(headText).length + utf8.encode(tailText).length;
    final omittedLines = math.max(0, originalLines - keptLines);
    final omittedBytes = math.max(0, originalBytes - keptBytes);

    final notice =
        '... [KERNEL I/O CAP: omitted $omittedLines lines ($omittedBytes bytes) '
        'out of $originalLines lines ($originalBytes bytes). '
        'Narrow range with sys_read_lines(startLine, endLine) or refine pattern.] ...';

    final buffer = StringBuffer();
    if (headText.isNotEmpty) {
      buffer.write(headText);
      buffer.write('\n');
    }
    buffer.write(notice);
    if (tailText.isNotEmpty) {
      buffer.write('\n');
      buffer.write(tailText);
    }

    return IoCapResult(
      text: buffer.toString(),
      truncated: true,
      originalLines: originalLines,
      originalBytes: originalBytes,
      omittedLines: omittedLines,
      omittedBytes: omittedBytes,
      spillPath: spillPath,
    );
  }

  /// Caps only designated [textFields] inside a structured syscall output map, preserving metadata ([D-006]).
  Future<({Map<String, dynamic> payload, bool truncated})> capStructuredPayload({
    required Map<String, dynamic> payload,
    required List<String> textFields,
    required String sessionId,
    required int syscallSeq,
    required String syscallName,
  }) async {
    if (textFields.isEmpty) {
      return (payload: payload, truncated: false);
    }

    final updated = Map<String, dynamic>.from(payload);
    var anyTruncated = false;

    for (final field in textFields) {
      final rawValue = updated[field];
      if (rawValue is String) {
        final suffix = textFields.length > 1 ? field : '';
        final capped = await capText(
          text: rawValue,
          sessionId: sessionId,
          syscallSeq: syscallSeq,
          syscallName: syscallName,
          fieldSuffix: suffix,
        );
        updated[field] = capped.text;
        if (field == 'stdout') {
          updated['truncatedStdout'] = capped.truncated;
        } else if (field == 'stderr') {
          updated['truncatedStderr'] = capped.truncated;
        }
        if (capped.truncated) {
          anyTruncated = true;
          updated['truncated'] = true;
          updated['originalLines'] = capped.originalLines;
          updated['originalBytes'] = capped.originalBytes;
          updated['omittedLines'] = capped.omittedLines;
          updated['omittedBytes'] = capped.omittedBytes;
          if (capped.spillPath != null) {
            updated['spillPath'] = capped.spillPath;
          }
        }
      } else if (rawValue is List<dynamic>) {
        final lineStrings = rawValue
            .map((e) => e is String ? e : jsonEncode(e))
            .toList(growable: false);
        final joined = lineStrings.join('\n');
        final suffix = textFields.length > 1 ? field : '';
        final capped = await capText(
          text: joined,
          sessionId: sessionId,
          syscallSeq: syscallSeq,
          syscallName: syscallName,
          fieldSuffix: suffix,
        );
        if (capped.truncated) {
          anyTruncated = true;
          final keptHead = math.min(config.headLines, rawValue.length);
          final keptTail = math.min(
            config.tailLines,
            math.max(0, rawValue.length - keptHead),
          );
          final sliced = <dynamic>[
            ...rawValue.take(keptHead),
            if (keptTail > 0) ...rawValue.skip(rawValue.length - keptTail),
          ];
          updated[field] = sliced;
          updated['truncated'] = true;
          updated['originalCount'] = rawValue.length;
          updated['omittedCount'] =
              math.max(0, rawValue.length - sliced.length);
          updated['originalBytes'] = capped.originalBytes;
          updated['omittedBytes'] = capped.omittedBytes;
          updated['capNotice'] =
              '... [KERNEL I/O CAP: omitted ${rawValue.length - sliced.length} items '
              '(${capped.omittedBytes} bytes) out of ${rawValue.length} items.] ...';
          if (capped.spillPath != null) {
            updated['spillPath'] = capped.spillPath;
          }
        }
      }
    }

    if (!anyTruncated && !updated.containsKey('truncated')) {
      updated['truncated'] = false;
    }

    return (payload: updated, truncated: anyTruncated);
  }

  Future<String?> _writeSpillFile({
    required String text,
    required String sessionId,
    required int syscallSeq,
    required String syscallName,
    required String fieldSuffix,
  }) async {
    final safeSession = sessionId.replaceAll(_unsafeFileNameChars, '_');
    final safeSyscall = syscallName.replaceAll(_unsafeFileNameChars, '_');
    final safeSuffix = fieldSuffix.isEmpty
        ? ''
        : '_${fieldSuffix.replaceAll(_unsafeFileNameChars, '_')}';
    final fileName = '${syscallSeq}_$safeSyscall$safeSuffix.txt';
    final virtualSpillPath = '/workspace/.agent_os/io_spill/$safeSession/$fileName';

    final hostRoot = workspaceHostRoot;
    if (hostRoot == null || hostRoot.isEmpty) {
      return virtualSpillPath;
    }

    ensureAgentOsGitignoreSync(hostRoot);
    final spillDir = Directory(p.join(hostRoot, '.agent_os', 'io_spill', safeSession));
    if (!spillDir.existsSync()) {
      await spillDir.create(recursive: true);
    }
    final spillFile = File(p.join(spillDir.path, fileName));
    await spillFile.writeAsString(text, flush: true);
    return virtualSpillPath;
  }

  static int _countLines(String text) {
    if (text.isEmpty) {
      return 0;
    }
    return const LineSplitter().convert(text).length;
  }

  /// Decodes up to [maxBytes] from the start of [text] without splitting a UTF-8 code point.
  static String _sliceUtf8Head(String text, int maxBytes) {
    if (maxBytes <= 0 || text.isEmpty) {
      return '';
    }
    final bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) {
      return text;
    }
    var end = maxBytes;
    // Step back across any UTF-8 continuation bytes (`10xxxxxx`) or partial multi-byte leader.
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(bytes.sublist(0, end), allowMalformed: false);
  }

  /// Decodes up to [maxBytes] from the end of [text] without splitting a UTF-8 code point.
  static String _sliceUtf8Tail(String text, int maxBytes) {
    if (maxBytes <= 0 || text.isEmpty) {
      return '';
    }
    final bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) {
      return text;
    }
    var start = bytes.length - maxBytes;
    // Advance forward past any UTF-8 continuation bytes (`10xxxxxx`) so start aligns to a rune boundary.
    while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
      start++;
    }
    return utf8.decode(bytes.sublist(start), allowMalformed: false);
  }
}
