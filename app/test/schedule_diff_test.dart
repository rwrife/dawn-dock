import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/schedule_diff.dart';
import 'package:flutter_test/flutter_test.dart';

AlarmDraft draft(
  String id, {
  String label = 'Wake',
  bool enabled = true,
  int hour = 7,
  int minute = 0,
  Set<int>? days,
  String timezone = 'America/New_York',
  int snoozeMinutes = 9,
  int volume = 45,
  String sound = 'gentle-1',
  DraftSource source = DraftSource.manual,
  ImportProvenance? provenance,
}) {
  return AlarmDraft(
    id: id,
    label: label,
    enabled: enabled,
    localHour: hour,
    localMinute: minute,
    days: days ?? {1, 2, 3, 4, 5},
    timezone: timezone,
    snoozeMinutes: snoozeMinutes,
    volume: volume,
    sound: sound,
    source: source,
    provenance: provenance,
  );
}

void main() {
  group('describeFieldChanges', () {
    test('identical drafts report no changes', () {
      final a = draft('x');
      expect(describeFieldChanges(a, draft('x')), isEmpty);
    });

    test('weekday masks compare as sets, not insertion order', () {
      final a = draft('x', days: {1, 3, 5});
      final b = draft('x', days: {5, 1, 3});
      expect(describeFieldChanges(a, b), isEmpty);
    });

    test('weekday set difference reports only days', () {
      final a = draft('x', days: {1, 2, 3, 4, 5});
      final b = draft('x', days: {1, 2, 3, 4, 5, 6, 7});
      expect(describeFieldChanges(a, b), ['days']);
    });

    test('each field maps to exactly its stable code', () {
      final base = draft('x');
      final cases = <String, AlarmDraft>{
        'label': draft('x', label: 'Other'),
        'enabled': draft('x', enabled: false),
        'local-time': draft('x', minute: 30),
        'days': draft('x', days: {1}),
        'timezone': draft('x', timezone: 'Europe/Berlin'),
        'snooze-minutes': draft('x', snoozeMinutes: 15),
        'volume': draft('x', volume: 80),
        'sound': draft('x', sound: 'chime-2'),
        'source-or-provenance': draft(
          'x',
          source: DraftSource.ics,
          provenance: const ImportProvenance(
            sourceEventId: 'evt-1',
            originLabel: 'ics',
          ),
        ),
      };
      cases.forEach((code, other) {
        expect(describeFieldChanges(base, other), [
          code,
        ], reason: 'expected exactly $code');
      });
    });

    test('hour and minute both collapse into local-time', () {
      final a = draft('x', hour: 6, minute: 45);
      final b = draft('x', hour: 7, minute: 0);
      expect(describeFieldChanges(a, b), ['local-time']);
    });

    test('provenance-only difference reports source-or-provenance', () {
      final a = draft(
        'x',
        source: DraftSource.ics,
        provenance: const ImportProvenance(
          sourceEventId: 'evt-1',
          originLabel: 'ics',
        ),
      );
      final b = draft(
        'x',
        source: DraftSource.ics,
        provenance: const ImportProvenance(
          sourceEventId: 'evt-2',
          originLabel: 'ics',
        ),
      );
      expect(describeFieldChanges(a, a), isEmpty);
      expect(describeFieldChanges(a, b), ['source-or-provenance']);
    });

    test('multiple simultaneous changes are sorted and complete', () {
      final a = draft('x');
      final b = draft(
        'x',
        label: 'Rise',
        volume: 100,
        timezone: 'Asia/Tokyo',
        enabled: false,
      );
      expect(describeFieldChanges(a, b), [
        'enabled',
        'label',
        'timezone',
        'volume',
      ]);
    });

    test('mismatched ids are rejected', () {
      expect(
        () => describeFieldChanges(draft('a'), draft('b')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the code list is unmodifiable', () {
      final codes = describeFieldChanges(draft('x'), draft('x', volume: 1));
      expect(() => codes.add('label'), throwsUnsupportedError);
    });
  });

  group('ChangedAlarm', () {
    test('constructs with sorted codes and matching id accessor', () {
      final c = ChangedAlarm(
        before: draft('x'),
        after: draft('x', volume: 10, label: 'Z'),
      );
      expect(c.id, 'x');
      expect(c.fieldCodes, ['label', 'volume']);
      expect(() => c.fieldCodes.clear(), throwsUnsupportedError);
    });

    test('refuses an equal pair', () {
      expect(
        () => ChangedAlarm(before: draft('x'), after: draft('x')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('value equality covers before/after and codes', () {
      final a = ChangedAlarm(before: draft('x'), after: draft('x', volume: 2));
      final b = ChangedAlarm(before: draft('x'), after: draft('x', volume: 2));
      final c = ChangedAlarm(before: draft('x'), after: draft('x', volume: 3));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('diffSchedule', () {
    test('empty against empty is an empty diff', () {
      final diff = diffSchedule(
        baseline: const [],
        proposal: const [],
        expectedRevision: 0,
      );
      expect(diff.isEmpty, isTrue);
      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.changed, isEmpty);
      expect(diff.unchanged, isEmpty);
      expect(diff.expectedRevision, 0);
      expect(diff.proposedOrder, isEmpty);
      expect(diff.toWirePreviewBody(), isEmpty);
    });

    test('add-only, remove-only, and change-only classification', () {
      final diff = diffSchedule(
        baseline: [draft('keep'), draft('drop'), draft('mod')],
        proposal: [draft('keep'), draft('mod', volume: 90), draft('new')],
        expectedRevision: 12,
      );
      expect(diff.added.map((a) => a.id), ['new']);
      expect(diff.removed.map((a) => a.id), ['drop']);
      expect(diff.changed.map((c) => c.id), ['mod']);
      expect(diff.changed.single.fieldCodes, ['volume']);
      expect(diff.unchanged, ['keep']);
      expect(diff.isEmpty, isFalse);
      expect(diff.expectedRevision, 12);
    });

    test('byte-reordered weekday sets are unchanged, not changed', () {
      final diff = diffSchedule(
        baseline: [
          draft('keep', days: {1, 3, 5}),
        ],
        proposal: [
          draft('keep', days: {5, 3, 1}),
        ],
        expectedRevision: 4,
      );
      expect(diff.unchanged, ['keep']);
      expect(diff.isEmpty, isTrue);
    });

    test('all groups sort by id regardless of insertion order', () {
      final diff = diffSchedule(
        baseline: [
          draft('z-old'),
          draft('m-old'),
          draft('z-stay'),
          draft('m-stay'),
        ],
        proposal: [
          draft('z-new'),
          draft('m-new'),
          draft('z-stay', volume: 1),
          draft('m-stay', volume: 1),
        ],
        expectedRevision: 7,
      );
      expect(diff.added.map((a) => a.id), ['m-new', 'z-new']);
      expect(diff.removed.map((a) => a.id), ['m-old', 'z-old']);
      expect(diff.changed.map((c) => c.id), ['m-stay', 'z-stay']);
      expect(diff.unchanged, isEmpty);
      expect(diff.proposedOrder.map((a) => a.id), [
        'm-new',
        'z-new',
        'm-stay',
        'z-stay',
      ]);
    });

    test('repeated diffs on equal state are equal and hash-equal', () {
      final baseline = [draft('a'), draft('b', volume: 2)];
      final proposal = [draft('a', label: 'A'), draft('b', volume: 2)];
      final d1 = diffSchedule(
        baseline: baseline,
        proposal: proposal,
        expectedRevision: 3,
      );
      final d2 = diffSchedule(
        baseline: baseline.reversed,
        proposal: proposal.reversed.toList().reversed,
        expectedRevision: 3,
      );
      expect(d1, d2);
      expect(d1.hashCode, d2.hashCode);
    });

    test('diffs differing in expectedRevision are unequal', () {
      final d1 = diffSchedule(
        baseline: const [],
        proposal: const [],
        expectedRevision: 1,
      );
      final d2 = diffSchedule(
        baseline: const [],
        proposal: const [],
        expectedRevision: 2,
      );
      expect(d1, isNot(d2));
    });

    test('every exposed collection is unmodifiable', () {
      final diff = diffSchedule(
        baseline: [draft('x')],
        proposal: [draft('y')],
        expectedRevision: 1,
      );
      expect(() => diff.added.clear(), throwsUnsupportedError);
      expect(() => diff.removed.clear(), throwsUnsupportedError);
      expect(() => diff.changed.clear(), throwsUnsupportedError);
      expect(() => diff.unchanged.clear(), throwsUnsupportedError);
      expect(() => diff.proposedOrder.clear(), throwsUnsupportedError);
    });

    test('capacity overflow fails closed before any diff work', () {
      final proposal = [for (var i = 0; i < 33; i++) draft('alarm-$i')];
      expect(
        () => diffSchedule(
          baseline: [draft('baseline-alarm')],
          proposal: proposal,
          expectedRevision: 1,
        ),
        throwsArgumentError,
      );
    });

    test('duplicate proposal ids fail closed', () {
      expect(
        () => diffSchedule(
          baseline: const [],
          proposal: [draft('dup'), draft('dup', volume: 9)],
          expectedRevision: 1,
        ),
        throwsArgumentError,
      );
    });

    test('a baseline alarm kept identical round-trips as unchanged', () {
      final original = draft('r', days: {2, 4});
      final roundTripped = AlarmDraft.fromMap(original.toMap());
      final diff = diffSchedule(
        baseline: [original],
        proposal: [roundTripped],
        expectedRevision: 5,
      );
      expect(diff.isEmpty, isTrue);
      expect(diff.unchanged, ['r']);
    });
  });

  group('toWirePreviewBody', () {
    test('emits exactly the wire alarm records in proposedOrder', () {
      final diff = diffSchedule(
        baseline: [draft('b-old'), draft('c-keep'), draft('a-mod')],
        proposal: [
          draft('c-keep'),
          draft('a-mod', sound: 'chime-2'),
          draft('b-new'),
        ],
        expectedRevision: 9,
      );
      final body = diff.toWirePreviewBody();
      expect(body.map((a) => a['id']), ['b-new', 'a-mod', 'c-keep']);
      for (var i = 0; i < body.length; i++) {
        expect(body[i], diff.proposedOrder[i].toWireAlarm());
      }
      expect(
        body.first.keys.toSet(),
        AlarmDraft.fromMap(draft('b-new').toMap()).toWireAlarm().keys.toSet(),
      );
    });

    test('an empty diff previews an empty alarms array', () {
      final diff = diffSchedule(
        baseline: [draft('gone')],
        proposal: const [],
        expectedRevision: 2,
      );
      expect(diff.toWirePreviewBody(), isEmpty);
      expect(diff.removed.map((a) => a.id), ['gone']);
    });
  });

  group('summaryText', () {
    test('is deterministic and lists changed, added, removed in order', () {
      final diff = diffSchedule(
        baseline: [draft('m-keep'), draft('z-drop'), draft('a-mod')],
        proposal: [draft('m-keep'), draft('a-mod', volume: 1), draft('b-add')],
        expectedRevision: 8,
      );
      final expected = [
        'Schedule review: 1 added, 1 removed, 1 changed, 1 unchanged '
            '(expected revision 8).',
        '~ a-mod: volume',
        '+ b-add: Wake 07:00',
        '- z-drop: Wake 07:00',
      ].join('\n');
      expect(diff.summaryText(), expected);
      expect(diff.summaryText(), diff.summaryText());
    });

    test('empty diff still reports counts and revision', () {
      final diff = diffSchedule(
        baseline: const [],
        proposal: const [],
        expectedRevision: 0,
      );
      expect(diff.summaryText(), contains('expected revision 0'));
      expect(diff.summaryText().split('\n'), hasLength(1));
    });
  });

  group('DraftSet integration', () {
    test('a replaceAll-shrunk set diffs without ghost entries', () {
      final set = DraftSet()
        ..put(draft('a'))
        ..put(draft('b'))
        ..put(draft('c'));
      set.replaceAll([draft('a'), draft('b', enabled: false)]);
      final diff = diffSchedule(
        baseline: [draft('a'), draft('b'), draft('c')],
        proposal: set.drafts,
        expectedRevision: 6,
      );
      expect(diff.unchanged, ['a']);
      expect(diff.changed.map((c) => c.id), ['b']);
      expect(diff.changed.single.fieldCodes, ['enabled']);
      expect(diff.removed.map((a) => a.id), ['c']);
      expect(diff.added, isEmpty);
    });
  });
}
