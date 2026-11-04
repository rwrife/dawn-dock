import 'package:dawn_dock_companion/main.dart';
import 'package:dawn_dock_companion/ui/calendar_import_demo_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const calendar = '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:example-1
SUMMARY:Private meeting
DESCRIPTION:Secret notes
DTSTART:20261019T073000
RRULE:FREQ=WEEKLY;BYDAY=MO,WE
END:VEVENT
BEGIN:VEVENT
UID:example-2
SUMMARY:Discarded event
DTSTART:20261019T083000
RRULE:FREQ=MONTHLY
END:VEVENT
END:VCALENDAR''';

Future<void> _pumpTallPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(const MaterialApp(home: CalendarImportDemoPage()));
}

void main() {
  testWidgets('review requires confirmation; cancel never saves', (
    tester,
  ) async {
    await _pumpTallPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      calendar,
    );
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    // Import results retain summary, not DESCRIPTION. Raw input still displays
    // in its editable field until the user clears it.
    expect(find.text('Private meeting'), findsOneWidget);
    expect(find.text('Secret notes'), findsNothing);
    expect(find.textContaining('Nothing saved yet'), findsOneWidget);
    expect(find.textContaining('Event 2:'), findsNWidgets(2));
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('cancel-import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-import')), findsNothing);
    expect(find.textContaining('saved in memory'), findsNothing);
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('acknowledge-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-import')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 suggestion saved in memory'), findsOneWidget);
    // Confirming discards the raw pasted calendar text.
    expect(find.text(calendar), findsNothing);
    expect(
      find.textContaining('No alarm was scheduled or sent to a device'),
      findsOneWidget,
    );
  });

  testWidgets('embedded alarm blocks review and confirmation', (tester) async {
    await _pumpTallPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:reminder
SUMMARY:Do not ring
DTSTART:20260901T070000
BEGIN:VALARM
TRIGGER:-PT15M
ACTION:DISPLAY
END:VALARM
END:VEVENT
END:VCALENDAR''',
    );
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 suggestions for review'), findsOneWidget);
    expect(
      find.textContaining('embedded calendar alarm; event dropped'),
      findsOneWidget,
    );
    expect(find.text('Do not ring'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('canceled event blocks suggestion and confirmation', (
    tester,
  ) async {
    await _pumpTallPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:canceled-1
SUMMARY:Canceled standup
STATUS:CANCELLED
DTSTART:20260901T070000
RRULE:FREQ=DAILY
END:VEVENT
END:VCALENDAR''',
    );
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 suggestions for review'), findsOneWidget);
    expect(
      find.textContaining('Canceled calendar event; event group dropped'),
      findsOneWidget,
    );
    expect(find.text('Canceled standup'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'recurrence addition shows a plain-language notice, not an alarm',
    (tester) async {
      await _pumpTallPage(tester);
      await tester.enterText(
        find.byKey(const ValueKey('calendar-input')),
        '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:blocked
SUMMARY:Should not ring
DTSTART:20260901T070000
RRULE:FREQ=DAILY
RDATE:20260907T070000
END:VEVENT
END:VCALENDAR''',
      );
      await tester.tap(find.text('Review calendar suggestions'));
      await tester.pumpAndSettle();
      expect(find.textContaining('0 suggestions for review'), findsOneWidget);
      expect(
        find.textContaining('Unsupported recurrence additions or exclusions'),
        findsOneWidget,
      );
      expect(find.text('Should not ring'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('detached override blocks master review and confirmation', (
    tester,
  ) async {
    await _pumpTallPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:shared
SUMMARY:Master must not ring
DTSTART:20260901T070000
RRULE:FREQ=DAILY
END:VEVENT
BEGIN:VEVENT
UID:shared
SUMMARY:Override must not ring
RECURRENCE-ID:20260902T070000
DTSTART:20260902T080000
END:VEVENT
END:VCALENDAR''',
    );
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 suggestions for review'), findsOneWidget);
    expect(
      find.textContaining('Recurrence override or canceled occurrence'),
      findsNWidgets(2),
    );
    expect(find.text('Master must not ring'), findsNothing);
    expect(find.text('Override must not ring'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('duplicate UIDs cannot be confirmed as two alarms', (
    tester,
  ) async {
    await _pumpTallPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:same
SUMMARY:First must not ring
DTSTART:20260901T070000
END:VEVENT
BEGIN:VEVENT
UID:same
SUMMARY:Second must not ring
DTSTART:20260902T080000
END:VEVENT
END:VCALENDAR''',
    );
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 suggestions for review'), findsOneWidget);
    expect(
      find.textContaining('Duplicate event ID; event group dropped.'),
      findsNWidgets(2),
    );
    expect(find.text('First must not ring'), findsNothing);
    expect(find.text('Second must not ring'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('bounded recurrence cannot be confirmed as endless alarm', (
    tester,
  ) async {
    await _pumpTallPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:bounded
SUMMARY:Temporary event
DTSTART:20260901T070000
RRULE:FREQ=DAILY;COUNT=2
END:VEVENT
END:VCALENDAR''',
    );
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 suggestions for review'), findsOneWidget);
    expect(find.textContaining('Calendar recurrence ends'), findsOneWidget);
    expect(find.text('Temporary event'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('excluded event shows a plain-language notice, not an alarm', (
    tester,
  ) async {
    await _pumpTallPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      '''BEGIN:VCALENDAR
BEGIN:VEVENT
UID:blocked
SUMMARY:Should not ring
DTSTART:20260901T070000
RRULE:FREQ=DAILY
EXDATE:20260907T070000
END:VEVENT
END:VCALENDAR''',
    );
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 suggestions for review'), findsOneWidget);
    expect(find.textContaining('Event has excluded dates'), findsOneWidget);
    expect(find.text('Should not ring'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('invalid input cannot confirm; edits invalidate review', (
    tester,
  ) async {
    await _pumpTallPage(tester);
    await tester.enterText(find.byKey(const ValueKey('calendar-input')), 'bad');
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('missing BEGIN:VCALENDAR'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-import')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      calendar,
    );
    await tester.tap(find.text('Review calendar suggestions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('acknowledge-import')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('confirm-import')))
          .onPressed,
      isNotNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('calendar-input')),
      'changed',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-import')), findsNothing);
    expect(find.byKey(const ValueKey('acknowledge-import')), findsNothing);
  });

  testWidgets('home navigation mounts the local-only calendar demo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(const MyApp());
    await tester.tap(find.byKey(const ValueKey('calendar-import-demo')));
    await tester.pumpAndSettle();
    expect(find.text('Calendar import demo'), findsOneWidget);
    expect(
      find.textContaining('No file picker or calendar permission'),
      findsOneWidget,
    );
    expect(find.textContaining('No alarm was scheduled'), findsOneWidget);
  });

  testWidgets('large text renders input label without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(const MaterialApp(home: CalendarImportDemoPage()));
    expect(find.text('Calendar text for local review'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
