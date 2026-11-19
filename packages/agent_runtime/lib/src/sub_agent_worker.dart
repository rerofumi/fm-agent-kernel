import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_kernel/agent_kernel.dart';

import 'child_isolate_bootstrap.dart';

/// Abstraction for invoking host-kernel syscalls from a Ring 3 child worker ([D-210]).
abstract interface class RemoteSyscallInvoker {
  /// Invokes [name] with [args] through the host [SyscallGate].
  ///
  /// When [canonicalCallId] is provided, the host records the tool result in the
  /// child's [VirtualContextMemory] Segment 1 for 1:1 `tool_call_id` pairing.
  Future<SyscallResult<Map<String, dynamic>>> invoke(
    String name,
    Map<String, dynamic> args, {
    String? canonicalCallId,
  });

  /// Appends synthetic error tool results on the host for unexecuted trailing tool calls
  /// when a step aborts mid-way due to fatal `EDQUOT` or `ECANCELLED` ([D-214]).
  Future<void> abortRemainingToolCalls(
    List<Map<String, dynamic>> remainingCalls,
    SyscallError abortError,
  );
}

/// Terminal outcome emitted by a Ring 3 [SubAgentWorker] loop.
class ChildWorkerExitReport {
  const ChildWorkerExitReport({
    required this.ok,
    required this.exitCode,
    required this.reason,
    this.errorCode,
    required this.summary,
  });

  final bool ok;
  final int exitCode;
  final String reason;
  final String? errorCode;
  final String summary;

  Map<String, Object?> toPrimitiveMap(Pid pid) {
    return <String, Object?>{
      'type': 'worker_done',
      'pid': pid,
      'ok': ok,
      'exitCode': exitCode,
      'reason': reason,
      'errorCode': errorCode,
      'summary': summary,
    };
  }
}

/// Ring 3 child worker ReAct loop shared identically across [IsolateChildWorkerBackend]
/// and [GreenTaskChildWorkerBackend] ([D-210], [D-211], [D-214]).
class SubAgentWorker {
  SubAgentWorker({
    required this.pid,
    required this.profile,
    required this.model,
    required this.taskPrompt,
    required this.maxSteps,
    required this.invoker,
    this.cancelToken,
  });

  final Pid pid;
  final String profile;
  final String model;
  final String taskPrompt;
  final int maxSteps;
  final RemoteSyscallInvoker invoker;
  final CancellationToken? cancelToken;

