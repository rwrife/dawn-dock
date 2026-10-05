import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/device_status.dart';
import 'package:dawn_dock_companion/domain/recurrence.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';
import 'package:dawn_dock_companion/ui/device_status_panel.dart';

final _anchor = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch ~/ 1000;
const _rules = TimezoneRules(
  name: 'Etc/UTC',
  version: '2026a',
  initialUtcOffsetSeconds: 0,
  transitions: [],
);

AlarmDraft _alarm({
  String id = 'wake',
  String zone = 'Etc/UTC',
  int hour = 7,
  int minute = 0,
  Set<int> days = const {1, 2, 3, 4, 5},
}) => AlarmDraft(
  id: id,
  label: 'Wake',
  enabled: true,
  localHour: hour,
  localMinute: minute,
  days: days,
  timezone: zone,
  snoozeMinutes: 9,
  volume: 45,
  sound: 'gentle-1',
  source: DraftSource.manual,
);

DeviceStatusProjection _projection({
  List<AlarmDraft>? alarms,
  DateTime? receiptNext,
}) {
  final committed = alarms ?? [_alarm()];
  final store = DeviceScheduleStore()
    ..replaceAll(
      revision: 2,
      alarms: committed,
      receipt: receiptNext == null
          ? null
          : SyncReceipt(
              appliedRevision: 2,
              alarmCount: committed.length,
              nextAlarmUtc: receiptNext,
              receivedAtUtc: DateTime.utc(2026, 1, 1),
            ),
    );
  return projectDeviceStatus(
    store: store,
    afterUtcSeconds: _anchor,
    rulesProvider: (zone) => zone == 'Etc/UTC' ? _rules : null,
  );
}

Future<void> _show(WidgetTester tester, DeviceStatusProjection value) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DeviceStatusPanel(projection: value),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('projection and matching receipt are distinct text evidence', (
    tester,
  ) async {
    await _show(tester, _projection());
    expect(find.textContaining('Local projection only'), findsOneWidget);
    expect(find.byKey(const ValueKey('projected-next')), findsOneWidget);
    expect(find.textContaining('2026-01-01T07:00:00.000Z'), findsOneWidget);
    await _show(tester, _projection(receiptNext: DateTime.utc(2026, 1, 1, 7)));
    expect(find.textContaining('matches a stored receipt'), findsOneWidget);
    expect(find.textContaining('not live device status'), findsOneWidget);
  });

  testWidgets('mismatch warns instead of confirming', (tester) async {
    await _show(tester, _projection(receiptNext: DateTime.utc(2026, 1, 2, 8)));
    expect(
      find.textContaining('Warning: stored receipt disagrees'),
      findsOneWidget,
    );
    expect(find.textContaining('matches a stored receipt'), findsNothing);
  });

  testWidgets('unresolved suppresses next and diagnoses missing rules', (
    tester,
  ) async {
    await _show(
      tester,
      _projection(
        alarms: [
          _alarm(),
          _alarm(id: 'unknown', zone: 'Missing/Rules'),
        ],
      ),
    );
    expect(find.textContaining('Next alarm withheld'), findsOneWidget);
    expect(find.textContaining('missing_timezone_rules'), findsOneWidget);
    expect(find.byKey(const ValueKey('projected-next')), findsNothing);
  });

  testWidgets('empty schedule has no next alarm', (tester) async {
    await _show(tester, _projection(alarms: []));
    expect(find.textContaining('No enabled alarms'), findsOneWidget);
    expect(find.byKey(const ValueKey('projected-next')), findsNothing);
  });

  testWidgets('spring gap and autumn fold each have textual flags', (
    tester,
  ) async {
    final gap = projectDeviceStatus(
      store: DeviceScheduleStore()
        ..replaceAll(
          revision: 1,
          alarms: [
            _alarm(
              hour: 2,
              minute: 30,
              days: const {7},
              zone: 'America/New_York',
            ),
          ],
        ),
      rulesProvider: (_) => const TimezoneRules(
        name: 'America/New_York',
        version: '2026a',
        initialUtcOffsetSeconds: -18000,
        transitions: [
          UtcOffsetTransition(
            atUtcSeconds: 1772953200,
            offsetBeforeSeconds: -18000,
            offsetAfterSeconds: -14400,
          ),
        ],
      ),
      afterUtcSeconds: DateTime.utc(2026, 3, 8).millisecondsSinceEpoch ~/ 1000,
    );
    await _show(tester, gap);
    expect(find.textContaining('Spring gap: shifted'), findsOneWidget);
    final fold = projectDeviceStatus(
      store: DeviceScheduleStore()
        ..replaceAll(
          revision: 1,
          alarms: [
            _alarm(
              hour: 1,
              minute: 30,
              days: const {7},
              zone: 'America/New_York',
            ),
          ],
        ),
      rulesProvider: (_) => const TimezoneRules(
        name: 'America/New_York',
        version: '2026a',
        initialUtcOffsetSeconds: -14400,
        transitions: [
          UtcOffsetTransition(
            atUtcSeconds: 1793512800,
            offsetBeforeSeconds: -14400,
            offsetAfterSeconds: -18000,
          ),
        ],
      ),
      afterUtcSeconds: DateTime.utc(2026, 11, 1).millisecondsSinceEpoch ~/ 1000,
    );
    await _show(tester, fold);
    expect(find.textContaining('Autumn fold: first'), findsOneWidget);
  });

  testWidgets('evidence is announced as a live region', (tester) async {
    final handle = tester.ensureSemantics();
    await _show(tester, _projection());
    final node = tester.getSemantics(
      find.byKey(const ValueKey('status-evidence')),
    );
    expect(
      node,
      matchesSemantics(
        label: 'Local projection only; no matching receipt for this revision.',
        isLiveRegion: true,
      ),
    );
    handle.dispose();
  });
}
