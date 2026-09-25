/// Pure-Dart device status and next-alarm projection over committed schedules.
///
/// Combines the local [DeviceScheduleStore] mirror, caller-supplied
/// [TimezoneRules] for active alarm timezones, and the device's explicit
/// [SyncReceipt] to produce a deterministic, truthful summary of upcoming
/// alarm occurrences and sync status without claiming live transport or
/// hardware execution.
///
/// Parity and correctness rules:
/// * Only enabled alarms are evaluated; disabled alarms never produce an
///   occurrence.
/// * If any enabled alarm cannot be resolved (missing rules, rule-version
///   mismatch, malformed schedule, or resolver outOfRange), the projection
///   fails closed for [nextOccurrence] because an unresolvable alarm could be
///   earlier than any resolved candidate.
/// * When multiple enabled alarms produce occurrences at the exact same
///   scheduled UTC instant, ties are broken deterministically by alarm `id`
///   in ascending lexicographic order.
/// * [NextAlarmEvidence] distinguishes local-only projection from explicit
///   sync-receipt agreement or mismatch. A receipt only confirms the next alarm
///   when its applied revision matches the store's current known revision.
library;

import 'alarm_draft.dart';
import 'recurrence.dart';
import 'schedule_store.dart';

/// Evidence classification for the projected next alarm.
enum NextAlarmEvidence {
  /// No alarms are enabled or the committed schedule is empty.
  none,

  /// At least one enabled alarm cannot be resolved (missing timezone rules,
  /// malformed schedule, or resolver outOfRange); a next-alarm claim is
  /// withheld because the unresolved alarm could be earlier.
  unresolved,

  /// The next occurrence was projected purely from the local committed schedule
  /// mirror; no sync receipt exists for the current revision.
  projectedOnly,

  /// The local projection exactly matches the device's explicit sync receipt
  /// `nextAlarmUtc` for the current committed revision.
  confirmedByReceipt,

  /// A sync receipt exists for the current committed revision, but its
  /// `nextAlarmUtc` disagrees with the local recurrence projection (e.g. clock
  /// drift across an anchor or conflicting timezone rule data).
  receiptMismatch,
}

/// One candidate alarm occurrence paired with its source draft and resolution.
class ProjectedOccurrence {
  const ProjectedOccurrence({required this.alarm, required this.occurrence});

  final AlarmDraft alarm;
  final ResolvedOccurrence occurrence;

  int get scheduledUtcSeconds => occurrence.scheduledUtcSeconds;

  DateTime get scheduledUtc => DateTime.fromMillisecondsSinceEpoch(
    scheduledUtcSeconds * 1000,
    isUtc: true,
  );

  bool get shiftedForGap => occurrence.shiftedForGap;
  bool get ambiguousFold => occurrence.ambiguousFold;
  String get localTime => occurrence.localTime;
  CivilDate get localDate => occurrence.localDate;

  @override
  bool operator ==(Object other) =>
      other is ProjectedOccurrence &&
      other.alarm == alarm &&
      other.occurrence.status == occurrence.status &&
      other.occurrence.scheduledUtcSeconds == occurrence.scheduledUtcSeconds &&
      other.occurrence.localDate == occurrence.localDate &&
      other.occurrence.resolvedLocalHour == occurrence.resolvedLocalHour &&
      other.occurrence.resolvedLocalMinute == occurrence.resolvedLocalMinute &&
      other.occurrence.utcOffsetSeconds == occurrence.utcOffsetSeconds &&
      other.occurrence.shiftedForGap == occurrence.shiftedForGap &&
      other.occurrence.ambiguousFold == occurrence.ambiguousFold;

  @override
  int get hashCode => Object.hash(
    alarm,
    occurrence.scheduledUtcSeconds,
    occurrence.localDate,
    occurrence.resolvedLocalHour,
    occurrence.resolvedLocalMinute,
    occurrence.utcOffsetSeconds,
    occurrence.shiftedForGap,
    occurrence.ambiguousFold,
  );

  @override
  String toString() =>
      'ProjectedOccurrence(${alarm.id}, ${occurrence.localTime} on ${occurrence.localDate}, UTC $scheduledUtcSeconds)';
}

/// Unresolved alarm diagnosis when [NextAlarmEvidence.unresolved] is produced.
class UnresolvedAlarmDetail {
  const UnresolvedAlarmDetail({
    required this.alarmId,
    required this.timezone,
    required this.status,
    required this.reason,
  });

  final String alarmId;
  final String timezone;
  final OccurrenceResolutionStatus? status;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is UnresolvedAlarmDetail &&
      other.alarmId == alarmId &&
      other.timezone == timezone &&
      other.status == status &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(alarmId, timezone, status, reason);

  @override
  String toString() => 'UnresolvedAlarmDetail($alarmId, $timezone, $reason)';
}

/// Deterministic projection of device status and next-alarm occurrence.
class DeviceStatusProjection {
  const DeviceStatusProjection({
    required this.revision,
    required this.totalAlarms,
    required this.enabledAlarmsCount,
    required this.nextOccurrence,
    required this.evidence,
    required this.unresolvedAlarms,
    required this.lastReceipt,
  });

  /// Committed revision of the schedule mirror.
  final int revision;

  /// Total alarms in the committed schedule mirror (enabled + disabled).
  final int totalAlarms;

  /// Count of enabled alarms in the committed schedule mirror.
  final int enabledAlarmsCount;

