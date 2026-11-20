import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'cancellation.dart';
import 'pcb.dart';
import 'syscall_error.dart';

/// Priority control signal kinds delivered over the reserved kernel lane ([D-212], [D-312]).
enum ControlSignalKind {
  cancel('cancel'),
  shutdown('shutdown'),
  quotaExceeded('quota_exceeded'),
  childExited('child_exited'),
  sigstop('sigstop'),
  sigcont('sigcont'),
  sigkill('sigkill');

  const ControlSignalKind(this.wireValue);

  final String wireValue;
}

/// Kernel-reserved control signal message bypassing data-lane backpressure ([D-212]).
class ControlSignalMessage {
  ControlSignalMessage({
    required this.kind,
    this.fromPid,
    this.reason,
    Map<String, dynamic>? details,
    DateTime? timestamp,
  })  : details = details == null
            ? null
            : Map<String, dynamic>.unmodifiable(details),
        timestamp = (timestamp ?? DateTime.now()).toUtc();

  final ControlSignalKind kind;
  final Pid? fromPid;
  final String? reason;
  final Map<String, dynamic>? details;
  final DateTime timestamp;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind.wireValue,
      if (fromPid != null) 'fromPid': fromPid,
      if (reason != null) 'reason': reason,
      if (details != null) 'details': details,
      'timestamp': timestamp.toUtc().toIso8601String(),
    };
  }
}

/// Structured IPC data envelope exchanged via `sys_send` / `sys_recv` ([D-212]).
class IpcEnvelope {
  IpcEnvelope({
    required this.msgId,
    required this.fromPid,
    required this.toPid,
    required this.schemaType,
    required this.payload,
    DateTime? timestamp,
  }) : timestamp = (timestamp ?? DateTime.now()).toUtc();

  factory IpcEnvelope.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['payload'];
    if (rawPayload is! String && rawPayload is! Map<String, dynamic>) {
      throw const FormatException(
        'IpcEnvelope payload must be a String or Map<String, dynamic>.',
      );
    }
    return IpcEnvelope(
      msgId: json['msgId'] as String,
      fromPid: json['fromPid'] as int,
      toPid: json['toPid'] as int,
      schemaType: (json['schemaType'] as String?) ?? 'message',
      payload: rawPayload is Map<String, dynamic>
          ? Map<String, dynamic>.from(rawPayload)
          : rawPayload as String,
      timestamp: DateTime.parse(json['timestamp'] as String).toUtc(),
    );
  }

  final String msgId;
  final Pid fromPid;
  final Pid toPid;
  final String schemaType;

  /// JSON-serializable payload (`Map<String, dynamic>` or `String`).
  final Object payload;

  final DateTime timestamp;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'msgId': msgId,
      'fromPid': fromPid,
      'toPid': toPid,
      'schemaType': schemaType,
      'payload': payload,
      'timestamp': timestamp.toUtc().toIso8601String(),
    };
  }
}

/// Two-lane bounded mailbox attached to each PCB ([D-212]).
///
/// - **Control / Signal lane**: Kernel-reserved priority lane (`maxControlSignals = 16`)
///   with same-kind coalescing; never blocked by a full data lane.
/// - **Data lane**: Bounded FIFO queue (`maxMessages = 32`, `maxPayloadBytes = 65536`)
///   returning `EINVAL: IPC_PAYLOAD_TOO_LARGE` or `EDQUOT: MAILBOX_FULL` (both
///   `recoverable: true`) without deadlocking the sender.
class BoundedMailbox {
  BoundedMailbox({
    this.maxControlSignals = defaultMaxControlSignals,
    this.maxMessages = defaultMaxMessages,
    this.maxPayloadBytes = defaultMaxPayloadBytes,
  })  : assert(maxControlSignals > 0),
        assert(maxMessages > 0),
        assert(maxPayloadBytes > 0);

  static const int defaultMaxControlSignals = 16;
  static const int defaultMaxMessages = 32;
  static const int defaultMaxPayloadBytes = 65536;

  final int maxControlSignals;
  final int maxMessages;
  final int maxPayloadBytes;

  final Queue<ControlSignalMessage> _controlQueue =
      Queue<ControlSignalMessage>();
  final Queue<IpcEnvelope> _dataQueue = Queue<IpcEnvelope>();
  final List<Completer<void>> _dataWaiters = <Completer<void>>[];

  int _msgSeq = 0;

  /// Number of pending control signals.
  int get controlLength => _controlQueue.length;

  /// Number of unread data messages.
  int get dataLength => _dataQueue.length;

  /// Whether any priority control signal is queued.
  bool get hasControlSignals => _controlQueue.isNotEmpty;

  /// Whether the data lane has reached [maxMessages].
  bool get isDataFull => _dataQueue.length >= maxMessages;

  /// Whether both control and data lanes are empty.
  bool get isEmpty => _controlQueue.isEmpty && _dataQueue.isEmpty;

  /// Enqueues a priority control signal.
  ///
  /// Same-[ControlSignalKind] signals are coalesced to the latest state.
  /// Even when the data lane is full, control signals are always accepted immediately.
  void enqueueControl(ControlSignalMessage signal) {
    _controlQueue.removeWhere((existing) => existing.kind == signal.kind);
    while (_controlQueue.length >= maxControlSignals) {
      _controlQueue.removeFirst();
    }
    _controlQueue.addLast(signal);
    _wakeDataWaiters();
  }

  /// Dequeues the oldest pending priority control signal, or `null` if none.
  ControlSignalMessage? dequeueControl() {
    if (_controlQueue.isEmpty) {
      return null;
    }
    return _controlQueue.removeFirst();
  }

