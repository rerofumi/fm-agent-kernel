import 'dart:convert';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:agent_runtime/agent_runtime.dart';

import 'json_rpc_peer.dart';

/// Stage 3/6 [SyscallHook] capturing syscall arguments and results for [AcpEventMapper] ([D-019]).
class AcpSyscallObserverHook extends BaseSyscallHook {
  AcpSyscallObserverHook(this._mapper);

  final AcpEventMapper _mapper;

  @override
  String get name => 'acp_syscall_observer';

  @override
  Future<HookBeforeResult> beforeSyscall(SyscallHookContext context) async {
    if (context.syscallName != 'sys_llm_chat') {
      _mapper.recordBeforeSyscall(context);
    }
    return const HookAllow();
  }

  @override
  Future<void> afterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) async {
    if (context.syscallName != 'sys_llm_chat') {
      _mapper.recordAfterSyscall(context, result);
    }
  }
}

/// Maps [LeadAgent] loop events, [LlmDoneEvent]s, and syscall outputs into
/// ACP v1 `session/update` notifications without placing custom keys at root ([D-019]).
class AcpEventMapper {
  AcpEventMapper({
    required this.sessionId,
    required JsonRpcPeer peer,
    required VfsNamespace namespace,
    required JjTxContext jjContext,
    SecretRedactor? redactor,
    this.contextWindowSize = 32768,
  })  : _peer = peer,
        _namespace = namespace,
        _jjContext = jjContext,
        _redactor = redactor ?? SecretRedactor();

  final String sessionId;
  final JsonRpcPeer _peer;
  final VfsNamespace _namespace;
  final JjTxContext _jjContext;
  final SecretRedactor _redactor;
  final int contextWindowSize;

  ModelIdentifier? _currentTurnModel;
  String? _activeCallId;
  Map<String, dynamic> _activeToolArgs = const <String, dynamic>{};
  bool _beforeHookReached = false;
  SyscallResult<Map<String, dynamic>>? _afterSyscallResult;
  ApprovalDecision? _lastApprovalDecision;
  List<Map<String, dynamic>> _lastApprovalContent = const <Map<String, dynamic>>[];

  /// Exposes the currently executing toolCallId for [AcpApprovalHandler] correlation.
  String? get activeToolCallId => _activeCallId;

  /// Records Stage 3 entry for non-LLM syscalls.
  void recordBeforeSyscall(SyscallHookContext context) {
    _beforeHookReached = true;
    _activeToolArgs = context.args;
  }

  /// Records Stage 6 syscall result for `tool_call_update` enrichment.
  void recordAfterSyscall(
    SyscallHookContext context,
    SyscallResult<Map<String, dynamic>> result,
  ) {
    _activeToolArgs = context.args;
    _afterSyscallResult = result;
  }

  /// Records the Stage 4 approval request preview and decision for `tool_call_update`.
  void recordApprovalResolution(
    ApprovalRequest request,
    ApprovalDecision decision,
  ) {
    _lastApprovalDecision = decision;
    if (request.content.isNotEmpty) {
      _lastApprovalContent = request.content;
    }
  }

  /// Forwards `LlmDoneEvent` from `sys_llm_chat` as an ACP `usage_update` ([D-019]).
  void onLlmStreamEvent(
    String eventSessionId,
    int turnIndex,
    LlmStreamEvent event,
  ) {
    if (eventSessionId != sessionId) {
      return;
    }
    if (event is LlmDoneEvent) {
      final model = _currentTurnModel;
      if (model != null) {
        _emitUsageUpdate(model, event.response.usage);
      }
    }
  }

  /// Translates a [LeadAgent] [AgentLoopEvent] into ACP `session/update` notifications.
  void onAgentLoopEvent(AgentLoopEvent event) {
    if (event.sessionId != sessionId) {
      return;
    }

    switch (event) {
      case AgentTurnStartedEvent(:final model):
        _currentTurnModel = model;
        _resetActiveCall();
      case AgentThoughtDeltaEvent(:final text):
        if (text.isNotEmpty) {
          _sendUpdate(<String, dynamic>{
            'sessionUpdate': 'agent_thought_chunk',
            'content': <String, dynamic>{
              'type': 'text',
              'text': _redactor.redactString(text),
            },
          });
        }
      case AgentTextDeltaEvent(:final text):
        if (text.isNotEmpty) {
          _sendUpdate(<String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': <String, dynamic>{
              'type': 'text',
              'text': _redactor.redactString(text),
            },
          });
        }
      case AgentToolCallStartedEvent(
          :final callId,
          :final toolName,
          :final arguments,
        ):
        _resetActiveCall();
        _activeCallId = callId;
        _activeToolArgs = arguments;

