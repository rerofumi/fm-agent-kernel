import 'dart:async';
import 'dart:collection';

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

/// Approval request delivered to an [ApprovalHandler] when Stage 4 yields `ASK_USER` ([D-020]).
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
  })  : argsSummary = Map<String, dynamic>.unmodifiable(argsSummary),
        content = List<Map<String, dynamic>>.unmodifiable(content),
        options = List<ApprovalOption>.unmodifiable(options);

  final String requestId;
  final String sessionId;
  final Pid pid;
  final String syscallName;
  final String title;
  final String kind;
  final Map<String, dynamic> argsSummary;
  final List<Map<String, dynamic>> content;
  final List<ApprovalOption> options;

  /// Optional stable signature used to remember `allow_always` within the session.
  final String? approvalSignature;
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

/// Session-scoped approval gate caching `allow_always` signatures and enforcing cancellation ([D-020]).
class ApprovalGate {
  ApprovalGate({required this.handler});

  final ApprovalHandler handler;
  final Set<String> _allowAlwaysSignatures = <String>{};

  /// Unmodifiable view of signatures remembered via `allow_always`.
  UnmodifiableSetView<String> get allowAlwaysSignatures =>
      UnmodifiableSetView<String>(_allowAlwaysSignatures);

  /// Clears remembered session approvals.
  void clearRemembered() {
    _allowAlwaysSignatures.clear();
  }

  /// Evaluates [request], honoring session `allow_always` cache and cooperative cancellation.
  Future<ApprovalDecision> evaluate(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) async {
    if (cancelToken != null && cancelToken.isCancelled) {
      return const ApprovalDecision.cancelled();
    }

    final sig = request.approvalSignature;
    if (sig != null && _allowAlwaysSignatures.contains(sig)) {
      return const ApprovalDecision.allowAlways();
    }

    final Future<ApprovalDecision> responseFuture = handler.requestApproval(
      request,
      cancelToken: cancelToken,
    );

    final ApprovalDecision decision;
    if (cancelToken != null) {
      decision = await Future.any<ApprovalDecision>(<Future<ApprovalDecision>>[
        responseFuture,
        cancelToken.onCancel.then((_) => const ApprovalDecision.cancelled()),
      ]);
    } else {
      decision = await responseFuture;
    }

    if (!decision.cancelled &&
        decision.option == ApprovalOption.allowAlways &&
        sig != null &&
        sig.isNotEmpty) {
      _allowAlwaysSignatures.add(sig);
    }

    return decision;
  }
}