  /// Drains all pending control signals in FIFO order.
  List<ControlSignalMessage> drainControlSignals() {
    if (_controlQueue.isEmpty) {
      return const <ControlSignalMessage>[];
    }
    final drained = List<ControlSignalMessage>.unmodifiable(_controlQueue);
    _controlQueue.clear();
    return drained;
  }

  /// Validates and enqueues a new data message onto the bounded data lane.
  SyscallResult<IpcEnvelope> enqueueData({
    required Pid fromPid,
    required Pid toPid,
    required Object payload,
    String schemaType = 'message',
    String? msgId,
    DateTime? timestamp,
  }) {
    final sizeError = _validatePayload(payload);
    if (sizeError != null) {
      return SyscallResult<IpcEnvelope>.failure(sizeError);
    }

    if (_dataQueue.length >= maxMessages) {
      return SyscallResult<IpcEnvelope>.failure(
        SyscallError(
          code: SyscallErrorCode.edquot,
          reason: 'MAILBOX_FULL',
          message:
              'Recipient mailbox (pid=$toPid) is full (${_dataQueue.length}/$maxMessages messages).',
          recoverable: true,
          hint:
              'Recipient mailbox is full; wait or summarize into fewer messages.',
          details: <String, dynamic>{
            'toPid': toPid,
            'currentMessages': _dataQueue.length,
            'maxMessages': maxMessages,
          },
        ),
      );
    }

    final envelope = IpcEnvelope(
      msgId: msgId ?? 'msg_${(++_msgSeq).toString().padLeft(4, '0')}',
      fromPid: fromPid,
      toPid: toPid,
      schemaType: schemaType,
      payload: payload is Map<String, dynamic>
          ? Map<String, dynamic>.unmodifiable(payload)
          : payload,
      timestamp: timestamp,
    );
    _dataQueue.addLast(envelope);
    _wakeDataWaiters();
    return SyscallResult<IpcEnvelope>.success(envelope);
  }

  /// Validates and enqueues a pre-constructed [IpcEnvelope] onto the data lane.
  SyscallResult<IpcEnvelope> enqueueEnvelope(IpcEnvelope envelope) {
    return enqueueData(
      fromPid: envelope.fromPid,
      toPid: envelope.toPid,
      payload: envelope.payload,
      schemaType: envelope.schemaType,
      msgId: envelope.msgId,
      timestamp: envelope.timestamp,
    );
  }

  /// Non-blocking FIFO dequeue of up to [maxCount] data messages.
  List<IpcEnvelope> dequeueData({int maxCount = 8}) {
    if (maxCount <= 0 || _dataQueue.isEmpty) {
      return const <IpcEnvelope>[];
    }
    final limit = maxCount > maxMessages ? maxMessages : maxCount;
    final out = <IpcEnvelope>[];
    while (out.length < limit && _dataQueue.isNotEmpty) {
      out.add(_dataQueue.removeFirst());
    }
    return List<IpcEnvelope>.unmodifiable(out);
  }

  /// Dequeues up to [maxCount] data messages, optionally waiting up to [waitTimeout].
  ///
  /// Returns an empty list on timeout (not an error, per [D-212]).
  Future<List<IpcEnvelope>> receiveData({
    int maxCount = 8,
    Duration waitTimeout = Duration.zero,
    CancellationToken? cancelToken,
  }) async {
    if (maxCount <= 0) {
      return const <IpcEnvelope>[];
    }
    if (_dataQueue.isNotEmpty || waitTimeout <= Duration.zero) {
      return dequeueData(maxCount: maxCount);
    }
    if (cancelToken?.isCancelled ?? false) {
      return const <IpcEnvelope>[];
    }

    final waiter = Completer<void>();
    _dataWaiters.add(waiter);

    Timer? timer;
    try {
      timer = Timer(waitTimeout, () {
        if (!waiter.isCompleted) {
          waiter.complete();
        }
      });

      if (cancelToken != null) {
        unawaited(
          cancelToken.onCancel.then((_) {
            if (!waiter.isCompleted) {
              waiter.complete();
            }
          }),
        );
      }

      await waiter.future;
    } finally {
      timer?.cancel();
      _dataWaiters.remove(waiter);
    }

    return dequeueData(maxCount: maxCount);
  }

  SyscallError? _validatePayload(Object payload) {
    if (payload is! String && payload is! Map<String, dynamic>) {
      return const SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_IPC_PAYLOAD',
        message: 'IPC payload must be a String or JSON object (Map<String, dynamic>).',
        recoverable: true,
      );
    }

    final String encoded;
    try {
      encoded = jsonEncode(payload);
    } catch (e) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'INVALID_IPC_PAYLOAD',
        message: 'IPC payload is not JSON-serializable: $e',
        recoverable: true,
      );
    }

    final byteLength = utf8.encode(encoded).length;
    if (byteLength > maxPayloadBytes) {
      return SyscallError(
        code: SyscallErrorCode.einval,
        reason: 'IPC_PAYLOAD_TOO_LARGE',
        message:
            'IPC payload size ($byteLength bytes) exceeds maximum allowed $maxPayloadBytes bytes.',
        recoverable: true,
        hint: 'Summarize the payload or split it into smaller messages under 64 KiB.',
        details: <String, dynamic>{
          'payloadBytes': byteLength,
          'maxPayloadBytes': maxPayloadBytes,
        },
      );
    }
    return null;
  }

  void _wakeDataWaiters() {
    if (_dataWaiters.isEmpty) {
      return;
    }
    final waiters = List<Completer<void>>.from(_dataWaiters);
    _dataWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }
}