        _sendUpdate(<String, dynamic>{
          'sessionUpdate': 'tool_call',
          'toolCallId': callId,
          'title': formatToolTitle(toolName, arguments),
          'kind': mapToolKind(toolName),
          'status': 'in_progress',
        });
      case AgentToolCallCompletedEvent(
          :final callId,
          :final toolName,
          :final ok,
          :final errorCode,
        ):
        final decision = _resolveAuditDecision(
          toolName: toolName,
          ok: ok,
          errorCode: errorCode,
        );
        final content = _buildToolResultContent(
          toolName: toolName,
          args: _activeToolArgs,
          ok: ok,
          errorCode: errorCode,
          result: _afterSyscallResult,
          approvalContent: _lastApprovalContent,
          decision: decision,
        );

        _sendUpdate(<String, dynamic>{
          'sessionUpdate': 'tool_call_update',
          'toolCallId': callId,
          'status': ok ? 'completed' : 'failed',
          if (content.isNotEmpty) 'content': content,
          '_meta': <String, dynamic>{
            'fm_agent_os/jj': <String, dynamic>{
              'jjChangeId': _jjContext.workingChangeId,
              'jjOpId': _jjContext.currentOpId,
              'decision': decision,
            },
          },
        });
        _resetActiveCall();
      case AgentTurnCompletedEvent():
      case AgentTurnFailedEvent():
        _resetActiveCall();
    }
  }

  /// Maps syscall names to ACP standard `tool_call.kind` enumeration values ([D-019]).
  static String mapToolKind(String toolName) {
    return switch (toolName) {
      'sys_read_lines' ||
      'sys_jj_status' ||
      'sys_jj_log' ||
      'sys_jj_diff' =>
        'read',
      'sys_glob' || 'sys_grep' => 'search',
      'sys_edit_block' ||
      'sys_write_file' ||
      'sys_tx_begin' ||
      'sys_tx_describe' ||
      'sys_tx_squash' ||
      'sys_tx_rollback' =>
        'edit',
      'sys_exec' => 'execute',
      _ => 'other',
    };
  }

  /// Formats a human-readable ACP `tool_call.title`.
  static String formatToolTitle(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'sys_read_lines':
        final path = args['path'] ?? '';
        final start = args['startLine'];
        final end = args['endLine'];
        if (start != null || end != null) {
          return 'Read $path (${start ?? 1}..${end ?? 'end'})';
        }
        return 'Read $path';
      case 'sys_glob':
        return 'Glob ${args['pattern'] ?? ''}';
      case 'sys_grep':
        return 'Grep "${args['pattern'] ?? ''}"';
      case 'sys_jj_status':
        return 'jj status';
      case 'sys_jj_log':
        return 'jj log (${args['revset'] ?? '::@ | @-'})';
      case 'sys_jj_diff':
        return 'jj diff (${args['rev'] ?? '@'})';
      case 'sys_edit_block':
        return 'Edit ${args['path'] ?? ''}';
      case 'sys_write_file':
        return 'Write ${args['path'] ?? ''}';
      case 'sys_tx_begin':
        return 'Begin jj transaction';
      case 'sys_tx_describe':
        return 'Describe jj working change';
      case 'sys_tx_squash':
        return 'Squash working change into @-';
      case 'sys_tx_rollback':
        return 'Rollback jj transaction';
      case 'sys_exec':
        final cmd = (args['command'] as String?) ?? '';
        final rawArgs = args['args'] as List<dynamic>?;
        final full = (rawArgs != null && rawArgs.isNotEmpty)
            ? '$cmd ${rawArgs.join(' ')}'
            : cmd;
        return 'Execute: $full';
      default:
        return toolName;
    }
  }

  void _emitUsageUpdate(ModelIdentifier model, LlmUsageTelemetry usage) {
    final update = <String, dynamic>{
      'sessionUpdate': 'usage_update',
      'used': usage.totalTokens,
      'size': contextWindowSize,
      if (usage.costMicroUsd != null)
        'cost': <String, dynamic>{
          'amount': double.parse((usage.costMicroUsd! / 1e6).toStringAsFixed(6)),
          'currency': 'USD',
        },
      '_meta': <String, dynamic>{
        'fm_agent_os/llmTelemetry': <String, dynamic>{
          'provider': model.provider.id,
          'model': model.modelName,
          'promptTokens': usage.promptTokens,
          'completionTokens': usage.completionTokens,
          'cachedTokens': usage.cachedTokens,
          'cacheWriteTokens': usage.cacheWriteTokens,
          'cacheHitRate': usage.cacheHitRate,
          'ttftMs': usage.ttftMs,
          'durationMs': usage.durationMs,
        },
      },
    };
    _sendUpdate(update);
  }

  String _resolveAuditDecision({
    required String toolName,
    required bool ok,
    required String? errorCode,
  }) {
    final approval = _lastApprovalDecision;
    if (approval != null) {
      if (approval.cancelled || !approval.isAllowed) {
        return AuditDecision.deniedByUser.wireValue;
      }
      return AuditDecision.approvedByUser.wireValue;
    }

    if (ok) {
      return AuditDecision.allowed.wireValue;
    }

    if (!_beforeHookReached &&
        errorCode == SyscallErrorCode.eperm.codeName &&
        toolName == 'sys_exec') {
      return AuditDecision.hookBlocked.wireValue;
    }

    if (errorCode == SyscallErrorCode.einval.codeName) {
      return AuditDecision.invalidArgs.wireValue;
    }
    if (errorCode == SyscallErrorCode.edquot.codeName) {
      return AuditDecision.quotaExceeded.wireValue;
    }
    return AuditDecision.deniedByPolicy.wireValue;
  }

  List<Map<String, dynamic>> _buildToolResultContent({
    required String toolName,
    required Map<String, dynamic> args,
    required bool ok,
    required String? errorCode,
    required SyscallResult<Map<String, dynamic>>? result,
    required List<Map<String, dynamic>> approvalContent,
    required String decision,
  }) {
    if (!ok) {
      final err = result?.error;
      final text = err != null
          ? err.toJsonString()
          : jsonEncode(<String, dynamic>{
              'code': errorCode ?? 'EIO',
              'decision': decision,
              'tool': toolName,
            });
      return <Map<String, dynamic>>[
        _textContentBlock(_redactor.redactString(text)),
      ];
    }

    final value = result?.value;
    switch (toolName) {
      case 'sys_edit_block':
        final hostPath = _resolveHostForwardSlash(args['path'] as String?);
        if (hostPath != null) {
          return <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'diff',
              'path': hostPath,
              'oldText': args['oldBlock'] as String?,
              'newText': (args['newBlock'] as String?) ?? '',
            },
          ];
        }
        break;
      case 'sys_write_file':
        final hostPath = _resolveHostForwardSlash(args['path'] as String?);
        if (hostPath != null) {
          return <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'diff',
              'path': hostPath,
              'oldText': null,
              'newText': (args['content'] as String?) ?? '',
            },
          ];
        }
        break;
      case 'sys_jj_diff':
        final diffText = (value?['diff'] as String?) ?? '';
        return <Map<String, dynamic>>[
          _textContentBlock(
            diffText.trim().isEmpty ? '(no diff)' : _redactor.redactString(diffText),
          ),
        ];
      case 'sys_tx_squash':
        if (approvalContent.isNotEmpty) {
          return approvalContent;
        }
        break;
      case 'sys_exec':
        if (value != null) {
          final exitCodeVal = value['exitCode'];
          final stdoutStr = ((value['stdout'] as String?) ?? '').trimRight();
          final stderrStr = ((value['stderr'] as String?) ?? '').trimRight();
          final buf = StringBuffer('exitCode=$exitCodeVal');
          if (stdoutStr.isNotEmpty) {
            buf.write('\n$stdoutStr');
          }
          if (stderrStr.isNotEmpty) {
            buf.write('\n[stderr]\n$stderrStr');
          }
          return <Map<String, dynamic>>[
            _textContentBlock(_redactor.redactString(buf.toString())),
          ];
        }
        break;
      default:
        break;
    }

    if (value != null) {
      return <Map<String, dynamic>>[
        _textContentBlock(_redactor.redactString(jsonEncode(value))),
      ];
    }
    return const <Map<String, dynamic>>[];
  }

  String? _resolveHostForwardSlash(String? virtualPath) {
    if (virtualPath == null || virtualPath.trim().isEmpty) {
      return null;
    }
    final res = _namespace.resolveVirtualPath(
      virtualPath,
      allowRoot: false,
      checkProtected: false,
      checkSymlinks: false,
    );
    if (!res.ok) {
      return null;
    }
    return res.value!.hostPath.replaceAll('\\', '/');
  }

  static Map<String, dynamic> _textContentBlock(String text) {
    return <String, dynamic>{
      'type': 'content',
      'content': <String, dynamic>{
        'type': 'text',
        'text': text,
      },
    };
  }

  void _sendUpdate(Map<String, dynamic> update) {
    _peer.sendNotification('session/update', <String, dynamic>{
      'sessionId': sessionId,
      'update': update,
    });
  }

  void _resetActiveCall() {
    _activeCallId = null;
    _activeToolArgs = const <String, dynamic>{};
    _beforeHookReached = false;
    _afterSyscallResult = null;
    _lastApprovalDecision = null;
    _lastApprovalContent = const <Map<String, dynamic>>[];
  }
}
