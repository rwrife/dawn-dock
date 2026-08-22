# Dawn Dock MVP threat model

**Baseline:** v0.1
**Method:** asset/trust-boundary review with misuse cases
**Evidence status:** design requirements only; no cryptographic implementation has been verified

## Scope and assumptions

The model covers a clock on a user's local network or BLE range, its local-first companion app, user-selected calendar/backup files, USB recovery, and physical reset. The device is not exposed intentionally as an internet service. Physical possession is powerful: an attacker with prolonged access may erase or reflash the prototype. The safety objective is to preserve local alarm availability and make changes visible, not to claim tamper resistance or guaranteed waking.

## Assets and security objectives

| Asset | Objective |
|---|---|
| Committed alarm schedule and revision | Integrity, availability, explicit user authorization |
| Alarm evaluator and occurrence journal | Integrity, bounded latency, duplicate prevention |
| Pairing/session credentials | Confidentiality, revocability, unique per device |
| Time/timezone configuration | Integrity, visible quality/source, correction audit |
| Local calendar-derived data | Minimization, confidentiality, user-controlled deletion/export |
| Firmware and last-known-good image/config | Authenticity where supported, recoverability, rollback |
| Diagnostics | Availability without leaking secrets or full calendar payloads |
| Physical controls | Always available for alarm actions; network activity cannot lock them out |

## Trust boundaries and entry points

- Untrusted local LAN packets, mDNS discovery, and BLE advertisements/frames.
- Pairing UI crossing between physical device display/control and companion app.
- User-selected `.ics` and JSON backup files.
- Authenticated protocol requests that are still untrusted structured input.
- Optional time/weather responses.
- USB serial/flashing and physical reset controls.
- Firmware image/update bundle.
- Local app storage and platform secure credential storage.

## Adversaries and failure actors

- Opportunistic attacker on the same LAN or within BLE range.
- Malicious or compromised paired client.
- Crafted calendar/backup file.
- Accidental user action, stale app state, or two legitimate clients racing.
- Faulty network service, clock correction, storage corruption, brownout, or resource exhaustion.
- Person with brief physical access attempting pairing/reset.
- Person with prolonged physical/USB access; full prevention is out of scope, but recovery and data erasure are defined.

## Required controls

### Pairing and credential storage

- Pairing is closed by default and opens only after a physical action for at most 120 seconds.
- The device creates a unique identity and fresh pairing material; no universal default secret exists.
- The displayed short code is a human confirmation value, not the sole long-term key. The eventual protocol must bind it to an ephemeral authenticated key exchange and show a device fingerprint on both sides.
- Failed attempts are rate-limited and pairing closes after 5 failures or timeout. Rate limiting may not delay clock, audio, or physical controls.
- Long-term app credentials use Keychain/Keystore or OS equivalent. Device credentials use ESP32-supported protected storage after implementation review.
- Users can list/revoke paired clients locally. Factory reset revokes all pairings.

### Schedule writes and replay

- All writes require an authenticated encrypted session.
- Each request carries protocol major version, unique message ID, freshness/session nonce, and expected schedule revision.
- The device keeps a bounded replay cache and rejects duplicate message IDs/nonces.
- Preview is side-effect free. Apply is schema-valid, size-bounded, revision-checked, atomic, re-read/validated, and acknowledged with a receipt.
- Conflicts fail closed and return the current revision; no silent last-write-wins behavior.
- Transport parsing and storage writes run outside the alarm-evaluator timing path.

### Malformed/untrusted input

- Maximum serialized message size: 64 KiB. Set lower operation-specific limits where practical.
- Bound collection counts, string lengths, nesting depth, recurrence expansion, decompressed size, and processing time before allocation or iteration.
- Calendar descriptions, locations, attendees, URLs, and attachments are excluded by default. Imported text is data, never markup or a command.
- Backup restore validates format version, schema, semantic limits, and integrity before preview. It cannot overwrite credentials.
- Stable errors omit secrets, raw credentials, full imported content, memory addresses, and stack traces.

### Denial of service and availability

