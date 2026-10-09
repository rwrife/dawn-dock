import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/schedule_flow_controller.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';
import 'package:dawn_dock_companion/ui/schedule_flow_panel.dart';

final _now = DateTime.utc(2026, 9, 6, 12);

AlarmDraft _alarm([String id = 'wake-weekdays']) => AlarmDraft(
  id: id,
  label: 'Workday',
  enabled: true,
  localHour: 7,
  localMinute: 0,
  days: const {2, 3, 4, 5, 6},
  timezone: 'America/New_York',
  snoozeMinutes: 9,
  volume: 45,
  sound: 'gentle-1',
  source: DraftSource.manual,
);

Map<String, Object?> _fixture(String name) => jsonDecode(
  File('../docs/protocol/fixtures/v1/valid/$name').readAsStringSync(),
) as Map<String, Object?>;

Map<String, Object?> _receipt() => _fixture('event_sync_receipt.response.json');

Map<String, Object?> _conflict() =>
    _fixture('error_revision_conflict.response.json');

/// Host harness owning a real controller the way a screen would: UI actions
/// go through controller gates inside setState; inbound token/receipt calls
/// simulate the transport owner feeding the same controller.
class _Harness extends StatefulWidget {
  const _Harness({required this.controller, required this.proposalBuilder});

  final ScheduleFlowController controller;
  final List<AlarmDraft> Function() proposalBuilder;

  @override
  State<_Harness> createState() => HarnessState();
}

class HarnessState extends State<_Harness> {
  int _request = 1;

  void receiveToken(String token) =>
      setState(() => widget.controller.receiveToken(token));

  void receive(Map<String, Object?> payload) =>
      setState(() => widget.controller.receive(payload));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ScheduleFlowPanel(
        state: widget.controller.state,
        onReview: () =>
            setState(() => widget.controller.review(widget.proposalBuilder())),
        onPreview: () => setState(
          () => widget.controller.requestPreview(
            messageId: 'req-ui-${++_request}',
            sentAt: _now,
          ),
        ),
        onConfirmApply: () => setState(
          () => widget.controller.confirmApply(
            messageId: 'req-ui-${++_request}',
            sentAt: _now,
          ),
        ),
        onCancel: () => setState(() => widget.controller.cancel()),
        onCheckRefresh: () =>
            setState(() => widget.controller.acknowledgeRefresh()),
      ),
    );
  }
}

Finder _button(String key) => find.byKey(ValueKey(key));

bool _enabled(WidgetTester tester, String key) {
  final widget = tester.widget<OutlinedButton>(_button(key));
  return widget.onPressed != null;
}

String _status(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('exchange-status'))).data ??
    '';

Future<void> _mount(
  WidgetTester tester,
  ScheduleFlowController controller,
  List<AlarmDraft> Function() proposalBuilder,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: _Harness(controller: controller, proposalBuilder: proposalBuilder),
    ),
  );
}

HarnessState _harnessState(WidgetTester tester) =>
    tester.state<HarnessState>(find.byType(_Harness));

