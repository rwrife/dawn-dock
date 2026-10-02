/// Accessible host-rendered review of a [ScheduleDiff].
///
/// Renders the deterministic diff produced by [diffSchedule] as explicit
/// text — a status header plus one line per changed (`~`, with its stable
/// field-change codes), added (`+`), and removed (`-`) alarm — and routes
/// the single confirm action through an injected callback so a screen can
/// never mutate a store or send anything by itself:
///
/// * The diff is recomputed from the current inputs on every build; the
///   panel holds no cached review state, so a proposal edited elsewhere is
///   always reflected before confirm.
/// * A proposal the wire contract would refuse (over capacity or duplicate
///   ids) is surfaced as an explicit refusal status and confirm is
///   disabled (`onPressed: null`); the panel never swallows the
///   `ArgumentError` silently and never invokes the confirm callback in
///   that state.
/// * An empty diff is labeled truthfully as "no changes" and confirm still
///   fires with the empty diff, so the caller decides what (if anything) a
///   no-op means.
/// * Status is conveyed in text only (never color alone) and marked as a
///   live-region semantic node so screen readers announce transitions.
/// * The panel adds no animations, so reduced-motion behavior holds by
///   construction, and every control carries an explicit 48-logical-pixel
///   minimum size independent of any app theme.
///
/// Detail lines mirror the exact wording of [ScheduleDiff.summaryText] so a
/// test can pin domain and rendering to one contract.
///
/// This is a presentation shell only: it performs no I/O, sends no
/// preview/apply envelope, validates no device token, and claims no device
/// receipt. The confirm callback receives the locally computed diff; what
/// happens next (envelope framing, transport, refusal handling) belongs to
/// the future transport slice.
library;

import 'package:flutter/material.dart';

import '../domain/alarm_draft.dart';
import '../domain/schedule_diff.dart';

/// Schedule review panel over a caller-supplied baseline/proposal pair.
class ScheduleReviewPanel extends StatelessWidget {
  const ScheduleReviewPanel({
    super.key,
    required this.baseline,
    required this.proposal,
    required this.expectedRevision,
    required this.onConfirm,
  });

  /// What the app currently believes is committed (e.g.
  /// `DeviceScheduleStore.committedAlarms`). The panel does not validate it
  /// — refusals are for proposals, matching [diffSchedule]'s contract.
  final Iterable<AlarmDraft> baseline;

  /// The complete intended replacement set under review.
  final Iterable<AlarmDraft> proposal;

  /// Revision the proposal expects the device to be at; rendered verbatim
  /// in the status header and validated against the device only once a
  /// transport exists.
  final int expectedRevision;

  /// Invoked with the locally computed diff when the user confirms. Never
  /// invoked while the panel reports a refusal.
  final void Function(ScheduleDiff diff) onConfirm;

  String _statusMessage(ScheduleDiff? diff, String? refusalMessage) {
    if (refusalMessage != null) {
      return 'Review status: proposal refused: $refusalMessage. '
          'Confirm is disabled; nothing will be previewed or applied.';
    }
    final d = diff!;
    if (d.isEmpty) {
      return 'Review status: no changes; the proposal matches the '
          'committed schedule (expected revision $expectedRevision).';
    }
    return 'Review status: ${d.added.length} added, ${d.removed.length} '
        'removed, ${d.changed.length} changed, ${d.unchanged.length} '
        'unchanged (expected revision $expectedRevision).';
  }

  ButtonStyle get _actionStyle =>
      FilledButton.styleFrom(minimumSize: const Size(48, 48));

  @override
  Widget build(BuildContext context) {
    ScheduleDiff? computed;
    String? refusalMessage;
    try {
      computed = diffSchedule(
        baseline: baseline,
        proposal: proposal,
        expectedRevision: expectedRevision,
      );
    } on ArgumentError catch (error) {
      refusalMessage = error.message?.toString() ?? 'proposal is invalid';
    }
    final diff = computed;
    final status = _statusMessage(diff, refusalMessage);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Schedule review',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            label: status,
            excludeSemantics: true,
            child: Text(status, key: const ValueKey('schedule-review-status')),
          ),
          const Text(
            'This review is recomputed locally from in-app state only. '
            'Confirming records your decision locally; nothing here sends a '
            'preview to a clock.',
            key: ValueKey('local-only-notice'),
          ),
          const SizedBox(height: 16),
          if (diff != null && !diff.isEmpty) ...[
            for (final c in diff.changed)
              Text(
                '~ ${c.id}: ${c.fieldCodes.join(', ')}',
                key: ValueKey('changed-${c.id}'),
              ),
            for (final a in diff.added)
              Text(
                '+ ${a.id}: ${a.label} ${a.localTime}',
                key: ValueKey('added-${a.id}'),
              ),
            for (final a in diff.removed)
              Text(
                '- ${a.id}: ${a.label} ${a.localTime}',
                key: ValueKey('removed-${a.id}'),
              ),
            const SizedBox(height: 16),
          ],
          FilledButton(
            key: const ValueKey('confirm-review'),
            style: _actionStyle,
            onPressed: diff == null ? null : () => onConfirm(diff),
            child: const Text('Confirm review'),
          ),
        ],
      ),
    );
  }
}
