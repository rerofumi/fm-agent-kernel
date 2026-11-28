import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'cancellation.dart';
import 'pcb.dart';
import 'syscall_hook.dart';

/// Ring 2 policy evaluation outcome at Stage 4 ([D-002]).
enum RingDecision {
  allow,
  askUser,
  deny,
}

/// User or policy approval options exposed by the Ring 2 gate ([D-020]).
enum ApprovalOption {
  allowOnce('allow_once'),
  allowAlways('allow_always'),
  rejectOnce('reject_once');

  const ApprovalOption(this.wireValue);

  final String wireValue;
}

/// Non-destructive preview payload attached to an [ApprovalRequest] ([D-015], [D-020]).
class ApprovalPreview {
  ApprovalPreview({
    required this.title,
    required this.kind,
    List<Map<String, dynamic>> content = const <Map<String, dynamic>>[],
    Map<String, dynamic>? metadata,
  })  : content = List<Map<String, dynamic>>.unmodifiable(content),
        metadata = metadata == null
            ? null
            : Map<String, dynamic>.unmodifiable(metadata);

  final String title;
  final String kind;
  final List<Map<String, dynamic>> content;
  final Map<String, dynamic>? metadata;
}

/// Side-effect-free callback producing an [ApprovalPreview] before Stage 5 ([D-002], [D-020]).
typedef ApprovalPreviewBuilder = Future<ApprovalPreview?> Function(
  SyscallHookContext context,
);

/// Approval request delivered to an [ApprovalHandler] when Stage 4 yields `ASK_USER` ([D-020], [D-706]).
class ApprovalRequest {
  ApprovalRequest({
    required this.requestId,
    required this.sessionId,
    required this.pid,
    required this.syscallName,
    required this.title,
    required this.kind,
    required Map<String, dynamic> argsSummary,
    List<Map<String, dynamic>> content = const <Map<String, dynamic>>[],
    List<ApprovalOption> options = const <ApprovalOption>[
      ApprovalOption.allowOnce,
      ApprovalOption.allowAlways,
      ApprovalOption.rejectOnce,
    ],
    this.approvalSignature,
    this.processName,
    this.profile,
    this.ring,
    this.agentReason,
    this.requestedVia,
    Map<String, dynamic>? metadata,
  })  : argsSummary = Map<String, dynamic>.unmodifiable(argsSummary),
        content = List<Map<String, dynamic>>.unmodifiable(content),
        options = List<ApprovalOption>.unmodifiable(options),
        metadata = metadata == null
            ? null
            : Map<String, dynamic>.unmodifiable(metadata);

  final String requestId;
  final String sessionId;
  final Pid pid;
  final String syscallName;
  final String title;
  final String kind;
  final Map<String, dynamic> argsSummary;
  final List<Map<String, dynamic>> content;
  final List<ApprovalOption> options;

  /// Optional stable signature used to remember `allow_always` within the process scope.
  final String? approvalSignature;

  /// Optional process metadata for subprocess correlation and UI display ([D-706], [D-708]).
  final String? processName;
  final String? profile;
  final ProtectionRing? ring;
  final String? agentReason;
  final String? requestedVia;
  final Map<String, dynamic>? metadata;
}

/// One-time approval ticket bound to `(pid, syscallName, canonicalArgsJson)` ([D-704], [D-706]).
class ApprovalGrant {
  const ApprovalGrant({
    required this.grantId,
    required this.pid,
    required this.syscallName,
    required this.canonicalArgsJson,
    required this.decisionOption,
    this.preview,
  });

  final String grantId;
  final Pid pid;
  final String syscallName;
  final String canonicalArgsJson;
  final ApprovalOption decisionOption;
  final ApprovalPreview? preview;
}

/// Result returned by an [ApprovalHandler] ([D-020]).
class ApprovalDecision {
  const ApprovalDecision._({
    required this.option,
    required this.cancelled,
  });

  const ApprovalDecision.allowOnce()
      : this._(option: ApprovalOption.allowOnce, cancelled: false);

  const ApprovalDecision.allowAlways()
      : this._(option: ApprovalOption.allowAlways, cancelled: false);