  /// Runs the Ring 3 ReAct loop until `sys_exit`, final text response, fatal `EDQUOT`, or cancellation.
  Future<ChildWorkerExitReport> run() async {
    var step = 0;
    var lastPartialContent = '';

    while (step < maxSteps) {
      if (cancelToken?.isCancelled ?? false) {
        return ChildWorkerExitReport(
          ok: false,
          exitCode: 130,
          reason: 'CANCELLED',
          errorCode: SyscallErrorCode.ecancelled.codeName,
          summary: _summaryWithNotice(
            lastPartialContent,
            'Child worker cancelled before next ReAct step.',
          ),
        );
      }

      step += 1;
      final llmRes = await invoker.invoke(
        'sys_llm_chat',
        <String, dynamic>{
          'model': model,
          'turnIndex': step,
          'stream': false,
        },
      );

      if (!llmRes.ok) {
        final err = llmRes.error!;
        final exitCode = err.code == SyscallErrorCode.edquot
            ? 77
            : (err.code == SyscallErrorCode.ecancelled ? 130 : 1);
        return ChildWorkerExitReport(
          ok: false,
          exitCode: exitCode,
          reason: err.reason,
          errorCode: err.code.codeName,
          summary: _summaryWithNotice(
            lastPartialContent,
            '${err.code.codeName} (${err.reason}): ${err.message}',
          ),
        );
      }

      final payload = llmRes.value ?? const <String, dynamic>{};
      final content = (payload['content'] as String?) ?? '';
      if (content.trim().isNotEmpty) {
        lastPartialContent = content.trim();
      }

      final rawToolCalls =
          (payload['toolCalls'] as List<dynamic>?) ?? const <dynamic>[];
      final normalizedCalls = <Map<String, dynamic>>[];
      for (final item in rawToolCalls) {
        if (item is Map) {
          normalizedCalls.add(Map<String, dynamic>.from(item));
        }
      }

      // [D-214] §5.3(3): Post-inference token/cost quota reached with pending tool calls.
      final postQuotaErrRaw = payload['postUsageQuotaError'];
      if (postQuotaErrRaw is Map) {
        final postErr = _decodeSyscallError(
          Map<String, dynamic>.from(postQuotaErrRaw),
        );
        return ChildWorkerExitReport(
          ok: false,
          exitCode: 77,
          reason: postErr.reason,
          errorCode: postErr.code.codeName,
          summary: _summaryWithNotice(
            lastPartialContent,
            '${postErr.code.codeName} (${postErr.reason}): ${postErr.message}',
          ),
        );
      }

      // [D-211] §2.3(3): Final text response without tool calls triggers implicit sys_exit(0).
      if (normalizedCalls.isEmpty) {
        final exitRes = await invoker.invoke(
          'sys_exit',
          <String, dynamic>{
            'exitCode': 0,
            'summary': content,
          },
        );
        if (exitRes.ok) {
          return ChildWorkerExitReport(
            ok: true,
            exitCode: 0,
            reason: 'EXITED_NORMALLY',
            summary: content,
          );
        }
        final err = exitRes.error!;
        return ChildWorkerExitReport(
          ok: false,
          exitCode: err.code == SyscallErrorCode.edquot ? 77 : 1,
          reason: err.reason,
          errorCode: err.code.codeName,
          summary: _summaryWithNotice(content, err.message),
        );
      }

      for (var i = 0; i < normalizedCalls.length; i++) {
        final tc = normalizedCalls[i];
        final tcId = (tc['canonicalCallId'] as String?) ??
            (tc['id'] as String?) ??
            'sc_${step}_${i + 1}';
        final tcName = (tc['name'] as String?) ?? '';
        final rawArgs = tc['arguments'];
        final tcArgs = rawArgs is Map
            ? Map<String, dynamic>.from(rawArgs)
            : const <String, dynamic>{};

        if (cancelToken?.isCancelled ?? false) {
          const abortErr = SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'CANCELLED',
            message: 'Child worker cancelled before executing tool call.',
            recoverable: true,
          );
          await invoker.abortRemainingToolCalls(
            normalizedCalls.sublist(i),
            abortErr,
          );
          return ChildWorkerExitReport(
            ok: false,
            exitCode: 130,
            reason: abortErr.reason,
            errorCode: abortErr.code.codeName,
            summary: _summaryWithNotice(lastPartialContent, abortErr.message),
          );
        }

        final toolRes = await invoker.invoke(
          tcName,
          tcArgs,
          canonicalCallId: tcId,
        );

        if (tcName == 'sys_exit' && toolRes.ok) {
          final exitCode = (tcArgs['exitCode'] as num?)?.toInt() ?? 0;
          final summary = (tcArgs['summary'] as String?) ?? lastPartialContent;
          return ChildWorkerExitReport(
            ok: exitCode == 0,
            exitCode: exitCode,
            reason: exitCode == 0 ? 'EXITED_NORMALLY' : 'EXITED_WITH_ERROR',
            summary: summary,
          );
        }

        if (!toolRes.ok) {
          final err = toolRes.error!;
          final isFatalQuota =
              err.code == SyscallErrorCode.edquot && !err.recoverable;
          final isCancelled = err.code == SyscallErrorCode.ecancelled;
          if (isFatalQuota || isCancelled) {
            if (i + 1 < normalizedCalls.length) {
              await invoker.abortRemainingToolCalls(
                normalizedCalls.sublist(i + 1),
                err,
              );
            }
            return ChildWorkerExitReport(
              ok: false,
              exitCode: isFatalQuota ? 77 : 130,
              reason: err.reason,
              errorCode: err.code.codeName,
              summary: _summaryWithNotice(
                lastPartialContent,
                '${err.code.codeName} (${err.reason}): ${err.message}',
              ),
            );
          }
        }
      }
    }

