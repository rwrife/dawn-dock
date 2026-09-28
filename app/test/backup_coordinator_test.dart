import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/backup.dart';
import 'package:dawn_dock_companion/domain/backup_coordinator.dart';
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
  late LocalBackupStore backupStore;
  late DeviceProfileStore profiles;
  late DraftSet drafts;
  late DeviceScheduleStore schedule;
  late BackupCoordinator coordinator;

  final now = DateTime.utc(2026, 9, 28, 12, 30);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'dawn_dock_backup_coordinator_test_',
    );
    backupStore = LocalBackupStore(directory: tempDir);
    profiles = DeviceProfileStore();
    drafts = DraftSet();
    schedule = DeviceScheduleStore(clock: () => now);
    coordinator = BackupCoordinator(
      backupStore: backupStore,
      profileStore: profiles,
      draftSet: drafts,
      scheduleStore: schedule,
      clock: () => now,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'export saves all current stores and returns a stable summary',
    () async {
      profiles.upsert(
        DeviceProfile(identity: 'bedside', displayName: 'Bedside Dock'),
      );
      drafts.put(_draft('draft-one'));
      schedule.replaceAll(revision: 4, alarms: [_draft('committed-one')]);

      final summary = await coordinator.export();

      expect(
        summary,
        BackupSummary(
          exportedAtUtc: now,
          profileCount: 1,
          draftCount: 1,
          knownRevision: 4,
          committedAlarmCount: 1,
          hasReceipt: false,
        ),
      );
      final persisted = await backupStore.load();
      expect(persisted, isNotNull);
      expect(persisted!.exportedAtUtc, now);
      expect(persisted.deviceProfiles.single.identity, 'bedside');
      expect(persisted.drafts.single.id, 'draft-one');
      expect(persisted.knownRevision, 4);
      expect(persisted.committedAlarms.single.id, 'committed-one');
    },
  );

  group('inspection', () {
    test('returns null when no saved backup exists', () async {
      expect(await coordinator.inspect(), isNull);
    });

    test('summarizes saved content without mutating live stores', () async {
      await backupStore.save(
        exportedAtUtc: now,
        deviceProfiles: [
          DeviceProfile(identity: 'saved', displayName: 'Saved Dock'),
        ],
        drafts: [_draft('saved-draft')],
        knownRevision: 8,
        committedAlarms: [_draft('saved-committed')],
      );
      profiles.upsert(
        DeviceProfile(identity: 'live', displayName: 'Live Dock'),
      );
      drafts.put(_draft('live-draft'));
      schedule.replaceAll(revision: 12, alarms: [_draft('live-committed')]);

      final summary = await coordinator.inspect();

      expect(
        summary,
        BackupSummary(
          exportedAtUtc: now,
          profileCount: 1,
          draftCount: 1,
          knownRevision: 8,
          committedAlarmCount: 1,
          hasReceipt: false,
        ),
      );
      expect(profiles.profiles.single.identity, 'live');
      expect(drafts.drafts.single.id, 'live-draft');
      expect(schedule.knownRevision, 12);
      expect(schedule.committedAlarms.single.id, 'live-committed');
    });

    test(
      'propagates corrupt-content failure rather than reporting absent',
      () async {
        await backupStore.file.writeAsString('{not valid json');

        await expectLater(
          coordinator.inspect(),
          throwsA(isA<BackupException>()),
        );
      },
    );
  });

  group('restore', () {
    test('reports a missing backup without changing live stores', () async {
      profiles.upsert(
        DeviceProfile(identity: 'live', displayName: 'Live Dock'),
      );
      drafts.put(_draft('live-draft'));
      schedule.replaceAll(revision: 3, alarms: [_draft('live-committed')]);

      await expectLater(
        coordinator.restore(),
        throwsA(
          isA<BackupException>().having(
            (error) => error.message,
            'message',
            'no saved backup is available to restore',
          ),
        ),
      );
      expect(profiles.profiles.single.identity, 'live');
      expect(drafts.drafts.single.id, 'live-draft');
      expect(schedule.knownRevision, 3);
      expect(schedule.committedAlarms.single.id, 'live-committed');
    });

    test('replaces all live stores after full backup validation', () async {
      final receipt = SyncReceipt(
        appliedRevision: 9,
        alarmCount: 1,
        nextAlarmUtc: DateTime.utc(2026, 9, 29, 11),
        receivedAtUtc: now,
      );
      await backupStore.save(
        exportedAtUtc: now,
        deviceProfiles: [
          DeviceProfile(identity: 'saved', displayName: 'Saved Dock'),
        ],
        drafts: [_draft('saved-draft')],
        knownRevision: 9,
        committedAlarms: [_draft('saved-committed')],
        lastReceipt: receipt,
      );
      profiles.upsert(
        DeviceProfile(identity: 'live', displayName: 'Live Dock'),
      );
      drafts.put(_draft('live-draft'));
      schedule.replaceAll(revision: 4, alarms: [_draft('live-committed')]);

      final summary = await coordinator.restore();

      expect(
        summary,
        BackupSummary(
          exportedAtUtc: now,
          profileCount: 1,
          draftCount: 1,
          knownRevision: 9,
          committedAlarmCount: 1,
          hasReceipt: true,
        ),
      );
      expect(profiles.profiles.single.identity, 'saved');
      expect(drafts.drafts.single.id, 'saved-draft');
      expect(schedule.knownRevision, 9);
      expect(schedule.committedAlarms.single.id, 'saved-committed');
      expect(schedule.lastReceipt, receipt);
    });

    test(
      'refuses a stale schedule revision without changing any store',
      () async {
        await backupStore.save(
          exportedAtUtc: now,
          deviceProfiles: [
            DeviceProfile(identity: 'saved', displayName: 'Saved Dock'),
          ],
          drafts: [_draft('saved-draft')],
          knownRevision: 5,
          committedAlarms: [_draft('saved-committed')],
        );
        profiles.upsert(
          DeviceProfile(identity: 'live', displayName: 'Live Dock'),
        );
        drafts.put(_draft('live-draft'));
        schedule.replaceAll(revision: 6, alarms: [_draft('live-committed')]);

        await expectLater(
          coordinator.restore(),
          throwsA(
            isA<BackupException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains(
                    'backup revision 5 is older than current revision 6',
                  ),
                )
                .having(
                  (error) => error.path,
                  'path',
                  '/scheduleMirror/knownRevision',
                ),
          ),
        );
        expect(profiles.profiles.single.identity, 'live');
        expect(drafts.drafts.single.id, 'live-draft');
        expect(schedule.knownRevision, 6);
        expect(schedule.committedAlarms.single.id, 'live-committed');
      },
    );

    test(
      'refuses corrupt saved backup content without mutating any live store',
      () async {
        profiles.upsert(
          DeviceProfile(identity: 'live', displayName: 'Live Dock'),
        );
        drafts.put(_draft('live-draft'));
        schedule.replaceAll(revision: 7, alarms: [_draft('live-committed')]);

        await backupStore.file.writeAsString('{not valid json');

        await expectLater(
          coordinator.restore(),
          throwsA(
            isA<BackupException>().having(
              (error) => error.message,
              'message',
              contains('not valid JSON'),
            ),
          ),
        );
        expect(profiles.profiles.single.identity, 'live');
        expect(drafts.drafts.single.id, 'live-draft');
        expect(schedule.knownRevision, 7);
        expect(schedule.committedAlarms.single.id, 'live-committed');
      },
    );

    test('allows an explicitly acknowledged stale restore', () async {
      await backupStore.save(
        exportedAtUtc: now,
        deviceProfiles: [
          DeviceProfile(identity: 'saved', displayName: 'Saved Dock'),
        ],
        drafts: [_draft('saved-draft')],
        knownRevision: 5,
        committedAlarms: [_draft('saved-committed')],
      );
      schedule.replaceAll(revision: 6, alarms: [_draft('live-committed')]);

      final summary = await coordinator.restore(allowStale: true);

      expect(summary.knownRevision, 5);
      expect(profiles.profiles.single.identity, 'saved');
      expect(drafts.drafts.single.id, 'saved-draft');
      expect(schedule.knownRevision, 5);
      expect(schedule.committedAlarms.single.id, 'saved-committed');
    });

    test('restoreBackup restores directly from an in-memory backup', () {
      final backup = CompanionBackup.parse(
        CompanionBackup.encode(
          exportedAtUtc: now,
          deviceProfiles: [
            DeviceProfile(identity: 'in-mem', displayName: 'In-Memory Dock'),
          ],
          drafts: [_draft('in-mem-draft')],
          knownRevision: 8,
          committedAlarms: [_draft('in-mem-alarm')],
        ),
      );

      final summary = coordinator.restoreBackup(backup);

      expect(summary.knownRevision, 8);
      expect(profiles.profiles.single.identity, 'in-mem');
      expect(drafts.drafts.single.id, 'in-mem-draft');
      expect(schedule.knownRevision, 8);
      expect(schedule.committedAlarms.single.id, 'in-mem-alarm');
    });
  });

  group('erase', () {
    test('removes saved backup and subsequent inspect returns null', () async {
      await coordinator.export();
      expect(await coordinator.inspect(), isNotNull);

      await coordinator.erase();

      expect(await coordinator.inspect(), isNull);
      await expectLater(coordinator.erase(), completes);
    });
  });
}
