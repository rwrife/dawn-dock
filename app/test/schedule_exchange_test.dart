import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/protocol_contract.dart';
import 'package:dawn_dock_companion/domain/schedule_diff.dart';
import 'package:dawn_dock_companion/domain/schedule_exchange.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';

/// Host-side evidence for the companion schedule exchange domain core:
/// contract-faithful request framing against the canonical v1 fixtures,
/// apply-token binding, sync-receipt consistency, and revision-conflict
/// handling. These are Dart software tests only — no transport, device, or
/// interoperability claim.
void main() {
  final fixtureRoot = Directory.current.uri
      .resolve('../docs/protocol/fixtures/v1/')
      .toFilePath();
  Map<String, Object?> readFixture(String path) => jsonDecode(
    File('$fixtureRoot${path.replaceAll('/', Platform.pathSeparator)}')
        .readAsStringSync(),
  ) as Map<String, Object?>;

  DateTime clockNow() => DateTime.utc(2026, 9, 6, 12, 0, 45);

  // Mirrors `valid/schedule_preview.request.json`: one manual alarm whose
  // wire day set is [1,2,3,4,5] (ISO days 2..6).
  AlarmDraft workdayDraft() => AlarmDraft(
    id: 'wake-weekdays',
    label: 'Workday',
    enabled: true,
    localHour: 7,
    localMinute: 0,
    days: const {2, 3, 4, 5, 6},
    timezone: 'America/New_York',
    snoozeMinutes: 9,
    volume: 45,
    sound: 'gentle-1',
    source: DraftSource.manual,
  );

  DeviceScheduleStore storeAt(int revision) =>
      DeviceScheduleStore(clock: clockNow)
        ..replaceAll(revision: revision, alarms: const []);

  ScheduleExchange armedExchange({
    int revision = 12,
    List<AlarmDraft>? proposal,
  }) {
    final store = storeAt(revision);
    final exchange = ScheduleExchange(store);
    exchange.beginPreview(
      diffSchedule(
        baseline: store.committedAlarms,
        proposal: proposal ?? [workdayDraft()],
        expectedRevision: revision,
      ),
    );
    return exchange;
  }

  group('preview request framing matches the canonical fixture', () {
    test('generated payload equals valid/schedule_preview.request.json', () {
      final exchange = armedExchange();
      final request = exchange.buildPreview(
        messageId: 'req-0002',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
      );
      expect(request, readFixture('valid/schedule_preview.request.json'));
    });

    test('generated payload passes the mirrored contract gate', () {
      final request = armedExchange().buildPreview(
        messageId: 'req-0002',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
      );
      expect(validateContractMessage(request), ContractCode.accepted);
    });

    test('invalid message identity refuses with the stable code', () {
      final exchange = armedExchange();
      expect(
        () => exchange.buildPreview(
          messageId: 'x' * 129,
          sentAt: DateTime.utc(2026, 9, 6),
        ),
        throwsA(
          isA<ExchangeRejectException>().having(
            (e) => e.code,
            'code',
            'invalid_message_id',
          ),
        ),
      );
      expect(
        () => exchange.buildPreview(
          messageId: 'has space',
          sentAt: DateTime.utc(2026, 9, 6),
        ),
        throwsA(
          isA<ExchangeRejectException>().having(
            (e) => e.code,
            'code',
            'invalid_message_id',
          ),
        ),
      );
    });

    test('sub-second sentAt refuses with invalid_sent_at', () {
      final exchange = armedExchange();
      expect(
        () => exchange.buildPreview(
          messageId: 'req-0002',
          sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10, 5),
        ),
        throwsA(
          isA<ExchangeRejectException>().having(
            (e) => e.code,
            'code',
            'invalid_sent_at',
          ),
        ),
      );
    });

    test('a stale proposal is refused before any envelope is built', () {
      final store = storeAt(12);
      final exchange = ScheduleExchange(store);
      expect(
        () => exchange.beginPreview(
          diffSchedule(
            baseline: store.committedAlarms,
            proposal: [workdayDraft()],
            expectedRevision: 11,
          ),
        ),
        throwsArgumentError,
      );
      expect(exchange.phase, ExchangePhase.idle);
    });
  });

  group('apply request framing and token binding', () {
    test('generated payload equals valid/schedule_apply.request.json', () {
      final exchange = armedExchange();
      exchange.buildPreview(
        messageId: 'req-0002',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
      );
      exchange.receiveApplyToken('preview-7f93d1');
      final request = exchange.buildApply(
        messageId: 'req-0003',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 30),
      );
      expect(request, readFixture('valid/schedule_apply.request.json'));
    });

    test('apply before token binding is a state error', () {
      final exchange = armedExchange();
      exchange.buildPreview(
        messageId: 'req-0002',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
      );
      expect(
        () => exchange.buildApply(
          messageId: 'req-0003',
          sentAt: DateTime.utc(2026, 9, 6, 12, 0, 30),
        ),
        throwsStateError,
      );
    });

    test('token only binds after the preview request is built', () {
      expect(
        () => armedExchange().receiveApplyToken('preview-7f93d1'),
        throwsStateError,
      );
    });

    test('malformed apply tokens are refused', () {
      final exchange = armedExchange();
      exchange.buildPreview(
        messageId: 'req-0002',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
      );
      for (final bad in ['', 'has space', 'x' * 129, 'ünïcode']) {
        expect(
          () => exchange.receiveApplyToken(bad),
          throwsArgumentError,
          reason: 'token $bad must be refused',
        );
      }
      expect(exchange.phase, ExchangePhase.previewSent);
      expect(exchange.hasBoundToken, isFalse);
    });

    test('apply refuses once the mirror moved past the armed revision', () {
      final store = storeAt(12);
      final exchange = ScheduleExchange(store);
      exchange.beginPreview(
        diffSchedule(
          baseline: store.committedAlarms,
          proposal: [workdayDraft()],
          expectedRevision: 12,
        ),
      );
      exchange.buildPreview(
        messageId: 'req-0002',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
      );
      exchange.receiveApplyToken('preview-7f93d1');
      // An independent sync adopted a newer revision while this exchange
      // was armed — the token is stale-by-revision and must not be sent.
      store.replaceAll(
        revision: 13,
        alarms: [workdayDraft()],
        receipt: SyncReceipt(
          appliedRevision: 13,
          alarmCount: 1,
          nextAlarmUtc: DateTime.utc(2026, 9, 7, 11),
          receivedAtUtc: clockNow(),
        ),
      );
      expect(
        () => exchange.buildApply(
          messageId: 'req-0003',
          sentAt: DateTime.utc(2026, 9, 6, 12, 0, 30),
        ),
        throwsStateError,
      );
      expect(exchange.phase, ExchangePhase.readyToApply);
    });

    test('proposal digest is stable and exposed while armed', () {
      final a = armedExchange();
      final b = armedExchange();
      expect(a.proposalDigest, isNotNull);
      expect(a.proposalDigest, b.proposalDigest);
      final drifted = armedExchange(
        proposal: [workdayDraft().copyWith(volume: 60)],
      );
      expect(drifted.proposalDigest, isNot(a.proposalDigest));
    });
  });

  group('sync receipt ingestion', () {
    test('consistent receipt adopts the applied revision and content', () {
      final store = storeAt(12);
      final exchange = ScheduleExchange(store);
      final proposal = [workdayDraft()];
      exchange.beginPreview(
        diffSchedule(
          baseline: store.committedAlarms,
          proposal: proposal,
          expectedRevision: 12,
        ),
      );
      exchange.buildPreview(
        messageId: 'req-0002',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
      );
      exchange.receiveApplyToken('preview-7f93d1');
      exchange.buildApply(
        messageId: 'req-0003',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 30),
      );
      final result = exchange.ingest(
        readFixture('valid/event_sync_receipt.response.json'),
      );
      expect(result.disposition, IngestDisposition.applied);
      expect(result.code, isNull);
      expect(exchange.phase, ExchangePhase.applied);
      expect(exchange.receiptApplied, isTrue);
      expect(exchange.hasBoundToken, isFalse, reason: 'token is single-use');
      expect(store.knownRevision, 13);
      expect(store.committedAlarms, proposal);
      expect(store.lastReceipt?.appliedRevision, 13);
      expect(store.lastReceipt?.alarmCount, 1);
      expect(store.lastReceipt?.nextAlarmUtc, DateTime.utc(2026, 9, 7, 11));
      expect(store.lastReceipt?.receivedAtUtc, clockNow());
    });

    test('receipt advancing more than one revision is refused untouched', () {
      final store = storeAt(12);
      final exchange = armedAndAwaiting(store);
      final result = exchange.ingest({
        'protocol': 'dawn-dock/1',
        'messageId': 'evt-0101',
        'sentAt': '2026-09-06T12:00:45Z',
        'type': 'event.syncReceipt',
        'body': {
          'appliedRevision': 14,
          'alarmCount': 1,
          'nextAlarmUtc': '2026-09-07T11:00:00Z',
        },
      });
      expect(result.disposition, IngestDisposition.rejected);
      expect(result.code, 'payload_semantic_error');
      expect(exchange.phase, ExchangePhase.applySent);
      expect(store.knownRevision, 12);
      expect(store.lastReceipt, isNull);
    });

    test('receipt alarm count inconsistent with the proposal is refused', () {
      final store = storeAt(12);
      final exchange = armedAndAwaiting(store);
      final result = exchange.ingest({
        'protocol': 'dawn-dock/1',
        'messageId': 'evt-0102',
        'sentAt': '2026-09-06T12:00:45Z',
        'type': 'event.syncReceipt',
        'body': {
          'appliedRevision': 13,
          'alarmCount': 2,
          'nextAlarmUtc': '2026-09-07T11:00:00Z',
        },
      });
      expect(result.disposition, IngestDisposition.rejected);
      expect(store.knownRevision, 12);
      expect(exchange.phase, ExchangePhase.applySent);
    });

    test('receipt behind the armed revision is refused', () {
      final store = storeAt(12);
      final exchange = armedAndAwaiting(store);
      final result = exchange.ingest({
        'protocol': 'dawn-dock/1',
        'messageId': 'evt-0103',
        'sentAt': '2026-09-06T12:00:45Z',
        'type': 'event.syncReceipt',
        'body': {
          'appliedRevision': 12,
          'alarmCount': 1,
          'nextAlarmUtc': '2026-09-07T11:00:00Z',
        },
      });
      expect(result.disposition, IngestDisposition.rejected);
      expect(store.knownRevision, 12);
    });
  });

  group('contract gate and replay protection on inbound messages', () {
    test('replayed receipt messageId is refused', () {
      final store = storeAt(12);
      final exchange = armedAndAwaiting(store);
      final receipt = readFixture('valid/event_sync_receipt.response.json');
      final first = exchange.ingest(receipt);
      expect(first.disposition, IngestDisposition.applied);
      // The replay window is per device session and survives reset(): a
      // fresh exchange on the same instance must still refuse the reused
      // identity at the gate before any domain handling.
      exchange.reset();
      exchange.beginPreview(
        diffSchedule(
          baseline: store.committedAlarms,
          proposal: [workdayDraft()],
          expectedRevision: 13,
        ),
      );
      exchange.buildPreview(
        messageId: 'req-0010',
        sentAt: DateTime.utc(2026, 9, 6, 12, 5),
      );
      exchange.receiveApplyToken('preview-abc');
      exchange.buildApply(
        messageId: 'req-0011',
        sentAt: DateTime.utc(2026, 9, 6, 12, 6),
      );
      final replay = exchange.ingest(receipt);
      expect(replay.disposition, IngestDisposition.invalid);
      expect(replay.code, 'duplicate_message_id');
      expect(store.knownRevision, 13);
    });

    test('gate-invalid envelopes are refused without state change', () {
      final store = storeAt(12);
      final exchange = armedAndAwaiting(store);
      final malformed = {
        'protocol': 'dawn-dock/1',
        'messageId': 'evt-bad',
        'sentAt': '2026-09-06T12:00:45+00:00',
        'type': 'event.syncReceipt',
        'body': {
          'appliedRevision': 13,
          'alarmCount': 1,
          'nextAlarmUtc': '2026-09-07T11:00:00Z',
        },
      };
      final result = exchange.ingest(malformed);
      expect(result.disposition, IngestDisposition.invalid);
      expect(result.code, 'invalid_sent_at');
      expect(store.knownRevision, 12);
      expect(exchange.phase, ExchangePhase.applySent);
    });

    test('non-response message types are refused', () {
      final exchange = armedAndAwaiting(storeAt(12));
      expect(
        () => exchange.ingest(
          readFixture('valid/device_status_get.request.json'),
        ),
        throwsArgumentError,
      );
    });

    test('ingest outside applySent is a state error', () {
      expect(() => armedExchange().ingest({}), throwsStateError);
    });
  });

  group('revision conflict handling', () {
    test('revision_conflict moves to needsRefresh and discards the token', () {
      final store = storeAt(12);
      final exchange = armedAndAwaiting(store);
      final result = exchange.ingest(
        readFixture('valid/error_revision_conflict.response.json'),
      );
      expect(result.disposition, IngestDisposition.conflict);
      expect(result.code, 'revision_conflict');
      expect(result.currentRevision, 13);
      expect(exchange.phase, ExchangePhase.needsRefresh);
      expect(exchange.hasBoundToken, isFalse);
      expect(exchange.conflictRevision, 13);
      expect(store.knownRevision, 12, reason: 'conflict must not mutate');
    });

    test('rebase refuses while the mirror is still stale', () {
      final store = storeAt(12);
      final exchange = armedAndAwaiting(store);
      exchange.ingest(
        readFixture('valid/error_revision_conflict.response.json'),
      );
      expect(() => exchange.rebase(), throwsStateError);
      expect(exchange.phase, ExchangePhase.needsRefresh);
    });

    test('rebase returns to idle once refreshed to the reported revision', () {
      final store = storeAt(12);
      final exchange = armedAndAwaiting(store);
      exchange.ingest(
        readFixture('valid/error_revision_conflict.response.json'),
      );
      // An independent sync path refreshes the mirror to the reported
      // revision, then the stale exchange may be rebased and a fresh
      // proposal armed against revision 13.
      store.replaceAll(
        revision: 13,
        alarms: [workdayDraft()],
        receipt: SyncReceipt(
          appliedRevision: 13,
          alarmCount: 1,
          nextAlarmUtc: DateTime.utc(2026, 9, 7, 11),
          receivedAtUtc: clockNow(),
        ),
      );
      exchange.rebase();
      expect(exchange.phase, ExchangePhase.idle);
      expect(exchange.conflictRevision, isNull);
      exchange.beginPreview(
        diffSchedule(
          baseline: store.committedAlarms,
          proposal: [workdayDraft().copyWith(label: 'Workday v2')],
          expectedRevision: 13,
        ),
      );
      expect(exchange.phase, ExchangePhase.idle);
      expect(exchange.expectedRevision, 13);
    });

    test(
      'terminal error responses reject the exchange and clear the token',
      () {
        final store = storeAt(12);
        final exchange = armedAndAwaiting(store);
        final result = exchange.ingest({
          'protocol': 'dawn-dock/1',
          'messageId': 'err-0300',
          'sentAt': '2026-09-06T12:02:00Z',
          'type': 'error.response',
          'body': {
            'code': 'unauthorized',
            'summary': 'Pairing not valid',
            'retryable': false,
          },
        });
        expect(result.disposition, IngestDisposition.rejected);
        expect(result.code, 'unauthorized');
        expect(exchange.phase, ExchangePhase.idle);
        expect(exchange.hasBoundToken, isFalse);
        expect(store.knownRevision, 12);
      },
    );
  });

  group('exchange lifecycle guards', () {
    test('abort clears the armed proposal and token from any active phase', () {
      final exchange = armedAndAwaiting(storeAt(12));
      exchange.abort();
      expect(exchange.phase, ExchangePhase.idle);
      expect(exchange.proposalDigest, isNull);
      expect(exchange.hasBoundToken, isFalse);
      expect(() => exchange.abort(), throwsStateError);
    });

    test('reset only follows a completed exchange', () {
      final exchange = armedAndAwaiting(storeAt(12));
      expect(() => exchange.reset(), throwsStateError);
      exchange.ingest(readFixture('valid/event_sync_receipt.response.json'));
      exchange.reset();
      expect(exchange.phase, ExchangePhase.idle);
      expect(exchange.receiptApplied, isFalse);
    });

    test('double preview and double ingest are refused', () {
      final exchange = armedExchange();
      exchange.buildPreview(
        messageId: 'req-0002',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
      );
      expect(
        () => exchange.buildPreview(
          messageId: 'req-0009',
          sentAt: DateTime.utc(2026, 9, 6, 12, 0, 11),
        ),
        throwsStateError,
      );
      exchange.receiveApplyToken('preview-7f93d1');
      exchange.buildApply(
        messageId: 'req-0003',
        sentAt: DateTime.utc(2026, 9, 6, 12, 0, 30),
      );
      exchange.ingest(readFixture('valid/event_sync_receipt.response.json'));
      expect(() => exchange.ingest({}), throwsStateError);
    });
  });
}

/// Arming helper for tests that only need a store waiting on the device.
ScheduleExchange armedAndAwaiting(DeviceScheduleStore store) {
  final exchange = ScheduleExchange(store);
  exchange.beginPreview(
    diffSchedule(
      baseline: store.committedAlarms,
      proposal: [
        AlarmDraft(
          id: 'wake-weekdays',
          label: 'Workday',
          enabled: true,
          localHour: 7,
          localMinute: 0,
          days: const {2, 3, 4, 5, 6},
          timezone: 'America/New_York',
          snoozeMinutes: 9,
          volume: 45,
          sound: 'gentle-1',
          source: DraftSource.manual,
        ),
      ],
      expectedRevision: store.knownRevision,
    ),
  );
  exchange.buildPreview(
    messageId: 'req-0002',
    sentAt: DateTime.utc(2026, 9, 6, 12, 0, 10),
  );
  exchange.receiveApplyToken('preview-7f93d1');
  exchange.buildApply(
    messageId: 'req-0003',
    sentAt: DateTime.utc(2026, 9, 6, 12, 0, 30),
  );
  return exchange;
}
