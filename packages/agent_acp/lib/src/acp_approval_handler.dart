import 'package:agent_kernel/agent_kernel.dart';

import 'json_rpc_peer.dart';

/// Callback notified when an [ApprovalRequest] resolves with a decision ([D-019], [D-020]).
typedef ApprovalResolutionObserver = void Function(
  ApprovalRequest request,
  ApprovalDecision decision,
);

/// Ring 2 [ApprovalHandler] bridging `WAITING_APPROVAL` pauses to ACP
/// `session/request_permission` JSON-RPC requests ([D-020]).
class AcpApprovalHandler implements ApprovalHandler {
  AcpApprovalHandler({
    required JsonRpcPeer peer,
    this.activeToolCallIdProvider,
    this.onDecision,
  }) : _peer = peer;

  final JsonRpcPeer _peer;

  /// Optional provider returning the active `sc_*` toolCallId from [LeadAgent].
  final String? Function()? activeToolCallIdProvider;

  /// Optional observer invoked once a permission request resolves.
  final ApprovalResolutionObserver? onDecision;

  @override
  Future<ApprovalDecision> requestApproval(
    ApprovalRequest request, {
    CancellationToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      const decision = ApprovalDecision.cancelled();
      onDecision?.call(request, decision);
      return decision;
    }

    final toolCallId = activeToolCallIdProvider?.call() ?? request.requestId;
    final content = request.content.isNotEmpty
        ? request.content
        : <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'content',
              'content': <String, dynamic>{
                'type': 'text',
                'text':
                    'Syscall: ${request.syscallName}\nArgs: ${request.argsSummary}',
              },
            },
          ];

    final params = <String, dynamic>{
      'sessionId': request.sessionId,
      'toolCall': <String, dynamic>{
        'toolCallId': toolCallId,
        'title': request.title,
        'kind': request.kind,
        'status': 'pending',
        'content': content,
      },
      'options': request.options
          .map(
            (opt) => <String, dynamic>{
              'optionId': opt.wireValue,
              'name': _optionDisplayName(opt),
              'kind': opt.wireValue,
            },
          )
          .toList(growable: false),
    };

    try {
      final rawResult = await _peer.sendRequest(
        'session/request_permission',
        params,
        cancelToken,
      );
      if (cancelToken?.isCancelled ?? false) {
        const decision = ApprovalDecision.cancelled();
        onDecision?.call(request, decision);
        return decision;
      }

      final decision = _parseDecision(rawResult);
      onDecision?.call(request, decision);
      return decision;
    } on JsonRpcException {
      if (cancelToken?.isCancelled ?? false) {
        const decision = ApprovalDecision.cancelled();
        onDecision?.call(request, decision);
        return decision;
      }
      const decision = ApprovalDecision.rejectOnce();
      onDecision?.call(request, decision);
      return decision;
    } on JsonRpcPeerClosedException {
      const decision = ApprovalDecision.cancelled();
      onDecision?.call(request, decision);
      return decision;
    } catch (_) {
      const decision = ApprovalDecision.rejectOnce();
      onDecision?.call(request, decision);
      return decision;
    }
  }

  static ApprovalDecision _parseDecision(Object? rawResult) {
    if (rawResult is! Map) {
      return const ApprovalDecision.rejectOnce();
    }
    final result = Map<String, dynamic>.from(rawResult);
    final rawOutcome = result['outcome'];
    if (rawOutcome is! Map) {
      return const ApprovalDecision.rejectOnce();
    }
    final outcome = Map<String, dynamic>.from(rawOutcome);
    final outcomeType = outcome['outcome'];
    if (outcomeType == 'cancelled') {
      return const ApprovalDecision.cancelled();
    }
    if (outcomeType != 'selected') {
      return const ApprovalDecision.rejectOnce();
    }

    return switch (outcome['optionId']) {
      'allow_once' => const ApprovalDecision.allowOnce(),
      'allow_always' => const ApprovalDecision.allowAlways(),
      'reject_once' => const ApprovalDecision.rejectOnce(),
      _ => const ApprovalDecision.rejectOnce(),
    };
  }

  static String _optionDisplayName(ApprovalOption option) {
    return switch (option) {
      ApprovalOption.allowOnce => 'Allow once',
      ApprovalOption.allowAlways => 'Allow for session',
      ApprovalOption.rejectOnce => 'Deny',
    };
  }
}
