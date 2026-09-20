import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/ics_import.dart';
import 'package:dawn_dock_companion/domain/protocol_contract.dart'
    show kMaxStoredAlarms;

/// Codes actually observed across this suite; the final test asserts the
/// declared code list is fully exercised (acceptance criterion: every notice
/// code has a dedicated test).
final Set<String> _observedCodes = {};

String wrap(List<String> lines) => [
  'BEGIN:VCALENDAR',
  'VERSION:2.0',
  'PRODID:-//dawn-dock//test//EN',
  ...lines,
  'END:VCALENDAR',
].join('\r\n');

String vevent(List<String> props) =>
    ['BEGIN:VEVENT', ...props, 'END:VEVENT'].join('\r\n');

IcsImportResult runImport(String text) {
  final result = importIcsSuggestions(text);
  for (final notice in result.notices) {
    _observedCodes.add(notice.code);
  }
  return result;
}

/// Minimal single-event import helper.
IcsImportResult importOne(List<String> eventProps) =>
    runImport(wrap([vevent(eventProps)]));

AlarmDraft onlySuggestion(IcsImportResult r) {
  expect(r.suggestions, hasLength(1));
  return r.suggestions.single;
}

Set<String> codes(IcsImportResult r) => r.notices.map((n) => n.code).toSet();

