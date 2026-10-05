/// Fixed-anchor, in-memory fixture for the read-only status projection panel.
library;

import 'package:flutter/material.dart';

import '../domain/alarm_draft.dart';
import '../domain/device_status.dart';
import '../domain/recurrence.dart';
import '../domain/schedule_store.dart';
import 'device_status_panel.dart';

enum StatusDemoCase {
  projected,
  matchingReceipt,
  mismatchedReceipt,
  unresolved,
  empty,
}

class DeviceStatusDemoPage extends StatefulWidget {
  const DeviceStatusDemoPage({super.key});

  @override
  State<DeviceStatusDemoPage> createState() => _DeviceStatusDemoPageState();
}

class _DeviceStatusDemoPageState extends State<DeviceStatusDemoPage> {
  static final _anchor = DateTime.utc(2026, 1, 1);
  static final _next = DateTime.utc(2026, 1, 1, 7);
  StatusDemoCase _case = StatusDemoCase.projected;

  DeviceStatusProjection _projection() {
    final alarm = AlarmDraft(
      id: 'demo-wake',
      label: 'Demo wake',
      enabled: true,
      localHour: 7,
      localMinute: 0,
      days: const {1, 2, 3, 4, 5},
      timezone: _case == StatusDemoCase.unresolved
          ? 'Missing/Rules'
          : 'Etc/UTC',
      snoozeMinutes: 9,
      volume: 45,
      sound: 'gentle-1',
      source: DraftSource.manual,
    );
    final receipt = switch (_case) {
      StatusDemoCase.matchingReceipt ||
      StatusDemoCase.mismatchedReceipt => SyncReceipt(
        appliedRevision: 3,
        alarmCount: 1,
        nextAlarmUtc: _case == StatusDemoCase.matchingReceipt
            ? _next
            : DateTime.utc(2026, 1, 2, 8),
        receivedAtUtc: _anchor,
      ),
      _ => null,
    };
    final store = DeviceScheduleStore()
      ..replaceAll(
        revision: 3,
        alarms: _case == StatusDemoCase.empty ? [] : [alarm],
        receipt: receipt,
      );
    return projectDeviceStatus(
      store: store,
      afterUtcSeconds: _anchor.millisecondsSinceEpoch ~/ 1000,
      rulesProvider: (zone) => zone == 'Etc/UTC'
          ? const TimezoneRules(
              name: 'Etc/UTC',
              version: '2026a',
              initialUtcOffsetSeconds: 0,
              transitions: [],
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Local status demo')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'No real clock is connected. Fixed fixture anchor: ${_anchor.toIso8601String()}. '
                  'Receipts below are seeded in memory, not obtained from a device.',
                ),
                const SizedBox(height: 12),
                for (final scenario in StatusDemoCase.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton(
                      key: ValueKey('case-${scenario.name}'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () => setState(() => _case = scenario),
                      child: Text('Show ${scenario.name} fixture'),
                    ),
                  ),
                const SizedBox(height: 12),
                DeviceStatusPanel(projection: _projection()),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