  const ApprovalDecision.rejectOnce()
      : this._(option: ApprovalOption.rejectOnce, cancelled: false);

  const ApprovalDecision.cancelled()
      : this._(option: ApprovalOption.rejectOnce, cancelled: true);

  final ApprovalOption option;
  final bool cancelled;

  bool get isAllowed =>
      !cancelled &&
      (option == ApprovalOption.allowOnce ||
          option == ApprovalOption.allowAlways);
}

/// Abstract handler deciding `ASK_USER` requests (e.g., [PolicyApprovalHandler] or ACP UI) ([D-020]).
abstract interface class ApprovalHandler {
  Future<ApprovalDecision> requestApproval(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  });
}

/// Injectable policy-based [ApprovalHandler] for tests and non-interactive harnesses ([D-020]).
class PolicyApprovalHandler implements ApprovalHandler {
  PolicyApprovalHandler(this._evaluator);

  /// Always approves once without remembering.
  factory PolicyApprovalHandler.alwaysAllow() {
    return PolicyApprovalHandler(
      (_, _) async => const ApprovalDecision.allowOnce(),
    );
  }

  /// Always approves for the rest of the session.
  factory PolicyApprovalHandler.alwaysAllowSession() {
    return PolicyApprovalHandler(
      (_, _) async => const ApprovalDecision.allowAlways(),
    );
  }

  /// Always rejects (`EACCES` / `DENIED_BY_USER`).
  factory PolicyApprovalHandler.alwaysReject() {
    return PolicyApprovalHandler(
      (_, _) async => const ApprovalDecision.rejectOnce(),
    );
  }

  /// Always cancels (`ECANCELLED`).
  factory PolicyApprovalHandler.alwaysCancel() {
    return PolicyApprovalHandler(
      (_, _) async => const ApprovalDecision.cancelled(),
    );
  }

  final Future<ApprovalDecision> Function(
    ApprovalRequest request,
    CancellationToken? cancelToken,
  ) _evaluator;

  final List<ApprovalRequest> _recordedRequests = <ApprovalRequest>[];

  /// Unmodifiable list of approval requests observed by this handler.
  UnmodifiableListView<ApprovalRequest> get recordedRequests =>
      UnmodifiableListView<ApprovalRequest>(_recordedRequests);

  @override
  Future<ApprovalDecision> requestApproval(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) async {
    _recordedRequests.add(request);
    return _evaluator(request, cancelToken);
  }
}

class _QueuedApprovalEntry {
  _QueuedApprovalEntry({
    required this.request,
    required this.cancelToken,
    required this.completer,
  });

  final ApprovalRequest request;
  final CancellationToken? cancelToken;
  final Completer<ApprovalDecision> completer;
  bool settled = false;
}

/// Approval gate serializing concurrent requests in FIFO order, scoping `allow_always` per PID,
/// and managing one-time [ApprovalGrant] tickets ([D-020], [D-706]).
class ApprovalGate {
  ApprovalGate({
    required this.handler,
    this.onApprovalWaitStart,
    this.onApprovalWaitEnd,
    this.onGrantConsumed,
  });

  final ApprovalHandler handler;

  /// Optional lifecycle callbacks invoked around approval wait and ticket consumption ([D-706]).
  void Function(Pid pid)? onApprovalWaitStart;
  void Function(Pid pid)? onApprovalWaitEnd;
  void Function(ApprovalGrant grant)? onGrantConsumed;

  final Map<Pid, Set<String>> _allowAlwaysByPid = <Pid, Set<String>>{};
  final Map<Pid, Map<String, ApprovalGrant>> _grantsByPid =
      <Pid, Map<String, ApprovalGrant>>{};
  final Queue<_QueuedApprovalEntry> _waitQueue = Queue<_QueuedApprovalEntry>();
  bool _isDraining = false;
  int _grantCounter = 0;

  /// Grace period for cooperative handler cleanup on cancellation before advancing FIFO queue ([D-706], RV-001).
  static const Duration _cancelCleanupGrace = Duration(milliseconds: 50);

