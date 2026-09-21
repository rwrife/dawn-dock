/// Deterministic, reviewable diff between a device schedule mirror and a
/// proposed set of alarm drafts.
///
/// This is the domain half of the `schedule.preview` / `schedule.apply`
/// review flow from `docs/protocol.md`: before any preview envelope is ever
/// sent, the user sees exactly which alarms would be added, removed, or
/// changed, with stable machine-readable field-change codes. Comparison
/// semantics match [AlarmDraft]'s `==`/`hashCode` (weekday masks are sets),
/// so the diff never reports a change the device would treat as a no-op.
///
/// Pure Dart with no I/O: no transport, envelope framing, UI, or filesystem
/// access. [ScheduleDiff.toWirePreviewBody] emits only the alarm-array body
/// payload; wrapping it in a versioned envelope with `expectedRevision` and a
/// fresh `messageId` is the future transport slice's job.
library;

import 'alarm_draft.dart';
import 'schedule_store.dart';

/// Stable, machine-readable codes for the wire-relevant fields of
/// [AlarmDraft]. A changed alarm lists exactly the codes whose values differ
/// between the committed and proposed draft.
const List<String> kScheduleDiffFieldCodes = [
  'days',
  'enabled',
  'label',
  'local-time',
  'snooze-minutes',
  'sound',
  'source-or-provenance',
  'timezone',
  'volume',
];

/// Sorted field-change codes between two drafts with the same id.
///
/// The result contains only codes from [kScheduleDiffFieldCodes] and is
/// sorted; an empty list means the drafts compare equal (which, per
/// [AlarmDraft]'s value equality, also means the device would see no
/// difference).
List<String> describeFieldChanges(AlarmDraft before, AlarmDraft after) {
  if (before.id != after.id) {
    throw ArgumentError.value(
      after.id,
      'after.id',
      'field changes require the same alarm id',
    );
  }
  final codes = <String>[];
  if (before.label != after.label) codes.add('label');
  if (before.enabled != after.enabled) codes.add('enabled');
  if (before.localHour != after.localHour ||
      before.localMinute != after.localMinute) {
    codes.add('local-time');
  }
  if (!_sameDaySet(before.days, after.days)) codes.add('days');
  if (before.timezone != after.timezone) codes.add('timezone');
  if (before.snoozeMinutes != after.snoozeMinutes) {
    codes.add('snooze-minutes');
  }
  if (before.volume != after.volume) codes.add('volume');
  if (before.sound != after.sound) codes.add('sound');
  if (before.source != after.source || before.provenance != after.provenance) {
    codes.add('source-or-provenance');
  }
  codes.sort();
  return List.unmodifiable(codes);
}

