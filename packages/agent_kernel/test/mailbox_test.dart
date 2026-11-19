import 'dart:async';

import 'package:agent_kernel/agent_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('BoundedMailbox [D-212]', () {
    test('enqueues and dequeues data envelopes in FIFO order with JSON serialization', () {
      final mailbox = BoundedMailbox();

      final r1 = mailbox.enqueueData(
        fromPid: 1,
        toPid: 2,
        schemaType: 'task_hint',
        payload: const <String, dynamic>{'step': 1, 'text': 'first'},
      );
      final r2 = mailbox.enqueueData(
        fromPid: 1,
        toPid: 2,
        schemaType: 'text',
        payload: 'second message',
      );

      expect(r1.ok, isTrue);
      expect(r2.ok, isTrue);
      expect(r1.value!.msgId, equals('msg_0001'));
      expect(r2.value!.msgId, equals('msg_0002'));
      expect(mailbox.dataLength, equals(2));

      final roundTripped = IpcEnvelope.fromJson(r1.value!.toJson());
      expect(roundTripped.msgId, equals(r1.value!.msgId));
      expect(roundTripped.fromPid, equals(1));
      expect(roundTripped.toPid, equals(2));
      expect(roundTripped.schemaType, equals('task_hint'));
      expect(roundTripped.payload, equals(const <String, dynamic>{'step': 1, 'text': 'first'}));

      final batch = mailbox.dequeueData(maxCount: 8);
      expect(batch, hasLength(2));
      expect(batch[0].msgId, equals('msg_0001'));
      expect(batch[1].msgId, equals('msg_0002'));
      expect(mailbox.dataLength, equals(0));
    });

    test('returns recoverable EDQUOT (MAILBOX_FULL) when exceeding 32 data messages', () {
      final mailbox = BoundedMailbox();

      for (var i = 0; i < BoundedMailbox.defaultMaxMessages; i++) {
        final res = mailbox.enqueueData(
          fromPid: 2,
          toPid: 1,
          payload: 'msg-$i',
        );
        expect(res.ok, isTrue, reason: 'Message $i should fit within 32-message bound');
      }
      expect(mailbox.isDataFull, isTrue);
      expect(mailbox.dataLength, equals(32));

      final overflow = mailbox.enqueueData(
        fromPid: 2,
        toPid: 1,
        payload: 'msg-33',
      );
      expect(overflow.ok, isFalse);
      expect(overflow.error!.code, equals(SyscallErrorCode.edquot));
      expect(overflow.error!.reason, equals('MAILBOX_FULL'));
      expect(overflow.error!.recoverable, isTrue);
      expect(mailbox.dataLength, equals(32));
    });

    test('returns recoverable EINVAL (IPC_PAYLOAD_TOO_LARGE) when payload exceeds 64 KiB', () {
      final mailbox = BoundedMailbox();

      // A 64 KiB string + JSON quotes exceeds 65,536 bytes.
      final oversized = 'a' * BoundedMailbox.defaultMaxPayloadBytes;
      final tooLarge = mailbox.enqueueData(
        fromPid: 2,
        toPid: 1,
        payload: oversized,
      );
      expect(tooLarge.ok, isFalse);
      expect(tooLarge.error!.code, equals(SyscallErrorCode.einval));
      expect(tooLarge.error!.reason, equals('IPC_PAYLOAD_TOO_LARGE'));
      expect(tooLarge.error!.recoverable, isTrue);
      expect(mailbox.dataLength, equals(0));

      // Exactly 65,534 ASCII chars + 2 JSON quotes == 65,536 bytes -> allowed.
      final maxFit = 'b' * (BoundedMailbox.defaultMaxPayloadBytes - 2);
      final okRes = mailbox.enqueueData(
        fromPid: 2,
        toPid: 1,
        payload: maxFit,
      );
      expect(okRes.ok, isTrue);
      expect(mailbox.dataLength, equals(1));
    });

    test('delivers priority control signals immediately even when data lane is full', () {
      final mailbox = BoundedMailbox();

      for (var i = 0; i < BoundedMailbox.defaultMaxMessages; i++) {
        expect(
          mailbox.enqueueData(fromPid: 2, toPid: 1, payload: 'fill-$i').ok,
          isTrue,
        );
      }
      expect(mailbox.isDataFull, isTrue);

      // Control lane accepts signals without blocking even while data lane is full.
      mailbox.enqueueControl(
        ControlSignalMessage(
          kind: ControlSignalKind.quotaExceeded,
          fromPid: 2,
          reason: 'TOKEN_QUOTA_EXCEEDED',
        ),
      );
      mailbox.enqueueControl(
        ControlSignalMessage(
          kind: ControlSignalKind.cancel,
          fromPid: 1,
          reason: 'USER_CANCELLED',
        ),
      );
      // Same kind coalesces to latest state without growing queue length.
      mailbox.enqueueControl(
        ControlSignalMessage(
          kind: ControlSignalKind.cancel,
          fromPid: 1,
          reason: 'USER_CANCELLED_V2',
        ),
      );

      expect(mailbox.hasControlSignals, isTrue);
      expect(mailbox.controlLength, equals(2));

      final first = mailbox.dequeueControl();
      expect(first, isNotNull);
      expect(first!.kind, equals(ControlSignalKind.quotaExceeded));

      final second = mailbox.dequeueControl();
      expect(second, isNotNull);
      expect(second!.kind, equals(ControlSignalKind.cancel));
      expect(second.reason, equals('USER_CANCELLED_V2'));
      expect(mailbox.hasControlSignals, isFalse);
      // Data lane remained untouched.
      expect(mailbox.dataLength, equals(32));
    });

    test('receiveData waits for incoming data and returns empty list on timeout', () async {
      final mailbox = BoundedMailbox();

      // Immediate non-blocking empty return.
      final emptyNow = await mailbox.receiveData(waitTimeout: Duration.zero);
      expect(emptyNow, isEmpty);

      // Short timeout returns empty list (not an error).
      final timedOut = await mailbox.receiveData(
        waitTimeout: const Duration(milliseconds: 20),
      );
      expect(timedOut, isEmpty);

      // Wakes immediately when a message arrives during wait.
      final pending = mailbox.receiveData(
        maxCount: 4,
        waitTimeout: const Duration(seconds: 2),
      );
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 10), () {
          mailbox.enqueueData(fromPid: 2, toPid: 1, payload: 'arrived');
        }),
      );
      final received = await pending;
      expect(received, hasLength(1));
      expect(received.first.payload, equals('arrived'));
    });
  });
}
