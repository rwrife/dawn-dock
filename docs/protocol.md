# Dawn Dock device/app protocol draft

Status: pre-implementation contract. Transport and cryptographic details require a threat-model spike and test evidence.

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

- Reject unknown major protocol versions, duplicate/replayed IDs, oversized frames, invalid timestamps where relevant, and malformed bodies.
- Unknown optional fields may be ignored; unknown message types are errors.
- `expectedRevision` prevents lost updates. Applying a schedule is atomic.
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

## Security and availability boundaries

- Network/weather/calendar failures cannot alter the already committed alarm schedule.
- Sync/update tasks must not block the real-time alarm evaluator.
- Firmware rejects unauthenticated writes and records bounded audit metadata without sensitive payloads.
- The device is a convenience clock, not a security, medical, emergency, or guaranteed wake-up system.
