import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dawn_dock_companion/domain/protocol_contract.dart';

/// Drives the canonical fixture manifest from
/// `docs/protocol/fixtures/v1/manifest.json` through the pure-Dart contract
/// gate. The manifest is the normative expectation set shared with the
/// firmware cross-language test and the Python mirror; this test reads it
/// from disk relative to the package root so the expectation lists cannot
/// drift silently out of sync with `docs/`.
void main() {
  // `flutter test` runs with the package root (`app/`) as the working
  // directory, matching CI's `working-directory: app`. The canonical
  // fixtures live one level up in `docs/` and are the normative source.
  final fixtureRoot = Directory.current.uri
      .resolve('../docs/protocol/fixtures/v1/')
      .toFilePath();
  final manifestFile = File('${fixtureRoot}manifest.json');

  if (!manifestFile.existsSync()) {
    test('canonical manifest is reachable from the package', () {
      fail('expected ${manifestFile.path} to exist');
    });
    return;
  }

  group('protocol fixture contract parity', () {
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
    final fixtures = (manifest['fixtures']! as List)
        .cast<Map<String, Object?>>();

    test('manifest is non-empty', () {
      expect(fixtures, isNotEmpty);
    });

    for (final entry in fixtures) {
      final path = entry['path']! as String;
      final shouldBeValid = entry['valid']! as bool;
      final expectedCode = entry['expected_code'] as String?;

      test(path, () {
        // fixtureRoot ends with a platform separator; the manifest uses '/'.
        final file = File(
          '$fixtureRoot${path.replaceAll('/', Platform.pathSeparator)}',
        );
        expect(file.existsSync(), isTrue, reason: 'missing fixture $path');
        final payload =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final code = validateContractMessage(payload);
        if (shouldBeValid) {
          expect(
            code,
            ContractCode.accepted,
            reason: 'fixture $path must validate as accepted',
          );
        } else {
          expect(
            contractCodeName(code),
            expectedCode,
            reason: 'fixture $path must fail with $expectedCode',
          );
        }
      });
    }
  });

  group('contract gate specifics', () {
    Map<String, Object?> envelope(
      Map<String, Object?> body, {
      String type = 'schedule.preview',
      String? messageId = 'req-1000',
      String sentAt = '2026-09-06T12:00:00Z',
      int? expectedRevision = 1,
    }) => {
      'protocol': kProtocolVersion,
      'messageId': messageId,
      'sentAt': sentAt,
      'expectedRevision': ?expectedRevision,
      'type': type,
      'body': body,
    };

    Map<String, Object?> alarm(
      String id, {
      String label = 'Workday',
      String localTime = '07:00',
      List<int> days = const [1, 2, 3, 4, 5],
      String timezone = 'America/New_York',
      int snoozeMinutes = 9,
      int volume = 45,
      String sound = 'gentle-1',
      String source = 'manual',
      String? sourceEventId,
    }) => {
      'id': id,
      'label': label,
      'enabled': true,
      'localTime': localTime,
      'days': days,
      'timezone': timezone,
      'snoozeMinutes': snoozeMinutes,
      'volume': volume,
      'sound': sound,
      'source': source,
      'sourceEventId': sourceEventId,
    };

    test('valid schedule body with two alarms is accepted', () {
      final code = validateContractMessage(
        envelope({
          'alarms': [
            alarm('wake-weekdays'),
            alarm('weekend', days: const [0, 6]),
          ],
        }),
      );
      expect(code, ContractCode.accepted);
    });

    test(
      'exactly the bound of alarms passes; one more is a semantic error',
      () {
        final atBound = List.generate(
          kMaxStoredAlarms,
          (i) => alarm('alarm-$i'),
        );
        expect(
          validateContractMessage(envelope({'alarms': atBound})),
          ContractCode.accepted,
        );
        final overBound = [...atBound, alarm('alarm-extra')];
        expect(
          validateContractMessage(envelope({'alarms': overBound})),
          ContractCode.payloadSemanticError,
        );
      },
    );

    test('duplicate alarm ids are a semantic conflict', () {
      final code = validateContractMessage(
        envelope({
          'alarms': [alarm('dup'), alarm('dup', label: 'Other')],
        }),
      );
      expect(code, ContractCode.payloadSemanticError);
    });

    test('label bound is measured in UTF-8 bytes, not code units', () {
      // 48 BMP characters fit 48 bytes exactly.
      final fits = alarm('fit', label: 'a' * 48);
      expect(
        validateContractMessage(
          envelope({
            'alarms': [fits],
          }),
        ),
        ContractCode.accepted,
      );
      // 24 four-byte emoji are 24 code points but 96 bytes.
      final tooWide = alarm('wide', label: '\u{1F305}' * 24);
      expect(
        validateContractMessage(
          envelope({
            'alarms': [tooWide],
          }),
        ),
        ContractCode.schemaInvalid,
      );
    });

    test('day list rejects duplicates, ranges, and emptiness', () {
      for (final days in [
        <int>[],
        [1, 1],
        [7],
        [-1],
      ]) {
        expect(
          validateContractMessage(
            envelope({
              'alarms': [alarm('days', days: days)],
            }),
          ),
          ContractCode.schemaInvalid,
          reason: 'days=$days must be rejected',
        );
      }
    });

    test('unknown envelope keys inside an alarm are rejected', () {
      final record = alarm('extra')..['description'] = 'not allowed';
      expect(
        validateContractMessage(
          envelope({
            'alarms': [record],
          }),
        ),
        ContractCode.schemaInvalid,
      );
    });

    test('rule order: unknown type outranks an invalid message id', () {
      final code = validateContractMessage(
        envelope(
          {'alarms': []},
          type: 'device.self_destruct',
          messageId: 'bad id',
        ),
      );
      expect(code, ContractCode.unknownType);
    });

    test('rule order: invalid protocol outranks everything', () {
      final payload = envelope({'alarms': []}, type: 'device.self_destruct')
        ..['protocol'] = 'dawn-dock/99';
      final code = validateContractMessage(payload);
      expect(code, ContractCode.invalidProtocol);
    });

    test('replay window rejects a repeated message id and remembers only accepted messages', () {
      final seen = <String>{};
      final payload = envelope({
        'alarms': [alarm('wake')],
      });
      expect(
        validateContractMessage(payload, replayWindow: seen),
        ContractCode.accepted,
      );
      expect(
        validateContractMessage(payload, replayWindow: seen),
        ContractCode.duplicateMessageId,
      );
      // A rejected message must not poison the window.
      final broken = envelope({
        'alarms': [alarm('bad!', label: '')],
      }, messageId: 'req-broken');
      expect(
        validateContractMessage(broken, replayWindow: seen),
        ContractCode.schemaInvalid,
      );
      expect(seen.contains('req-broken'), isFalse);
    });

    test('oversize accounting prefers fixture transport metadata', () {
      final payload = envelope(
        {'alarms': []},
        type: 'device.status.get',
        expectedRevision: null,
      )..['_fixtureMeta'] = {'serializedSizeBytes': 70000};
      expect(validateContractMessage(payload), ContractCode.envelopeTooLarge);
    });

    test(
      'canonical serialization stays under the cap for realistic payloads',
      () {
        final payload = envelope({
          'alarms': List.generate(8, (i) => alarm('alarm-$i')),
        });
        expect(serializedEnvelopeBytes(payload), lessThan(kMaxEnvelopeBytes));
      },
    );

    test('sync receipt beyond the storage bound is a semantic error', () {
      final code = validateContractMessage(
        envelope(
          {
            'appliedRevision': 13,
            'alarmCount': kMaxStoredAlarms + 1,
            'nextAlarmUtc': '2026-09-07T11:00:00Z',
          },
          type: 'event.syncReceipt',
          expectedRevision: null,
        ),
      );
      expect(code, ContractCode.payloadSemanticError);
    });

    test('error response with an out-of-enum code is schema-invalid', () {
      final code = validateContractMessage(
        envelope(
          {'code': 'not_a_real_code', 'summary': 'x', 'retryable': false},
          type: 'error.response',
          expectedRevision: null,
        ),
      );
      expect(code, ContractCode.schemaInvalid);
    });

    test('body types without a checked-in schema pass through', () {
      expect(
        validateContractMessage(
          envelope(
            {'anything': 1},
            type: 'device.status.get',
            expectedRevision: null,
          ),
        ),
        ContractCode.accepted,
      );
    });
  });
}