    return ChildWorkerExitReport(
      ok: false,
      exitCode: 77,
      reason: 'MAX_STEPS_EXCEEDED',
      errorCode: SyscallErrorCode.edquot.codeName,
      summary: _summaryWithNotice(
        lastPartialContent,
        'Child worker exceeded maxSteps ($maxSteps) without exiting.',
      ),
    );
  }

  static String _summaryWithNotice(String partial, String notice) {
    final trimmed = partial.trim();
    if (trimmed.isEmpty) {
      return notice;
    }
    return '$trimmed\n[$notice]';
  }
}

/// RPC-based [RemoteSyscallInvoker] communicating strictly with primitive Isolate messages ([D-210]).
class IsolateRemoteSyscallInvoker implements RemoteSyscallInvoker {
  IsolateRemoteSyscallInvoker({
    required this.pid,
    required this.capHandleId,
    required this.sessionId,
    required this.hostPort,
    required this.controlPort,
    required this.cancelSource,
  }) {
    _sub = controlPort.listen(_onControlMessage);
  }

  final Pid pid;
  final String capHandleId;
  final String sessionId;
  final SendPort hostPort;
  final ReceivePort controlPort;
  final CancellationTokenSource cancelSource;

  late final StreamSubscription<dynamic> _sub;
  final Map<int, Completer<SyscallResult<Map<String, dynamic>>>> _pending =
      <int, Completer<SyscallResult<Map<String, dynamic>>>>{};
  int _nextReqId = 0;
  bool _closed = false;

  void _onControlMessage(dynamic message) {
    if (message is! Map) {
      return;
    }
    final type = message['type'];
    if (type == 'syscall_resp') {
      final reqId = message['reqId'];
      if (reqId is! int) {
        return;
      }
      final completer = _pending.remove(reqId);
      if (completer == null || completer.isCompleted) {
        return;
      }
      final ok = message['ok'] == true;
      if (ok) {
        final rawValue = message['value'];
        final mapVal = rawValue is Map
            ? deepCopyJsonMap(rawValue)
            : <String, dynamic>{};
        completer.complete(SyscallResult<Map<String, dynamic>>.success(mapVal));
      } else {
        final rawErr = message['error'];
        final err = rawErr is Map
            ? _decodeSyscallError(deepCopyJsonMap(rawErr))
            : const SyscallError(
                code: SyscallErrorCode.eio,
                reason: 'MALFORMED_RPC_ERROR',
                message: 'Host returned an invalid syscall error payload.',
                recoverable: false,
              );
        completer.complete(SyscallResult<Map<String, dynamic>>.failure(err));
      }
    } else if (type == 'cancel') {
      final reason = message['reason'] as String?;
      cancelSource.cancel(reason ?? 'Cancelled by host');
      final pendingCopy = List<Completer<SyscallResult<Map<String, dynamic>>>>.from(
        _pending.values,
      );
      _pending.clear();
      const cancelErr = SyscallError(
        code: SyscallErrorCode.ecancelled,
        reason: 'CANCELLED',
        message: 'Syscall cancelled by host.',
        recoverable: true,
      );
      for (final c in pendingCopy) {
        if (!c.isCompleted) {
          c.complete(const SyscallResult<Map<String, dynamic>>.failure(cancelErr));
        }
      }
    }
  }

  @override
  Future<SyscallResult<Map<String, dynamic>>> invoke(
    String name,
    Map<String, dynamic> args, {
    String? canonicalCallId,
  }) {
    if (_closed || cancelSource.token.isCancelled) {
      return Future<SyscallResult<Map<String, dynamic>>>.value(
        const SyscallResult<Map<String, dynamic>>.failure(
          SyscallError(
            code: SyscallErrorCode.ecancelled,
            reason: 'CANCELLED',
            message: 'Worker invoker is closed or cancelled.',
            recoverable: true,
          ),
        ),
      );
    }

    final reqId = ++_nextReqId;
    final completer = Completer<SyscallResult<Map<String, dynamic>>>();
    _pending[reqId] = completer;

    hostPort.send(<String, Object?>{
      'type': 'syscall_req',
      'reqId': reqId,
      'pid': pid,
      'capHandleId': capHandleId,
      'sessionId': sessionId,
      'name': name,
      'args': sanitizeToPrimitives(args),
      'canonicalCallId': ?canonicalCallId,
    });

    return completer.future;
  }