- Network/BLE queues are bounded. Excess input is dropped/rate-limited with counters.
- Discovery, pairing, sync, optional time, weather, and update checks have finite deadlines and cannot hold the alarm storage lock during I/O.
- Alarm evaluation and physical controls have reserved execution capacity and watchdog coverage.
- Diagnostic logs are bounded/ring-buffered and redact credentials and event payloads.
- Radio failure degrades to offline status; committed alarms continue.

### Firmware recovery and reset

- USB recovery remains available without cloud service.
- Update images require authenticity verification before release of any OTA path; failed boot rolls back to last-known-good firmware.
- Schedule/config migration is versioned and independently rollback-capable. Firmware rollback must not silently erase the committed schedule.
- Factory reset requires a sustained physical gesture (target 5 seconds) plus on-device confirmation. Remote requests may open instructions but may not complete reset.
- Reset erases pairings, network credentials, schedules, imported provenance, and diagnostics, then visibly reports completion.
- Debug interfaces and production lock policy remain an explicit pre-release decision; prototypes must not claim physical tamper resistance.

## Threat and misuse-case analysis

| ID | Threat / misuse | Consequence | Control / verification |
|---|---|---|---|
| TM-01 | Unauthorized nearby client pairs | Schedule/privacy compromise | Physical 120 s window, unique identity, transcript-bound confirmation, 5-attempt closure; protocol and bench negative tests |
| TM-02 | Captured write is replayed | Alarm changes or duplicate apply | Session nonce, message ID cache, expected revision, atomic receipt; fixture replays before/after reboot |
| TM-03 | Two legitimate apps write stale revisions | Lost update | Preview + compare-and-swap revision; conflict fixture |
| TM-04 | Crafted `.ics` expands indefinitely | App memory/CPU exhaustion | File/recurrence/count limits, bounded normalization, fuzz/property tests |
| TM-05 | Crafted JSON/packet exploits parser | Crash or corruption | Strict schema/semantic limits, safe parser, fuzzing, malformed fixture corpus |
| TM-06 | LAN/BLE flood starves alarm task | Late/missed alarm | Bounded queues, task isolation, watchdog, overload fixture plus on-device timing test |
| TM-07 | Pairing failures lock local controls | User cannot snooze/dismiss | Lockout applies only to pairing; physical control priority test |
| TM-08 | Credential appears in log/backup | Unauthorized access | Redaction, credential exclusion from export, log/backup scan tests |
| TM-09 | Malicious time correction suppresses/repeats alarm | Missed or duplicate alarm | Authenticated explicit time change, correction preview, occurrence journal, alarm-semantic fixtures |
| TM-10 | Corrupt update/config bricks device | Loss of alarm service | Signed/authentic update gate, last-known-good rollback, USB recovery, corruption tests |
| TM-11 | Accidental/remote factory reset | Data loss | Physical hold + on-device confirmation; remote reset prohibited; bench gesture tests |
| TM-12 | Optional weather/NTP endpoint fails or lies | UI error or wrong time | Optional isolation, time-quality display, authenticated/validated time policy; network-loss fixtures |
| TM-13 | Prolonged physical/USB attacker reflashes prototype | Full compromise | Out-of-scope to prevent completely; disclose limitation, preserve local erase/recovery, decide debug lock before release |
| TM-14 | Secret/calendar data remains after erase | Privacy failure | Defined erase inventory, post-reset storage inspection, app deletion tests |

## Security decisions deferred to implementation spikes

The final authenticated transport, key exchange, cipher suite, certificate/fingerprint lifecycle, ESP32 flash-encryption/secure-boot posture, and platform BLE association mode are not selected here. Issues #5 and #6 must choose reviewed platform-supported primitives rather than inventing cryptography. Regardless of transport, all controls above are invariant acceptance criteria.

## Verification evidence classes

- Protocol schema, static analysis, unit/fuzz/property tests: software test evidence.
- Packet capture, pairing timing, overload latency, reset gesture, rollback, and radio-loss runs on target: bench evidence.
- Multi-day operation in realistic RF conditions: field evidence.

No security control is called implemented or verified until the corresponding evidence exists.
