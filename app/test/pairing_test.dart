import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/pairing.dart';

void main() {
  final baseStart = DateTime.utc(2026, 9, 26, 12, 0, 0);

  PairingCandidate manualCandidate({
    String identity = '192.168.1.42:8443',
    String displayName = 'Bedside Clock',
  }) => PairingCandidate(
    identity: identity,
    displayName: displayName,
    source: CandidateSource.manual,
  );

  PairingCandidate discoveredCandidate({
    String identity = 'dawn-dock-7f93d1._dawn-dock._tcp.local',
    String displayName = 'Dawn Dock Guest',
  }) => PairingCandidate(
    identity: identity,
    displayName: displayName,
    source: CandidateSource.discovered,
  );

  PairingCeremony openCeremony({
    PairingCandidate? candidate,
    String expectedShortCode = '482910',
    String expectedFingerprint = 'A1:B2:C3:D4:E5:F6:07:18',
    DateTime? windowStart,
    int windowSeconds = kMaxPairingWindowSeconds,
    DateTime Function()? clock,
  }) => PairingCeremony(
    candidate: candidate ?? manualCandidate(),
    expectedShortCode: expectedShortCode,
    expectedFingerprint: expectedFingerprint,
    windowStart: windowStart ?? baseStart,
    windowSeconds: windowSeconds,
    clock: clock ?? () => baseStart,
  );

  group('PairingCandidate and registry', () {
    test('enforces non-empty and bounded UTF-8 limits', () {
      expect(
        () => PairingCandidate(
          identity: '',
          displayName: 'Clock',
          source: CandidateSource.manual,
        ),
        throwsArgumentError,
      );
      expect(
        () => PairingCandidate(
          identity: 'a' * 65,
          displayName: 'Clock',
          source: CandidateSource.manual,
        ),
        throwsArgumentError,
      );
      expect(
        () => PairingCandidate(
          identity: 'clock',
          displayName: '',
          source: CandidateSource.manual,
        ),
        throwsArgumentError,
      );
      expect(
        () => PairingCandidate(
          identity: 'clock',
          displayName: 'd' * 65,
          source: CandidateSource.manual,
        ),
        throwsArgumentError,
      );
    });

    test('value equality and hashCode match by fields', () {
      final a = manualCandidate();
      final b = manualCandidate();
      final c = discoveredCandidate();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('registry upserts by identity, preserves insertion order, and removes', () {
      final registry = PairingCandidateRegistry();
      final c1 = manualCandidate(identity: 'clock-1', displayName: 'Clock 1');
      final c2 = discoveredCandidate(
        identity: 'clock-2',
        displayName: 'Clock 2',
      );
      final c1Updated = manualCandidate(
        identity: 'clock-1',
        displayName: 'Clock 1 (Renamed)',
      );

      registry.upsert(c1);
      registry.upsert(c2);
      expect(registry.candidates.map((c) => c.identity), [
        'clock-1',
        'clock-2',
      ]);

      // Upserting an existing identity updates in place without moving position
      registry.upsert(c1Updated);
      expect(registry.candidates.map((c) => c.identity), [
        'clock-1',
        'clock-2',
      ]);
      expect(registry.byIdentity('clock-1')?.displayName, 'Clock 1 (Renamed)');

      expect(registry.remove('clock-2'), isTrue);
      expect(registry.remove('non-existent'), isFalse);
      expect(registry.candidates.length, 1);

      registry.clear();
      expect(registry.candidates, isEmpty);
    });

    test('registry enforces candidate capacity ceiling', () {
      final registry = PairingCandidateRegistry();
      for (var i = 0; i < kMaxDiscoveryCandidates; i++) {
        registry.upsert(
          manualCandidate(identity: 'dev-$i', displayName: 'Device $i'),
        );
      }
      expect(registry.candidates.length, kMaxDiscoveryCandidates);

      // Updating existing identity succeeds
      expect(
        () => registry.upsert(
          manualCandidate(identity: 'dev-0', displayName: 'Device 0 Updated'),
        ),
        returnsNormally,
      );

      // Adding 33rd candidate throws
      expect(
        () => registry.upsert(
          manualCandidate(identity: 'dev-overflow', displayName: 'Overflow'),
        ),
        throwsStateError,
      );
    });
  });

  group('PairingCeremony: window constraints and clock behavior', () {
    test('enforces bounded short code, fingerprint, and window bounds', () {
      expect(() => openCeremony(expectedShortCode: ''), throwsArgumentError);
      expect(
        () => openCeremony(expectedShortCode: '1' * 17),
        throwsArgumentError,
      );
      expect(() => openCeremony(expectedFingerprint: ''), throwsArgumentError);
      expect(
        () => openCeremony(expectedFingerprint: 'F' * 65),
        throwsArgumentError,
      );
      expect(() => openCeremony(windowSeconds: 0), throwsArgumentError);
      expect(() => openCeremony(windowSeconds: 121), throwsArgumentError);
    });

    test(
      'window deadline and remaining seconds clamp to zero when elapsed',
      () {
        var currentClock = baseStart;
        final ceremony = openCeremony(
          windowStart: baseStart,
          windowSeconds: 120,
          clock: () => currentClock,
        );

        expect(
          ceremony.windowDeadline,
          baseStart.add(const Duration(seconds: 120)),
        );
        expect(ceremony.remainingWindowSeconds(), 120);

        currentClock = baseStart.add(const Duration(seconds: 45));
        expect(ceremony.remainingWindowSeconds(), 75);

        currentClock = baseStart.subtract(const Duration(seconds: 10));
        expect(ceremony.remainingWindowSeconds(), 120);

        currentClock = baseStart.add(const Duration(seconds: 120));
        expect(ceremony.remainingWindowSeconds(), 0);

        currentClock = baseStart.add(const Duration(seconds: 200));
        expect(ceremony.remainingWindowSeconds(), 0);
      },
    );

    test(
      'checkExpiry transitions ceremony to timedOut when window has elapsed',
      () {
        var currentClock = baseStart;
        final ceremony = openCeremony(
          windowStart: baseStart,
          windowSeconds: 60,
          clock: () => currentClock,
        );

        expect(ceremony.isClosed, isFalse);
        expect(ceremony.checkExpiry(), isFalse);
        expect(ceremony.isClosed, isFalse);

        currentClock = baseStart.add(const Duration(seconds: 60));
        expect(ceremony.checkExpiry(), isTrue);
        expect(ceremony.isClosed, isTrue);
        expect(ceremony.closureReason, PairingClosureReason.timedOut);
        expect(ceremony.remainingAttempts, 0);

        // Subsequent checkExpiry is a no-op
        expect(ceremony.checkExpiry(), isFalse);
      },
    );
  });

  group(
    'PairingCeremony: confirmation attempts, failure lockout, and cancellation',
    () {
      test('successful confirmation on first attempt completes ceremony', () {
        final ceremony = openCeremony(
          expectedShortCode: '482910',
          expectedFingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
        );

        final result = ceremony.attemptConfirmation(
          shortCode: '482910',
          fingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
        );

        expect(result.accepted, isTrue);
        expect(result.attemptNumber, 1);
        expect(result.remainingAttempts, 0);
        expect(result.closureReason, PairingClosureReason.confirmed);
        expect(ceremony.isClosed, isTrue);
        expect(ceremony.closureReason, PairingClosureReason.confirmed);
      });

      test('wrong code or fingerprint increments attempt and leaves ceremony open if under 5', () {
        final ceremony = openCeremony(
          expectedShortCode: '482910',
          expectedFingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
        );

        // Wrong code, correct fingerprint
        var res = ceremony.attemptConfirmation(
          shortCode: '000000',
          fingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
        );
        expect(res.accepted, isFalse);
        expect(res.attemptNumber, 1);
        expect(res.remainingAttempts, 4);
        expect(res.closureReason, isNull);
        expect(ceremony.isClosed, isFalse);

        // Correct code, wrong fingerprint
        res = ceremony.attemptConfirmation(
          shortCode: '482910',
          fingerprint: '00:00:00:00:00:00:00:00',
        );
        expect(res.accepted, isFalse);
        expect(res.attemptNumber, 2);
        expect(res.remainingAttempts, 3);
        expect(res.closureReason, isNull);
        expect(ceremony.isClosed, isFalse);
      });

      test(
        'attempt before window start throws and does not consume attempts',
        () {
          var currentClock = baseStart.subtract(const Duration(seconds: 1));
          final ceremony = PairingCeremony(
            candidate: manualCandidate(),
            expectedShortCode: '482910',
            expectedFingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
            windowStart: baseStart,
            windowSeconds: 120,
            clock: () => currentClock,
          );

          expect(
            () => ceremony.attemptConfirmation(
              shortCode: '482910',
              fingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
            ),
            throwsStateError,
          );
          expect(ceremony.attemptCount, 0);
          expect(ceremony.isClosed, isFalse);

          currentClock = baseStart;
          final result = ceremony.attemptConfirmation(
            shortCode: '482910',
            fingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
          );
          expect(result.accepted, isTrue);
          expect(result.attemptNumber, 1);
          expect(ceremony.closureReason, PairingClosureReason.confirmed);
        },
      );

      test('reaches 5-attempt closure (attemptsExhausted) on 5th failed confirmation', () {
        final ceremony = openCeremony(
          expectedShortCode: '111111',
          expectedFingerprint: 'AA:BB:CC',
        );

        for (var i = 1; i <= 4; i++) {
          final res = ceremony.attemptConfirmation(
            shortCode: 'wrong',
            fingerprint: 'wrong',
          );
          expect(res.accepted, isFalse);
          expect(res.attemptNumber, i);
          expect(res.remainingAttempts, 5 - i);
          expect(res.closureReason, isNull);
        }

        // 5th attempt exhausts attempts
        final fifth = ceremony.attemptConfirmation(
          shortCode: 'wrong',
          fingerprint: 'wrong',
        );
        expect(fifth.accepted, isFalse);
        expect(fifth.attemptNumber, 5);
        expect(fifth.remainingAttempts, 0);
        expect(fifth.closureReason, PairingClosureReason.attemptsExhausted);
        expect(ceremony.isClosed, isTrue);
        expect(ceremony.closureReason, PairingClosureReason.attemptsExhausted);

        // 6th attempt throws StateError
        expect(
          () => ceremony.attemptConfirmation(
            shortCode: '111111',
            fingerprint: 'AA:BB:CC',
          ),
          throwsStateError,
        );
      });

      test('attempting confirmation after window expires throws StateError and marks timedOut', () {
        var currentClock = baseStart;
        final ceremony = openCeremony(
          windowStart: baseStart,
          windowSeconds: 60,
          clock: () => currentClock,
        );

        currentClock = baseStart.add(const Duration(seconds: 61));

        expect(
          () => ceremony.attemptConfirmation(
            shortCode: '482910',
            fingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
          ),
          throwsStateError,
        );
        expect(ceremony.isClosed, isTrue);
        expect(ceremony.closureReason, PairingClosureReason.timedOut);
      });

      test('cancel marks ceremony cancelled and subsequent attempts throw', () {
        final ceremony = openCeremony();
        expect(ceremony.isClosed, isFalse);

        ceremony.cancel();
        expect(ceremony.isClosed, isTrue);
        expect(ceremony.closureReason, PairingClosureReason.cancelled);
        expect(ceremony.remainingAttempts, 0);

        expect(
          () => ceremony.attemptConfirmation(
            shortCode: '482910',
            fingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
          ),
          throwsStateError,
        );

        // Redundant cancel preserves original reason
        ceremony.cancel();
        expect(ceremony.closureReason, PairingClosureReason.cancelled);
      });
    },
  );

  group('PairedDeviceRecord and PairedDeviceRegistry', () {
    test('completeWithReference requires confirmed state and cannot be called twice', () {
      final ceremony = openCeremony();
      expect(
        () =>
            ceremony.completeWithReference(secureStorageReference: 'key-ref-1'),
        throwsStateError,
      );

      ceremony.attemptConfirmation(
        shortCode: '482910',
        fingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
      );

      final record = ceremony.completeWithReference(
        secureStorageReference: 'key-ref-1',
        pairedAtUtc: baseStart,
      );
      expect(record.identity, ceremony.candidate.identity);
      expect(record.displayName, ceremony.candidate.displayName);
      expect(record.secureStorageReference, 'key-ref-1');
      expect(record.pairedAtUtc, baseStart);

      // Re-invoking completeWithReference on the same ceremony throws StateError
      expect(
        () =>
            ceremony.completeWithReference(secureStorageReference: 'key-ref-2'),
        throwsStateError,
      );
    });

    test('invalid secureStorageReference does not consume one-shot completion', () {
      final ceremony = openCeremony();
      ceremony.attemptConfirmation(
        shortCode: '482910',
        fingerprint: 'A1:B2:C3:D4:E5:F6:07:18',
      );

      expect(
        () => ceremony.completeWithReference(secureStorageReference: ''),
        throwsArgumentError,
      );

      // Ceremony is still confirmed and can be completed with a valid reference
      final record = ceremony.completeWithReference(
        secureStorageReference: 'valid-ref',
      );
      expect(record.secureStorageReference, 'valid-ref');
    });

    test(
      'diagnostic map redacts secure storage reference, code, and fingerprint',
      () {
        final record = PairedDeviceRecord(
          identity: 'clock-abc',
          displayName: 'Bedroom Clock',
          secureStorageReference: 'keychain-alias-9921',
          pairedAtUtc: DateTime.utc(2026, 9, 26, 14, 30, 0),
        );

        final diag = record.toDiagnosticMap();
        expect(diag.keys.toSet(), {'identity', 'displayName', 'pairedAtUtc'});
        expect(diag['identity'], 'clock-abc');
        expect(diag['displayName'], 'Bedroom Clock');
        expect(diag['pairedAtUtc'], '2026-09-26T14:30:00.000Z');
        expect(diag.containsKey('secureStorageReference'), isFalse);
      },
    );

    test(
      'paired registry stores records, enforces capacity, revokes, and clears',
      () {
        final registry = PairedDeviceRegistry();
        final r1 = PairedDeviceRecord(
          identity: 'clock-1',
          displayName: 'Clock 1',
          secureStorageReference: 'ref-1',
          pairedAtUtc: baseStart,
        );
        final r2 = PairedDeviceRecord(
          identity: 'clock-2',
          displayName: 'Clock 2',
          secureStorageReference: 'ref-2',
          pairedAtUtc: baseStart,
        );

        registry.add(r1);
        registry.add(r2);
        expect(registry.records.length, 2);
        expect(registry.byIdentity('clock-1'), equals(r1));

        // Updating existing record replaces without increasing length
        final r1Updated = PairedDeviceRecord(
          identity: 'clock-1',
          displayName: 'Clock 1 Renamed',
          secureStorageReference: 'ref-1-new',
          pairedAtUtc: baseStart,
        );
        registry.add(r1Updated);
        expect(registry.records.length, 2);
        expect(registry.byIdentity('clock-1')?.displayName, 'Clock 1 Renamed');

        expect(registry.revoke('clock-1'), isTrue);
        expect(registry.revoke('clock-1'), isFalse);
        expect(registry.records.length, 1);

        registry.clear();
        expect(registry.records, isEmpty);
      },
    );

    test(
      'paired registry throws StateError when reaching capacity ceiling',
      () {
        final registry = PairedDeviceRegistry();
        for (var i = 0; i < kMaxDiscoveryCandidates; i++) {
          registry.add(
            PairedDeviceRecord(
              identity: 'dev-$i',
              displayName: 'Device $i',
              secureStorageReference: 'ref-$i',
              pairedAtUtc: baseStart,
            ),
          );
        }
        expect(registry.records.length, kMaxDiscoveryCandidates);

        expect(
          () => registry.add(
            PairedDeviceRecord(
              identity: 'overflow',
              displayName: 'Overflow',
              secureStorageReference: 'ref-overflow',
              pairedAtUtc: baseStart,
            ),
          ),
          throwsStateError,
        );
      },
    );
  });
}
