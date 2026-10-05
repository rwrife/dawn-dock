/// Read-only, local presentation of a caller-supplied schedule projection.
/// No connection, wall-clock read, device alarm execution or refresh is implied.
library;

import 'package:flutter/material.dart';

import '../domain/device_status.dart';

class DeviceStatusPanel extends StatelessWidget {
  const DeviceStatusPanel({super.key, required this.projection});

  final DeviceStatusProjection projection;

  String get _evidenceText => switch (projection.evidence) {
    NextAlarmEvidence.none => 'No enabled alarms in the local schedule mirror.',
    NextAlarmEvidence.unresolved =>
      'Next alarm withheld: one or more enabled alarms cannot be resolved.',
    NextAlarmEvidence.projectedOnly =>
      'Local projection only; no matching receipt for this revision.',
    NextAlarmEvidence.confirmedByReceipt => 'Projection matches a stored receipt for this revision. This is not live device status.',
    NextAlarmEvidence.receiptMismatch => 'Warning: stored receipt disagrees with the local projection. Do not rely on this next alarm.',
  };

  @override
  Widget build(BuildContext context) {
    // A malformed caller-produced projection must not surface a next alarm
    // when the evidence explicitly withholds one.
    final next =
        projection.evidence == NextAlarmEvidence.unresolved ||
            projection.evidence == NextAlarmEvidence.none
        ? null
        : projection.nextOccurrence;
    final evidence = _evidenceText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Local schedule mirror',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          'Revision ${projection.revision}; ${projection.enabledAlarmsCount} enabled of ${projection.totalAlarms} alarms.',
        ),
        Semantics(
          liveRegion: true,
          label: evidence,
          excludeSemantics: true,
          child: Text(evidence, key: const ValueKey('status-evidence')),
        ),
        if (projection.evidence == NextAlarmEvidence.unresolved)
          for (final problem in projection.unresolvedAlarms)
            Text(
              'Cannot resolve ${problem.alarmId} (${problem.timezone}): ${problem.reason}',
              key: ValueKey('unresolved-${problem.alarmId}'),
            ),
        if (next != null) ...[
          Text(
            'Projected next: ${next.alarm.label} (${next.alarm.id})',
            key: const ValueKey('projected-next'),
          ),
          Text(
            'Local: ${next.localDate} ${next.localTime} (${next.alarm.timezone}); UTC: ${next.scheduledUtc.toIso8601String()}',
          ),
          if (next.shiftedForGap)
            const Text('Spring gap: shifted to the first valid local time.'),
          if (next.ambiguousFold)
            const Text('Autumn fold: first occurrence selected.'),
        ],
        const Text(
          'Projection is not a guaranteed wake-up or a physical clock measurement.',
        ),
      ],
    );
  }
}
