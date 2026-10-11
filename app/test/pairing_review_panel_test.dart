import 'package:dawn_dock_companion/domain/pairing.dart';
import 'package:dawn_dock_companion/ui/pairing_review_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('exact inputs confirm only the supplied local ceremony', (
    tester,
  ) async {
    final now = DateTime.utc(2026);
    final ceremony = PairingCeremony(
      candidate: PairingCandidate(
        identity: 'demo',
        displayName: 'Sample clock',
        source: CandidateSource.manual,
      ),
      expectedShortCode: '123456',
      expectedFingerprint: 'sample-fingerprint',
      windowStart: now,
      clock: () => now,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingReviewPanel(ceremony: ceremony, clock: () => now),
        ),
      ),
    );
    expect(ceremony.attemptCount, 0);
    await tester.enterText(
      find.byKey(const ValueKey('pairing-code')),
      '123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey('pairing-fingerprint')),
      'sample-fingerprint',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('pairing-confirm')));
    await tester.tap(find.byKey(const ValueKey('pairing-confirm')));
    await tester.pump();
    expect(ceremony.closureReason, PairingClosureReason.confirmed);
    expect(find.textContaining('Local comparison accepted'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('pairing-confirm')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('confirmation stays disabled before reported window start', (
    tester,
  ) async {
    final start = DateTime.utc(2026);
    var now = start.subtract(const Duration(seconds: 1));
    final ceremony = PairingCeremony(
      candidate: PairingCandidate(
        identity: 'demo',
        displayName: 'Sample clock',
        source: CandidateSource.manual,
      ),
      expectedShortCode: '123456',
      expectedFingerprint: 'sample-fingerprint',
      windowStart: start,
      clock: () => now,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingReviewPanel(ceremony: ceremony, clock: () => now),
        ),
      ),
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('pairing-confirm')))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('has not opened'), findsOneWidget);
    now = start;
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('pairing-confirm')))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('each mismatch consumes one attempt then closes at five', (
    tester,
  ) async {
    final now = DateTime.utc(2026);
    final ceremony = makeCeremony(now, () => now);
    await mount(tester, ceremony, () => now);
    await tester.enterText(
      find.byKey(const ValueKey('pairing-code')),
      '123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey('pairing-fingerprint')),
      'wrong',
    );
    for (var attempt = 1; attempt <= 5; attempt++) {
      await tap(tester, 'pairing-confirm');
      expect(ceremony.attemptCount, attempt);
      if (attempt < 5) {
        expect(ceremony.isClosed, isFalse);
        expect(find.textContaining('mismatch'), findsOneWidget);
      }
    }
    expect(ceremony.closureReason, PairingClosureReason.attemptsExhausted);
    expect(find.textContaining('Five failed'), findsOneWidget);
    expect(button(tester, 'pairing-confirm').onPressed, isNull);
    expect(button(tester, 'pairing-cancel').onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('deadline closes without a tap and late tap cannot confirm', (
    tester,
  ) async {
    final start = DateTime.utc(2026);
    var now = start;
    final ceremony = makeCeremony(start, () => now);
    await mount(tester, ceremony, () => now);
    await tester.enterText(
      find.byKey(const ValueKey('pairing-code')),
      '123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey('pairing-fingerprint')),
      'sample-fingerprint',
    );
    now = start.add(const Duration(seconds: 120));
    await tester.pump(const Duration(seconds: 1));
    expect(ceremony.closureReason, PairingClosureReason.timedOut);
    expect(ceremony.attemptCount, 0);
    expect(find.textContaining('window elapsed'), findsOneWidget);
    expect(button(tester, 'pairing-confirm').onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());

    now = start;
    final late = makeCeremony(start, () => now);
    await mount(tester, late, () => now);
    now = start.add(const Duration(seconds: 120));
    // No polling tick before this tap: the action must recheck expiry itself.
    await tap(tester, 'pairing-confirm');
    expect(late.closureReason, PairingClosureReason.timedOut);
    expect(late.attemptCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'clock crossing deadline during confirmation closes without a widget error',
    (tester) async {
      final start = DateTime.utc(2026);
      var calls = 0;
      DateTime clock() =>
          ++calls >= 3 ? start.add(const Duration(seconds: 120)) : start;
      final ceremony = makeCeremony(start, clock);
      await mount(tester, ceremony, clock);
      // The clock can advance between the button gate and the domain attempt.
      final action = button(tester, 'pairing-confirm').onPressed!;
      calls = 0;
      action();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(ceremony.attemptCount, 0);
      expect(ceremony.closureReason, PairingClosureReason.timedOut);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('cancel closes locally and replacement clears sensitive inputs', (
    tester,
  ) async {
    final now = DateTime.utc(2026);
    final old = makeCeremony(now, () => now);
    await mount(tester, old, () => now);
    await tester.enterText(find.byKey(const ValueKey('pairing-code')), 'wrong');
    await tester.enterText(
      find.byKey(const ValueKey('pairing-fingerprint')),
      'wrong',
    );
    await tap(tester, 'pairing-confirm');
    await tap(tester, 'pairing-cancel');
    expect(old.closureReason, PairingClosureReason.cancelled);
    expect(button(tester, 'pairing-confirm').onPressed, isNull);
    final fresh = makeCeremony(now, () => now);
    await mount(tester, fresh, () => now);
    for (final key in ['pairing-code', 'pairing-fingerprint']) {
      expect(
        tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text,
        isEmpty,
      );
    }
    expect(find.textContaining('mismatch'), findsNothing);
    expect(fresh.attemptCount, 0);
    expect(button(tester, 'pairing-confirm').onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow large text keeps labeled inputs live status and 48px controls',
    (tester) async {
      final semantics = tester.ensureSemantics();
      // Dispose before the widget-test end-of-test semantics verification.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.utc(2026);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: PairingReviewPanel(
                ceremony: makeCeremony(now, () => now),
                clock: () => now,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('pairing-status'))),
        matchesSemantics(
          label: 'Reported pairing window open. 5 attempts remaining.',
          isLiveRegion: true,
        ),
      );
      for (final entry in {
        'pairing-code': 'Short code displayed on clock',
        'pairing-fingerprint': 'Fingerprint displayed on clock',
      }.entries) {
        final field = find.byKey(ValueKey(entry.key));
        await tester.ensureVisible(field);
        expect(
          tester.widget<TextField>(field).decoration!.labelText,
          entry.value,
        );
      }
      for (final key in ['pairing-confirm', 'pairing-cancel']) {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(finder).width, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

PairingCeremony makeCeremony(DateTime start, DateTime Function() clock) =>
    PairingCeremony(
      candidate: PairingCandidate(
        identity: 'demo',
        displayName: 'Sample clock',
        source: CandidateSource.manual,
      ),
      expectedShortCode: '123456',
      expectedFingerprint: 'sample-fingerprint',
      windowStart: start,
      clock: clock,
    );

Future<void> mount(
  WidgetTester tester,
  PairingCeremony ceremony,
  DateTime Function() clock,
) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: PairingReviewPanel(ceremony: ceremony, clock: clock),
    ),
  ),
);

OutlinedButton button(WidgetTester tester, String key) =>
    tester.widget<OutlinedButton>(find.byKey(ValueKey(key)));

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
}
