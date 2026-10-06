import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/schedule_exchange.dart';
import 'package:dawn_dock_companion/domain/schedule_flow_controller.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';

void main() {
  final now = DateTime.utc(2026, 9, 6, 12);
  AlarmDraft alarm([String id = 'wake-weekdays']) => AlarmDraft(
    id: id,
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
  Map<String, Object?> fixture(String name) => jsonDecode(
    File('../docs/protocol/fixtures/v1/valid/$name').readAsStringSync(),
  ) as Map<String, Object?>;
  Map<String, Object?> receipt() => fixture('event_sync_receipt.response.json');
  Map<String, Object?> conflict() =>
      fixture('error_revision_conflict.response.json');
  late DeviceScheduleStore store;
  late ScheduleFlowController controller;
  setUp(() {
    store = DeviceScheduleStore(clock: () => now)
      ..replaceAll(revision: 12, alarms: const []);
    controller = ScheduleFlowController(store);
  });
  void preview() {
    expect(controller.review([alarm()]), isTrue);
    expect(
      controller.requestPreview(messageId: 'req-0002', sentAt: now),
      isNotNull,
    );
  }

  void ready() {
    preview();
    expect(controller.receiveToken('preview-7f93d1'), isTrue);
  }

  void pending() {
    ready();
    expect(
      controller.confirmApply(messageId: 'req-0003', sentAt: now),
      isNotNull,
    );
  }

  void unchanged() {
    expect(store.knownRevision, 12);
    expect(store.committedAlarms, isEmpty);
    expect(store.lastReceipt, isNull);
  }

  test('review, token and explicit confirmation never implicitly adopt', () {
    final idle = controller.state;
    expect(idle.canPreview, isFalse);
    expect(controller.receiveToken('token'), isFalse);
    expect(controller.confirmApply(messageId: 'a', sentAt: now), isNull);
    expect(controller.receive(receipt()), isNull);
    expect(controller.review([alarm()]), isTrue);
    final review = controller.state;
    expect(review.canPreview, isTrue);
    expect(review.canConfirm, isFalse);
    unchanged();
    final request = controller.requestPreview(
      messageId: 'req-0002',
      sentAt: now,
    )!;
    expect(request['type'], 'schedule.preview');
    expect(request['expectedRevision'], 12);
    expect(controller.state.phase, ScheduleFlowPhase.previewPending);
    expect(review.phase, ScheduleFlowPhase.review); // immutable old snapshot
    expect(controller.state.canConfirm, isFalse);
    expect(controller.receive(receipt()), isNull);
    expect(controller.receiveToken('preview-7f93d1'), isTrue);
    expect(controller.state.canConfirm, isTrue);
    unchanged();
    final apply = controller.confirmApply(messageId: 'req-0003', sentAt: now)!;
    expect(apply['type'], 'schedule.apply');
    expect(
      (apply['body']! as Map)['alarms'],
      (request['body']! as Map)['alarms'],
    );
    expect((apply['body']! as Map)['applyToken'], 'preview-7f93d1');
    expect(controller.state.statusText, contains('outcome unknown'));
    unchanged();
    expect(
      controller.receive(receipt())!.disposition,
      IngestDisposition.applied,
    );
    expect(controller.state.phase, ScheduleFlowPhase.applied);
    expect(store.knownRevision, 13);
    expect(store.committedAlarms, [alarm()]);
    expect(store.lastReceipt!.alarmCount, 1);
    expect(store.lastReceipt!.receivedAtUtc, now);
    expect(controller.state.canConfirm, isFalse);
    expect(controller.receive(receipt()), isNull);
    expect(controller.review([alarm()]), isTrue);
    expect(controller.state.diff!.expectedRevision, 13);
  });

  test('invalid proposals fail closed and can be replaced by fresh review', () {
    for (final proposal in [
      [alarm(), alarm()],
      [for (var i = 0; i < 33; i++) alarm('a$i')],
    ]) {
      expect(controller.review(proposal), isFalse);
      expect(controller.state.phase, ScheduleFlowPhase.refused);
      expect(controller.state.diff, isNull);
      expect(controller.state.code, 'invalid_proposal');
      expect(controller.requestPreview(messageId: 'p', sentAt: now), isNull);
      expect(controller.confirmApply(messageId: 'a', sentAt: now), isNull);
      unchanged();
    }
    expect(controller.review([alarm()]), isTrue);
  });

  test(
    'bad preview identity and timing can be corrected without auto-preview',
    () {
      controller.review([alarm()]);
      expect(
        controller.requestPreview(messageId: 'has space', sentAt: now),
        isNull,
      );
      expect(controller.state.code, 'invalid_message_id');
      expect(controller.state.canPreview, isTrue);
      expect(
        controller.requestPreview(
          messageId: 'p',
          sentAt: now.add(const Duration(milliseconds: 1)),
        ),
        isNull,
      );
      expect(controller.state.code, 'invalid_sent_at');
      expect(controller.requestPreview(messageId: 'p', sentAt: now), isNotNull);
      expect(controller.state.code, isNull);
      unchanged();
    },
  );

  test(
    'bad token remains pending and bad apply identity remains confirmation',
    () {
      preview();
      expect(controller.receiveToken('bad token'), isFalse);
      expect(controller.state.code, 'invalid_apply_token');
      expect(controller.state.canConfirm, isFalse);
      expect(controller.receiveToken('token'), isTrue);
      expect(controller.confirmApply(messageId: 'bad id', sentAt: now), isNull);
      expect(controller.state.code, 'invalid_message_id');
      expect(controller.state.canConfirm, isTrue);
      expect(controller.confirmApply(messageId: 'a', sentAt: now), isNotNull);
      unchanged();
    },
  );

  test(
    'overlapping actions do not replace pending proposal or frame twice',
    () {
      ready();
      final diff = controller.state.diff;
      expect(controller.review([alarm('other')]), isFalse);
      expect(controller.requestPreview(messageId: 'p2', sentAt: now), isNull);
      expect(controller.receiveToken('different'), isFalse);
      expect(controller.state.diff, same(diff));
      expect(controller.confirmApply(messageId: 'a', sentAt: now), isNotNull);
      expect(controller.confirmApply(messageId: 'a2', sentAt: now), isNull);
      expect(controller.review([]), isFalse);
      expect(controller.receiveToken('t'), isFalse);
      unchanged();
    },
  );

  test('cancel works only before apply and discards token/proposal', () {
    expect(controller.cancel(), isFalse);
    controller.review([alarm()]);
    expect(controller.cancel(), isTrue);
    preview();
    expect(controller.state.canCancel, isTrue);
    expect(controller.cancel(), isTrue);
    ready();
    expect(controller.cancel(), isTrue);
    expect(controller.state.diff, isNull);
    expect(controller.confirmApply(messageId: 'a', sentAt: now), isNull);
    pending();
    expect(controller.state.canCancel, isFalse);
    expect(controller.cancel(), isFalse);
    expect(controller.state.phase, ScheduleFlowPhase.applyPending);
    unchanged();
    controller.receive(receipt());
    expect(controller.cancel(), isFalse);
  });

  test(
    'malformed, wrong-type and semantically rejected receipts keep pending',
    () {
      pending();
      expect(
        controller.receive({'type': 'event.syncReceipt'})!.disposition,
        IngestDisposition.invalid,
      );
      expect(controller.state.phase, ScheduleFlowPhase.applyPending);
      final request = fixture('schedule_preview.request.json');
      expect(controller.receive(request)!.code, 'unexpected_response');
      unchanged();
      final bad = receipt();
      (bad['body']! as Map)['alarmCount'] = 2;
      expect(controller.receive(bad)!.disposition, IngestDisposition.rejected);
      expect(controller.state.code, 'payload_semantic_error');
      expect(controller.cancel(), isFalse);
      unchanged();
      final good = receipt()..['messageId'] = 'evt-fresh';
      expect(controller.receive(good)!.disposition, IngestDisposition.applied);
    },
  );

  test(
    'replayed rejected receipt is invalid until a fresh consistent response',
    () {
      pending();
      final bad = receipt();
      (bad['body']! as Map)['appliedRevision'] = 14;
      expect(controller.receive(bad)!.disposition, IngestDisposition.rejected);
      expect(controller.receive(bad)!.disposition, IngestDisposition.invalid);
      unchanged();
      expect(controller.state.canConfirm, isFalse);
      expect(
        controller.receive(receipt()..['messageId'] = 'evt-fresh')!.disposition,
        IngestDisposition.applied,
      );
    },
  );

  test(
    'terminal supplied error requires fresh review, never retries apply',
    () {
      pending();
      final error = conflict();
      (error['body']! as Map)['code'] = 'schema_invalid';
      expect(
        controller.receive(error)!.disposition,
        IngestDisposition.rejected,
      );
      expect(controller.state.phase, ScheduleFlowPhase.refused);
      expect(controller.state.canConfirm, isFalse);
      expect(controller.confirmApply(messageId: 'again', sentAt: now), isNull);
      unchanged();
      expect(controller.review([alarm()]), isTrue);
      expect(controller.state.canPreview, isTrue);
    },
  );

  test(
    'conflict requires matching independent refresh and a new explicit review',
    () {
      pending();
      expect(
        controller.receive(conflict())!.disposition,
        IngestDisposition.conflict,
      );
      expect(controller.state.phase, ScheduleFlowPhase.needsRefresh);
      expect(controller.state.conflictRevision, 13);
      expect(controller.state.diff, isNull);
      unchanged();
      expect(controller.acknowledgeRefresh(), isFalse);
      expect(controller.review([alarm()]), isFalse);
      expect(controller.cancel(), isFalse);
      expect(controller.confirmApply(messageId: 'retry', sentAt: now), isNull);
      store.replaceAll(revision: 14, alarms: [alarm('other')]);
      expect(controller.acknowledgeRefresh(), isFalse);
      store.replaceAll(revision: 13, alarms: [alarm('other')]);
      expect(controller.acknowledgeRefresh(), isTrue);
      expect(controller.state.phase, ScheduleFlowPhase.idle);
      expect(controller.confirmApply(messageId: 'retry', sentAt: now), isNull);
      expect(controller.review([alarm()]), isTrue);
      expect(controller.state.diff!.expectedRevision, 13);
      expect(controller.state.diff!.removed.single.id, 'other');
      expect(store.committedAlarms.single.id, 'other');
    },
  );

  test('conflict without revision cannot claim mirror refresh success', () {
    pending();
    final error = conflict();
    (error['body']! as Map).remove('currentRevision');
    expect(controller.receive(error)!.disposition, IngestDisposition.conflict);
    expect(controller.state.conflictRevision, isNull);
    store.replaceAll(revision: 13, alarms: []);
    expect(controller.acknowledgeRefresh(), isFalse);
    expect(controller.state.canConfirm, isFalse);
  });

  test('mirror advancement before preview or apply forces a new review', () {
    controller.review([alarm()]);
    store.replaceAll(revision: 13, alarms: []);
    expect(controller.requestPreview(messageId: 'p', sentAt: now), isNull);
    expect(controller.state.code, 'mirror_changed');
    expect(controller.review([alarm()]), isTrue);
    controller.requestPreview(messageId: 'p', sentAt: now);
    controller.receiveToken('token');
    store.replaceAll(revision: 14, alarms: []);
    expect(controller.confirmApply(messageId: 'a', sentAt: now), isNull);
    expect(controller.state.code, 'mirror_changed');
    expect(controller.state.canConfirm, isFalse);
    expect(store.lastReceipt, isNull);
    expect(store.knownRevision, 14);
  });

  test('mirror change after apply keeps outcome unknown without overwriting refresh', () {
    pending();
    store.replaceAll(revision: 13, alarms: [alarm('other')]);
    expect(controller.receive(receipt())!.code, 'mirror_changed');
    expect(controller.state.phase, ScheduleFlowPhase.applyPending);
    expect(controller.state.statusText, contains('outcome unknown'));
    expect(controller.state.canCancel, isFalse);
    expect(store.knownRevision, 13);
    expect(store.committedAlarms.single.id, 'other');
    expect(store.lastReceipt, isNull);
  });
}
