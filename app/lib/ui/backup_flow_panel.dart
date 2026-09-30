/// Accessible host-rendered panel over [BackupFlowController].
///
/// Renders every controller state as explicit text and routes the four
/// scoped backup actions (export, check, restore, erase) through the
/// controller so a screen can never bypass its guarantees:
///
/// * Every action button is disabled (`onPressed: null`) while the
///   controller reports [BackupFlowController.isBusy], so overlapping taps
///   cannot reach the coordinator.
/// * A refused stale restore is only ever resolved through the controller's
///   own `confirmStaleRestore()` / `cancelStaleConfirmation()` calls — the
///   panel never applies `allowStale` itself and mutates no store state.
/// * Status is conveyed in text only (never color alone) and marked as a
///   live-region semantic node so screen readers announce transitions.
/// * The panel adds no animations, so reduced-motion behavior holds by
///   construction, and every control carries an explicit 48-logical-pixel
///   minimum size independent of any app theme.
///
/// This is a presentation shell only: it performs no I/O, selects no
/// directory, requests no permission, and knows nothing about transports.
library;

import 'package:flutter/material.dart';

import '../domain/backup_flow_controller.dart';

/// Backup/restore status panel driven by an injected controller.
class BackupFlowPanel extends StatefulWidget {
  const BackupFlowPanel({super.key, required this.controller});

  final BackupFlowController controller;

  @override
  State<BackupFlowPanel> createState() => _BackupFlowPanelState();
}

class _BackupFlowPanelState extends State<BackupFlowPanel> {
  /// Starts [action] (which transitions the controller to busy
  /// synchronously), rebuilds so the busy state renders immediately, then
  /// rebuilds again once the operation settles into its terminal state.
  Future<void> _run(Future<bool> Function() action) async {
    final started = action();
    setState(() {});
    await started;
    if (mounted) {
      setState(() {});
    }
  }

  void _cancelStaleConfirmation() {
    widget.controller.cancelStaleConfirmation();
    setState(() {});
  }

  String _statusMessage(BackupFlowState state) {
    return switch (state) {
      BackupInitial() => 'Backup status: no action has run yet.',
      BackupBusy(:final operation) =>
        'Backup status: working, ${operation.name} in progress.',
      BackupAbsent(:final operation) =>
        'Backup status: no saved backup file exists (${operation.name}).',
      BackupSuccess(:final operation, :final summary) =>
        'Backup status: ${operation.name} completed. '
            'Revision ${summary.knownRevision}, exported '
            '${summary.exportedAtUtc.toIso8601String()}, '
            '${summary.profileCount} profile(s), ${summary.draftCount} '
            'draft(s), ${summary.committedAlarmCount} committed alarm(s).',
      BackupStaleConfirmationRequired(
        :final backupRevision,
        :final currentRevision,
      ) =>
        'Backup status: confirmation required. The saved backup is at '
            'revision $backupRevision but the current schedule is at '
            'revision $currentRevision. Nothing has been restored yet. '
            'Confirm only if you intend to restore the older schedule.',
      BackupFailure(:final operation, :final message) =>
        'Backup status: ${operation.name} failed. $message',
    };
  }

  ButtonStyle get _actionStyle =>
      FilledButton.styleFrom(minimumSize: const Size(48, 48));

  ButtonStyle get _secondaryActionStyle =>
      OutlinedButton.styleFrom(minimumSize: const Size(48, 48));

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final busy = widget.controller.isBusy;
    final status = _statusMessage(state);
    final stale = state is BackupStaleConfirmationRequired;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Backup and restore',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            label: status,
            excludeSemantics: true,
            child: Text(status, key: const ValueKey('backup-status')),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton(
                key: const ValueKey('export'),
                style: _actionStyle,
                onPressed: busy ? null : () => _run(widget.controller.export),
                child: const Text('Export backup'),
              ),
              OutlinedButton(
                key: const ValueKey('check'),
                style: _secondaryActionStyle,
                onPressed: busy ? null : () => _run(widget.controller.inspect),
                child: const Text('Check backup'),
              ),
              OutlinedButton(
                key: const ValueKey('restore'),
                style: _secondaryActionStyle,
                onPressed: busy ? null : () => _run(widget.controller.restore),
                child: const Text('Restore backup'),
              ),
              OutlinedButton(
                key: const ValueKey('erase'),
                style: _secondaryActionStyle,
                onPressed: busy ? null : () => _run(widget.controller.erase),
                child: const Text('Erase backup'),
              ),
            ],
          ),
          if (stale) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton(
                  key: const ValueKey('confirm-stale'),
                  style: _actionStyle,
                  onPressed: () => _run(widget.controller.confirmStaleRestore),
                  child: const Text('Confirm older restore'),
                ),
                OutlinedButton(
                  key: const ValueKey('cancel-stale'),
                  style: _secondaryActionStyle,
                  onPressed: _cancelStaleConfirmation,
                  child: const Text('Keep current schedule'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
