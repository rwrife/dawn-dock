import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/device_profile.dart';
import 'package:dawn_dock_companion/domain/protocol_contract.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';

AlarmDraft draft(
  String id, {
  String label = 'Workday',
  int hour = 7,
  int minute = 0,
  Set<int> days = const {1, 2, 3, 4, 5},
  String timezone = 'America/New_York',
  DraftSource source = DraftSource.manual,
  ImportProvenance? provenance,
}) => AlarmDraft(
  id: id,
  label: label,
  enabled: true,
  localHour: hour,
  localMinute: minute,
  days: days,
  timezone: timezone,
  snoozeMinutes: 9,
  volume: 45,
  sound: 'gentle-1',
  source: source,
  provenance: provenance,
);

void main() {
  group('device profiles', () {
    test('rejects empty and oversized identities at construction', () {
      expect(
        () => DeviceProfile(identity: '', displayName: 'X'),
        throwsArgumentError,
      );
      expect(
        () => DeviceProfile(
          identity: 'night-stand-clock-x',
          displayName: 'A' * 65,
        ),
        throwsArgumentError,
      );
    });

    test('store upserts by identity, is bounded, and removes precisely', () {
      final store = DeviceProfileStore();
      store.upsert(DeviceProfile(identity: 'a', displayName: 'A'));
      store.upsert(DeviceProfile(identity: 'b', displayName: 'B'));
      store.upsert(DeviceProfile(identity: 'a', displayName: 'A2'));
      expect(store.profiles.length, 2);
      expect(store.byIdentity('a')?.displayName, 'A2');
      expect(store.remove('b'), isTrue);
      expect(store.remove('b'), isFalse);
      expect(store.profiles.map((p) => p.identity), ['a']);
    });

    test('store refuses new identities at capacity but allows replacement', () {
      final store = DeviceProfileStore();
      for (var i = 0; i < kMaxProfiles; i++) {
        store.upsert(DeviceProfile(identity: 'd$i', displayName: 'D$i'));
      }
      expect(
        () => store.upsert(DeviceProfile(identity: 'extra', displayName: 'X')),
        throwsStateError,
      );
      expect(
        () =>
            store.upsert(DeviceProfile(identity: 'd0', displayName: 'Renamed')),
        returnsNormally,
      );
      expect(store.byIdentity('d0')?.displayName, 'Renamed');
    });
  });

  group('alarm drafts', () {
    test('bounds are enforced at construction', () {
      expect(() => draft('Bad Id'), throwsArgumentError);
      expect(() => draft('ok', label: ''), throwsArgumentError);
      expect(() => draft('ok', hour: 24), throwsArgumentError);
      expect(() => draft('ok', minute: 60), throwsArgumentError);
      expect(() => draft('ok', days: {}), throwsArgumentError);
      expect(() => draft('ok', days: {8}), throwsArgumentError);
      expect(() => draft('ok', timezone: 'ab'), throwsArgumentError);
    });

    test('ics drafts require provenance and manual drafts forbid it', () {
      const prov = ImportProvenance(
        sourceEventId: 'evt-42',
        originLabel: 'ics',
      );
      expect(
        () => AlarmDraft(
          id: 'imp',
          label: 'Standup',
          enabled: true,
          localHour: 9,
          localMinute: 15,
          days: const {1, 2, 3, 4, 5},
          timezone: 'Europe/Berlin',
          snoozeMinutes: 5,
          volume: 60,
          sound: 'chime',
          source: DraftSource.ics,
          provenance: prov,
        ),
        returnsNormally,
      );
      expect(
        () => AlarmDraft(
          id: 'imp',
          label: 'Standup',
          enabled: true,
          localHour: 9,
          localMinute: 15,
          days: const {1, 2, 3, 4, 5},
          timezone: 'Europe/Berlin',
          snoozeMinutes: 5,
          volume: 60,
          sound: 'chime',
          source: DraftSource.ics,
        ),
        throwsArgumentError,
      );
      expect(
        () => draft('man', source: DraftSource.manual, provenance: prov),
        throwsArgumentError,
      );
    });

    test('draft wire projection satisfies the contract gate', () {
      final payload = {
        'protocol': kProtocolVersion,
        'messageId': 'req-draft-1',
        'sentAt': '2026-09-16T07:00:00Z',
        'type': 'schedule.preview',
        'expectedRevision': 4,
        'body': {
          'alarms': [
            draft('wake').toWireAlarm(),
            draft(
              'standup',
              hour: 9,
              minute: 15,
              timezone: 'Europe/Berlin',
              source: DraftSource.ics,
              provenance: const ImportProvenance(
                sourceEventId: 'evt-9',
                originLabel: 'ics',
              ),
            ).toWireAlarm(),
          ],
        },
      };
      expect(validateContractMessage(payload), ContractCode.accepted);
    });

    test('map round-trip preserves all fields including provenance', () {
      const prov = ImportProvenance(sourceEventId: 'evt-1', originLabel: 'ics');
      final original = draft(
        'rt',
        hour: 6,
        minute: 45,
        days: const {2, 4, 6},
        source: DraftSource.ics,
        provenance: prov,
      );
      final restored = AlarmDraft.fromMap(
        original.toMap().cast<Object?, Object?>(),
      );
      expect(restored, original);
    });

    test('draft set is bounded and keyed by id', () {
      final set = DraftSet();
      set.put(draft('one'));
      set.put(draft('one', label: 'renamed'));
      expect(set.length, 1);
      expect(set.byId('one')?.label, 'renamed');
      for (var i = 2; i <= kMaxDrafts; i++) {
        set.put(draft('alarm-$i'));
      }
      expect(set.length, kMaxDrafts);
      expect(() => set.put(draft('overflow')), throwsStateError);
      expect(set.remove('one'), isTrue);
      expect(() => set.put(draft('now-fits')), returnsNormally);
    });
  });

  group('schedule store', () {
    test('starts empty', () {
      expect(DeviceScheduleStore().status, ScheduleStoreStatus.empty);
    });

    test('recordApplied requires strict forward revisions and keeps state untouched on rejection', () {
      final store = DeviceScheduleStore(
        clock: () => DateTime.utc(2026, 9, 16, 12),
      );
      store.recordApplied(
        revision: 5,
        appliedAlarms: [draft('wake')],
        nextAlarmUtc: DateTime.utc(2026, 9, 17, 11),
      );
      expect(store.knownRevision, 5);
      expect(store.committedAlarms.single.id, 'wake');
      expect(store.lastReceipt?.alarmCount, 1);
      expect(store.status, ScheduleStoreStatus.synced);

      expect(
        () => store.recordApplied(
          revision: 5,
          appliedAlarms: [draft('other')],
          nextAlarmUtc: DateTime.utc(2026, 9, 18, 11),
        ),
        throwsStateError,
      );
      expect(
        () => store.recordApplied(
          revision: 4,
          appliedAlarms: [draft('other')],
          nextAlarmUtc: DateTime.utc(2026, 9, 18, 11),
        ),
        throwsStateError,
      );
      expect(store.knownRevision, 5);
      expect(store.committedAlarms.single.id, 'wake');
    });

    test('proposal validation rejects capacity overflow and duplicates', () {
      final tooMany = List.generate(kMaxStoredAlarms + 1, (i) => draft('a$i'));
      expect(
        () => DeviceScheduleStore.validateProposal(tooMany),
        throwsArgumentError,
      );
      expect(
        () => DeviceScheduleStore.validateProposal([
          draft('same'),
          draft('same', label: 'other'),
        ]),
        throwsArgumentError,
      );
    });

    test('replaceAll rejects a receipt inconsistent with the payload', () {
      final store = DeviceScheduleStore();
      final alarms = [draft('wake')];
      final mismatched = SyncReceipt(
        appliedRevision: 9,
        alarmCount: alarms.length + 1,
        nextAlarmUtc: DateTime.utc(2026, 9, 17, 11),
        receivedAtUtc: DateTime.utc(2026, 9, 16, 12),
      );
      expect(
        () =>
            store.replaceAll(revision: 9, alarms: alarms, receipt: mismatched),
        throwsArgumentError,
      );
      expect(store.knownRevision, 0);
      expect(store.status, ScheduleStoreStatus.empty);
    });
  });
}