void main() {
  group('fail-closed whole-import rejections', () {
    test('input over 1 MiB throws and takes precedence over other gates', () {
      // Pure junk that also lacks BEGIN:VCALENDAR — size gate must fire.
      final huge = 'x' * (kIcsImportMaxInputBytes + 1);
      expect(
        () => importIcsSuggestions(huge),
        throwsA(isA<IcsImportInputTooLargeException>()),
      );
    });

    test('exactly 1 MiB of ASCII passes the size gate', () {
      final body = <String>[
        'BEGIN:VEVENT',
        'UID:sized',
        'DTSTART:20260901T070000',
        'END:VEVENT',
      ];
      final core = wrap(body);
      final padding = ' ' * (kIcsImportMaxInputBytes - core.length - 8);
      final text = wrap([...body, 'X-PAD:$padding']);
      expect(_utf8(text), kIcsImportMaxInputBytes);
      final result = runImport(text);
      expect(result.suggestions, hasLength(1));
    });

    test('256 events is at the limit and imports', () {
      final events = [
        for (var i = 1; i <= kIcsImportMaxEvents; i++)
          vevent(['UID:cap-$i', 'DTSTART:20260901T070000']),
      ];
      final result = runImport(wrap(events));
      // Suggestions are separately capped at kMaxStoredAlarms with a notice.
      expect(result.suggestions, hasLength(kMaxStoredAlarms));
      expect(codes(result), contains(kIcsNoticeCapacityTruncated));
    });

    test('257 events throws before any suggestion is produced', () {
      final events = [
        for (var i = 1; i <= kIcsImportMaxEvents + 1; i++)
          vevent(['UID:cap-$i']),
      ];
      expect(
        () => importIcsSuggestions(wrap(events)),
        throwsA(isA<IcsImportTooManyEventsException>()),
      );
    });

    test('missing BEGIN:VCALENDAR throws even when an event is present', () {
      expect(
        () => importIcsSuggestions(vevent(['UID:x'])),
        throwsA(isA<IcsImportNotCalendarException>()),
      );
    });

    test('empty and junk inputs throw', () {
      expect(
        () => importIcsSuggestions(''),
        throwsA(isA<IcsImportNotCalendarException>()),
      );
      expect(
        () => importIcsSuggestions('total nonsense\r\nmore nonsense'),
        throwsA(isA<IcsImportNotCalendarException>()),
      );
    });
  });

  group('parser: unfolding and text escapes', () {
    test('tab-folded SUMMARY is rejoined without the fold char', () {
      final text = wrap([
        'BEGIN:VEVENT',
        'UID:fold1',
        'DTSTART;TZID=America/New_York:20260901T070000',
        'SUMMARY:Standup fold\r\n\ttest',
        'END:VEVENT',
      ]);
      final draft = onlySuggestion(runImport(text));
      expect(draft.label, 'Standup foldtest');
    });

    test('space-folded DTSTART value is rejoined before parsing', () {
      final text = wrap([
        'BEGIN:VEVENT',
        'UID:fold2',
        'DTSTART;TZID=America/New_York:20260901T0700\r\n 00',
        'END:VEVENT',
      ]);
      final result = runImport(text);
      expect(result.suggestions, hasLength(1));
      expect(result.suggestions.single.localTime, '07:00');
    });

    test('escaped comma and newline decode; newline collapses in labels', () {
      final result = importOne([
        'UID:esc1',
        'DTSTART:20260901T070000',
        r'SUMMARY:Team\, sync\nstandup',
      ]);
      expect(onlySuggestion(result).label, 'Team, sync standup');
    });

    test('escaped semicolon, colon, and backslash decode', () {
      final result = importOne([
        'UID:esc2',
        'DTSTART:20260901T070000',
        r'SUMMARY:a\;b\:c\\d',
      ]);
      expect(onlySuggestion(result).label, 'a;b:c\\d');
    });

    test(
      'uppercase \\N escape is a newline too, and stray backslash drops',
      () {
        final result = importOne([
          'UID:esc3',
          'DTSTART:20260901T070000',
          r'SUMMARY:line1\Nline2 x trailing\',
        ]);
        expect(onlySuggestion(result).label, 'line1 line2 x trailing');
      },
    );
  });

  group('DTSTART forms', () {
    test('named TZID keeps the zone verbatim, no zone judgments', () {
      final result = importOne([
        'UID:tz1',
        'DTSTART;TZID=America/New_York:20260901T071500',
      ]);
      final draft = onlySuggestion(result);
      expect(draft.timezone, 'America/New_York');
      expect(draft.localTime, '07:15');
      expect(codes(result), isNot(contains(kIcsNoticeFloatingLocalTime)));
      expect(codes(result), isNot(contains(kIcsNoticeUtcWallTime)));
    });

    test('floating local time uses the app default zone with a notice', () {
      final result = importOne(['UID:flt', 'DTSTART:20260901T070000']);
      expect(onlySuggestion(result).timezone, kIcsImportDefaultTimezone);
      expect(codes(result), contains(kIcsNoticeFloatingLocalTime));
    });

    test('UTC (Z) form keeps wall time, stores default zone, notices once', () {
      final result = importOne(['UID:utc1', 'DTSTART:20260901T213000Z']);
      final draft = onlySuggestion(result);
      expect(draft.localTime, '21:30');
      expect(draft.timezone, kIcsImportDefaultTimezone);
      expect(codes(result), contains(kIcsNoticeUtcWallTime));
      expect(codes(result), isNot(contains(kIcsNoticeUtcTimezoneId)));
    });

    test('TZID=UTC designator emits both utc notices', () {
      final result = importOne([
        'UID:utc2',
        'DTSTART;TZID=UTC:20260901T213000',
      ]);
      expect(codes(result), contains(kIcsNoticeUtcWallTime));
      expect(codes(result), contains(kIcsNoticeUtcTimezoneId));
      expect(onlySuggestion(result).timezone, kIcsImportDefaultTimezone);
    });

    test('lowercase tzid utc is a UTC designator', () {
      final result = importOne([
        'UID:utc3',
        'DTSTART;TZID=utc:20260901T213000',
      ]);
      expect(codes(result), contains(kIcsNoticeUtcWallTime));
    });

    test('all-day VALUE=DATE defaults to midnight with a notice', () {
      final result = importOne([
        'UID:all1',
        'DTSTART;VALUE=DATE:20260901',
        'RRULE:FREQ=DAILY',
      ]);
      final draft = onlySuggestion(result);
      expect(draft.localTime, '00:00');
      expect(codes(result), contains(kIcsNoticeAllDayDefaultTime));
    });

    test('empty TZID parameter drops the event with its own code', () {
      final result = importOne(['UID:ntz', 'DTSTART;TZID=:20260901T070000']);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeMissingTzid));
    });

    test('impossible calendar dates are invalid DTSTART', () {
      for (final value in [
        '20260230T070000', // Feb 30
        '20261301T070000', // month 13
        '20260932T070000', // day 32
        '20260901T240000', // hour 24
        '20260901T076000', // minute 60
        '20260901T070061', // second 61
        '20260901T70000', // short hour
        '2026-09-01T07:00:00', // dashed
        'nonsense',
      ]) {
        final result = importOne(['UID:bad-$value', 'DTSTART:$value']);
        expect(result.suggestions, isEmpty, reason: 'should drop $value');
        expect(
          codes(result),
          contains(kIcsNoticeInvalidDtstart),
          reason: 'should notice $value',
        );
      }
    });

    test('leap day Feb 29 2028 is accepted', () {
      final result = importOne([
        'UID:leap',
        'DTSTART;TZID=America/New_York:20280229T070000',
        'RRULE:FREQ=DAILY',
      ]);
      expect(result.suggestions, hasLength(1));
    });

    test('non-leap Feb 29 2026 is rejected', () {
      final result = importOne(['UID:noleap', 'DTSTART:20260229T070000']);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeInvalidDtstart));
    });

    test('TZID shorter than the timezone field minimum is invalid DTSTART', () {
      final result = importOne([
        'UID:shorttz',
        'DTSTART;TZID=XY:20260901T070000',
      ]);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeInvalidDtstart));
    });

    test('TZID longer than the timezone field maximum is invalid DTSTART', () {
      final long = 'Z' * 65;
      final result = importOne([
        'UID:longtz',
        'DTSTART;TZID=$long:20260901T070000',
      ]);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeInvalidDtstart));
    });

    test('missing DTSTART drops with invalid-dtstart', () {
      final result = importOne(['UID:nots']);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeInvalidDtstart));
    });
  });

  group('weekday math', () {
    test('single occurrences carry the literal date weekday', () {
      // 2026-09-01 is a Tuesday (ISO 2); 2026-09-05 a Saturday (ISO 7-1).
      final tuesday = importOne([
        'UID:wed-tue',
        'DTSTART;TZID=America/New_York:20260901T070000',
      ]);
      expect(onlySuggestion(tuesday).days, {2});

      final saturday = importOne([
        'UID:wed-sat',
        'DTSTART;TZID=America/New_York:20260905T070000',
      ]);
      expect(onlySuggestion(saturday).days, {6});

      final sunday = importOne([
        'UID:wed-sun',
        'DTSTART;TZID=America/New_York:20260906T070000',
      ]);
      expect(onlySuggestion(sunday).days, {7});
    });
  });

  group('recurrence mapping', () {
    test('no RRULE expands weekly on the event weekday with a notice', () {
      final result = importOne([
        'UID:rr-none',
        'DTSTART;TZID=America/New_York:20260901T070000',
      ]);
      expect(onlySuggestion(result).days, {2});
      expect(codes(result), contains(kIcsNoticeSingleOccurrenceWeekly));
    });

    test('FREQ=DAILY maps to all seven days', () {
      final result = importOne([
        'UID:rr-daily',
        'DTSTART;TZID=America/New_York:20260901T070000',
        'RRULE:FREQ=DAILY',
      ]);
      expect(onlySuggestion(result).days, {1, 2, 3, 4, 5, 6, 7});
      expect(codes(result), isNot(contains(kIcsNoticeSingleOccurrenceWeekly)));
    });

    test('WEEKLY with BYDAY maps each named day', () {
      final result = importOne([
        'UID:rr-weekly',
        'DTSTART;TZID=America/New_York:20260901T070000',
        'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR',
      ]);
      expect(onlySuggestion(result).days, {1, 3, 5});
    });

    test('BYDAY ordinals and lowercase are tolerated', () {
      final result = importOne([
        'UID:rr-ord',
        'DTSTART;TZID=America/New_York:20260901T070000',
        'RRULE:FREQ=WEEKLY;BYDAY=+3tu,-1MO',
      ]);
      expect(onlySuggestion(result).days, {1, 2});
    });

    test('WEEKLY without BYDAY uses the event weekday with a notice', () {
      final result = importOne([
        'UID:rr-weekly-nobday',
        'DTSTART;TZID=America/New_York:20260903T070000',
        'RRULE:FREQ=WEEKLY',
      ]);
      expect(onlySuggestion(result).days, {4}); // 2026-09-03 is a Thursday
      expect(codes(result), contains(kIcsNoticeSingleOccurrenceWeekly));
    });

    test('freq is case-insensitive', () {
      final result = importOne([
        'UID:rr-case',
        'DTSTART;TZID=America/New_York:20260901T070000',
        'RRULE:freq=daily',
      ]);
      expect(onlySuggestion(result).days, {1, 2, 3, 4, 5, 6, 7});
    });

    test('COUNT and UNTIL are dropped with a recurrence-end notice', () {
      for (final rrule in [
        'FREQ=WEEKLY;BYDAY=MO;COUNT=5',
        'FREQ=WEEKLY;BYDAY=MO;UNTIL=20261201T000000Z',
        'FREQ=WEEKLY;BYDAY=MO;UNTIL=20261201',
      ]) {
        final result = importOne([
          'UID:rr-end-$rrule',
          'DTSTART;TZID=America/New_York:20260901T070000',
          'RRULE:$rrule',
        ]);
        expect(onlySuggestion(result).days, {1}, reason: rrule);
        expect(
          codes(result),
          contains(kIcsNoticeRecurrenceEndDropped),
          reason: rrule,
        );
      }
    });

    test('INTERVAL other than 1 drops as interval-not-representable', () {
      for (final value in ['2', '0', '-1', 'abc']) {
        final result = importOne([
          'UID:rr-int-$value',
          'DTSTART;TZID=America/New_York:20260901T070000',
          'RRULE:FREQ=WEEKLY;BYDAY=MO;INTERVAL=$value',
        ]);
        expect(result.suggestions, isEmpty, reason: 'INTERVAL=$value');
        expect(
          codes(result),
          contains(
            value == '2'
                ? kIcsNoticeIntervalNotRepresentable
                : kIcsNoticeUnsupportedRecurrence,
          ),
          reason: 'INTERVAL=$value',
        );
      }
    });

    test('MONTHLY, YEARLY, and BYSETPOS drop as unsupported recurrence', () {
      for (final rrule in [
        'FREQ=MONTHLY',
        'FREQ=YEARLY',
        'FREQ=MONTHLY;BYMONTHDAY=15',
        'FREQ=WEEKLY;BYSETPOS=2;BYDAY=MO',
        'FREQ=HOURLY',
        'INTERVAL=1', // no FREQ
        'FREQ=WEEKLY;BYDAY=XX',
        'FREQ=WEEKLY;BYYAY=MO',
        'FREQ=WEEKLY;BYDAY=',
      ]) {
        final result = importOne([
          'UID:rr-bad-$rrule',
          'DTSTART;TZID=America/New_York:20260901T070000',
          'RRULE:$rrule',
        ]);
        expect(result.suggestions, isEmpty, reason: rrule);
        expect(
          codes(result),
          contains(kIcsNoticeUnsupportedRecurrence),
          reason: rrule,
        );
      }
    });

    test('two RRULE properties mark the event malformed', () {
      final result = importOne([
        'UID:rr-two',
        'DTSTART;TZID=America/New_York:20260901T070000',
        'RRULE:FREQ=DAILY',
        'RRULE:FREQ=WEEKLY;BYDAY=MO',
      ]);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeMalformedEvent));
    });
  });

  group('label bounds', () {
    test('missing or blank SUMMARY defaults with a notice', () {
      final absent = importOne(['UID:lbl-none', 'DTSTART:20260901T070000']);
      expect(onlySuggestion(absent).label, kIcsDefaultLabel);
      expect(codes(absent), contains(kIcsNoticeLabelDefaulted));

      final blank = importOne([
        'UID:lbl-blank',
        'DTSTART:20260901T070000',
        'SUMMARY:   ',
      ]);
      expect(onlySuggestion(blank).label, kIcsDefaultLabel);
      expect(codes(blank), contains(kIcsNoticeLabelDefaulted));
    });

    test('ASCII labels over 48 bytes truncate with a notice', () {
      final long = 'Meeting preparation session '.padRight(80, 'x');
      final result = importOne([
        'UID:lbl-long',
        'DTSTART:20260901T070000',
        'SUMMARY:$long',
      ]);
      final label = onlySuggestion(result).label;
      expect(label.length, 48);
      expect(label, long.substring(0, 48));
      expect(codes(result), contains(kIcsNoticeLabelTruncated));
    });

    test('truncation never splits a multi-byte code point', () {
      final accented = 'é' * 25; // 50 UTF-8 bytes
      final result = importOne([
        'UID:lbl-utf8',
        'DTSTART:20260901T070000',
        'SUMMARY:$accented',
      ]);
      final label = onlySuggestion(result).label;
      expect(label, 'é' * 24); // exactly 48 bytes, no partial code point
      expect(utf8.encode(label).length, 48);
      expect(codes(result), contains(kIcsNoticeLabelTruncated));
    });

    test('emoji (4-byte code points) truncate on boundaries', () {
      final party = '🎉' * 13; // 52 bytes
      final result = importOne([
        'UID:lbl-emoji',
        'DTSTART:20260901T070000',
        'SUMMARY:$party',
      ]);
      final label = onlySuggestion(result).label;
      expect(label, '🎉' * 12); // 48 bytes
      // Not a lone surrogate: encoding the label round-trips.
      expect(utf8.decode(utf8.encode(label)), label);
    });

    test('control characters are stripped from labels', () {
      final result = importOne([
        'UID:lbl-ctl',
        'DTSTART:20260901T070000',
        'SUMMARY:alert\x07 bell\x1B[0m',
      ]);
      expect(onlySuggestion(result).label, 'alert bell[0m');
    });
  });

  group('UID handling and deterministic ids', () {
    test('derived ids are FNV-1a-64 goldens in ics- prefix form', () {
      final result = importOne([
        'UID:example-uid-1',
        'DTSTART;TZID=America/New_York:20260901T070000',
      ]);
      // Golden hashes computed independently (Python reference FNV-1a 64).
      expect(onlySuggestion(result).id, 'ics-f8a65e4e1605ff18');

      final second = importOne([
        'UID:evt-7@calendar',
        'DTSTART;TZID=America/New_York:20260901T070000',
      ]);
      expect(onlySuggestion(second).id, 'ics-14383bb3335e487c');
    });

    test('same input yields byte-identical ids across runs', () {
      final a = importOne([
        'UID:stable',
        'DTSTART;TZID=America/New_York:20260901T070000',
      ]);
      final b = importOne([
        'UID:stable',
        'DTSTART;TZID=America/New_York:20260901T070000',
      ]);
      expect(a.suggestions.single.id, b.suggestions.single.id);
      expect(a.suggestions.single, b.suggestions.single);
    });

    test('duplicate UIDs stay importable with suffixed ids and a notice', () {
      final result = runImport(
        wrap([
          vevent([
            'UID:dup-uid',
            'DTSTART;TZID=America/New_York:20260901T070000',
          ]),
          vevent([
            'UID:dup-uid',
            'DTSTART;TZID=America/New_York:20260902T080000',
          ]),
        ]),
      );
      expect(result.suggestions, hasLength(2));
      expect(result.suggestions[0].id, 'ics-b1c8f44d75465381');
      expect(result.suggestions[1].id, 'ics-b1c8f44d75465381-2');
      expect(
        result.notices
            .where((n) => n.code == kIcsNoticeDuplicateUid)
            .single
            .eventNumber,
        2,
      );
      // Provenance keeps the ORIGINAL uid, not the suffixed id.
      expect(result.suggestions[1].provenance?.sourceEventId, 'dup-uid');
    });

    test('missing UID drops with a notice', () {
      final result = importOne([
        'DTSTART:20260901T070000',
        'SUMMARY:No identity',
      ]);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeMissingUid));
    });

    test('oversized UID drops with a notice', () {
      final hugeUid = 'u' * 129; // > kMaxSourceEventIdBytes (128)
      final result = importOne(['UID:$hugeUid', 'DTSTART:20260901T070000']);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeOversizedUid));
    });

    test('128-byte UID is at the bound and imports', () {
      final edgeUid = 'u' * 128;
      final result = importOne(['UID:$edgeUid', 'DTSTART:20260901T070000']);
      expect(result.suggestions, hasLength(1));
      expect(result.suggestions.single.provenance?.sourceEventId, edgeUid);
    });
  });

  group('provenance and wire shape', () {
    test('suggestions carry ics provenance and wire-legal fields', () {
      final draft = onlySuggestion(
        importOne([
          'UID:prov-1',
          'SUMMARY:Morning standup',
          'DTSTART;TZID=Europe/Paris:20260901T090000',
          'RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
        ]),
      );
      expect(draft.source, DraftSource.ics);
      expect(draft.provenance, isNotNull);
      expect(draft.provenance!.sourceEventId, 'prov-1');
      expect(draft.provenance!.originLabel, 'ics');

      final wire = draft.toWireAlarm();
      expect(wire['source'], 'ics');
      expect(wire['sourceEventId'], 'prov-1');
      expect(wire['label'], 'Morning standup');
      expect(wire['localTime'], '09:00');
      expect(wire['days'], [0, 1, 2, 3, 4]); // wire days are 0..6 Mon..Fri
      expect(wire['timezone'], 'Europe/Paris');
      expect(draft.days, {1, 2, 3, 4, 5});
    });
  });

  group('structural exclusion of unretained content', () {
    test('description, attendee, location never reach any result field', () {
      final text = wrap([
        vevent([
          'UID:secret-1',
          'SUMMARY:Doctor appointment',
          'DTSTART;TZID=America/New_York:20260901T083000',
          'DESCRIPTION:SECRET-DESCRIPTION-should-never-appear',
          'LOCATION:SECRET-LOCATION-should-never-appear',
          'ATTENDEE:mailto:SECRET-ATTENDEE@should-never-appear.test',
          'ORGANIZER:mailto:SECRET-ORGANIZER@should-never-appear.test',
          'CATEGORIES:SECRET-CATEGORY',
          'COMMENT:SECRET-COMMENT',
          'CONTACT:SECRET-CONTACT',
          'URL:https://SECRET-URL.example/leak',
        ]),
      ]);
      final result = runImport(text);
      expect(result.suggestions, hasLength(1));
      final serialized = jsonEncode([
        ...result.suggestions.map((d) => d.toMap()),
        ...result.notices.map((n) => n.toMap()),
      ]);
      for (final secret in [
        'SECRET-DESCRIPTION',
        'SECRET-LOCATION',
        'SECRET-ATTENDEE',
        'SECRET-ORGANIZER',
        'SECRET-CATEGORY',
        'SECRET-COMMENT',
        'SECRET-CONTACT',
        'SECRET-URL',
      ]) {
        expect(serialized, isNot(contains(secret)), reason: secret);
      }
    });

    test('VTIMEZONE blocks and their properties are never retained', () {
      final text =
          'BEGIN:VCALENDAR\r\n'
          'BEGIN:VTIMEZONE\r\n'
          'TZID:America/New_York\r\n'
          'BEGIN:DAYLIGHT\r\n'
          'TZOFFSETFROM:-0500\r\n'
          'TZNAME:SECRET-TZNAME\r\n'
          'END:DAYLIGHT\r\n'
          'END:VTIMEZONE\r\n'
          '${vevent(['UID:vtz', 'DTSTART;TZID=America/New_York:20260901T070000'])}\r\n'
          'END:VCALENDAR';
      final result = runImport(text);
      expect(result.suggestions, hasLength(1));
      expect(
        jsonEncode(result.suggestions.map((d) => d.toMap()).toList()),
        isNot(contains('SECRET-TZNAME')),
      );
    });

    test('calendar outside any VEVENT is ignored entirely', () {
      final text = [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'SUMMARY:orphan-summary',
        'DESCRIPTION:orphan-description',
        'END:VCALENDAR',
      ].join('\r\n');
      final result = runImport(text);
      expect(result.suggestions, isEmpty);
      expect(result.notices, isEmpty);
    });
  });

  group('malformed events', () {
    test('duplicate SUMMARY marks the event malformed', () {
      final result = importOne([
        'UID:m1',
        'DTSTART:20260901T070000',
        'SUMMARY:one',
        'SUMMARY:two',
      ]);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeMalformedEvent));
    });

    test('duplicate UID property is malformed', () {
      final result = importOne([
        'UID:m2a',
        'UID:m2b',
        'DTSTART:20260901T070000',
      ]);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeMalformedEvent));
    });

    test('nested BEGIN:VEVENT and missing END:VEVENT are malformed', () {
      final nested = runImport(
        'BEGIN:VCALENDAR\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:m3\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:inner\r\n'
        'END:VEVENT\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR',
      );
      expect(nested.suggestions, isEmpty);
      expect(
        nested.notices.where((n) => n.code == kIcsNoticeMalformedEvent),
        isNotEmpty,
      );

      final unterminated = runImport(
        'BEGIN:VCALENDAR\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:m4\r\n'
        'DTSTART:20260901T070000\r\n'
        'END:VCALENDAR',
      );
      expect(unterminated.suggestions, isEmpty);
      expect(
        unterminated.notices.where((n) => n.code == kIcsNoticeMalformedEvent),
        isNotEmpty,
      );
    });

    test('a colonless junk line inside an event is malformed', () {
      final result = importOne([
        'UID:m5',
        'DTSTART:20260901T070000',
        'THIS LINE HAS NO COLON',
      ]);
      expect(result.suggestions, isEmpty);
      expect(codes(result), contains(kIcsNoticeMalformedEvent));
    });

    test('good events import around a dropped malformed neighbor', () {
      final result = runImport(
        wrap([
          vevent(['UID:ok-a', 'DTSTART:20260901T070000', 'SUMMARY:A']),
          vevent(['UID:bad', 'DUPLICATE', 'SUMMARY:x', 'SUMMARY:y']),
          vevent(['UID:ok-b', 'DTSTART:20260902T070000', 'SUMMARY:B']),
        ]),
      );
      expect(result.suggestions.map((d) => d.label), ['A', 'B']);
    });
  });

  group('capacity', () {
    test('suggestions cap at kMaxStoredAlarms in file order', () {
      final events = [
        for (var i = 1; i <= kMaxStoredAlarms + 3; i++)
          vevent([
            'UID:cap-$i',
            'SUMMARY:Alarm ${String.fromCharCode(64 + i)}',
            'DTSTART;TZID=America/New_York:2026090${(i % 9) + 1}T070000',
          ]),
      ];
      final result = runImport(wrap(events));
      expect(result.suggestions, hasLength(kMaxStoredAlarms));
      // File order: first kMaxStoredAlarms UIDs survived, in order.
      final expectedIds = [
        for (var i = 1; i <= kMaxStoredAlarms; i++) 'ics-${fnvHex('cap-$i')}',
      ];
      expect(result.suggestions.map((d) => d.id).toList(), expectedIds);

      final truncation = result.notices
          .where((n) => n.code == kIcsNoticeCapacityTruncated)
          .toList();
      expect(truncation, hasLength(1));
      expect(truncation.single.eventNumber, kMaxStoredAlarms + 1);
    });

    test('dropped-by-error events do not consume suggestion capacity', () {
      final events = <String>[];
      for (var i = 1; i <= kMaxStoredAlarms - 1; i++) {
        events.add(vevent(['UID:keep-$i', 'DTSTART:20260901T070000']));
      }
      // 31 valid events, then a malformed one, then a valid trailing event.
      // If a dropped event consumed a slot, `tail` (file position 33) would
      // fall past the 32-suggestion cap; it must instead take slot 32.
      events.insert(
        kMaxStoredAlarms ~/ 2,
        vevent(['UID:zap', 'SUMMARY:a', 'SUMMARY:b']),
      );
      events.add(vevent(['UID:tail', 'DTSTART:20260901T070000']));
      final result = runImport(wrap(events));
      expect(result.suggestions, hasLength(kMaxStoredAlarms));
      final tailHash = fnvHex('tail');
      expect(
        result.suggestions.any((d) => d.id == 'ics-$tailHash'),
        isTrue,
        reason: 'trailing event should fill the freed slot',
      );
      expect(
        codes(result),
        isNot(contains(kIcsNoticeCapacityTruncated)),
        reason: 'no event was dropped for capacity here',
      );
    });
  });

  group('notices', () {
    test('notice event numbers follow file order', () {
      final result = runImport(
        wrap([
          vevent(['UID:n-1', 'DTSTART:20260901T070000']),
          vevent(['DTSTART:20260902T070000']), // missing UID
          vevent(['UID:n-3', 'DTSTART;VALUE=DATE:20260903']),
        ]),
      );
      final byEvent = {for (final n in result.notices) n.eventNumber: n.code};
      // Event 1: floating + weekly expansion. Event 2: missing-uid.
      expect(byEvent.keys, containsAll(<int>[1, 2, 3]));
      expect(
        result.notices
            .where((n) => n.code == kIcsNoticeMissingUid)
            .single
            .eventNumber,
        2,
      );
    });

    test('clean single import emits only expected expansion notices', () {
      final result = importOne([
        'UID:clean',
        'SUMMARY:Standup',
        'DTSTART;TZID=Europe/Berlin:20260907T090000',
        'RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      ]);
      expect(result.notices, isEmpty);
    });

    test('notice maps round-trip their fields', () {
      const notice = IcsImportNotice(
        code: kIcsNoticeFloatingLocalTime,
        eventNumber: 7,
        detail: 'x',
      );
      final map = notice.toMap();
      expect(map['code'], kIcsNoticeFloatingLocalTime);
      expect(map['eventNumber'], 7);
      expect(map['detail'], 'x');
    });

    test('every declared notice code was exercised by this suite', () {
      expect(
        _observedCodes,
        containsAll(kIcsImportNoticeCodes),
        reason: 'each notice code needs a dedicated test above',
      );
    });

    test('declared code list is unique and slug-formatted', () {
      expect(
        kIcsImportNoticeCodes.toSet(),
        hasLength(kIcsImportNoticeCodes.length),
      );
      final slug = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');
      for (final code in kIcsImportNoticeCodes) {
        expect(slug.hasMatch(code), isTrue, reason: code);
      }
    });
  });

  group('round-trip equality', () {
    test('a suggestion survives AlarmDraft map round-trip identically', () {
      final original = onlySuggestion(
        importOne([
          'UID:rt-1',
          'SUMMARY:Round-trip check',
          'DTSTART;TZID=Asia/Tokyo:20260901T063000',
          'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR',
        ]),
      );
      final restored = AlarmDraft.fromMap(original.toMap());
      expect(restored, original);
      expect(restored.provenance, original.provenance);
      expect(restored.toWireAlarm()['sourceEventId'], 'rt-1');
    });

    test('all suggestions in a mixed file round-trip', () {
      final result = runImport(
        wrap([
          vevent([
            'UID:rt-a',
            'SUMMARY:Gym',
            'DTSTART;TZID=America/Chicago:20260901T180000',
            'RRULE:FREQ=WEEKLY;BYDAY=MO,WE',
          ]),
          vevent(['UID:rt-b', 'SUMMARY:Medication', 'DTSTART:20260901T080000']),
          vevent([
            'UID:rt-c',
            'DTSTART;VALUE=DATE:20260915',
            'RRULE:FREQ=DAILY;COUNT=7',
          ]),
        ]),
      );
      expect(result.suggestions, hasLength(3));
      for (final draft in result.suggestions) {
        expect(AlarmDraft.fromMap(draft.toMap()), draft);
      }
    });
  });

  test('every suggestion validates against the draft contract', () {
    List<String> eventFor(int i, String dtstart, String? rrule) => [
      'UID:contract-$i',
      'SUMMARY:Case $i',
      'DTSTART$dtstart',
      if (rrule != null) 'RRULE:$rrule',
    ];
    final result = runImport(
      wrap([
        vevent(
          eventFor(
            0,
            ';TZID=America/New_York:20260901T070000',
            'FREQ=WEEKLY;BYDAY=MO',
          ),
        ),
        vevent(eventFor(1, ';TZID=Asia/Tokyo:20260902T235900', 'FREQ=DAILY')),
        vevent(eventFor(2, ':20260903T000000', null)),
        vevent(eventFor(3, ';TZID=UTC:20260904T120000Z', 'FREQ=WEEKLY')),
      ]),
    );
    expect(result.suggestions, hasLength(4));
    for (final draft in result.suggestions) {
      // AlarmDraft self-validates in its constructor; fromMap proves the
      // serialized map re-passes every wire bound.
      expect(AlarmDraft.fromMap(draft.toMap()), draft);
    }
  });
}

int _utf8(String value) => utf8.encode(value).length;

/// Independent (non-importer-source) FNV-1a 64-bit reference for capacity
/// tests, implemented with 128-bit-exact BigInt math so it cannot share a
/// bug with the production implementation.
String fnvHex(String value) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final byte in utf8.encode(value)) {
    hash = (hash ^ BigInt.from(byte)) * prime & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
