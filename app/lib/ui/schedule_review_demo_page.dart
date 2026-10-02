/// Demo-scoped screen mounting [ScheduleReviewPanel] over seeded in-memory
/// schedule state.
///
/// The baseline is a [DeviceScheduleStore] mirror seeded with two committed
/// alarms (revision 3); the proposal starts as one changed copy of an
/// existing alarm, one kept alarm, and one new alarm — so the panel opens
/// showing one changed, one added, and one removed line. Demo-local controls
/// add or drop the new proposal alarm so host tests can pin that the review
/// recomputes from current inputs. Confirming records the locally computed
/// diff on-screen only.
///
/// Honest scope of what this is NOT:
///
/// * Nothing is previewed or applied to a device: no transport, no
///   `schedule.preview`/`schedule.apply` envelope, no device-issued apply
///   token, no revision-conflict handling over a session. The baseline
///   mirror's revision never advances; "confirmed" here means the demo
///   displayed the confirmed counts, nothing more.
/// * The stores are fresh in-memory session state; edits made elsewhere in
///   the app are not shared here.
/// * No real calendar import, pairing, or secure storage is involved.
library;

import 'package:flutter/material.dart';

import '../domain/alarm_draft.dart';
import '../domain/schedule_diff.dart';
import '../domain/schedule_store.dart';
import 'schedule_review_panel.dart';

AlarmDraft _alarm({
  required String id,
  required String label,
  required int localHour,
  required int localMinute,
  Set<int> days = const {1, 2, 3, 4, 5},
}) => AlarmDraft(
  id: id,
  label: label,
  enabled: true,
  localHour: localHour,
  localMinute: localMinute,
  days: days,
  timezone: 'America/New_York',
  snoozeMinutes: 9,
  volume: 45,
  sound: 'gentle-1',
  source: DraftSource.manual,
);

/// Committed baseline shared by the demo (revision 3).
final List<AlarmDraft> kDemoBaselineAlarms = List.unmodifiable([
  _alarm(id: 'weekday-rise', label: 'Workday', localHour: 7, localMinute: 0),
  _alarm(id: 'saturday-chore', label: 'Chores', localHour: 9, localMinute: 0),
]);

/// Proposal content of the demo: `weekday-rise` moved to 7:30, a new
/// `weekend-hike` alarm, and `saturday-chore` intentionally absent (an
/// intentional removal).
final List<AlarmDraft> kDemoProposalBase = List.unmodifiable([
  _alarm(id: 'weekday-rise', label: 'Workday', localHour: 7, localMinute: 30),
]);

/// Extra proposal alarm toggled by the demo control.
final AlarmDraft kDemoProposalExtra = _alarm(
  id: 'weekend-hike',
  label: 'Hike',
  localHour: 8,
  localMinute: 0,
  days: const {6, 7},
);

/// Schedule-review demo page over seeded in-memory state.
class ScheduleReviewDemoPage extends StatefulWidget {
  const ScheduleReviewDemoPage({super.key});

  @override
  State<ScheduleReviewDemoPage> createState() => _ScheduleReviewDemoPageState();
}

class _ScheduleReviewDemoPageState extends State<ScheduleReviewDemoPage> {
  late final DeviceScheduleStore _schedule;
  bool _includeExtra = true;
  ScheduleDiff? _confirmedDiff;

  @override
  void initState() {
    super.initState();
    _schedule = DeviceScheduleStore();
    _schedule.replaceAll(revision: 3, alarms: kDemoBaselineAlarms);
  }

  List<AlarmDraft> get _proposal => [
    ...kDemoProposalBase,
    if (_includeExtra) kDemoProposalExtra,
  ];

  void _onConfirm(ScheduleDiff diff) {
    setState(() => _confirmedDiff = diff);
  }

  @override
  Widget build(BuildContext context) {
    final confirmed = _confirmedDiff;
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule review demo • In-memory')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Schedule review demo • In-memory state',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'The committed baseline and the proposal below are '
                    'in-memory demo state for this widget session only. '
                    'Nothing here connects to a real clock.',
                    key: ValueKey('no-hardware-notice'),
                  ),
                  const Text(
                    'Baseline mirror revision: 3. The proposal expects this '
                    'revision; a real device would refuse a stale proposal, '
                    'and that check needs a transport that does not exist '
                    'yet.',
                    key: ValueKey('revision-notice'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Demo proposal alarms: ${_proposal.length}.',
                    key: ValueKey('proposal-count'),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton(
                        key: const ValueKey('toggle-extra'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () =>
                            setState(() => _includeExtra = !_includeExtra),
                        child: Text(
                          _includeExtra
                              ? 'Drop weekend-hike from proposal'
                              : 'Add weekend-hike to proposal',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ScheduleReviewPanel(
                    baseline: _schedule.committedAlarms,
                    proposal: _proposal,
                    expectedRevision: _schedule.knownRevision,
                    onConfirm: _onConfirm,
                  ),
                  if (confirmed != null)
                    Text(
                      'Confirmed locally: ${confirmed.added.length} added, '
                      '${confirmed.removed.length} removed, '
                      '${confirmed.changed.length} changed. Not sent to any '
                      'device; the baseline mirror is unchanged at revision '
                      '${_schedule.knownRevision}.',
                      key: const ValueKey('confirmed-notice'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
