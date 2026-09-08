# Dawn Dock device/app protocol draft

Status: envelope/schema fixtures, host-side envelope validation, bounded JSON body parsing, and body-schema validation with stable `schema_invalid`/`payload_semantic_error` codes are implemented for `dawn-dock/1`. Transport and cryptographic session details still require implementation evidence. Security invariants are normative in [`threat-model.md`](threat-model.md); alarm behavior is normative in [`alarm-semantics.md`](alarm-semantics.md).

## Goals

- Local operation without a cloud broker.
- Explicit physical pairing and unique per-device credentials.
- Human-reviewable schedule diffs and atomic revisioned updates.
- Forward-compatible messages with strict size/schema validation.
- Alarm execution independent of transport availability.

## Candidate transports

1. Local HTTPS plus WebSocket events after discovery by mDNS/manual address.
2. BLE GATT framing for initial provisioning and schedule transfer.

Firmware exposes one transport-neutral service. The MVP may ship one transport first, but serialized domain messages and security invariants must be shared.

## Pairing assumptions

- User physically opens a short pairing window on the clock.
- Device displays a random short code and fingerprint; there is no universal default credential.
- Pairing establishes a high-entropy secret or key pair stored in device secure storage and app Keychain/Keystore.
- LAN communication uses authenticated encryption. BLE relies on an authenticated application session in addition to applicable platform link security.
- Factory reset revokes all pairings. Rate limits and lockouts must not disable local physical alarm controls.

## v1 schemas and fixtures

- Envelope schema: `docs/protocol/schemas/v1/envelope.schema.json`
- Alarm record schema: `docs/protocol/schemas/v1/alarm.schema.json`
- Error-body schema: `docs/protocol/schemas/v1/error_response.schema.json`
- Canonical fixtures: `docs/protocol/fixtures/v1/` (`manifest.json`, `valid/`, `invalid/`)
- Firmware-host validation entrypoints: `firmware/host/tests/protocol_fixture_contract_test.py` (cross-language contract mirror) and `firmware/host/tests/protocol_fixture_cross_language_test.cpp` (drives the same manifest through the C++ envelope preflight, parser, and body validator)

The fixture manifest is normative for cross-language compatibility tests: app-side and firmware-side tests should consume the same fixture set and expected error codes. Body-level violations inside otherwise-envelope-valid fixtures are reported with the stable codes `schema_invalid` (malformed payload) or `payload_semantic_error` (schema-valid payload breaking domain bounds such as the 32-alarm storage limit or duplicate alarm ids).

## Envelope

```json
{
  "protocol": "dawn-dock/1",
  "messageId": "client-generated-unique-id",
  "sentAt": "2026-08-21T00:00:00Z",
  "type": "schedule.preview",
  "expectedRevision": 12,
  "body": {}
}
```

Rules:

- The serialized envelope is at most 64 KiB; operations must define tighter collection/string/recurrence limits where practical.
- Reject unknown major protocol versions, duplicate/replayed IDs, oversized frames, invalid timestamps where relevant, and malformed bodies.
- Envelope-level unknown fields are rejected for deterministic interoperability; operation bodies may evolve through explicit schema version updates.
- `expectedRevision` is required for `schedule.preview` and `schedule.apply` to prevent lost updates. Applying a schedule is atomic.
- External strings are length-limited and safely rendered; they are never commands.

## Initial operations

| Type | Direction | Purpose |
|---|---|---|
| `device.status.get` | app → device | Read identity, versions, time quality, next alarm, schedule revision, and capabilities |
| `time.configure` | app → device | Set timezone/rule source and synchronize time with explicit user action |
| `schedule.preview` | app → device | Validate proposed alarms and return normalized diff without applying |
| `schedule.apply` | app → device | Atomically apply the accepted diff against an expected revision |
| `schedule.get` | app → device | Fetch local alarm records without unrelated imported event detail |
| `diagnostics.get` | app → device | Fetch bounded reset/storage/RTC/radio diagnostics |
| `backup.export` | app → device | Export versioned settings and schedules |
| `event.syncReceipt` | device → app | Confirm applied revision, item counts, and computed next alarm |
| `event.alarmState` | device → app | Optional live ring/snooze/dismiss status; not required for execution |

## Alarm record draft

```json
{
  "id": "uuid",
  "label": "Workday",
  "enabled": true,
  "localTime": "07:00",
  "days": [1, 2, 3, 4, 5],
  "timezone": "America/New_York",
  "sound": "gentle-1",
  "volume": 45,
  "snoozeMinutes": 9,
  "source": "manual",
  "sourceEventId": null
}
```

Calendar imports are normalized in the app. Only fields required for an accepted alarm are transferred; descriptions, attendees, and location are excluded by default.

## Error model

Errors include a stable code, safe user-facing summary, optional field path, current revision where relevant, and retryability flag. Logs must not include Wi-Fi credentials, pairing secrets, or full imported calendar payloads.

Envelope/service-level stable codes (`docs/protocol/schemas/v1/error_response.schema.json`):

| Code | Meaning | Retryable |
|---|---|---|
| `invalid_protocol` | Unknown/incompatible major protocol string | No |
| `unknown_type` | Unsupported message `type` | No |
| `invalid_message_id` | Missing/invalid `messageId` format | No |
| `duplicate_message_id` | Replay window already contains this `messageId` | Yes (with a fresh ID) |
| `invalid_sent_at` | `sentAt` is not strict UTC RFC3339 form | No |
| `expected_revision_required` | Missing `expectedRevision` for schedule preview/apply | Yes |
| `envelope_too_large` | Serialized envelope exceeds 64 KiB cap | No |
| `revision_conflict` | `expectedRevision` does not match device revision | Yes (after refresh) |
| `schema_invalid` | Body fails message schema validation | No |
| `payload_semantic_error` | Schema-valid payload breaks domain constraints | No |
| `unauthorized` | Pairing/session/authentication not valid | Possibly |
| `rate_limited` | Request refused by anti-abuse throttles | Yes |

## Security and availability boundaries

- Network/weather/calendar failures cannot alter the already committed alarm schedule.
- Sync/update tasks must not block the real-time alarm evaluator.
- Firmware rejects unauthenticated writes and records bounded audit metadata without sensitive payloads.
- The device is a convenience clock, not a security, medical, emergency, or guaranteed wake-up system.
