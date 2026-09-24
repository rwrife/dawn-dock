import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/recurrence.dart';

/// One-to-one mirror of the expectations in
/// `firmware/host/tests/recurrence_resolver_test.cpp`. The epoch-second
/// helper matches the C++ `utc_seconds` helper: same inputs, same instants.
int utcSeconds(int year, int month, int day, int hour, [int minute = 0]) =>
    DateTime.utc(year, month, day, hour, minute).millisecondsSinceEpoch ~/ 1000;

DateTime utcFrom(int epochSeconds) =>
    DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);

TimezoneRules nyGapRules() => const TimezoneRules(
  name: 'America/New_York',
  version: '2026a',
  initialUtcOffsetSeconds: -5 * 3600,
  transitions: [
    UtcOffsetTransition(
      atUtcSeconds: 1772953200, // utcSeconds(2026, 3, 8, 7)
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
      atUtcSeconds: 1793512800, // utcSeconds(2026, 11, 1, 6)
      offsetBeforeSeconds: -4 * 3600,
      offsetAfterSeconds: -5 * 3600,
    ),
  ],
);

WeeklyOccurrenceSchedule nySunday({required int hour, required int minute}) =>
    WeeklyOccurrenceSchedule(
      localHour: hour,
      localMinute: minute,
      isoWeekdayMask: 0x40, // Sunday
      timezoneName: 'America/New_York',
      timezoneRulesVersion: '2026a',
    );

const utcRules = TimezoneRules(
  name: 'Etc/UTC',
  version: '2026a',
  initialUtcOffsetSeconds: 0,
  transitions: [],
);