  /// Deterministically encodes [value] as JSON with lexicographically sorted Map keys
  /// and `null`-valued Map entries omitted ([D-706]).
  static String canonicalJsonEncode(Object? value) {
    return jsonEncode(_canonicalizeValue(value));
  }

  static Object? _canonicalizeValue(Object? value) {
    if (value is Map) {
      final entries = <MapEntry<String, Object?>>[];
      for (final entry in value.entries) {
        if (entry.value == null) {
          continue;
        }
        entries.add(
          MapEntry<String, Object?>(
            entry.key.toString(),
            _canonicalizeValue(entry.value),
          ),
        );
      }
      entries.sort((a, b) => a.key.compareTo(b.key));
      final out = <String, Object?>{};
      for (final entry in entries) {
        out[entry.key] = entry.value;
      }
      return out;
    }
    if (value is List) {
      return value.map<Object?>(_canonicalizeValue).toList(growable: false);
    }
    return value;
  }

  static String _grantLookupKey(String syscallName, String canonicalArgsJson) =>
      '$syscallName\u0000$canonicalArgsJson';

  /// Unmodifiable view of signatures remembered via `allow_always` for the lead process (`pid == 1`).
  UnmodifiableSetView<String> get allowAlwaysSignatures =>
      UnmodifiableSetView<String>(_allowAlwaysByPid[1] ?? const <String>{});

  /// Returns an unmodifiable view of `allow_always` signatures remembered for [pid] ([D-706]).
  Set<String> allowAlwaysSignaturesForPid(Pid pid) =>
      UnmodifiableSetView<String>(_allowAlwaysByPid[pid] ?? const <String>{});

  /// Returns true if [pid] has already remembered [signature] via `allow_always` ([D-706]).
  bool hasAllowAlways({
    required Pid pid,
    required String? signature,
  }) {
    if (signature == null || signature.isEmpty) {
      return false;
    }
    return _allowAlwaysByPid[pid]?.contains(signature) ?? false;
  }

  /// Issues (or replaces) a one-time [ApprovalGrant] bound to `(pid, syscallName, normalizedArgs)` ([D-706]).
  ApprovalGrant issueGrant({
    required Pid pid,
    required String syscallName,
    required Map<String, dynamic> normalizedArgs,
    required ApprovalOption decisionOption,
    ApprovalPreview? preview,
  }) {
    final canonical = canonicalJsonEncode(normalizedArgs);
    final lookupKey = _grantLookupKey(syscallName, canonical);
    final grant = ApprovalGrant(
      grantId: 'grt_${++_grantCounter}',
      pid: pid,
      syscallName: syscallName,
      canonicalArgsJson: canonical,
      decisionOption: decisionOption,
      preview: preview,
    );
    _grantsByPid.putIfAbsent(pid, () => <String, ApprovalGrant>{})[lookupKey] =
        grant;
    return grant;
  }

  /// Atomically consumes and returns a matching one-time [ApprovalGrant], or `null` if none exists ([D-706]).
  ApprovalGrant? consumeGrant({
    required Pid pid,
    required String syscallName,
    required Map<String, dynamic> normalizedArgs,
  }) {
    final pidGrants = _grantsByPid[pid];
    if (pidGrants == null || pidGrants.isEmpty) {
      return null;
    }
    final canonical = canonicalJsonEncode(normalizedArgs);
    final lookupKey = _grantLookupKey(syscallName, canonical);
    final grant = pidGrants.remove(lookupKey);
    if (pidGrants.isEmpty) {
      _grantsByPid.remove(pid);
    }
    if (grant != null) {
      try {
        onGrantConsumed?.call(grant);
      } catch (_) {
        // Non-critical observer error must not disrupt ticket consumption.
      }
    }
    return grant;
  }

  /// Releases all remembered `allow_always` signatures and unconsumed tickets for [pid] ([D-706]).
  void clearForPid(Pid pid) {
    _allowAlwaysByPid.remove(pid);
    _grantsByPid.remove(pid);
  }

  /// Clears remembered session approvals and unconsumed tickets for all PIDs.
  void clearRemembered() {
    _allowAlwaysByPid.clear();
    _grantsByPid.clear();
  }