void main() {
  late DeviceScheduleStore store;
  late ScheduleFlowController controller;

  setUp(() {
    store = DeviceScheduleStore(clock: () => _now)
      ..replaceAll(revision: 12, alarms: const []);
    controller = ScheduleFlowController(store);
  });

  Future<void> toReview(WidgetTester tester) async {
    await _mount(tester, controller, () => [_alarm()]);
    await tester.tap(_button('exchange-review'));
    await tester.pump();
  }

  Future<void> toPendingApply(WidgetTester tester) async {
    await toReview(tester);
    await tester.tap(_button('exchange-preview'));
    await tester.pump();
    _harnessState(tester).receiveToken('preview-7f93d1');
    await tester.pump();
    await tester.tap(_button('exchange-apply'));
    await tester.pump();
  }

  testWidgets('idle shows honest framing notice and gated actions', (
    tester,
  ) async {
    await _mount(tester, controller, () => [_alarm()]);
    expect(_status(tester), startsWith('No proposal reviewed.'));
    expect(_enabled(tester, 'exchange-review'), isTrue);
    expect(_enabled(tester, 'exchange-preview'), isFalse);
    expect(_enabled(tester, 'exchange-apply'), isFalse);
    expect(_enabled(tester, 'exchange-cancel'), isFalse);
    expect(_enabled(tester, 'exchange-refresh'), isFalse);
    expect(
      find.text(
        'Local presentation only. Framed requests are not delivery evidence. '
        'Supplied receipts are not authenticated by this panel. '
        'No alarm is executed here.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Reason:'), findsNothing);
  });

  testWidgets('review enables preview and cancel but not apply', (
    tester,
  ) async {
    await toReview(tester);
    expect(_status(tester), contains('Review ready. No request sent.'));
    expect(find.text(controller.state.diff!.summaryText()), findsOneWidget);
    expect(_enabled(tester, 'exchange-preview'), isTrue);
    expect(_enabled(tester, 'exchange-apply'), isFalse);
    expect(_enabled(tester, 'exchange-cancel'), isTrue);
    expect(store.knownRevision, 12);
    expect(store.lastReceipt, isNull);
  });

  testWidgets('status is a live-region semantic node mirroring the text', (
    tester,
  ) async {
    await toReview(tester);
    final semantics = tester.widget<Semantics>(
      find.ancestor(
        of: find.byKey(const ValueKey('exchange-status')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
      ),
    );
    expect(semantics.properties.liveRegion, isTrue);
    expect(semantics.properties.label, _status(tester));
  });

  testWidgets('framed preview moves to pending without adopting anything', (
    tester,
  ) async {
    await toReview(tester);
    await tester.tap(_button('exchange-preview'));
    await tester.pump();
    expect(
      _status(tester),
      contains('Preview framed. Awaiting caller-supplied token.'),
    );
    expect(_enabled(tester, 'exchange-preview'), isFalse);
    expect(_enabled(tester, 'exchange-apply'), isFalse);
    expect(store.knownRevision, 12);
    expect(store.committedAlarms, isEmpty);
  });

  testWidgets('explicit confirmation gates the only apply framing', (
    tester,
  ) async {
    await toReview(tester);
    await tester.tap(_button('exchange-preview'));
    await tester.pump();
    _harnessState(tester).receiveToken('preview-7f93d1');
    await tester.pump();
    expect(_status(tester), contains('Explicit apply confirmation required.'));
    expect(_enabled(tester, 'exchange-apply'), isTrue);
    await tester.tap(_button('exchange-apply'));
    await tester.pump();
    expect(_status(tester), contains('outcome unknown'));
    expect(store.knownRevision, 12);
  });

  testWidgets('pending apply cannot be canceled or re-confirmed', (
    tester,
  ) async {
    await toPendingApply(tester);
    expect(_enabled(tester, 'exchange-cancel'), isFalse);
    expect(_enabled(tester, 'exchange-apply'), isFalse);
    expect(_enabled(tester, 'exchange-review'), isFalse);
    expect(
      find.textContaining('Apply cannot be canceled as a device rollback.'),
      findsOneWidget,
    );
    expect(store.knownRevision, 12);
    expect(store.lastReceipt, isNull);
  });

  testWidgets('consistent supplied receipt lands as local adoption only', (
    tester,
  ) async {
    await toPendingApply(tester);
    _harnessState(tester).receive(_receipt());
    await tester.pump();
    expect(_status(tester), contains('Consistent supplied receipt adopted'));
    expect(store.knownRevision, 13);
    expect(_enabled(tester, 'exchange-review'), isTrue);
    expect(_enabled(tester, 'exchange-apply'), isFalse);
  });

  testWidgets('duplicate proposal is refused with reason and no preview', (
    tester,
  ) async {
    await _mount(tester, controller, () => [_alarm(), _alarm()]);
    await tester.tap(_button('exchange-review'));
    await tester.pump();
    expect(_status(tester), contains('Proposal refused.'));
    expect(_status(tester), contains('Reason: invalid_proposal.'));
    expect(_enabled(tester, 'exchange-preview'), isFalse);
    expect(_enabled(tester, 'exchange-review'), isTrue);
    expect(store.knownRevision, 12);
  });

  testWidgets('revision conflict gates refresh on the reported revision', (
    tester,
  ) async {
    await toPendingApply(tester);
    _harnessState(tester).receive(_conflict());
    await tester.pump();
    expect(_status(tester), contains('Revision conflict.'));
    expect(_status(tester), contains('Required mirror revision: 13.'));
    expect(_enabled(tester, 'exchange-review'), isFalse);
    expect(_enabled(tester, 'exchange-apply'), isFalse);
    expect(
      find.textContaining('The owner must refresh the mirror independently'),
      findsOneWidget,
    );
    // Mirror not yet refreshed: acknowledging must be refused and visible.
    await tester.tap(_button('exchange-refresh'));
    await tester.pump();
    expect(controller.state.phase, ScheduleFlowPhase.needsRefresh);
    expect(_status(tester), contains('Required mirror revision: 13.'));
    // Independent refresh to a DIFFERENT revision is also refused.
    store.replaceAll(revision: 14, alarms: [_alarm('other')]);
    await tester.tap(_button('exchange-refresh'));
    await tester.pump();
    expect(controller.state.phase, ScheduleFlowPhase.needsRefresh);
    // Matching revision releases the gate into idle; old proposal is gone.
    store.replaceAll(revision: 13, alarms: [_alarm('other')]);
    await tester.tap(_button('exchange-refresh'));
    await tester.pump();
    expect(_status(tester), startsWith('No proposal reviewed.'));
    expect(_enabled(tester, 'exchange-review'), isTrue);
    expect(_enabled(tester, 'exchange-preview'), isFalse);
  });

  testWidgets('conflict without a reported revision keeps refresh disabled', (
    tester,
  ) async {
    await toPendingApply(tester);
    final error = _conflict();
    (error['body']! as Map).remove('currentRevision');
    _harnessState(tester).receive(error);
    await tester.pump();
    expect(_status(tester), contains('No conflict revision supplied'));
    expect(_enabled(tester, 'exchange-refresh'), isFalse);
    store.replaceAll(revision: 13, alarms: const []);
    expect(controller.state.phase, ScheduleFlowPhase.needsRefresh);
  });

  testWidgets('cancel returns to idle and clears the stale status', (
    tester,
  ) async {
    await toReview(tester);
    await tester.tap(_button('exchange-cancel'));
    await tester.pump();
    expect(_status(tester), startsWith('No proposal reviewed.'));
    expect(_enabled(tester, 'exchange-preview'), isFalse);
    expect(_enabled(tester, 'exchange-review'), isTrue);
  });

  testWidgets('stays usable at 320px width and 200% text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    tester.view.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.platformDispatcher.clearTextScaleFactorTestValue);
    await _mount(tester, controller, () => [_alarm()]);
    for (final key in [
      'exchange-review',
      'exchange-preview',
      'exchange-apply',
      'exchange-cancel',
      'exchange-refresh',
    ]) {
      await tester.ensureVisible(_button(key));
      expect(tester.takeException(), isNull);
    }
    expect(tester.takeException(), isNull);
  });
}
