# Dawn Dock companion bootstrap

This is an offline, in-memory Flutter demo backed by a fake device. Its Dart
application behavior uses no account, network operation, runtime permission,
telemetry, or persistence. The displayed next alarm is illustrative and is not
derived from the current time. The demo never executes an alarm or sends a
confirmation to real hardware.

The screen lets a reviewer preview one hardcoded schedule change, cancel it, or
explicitly apply it to fake state. Applying advances the in-memory revision once
and produces a demo-only receipt. **Reset demo** restores the initial state. The
controller is intentionally non-persistent, so restoring the initial state after
a real app restart is implementation intent, not measured evidence. The host
test only removes and reconstructs the widget tree within the same test process.

This bootstrap is not evidence of pairing, transport, device storage, calendar
import, notifications, or alarm execution. Those remain part of open parent
issue #6. The architectural and privacy boundaries are defined in
[system architecture](../docs/system-architecture.md), the
[threat model](../docs/threat-model.md), and the
[protocol](../docs/protocol.md).

## Local domain layer (issues #35, #39, #41, #43, #45, #47)

`lib/domain/` adds pure-Dart building blocks behind the demo. Nothing in the
demo UI changed: the domain code is host-tested only and is not yet wired to
any screen, filesystem, or transport.

- `protocol_contract.dart` mirrors the firmware validator chain
  (`validate_protocol_envelope` + bounded body validation) in the documented
  rule order with the stable error codes from `docs/protocol.md`.
  `test/protocol_contract_test.dart` drives the canonical manifest
  `docs/protocol/fixtures/v1/manifest.json` read from disk, so the Dart side
  is checked against the same normative fixtures as firmware, plus targeted
  gate-specific cases (rule order, replay window, UTF-8 byte bounds, the
  32-alarm semantic boundary). This is Dart-side self-consistency evidence
  only — real device interoperability still requires authenticated
  transport.
- `device_profile.dart`, `alarm_draft.dart`, and `schedule_store.dart` hold
  device profiles, editable alarm drafts with bounded import provenance
  (ics drafts must carry provenance; manual drafts must not), and a
  revision-tracked in-memory schedule mirror with a sync-receipt mirror. All
  bounds are enforced at construction; nothing here performs I/O.
- `backup.dart` exports/restores versioned JSON backups
  (`dawndock-companion-backup` v1) of the app's own state. Restore is
  fail-closed: exact key sets, model-bound validation of every entry, and a
  reserved-key scan that rejects credential-like keys before any state is
  replaced. Backups currently live only as strings in memory/tests — the
  file pick and storage wiring are later slices.
- `schedule_diff.dart` computes the deterministic, reviewable diff between
  the committed schedule mirror and a proposed draft set: id-sorted
  added/removed/changed/unchanged classification with stable field-change
  codes, an unmodifiable value-equal result, a `summaryText()` review
  string, and a `toWirePreviewBody()` alarm-array payload matching
  `AlarmDraft.toWireAlarm()` exactly. Proposals the wire contract would
  refuse (capacity, duplicate ids) fail closed before any diff work, via
  the same `DeviceScheduleStore.validateProposal` check.
- `schedule_exchange.dart` frames the `schedule.preview` / `schedule.apply`
  exchange around that diff. `ScheduleExchange.beginPreview` arms a proposal
  only when its expected revision equals the local mirror, and
  `buildPreview`/`buildApply` produce request envelopes that pass the
  mirrored `validateContractMessage` gate and are byte-equal to the canonical
  fixtures `valid/schedule_preview.request.json` and
  `valid/schedule_apply.request.json` (verified by
  `test/schedule_exchange_test.dart`). A device-issued apply token is bound
  to the exact previewed content digest and revision; malformed tokens,
  content drift, or mirror movement past the armed revision refuse the apply
  without sending. `ingest` runs inbound `event.syncReceipt` /
  `error.response` messages through the contract gate with a bounded replay
  window first: a receipt is adopted only when it advances exactly one
  revision with a matching alarm count (everything else leaves the store
  untouched), a `revision_conflict` moves the exchange to a refresh-required
  state that discards the token, and `rebase` refuses until an independent
  sync refreshes the mirror to the device-reported revision. This is
  host-side framing evidence only: the real transport, device-side token
  issuance, and UI wiring remain open.
