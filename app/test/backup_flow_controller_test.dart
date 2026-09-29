import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/backup.dart';
import 'package:dawn_dock_companion/domain/backup_coordinator.dart';
import 'package:dawn_dock_companion/domain/backup_flow_controller.dart';
import 'package:dawn_dock_companion/domain/device_profile.dart';
import 'package:dawn_dock_companion/domain/local_backup_store.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';

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

class _DelayedBackupStore extends LocalBackupStore {
  _DelayedBackupStore({required super.directory, required this.gate});

  final Completer<void> gate;

  @override
  Future<void> save({
    required DateTime exportedAtUtc,
    required List<DeviceProfile> deviceProfiles,
    required List<AlarmDraft> drafts,
    required int knownRevision,
    required List<AlarmDraft> committedAlarms,
    SyncReceipt? lastReceipt,
  }) async {
    await gate.future;
    await super.save(
      exportedAtUtc: exportedAtUtc,
      deviceProfiles: deviceProfiles,
      drafts: drafts,
      knownRevision: knownRevision,
      committedAlarms: committedAlarms,
      lastReceipt: lastReceipt,
    );
  }
}

void main() {
  late Directory tempDir;
  late LocalBackupStore backupStore;
  late DeviceProfileStore profiles;
  late DraftSet drafts;
  late DeviceScheduleStore schedule;
  late BackupCoordinator coordinator;
  late BackupFlowController controller;

  final now = DateTime.utc(2026, 9, 29, 9, 0);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'dawn_dock_backup_flow_controller_test_',
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
    controller = BackupFlowController(
      coordinator: coordinator,
      clock: () => now,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('starts in an idle, non-busy state', () {
    expect(controller.state, isA<BackupInitial>());
    expect(controller.isBusy, isFalse);
    expect(controller.lastSummary, isNull);
  });

  test('inspect distinguishes missing backup from read failure', () async {
    expect(await controller.inspect(), isTrue);
    expect(
      controller.state,
      isA<BackupAbsent>().having(
        (state) => state.operation,
        'operation',
        BackupOperation.inspect,
      ),
    );

    await backupStore.file.writeAsString('{not-json');
    expect(await controller.inspect(), isTrue);
    expect(
      controller.state,
      isA<BackupFailure>()
          .having(
            (state) => state.operation,
            'operation',
            BackupOperation.inspect,
          )
          .having((state) => state.message, 'message', contains('valid JSON')),
    );
  });

  test('export persists current stores and exposes a summary', () async {
    profiles.upsert(
      DeviceProfile(identity: 'bedside', displayName: 'Bedside Dock'),
    );
    drafts.put(_draft('draft-one'));
    schedule.replaceAll(revision: 4, alarms: [_draft('committed-one')]);

    expect(await controller.export(), isTrue);

    expect(
      controller.state,
      isA<BackupSuccess>()
          .having(
            (state) => state.operation,
            'operation',
            BackupOperation.export,
          )
          .having((state) => state.summary.knownRevision, 'revision', 4)
          .having((state) => state.summary.profileCount, 'profiles', 1)
          .having((state) => state.summary.draftCount, 'drafts', 1),
    );
    expect(await backupStore.load(), isNotNull);
  });

  test('a busy export rejects overlapping actions', () async {
    final gate = Completer<void>();
    final delayedStore = _DelayedBackupStore(directory: tempDir, gate: gate);
    final delayedCoordinator = BackupCoordinator(
      backupStore: delayedStore,
      profileStore: profiles,
      draftSet: drafts,
      scheduleStore: schedule,
      clock: () => now,
    );
    final delayedController = BackupFlowController(
      coordinator: delayedCoordinator,
      clock: () => now,
    );

    final exportFuture = delayedController.export();
    await Future<void>.delayed(Duration.zero);

    expect(delayedController.isBusy, isTrue);
    expect(delayedController.state, isA<BackupBusy>());
    expect(await delayedController.inspect(), isFalse);
    expect(await delayedController.erase(), isFalse);

    gate.complete();
    expect(await exportFuture, isTrue);
    expect(delayedController.state, isA<BackupSuccess>());
  });

  test('stale restore requires explicit confirmation and preserves live state first', () async {
    await backupStore.save(
      exportedAtUtc: now,
      deviceProfiles: [
        DeviceProfile(identity: 'saved', displayName: 'Saved Dock'),
      ],
      drafts: [_draft('saved-draft')],
      knownRevision: 3,
      committedAlarms: [_draft('saved-committed')],
    );
    profiles.upsert(DeviceProfile(identity: 'live', displayName: 'Live Dock'));
    drafts.put(_draft('live-draft'));
    schedule.replaceAll(revision: 5, alarms: [_draft('live-committed')]);

    expect(await controller.restore(), isTrue);

    expect(
      controller.state,
      isA<BackupStaleConfirmationRequired>()
          .having((state) => state.backupRevision, 'backup revision', 3)
          .having((state) => state.currentRevision, 'current revision', 5),
    );
    expect(profiles.profiles.single.identity, 'live');
    expect(drafts.drafts.single.id, 'live-draft');
    expect(schedule.knownRevision, 5);
    expect(schedule.committedAlarms.single.id, 'live-committed');

    expect(await controller.confirmStaleRestore(), isTrue);
    expect(
      controller.state,
      isA<BackupSuccess>().having(
        (state) => state.operation,
        'operation',
        BackupOperation.restore,
      ),
    );
    expect(profiles.profiles.single.identity, 'saved');
    expect(drafts.drafts.single.id, 'saved-draft');
    expect(schedule.knownRevision, 3);
    expect(schedule.committedAlarms.single.id, 'saved-committed');
  });

  test('cancel stale confirmation leaves live stores unchanged', () async {
    final backup = CompanionBackup.parse(
      CompanionBackup.encode(
        exportedAtUtc: now,
        deviceProfiles: [
          DeviceProfile(identity: 'saved', displayName: 'Saved Dock'),
        ],
        drafts: [_draft('saved-draft')],
        knownRevision: 2,
        committedAlarms: [_draft('saved-committed')],
      ),
    );
    schedule.replaceAll(revision: 7, alarms: [_draft('live')]);

    expect(controller.restoreParsedBackup(backup), isTrue);
    expect(controller.state, isA<BackupStaleConfirmationRequired>());
    expect(controller.cancelStaleConfirmation(), isTrue);
    expect(controller.state, isA<BackupSuccess>());
    expect(schedule.knownRevision, 7);
    expect(schedule.committedAlarms.single.id, 'live');
    expect(controller.cancelStaleConfirmation(), isFalse);
  });

  test('confirming without a pending stale restore fails closed', () async {
    await expectLater(
      controller.confirmStaleRestore(),
      throwsA(isA<StateError>()),
    );
  });

  test('erase is idempotent and ends in absent state', () async {
    await coordinator.export();
    expect(await backupStore.file.exists(), isTrue);

    expect(await controller.erase(), isTrue);
    expect(await backupStore.file.exists(), isFalse);
    expect(
      controller.state,
      isA<BackupAbsent>().having(
        (state) => state.operation,
        'operation',
        BackupOperation.erase,
      ),
    );

    expect(await controller.erase(), isTrue);
    expect(controller.state, isA<BackupAbsent>());
  });
}