bool _sameDaySet(Set<int> a, Set<int> b) {
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

/// One alarm that exists in both baseline and proposal but differs.
class ChangedAlarm {
  ChangedAlarm({required this.before, required this.after})
    : fieldCodes = describeFieldChanges(before, after) {
    if (fieldCodes.isEmpty) {
      throw ArgumentError(
        'changed alarm ${after.id} has no field differences; '
        'it belongs in unchanged ids',
      );
    }
  }

  final AlarmDraft before;
  final AlarmDraft after;

  /// Sorted stable codes from [kScheduleDiffFieldCodes]; never empty.
  final List<String> fieldCodes;

  String get id => after.id;

  Map<String, Object?> toMap() => {
    'id': id,
    'fieldCodes': fieldCodes,
    'before': before.toMap(),
    'after': after.toMap(),
  };

  @override
  bool operator ==(Object other) =>
      other is ChangedAlarm &&
      other.before == before &&
      other.after == after &&
      _sameCodeList(other.fieldCodes, fieldCodes);

  @override
  int get hashCode => Object.hash(before, after, Object.hashAll(fieldCodes));
}

bool _sameCodeList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The reviewable result of comparing committed schedule state against a
/// proposal. All collections are unmodifiable and sorted by alarm id, so the
/// same inputs always produce a `==`-equal, identically ordered diff.
class ScheduleDiff {
  ScheduleDiff._({
    required this.expectedRevision,
    required List<AlarmDraft> addedAlarms,
    required List<AlarmDraft> removedAlarms,
    required List<ChangedAlarm> changedAlarms,
    required List<AlarmDraft> unchangedAlarms,
  }) : _added = List.unmodifiable(addedAlarms),
       _removed = List.unmodifiable(removedAlarms),
       _changed = List.unmodifiable(changedAlarms),
       _unchangedAlarms = List.unmodifiable(unchangedAlarms),
       _unchanged = List.unmodifiable(
         <String>[for (final a in unchangedAlarms) a.id]..sort(_byIdKey),
       );

  /// The revision the proposal expects the device to be at, recorded for
  /// the future preview/apply envelope. This class does not validate it
  /// against the store — a stale revision is the device's
  /// `revision_conflict` decision, surfaced after transport lands.
  final int expectedRevision;

  final List<AlarmDraft> _added;
  final List<AlarmDraft> _removed;
  final List<ChangedAlarm> _changed;
  final List<AlarmDraft> _unchangedAlarms;
  final List<String> _unchanged;

  /// Proposal alarms with no committed alarm of the same id, id-sorted.
  List<AlarmDraft> get added => _added;

  /// Committed alarms absent from the proposal, id-sorted.
  List<AlarmDraft> get removed => _removed;

  /// Alarms present in both whose values differ, id-sorted.
  List<ChangedAlarm> get changed => _changed;

  /// Ids present in both with identical values, id-sorted.
  List<String> get unchanged => _unchanged;

  bool get isEmpty => _added.isEmpty && _removed.isEmpty && _changed.isEmpty;

  /// The full proposed replacement set in apply order: additions first,
  /// then changed (carrying the proposed value), then unchanged — each
  /// group id-sorted. This is the alarm array a `schedule.apply` would
  /// send; `removed` alarms are simply absent.
  List<AlarmDraft> get proposedOrder => List.unmodifiable([
    ..._added,
    ..._changed.map((c) => c.after),
    ..._unchangedAlarms,
  ]);

  /// The `alarms` array body payload matching the `schedule.preview` /
  /// `schedule.apply` wire shape exactly (the full proposed replacement
  /// set, keys from [AlarmDraft.toWireAlarm]). No envelope fields are
  /// added; envelope framing, `expectedRevision`, and message identity
  /// belong to the transport slice.
  List<Map<String, Object?>> toWirePreviewBody() => [
    for (final alarm in proposedOrder) alarm.toWireAlarm(),
  ];

  /// Stable plain-text review summary: a header line plus one line per
  /// changed, added, and removed alarm (that order, id-sorted within each).
  /// Deterministic and locale-free so it is safe for tests and accessible
  /// text rendering.
  String summaryText() {
    final lines = <String>[
      'Schedule review: ${_added.length} added, ${_removed.length} removed, '
          '${_changed.length} changed, ${_unchanged.length} unchanged '
          '(expected revision $expectedRevision).',
    ];
    for (final c in _changed) {
      lines.add('~ ${c.id}: ${c.fieldCodes.join(', ')}');
    }
    for (final a in _added) {
      lines.add('+ ${a.id}: ${a.label} ${a.localTime}');
    }
    for (final a in _removed) {
      lines.add('- ${a.id}: ${a.label} ${a.localTime}');
    }
    return lines.join('\n');
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleDiff &&
      other.expectedRevision == expectedRevision &&
      _sameDraftList(other._added, _added) &&
      _sameDraftList(other._removed, _removed) &&
      _sameChangedList(other._changed, _changed) &&
      _sameDraftList(other._unchangedAlarms, _unchangedAlarms) &&
      _sameStringList(other._unchanged, _unchanged);

  @override
  int get hashCode => Object.hash(
    expectedRevision,
    Object.hashAll(_added),
    Object.hashAll(_removed),
    Object.hashAll(_changed),
    Object.hashAll(_unchangedAlarms),
    Object.hashAll(_unchanged),
  );
}

bool _sameDraftList(List<AlarmDraft> a, List<AlarmDraft> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameChangedList(List<ChangedAlarm> a, List<ChangedAlarm> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameStringList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _byIdKey(String a, String b) => a.compareTo(b);

/// Diff a proposal against a committed baseline.
///
/// [baseline] is what the app believes is committed (typically
/// `DeviceScheduleStore.committedAlarms`); [proposal] is the user's
/// complete intended replacement set. The proposal is validated with
/// [DeviceScheduleStore.validateProposal] *before* any diff work, so a
/// proposal that the wire contract would refuse (over capacity or
/// duplicate ids) raises the same `ArgumentError` and produces no partial
/// diff.
///
/// Comparison uses [AlarmDraft] value equality; weekday masks are sets, so
/// re-serialization of an unchanged alarm is reported as unchanged, not as
/// a modification.
ScheduleDiff diffSchedule({
  required Iterable<AlarmDraft> baseline,
  required Iterable<AlarmDraft> proposal,
  required int expectedRevision,
}) {
  final baselineList = baseline.toList(growable: false);
  final proposalList = proposal.toList(growable: false);
  DeviceScheduleStore.validateProposal(proposalList);

  final baselineById = <String, AlarmDraft>{};
  for (final alarm in baselineList) {
    baselineById[alarm.id] = alarm;
  }
  final proposalById = <String, AlarmDraft>{
    for (final alarm in proposalList) alarm.id: alarm,
  };

  final added = <AlarmDraft>[];
  final changed = <ChangedAlarm>[];
  final unchanged = <AlarmDraft>[];
  for (final alarm in proposalList) {
    final before = baselineById[alarm.id];
    if (before == null) {
      added.add(alarm);
      continue;
    }
    final codes = describeFieldChanges(before, alarm);
    if (codes.isEmpty) {
      unchanged.add(alarm);
    } else {
      changed.add(ChangedAlarm(before: before, after: alarm));
    }
  }

  final removed = <AlarmDraft>[
    for (final alarm in baselineList)
      if (!proposalById.containsKey(alarm.id)) alarm,
  ];

  added.sort((a, b) => _byIdKey(a.id, b.id));
  removed.sort((a, b) => _byIdKey(a.id, b.id));
  changed.sort((a, b) => _byIdKey(a.id, b.id));
  unchanged.sort((a, b) => _byIdKey(a.id, b.id));

  return ScheduleDiff._(
    expectedRevision: expectedRevision,
    addedAlarms: added,
    removedAlarms: removed,
    changedAlarms: changed,
    unchangedAlarms: unchanged,
  );
}