void main() {
  group('firmware parity: new york spring gap', () {
    test('shifts nonexistent 02:30 to earliest valid local instant', () {
      final result = resolveNextOccurrence(
        schedule: nySunday(hour: 2, minute: 30),
        rules: nyGapRules(),
        afterUtcSeconds: utcSeconds(2026, 3, 8, 0),
      );
      expect(result.status, OccurrenceResolutionStatus.resolved);
      expect(
        result.scheduledUtcSeconds,
        utcSeconds(2026, 3, 8, 7),
        reason: 'nonexistent 02:30 shifts to 03:00 EDT / 07:00 UTC',
      );
      expect(
        result.localDate,
        const CivilDate(year: 2026, month: 3, day: 8),
        reason: 'shift retains the requested local calendar date',
      );
      expect(result.resolvedLocalHour, 3);
      expect(result.resolvedLocalMinute, 0);
      expect(result.shiftedForGap, isTrue);
      expect(result.ambiguousFold, isFalse);
    });
  });

  group('firmware parity: new york fall fold', () {
    test('selects the first EDT occurrence and reports ambiguity', () {
      final result = resolveNextOccurrence(
        schedule: nySunday(hour: 1, minute: 30),
        rules: nyFoldRules(),
        afterUtcSeconds: utcSeconds(2026, 11, 1, 0),
      );
      expect(result.status, OccurrenceResolutionStatus.resolved);
      expect(
        result.scheduledUtcSeconds,
        utcSeconds(2026, 11, 1, 5, 30),
        reason: 'ambiguous 01:30 selects the first EDT occurrence',
      );
      expect(result.utcOffsetSeconds, -4 * 3600);
      expect(result.ambiguousFold, isTrue);
      expect(result.shiftedForGap, isFalse);
    });

    test(
      'after the first fold instant advances a week, never to second fold',
      () {
        final result = resolveNextOccurrence(
          schedule: nySunday(hour: 1, minute: 30),
          rules: nyFoldRules(),
          afterUtcSeconds: utcSeconds(2026, 11, 1, 5, 45),
        );
        expect(result.status, OccurrenceResolutionStatus.resolved);
        expect(
          result.scheduledUtcSeconds,
          utcSeconds(2026, 11, 8, 6, 30),
          reason: 'resolver advances a week, not to the second fold instant',
        );
      },
    );
  });

  group('firmware parity: fail-closed validation', () {
    test('mismatched timezone provenance is invalidRules', () {
      const rules = TimezoneRules(
        name: 'Europe/Berlin',
        version: '2026b',
        initialUtcOffsetSeconds: 3600,
        transitions: [],
      );
      const schedule = WeeklyOccurrenceSchedule(
        localHour: 7,
        localMinute: 0,
        isoWeekdayMask: 0x01,
        timezoneName: 'America/New_York',
        timezoneRulesVersion: '2026a',
      );
      final result = resolveNextOccurrence(
        schedule: schedule,
        rules: rules,
        afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
      );
      expect(result.status, OccurrenceResolutionStatus.invalidRules);
    });

    test('malformed schedules are invalidSchedule', () {
      const valid = WeeklyOccurrenceSchedule(
        localHour: 7,
        localMinute: 30,
        isoWeekdayMask: 0x01,
        timezoneName: 'Etc/UTC',
        timezoneRulesVersion: '2026a',
      );
      const malformed = [
        WeeklyOccurrenceSchedule(
          localHour: 7,
          localMinute: 60,
          isoWeekdayMask: 0x01,
          timezoneName: 'Etc/UTC',
          timezoneRulesVersion: '2026a',
        ),
        WeeklyOccurrenceSchedule(
          localHour: 24,
          localMinute: 30,
          isoWeekdayMask: 0x01,
          timezoneName: 'Etc/UTC',
          timezoneRulesVersion: '2026a',
        ),
        WeeklyOccurrenceSchedule(
          localHour: 7,
          localMinute: 30,
          isoWeekdayMask: 0,
          timezoneName: 'Etc/UTC',
          timezoneRulesVersion: '2026a',
        ),
        WeeklyOccurrenceSchedule(
          localHour: 7,
          localMinute: 30,
          isoWeekdayMask: 0x80,
          timezoneName: 'Etc/UTC',
          timezoneRulesVersion: '2026a',
        ),
      ];
      for (final schedule in malformed) {
        final result = resolveNextOccurrence(
          schedule: schedule,
          rules: utcRules,
          afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
        );
        expect(result.status, OccurrenceResolutionStatus.invalidSchedule);
      }
      // Sanity: the valid control itself resolves.
      expect(
        resolveNextOccurrence(
          schedule: valid,
          rules: utcRules,
          afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
        ).status,
        OccurrenceResolutionStatus.resolved,
      );
    });

    test('malformed transition chains are invalidRules', () {
      const schedule = WeeklyOccurrenceSchedule(
        localHour: 7,
        localMinute: 0,
        isoWeekdayMask: 0x01,
        timezoneName: 'Test/Zone',
        timezoneRulesVersion: '2026a',
      );
      const malformed = [
        TimezoneRules(
          name: 'Test/Zone',
          version: '2026a',
          initialUtcOffsetSeconds: 0,
          transitions: [
            UtcOffsetTransition(
              atUtcSeconds: 1772323200, // utcSeconds(2026, 3, 1, 0)
              offsetBeforeSeconds: 3600,
              offsetAfterSeconds: 7200,
            ),
          ],
        ),
        TimezoneRules(
          name: 'Test/Zone',
          version: '2026a',
          initialUtcOffsetSeconds: 0,
          transitions: [
            UtcOffsetTransition(
              atUtcSeconds: 1790812800, // utcSeconds(2026, 10, 1, 0)
              offsetBeforeSeconds: 0,
              offsetAfterSeconds: 3600,
            ),
            UtcOffsetTransition(
              atUtcSeconds: 1772323200, // utcSeconds(2026, 3, 1, 0)
              offsetBeforeSeconds: 3600,
              offsetAfterSeconds: 0,
            ),
          ],
        ),
        TimezoneRules(
          name: 'Test/Zone',
          version: '2026a',
          initialUtcOffsetSeconds: 25 * 3600,
          transitions: [],
        ),
        TimezoneRules(
          name: 'Test/Zone',
          version: '2026a',
          initialUtcOffsetSeconds: 0,
          transitions: [
            UtcOffsetTransition(
              atUtcSeconds: kInt64Max,
              offsetBeforeSeconds: 0,
              offsetAfterSeconds: 3600,
            ),
          ],
        ),
      ];
      for (final rules in malformed) {
        final result = resolveNextOccurrence(
          schedule: schedule,
          rules: rules,
          afterUtcSeconds: utcSeconds(2026, 1, 1, 0),
        );
        expect(result.status, OccurrenceResolutionStatus.invalidRules);
      }
    });

    test('maximum and minimum UTC anchors are outOfRange without overflow', () {
      const daily = WeeklyOccurrenceSchedule(
        localHour: 0,
        localMinute: 0,
        isoWeekdayMask: 0x7f,
        timezoneName: 'Etc/UTC',
        timezoneRulesVersion: '2026a',
      );
      expect(
        resolveNextOccurrence(
          schedule: daily,
          rules: utcRules,
          afterUtcSeconds: kInt64Max,
        ).status,
        OccurrenceResolutionStatus.outOfRange,
      );
      expect(
        resolveNextOccurrence(
          schedule: daily,
          rules: utcRules,
          afterUtcSeconds: kInt64Min,
        ).status,
        OccurrenceResolutionStatus.outOfRange,
      );
    });

    test(
      'west-boundary local overflow and civil-year narrowing fail closed',
      () {
        const daily = WeeklyOccurrenceSchedule(
          localHour: 0,
          localMinute: 0,
          isoWeekdayMask: 0x7f,
          timezoneName: 'Test/Fixed',
          timezoneRulesVersion: '2026a',
        );
        const west = TimezoneRules(
          name: 'Test/Fixed',
          version: '2026a',
          initialUtcOffsetSeconds: -24 * 3600,
          transitions: [],
        );
        expect(
          resolveNextOccurrence(
            schedule: daily,
            rules: west,
            afterUtcSeconds: kInt64Max - 1,
          ).status,
          OccurrenceResolutionStatus.outOfRange,
          reason: 'local candidate beyond maximum UTC fails closed',
        );
        const utcDaily = WeeklyOccurrenceSchedule(
          localHour: 0,
          localMinute: 0,
          isoWeekdayMask: 0x7f,
          timezoneName: 'Etc/UTC',
          timezoneRulesVersion: '2026a',
        );
        expect(
          resolveNextOccurrence(
            schedule: utcDaily,
            rules: utcRules,
            afterUtcSeconds: 1000000000000000000,
          ).status,
          OccurrenceResolutionStatus.outOfRange,
          reason: 'civil year outside int32 range fails closed (parity)',
        );
      },
    );
  });

  group('firmware parity: berlin, tokyo, utc rollover', () {
    test('berlin spring gap shifts 02:30 to 03:00 CEST / 01:00 UTC', () {
      const rules = TimezoneRules(
        name: 'Europe/Berlin',
        version: '2026a',
        initialUtcOffsetSeconds: 3600,
        transitions: [
          UtcOffsetTransition(
            atUtcSeconds: 1774746000, // utcSeconds(2026, 3, 29, 1)
            offsetBeforeSeconds: 3600,
            offsetAfterSeconds: 7200,
          ),
          UtcOffsetTransition(
            atUtcSeconds: 1792890000, // utcSeconds(2026, 10, 25, 1)
            offsetBeforeSeconds: 7200,
            offsetAfterSeconds: 3600,
          ),
        ],
      );
      const schedule = WeeklyOccurrenceSchedule(
        localHour: 2,
        localMinute: 30,
        isoWeekdayMask: 0x40,
        timezoneName: 'Europe/Berlin',
        timezoneRulesVersion: '2026a',
      );
      final gap = resolveNextOccurrence(
        schedule: schedule,
        rules: rules,
        afterUtcSeconds: utcSeconds(2026, 3, 29, 0),
      );
      expect(gap.status, OccurrenceResolutionStatus.resolved);
      expect(gap.scheduledUtcSeconds, utcSeconds(2026, 3, 29, 1));
      expect(gap.shiftedForGap, isTrue);
      expect(gap.resolvedLocalHour, 3);
      expect(gap.resolvedLocalMinute, 0);

      final fold = resolveNextOccurrence(
        schedule: schedule,
        rules: rules,
        afterUtcSeconds: utcSeconds(2026, 10, 25, 0),
      );
      expect(fold.status, OccurrenceResolutionStatus.resolved);
      expect(fold.scheduledUtcSeconds, utcSeconds(2026, 10, 25, 0, 30));
      expect(fold.ambiguousFold, isTrue);
      expect(fold.utcOffsetSeconds, 7200);
    });

    test('tokyo monday recurrence uses the local calendar', () {
      const tokyo = TimezoneRules(
        name: 'Asia/Tokyo',
        version: '2026a',
        initialUtcOffsetSeconds: 9 * 3600,
        transitions: [],
      );
      const monday = WeeklyOccurrenceSchedule(
        localHour: 0,
        localMinute: 30,
        isoWeekdayMask: 0x01,
        timezoneName: 'Asia/Tokyo',
        timezoneRulesVersion: '2026a',
      );
      final result = resolveNextOccurrence(
        schedule: monday,
        rules: tokyo,
        afterUtcSeconds: utcSeconds(2026, 12, 27, 15),
      );
      expect(result.status, OccurrenceResolutionStatus.resolved);
      expect(result.scheduledUtcSeconds, utcSeconds(2026, 12, 27, 15, 30));
      expect(result.localDate, const CivilDate(year: 2026, month: 12, day: 28));
    });

    test('daily utc recurrence crosses month and year boundary', () {
      const daily = WeeklyOccurrenceSchedule(
        localHour: 0,
        localMinute: 0,
        isoWeekdayMask: 0x7f,
        timezoneName: 'Etc/UTC',
        timezoneRulesVersion: '2026a',
      );
      final result = resolveNextOccurrence(
        schedule: daily,
        rules: utcRules,
        afterUtcSeconds: utcSeconds(2026, 12, 31, 23, 59),
      );
      expect(result.status, OccurrenceResolutionStatus.resolved);
      expect(result.scheduledUtcSeconds, utcSeconds(2027, 1, 1, 0));
      expect(result.localDate, const CivilDate(year: 2027, month: 1, day: 1));
    });
  });

  group('firmware parity: pacific/apia deleted Friday', () {
    test(
      'a fully deleted local date advances to the next matching weekday',
      () {
        const apia = TimezoneRules(
          name: 'Pacific/Apia',
          version: '2026a',
          initialUtcOffsetSeconds: -10 * 3600,
          transitions: [
            UtcOffsetTransition(
              atUtcSeconds: 1325239200, // utcSeconds(2011, 12, 30, 10)
              offsetBeforeSeconds: -10 * 3600,
              offsetAfterSeconds: 14 * 3600,
            ),
          ],
        );
        const friday = WeeklyOccurrenceSchedule(
          localHour: 7,
          localMinute: 0,
          isoWeekdayMask: 0x10, // Friday
          timezoneName: 'Pacific/Apia',
          timezoneRulesVersion: '2026a',
        );
        final result = resolveNextOccurrence(
          schedule: friday,
          rules: apia,
          afterUtcSeconds: utcSeconds(2011, 12, 29, 0),
        );
        expect(result.status, OccurrenceResolutionStatus.resolved);
        expect(
          result.scheduledUtcSeconds,
          utcSeconds(2012, 1, 5, 17),
          reason: 'skipped Friday advances to next Friday 07:00 local',
        );
        expect(result.localDate, const CivilDate(year: 2012, month: 1, day: 6));
        expect(result.shiftedForGap, isFalse);
      },
    );
  });

  group('draft bridge', () {
    AlarmDraft draft({int hour = 6, int minute = 15, Set<int>? days}) =>
        AlarmDraft(
          id: 'morning',
          label: 'Morning',
          enabled: true,
          localHour: hour,
          localMinute: minute,
          days: days ?? const {1, 2, 3, 4, 5},
          timezone: 'Etc/UTC',
          snoozeMinutes: 9,
          volume: 45,
          sound: 'gentle-1',
          source: DraftSource.manual,
        );

    test('fromAlarm maps ISO days to firmware weekday bits', () {
      final schedule = WeeklyOccurrenceSchedule.fromAlarm(
        draft(days: const {1}),
        timezoneRulesVersion: '2026a',
      );
      expect(schedule.isoWeekdayMask, 0x01); // Monday
      expect(
        WeeklyOccurrenceSchedule.fromAlarm(
          draft(days: const {7}),
          timezoneRulesVersion: '2026a',
        ).isoWeekdayMask,
        0x40,
      ); // Sunday
      expect(
        WeeklyOccurrenceSchedule.fromAlarm(
          draft(days: const {1, 2, 3, 4, 5, 6, 7}),
          timezoneRulesVersion: '2026a',
        ).isoWeekdayMask,
        0x7f,
      );
      expect(schedule.localHour, 6);
      expect(schedule.localMinute, 15);
      expect(schedule.timezoneName, 'Etc/UTC');
      expect(schedule.timezoneRulesVersion, '2026a');
    });

    test('a validated draft resolves through the mirrored policy', () {
      final result = resolveNextOccurrence(
        schedule: WeeklyOccurrenceSchedule.fromAlarm(
          draft(hour: 7, minute: 0, days: const {2}),
          timezoneRulesVersion: '2026a',
        ),
        rules: utcRules,
        afterUtcSeconds: utcSeconds(2026, 9, 24, 0), // Thursday
      );
      expect(result.status, OccurrenceResolutionStatus.resolved);
      expect(utcFrom(result.scheduledUtcSeconds), DateTime.utc(2026, 9, 29, 7));
      expect(result.localDate, const CivilDate(year: 2026, month: 9, day: 29));
      expect(result.localTime, '07:00');
    });
  });
}
