import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/main.dart';

Finder _key(String key) => find.byKey(ValueKey(key));
String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data ?? '';

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(const MyApp());
  await tester.pumpAndSettle();
  await tester.ensureVisible(_key('schedule-flow-demo'));
  await tester.tap(_key('schedule-flow-demo'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('home mounts local-only flow with no token or receipt', (
    tester,
  ) async {
    await _open(tester);
    expect(_text(tester, 'flow-demo-notice'), contains('No real clock'));
    expect(_text(tester, 'flow-demo-revision'), contains('revision: 3'));
    expect(_text(tester, 'exchange-status'), contains('No proposal reviewed'));
    expect(
      tester.widget<OutlinedButton>(_key('exchange-apply')).onPressed,
      isNull,
    );
    expect(_key('flow-demo-frame'), findsNothing);
  });

  testWidgets(
    'review recomputes proposal, preview is framed but not delivered',
    (tester) async {
      await _open(tester);
      await _tap(tester, 'exchange-review');
      expect(find.textContaining('Schedule review: 1 added'), findsOneWidget);
      await _tap(tester, 'exchange-cancel');
      await _tap(tester, 'flow-demo-toggle');
      await _tap(tester, 'exchange-review');
      expect(_text(tester, 'exchange-status'), contains('Review ready'));
      expect(find.textContaining('Schedule review: 0 added'), findsOneWidget);
      await _tap(tester, 'exchange-preview');
      expect(
        _text(tester, 'exchange-status'),
        contains('Awaiting caller-supplied token'),
      );
      expect(
        _text(tester, 'flow-demo-frame'),
        contains('schedule.preview at revision 3, message ID demo-preview-1'),
      );
      expect(_text(tester, 'flow-demo-frame'), contains('Not delivered'));
      expect(_text(tester, 'flow-demo-revision'), contains('revision: 3'));
      expect(
        tester.widget<OutlinedButton>(_key('exchange-apply')).onPressed,
        isNull,
      );
      expect(
        tester.widget<OutlinedButton>(_key('flow-demo-toggle')).onPressed,
        isNull,
      );
      await _tap(tester, 'exchange-cancel');
      expect(_key('flow-demo-frame'), findsNothing);
      expect(
        _text(tester, 'exchange-status'),
        contains('No proposal reviewed'),
      );
      expect(_text(tester, 'flow-demo-revision'), contains('revision: 3'));
    },
  );

  testWidgets('rebuilding demo route resets only local state', (tester) async {
    await _open(tester);
    await _tap(tester, 'exchange-review');
    await _tap(tester, 'exchange-preview');
    expect(_key('flow-demo-frame'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _open(tester);
    expect(_key('flow-demo-frame'), findsNothing);
    expect(_text(tester, 'exchange-status'), contains('No proposal reviewed'));
    expect(_text(tester, 'flow-demo-revision'), contains('revision: 3'));
  });

  testWidgets('popping and reopening the route resets demo state', (
    tester,
  ) async {
    await _open(tester);
    await _tap(tester, 'exchange-review');
    await _tap(tester, 'exchange-preview');
    expect(_key('flow-demo-frame'), findsOneWidget);
    // Pop back to home within the SAME app instance, then reopen.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_key('exchange-status'), findsNothing);
    await tester.ensureVisible(_key('schedule-flow-demo'));
    await tester.tap(_key('schedule-flow-demo'));
    await tester.pumpAndSettle();
    expect(_key('flow-demo-frame'), findsNothing);
    expect(_text(tester, 'exchange-status'), contains('No proposal reviewed'));
    expect(_text(tester, 'flow-demo-revision'), contains('revision: 3'));
  });

  testWidgets('narrow large-text layout stays scrollable', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _open(tester);
    await _tap(tester, 'exchange-review');
    await _tap(tester, 'exchange-preview');
    await tester.ensureVisible(_key('exchange-cancel'));
    expect(tester.takeException(), isNull);
  });
}