  @override
  Future<void> abortRemainingToolCalls(
    List<Map<String, dynamic>> remainingCalls,
    SyscallError abortError,
  ) async {
    if (_closed) {
      return;
    }
    hostPort.send(<String, Object?>{
      'type': 'abort_remaining_tool_calls',
      'pid': pid,
      'remainingCalls': sanitizeToPrimitives(remainingCalls),
      'error': sanitizeToPrimitives(abortError.toJson()),
    });
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _sub.cancel();
    controlPort.close();
  }
}

/// Top-level worker runner invoked inside [childIsolateEntryPoint]'s `runZonedGuarded` ([D-210]).
Future<void> runSubAgentIsolateWorker(Map<String, Object?> rawInit) async {
  final hostPort = rawInit['hostPort'];
  final pid = rawInit['pid'];
  if (hostPort is! SendPort || pid is! int) {
    stderr.writeln('[agent_os_worker] Missing hostPort or pid in rawInit.');
    return;
  }

  final diagnosticMode = rawInit['diagnosticMode'];
  if (diagnosticMode is String && diagnosticMode.isNotEmpty) {
    // Diagnostic hook used exclusively by AOT stdout purity verification tests ([D-210]).
    if (diagnosticMode == 'print_and_throw') {
      // ignore: avoid_print
      print('CHILD_ISOLATE_DIAGNOSTIC_PRINT_PID_$pid');
      throw StateError('Intentional child isolate uncaught error (pid=$pid)');
    }
    if (diagnosticMode == 'spin') {
      // Wait forever until Isolate.kill(priority: immediate) terminates this isolate.
      final never = Completer<void>();
      await never.future;
      return;
    }
  }

  final capHandleId = (rawInit['capHandleId'] as String?) ?? 'cap_child';
  final sessionId = (rawInit['sessionId'] as String?) ?? 'session';
  final profile = (rawInit['profile'] as String?) ?? 'explorer';
  final model = (rawInit['model'] as String?) ?? '';
  final taskPrompt = (rawInit['taskPrompt'] as String?) ?? '';
  final maxSteps = (rawInit['maxSteps'] as int?) ?? SpawnSpec.defaultMaxSteps;

  final controlPort = ReceivePort();
  final cancelSource = CancellationTokenSource();
  final invoker = IsolateRemoteSyscallInvoker(
    pid: pid,
    capHandleId: capHandleId,
    sessionId: sessionId,
    hostPort: hostPort,
    controlPort: controlPort,
    cancelSource: cancelSource,
  );

  // Handshake: send worker control SendPort back to host.
  hostPort.send(<String, Object?>{
    'type': 'worker_ready',
    'pid': pid,
    'controlPort': controlPort.sendPort,
  });

  try {
    final worker = SubAgentWorker(
      pid: pid,
      profile: profile,
      model: model,
      taskPrompt: taskPrompt,
      maxSteps: maxSteps,
      invoker: invoker,
      cancelToken: cancelSource.token,
    );
    final report = await worker.run();
    hostPort.send(report.toPrimitiveMap(pid));
  } finally {
    await invoker.close();
  }
}

/// Launch configuration passed to [ChildWorkerBackend.spawn] ([D-210]).
class ChildWorkerLaunchConfig {
  const ChildWorkerLaunchConfig({
    required this.pid,
    required this.capHandleId,
    required this.sessionId,
    required this.profile,
    required this.model,
    required this.taskPrompt,
    required this.maxSteps,
    required this.hostPort,
    required this.directInvoker,
    required this.onWorkerDone,
    required this.onWorkerFatal,
    this.diagnosticMode,
  });

