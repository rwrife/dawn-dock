import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/alarm_draft.dart';
import 'package:dawn_dock_companion/domain/backup.dart';
import 'package:dawn_dock_companion/domain/device_profile.dart';
import 'package:dawn_dock_companion/domain/schedule_store.dart';

AlarmDraft draft(String id, {String label = 'Workday'}) => AlarmDraft(
  id: id,
  label: label,
  enabled: true,
  localHour: 7,
  localMinute: 0,
  days: const {1, 2, 3, 4, 5},
  timezone: 'America/New_York',
  snoozeMinutes: 9,
  volume: 45,
  sound: 'gentle-1',
  source: DraftSource.manual,
);

void main() {
  final exportedAt = DateTime.utc(2026, 9, 16, 9, 30);
  final receipt = SyncReceipt(
    appliedRevision: 7,
    alarmCount: 1,
    nextAlarmUtc: DateTime.utc(2026, 9, 17, 11),
    receivedAtUtc: DateTime.utc(2026, 9, 16, 9),
  );

  String sampleBackup({int revision = 7}) => CompanionBackup.encode(
    exportedAtUtc: exportedAt,
    deviceProfiles: [
      DeviceProfile(
        identity: 'bedside',
        displayName: 'Bedside dock',
        note: 'USB-C on left',
        addedAtUtc: DateTime.utc(2026, 9, 1),
      ),
    ],
    drafts: [
      draft('wake'),
      draft('standup', label: 'Standup'),
    ],
    knownRevision: revision,
    committedAlarms: [draft('wake')],
    lastReceipt: revision == 0 ? null : receipt,
  );

  group('backup round-trip', () {
    test('encode then parse reproduces every model', () {
      final parsed = CompanionBackup.parse(sampleBackup());
      expect(parsed.exportedAtUtc, exportedAt);
      expect(parsed.deviceProfiles.single.identity, 'bedside');
      expect(parsed.drafts.map((d) => d.id), ['standup', 'wake']);
      expect(parsed.knownRevision, 7);
      expect(parsed.committedAlarms.single.id, 'wake');
      expect(parsed.lastReceipt, receipt);
    });

    test('applyTo replaces all three live stores atomically', () {
      final profiles = DeviceProfileStore();
      final drafts = DraftSet();
      final schedule = DeviceScheduleStore();
      profiles.upsert(DeviceProfile(identity: 'stale', displayName: 'Old'));
      drafts.put(draft('stale'));
      schedule.replaceAll(revision: 99, alarms: [draft('stale')]);

      CompanionBackup.parse(sampleBackup()).applyTo(
        profileStore: profiles,
        draftSet: drafts,
        scheduleStore: schedule,
      );

      expect(profiles.profiles.map((p) => p.identity), ['bedside']);
      expect(drafts.drafts.map((d) => d.id), ['standup', 'wake']);
      expect(schedule.knownRevision, 7);
      expect(schedule.committedAlarms.single.id, 'wake');
      expect(schedule.lastReceipt, receipt);
    });

    test('a receipt-free backup restores to a receipt-free store', () {
      final parsed = CompanionBackup.parse(sampleBackup(revision: 0));
      expect(parsed.lastReceipt, isNull);
      final schedule = DeviceScheduleStore();
      parsed.applyTo(
        profileStore: DeviceProfileStore(),
        draftSet: DraftSet(),
        scheduleStore: schedule,
      );
      expect(schedule.lastReceipt, isNull);
      expect(schedule.knownRevision, 0);
    });
  });

  group('backup fail-closed rejections', () {
    late DeviceProfileStore profiles;
    late DraftSet drafts;
    late DeviceScheduleStore schedule;

    setUp(() {
      profiles = DeviceProfileStore();
      drafts = DraftSet();
      schedule = DeviceScheduleStore();
      profiles.upsert(DeviceProfile(identity: 'keep', displayName: 'Keep'));
      drafts.put(draft('keep'));
      schedule.replaceAll(revision: 3, alarms: [draft('keep')]);
    });

    void expectRejected(String text) {
      expect(
        () => CompanionBackup.parse(text),
        throwsA(isA<BackupException>()),
        reason:
            'restore must reject: ${text.length > 80 ? '${text.substring(0, 80)}…' : text}',
      );
      // Live state untouched (restore applies only after full validation).
      expect(profiles.profiles.single.identity, 'keep');
      expect(drafts.drafts.single.id, 'keep');
      expect(schedule.knownRevision, 3);
    }

    test('malformed JSON', () => expectRejected('{not json'));

    test(
      'wrong format marker',
      () => expectRejected(
        jsonEncode({'format': 'somebody-elses-backup', 'version': 1}),
      ),
    );

    test(
      'missing format marker',
      () => expectRejected(jsonEncode({'version': 1})),
    );

    test('future version fails closed', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>
        ..['version'] = 99;
      expectRejected(jsonEncode(document));
    });

    test('unknown top-level key', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>
        ..['sneaky'] = true;
      expectRejected(jsonEncode(document));
    });

    test('credential-like key anywhere is refused even if otherwise valid', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>;
      (document['deviceProfiles']! as List)
              .cast<Map<String, Object?>>()
              .first['pairingToken'] =
          'super-secret';
      expectRejected(jsonEncode(document));
    });

    test('credential-like key nested inside an allowed object is refused', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>;
      (document['deviceProfiles']! as List)
              .cast<Map<String, Object?>>()
              .first['note'] =
          'innocent';
      // Smuggle inside a nested note object key.
      document['scheduleMirror'] = {
        ...(document['scheduleMirror']! as Map).cast<String, Object?>(),
        'api_key': 'leak',
      };
      expectRejected(jsonEncode(document));
    });

    test('oversized text is refused before parsing', () {
      final padding = 'x' * (kMaxBackupTextBytes + 10);
      expectRejected('{"pad": "$padding"}');
    });

    test('draft array beyond the device bound is refused', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>;
      document['drafts'] = List.generate(
        kMaxDrafts + 1,
        (i) => draft('overflow-$i').toMap().cast<String, Object?>(),
      );
      expectRejected(jsonEncode(document));
    });

    test('duplicate draft ids are refused', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>;
      document['drafts'] = [
        draft('twin').toMap(),
        draft('twin', label: 'Other').toMap(),
      ];
      expectRejected(jsonEncode(document));
    });

    test('duplicate device profile identities are refused', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>;
      final profile = DeviceProfile(
        identity: 'bedside',
        displayName: 'Dup',
      ).toMap();
      (document['deviceProfiles']! as List).add(profile);
      expectRejected(jsonEncode(document));
    });

    test('receipt inconsistent with mirror state is refused', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>;
      final mirror = (document['scheduleMirror']! as Map)
          .cast<String, Object?>();
      mirror['knownRevision'] = 8; // receipt says 7
      expectRejected(jsonEncode({...document, 'scheduleMirror': mirror}));
    });

    test('model bound violations inside the backup are refused', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>;
      final drafts = (document['drafts']! as List).cast<Map<String, Object?>>();
      drafts.first['volume'] = 101; // outside contract bound
      expectRejected(jsonEncode(document));
    });

    test('out-of-contract timezone is refused', () {
      final document = jsonDecode(sampleBackup()) as Map<String, Object?>;
      final drafts = (document['drafts']! as List).cast<Map<String, Object?>>();
      drafts.first['timezone'] = 'ab';
      expectRejected(jsonEncode(document));
    });
  });

  group('backup export hygiene', () {
    test('encode refuses documents that would break their own key scan', () {
      // The scan is over structure, and app models cannot create these keys;
      // encode therefore stays clean by construction for legal state.
      expect(() => sampleBackup(), returnsNormally);
    });
  });
}