- `recurrence.dart` is a line-faithful pure-Dart mirror of the firmware
  weekly recurrence resolver (`firmware/components/alarm_core/`), including
  its int64 overflow guards and 14-day bounded search. It resolves the next
  occurrence for a caller-supplied UTC-offset rule chain: spring-gap times
  shift once to the earliest valid local instant on the same calendar date
  (`shiftedForGap`), ambiguous fold instants resolve to the FIRST UTC
  occurrence only (`ambiguousFold`), and malformed schedules, mismatched
  rule-set provenance, broken transition chains, and unrepresentable
  instants fail closed with typed statuses.
  `test/recurrence_test.dart` asserts the identical instants, offsets,
  local dates, and gap/fold flags as every expectation in
  `firmware/host/tests/recurrence_resolver_test.cpp` (New York and Berlin
  gap/fold, Apia's fully deleted Friday, Tokyo local-weekday selection,
  UTC year rollover, second-fold-never-selected, and the overflow
  fail-closed cases). This is static policy-mirror evidence: the app never
  queries a platform timezone database, on-device rule-data embedding, and
  app/device output interoperability over a session remain open.
- `device_status.dart` projects a deterministic next-alarm/status summary
  over the committed schedule mirror and caller-supplied timezone rules.
  It fails closed when any enabled alarm cannot be resolved, tie-breaks equal
  UTC instants by alarm ID, and classifies evidence as local-only, current-
  revision receipt-confirmed, or receipt-mismatch. `test/device_status_test.dart`
  covers empty/disabled schedules, gap/fold metadata, unresolved fail-closed
  behavior, and receipt-evidence transitions. This is host-only model evidence:
  there is no live transport, runtime clock source integration, target alarm
  execution, or endurance proof.
- `pairing.dart` adds a pure-Dart pairing-domain policy core for issue #47:
  bounded discovery/manual-address candidates, a ceremony that is closed by
  default and only valid inside a caller-reported device pairing window
  (max 120 seconds), exact short-code + fingerprint confirmation, 5-attempt
  lockout closure, explicit cancel/timeout states, and paired-device records
  that carry only an opaque secure-storage reference token (never raw
  credentials). `test/pairing_test.dart` verifies happy path, timeout edge,
  lockout boundary, mismatch handling, one-shot completion behavior, and
  diagnostic redaction. This is software-only policy evidence — no
  cryptographic key exchange, Keychain/Keystore plugin integration,
  LAN/BLE transport, firmware/device interoperability, or physical pairing
  timing claim.

## Toolchain and quickstart

The repository pins Flutter 3.47.2 and its bundled Dart 3.13.2 in
`.flutter-version`, CI, and `tool/verify_flutter_version.sh`. With the approved
SDK installed at `/tmp/flutter-3.47.2`:

```bash
cd app
FLUTTER_BIN=/tmp/flutter-3.47.2/bin/flutter ./tool/verify_flutter_version.sh
/tmp/flutter-3.47.2/bin/flutter pub get --enforce-lockfile
/tmp/flutter-3.47.2/bin/dart format --output=none --set-exit-if-changed lib test
/tmp/flutter-3.47.2/bin/flutter analyze
/tmp/flutter-3.47.2/bin/flutter test --coverage
/tmp/flutter-3.47.2/bin/flutter run
```

`flutter run` needs an Android or iOS development target configured on the
host. Local widget tests are host software evidence, not a physical-device test.

The Android debug and profile manifests declare `android.permission.INTERNET`
for Flutter development tooling. iOS development tooling may also use the local
network. Those tooling behaviors are separate from the fake demo's application
behavior. The current build gates are development builds and do not prove final
release permission configuration; release manifest and packaged-app permission
review remain open.

Android and iOS editable projects are committed. The companion CI workflow
will run quality checks, compile an Android debug APK, and compile an unsigned
iOS simulator app without executing a simulator. CI results are not claimed
until that workflow actually runs.

Windows and macOS desktop targets are not enabled yet. In the future, from
`app/` on appropriately configured hosts, enable them with:

```bash
flutter create --platforms=windows,macos .
```

Before enabling desktop targets, review the generated changes and retain the
pinned SDK and fake-only boundary.

## Accessibility evidence and gaps

Widget tests exercise semantic status labels, 48 logical-pixel action targets,
AA text/theme contrast calculations, logical Tab/Enter operation, a 320 logical
pixel layout at 200% text scaling, and reduced-motion behavior. Physical screen
reader, switch-control, platform high-contrast, and real-device usability tests
remain open.
