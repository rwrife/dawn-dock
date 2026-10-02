import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/main.dart';

Finder _textFinder(String key) => find.byKey(ValueKey(key));

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_textFinder(key)).data ?? '';

Future<void> _openDemo(WidgetTester tester) async {
  await tester.pumpWidget(const MyApp());
  await tester.pumpAndSettle();
  final entry = find.byKey(const ValueKey('schedule-review-demo'));
  await tester.ensureVisible(entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('home navigation exposes the schedule review demo entry', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('schedule-review-demo')), findsOneWidget);
    expect(find.text('Open schedule review demo'), findsOneWidget);
  });

  testWidgets('demo opens seeded with one changed, added, and removed alarm', (
    tester,
  ) async {
    await _openDemo(tester);

    expect(
      _text(tester, 'schedule-review-status'),
      'Review status: 1 added, 1 removed, 1 changed, 0 unchanged '
      '(expected revision 3).',
    );
    expect(find.text('~ weekday-rise: local-time'), findsOneWidget);
    expect(find.text('+ weekend-hike: Hike 08:00'), findsOneWidget);
    expect(find.text('- saturday-chore: Chores 09:00'), findsOneWidget);
    expect(_text(tester, 'proposal-count'), 'Demo proposal alarms: 2.');
    expect(_text(tester, 'no-hardware-notice'), contains('in-memory'));
    expect(_text(tester, 'revision-notice'), contains('revision: 3'));
  });

  testWidgets('toggling the proposal recomputes the review', (tester) async {
    await _openDemo(tester);

    await tester.tap(find.byKey(const ValueKey('toggle-extra')));
    await tester.pumpAndSettle();

    expect(_text(tester, 'proposal-count'), 'Demo proposal alarms: 1.');
    expect(
      _text(tester, 'schedule-review-status'),
      'Review status: 0 added, 1 removed, 1 changed, 0 unchanged '
      '(expected revision 3).',
    );
    expect(find.text('+ weekend-hike: Hike 08:00'), findsNothing);
    expect(find.text('- weekend-hike: Hike 08:00'), findsNothing);
    expect(find.text('- saturday-chore: Chores 09:00'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('toggle-extra')));
    await tester.pumpAndSettle();
    expect(_text(tester, 'schedule-review-status'), contains('1 added'));
  });

  testWidgets('confirm records the locally computed review only', (
    tester,
  ) async {
    await _openDemo(tester);

    expect(_textFinder('confirmed-notice'), findsNothing);
    final confirm = find.byKey(const ValueKey('confirm-review'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    final notice = _text(tester, 'confirmed-notice');
    expect(notice, contains('Confirmed locally: 1 added, 1 removed, 1'));
    expect(notice, contains('Not sent to any device'));
    expect(notice, contains('unchanged at revision 3'));
    // The baseline mirror never advanced.
    expect(find.text('~ weekday-rise: local-time'), findsOneWidget);
  });

  testWidgets('demo survives a widget reconstruction with fresh state', (
    tester,
  ) async {
    await _openDemo(tester);
    final confirm = find.byKey(const ValueKey('confirm-review'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(_textFinder('confirmed-notice'), findsOneWidget);

    // Same-process widget reconstruction, NOT an app process restart:
    // rebuilding the page resets the demo to its seeded state. The
    // intermediate pump tears down the pushed route, as the backup demo
    // remount test does.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    final reentry = find.byKey(const ValueKey('schedule-review-demo'));
    await tester.ensureVisible(reentry);
    await tester.tap(reentry);
    await tester.pumpAndSettle();
    expect(_textFinder('confirmed-notice'), findsNothing);
    expect(_text(tester, 'schedule-review-status'), contains('1 added'));
  });

  testWidgets('demo renders at 320 logical pixels with 200 percent text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _openDemo(tester);
    expect(tester.takeException(), isNull);

    final confirm = find.byKey(const ValueKey('confirm-review'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_text(tester, 'confirmed-notice'), contains('Confirmed locally'));
  });
}
