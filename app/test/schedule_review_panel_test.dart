import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/schedule_diff.dart';
import 'package:dawn_dock_companion/ui/schedule_review_panel.dart';

AlarmDraft _alarm({
  required String id,
  String label = 'Workday',
  int localHour = 7,
  int localMinute = 0,
  Set<int> days = const {1, 2, 3, 4, 5},
}) => AlarmDraft(
  id: id,
  label: label,
  enabled: true,
  localHour: localHour,
  localMinute: localMinute,
  days: days,
  timezone: 'America/New_York',
  snoozeMinutes: 9,
  volume: 45,
  sound: 'gentle-1',
  source: DraftSource.manual,
);

/// Baseline the panel treats as committed.
final List<AlarmDraft> _baseline = [
  _alarm(id: 'weekday-rise'),
  _alarm(id: 'saturday-chore', label: 'Chores', localHour: 9),
];

/// Proposal with one changed (7:00 -> 7:30), one added, one removed.
final List<AlarmDraft> _proposal = [
  _alarm(id: 'weekday-rise', localMinute: 30),
  _alarm(id: 'weekend-hike', label: 'Hike', localHour: 8, days: const {6, 7}),
];

String _statusMessage(WidgetTester tester) =>
    tester
        .widget<Text>(find.byKey(const ValueKey('schedule-review-status')))
        .data ??
    '';

bool _confirmEnabled(WidgetTester tester) {
  final button = tester.widget<FilledButton>(
    find.byKey(const ValueKey('confirm-review')),
  );
  return button.onPressed != null;
}

Future<void> _mount(
  WidgetTester tester, {
  required Iterable<AlarmDraft> baseline,
  required Iterable<AlarmDraft> proposal,
  int expectedRevision = 3,
  void Function(ScheduleDiff)? onConfirm,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ScheduleReviewPanel(
          baseline: baseline,
          proposal: proposal,
          expectedRevision: expectedRevision,
          onConfirm: onConfirm ?? (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders counts status and one line per diff entry', (
    tester,
  ) async {
    await _mount(tester, baseline: _baseline, proposal: _proposal);

    expect(find.text('Schedule review'), findsOneWidget);
    expect(
      _statusMessage(tester),
      'Review status: 1 added, 1 removed, 1 changed, 0 unchanged '
      '(expected revision 3).',
    );
    expect(find.text('~ weekday-rise: local-time'), findsOneWidget);
    expect(find.text('+ weekend-hike: Hike 08:00'), findsOneWidget);
    expect(find.text('- saturday-chore: Chores 09:00'), findsOneWidget);
    expect(_confirmEnabled(tester), isTrue);
    expect(find.byKey(const ValueKey('local-only-notice')), findsOneWidget);
  });

  testWidgets('detail lines match the domain summaryText wording exactly', (
    tester,
  ) async {
    await _mount(tester, baseline: _baseline, proposal: _proposal);

    final domain = diffSchedule(
      baseline: _baseline,
      proposal: _proposal,
      expectedRevision: 3,
    );
    final detailLines = domain.summaryText().split('\n').skip(1);
    for (final line in detailLines) {
      expect(
        find.text(line),
        findsOneWidget,
        reason: 'rendered lines must equal summaryText lines: $line',
      );
    }
  });

  testWidgets('changed alarm lists every differing stable field code', (
    tester,
  ) async {
    final after = _alarm(
      id: 'weekday-rise',
      label: 'Standup',
      localMinute: 30,
      days: const {1, 2, 3, 4, 5},
    );
    await _mount(
      tester,
      baseline: [_alarm(id: 'weekday-rise')],
      proposal: [after.copyWith(volume: 60)],
    );

    expect(
      find.text('~ weekday-rise: label, local-time, volume'),
      findsOneWidget,
    );
  });

  testWidgets('empty diff reports no changes and still confirms', (
    tester,
  ) async {
    ScheduleDiff? confirmed;
    await _mount(
      tester,
      baseline: _baseline,
      proposal: _baseline,
      onConfirm: (d) => confirmed = d,
    );

    expect(_statusMessage(tester), startsWith('Review status: no changes'));
    expect(find.textContaining('expected revision 3'), findsWidgets);
    expect(_confirmEnabled(tester), isTrue);

    await tester.tap(find.byKey(const ValueKey('confirm-review')));
    await tester.pump();
    expect(confirmed, isNotNull);
    expect(confirmed!.isEmpty, isTrue);
  });

  testWidgets('duplicate-id proposal is refused and confirm is disabled', (
    tester,
  ) async {
    ScheduleDiff? confirmed;
    await _mount(
      tester,
      baseline: _baseline,
      proposal: [
        _alarm(id: 'weekday-rise'),
        _alarm(id: 'weekday-rise', localMinute: 30),
      ],
      onConfirm: (d) => confirmed = d,
    );

    final message = _statusMessage(tester);
    expect(message, contains('proposal refused'));
    expect(message, contains('duplicate alarm ids'));
    expect(message, contains('Confirm is disabled'));
    expect(_confirmEnabled(tester), isFalse);
    expect(find.byKey(const ValueKey('local-only-notice')), findsOneWidget);

    // A disabled button must be a no-op even when tapped.
    await tester.tap(find.byKey(const ValueKey('confirm-review')));
    await tester.pump();
    expect(confirmed, isNull);
  });

  testWidgets('over-capacity proposal is refused explicitly', (tester) async {
    await _mount(
      tester,
      baseline: const [],
      proposal: [for (var i = 0; i < 33; i++) _alarm(id: 'alarm-$i')],
    );

    final message = _statusMessage(tester);
    expect(message, contains('proposal refused'));
    expect(message, contains('exceeds the 32-alarm device bound'));
    expect(_confirmEnabled(tester), isFalse);
  });

  testWidgets('status is announced as a live-region semantic label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _mount(tester, baseline: _baseline, proposal: _proposal);

    expect(
      find.bySemanticsLabel(
        'Review status: 1 added, 1 removed, 1 changed, 0 unchanged '
        '(expected revision 3).',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('confirm action meets the 48 logical pixel minimum', (
    tester,
  ) async {
    await _mount(tester, baseline: _baseline, proposal: _proposal);

    final size = tester.getSize(find.byKey(const ValueKey('confirm-review')));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('confirm emits exactly the locally computed diff', (
    tester,
  ) async {
    ScheduleDiff? confirmed;
    await _mount(
      tester,
      baseline: _baseline,
      proposal: _proposal,
      expectedRevision: 7,
      onConfirm: (d) => confirmed = d,
    );

    await tester.tap(find.byKey(const ValueKey('confirm-review')));
    await tester.pump();

    expect(confirmed, isNotNull);
    expect(confirmed!.expectedRevision, 7);
    expect(confirmed!.added.map((a) => a.id), ['weekend-hike']);
    expect(confirmed!.removed.map((a) => a.id), ['saturday-chore']);
    expect(confirmed!.changed.single.id, 'weekday-rise');
  });

  testWidgets('320-wide 200 percent text renders without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _mount(tester, baseline: _baseline, proposal: _proposal);
    expect(tester.takeException(), isNull);

    await _mount(tester, baseline: _baseline, proposal: _baseline);
    expect(tester.takeException(), isNull);
    expect(_statusMessage(tester), startsWith('Review status: no changes'));
  });
}
