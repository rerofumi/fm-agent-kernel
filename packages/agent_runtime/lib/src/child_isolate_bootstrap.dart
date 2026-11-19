import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'sub_agent_worker.dart';

/// Sole AOT-compatible entry point for all Ring 3 child [Isolate]s ([D-210]).
///
/// Dart child isolates do NOT inherit the parent isolate's [ZoneSpecification].
/// Wrapping every child isolate at its outermost boundary with [runZonedGuarded]
/// and a `print -> stderr` [ZoneSpecification] guarantees 100% ACP JSON-RPC
/// NDJSON purity on OS FD 1 (`stdout`), even if third-party code or a worker
/// invokes `print()` or throws an uncaught error.
@pragma('vm:entry-point')
void childIsolateEntryPoint(Map<String, Object?> rawInit) {
  runZonedGuarded<void>(
    () {
      unawaited(runSubAgentIsolateWorker(rawInit));
    },
    (Object error, StackTrace stack) {
      stderr.writeln('[agent_os_worker] Unhandled isolate error: $error\n$stack');
      final hostPort = rawInit['hostPort'];
      if (hostPort is SendPort) {
        hostPort.send(<String, Object?>{
          'type': 'worker_fatal',
          'pid': rawInit['pid'],
          'error': error.toString(),
        });
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        stderr.writeln(line);
      },
    ),
  );
}
