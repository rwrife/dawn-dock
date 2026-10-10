/// Demo-scoped screen mounting [ScheduleFlowPanel] over seeded in-memory
/// schedule state (issue #67).
///
/// The committed mirror is a [DeviceScheduleStore] seeded with two alarms at
/// revision 3; the proposal is the same edited copy the schedule-review demo
/// uses, with one toggleable extra alarm so host tests can pin that review
/// recomputes from current inputs. Review runs the real domain diff and
/// preview framing runs the real `ScheduleExchange` gate, so the framed
/// `schedule.preview` envelope is contract-validated, byte-honest output.
///
/// Honest scope of what this is NOT:
///
/// * Framing is local presentation only. Nothing is sent: there is no
///   transport, no device, and this page never receives or synthesizes an
///   apply token, sync receipt, or error response. Because no token can
///   arrive, the explicit apply confirmation stays unreachable here by
///   design, and the local mirror never advances past revision 3.
/// * "Pending" after preview framing means an envelope was built and is
///   awaiting a caller-supplied token that this demo will never supply.
///   Canceling abandons only local demo state; it is not, and never claims
///   to be, a device rollback.
/// * The stores are fresh in-memory session state; nothing is shared with
///   other demo pages or persisted anywhere.
library;

import 'package:flutter/material.dart';

import '../domain/alarm_draft.dart';
import '../domain/schedule_flow_controller.dart';
import '../domain/schedule_store.dart';
import 'schedule_flow_panel.dart';
import 'schedule_review_demo_page.dart';

/// Demo-scoped schedule exchange flow page over seeded in-memory state.
class ScheduleFlowDemoPage extends StatefulWidget {
  const ScheduleFlowDemoPage({super.key});

  @override
  State<ScheduleFlowDemoPage> createState() => _ScheduleFlowDemoPageState();
}

class _ScheduleFlowDemoPageState extends State<ScheduleFlowDemoPage> {
  /// Fixed identity so framed envelopes stay deterministic in host tests.
  static final DateTime _sentAt = DateTime.utc(2026, 9, 6, 12);

  late final DeviceScheduleStore _store;
  late final ScheduleFlowController _controller;
  int _previewCount = 0;
  bool _includeExtra = true;
  Map<String, Object?>? _framed;

  @override
  void initState() {
    super.initState();
    _store = DeviceScheduleStore()
      ..replaceAll(revision: 3, alarms: kDemoBaselineAlarms);
    _controller = ScheduleFlowController(_store);
  }

  List<AlarmDraft> get _proposal => [
    ...kDemoProposalBase,
    if (_includeExtra) kDemoProposalExtra,
  ];

  bool get _proposalEditable =>
      _controller.state.phase == ScheduleFlowPhase.idle;

  void _review() => setState(() {
    _framed = null;
    _controller.review(_proposal);
  });

  void _preview() => setState(() {
    final envelope = _controller.requestPreview(
      messageId: 'demo-preview-${++_previewCount}',
      sentAt: _sentAt,
    );
    _framed = envelope;
  });

  void _cancel() => setState(() {
    _framed = null;
    _controller.cancel();
  });

  @override
  Widget build(BuildContext context) {
    final framed = _framed;
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule flow demo • In-memory')),
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
                    'Schedule flow demo • In-memory state',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'No real clock is connected. Review and preview framing '
                    'run the real domain gates locally; nothing is sent, and '
                    'this demo never receives an apply token or receipt.',
                    key: ValueKey('flow-demo-notice'),
                  ),
                  Text(
                    'Demo committed mirror revision: ${_store.knownRevision}. '
                    'Without a device-issued token and receipt this page '
                    'cannot reach apply confirmation, and the mirror never '
                    'advances.',
                    key: const ValueKey('flow-demo-revision'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const ValueKey('flow-demo-toggle'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: _proposalEditable
                        ? () => setState(() => _includeExtra = !_includeExtra)
                        : null,
                    child: Text(
                      _includeExtra
                          ? 'Drop weekend-hike from proposal'
                          : 'Add weekend-hike to proposal',
                    ),
                  ),
                  const SizedBox(height: 12),
                  ScheduleFlowPanel(
                    state: _controller.state,
                    onReview: _review,
                    onPreview: _preview,
                    onConfirmApply: () => setState(() {
                      // Unreachable in this demo: no token can arrive, so
                      // the controller never opens the confirm gate. Bound
                      // anyway so the panel keeps its real wiring.
                      _controller.confirmApply(
                        messageId: 'demo-apply-${++_previewCount}',
                        sentAt: _sentAt,
                      );
                    }),
                    onCancel: _cancel,
                    onCheckRefresh: () =>
                        setState(() => _controller.acknowledgeRefresh()),
                  ),
                  if (framed != null)
                    Text(
                      'Framed locally: ${framed['type']} at revision '
                      '${framed['expectedRevision']}, message ID '
                      '${framed['messageId']}. Not delivered — no transport '
                      'exists, and no token or receipt was received.',
                      key: const ValueKey('flow-demo-frame'),
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
