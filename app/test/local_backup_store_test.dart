import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/backup.dart';
import 'package:dawn_dock_companion/domain/device_profile.dart';
import 'package:dawn_dock_companion/domain/local_backup_store.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';

AlarmDraft _draft(String id, {String label = 'Workday'}) => AlarmDraft(
  id: id,
  label: label,
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

void main() {
  late Directory tempDir;
  late LocalBackupStore store;

  final exportedAt = DateTime.utc(2026, 9, 27, 10, 0);
  final receipt = SyncReceipt(
    appliedRevision: 3,
    alarmCount: 1,
    nextAlarmUtc: DateTime.utc(2026, 9, 28, 11),
    receivedAtUtc: DateTime.utc(2026, 9, 27, 9, 30),
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dawn_dock_backup_test_');
    store = LocalBackupStore(directory: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('LocalBackupStore basics', () {
    test('enforces non-empty fileName', () {
      expect(
        () => LocalBackupStore(directory: tempDir, fileName: ''),
        throwsArgumentError,
      );
    });

    test('rejects path-like fileName values', () {
      for (final bad in ['sub/dir.json', r'sub\dir.json', '.', '..']) {
        expect(
          () => LocalBackupStore(directory: tempDir, fileName: bad),
          throwsArgumentError,
          reason: 'fileName "$bad" must be rejected',
        );
      }
    });

    test('load on absent file returns null without throwing', () async {
      final loaded = await store.load();
      expect(loaded, isNull);
      final loadedText = await store.loadText();
      expect(loadedText, isNull);
    });

    test('save then load round-trips state cleanly', () async {
      await store.save(
        exportedAtUtc: exportedAt,
        deviceProfiles: [
          DeviceProfile(
            identity: 'bedside',
            displayName: 'Bedside Dock',
            note: 'Nightstand',
          ),
        ],
        drafts: [_draft('alarm-1')],
        knownRevision: 3,
        committedAlarms: [_draft('alarm-1')],
        lastReceipt: receipt,
      );

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.exportedAtUtc, exportedAt);
      expect(loaded.deviceProfiles.single.identity, 'bedside');
      expect(loaded.drafts.single.id, 'alarm-1');
      expect(loaded.knownRevision, 3);
      expect(loaded.committedAlarms.single.id, 'alarm-1');
      expect(loaded.lastReceipt, receipt);
    });

    test('save replaces previous content atomically', () async {
      await store.save(
        exportedAtUtc: exportedAt,
        deviceProfiles: [
          DeviceProfile(identity: 'first', displayName: 'First Dock'),
        ],
        drafts: [_draft('first')],
        knownRevision: 1,
        committedAlarms: [_draft('first')],
      );

      var loaded = await store.load();
      expect(loaded!.deviceProfiles.single.identity, 'first');

      await store.save(
        exportedAtUtc: exportedAt.add(const Duration(hours: 1)),
        deviceProfiles: [
          DeviceProfile(identity: 'second', displayName: 'Second Dock'),
        ],
        drafts: [_draft('second')],
        knownRevision: 2,
        committedAlarms: [_draft('second')],
      );

      loaded = await store.load();
      expect(loaded!.deviceProfiles.single.identity, 'second');
      expect(loaded.knownRevision, 2);
    });

    test('erase deletes the file and is idempotent when absent', () async {
      await store.save(
        exportedAtUtc: exportedAt,
        deviceProfiles: [
          DeviceProfile(identity: 'to-delete', displayName: 'Delete Me'),
        ],
        drafts: [_draft('d1')],
        knownRevision: 1,
        committedAlarms: [_draft('d1')],
      );

      expect(await store.file.exists(), isTrue);
      await store.erase();
      expect(await store.file.exists(), isFalse);
      expect(await store.load(), isNull);

      // Calling erase again when already absent should not throw
      await expectLater(store.erase(), completes);
    });

    test('save rejects oversized text before modifying disk', () async {
      final oversizedText = ' ' * (kMaxBackupTextBytes + 10);
      expect(
        () => store.saveText(oversizedText),
        throwsA(isA<BackupException>()),
      );
      expect(await store.file.exists(), isFalse);
    });

    test('corrupt or invalid file content throws on load', () async {
      await store.file.writeAsString('{not valid json');
      expect(() => store.load(), throwsA(isA<BackupException>()));
    });
  });
}