  /// Evaluates [request], honoring PID-scoped `allow_always`, FIFO serialization,
  /// and immediate per-request cancellation ([D-020], [D-706]).
  Future<ApprovalDecision> evaluate(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) async {
    if (cancelToken != null && cancelToken.isCancelled) {
      return const ApprovalDecision.cancelled();
    }

    if (hasAllowAlways(pid: request.pid, signature: request.approvalSignature)) {
      return const ApprovalDecision.allowAlways();
    }

    final entry = _QueuedApprovalEntry(
      request: request,
      cancelToken: cancelToken,
      completer: Completer<ApprovalDecision>(),
    );
    _waitQueue.addLast(entry);

    if (cancelToken != null) {
      unawaited(
        cancelToken.onCancel.then((_) {
          if (!entry.settled) {
            entry.settled = true;
            entry.completer.complete(const ApprovalDecision.cancelled());
          }
        }),
      );
    }

    if (!_isDraining) {
      unawaited(_drainQueue());
    }

    return entry.completer.future;
  }

  Future<void> _drainQueue() async {
    if (_isDraining) {
      return;
    }
    _isDraining = true;
    try {
      while (_waitQueue.isNotEmpty) {
        final entry = _waitQueue.removeFirst();
        if (entry.settled || (entry.cancelToken?.isCancelled ?? false)) {
          if (!entry.settled) {
            entry.settled = true;
            entry.completer.complete(const ApprovalDecision.cancelled());
          }
          continue;
        }

        final sig = entry.request.approvalSignature;
        if (hasAllowAlways(pid: entry.request.pid, signature: sig)) {
          if (!entry.settled) {
            entry.settled = true;
            entry.completer.complete(const ApprovalDecision.allowAlways());
          }
          continue;
        }

        final Future<ApprovalDecision> responseFuture;
        try {
          responseFuture = handler.requestApproval(
            entry.request,
            cancelToken: entry.cancelToken,
          );
        } catch (err, st) {
          if (!entry.settled) {
            entry.settled = true;
            entry.completer.completeError(err, st);
          }
          continue;
        }

        ApprovalDecision decision;
        if (entry.cancelToken == null) {
          try {
            decision = await responseFuture;
          } catch (err, st) {
            if (!entry.settled) {
              entry.settled = true;
              entry.completer.completeError(err, st);
            }
            continue;
          }
        } else {
          var responseCompleted = false;
          ApprovalDecision? completedDecision;
          Object? responseError;
          StackTrace? responseStack;
          final trackedResponse = responseFuture.then<ApprovalDecision?>(
            (value) {
              responseCompleted = true;
              completedDecision = value;
              return value;
            },
            onError: (Object err, StackTrace st) {
              responseCompleted = true;
              responseError = err;
              responseStack = st;
              return null;
            },
          );

          await Future.any<Object?>(<Future<Object?>>[
            trackedResponse,
            entry.cancelToken!.onCancel,
          ]);

          if (!responseCompleted) {
            // Wait up to 50ms for cooperative handler cleanup (e.g. permission_cancelled wire flush)
            // before dispatching the next queued request ([D-706], RV-001).
            await trackedResponse.timeout(
              _cancelCleanupGrace,
              onTimeout: () => const ApprovalDecision.cancelled(),
            );
          }

          if (responseError != null) {
            if (!entry.settled) {
              entry.settled = true;
              entry.completer.completeError(responseError!, responseStack);
            }
            continue;
          }

          if ((entry.cancelToken!.isCancelled) || !responseCompleted) {
            decision = const ApprovalDecision.cancelled();
          } else {
            decision =
                completedDecision ?? const ApprovalDecision.cancelled();
          }
        }

        if (!decision.cancelled &&
            decision.option == ApprovalOption.allowAlways &&
            sig != null &&
            sig.isNotEmpty) {
          _allowAlwaysByPid
              .putIfAbsent(entry.request.pid, () => <String>{})
              .add(sig);
        }

        if (!entry.settled) {
          entry.settled = true;
          entry.completer.complete(decision);
        }
      }
    } finally {
      _isDraining = false;
      if (_waitQueue.isNotEmpty) {
        unawaited(_drainQueue());
      }
    }
  }
}