  final Pid pid;
  final String capHandleId;
  final String sessionId;
  final String profile;
  final String model;
  final String taskPrompt;
  final int maxSteps;
  final SendPort hostPort;
  final RemoteSyscallInvoker directInvoker;
  final void Function(ChildWorkerExitReport report) onWorkerDone;
  final void Function(String error) onWorkerFatal;
  final String? diagnosticMode;
}

/// Handle for controlling a spawned Ring 3 child worker ([D-210]).
abstract interface class ChildWorkerHandle {
  /// Sends a cooperative cancellation signal to the child worker.
  void sendCancel(String reason);

  /// Immediately terminates the child worker (`Isolate.kill(priority: immediate)` in Isolate mode).
  Future<void> killImmediate();
}

/// Execution backend abstraction supporting production Dart [Isolate]s and fast [GreenTask] tests ([D-210]).
abstract interface class ChildWorkerBackend {
  Future<ChildWorkerHandle> spawn(ChildWorkerLaunchConfig config);
}

/// Production backend executing each Ring 3 child in an isolated Dart [Isolate] ([D-210]).
class IsolateChildWorkerBackend implements ChildWorkerBackend {
  const IsolateChildWorkerBackend();

  @override
  Future<ChildWorkerHandle> spawn(ChildWorkerLaunchConfig config) async {
    final onErrorPort = ReceivePort();
    final onExitPort = ReceivePort();

    final rawInit = <String, Object?>{
      'hostPort': config.hostPort,
      'pid': config.pid,
      'capHandleId': config.capHandleId,
      'sessionId': config.sessionId,
      'profile': config.profile,
      'model': config.model,
      'taskPrompt': config.taskPrompt,
      'maxSteps': config.maxSteps,
      if (config.diagnosticMode != null)
        'diagnosticMode': config.diagnosticMode,
    };

    final isolate = await Isolate.spawn<Map<String, Object?>>(
      childIsolateEntryPoint,
      rawInit,
      onError: onErrorPort.sendPort,
      onExit: onExitPort.sendPort,
      errorsAreFatal: true,
      debugName: 'agent_os_${config.profile}_${config.pid}',
    );

    final handle = _IsolateChildWorkerHandle(
      isolate: isolate,
      onErrorPort: onErrorPort,
      onExitPort: onExitPort,
      onWorkerFatal: config.onWorkerFatal,
    );
    return handle;
  }
}

class _IsolateChildWorkerHandle implements ChildWorkerHandle {
  _IsolateChildWorkerHandle({
    required this.isolate,
    required this.onErrorPort,
    required this.onExitPort,
    required void Function(String error) onWorkerFatal,
  }) {
    _errorSub = onErrorPort.listen((dynamic message) {
      if (_disposed) {
        return;
      }
      final errText = message is List && message.isNotEmpty
          ? '${message.first}'
          : '$message';
      onWorkerFatal(errText);
    });
    _exitSub = onExitPort.listen((dynamic _) {
      if (!_exitCompleter.isCompleted) {
        _exitCompleter.complete();
      }
      unawaited(_closePorts());
    });
  }

  final Isolate isolate;
  final ReceivePort onErrorPort;
  final ReceivePort onExitPort;
  late final StreamSubscription<dynamic> _errorSub;
  late final StreamSubscription<dynamic> _exitSub;
  final Completer<void> _exitCompleter = Completer<void>();

  SendPort? controlSendPort;
  bool _disposed = false;

  void attachControlPort(SendPort port) {
    controlSendPort = port;
  }

  @override
  void sendCancel(String reason) {
    final port = controlSendPort;
    if (port != null) {
      port.send(<String, Object?>{
        'type': 'cancel',
        'reason': reason,
      });
    }
  }

  @override
  Future<void> killImmediate() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      isolate.kill(priority: Isolate.immediate);
    } catch (_) {
      // Isolate may have already exited.
    }
    await _exitCompleter.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    await _closePorts();
  }

  Future<void> _closePorts() async {
    await _errorSub.cancel();
    await _exitSub.cancel();
    onErrorPort.close();
    onExitPort.close();
  }
}

