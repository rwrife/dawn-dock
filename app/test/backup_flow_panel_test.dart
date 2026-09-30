import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/backup_coordinator.dart';
import 'package:dawn_dock_companion/domain/backup_flow_controller.dart';
import 'package:dawn_dock_companion/domain/device_profile.dart';
import 'package:dawn_dock_companion/domain/local_backup_store.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';
import 'package:dawn_dock_companion/ui/backup_flow_panel.dart';

/// Filesystem-free [LocalBackupStore] double: holds backup text in memory and
/// optionally gates writes so tests can pin the busy window precisely.
class InMemoryBackupStore extends LocalBackupStore {
  InMemoryBackupStore() : super(directory: Directory.systemTemp);

  String? text;
  Completer<void>? saveGate;

  @override
  Future<void> saveText(String backupText) async {
    final gate = saveGate;
    if (gate != null) {
      await gate.future;
    }
    text = backupText;
  }

  @override
  Future<String?> loadText() async => text;

  @override
  Future<void> erase() async {
    text = null;
  }
}

AlarmDraft _draft(String id) => AlarmDraft(
  id: id,
  label: 'Workday',
  enabled: true,
  localHour: 7,
  localMinute: 0,
  days: const {1, 2, 3, 4, 5},
  timezone: 'America/New_York',
  snoozeMinutes: 9,
  volume: 45,
  sound: 'gentle-1',
  source: DraftSource.manual,
);

final _now = DateTime.utc(2026, 9, 30, 9, 0);

class _Fixture {
  _Fixture() {
    store = InMemoryBackupStore();
    profiles = DeviceProfileStore();
    drafts = DraftSet();
    schedule = DeviceScheduleStore(clock: () => _now);
    coordinator = BackupCoordinator(
      backupStore: store,
      profileStore: profiles,
      draftSet: drafts,
      scheduleStore: schedule,
      clock: () => _now,
    );
    controller = BackupFlowController(
      coordinator: coordinator,
      clock: () => _now,
    );
  }

  late final InMemoryBackupStore store;
  late final DeviceProfileStore profiles;
  late final DraftSet drafts;
  late final DeviceScheduleStore schedule;
  late final BackupCoordinator coordinator;
  late final BackupFlowController controller;

  /// Seed a saved backup captured at revision 3 with `saved-*` state.
  Future<void> seedBackupRevision3() async {
    profiles.upsert(
      DeviceProfile(identity: 'saved', displayName: 'Saved Dock'),
    );
    drafts.put(_draft('saved-draft'));
    schedule.replaceAll(revision: 3, alarms: [_draft('saved-committed')]);
    await coordinator.export();
    profiles.replaceAll(const []);
    drafts.clear();
    schedule.replaceAll(revision: 5, alarms: [_draft('live-committed')]);
  }
}

Finder _statusText() => find.byKey(const ValueKey('backup-status'));

String _statusMessage(WidgetTester tester) =>
    tester.widget<Text>(_statusText()).data ?? '';

Future<void> _mount(
  WidgetTester tester,
  BackupFlowController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: BackupFlowPanel(controller: controller)),
    ),
  );
}

bool _buttonEnabled(Finder finder) {
  final widget = finder.evaluate().single.widget;
  return switch (widget) {
    FilledButton(:final onPressed) => onPressed != null,
    OutlinedButton(:final onPressed) => onPressed != null,
    _ => throw StateError('not a button: $widget'),
  };
}

