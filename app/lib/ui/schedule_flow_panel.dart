import 'package:flutter/material.dart';

import '../domain/schedule_flow_controller.dart';

/// Renders a controller snapshot. The owner rebuilds after every transition
/// (including inbound responses) and binds callbacks to the controller gates.
/// No token, receipt, transport, or mirror refresh is generated here.
class ScheduleFlowPanel extends StatelessWidget {
  const ScheduleFlowPanel({
    super.key,
    required this.state,
    required this.onReview,
    required this.onPreview,
    required this.onConfirmApply,
    required this.onCancel,
    required this.onCheckRefresh,
  });

  final ScheduleFlowState state;
  final VoidCallback onReview;
  final VoidCallback onPreview;
  final VoidCallback onConfirmApply;
  final VoidCallback onCancel;
  final VoidCallback onCheckRefresh;

  @override
  Widget build(BuildContext context) {
    final canReview = const {
      ScheduleFlowPhase.idle,
      ScheduleFlowPhase.review,
      ScheduleFlowPhase.refused,
      ScheduleFlowPhase.applied,
    }.contains(state.phase);
    final status = [
      state.statusText,
      if (state.code != null) 'Reason: ${state.code}.',
      if (state.phase == ScheduleFlowPhase.needsRefresh)
        state.conflictRevision == null
            ? 'No conflict revision supplied; reconciliation remains unresolved.'
            : 'Required mirror revision: ${state.conflictRevision}.',
    ].join(' ');
    Widget action(String key, String label, VoidCallback? callback) =>
        OutlinedButton(
          key: ValueKey(key),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: callback,
          child: Text(label),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Schedule exchange',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Semantics(
              liveRegion: true,
              label: status,
              excludeSemantics: true,
              child: Text(status, key: const ValueKey('exchange-status')),
            ),
            const Text(
              'Local presentation only. Framed requests are not delivery evidence. '
              'Supplied receipts are not authenticated by this panel. '
              'No alarm is executed here.',
            ),
            if (state.diff case final diff?) Text(diff.summaryText()),
            action(
              'exchange-review',
              'Review proposal',
              canReview ? onReview : null,
            ),
            action(
              'exchange-preview',
              'Frame preview request',
              state.canPreview ? onPreview : null,
            ),
            action(
              'exchange-apply',
              'Confirm and frame apply request',
              state.canConfirm ? onConfirmApply : null,
            ),
            action(
              'exchange-cancel',
              'Cancel local review',
              state.canCancel ? onCancel : null,
            ),
            action(
              'exchange-refresh',
              'Check independently refreshed mirror',
              state.phase == ScheduleFlowPhase.needsRefresh &&
                      state.conflictRevision != null
                  ? onCheckRefresh
                  : null,
            ),
            if (state.phase == ScheduleFlowPhase.applyPending)
              const Text(
                'Apply cannot be canceled as a device rollback. Do not retry while the outcome is unknown.',
              ),
            if (state.phase == ScheduleFlowPhase.needsRefresh)
              const Text(
                'This check does not fetch a schedule. The owner must refresh the mirror independently; a matching revision then requires a new review.',
              ),
          ],
        ),
      ),
    );
  }
}