  /// Earliest projected occurrence strictly after the evaluation anchor,
  /// or null if no alarm is enabled or resolution was withheld.
  final ProjectedOccurrence? nextOccurrence;

  /// Evidence class of [nextOccurrence].
  final NextAlarmEvidence evidence;

  /// Details on any enabled alarm that failed to resolve, sorted by alarm `id`.
  final List<UnresolvedAlarmDetail> unresolvedAlarms;

  /// The store's last sync receipt, or null.
  final SyncReceipt? lastReceipt;

  bool get hasNextAlarm => nextOccurrence != null;
  bool get isConfirmed => evidence == NextAlarmEvidence.confirmedByReceipt;

  @override
  bool operator ==(Object other) =>
      other is DeviceStatusProjection &&
      other.revision == revision &&
      other.totalAlarms == totalAlarms &&
      other.enabledAlarmsCount == enabledAlarmsCount &&
      other.nextOccurrence == nextOccurrence &&
      other.evidence == evidence &&
      _listEquals(other.unresolvedAlarms, unresolvedAlarms) &&
      other.lastReceipt == lastReceipt;

  @override
  int get hashCode => Object.hash(
    revision,
    totalAlarms,
    enabledAlarmsCount,
    nextOccurrence,
    evidence,
    Object.hashAll(unresolvedAlarms),
    lastReceipt,
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Project status and next alarm from a committed [DeviceScheduleStore] mirror.
///
/// [rulesProvider] maps a timezone name to its supplied [TimezoneRules]. If
/// an enabled alarm references a timezone not returned by [rulesProvider],
/// it is diagnosed as missing rules and next alarm is marked [NextAlarmEvidence.unresolved].
///
/// [afterUtcSeconds] is the evaluation anchor in epoch seconds (usually current
/// wall-clock UTC seconds).
DeviceStatusProjection projectDeviceStatus({
  required DeviceScheduleStore store,
  required TimezoneRules? Function(String timezone) rulesProvider,
  required int afterUtcSeconds,
  String timezoneRulesVersion = '2026a',
}) {
  final committed = store.committedAlarms;
  final enabled = committed.where((a) => a.enabled).toList();

  if (enabled.isEmpty) {
    return DeviceStatusProjection(
      revision: store.knownRevision,
      totalAlarms: committed.length,
      enabledAlarmsCount: 0,
      nextOccurrence: null,
      evidence: NextAlarmEvidence.none,
      unresolvedAlarms: const [],
      lastReceipt: store.lastReceipt,
    );
  }

  final unresolved = <UnresolvedAlarmDetail>[];
  final candidates = <ProjectedOccurrence>[];

  for (final alarm in enabled) {
    final rules = rulesProvider(alarm.timezone);
    if (rules == null) {
      unresolved.add(
        UnresolvedAlarmDetail(
          alarmId: alarm.id,
          timezone: alarm.timezone,
          status: null,
          reason: 'missing_timezone_rules',
        ),
      );
      continue;
    }

    final schedule = WeeklyOccurrenceSchedule.fromAlarm(
      alarm,
      timezoneRulesVersion: timezoneRulesVersion,
    );

    final resolved = resolveNextOccurrence(
      schedule: schedule,
      rules: rules,
      afterUtcSeconds: afterUtcSeconds,
    );

    if (resolved.status != OccurrenceResolutionStatus.resolved) {
      unresolved.add(
        UnresolvedAlarmDetail(
          alarmId: alarm.id,
          timezone: alarm.timezone,
          status: resolved.status,
          reason: resolved.status.name,
        ),
      );
      continue;
    }

    candidates.add(ProjectedOccurrence(alarm: alarm, occurrence: resolved));
  }

  if (unresolved.isNotEmpty) {
    unresolved.sort((a, b) => a.alarmId.compareTo(b.alarmId));
    return DeviceStatusProjection(
      revision: store.knownRevision,
      totalAlarms: committed.length,
      enabledAlarmsCount: enabled.length,
      nextOccurrence: null,
      evidence: NextAlarmEvidence.unresolved,
      unresolvedAlarms: List.unmodifiable(unresolved),
      lastReceipt: store.lastReceipt,
    );
  }

  // Sort candidates by earliest scheduled UTC seconds ascending, breaking ties
  // by alarm `id` ascending for deterministic order.
  candidates.sort((a, b) {
    final cmp = a.scheduledUtcSeconds.compareTo(b.scheduledUtcSeconds);
    if (cmp != 0) return cmp;
    return a.alarm.id.compareTo(b.alarm.id);
  });

  final earliest = candidates.first;

  // Evaluate evidence against sync receipt.
  final receipt = store.lastReceipt;
  NextAlarmEvidence evidence;

  if (receipt == null || receipt.appliedRevision != store.knownRevision) {
    evidence = NextAlarmEvidence.projectedOnly;
  } else {
    final receiptUtcSeconds =
        receipt.nextAlarmUtc.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (receiptUtcSeconds == earliest.scheduledUtcSeconds) {
      evidence = NextAlarmEvidence.confirmedByReceipt;
    } else {
      evidence = NextAlarmEvidence.receiptMismatch;
    }
  }

  return DeviceStatusProjection(
    revision: store.knownRevision,
    totalAlarms: committed.length,
    enabledAlarmsCount: enabled.length,
    nextOccurrence: earliest,
    evidence: evidence,
    unresolvedAlarms: const [],
    lastReceipt: receipt,
  );
}
