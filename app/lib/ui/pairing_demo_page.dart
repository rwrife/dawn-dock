/// Demo-scoped screen mounting [PairingReviewPanel] over a simulated,
/// in-memory pairing ceremony (issue #71).
///
/// Pairing is closed by default here exactly as the domain requires: no
/// `PairingCeremony` object exists until the user explicitly starts a
/// clearly labeled *simulated* device window. Starting a window creates a
/// fresh ceremony with fixed illustrative code/fingerprint — a stand-in for
/// what a real clock screen would display — and a caller-owned demo clock,
/// so host tests can move time deterministically.
///
/// Honest scope of what this is NOT:
///
/// * No discovery, transport, Bluetooth, LAN, handshake, or key exchange.
///   The "displayed" code and fingerprint are constants on this page; the
///   app receives nothing from anywhere.
/// * A successful local comparison here never calls
///   `PairingCeremony.completeWithReference`, so no `PairedDeviceRecord`,
///   credential, or secure-storage reference is ever created or stored.
/// * Reset, closure, and the advance-clock control affect only local demo
///   objects. They do not and cannot close a device-side window; a real
///   device would enforce its own monotonic deadline and attempt count
///   (verification matrix CONN-02, still open).
/// * State is per-page-session in memory; leaving the route discards it and
///   remounting starts from the closed-by-default state.
library;

import 'package:flutter/material.dart';

import '../domain/pairing.dart';
import 'pairing_review_panel.dart';

/// Fixed illustrative values standing in for a clock's displayed pairing
/// short code and fingerprint. Constants on this page — never received.
const String kDemoPairingShortCode = '123456';
const String kDemoPairingFingerprint = 'dawn-demo-fp-aa11-bb22';

class PairingDemoPage extends StatefulWidget {
  const PairingDemoPage({super.key});

  @override
  State<PairingDemoPage> createState() => _PairingDemoPageState();
}

class _PairingDemoPageState extends State<PairingDemoPage> {
  static final PairingCandidate _candidate = PairingCandidate(
    identity: 'demo:local-only-clock',
    displayName: 'Demo bedside clock',
    source: CandidateSource.manual,
  );

  /// Caller-owned demo clock. Only the advance control moves it, so expiry
  /// is deterministic in host tests instead of wall-clock dependent.
  DateTime _now = DateTime.utc(2026, 10, 13, 7);

  /// Null until the user explicitly starts a simulated window — the UI
  /// mirror of "pairing is closed by default".
  PairingCeremony? _ceremony;

  DateTime _clock() => _now;

  void _startSimulatedWindow() {
    if (_ceremony != null) return;
    setState(() {
      _ceremony = PairingCeremony(
        candidate: _candidate,
        expectedShortCode: kDemoPairingShortCode,
        expectedFingerprint: kDemoPairingFingerprint,
        windowStart: _now,
        clock: _clock,
      );
    });
  }

  void _resetSimulatedWindow() {
    setState(() => _ceremony = null);
  }

  void _advanceDemoClock() {
    final ceremony = _ceremony;
    if (ceremony == null) {
      return;
    }
    setState(() {
      _now = _now.add(const Duration(seconds: kMaxPairingWindowSeconds + 1));
      // Observe the timeout transition now instead of waiting for the
      // panel's next polling tick; a real device would enforce this itself.
      ceremony.checkExpiry();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ceremony = _ceremony;
    return Scaffold(
      appBar: AppBar(title: const Text('Pairing demo • Simulated only')),
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
                    'Pairing demo • Simulated ceremony',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'No real clock is connected. Nothing is discovered, '
                    'sent, or stored. The short code and fingerprint below '
                    'stand in for a clock screen; they are fixed values on '
                    'this page. A closed or reset ceremony here is local '
                    'only — it cannot close a device-side window, and a '
                    'successful comparison creates no paired record or '
                    'credential.',
                    key: ValueKey('pairing-demo-notice'),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('pairing-demo-start'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: ceremony == null
                            ? _startSimulatedWindow
                            : null,
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('Start simulated pairing window'),
                      ),

                      OutlinedButton(
                        key: const ValueKey('pairing-demo-reset'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: ceremony == null
                            ? null
                            : _resetSimulatedWindow,
                        child: const Text('Discard local ceremony'),
                      ),
                      OutlinedButton(
                        key: const ValueKey('pairing-demo-advance'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: ceremony == null ? null : _advanceDemoClock,
                        child: const Text('Advance demo clock past deadline'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (ceremony == null)
                    Semantics(
                      container: true,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                'Pairing closed by default',
                                key: ValueKey('pairing-demo-idle'),
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'No ceremony object exists. A real device '
                                'opens its own bounded window; this demo '
                                'simulates that report locally.',
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  else ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Simulated clock screen (illustrative only)',
                              key: ValueKey('pairing-demo-screen'),
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text('Short code: $kDemoPairingShortCode'),
                            Text('Fingerprint: $kDemoPairingFingerprint'),
                            Text(
                              'Simulated window started '
                              '${ceremony.windowStart.toIso8601String()} '
                              '(demo clock).',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    PairingReviewPanel(ceremony: ceremony, clock: _clock),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