void main() {
  late _Fixture fx;

  setUp(() {
    fx = _Fixture();
  });

  testWidgets('initial state labels the panel and enables actions', (
    tester,
  ) async {
    await _mount(tester, fx.controller);

    expect(find.text('Backup and restore'), findsOneWidget);
    expect(_statusMessage(tester), 'Backup status: no action has run yet.');
    for (final key in ['export', 'check', 'restore', 'erase']) {
      expect(
        _buttonEnabled(find.byKey(ValueKey(key))),
        isTrue,
        reason: 'action $key should start enabled',
      );
    }
    expect(find.byKey(const ValueKey('confirm-stale')), findsNothing);
    expect(find.byKey(const ValueKey('cancel-stale')), findsNothing);
  });

  testWidgets('export success renders summary text', (tester) async {
    fx.profiles.upsert(
      DeviceProfile(identity: 'bedside', displayName: 'Bedside Dock'),
    );
    fx.drafts.put(_draft('draft-one'));
    fx.schedule.replaceAll(revision: 4, alarms: [_draft('committed-one')]);

    await _mount(tester, fx.controller);
    await tester.tap(find.byKey(const ValueKey('export')));
    await tester.pumpAndSettle();

    final message = _statusMessage(tester);
    expect(message, contains('export completed'));
    expect(message, contains('Revision 4'));
    expect(message, contains('1 profile(s)'));
    expect(message, contains('1 draft(s)'));
    expect(message, contains('1 committed alarm(s)'));
    expect(fx.store.text, isNotNull);
  });

  testWidgets('check reports absent and corrupt distinctly', (tester) async {
    await _mount(tester, fx.controller);

    await tester.tap(find.byKey(const ValueKey('check')));
    await tester.pumpAndSettle();
    expect(
      _statusMessage(tester),
      contains('no saved backup file exists (inspect)'),
    );

    fx.store.text = '{not-json';
    await tester.tap(find.byKey(const ValueKey('check')));
    await tester.pumpAndSettle();
    final message = _statusMessage(tester);
    expect(message, contains('inspect failed'));
    expect(message, contains('not valid JSON'));
  });

  testWidgets('erase transitions to absent and is repeatable', (tester) async {
    await fx.seedBackupRevision3();
    await _mount(tester, fx.controller);

    await tester.tap(find.byKey(const ValueKey('erase')));
    await tester.pumpAndSettle();
    expect(_statusMessage(tester), contains('no saved backup file exists'));
    expect(fx.store.text, isNull);

    await tester.tap(find.byKey(const ValueKey('erase')));
    await tester.pumpAndSettle();
    expect(_statusMessage(tester), contains('no saved backup file exists'));
  });

  testWidgets('all actions are disabled while an operation is busy', (
    tester,
  ) async {
    await _mount(tester, fx.controller);

    fx.store.saveGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('export')));
    await tester.pump();

    expect(fx.controller.isBusy, isTrue);
    expect(_statusMessage(tester), contains('working, export in progress'));
    for (final key in ['export', 'check', 'restore', 'erase']) {
      expect(
        _buttonEnabled(find.byKey(ValueKey(key))),
        isFalse,
        reason: 'action $key must be disabled while busy',
      );
    }

    // Tapping a disabled button must be a no-op.
    await tester.tap(find.byKey(const ValueKey('export')));
    await tester.pump();
    expect(fx.controller.isBusy, isTrue);

    fx.store.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(_statusMessage(tester), contains('export completed'));
    for (final key in ['export', 'check', 'restore', 'erase']) {
      expect(_buttonEnabled(find.byKey(ValueKey(key))), isTrue);
    }
  });

  testWidgets('stale restore shows explicit two-step confirmation', (
    tester,
  ) async {
    await fx.seedBackupRevision3();
    await _mount(tester, fx.controller);

    await tester.tap(find.byKey(const ValueKey('restore')));
    await tester.pumpAndSettle();

    final message = _statusMessage(tester);
    expect(message, contains('confirmation required'));
    expect(message, contains('revision 3'));
    expect(message, contains('revision 5'));
    expect(message, contains('Nothing has been restored yet'));
    // Live stores untouched by the refusal.
    expect(fx.schedule.knownRevision, 5);
    expect(fx.schedule.committedAlarms.single.id, 'live-committed');

    await tester.tap(find.byKey(const ValueKey('confirm-stale')));
    await tester.pumpAndSettle();
    expect(_statusMessage(tester), contains('restore completed'));
    expect(fx.schedule.knownRevision, 3);
    expect(fx.schedule.committedAlarms.single.id, 'saved-committed');
  });

  testWidgets('cancelling stale confirmation preserves live stores', (
    tester,
  ) async {
    await fx.seedBackupRevision3();
    await _mount(tester, fx.controller);

    await tester.tap(find.byKey(const ValueKey('restore')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-stale')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cancel-stale')));
    await tester.pumpAndSettle();

    expect(_statusMessage(tester), contains('inspect completed'));
    expect(fx.schedule.knownRevision, 5);
    expect(fx.schedule.committedAlarms.single.id, 'live-committed');
    expect(find.byKey(const ValueKey('confirm-stale')), findsNothing);
  });

  testWidgets('status is announced as a live-region semantic label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _mount(tester, fx.controller);

    expect(
      find.bySemanticsLabel('Backup status: no action has run yet.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('check')));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(
        'Backup status: no saved backup file exists (inspect).',
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('every control meets the 48 logical pixel minimum', (
    tester,
  ) async {
    await fx.seedBackupRevision3();
    await _mount(tester, fx.controller);

    for (final key in ['export', 'check', 'restore', 'erase']) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }

    await tester.tap(find.byKey(const ValueKey('restore')));
    await tester.pumpAndSettle();
    for (final key in ['confirm-stale', 'cancel-stale']) {
      final size = tester.getSize(find.byKey(ValueKey(key)));
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
  });

  testWidgets('320-wide 200 percent text renders without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _mount(tester, fx.controller);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('check')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_statusMessage(tester), contains('no saved backup file exists'));
  });
}
