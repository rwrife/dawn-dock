/// Revision-tracked schedule state the app holds for a device, plus the
/// last-sync receipt mirror. No transport: `recordApplied` is what a future
/// transport layer calls after a device confirms an apply.
library;

import 'alarm_draft.dart';
import 'protocol_contract.dart' show kMaxStoredAlarms;

class SyncReceipt {
  const SyncReceipt({
    required this.appliedRevision,
    required this.alarmCount,
    required this.nextAlarmUtc,
    required this.receivedAtUtc,
  });

  final int appliedRevision;
  final int alarmCount;
  final DateTime nextAlarmUtc;
  final DateTime receivedAtUtc;

  Map<String, Object?> toMap() => {
    'appliedRevision': appliedRevision,
    'alarmCount': alarmCount,
    'nextAlarmUtc': nextAlarmUtc.toUtc().toIso8601String(),
    'receivedAtUtc': receivedAtUtc.toUtc().toIso8601String(),
  };

  static SyncReceipt fromMap(Map<Object?, Object?> map) {
    Object? need(String key) {
      if (!map.containsKey(key)) {
        throw FormatException('receipt missing $key');
      }
      return map[key];
    }

    final next = DateTime.tryParse(need('nextAlarmUtc') as String? ?? '');
    final received = DateTime.tryParse(need('receivedAtUtc') as String? ?? '');
    if (next == null || received == null) {
      throw const FormatException('receipt timestamps are not ISO-8601');
    }
    return SyncReceipt(
      appliedRevision: need('appliedRevision') as int,
      alarmCount: need('alarmCount') as int,
      nextAlarmUtc: next.toUtc(),
      receivedAtUtc: received.toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncReceipt &&
      other.appliedRevision == appliedRevision &&
      other.alarmCount == alarmCount &&
      other.nextAlarmUtc == nextAlarmUtc &&
      other.receivedAtUtc == receivedAtUtc;

  @override
  int get hashCode =>
      Object.hash(appliedRevision, alarmCount, nextAlarmUtc, receivedAtUtc);
}

enum ScheduleStoreStatus { empty, synced, localAhead }

/// In-memory mirror of one device's committed schedule as last known to the
/// app. The revision counter follows the protocol's optimistic-concurrency
/// model: the app proposes against `knownRevision` and only adopts newer
/// state from an explicit apply receipt.
class DeviceScheduleStore {
  DeviceScheduleStore({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<AlarmDraft> _committed = [];
  int _knownRevision = 0;
  SyncReceipt? _lastReceipt;

  ScheduleStoreStatus get status => _committed.isEmpty && _knownRevision == 0
      ? ScheduleStoreStatus.empty
      : ScheduleStoreStatus.synced;

  int get knownRevision => _knownRevision;
  SyncReceipt? get lastReceipt => _lastReceipt;
  List<AlarmDraft> get committedAlarms => List.unmodifiable(_committed);

  /// Validates a proposed replacement the same way the wire contract would:
  /// capacity and duplicate ids are refused before anything is staged.
  static void validateProposal(List<AlarmDraft> proposal) {
    if (proposal.length > kMaxStoredAlarms) {
      throw ArgumentError(
        'proposal exceeds the $kMaxStoredAlarms-alarm device bound',
      );
    }
    final ids = proposal.map((d) => d.id).toSet();
    if (ids.length != proposal.length) {
      throw ArgumentError('proposal contains duplicate alarm ids');
    }
  }

  /// Adopt a confirmed device apply: the device reported [revision] as
  /// applied, so the app's mirror of committed alarms is replaced and the
  /// receipt recorded. Revisions must move strictly forward; a receipt at or
  /// below the current revision is rejected without touching state.
  void recordApplied({
    required int revision,
    required List<AlarmDraft> appliedAlarms,
    required DateTime nextAlarmUtc,
  }) {
    validateProposal(appliedAlarms);
    if (revision <= _knownRevision) {
      throw StateError(
        'receipt revision $revision does not advance past $_knownRevision',
      );
    }
    _knownRevision = revision;
    _committed
      ..clear()
      ..addAll(appliedAlarms);
    _lastReceipt = SyncReceipt(
      appliedRevision: revision,
      alarmCount: appliedAlarms.length,
      nextAlarmUtc: nextAlarmUtc.toUtc(),
      receivedAtUtc: _clock().toUtc(),
    );
  }

  /// Bulk-replace mirror state (restore-from-backup path). Validated
  /// against proposal bounds; a negative revision or inconsistency with an
  /// attached receipt is rejected without touching state.
  void replaceAll({
    required int revision,
    required List<AlarmDraft> alarms,
    SyncReceipt? receipt,
  }) {
    validateProposal(alarms);
    if (revision < 0) {
      throw ArgumentError('revision must be non-negative');
    }
    if (receipt != null &&
        (receipt.appliedRevision != revision ||
            receipt.alarmCount != alarms.length)) {
      throw ArgumentError('receipt is inconsistent with replaced state');
    }
    _knownRevision = revision;
    _committed
      ..clear()
      ..addAll(alarms);
    _lastReceipt = receipt;
  }

  void clear() {
    _committed.clear();
    _knownRevision = 0;
    _lastReceipt = null;
  }
}
