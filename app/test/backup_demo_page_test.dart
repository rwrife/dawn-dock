import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/backup.dart';
import 'package:dawn_dock_companion/domain/local_backup_store.dart';
import 'package:dawn_dock_companion/main.dart';
import 'package:dawn_dock_companion/ui/backup_demo_page.dart';

Finder _statusText() => find.byKey(const ValueKey('backup-status'));

String _statusMessage(WidgetTester tester) =>
    tester.widget<Text>(_statusText()).data ?? '';

/// Drives a panel action to completion across the fake-clock/real-I/O
/// boundary: the controller's `dart:io` work only progresses when the test
/// yields to the real event loop via [WidgetTester.runAsync], after which a
/// fake-zone `pump` flushes the queued completions into the widget tree.
Future<void> _tapAndSettle(WidgetTester tester, String actionKey) async {
  final button = find.byKey(ValueKey(actionKey));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  for (var attempt = 0; attempt < 200; attempt++) {
    if (!_statusMessage(tester).contains('working')) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  fail('action $actionKey never left the busy state');
}

void main() {
  late Directory backupDir;

  setUp(() async {
    backupDir = await Directory.systemTemp.createTemp('dawn-dock-backup-test');
  });

  tearDown(() async {
    if (backupDir.existsSync()) {
      backupDir.deleteSync(recursive: true);
    }
  });

  File backupFile() => LocalBackupStore(directory: backupDir).file;

  Future<void> mountPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: BackupDemoPage(backupDirectory: backupDir)),
    );
  }

  testWidgets('demo home navigation reaches the backup page', (tester) async {
    await tester.pumpWidget(const MyApp());

    await tester.ensureVisible(find.text('Open backup demo'));
    await tester.tap(find.text('Open backup demo'));
    await tester.pumpAndSettle();

    expect(find.text('Backup demo • Temporary directory'), findsOneWidget);
    expect(find.text('Backup and restore'), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-notice')), findsOneWidget);
    expect(find.byKey(const ValueKey('state-notice')), findsOneWidget);
    expect(find.byKey(const ValueKey('no-hardware-notice')), findsOneWidget);
    expect(_statusMessage(tester), 'Backup status: no action has run yet.');
  });

  testWidgets('navigation control meets the 48 logical pixel minimum', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.ensureVisible(find.text('Open backup demo'));

    final size = tester.getSize(find.byKey(const ValueKey('backup-demo')));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('check reports absent before any file exists', (tester) async {
    await mountPage(tester);
    await _tapAndSettle(tester, 'check');

    expect(
      _statusMessage(tester),
      contains('no saved backup file exists (inspect)'),
    );
    expect(backupFile().existsSync(), isFalse);
  });

  testWidgets('export writes a real backup file to the injected directory', (
    tester,
  ) async {
    await mountPage(tester);
    await _tapAndSettle(tester, 'export');

    final message = _statusMessage(tester);
    expect(message, contains('export completed'));
    expect(message, contains('Revision 0'));

    final file = backupFile();
    expect(file.existsSync(), isTrue, reason: 'export must create a real file');
    final document =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(document['format'], kBackupFormat);
    final mirror = document['scheduleMirror']! as Map<String, Object?>;
    expect(mirror['knownRevision'], 0);
  });

  testWidgets('check reports a summary once a file exists on disk', (
    tester,
  ) async {
    await mountPage(tester);
    await _tapAndSettle(tester, 'export');
    expect(_statusMessage(tester), contains('export completed'));

    await _tapAndSettle(tester, 'check');

    final message = _statusMessage(tester);
    expect(message, contains('inspect completed'));
    expect(message, contains('Revision 0'));
  });

  testWidgets('remounting the page against the same directory discovers the '
      'saved file (widget remount, not an app process restart)', (
    tester,
  ) async {
    await mountPage(tester);
    await _tapAndSettle(tester, 'export');
    expect(backupFile().existsSync(), isTrue);

    // Same-process widget reconstruction only: a new widget tree over the
    // same directory. This is NOT evidence of persistence across an app
    // process restart or platform relaunch.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(home: BackupDemoPage(backupDirectory: backupDir)),
    );

    expect(_statusMessage(tester), 'Backup status: no action has run yet.');
    await _tapAndSettle(tester, 'check');
    expect(_statusMessage(tester), contains('inspect completed'));
    expect(_statusMessage(tester), contains('Revision 0'));
  });

  testWidgets('erase removes the file from disk', (tester) async {
    await mountPage(tester);
    await _tapAndSettle(tester, 'export');
    expect(backupFile().existsSync(), isTrue);

    await _tapAndSettle(tester, 'erase');

    expect(_statusMessage(tester), contains('no saved backup file exists'));
    expect(backupFile().existsSync(), isFalse);
  });

  testWidgets('restore applies an on-disk backup written outside the page', (
    tester,
  ) async {
    // Write a revision-3 backup through a separate store, then show the
    // mounted flow reads it from disk.
    final writer = LocalBackupStore(directory: backupDir);
    await tester.runAsync(() async {
      await writer.save(
        exportedAtUtc: DateTime.utc(2026, 10, 1, 8, 0),
        deviceProfiles: const [],
        drafts: const [],
        knownRevision: 3,
        committedAlarms: const [],
      );
    });

    await mountPage(tester);
    await _tapAndSettle(tester, 'restore');

    // Fresh in-memory mirror is at revision 0; a revision-3 backup is
    // ahead, not stale, so the restore applies without confirmation.
    expect(_statusMessage(tester), contains('restore completed'));
    expect(_statusMessage(tester), contains('Revision 3'));
  });

  testWidgets('320-wide 200 percent text renders without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await mountPage(tester);
    expect(tester.takeException(), isNull);

    await _tapAndSettle(tester, 'check');
    expect(tester.takeException(), isNull);
    expect(_statusMessage(tester), contains('no saved backup file exists'));
  });
}
