import 'dart:math' as math;

import 'package:dawn_dock_companion/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

double _relativeLuminance(Color color) {
  double channel(double value) => value <= 0.04045
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  final red = channel(color.r);
  final green = channel(color.g);
  final blue = channel(color.b);
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

double _contrastRatio(Color first, Color second) {
  final a = _relativeLuminance(first);
  final b = _relativeLuminance(second);
  final lighter = a > b ? a : b;
  final darker = a > b ? b : a;
  return (lighter + 0.05) / (darker + 0.05);
}

void _expectMinimumTouchTarget(WidgetTester tester, Finder finder) {
  final size = tester.getSize(finder);
  expect(size.width, greaterThanOrEqualTo(48));
  expect(size.height, greaterThanOrEqualTo(48));
}

void main() {
  testWidgets('startup identifies the bounded offline demo', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Dawn Dock companion'), findsOneWidget);
    expect(find.text('Offline demo • Fake device'), findsOneWidget);
    expect(find.text('No real clock is connected.'), findsOneWidget);
    expect(
      find.text('Illustrative sample — not the current time'),
      findsOneWidget,
    );
    expect(find.text('No alarms are executed by this demo.'), findsOneWidget);
  });

  testWidgets('review shows a diff without mutating fake state', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    await tester.tap(find.text('Review sample change'));
    await tester.pump();

    expect(find.text('Review illustrative change'), findsOneWidget);
    expect(find.text('Current: Weekdays at 7:00 AM'), findsOneWidget);
    expect(find.text('Proposed: Weekdays at 7:30 AM'), findsOneWidget);
    expect(find.text('Schedule revision: 1'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Apply to fake device'), findsOneWidget);
  });

  testWidgets('cancel closes review and preserves fake schedule', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.tap(find.text('Review sample change'));
    await tester.pump();

    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(find.text('Review illustrative change'), findsNothing);
    expect(find.text('Weekdays at 7:00 AM'), findsOneWidget);
    expect(find.text('Schedule revision: 1'), findsOneWidget);
    expect(find.text('Review sample change'), findsOneWidget);
  });

  testWidgets('explicit confirmation applies once and shows demo receipt', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.tap(find.text('Review sample change'));
    await tester.pump();

    await tester.ensureVisible(find.text('Apply to fake device'));
    await tester.tap(find.text('Apply to fake device'));
    await tester.pump();

    expect(find.text('Weekdays at 7:30 AM'), findsOneWidget);
    expect(find.text('Schedule revision: 2'), findsOneWidget);
    expect(find.text('Demo-only revision receipt'), findsOneWidget);
    expect(find.text('Applied fake revision 2'), findsOneWidget);
    expect(find.text('Apply to fake device'), findsNothing);
    expect(find.text('Nothing was sent to real hardware.'), findsOneWidget);
  });

  testWidgets('reset and widget reconstruction restore the in-memory demo', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.tap(find.text('Review sample change'));
    await tester.pump();
    await tester.ensureVisible(find.text('Apply to fake device'));
    await tester.tap(find.text('Apply to fake device'));
    await tester.pump();

    await tester.ensureVisible(find.text('Reset demo'));
    await tester.tap(find.text('Reset demo'));
    await tester.pump();
    expect(find.text('Weekdays at 7:00 AM'), findsOneWidget);
    expect(find.text('Schedule revision: 1'), findsOneWidget);
    expect(find.text('Demo-only revision receipt'), findsNothing);

    await tester.tap(find.text('Review sample change'));
    await tester.pump();
    await tester.ensureVisible(find.text('Apply to fake device'));
    await tester.tap(find.text('Apply to fake device'));
    await tester.pump();
    expect(find.text('Schedule revision: 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MyApp());
    expect(find.text('Weekdays at 7:00 AM'), findsOneWidget);
    expect(find.text('Schedule revision: 1'), findsOneWidget);
  });

  testWidgets(
    'status and actions meet semantic touch and contrast guidelines',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(const MyApp());

      expect(
        find.bySemanticsLabel('Fake device status: simulated offline'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Next alarm sample: weekdays at 7:00 AM, illustrative only',
        ),
        findsOneWidget,
      );

      final reviewButton = find.widgetWithText(
        FilledButton,
        'Review sample change',
      );
      _expectMinimumTouchTarget(tester, reviewButton);

      final context = tester.element(find.byType(Scaffold));
      final colors = Theme.of(context).colorScheme;
      expect(
        _contrastRatio(colors.onSurface, colors.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrastRatio(colors.onPrimary, colors.primary),
        greaterThanOrEqualTo(4.5),
      );

      await tester.tap(reviewButton);
      await tester.pumpAndSettle();
      final cancelButton = find.widgetWithText(OutlinedButton, 'Cancel');
      final applyButton = find.widgetWithText(
        FilledButton,
        'Apply to fake device',
      );
      _expectMinimumTouchTarget(tester, cancelButton);
      _expectMinimumTouchTarget(tester, applyButton);

      await tester.ensureVisible(applyButton);
      await tester.tap(applyButton);
      await tester.pumpAndSettle();
      _expectMinimumTouchTarget(
        tester,
        find.widgetWithText(OutlinedButton, 'Reset demo'),
      );
      semantics.dispose();
    },
  );

  testWidgets('320-wide 200 percent text honors reduced motion', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(const MyApp());
    expect(tester.takeException(), isNull);
    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(switcher.duration, Duration.zero);

    await tester.ensureVisible(find.text('Review sample change'));
    await tester.tap(find.text('Review sample change'));
    await tester.pump();
    expect(find.text('Review illustrative change'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard tab and enter operate the logical action order', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    expect(find.byKey(const ValueKey('demo-actions')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final reviewButton = find.widgetWithText(
      FilledButton,
      'Review sample change',
    );
    expect(Focus.of(tester.element(reviewButton)).hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Review illustrative change'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final cancelButton = find.widgetWithText(OutlinedButton, 'Cancel');
    expect(Focus.of(tester.element(cancelButton)).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Review illustrative change'), findsNothing);
  });
}
