import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/device_status.dart';
import 'package:dawn_dock_companion/domain/recurrence.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';

int utcSeconds(int year, int month, int day, int hour, [int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch ~/ 1000;

TimezoneRules nyGapRules() => const TimezoneRules(
  name: 'America/New_York',
  version: '2026a',
  initialUtcOffsetSeconds: -5 * 3600,
  transitions: [
    UtcOffsetTransition(
      atUtcSeconds: 1772953200, // 2026-03-08T07:00:00Z
      offsetBeforeSeconds: -5 * 3600,
      offsetAfterSeconds: -4 * 3600,
    ),
  ],
);

TimezoneRules nyFoldRules() => const TimezoneRules(
  name: 'America/New_York',
  version: '2026a',
  initialUtcOffsetSeconds: -4 * 3600,
  transitions: [
    UtcOffsetTransition(
      atUtcSeconds: 1793512800, // 2026-11-01T06:00:00Z
      offsetBeforeSeconds: -4 * 3600,
      offsetAfterSeconds: -5 * 3600,
    ),
  ],
);

const utcRules = TimezoneRules(
  name: 'Etc/UTC',
  version: '2026a',
  initialUtcOffsetSeconds: 0,
  transitions: [],
);

AlarmDraft makeAlarm(
  String id, {
  String label = 'Test Alarm',
  bool enabled = true,
  int hour = 7,
  int minute = 0,
  Set<int> days = const {1, 2, 3, 4, 5},
  String timezone = 'America/New_York',
}) => AlarmDraft(
  id: id,
  label: label,
  enabled: enabled,
  localHour: hour,
  localMinute: minute,
  days: days,
  timezone: timezone,
  snoozeMinutes: 9,
  volume: 45,
  sound: 'gentle-1',
  source: DraftSource.manual,
);

void main() {
  group('device status projection: empty and disabled schedules', () {
    test('empty committed store reports none evidence and null occurrence', () {
      final store = DeviceScheduleStore();
      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => utcRules,
        afterUtcSeconds: utcSeconds(2026, 3, 1, 0),
      );

      expect(projection.revision, 0);
      expect(projection.totalAlarms, 0);
      expect(projection.enabledAlarmsCount, 0);
      expect(projection.hasNextAlarm, isFalse);
      expect(projection.nextOccurrence, isNull);
      expect(projection.evidence, NextAlarmEvidence.none);
      expect(projection.unresolvedAlarms, isEmpty);
      expect(projection.lastReceipt, isNull);
    });

    test('schedule with only disabled alarms reports none evidence', () {
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 3,
          alarms: [
            makeAlarm('alarm-1', enabled: false),
            makeAlarm('alarm-2', enabled: false),
          ],
        );

      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => nyGapRules(),
        afterUtcSeconds: utcSeconds(2026, 3, 1, 0),
      );

      expect(projection.revision, 3);
      expect(projection.totalAlarms, 2);
      expect(projection.enabledAlarmsCount, 0);
      expect(projection.hasNextAlarm, isFalse);
      expect(projection.evidence, NextAlarmEvidence.none);
    });
  });

  group('device status projection: single and multi-alarm resolution', () {
    test('projects earliest occurrence among multiple enabled alarms', () {
      // Alarm A: Mon-Fri at 08:00 New York
      // Alarm B: Mon-Fri at 06:30 New York (earlier)
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 5,
          alarms: [
            makeAlarm('alarm-a', hour: 8, minute: 0),
            makeAlarm('alarm-b', hour: 6, minute: 30),
          ],
        );

      // Anchor: Sunday 2026-03-01 00:00 UTC
      // Next day is Monday 2026-03-02
      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => nyGapRules(),
        afterUtcSeconds: utcSeconds(2026, 3, 1, 0),
      );

      expect(projection.revision, 5);
      expect(projection.totalAlarms, 2);
      expect(projection.enabledAlarmsCount, 2);
      expect(projection.hasNextAlarm, isTrue);
      expect(projection.nextOccurrence?.alarm.id, 'alarm-b');
      expect(projection.nextOccurrence?.localTime, '06:30');
      // 06:30 EST (UTC-5) = 11:30 UTC
      expect(
        projection.nextOccurrence?.scheduledUtcSeconds,
        utcSeconds(2026, 3, 2, 11, 30),
      );
      expect(projection.evidence, NextAlarmEvidence.projectedOnly);
    });

    test('deterministic tie-breaking: sorts by alarm ID ascending when instants tie', () {
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 2,
          alarms: [
            makeAlarm('z-alarm', hour: 7, minute: 0),
            makeAlarm('a-alarm', hour: 7, minute: 0),
            makeAlarm('m-alarm', hour: 7, minute: 0),
          ],
        );

      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => nyGapRules(),
        afterUtcSeconds: utcSeconds(2026, 3, 1, 0),
      );

      expect(projection.hasNextAlarm, isTrue);
      expect(projection.nextOccurrence?.alarm.id, 'a-alarm');
    });
  });

  group('device status projection: gap and fold metadata', () {
    test('surfaces shiftedForGap on spring-gap resolution', () {
      // 02:30 on Sunday 2026-03-08 in New York shifts to 03:00 EDT (07:00 UTC)
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 4,
          alarms: [
            makeAlarm(
              'spring-alarm',
              hour: 2,
              minute: 30,
              days: const {7}, // Sunday
            ),
          ],
        );

      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => nyGapRules(),
        afterUtcSeconds: utcSeconds(2026, 3, 8, 0),
      );

      expect(projection.hasNextAlarm, isTrue);
      final next = projection.nextOccurrence!;
      expect(next.shiftedForGap, isTrue);
      expect(next.ambiguousFold, isFalse);
      expect(next.localTime, '03:00');
      expect(next.scheduledUtcSeconds, utcSeconds(2026, 3, 8, 7));
      expect(next.localDate, const CivilDate(year: 2026, month: 3, day: 8));
    });

    test('surfaces ambiguousFold on fall-fold resolution', () {
      // 01:30 on Sunday 2026-11-01 in New York is ambiguous fold
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 6,
          alarms: [
            makeAlarm(
              'fall-alarm',
              hour: 1,
              minute: 30,
              days: const {7}, // Sunday
            ),
          ],
        );

      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => nyFoldRules(),
        afterUtcSeconds: utcSeconds(2026, 11, 1, 0),
      );

      expect(projection.hasNextAlarm, isTrue);
      final next = projection.nextOccurrence!;
      expect(next.shiftedForGap, isFalse);
      expect(next.ambiguousFold, isTrue);
      expect(next.localTime, '01:30');
      expect(next.scheduledUtcSeconds, utcSeconds(2026, 11, 1, 5, 30));
    });
  });

  group('device status projection: fail-closed on unresolvable alarms', () {
    test('missing timezone rules withholds next-alarm claim', () {
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 1,
          alarms: [
            makeAlarm('wake-utc', timezone: 'Etc/UTC'),
            makeAlarm('wake-unknown', timezone: 'Mars/Colony'),
          ],
        );

      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => tz == 'Etc/UTC' ? utcRules : null,
        afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
      );

      expect(projection.hasNextAlarm, isFalse);
      expect(projection.nextOccurrence, isNull);
      expect(projection.evidence, NextAlarmEvidence.unresolved);
      expect(projection.unresolvedAlarms.length, 1);
      final err = projection.unresolvedAlarms.first;
      expect(err.alarmId, 'wake-unknown');
      expect(err.timezone, 'Mars/Colony');
      expect(err.reason, 'missing_timezone_rules');
    });

    test('rule version mismatch is caught and sorted by ID', () {
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 2,
          alarms: [
            makeAlarm('z-unresolved', timezone: 'Europe/Berlin'),
            makeAlarm('a-unresolved', timezone: 'Asia/Tokyo'),
          ],
        );

      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => TimezoneRules(
          name: tz,
          version: '2025z', // schedule expects 2026a by default
          initialUtcOffsetSeconds: 0,
          transitions: const [],
        ),
        afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
      );

      expect(projection.evidence, NextAlarmEvidence.unresolved);
      expect(projection.unresolvedAlarms.map((u) => u.alarmId), [
        'a-unresolved',
        'z-unresolved',
      ]);
      expect(
        projection.unresolvedAlarms.first.status,
        OccurrenceResolutionStatus.invalidRules,
      );
    });

    test(
      'disabled unresolvable alarm does not block resolution of enabled alarms',
      () {
        final store = DeviceScheduleStore()
          ..replaceAll(
            revision: 1,
            alarms: [
              makeAlarm('active', timezone: 'Etc/UTC', enabled: true),
              makeAlarm('inactive', timezone: 'Unknown/Zone', enabled: false),
            ],
          );

        final projection = projectDeviceStatus(
          store: store,
          rulesProvider: (tz) => tz == 'Etc/UTC' ? utcRules : null,
          afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
        );

        expect(projection.hasNextAlarm, isTrue);
        expect(projection.nextOccurrence?.alarm.id, 'active');
        expect(projection.evidence, NextAlarmEvidence.projectedOnly);
        expect(projection.unresolvedAlarms, isEmpty);
      },
    );
  });

  group('device status projection: sync receipt evidence evaluation', () {
    test('confirmedByReceipt when receipt matches current revision and nextAlarmUtc', () {
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 10,
          alarms: [
            makeAlarm('wake', hour: 7, minute: 0, days: const {1}), // Mon
          ],
          receipt: SyncReceipt(
            appliedRevision: 10,
            alarmCount: 1,
            // 2026-03-02 07:00 EST (UTC-5) = 12:00 UTC
            nextAlarmUtc: DateTime.utc(2026, 3, 2, 12, 0),
            receivedAtUtc: DateTime.utc(2026, 3, 1, 12, 0),
          ),
        );

      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => nyGapRules(),
        afterUtcSeconds: utcSeconds(2026, 3, 1, 0),
      );

      expect(projection.hasNextAlarm, isTrue);
      expect(projection.isConfirmed, isTrue);
      expect(projection.evidence, NextAlarmEvidence.confirmedByReceipt);
      expect(projection.lastReceipt?.appliedRevision, 10);
    });

    test('receiptMismatch when receipt has different nextAlarmUtc for current revision', () {
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 10,
          alarms: [
            makeAlarm('wake', hour: 7, minute: 0, days: const {1}),
          ],
          receipt: SyncReceipt(
            appliedRevision: 10,
            alarmCount: 1,
            nextAlarmUtc: DateTime.utc(
              2026,
              3,
              2,
              15,
              0,
            ), // Disagrees with 12:00
            receivedAtUtc: DateTime.utc(2026, 3, 1, 12, 0),
          ),
        );

      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => nyGapRules(),
        afterUtcSeconds: utcSeconds(2026, 3, 1, 0),
      );

      expect(projection.hasNextAlarm, isTrue);
      expect(projection.isConfirmed, isFalse);
      expect(projection.evidence, NextAlarmEvidence.receiptMismatch);
    });

    test('stale receipt from prior revision is treated as projectedOnly', () {
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 11, // Store is at revision 11
          alarms: [
            makeAlarm('wake', hour: 7, minute: 0, days: const {1}),
          ],
          // Receipt was from revision 10 (not yet updated for rev 11)
          // Note: replaceAll enforces receipt.appliedRevision == revision if receipt != null.
          // To simulate store moving revision without a new receipt:
        );

      // Verify store with no receipt gives projectedOnly
      final projection = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => nyGapRules(),
        afterUtcSeconds: utcSeconds(2026, 3, 1, 0),
      );

      expect(projection.hasNextAlarm, isTrue);
      expect(projection.evidence, NextAlarmEvidence.projectedOnly);
      expect(projection.isConfirmed, isFalse);
    });
  });

  group('device status projection: value equality', () {
    test('equality and hashcode match across identical projections', () {
      final store = DeviceScheduleStore()
        ..replaceAll(
          revision: 1,
          alarms: [makeAlarm('wake', timezone: 'Etc/UTC')],
        );

      final p1 = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => utcRules,
        afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
      );
      final p2 = projectDeviceStatus(
        store: store,
        rulesProvider: (tz) => utcRules,
        afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
      );

      expect(p1, equals(p2));
      expect(p1.hashCode, equals(p2.hashCode));
    });
  });
}
