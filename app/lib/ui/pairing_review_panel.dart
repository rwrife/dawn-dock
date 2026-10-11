import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/pairing.dart';

/// Unmounted local comparison UI, not a handshake or credential-storage flow.
/// The owner must supply the same clock used by the ceremony. Device/session
/// enforcement of attempts and monotonic timing remains outside this panel.
class PairingReviewPanel extends StatefulWidget {
  const PairingReviewPanel({
    super.key,
    required this.ceremony,
    required this.clock,
  });

  final PairingCeremony ceremony;
  final DateTime Function() clock;

  @override
  State<PairingReviewPanel> createState() => _PairingReviewPanelState();
}

class _PairingReviewPanelState extends State<PairingReviewPanel> {
  final _code = TextEditingController();
  final _fingerprint = TextEditingController();
  late final Timer _timer;
  String? _mismatch;

  @override
  void initState() {
    super.initState();
    widget.ceremony.checkExpiry();
    // ponytail: one-second UI polling; authoritative deadlines belong to the device.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      widget.ceremony.checkExpiry();
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant PairingReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ceremony != widget.ceremony) {
      _code.clear();
      _fingerprint.clear();
      _mismatch = null;
      widget.ceremony.checkExpiry();
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    _code.dispose();
    _fingerprint.dispose();
    super.dispose();
  }

  bool get _started =>
      !widget.clock().toUtc().isBefore(widget.ceremony.windowStart);

  void _confirm() {
    final ceremony = widget.ceremony;
    ceremony.checkExpiry();
    if (!_started || ceremony.isClosed) {
      setState(() {});
      return;
    }
    try {
      final result = ceremony.attemptConfirmation(
        shortCode: _code.text,
        fingerprint: _fingerprint.text,
      );
      setState(() {
        _mismatch = result.accepted
            ? null
            : 'Code or fingerprint mismatch. ${result.remainingAttempts} attempts remaining.';
      });
    } on StateError {
      // The clock can reach the deadline between checkExpiry and the attempt.
      // Only the domain's observed timeout is a normal UI transition.
      if (ceremony.closureReason != PairingClosureReason.timedOut) rethrow;
      setState(() {});
    }
  }

  void _cancel() {
    setState(() => widget.ceremony.cancel());
  }

  String get _status {
    final ceremony = widget.ceremony;
    return switch (ceremony.closureReason) {
      PairingClosureReason.confirmed => 'Local comparison accepted. No device handshake or credential storage completed.',
      PairingClosureReason.timedOut =>
        'Pairing window elapsed. Ceremony closed.',
      PairingClosureReason.attemptsExhausted =>
        'Five failed confirmations. Ceremony closed.',
      PairingClosureReason.cancelled => 'Review cancelled locally.',
      null =>
        !_started
            ? 'Reported pairing window has not opened. Confirmation disabled.'
            : _mismatch ??
                  'Reported pairing window open. ${ceremony.remainingAttempts} attempts remaining.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final ceremony = widget.ceremony;
    final canConfirm = _started && !ceremony.isClosed;
    final status = _status;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pairing review',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Semantics(
              liveRegion: true,
              label: status,
              excludeSemantics: true,
              child: Text(status, key: const ValueKey('pairing-status')),
            ),
            Text('Candidate: ${ceremony.candidate.displayName}'),
            const Text(
              'Local comparison only. No discovery, transport, key exchange, paired record, or secure storage. '
              'Attempts are per ceremony object and timing follows a caller-supplied clock; '
              'a new object resets attempts and clock rollback can extend the window. '
              'Authoritative device/session enforcement remains open.',
            ),
            TextField(
              key: const ValueKey('pairing-code'),
              controller: _code,
              enabled: canConfirm,
              maxLength: kMaxShortCodeBytes,
              decoration: const InputDecoration(
                labelText: 'Short code displayed on clock',
              ),
            ),
            TextField(
              key: const ValueKey('pairing-fingerprint'),
              controller: _fingerprint,
              enabled: canConfirm,
              maxLength: kMaxFingerprintBytes,
              decoration: const InputDecoration(
                labelText: 'Fingerprint displayed on clock',
              ),
            ),
            OutlinedButton(
              key: const ValueKey('pairing-confirm'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: canConfirm ? _confirm : null,
              child: const Text('Confirm local code and fingerprint'),
            ),
            OutlinedButton(
              key: const ValueKey('pairing-cancel'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: ceremony.isClosed ? null : _cancel,
              child: const Text('Cancel review'),
            ),
          ],
        ),
      ),
    );
  }
}
