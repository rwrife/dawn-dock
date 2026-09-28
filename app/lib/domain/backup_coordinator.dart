/// Host-testable backup flow coordination for the companion's live stores.
///
/// Composes the existing pieces — [DeviceProfileStore], [DraftSet],
/// [DeviceScheduleStore], and [LocalBackupStore] — into one export /
/// inspect / restore / erase flow so screen code (a later slice) never has
/// to sequence backup mechanics itself. Design rules the host tests pin:
///
/// * `export` snapshots live store state and persists it; it never mutates
///   the stores.
/// * `inspect` reports what a saved backup contains WITHOUT touching any
///   store — a preview step must be side-effect free.
/// * `restore` refuses to move the schedule mirror backwards (a backup
///   whose revision is older than the current mirror) unless the caller
///   explicitly acknowledges staleness, and applies a validated backup to
///   all three stores only after every guard passes.
/// * `erase` removes the saved backup and is idempotent.
///
/// Like the rest of `lib/domain/`, this file is pure Dart with no plugins:
/// directory selection stays with [LocalBackupStore]'s caller, and nothing
/// here performs networking or platform secure-storage work.
library;

import 'alarm_draft.dart';
import 'backup.dart';
import 'device_profile.dart';
import 'local_backup_store.dart';
import 'schedule_store.dart';

/// Non-secret overview of one backup document, safe to show in a UI list
/// or confirmation dialog. Carries counts and timestamps only — never the
/// profiles, drafts, alarms, or receipts themselves.
class BackupSummary {
  const BackupSummary({
    required this.exportedAtUtc,
    required this.profileCount,
    required this.draftCount,
    required this.knownRevision,
    required this.committedAlarmCount,
    required this.hasReceipt,
  });

  factory BackupSummary.fromBackup(CompanionBackup backup) => BackupSummary(
    exportedAtUtc: backup.exportedAtUtc,
    profileCount: backup.deviceProfiles.length,
    draftCount: backup.drafts.length,
    knownRevision: backup.knownRevision,
    committedAlarmCount: backup.committedAlarms.length,
    hasReceipt: backup.lastReceipt != null,
  );

  final DateTime exportedAtUtc;
  final int profileCount;
  final int draftCount;
  final int knownRevision;
  final int committedAlarmCount;
  final bool hasReceipt;

  @override
  bool operator ==(Object other) =>
      other is BackupSummary &&
      other.exportedAtUtc == exportedAtUtc &&
      other.profileCount == profileCount &&
      other.draftCount == draftCount &&
      other.knownRevision == knownRevision &&
      other.committedAlarmCount == committedAlarmCount &&
      other.hasReceipt == hasReceipt;

  @override
  int get hashCode => Object.hash(
    exportedAtUtc,
    profileCount,
    draftCount,
    knownRevision,
    committedAlarmCount,
    hasReceipt,
  );

  @override
  String toString() =>
      'BackupSummary(exportedAtUtc: $exportedAtUtc, profileCount: '
      '$profileCount, draftCount: $draftCount, knownRevision: '
      '$knownRevision, committedAlarmCount: $committedAlarmCount, '
      'hasReceipt: $hasReceipt)';
}

/// Sequences backup operations across the live stores and the local backup
/// file. All state reads happen at call time, so a coordinator can outlive
/// edits to the stores it was given.
class BackupCoordinator {
  BackupCoordinator({
    required this.profileStore,
    required this.draftSet,
    required this.scheduleStore,
    required this.backupStore,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final DeviceProfileStore profileStore;
  final DraftSet draftSet;
  final DeviceScheduleStore scheduleStore;
  final LocalBackupStore backupStore;
  final DateTime Function() _clock;

  /// Snapshots the current live state into the backup file and returns the
  /// summary of what was written. An explicit [exportedAtUtc] overrides the
  /// injected clock (tests and "export at this moment" UI flows).
  Future<BackupSummary> export({DateTime? exportedAtUtc}) async {
    final stamp = (exportedAtUtc ?? _clock()).toUtc();
    final profiles = profileStore.profiles;
    final drafts = draftSet.drafts;
    final revision = scheduleStore.knownRevision;
    final committed = scheduleStore.committedAlarms;
    final receipt = scheduleStore.lastReceipt;

    await backupStore.save(
      exportedAtUtc: stamp,
      deviceProfiles: profiles,
      drafts: drafts,
      knownRevision: revision,
      committedAlarms: committed,
      lastReceipt: receipt,
    );

    return BackupSummary(
      exportedAtUtc: stamp,
      profileCount: profiles.length,
      draftCount: drafts.length,
      knownRevision: revision,
      committedAlarmCount: committed.length,
      hasReceipt: receipt != null,
    );
  }

  /// Reports what the saved backup contains without touching any live
  /// store. Returns null when no backup file exists; a file that exists but
  /// fails validation throws [BackupException] so callers can distinguish
  /// "absent" from "present but unreadable".
  Future<BackupSummary?> inspect() async {
    final backup = await backupStore.load();
    if (backup == null) {
      return null;
    }
    return BackupSummary.fromBackup(backup);
  }

  /// Restores from the saved backup file into all live stores.
  ///
  /// By default, stale restores are refused: if the saved backup's
  /// `knownRevision` is lower than the current live schedule revision,
  /// this throws [BackupException]. Call with `allowStale: true` only when
  /// the caller explicitly confirmed that rollback is intended.
  Future<BackupSummary> restore({bool allowStale = false}) async {
    final backup = await backupStore.load();
    if (backup == null) {
      throw BackupException('no saved backup is available to restore');
    }
    _validateStaleGuard(backup, allowStale: allowStale);
    return _applyBackup(backup);
  }

  /// Restores a parsed backup object into all live stores.
  BackupSummary restoreBackup(
    CompanionBackup backup, {
    bool allowStale = false,
  }) {
    _validateStaleGuard(backup, allowStale: allowStale);
    return _applyBackup(backup);
  }

  void _validateStaleGuard(CompanionBackup backup, {required bool allowStale}) {
    final currentRevision = scheduleStore.knownRevision;
    if (!allowStale && backup.knownRevision < currentRevision) {
      throw BackupException(
        'backup revision ${backup.knownRevision} is older than '
        'current revision $currentRevision',
        path: '/scheduleMirror/knownRevision',
      );
    }
  }

  BackupSummary _applyBackup(CompanionBackup backup) {
    backup.applyTo(
      profileStore: profileStore,
      draftSet: draftSet,
      scheduleStore: scheduleStore,
    );
    return BackupSummary.fromBackup(backup);
  }

  /// Deletes the saved backup file. Safe to call when no backup exists.
  Future<void> erase() => backupStore.erase();
}