/// Deterministic in-host-isolate backend for fast unit testing using the exact same [SubAgentWorker] ([D-210]).
class GreenTaskChildWorkerBackend implements ChildWorkerBackend {
  const GreenTaskChildWorkerBackend();

  @override
  Future<ChildWorkerHandle> spawn(ChildWorkerLaunchConfig config) async {
    final cancelSource = CancellationTokenSource();
    final handle = _GreenTaskChildWorkerHandle(cancelSource);

    runZonedGuarded<void>(
      () {
        unawaited(() async {
          if (config.diagnosticMode == 'print_and_throw') {
            // ignore: avoid_print
            print('CHILD_GREEN_DIAGNOSTIC_PRINT_PID_${config.pid}');
            throw StateError(
              'Intentional green-task worker error (pid=${config.pid})',
            );
          }
          if (config.diagnosticMode == 'spin') {
            await cancelSource.token.onCancel;
            return;
          }

          final worker = SubAgentWorker(
            pid: config.pid,
            profile: config.profile,
            model: config.model,
            taskPrompt: config.taskPrompt,
            maxSteps: config.maxSteps,
            invoker: config.directInvoker,
            cancelToken: cancelSource.token,
          );
          final report = await worker.run();
          config.onWorkerDone(report);
        }());
      },
      (Object error, StackTrace stack) {
        stderr.writeln(
          '[agent_os_green_worker] Unhandled error (pid=${config.pid}): $error\n$stack',
        );
        config.onWorkerFatal(error.toString());
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
          stderr.writeln(line);
        },
      ),
    );

    return handle;
  }
}

class _GreenTaskChildWorkerHandle implements ChildWorkerHandle {
  _GreenTaskChildWorkerHandle(this._cancelSource);

  final CancellationTokenSource _cancelSource;

  @override
  void sendCancel(String reason) {
    _cancelSource.cancel(reason);
  }

  @override
  Future<void> killImmediate() async {
    _cancelSource.cancel('Killed immediately');
  }
}

/// Helper to bind a discovered control [SendPort] on an isolate worker handle.
void attachWorkerControlPort(ChildWorkerHandle handle, SendPort port) {
  if (handle is _IsolateChildWorkerHandle) {
    handle.attachControlPort(port);
  }
}

/// Recursively converts arbitrary JSON-like values into Isolate-safe primitives ([D-210]).
Object? sanitizeToPrimitives(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is SendPort || value is TransferableTypedData) {
    return value;
  }
  if (value is Map) {
    final out = <String, Object?>{};
    value.forEach((k, v) {
      out[k.toString()] = sanitizeToPrimitives(v);
    });
    return out;
  }
  if (value is Iterable) {
    return value.map<Object?>(sanitizeToPrimitives).toList(growable: false);
  }
  return value.toString();
}

/// Recursively converts any Isolate-received `Map` into strongly typed `Map<String, dynamic>`.
Map<String, dynamic> deepCopyJsonMap(Map<dynamic, dynamic> raw) {
  final out = <String, dynamic>{};
  raw.forEach((k, v) {
    out[k.toString()] = _deepCopyJsonValue(v);
  });
  return out;
}

dynamic _deepCopyJsonValue(dynamic value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map) {
    return deepCopyJsonMap(value);
  }
  if (value is List) {
    return value.map<dynamic>(_deepCopyJsonValue).toList(growable: false);
  }
  return value.toString();
}

SyscallError _decodeSyscallError(Map<String, dynamic> json) {
  final codeStr = (json['code'] as String?) ?? 'EIO';
  final code = SyscallErrorCode.values.firstWhere(
    (c) => c.codeName == codeStr,
    orElse: () => SyscallErrorCode.eio,
  );
  final rawDetails = json['details'];
  return SyscallError(
    code: code,
    reason: (json['reason'] as String?) ?? 'RPC_ERROR',
    message: (json['message'] as String?) ?? 'Unknown syscall error.',
    recoverable: (json['recoverable'] as bool?) ?? false,
    hint: json['hint'] as String?,
    details: rawDetails is Map ? Map<String, dynamic>.from(rawDetails) : null,
  );
}
