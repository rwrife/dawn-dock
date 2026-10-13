import 'package:dawn_dock_companion/main.dart';
import 'package:dawn_dock_companion/ui/pairing_demo_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('navigation opens the simulated-only pairing demo', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    expect(find.byKey(const ValueKey('pairing-demo')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('pairing-demo')));
    await tester.tap(find.byKey(const ValueKey('pairing-demo')));
    await tester.pumpAndSettle();

    expect(find.text('Pairing demo • Simulated only'), findsOneWidget);
    expect(find.text('Pairing demo • Simulated ceremony'), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-demo-notice')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-demo-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-demo-start')), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('pairing-demo-reset')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('starts closed by default; start button opens fresh ceremony', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PairingDemoPage()));

    // Closed by default: panel inputs are not mounted.
    expect(find.byKey(const ValueKey('pairing-demo-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-code')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('pairing-demo-start')));
    await tester.pump();

    // Ceremony opened: screen card and panel are mounted.
    expect(find.byKey(const ValueKey('pairing-demo-idle')), findsNothing);
    expect(find.byKey(const ValueKey('pairing-demo-screen')), findsOneWidget);
    expect(find.textContaining(kDemoPairingShortCode), findsOneWidget);
    expect(find.textContaining(kDemoPairingFingerprint), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-fingerprint')), findsOneWidget);
    expect(find.textContaining('5 attempts remaining'), findsOneWidget);
  });

  testWidgets(
    'wrong code decrements attempts; correct inputs confirm locally',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PairingDemoPage()));
      await tester.tap(find.byKey(const ValueKey('pairing-demo-start')));
      await tester.pump();

      // Wrong code attempt.
      await tester.enterText(
        find.byKey(const ValueKey('pairing-code')),
        'wrong!',
      );
      await tester.enterText(
        find.byKey(const ValueKey('pairing-fingerprint')),
        kDemoPairingFingerprint,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('pairing-confirm')));
      await tester.tap(find.byKey(const ValueKey('pairing-confirm')));
      await tester.pump();

      expect(find.textContaining('4 attempts remaining'), findsOneWidget);
      expect(
        find.textContaining('Code or fingerprint mismatch'),
        findsOneWidget,
      );

      // Correct input.
      await tester.enterText(
        find.byKey(const ValueKey('pairing-code')),
        kDemoPairingShortCode,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('pairing-confirm')));
      await tester.tap(find.byKey(const ValueKey('pairing-confirm')));

      await tester.pump();

      expect(find.textContaining('Local comparison accepted'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('pairing-confirm')),
            )
            .onPressed,
        isNull,
      );
      // The ceremony object still exists (closed), so starting another
      // requires discarding it first — no silent per-attempt restart.
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('pairing-demo-start')),
            )
            .onPressed,
        isNull,
      );
      // Discarding returns to the closed-by-default state.
      await tester.ensureVisible(
        find.byKey(const ValueKey('pairing-demo-reset')),
      );
      await tester.tap(find.byKey(const ValueKey('pairing-demo-reset')));
      await tester.pump();
      expect(find.byKey(const ValueKey('pairing-demo-idle')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('pairing-demo-start')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('advance clock elapses the window and disables confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PairingDemoPage()));
    await tester.tap(find.byKey(const ValueKey('pairing-demo-start')));
    await tester.pump();

    await tester.ensureVisible(
      find.byKey(const ValueKey('pairing-demo-advance')),
    );
    await tester.tap(find.byKey(const ValueKey('pairing-demo-advance')));
    await tester.pump();

    expect(
      find.textContaining('Pairing window elapsed. Ceremony closed.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('pairing-confirm')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('discard reset clears the ceremony back to closed-by-default', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PairingDemoPage()));
    await tester.tap(find.byKey(const ValueKey('pairing-demo-start')));
    await tester.pump();

    expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pairing-demo-reset')));
    await tester.pump();

    expect(find.byKey(const ValueKey('pairing-demo-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-code')), findsNothing);
  });

  testWidgets('remounting the page discards in-memory ceremony state', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PairingDemoPage()));
    await tester.tap(find.byKey(const ValueKey('pairing-demo-start')));
    await tester.pump();
    expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);

    // Unmount and remount.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(home: PairingDemoPage()));

    // Starts from closed by default again.
    expect(find.byKey(const ValueKey('pairing-demo-idle')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing-code')), findsNothing);
  });

  testWidgets('adapts to 320px width and 2.0 text scaling without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320 * 2.0, 640 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: PairingDemoPage(),
        ),
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('pairing-demo-start')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pairing-demo-start')));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);
    final startSize = tester.getSize(
      find.byKey(const ValueKey('pairing-demo-start')),
    );
    expect(startSize.width, greaterThanOrEqualTo(48));
    expect(startSize.height, greaterThanOrEqualTo(48));
  });
}
