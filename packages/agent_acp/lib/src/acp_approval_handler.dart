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

    final isSubprocess = request.pid != 1;
    final toolCallId = isSubprocess
        ? request.requestId
        : (activeToolCallIdProvider?.call() ?? request.requestId);
    final title = isSubprocess
        ? '[Subprocess pid=${request.pid} ${request.processName ?? 'worker'}${request.profile != null && request.profile!.isNotEmpty ? ' (${request.profile})' : ''}] ${request.title}'
        : request.title;

    final baseContent = request.content.isNotEmpty
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

    final hasReason =
        request.agentReason != null && request.agentReason!.isNotEmpty;
    final List<Map<String, dynamic>> content;
    if (!isSubprocess && !hasReason) {
      content = baseContent;
    } else {
      final headerLines = <String>[];
      if (isSubprocess) {
        final requesterBuf = StringBuffer('Requester: pid=${request.pid}');
        if (request.processName != null && request.processName!.isNotEmpty) {
          requesterBuf.write(', name=${request.processName}');
        }
        if (request.profile != null && request.profile!.isNotEmpty) {
          requesterBuf.write(', profile=${request.profile}');
        }
        headerLines.add(requesterBuf.toString());
      }
      if (hasReason) {
        headerLines.add('Reason: ${request.agentReason}');
      }
      content = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'content',
          'content': <String, dynamic>{
            'type': 'text',
            'text': headerLines.join('\n'),
          },
        },
        ...baseContent,
      ];
    }

    final approvalMeta = <String, dynamic>{
      'requestId': request.requestId,
      'pid': request.pid,
      'processName':
          (request.processName != null && request.processName!.isNotEmpty)
              ? request.processName!
              : (isSubprocess ? 'worker' : 'lead'),
      if (request.profile != null && request.profile!.isNotEmpty)
        'profile': request.profile,
      'ring': (request.ring ??
              (isSubprocess ? ProtectionRing.ring3 : ProtectionRing.ring2))
          .name,
      'syscallName': request.syscallName,
      if (request.requestedVia != null && request.requestedVia!.isNotEmpty)
        'requestedVia': request.requestedVia,
      'allowAlwaysScope': isSubprocess ? 'pid' : 'session',
      if (hasReason) 'reason': request.agentReason,
    };

    final params = <String, dynamic>{
      'sessionId': request.sessionId,
      'toolCall': <String, dynamic>{
        'toolCallId': toolCallId,
        'title': title,
        'kind': request.kind,
        'status': 'pending',
        'content': content,
      },
      'options': request.options
          .map(
            (opt) => <String, dynamic>{
              'optionId': opt.wireValue,
              'name': _optionDisplayName(opt, pid: request.pid),
              'kind': opt.wireValue,
            },
          )
          .toList(growable: false),
      '_meta': <String, dynamic>{
        'fm_agent_os/approval': approvalMeta,
      },
    };

    try {
      final rawResult = await _peer.sendRequest(
        'session/request_permission',
        params,
        cancelToken,
      );
      if (cancelToken?.isCancelled ?? false) {
        _emitPermissionCancelled(
          sessionId: request.sessionId,
          requestId: request.requestId,
          toolCallId: toolCallId,
          pid: request.pid,
        );
        const decision = ApprovalDecision.cancelled();
        onDecision?.call(request, decision);
        return decision;
      }

      final decision = _parseDecision(rawResult);
      onDecision?.call(request, decision);
      return decision;
    } on JsonRpcException {
      if (cancelToken?.isCancelled ?? false) {
        _emitPermissionCancelled(
          sessionId: request.sessionId,
          requestId: request.requestId,
          toolCallId: toolCallId,
          pid: request.pid,
        );
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
      if (cancelToken?.isCancelled ?? false) {
        _emitPermissionCancelled(
          sessionId: request.sessionId,
          requestId: request.requestId,
          toolCallId: toolCallId,
          pid: request.pid,
        );
        const decision = ApprovalDecision.cancelled();
        onDecision?.call(request, decision);
        return decision;
      }
      const decision = ApprovalDecision.rejectOnce();
      onDecision?.call(request, decision);
      return decision;
    }
  }

  void _emitPermissionCancelled({
    required String sessionId,
    required String requestId,
    required String toolCallId,
    required Pid pid,
  }) {
    if (_peer.isClosed) {
      return;
    }
    try {
      _peer.sendNotification('_fm_agent_os/permission_cancelled', <String, dynamic>{
        'sessionId': sessionId,
        'requestId': requestId,
        'toolCallId': toolCallId,
        'pid': pid,
      });
    } catch (_) {
      // Best-effort cancellation notification when peer is closing.
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

  static String _optionDisplayName(ApprovalOption option, {required Pid pid}) {
    return switch (option) {
      ApprovalOption.allowOnce => 'Allow once',
      ApprovalOption.allowAlways =>
        pid == 1 ? 'Allow for session' : 'Allow for this process (pid=$pid)',
      ApprovalOption.rejectOnce => 'Deny',
    };
  }
}
