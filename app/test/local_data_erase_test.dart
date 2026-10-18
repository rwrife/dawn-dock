import 'dart:io';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/backup_coordinator.dart';
import 'package:dawn_dock_companion/domain/device_profile.dart';
import 'package:dawn_dock_companion/domain/local_backup_store.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';
import 'package:flutter_test/flutter_test.dart';

AlarmDraft _alarm() => AlarmDraft(
  id: 'weekday',
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

class _FailingEraseStore extends LocalBackupStore {
  _FailingEraseStore({required super.directory});

  @override
  Future<void> erase() async => throw const FileSystemException('denied');
}

void main() {
  late Directory directory;
  late DeviceProfileStore profiles;
  late DraftSet drafts;
  late DeviceScheduleStore schedule;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dawn-erase-');
    profiles = DeviceProfileStore();
    drafts = DraftSet();
    schedule = DeviceScheduleStore();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  BackupCoordinator coordinator(LocalBackupStore store) => BackupCoordinator(
    backupStore: store,
    profileStore: profiles,
    draftSet: drafts,
    scheduleStore: schedule,
  );

  void populate() {
    profiles.upsert(
      DeviceProfile(identity: 'device-1', displayName: 'Bedroom'),
    );
    drafts.put(_alarm());
    schedule.recordApplied(
      revision: 1,
      appliedAlarms: [_alarm()],
      nextAlarmUtc: DateTime.utc(2026, 10, 19, 11),
    );
  }

  test(
    'erases owned file and all three live stores, including receipt',
    () async {
      final store = LocalBackupStore(directory: directory);
      final flow = coordinator(store);
      populate();
      await flow.export();
      expect(await store.file.exists(), isTrue);
      expect(schedule.lastReceipt, isNotNull);

      await flow.eraseLocalData();

      expect(await store.file.exists(), isFalse);
      expect(profiles.profiles, isEmpty);
      expect(drafts.drafts, isEmpty);
      expect(schedule.committedAlarms, isEmpty);
      expect(schedule.knownRevision, 0);
      expect(schedule.lastReceipt, isNull);
      await flow.eraseLocalData();
      expect(await store.file.exists(), isFalse);
    },
  );

  test('erase on empty stores and absent file is idempotent', () async {
    final store = LocalBackupStore(directory: directory);
    await coordinator(store).eraseLocalData();
    await coordinator(store).eraseLocalData();
    expect(await store.file.exists(), isFalse);
    expect(schedule.knownRevision, 0);
  });

  test('file deletion failure leaves every live store untouched', () async {
    populate();
    final flow = coordinator(_FailingEraseStore(directory: directory));
    final beforeReceipt = schedule.lastReceipt;
    await expectLater(
      flow.eraseLocalData(),
      throwsA(isA<FileSystemException>()),
    );
    expect(profiles.profiles.single.identity, 'device-1');
    expect(drafts.drafts.single.id, 'weekday');
    expect(schedule.committedAlarms.single.id, 'weekday');
    expect(schedule.knownRevision, 1);
    expect(schedule.lastReceipt, beforeReceipt);
  });
}
