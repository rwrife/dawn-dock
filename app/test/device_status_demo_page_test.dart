import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dawn_dock_companion/main.dart';

void main() {
  testWidgets('home opens local demo and switches all evidence fixtures', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    final entry = find.byKey(const ValueKey('status-demo'));
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('No real clock is connected. Fixed fixture anchor'),
      findsOneWidget,
    );
    expect(find.textContaining('Local projection only'), findsOneWidget);

    for (final (key, expected, hasNext) in [
      ('matchingReceipt', 'matches a stored receipt', true),
      ('mismatchedReceipt', 'Warning: stored receipt disagrees', true),
      ('unresolved', 'Next alarm withheld', false),
      ('empty', 'No enabled alarms', false),
    ]) {
      final control = find.byKey(ValueKey('case-$key'));
      await tester.ensureVisible(control);
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(find.textContaining(expected), findsOneWidget);
      expect(
        find.byKey(const ValueKey('projected-next')),
        hasNext ? findsOneWidget : findsNothing,
      );
    }
  });

  testWidgets(
    '320 width, 200 percent text remains scrollable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.platformDispatcher.clearTextScaleFactorTestValue();
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Ready'))),
        ),
      );
      await tester.pumpWidget(const MyApp());
      final entry = find.byKey(const ValueKey('status-demo'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final control = find.byKey(const ValueKey('case-unresolved'));
      await tester.ensureVisible(control);
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(find.textContaining('Next alarm withheld'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
