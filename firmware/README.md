# Dawn Dock firmware

Status: executable ESP-IDF scaffold plus host-tested offline alarm occurrence, committed-schedule evaluation with active lifecycle orchestration, atomic schedule/runtime-journal storage, weekly local-calendar recurrence cores, and a transport-neutral protocol-envelope preflight validator with canonical contract fixtures. No firmware has been flashed to physical hardware, and no ESP-IDF NVS adapter, RTC, display, controls, audio, authenticated transport session, or IANA timezone-rule data adapter is implemented yet.

Normative behavior and boundaries remain in [`docs/alarm-semantics.md`](../docs/alarm-semantics.md), [`docs/system-architecture.md`](../docs/system-architecture.md), and [`docs/threat-model.md`](../docs/threat-model.md). Tests trace to [`docs/verification-matrix.md`](../docs/verification-matrix.md).

## Implemented slice

`components/alarm_core` is a pure C++ component shared by the native host test and ESP-IDF builds. It currently implements:

- deterministic occurrence IDs from alarm ID, committed revision, and resolved UTC instant;
- journal-before-side-effect admission and duplicate suppression for active/terminal occurrences;
- the frozen late-ring boundary (9:59 and 10:00 ring late; 10:01 is missed);
- 1–30 minute snooze validation, 9-minute default, monotonic deadlines, and six-snooze maximum;
- rejection of stale dismiss IDs and repeated snooze edges;
- durable dismiss and 60-minute monotonic timeout outcomes;
- oldest-first bounded retention of 32 recent terminal diagnostic records;
- duplicate prevention via scheduled-UTC terminal high-watermarks for up to 32
  distinct alarm IDs;
- reboot recovery once per boot inside the original wall lifetime, snooze cancellation, and prolonged-power-off `Missed` classification.

The caller must persist `PersistentAlarmState` atomically before acting on any result with `persist_before_effects=true`. The 32 recent terminal records are diagnostic history and may be evicted, while a separate index retains the greatest terminal scheduled UTC instant for each of at most 32 distinct alarm IDs. For a tracked alarm ID, any occurrence at or below that high-watermark remains duplicate-suppressed after diagnostic compaction; a later scheduled instant can be admitted. When all 32 alarm-ID slots are occupied, an occurrence for a new alarm ID fails closed with `conflict` rather than being admitted without durable duplicate protection. This bound assumes scheduled UTC instants for a given alarm ID advance over time; intentionally reusing an alarm ID for an earlier instant remains suppressed. Recurrence/timezone resolution remains outside this component.

`AtomicScheduleStore` persists the complete schedule and occurrence journal through a two-slot `SlotStorage` abstraction:

- each schema-v2 record carries magic, schema version, monotonically increasing storage generation, payload length, and CRC32 over all selection metadata plus payload;
- snapshots are bounded to 64 KiB, 32 alarms, bounded identifiers, 32 recent terminal outcomes, and 32 terminal high-watermarks;
- `save` holds a backend-wide exclusive transaction across both-slot inspection, compare-and-swap schedule revision checks, opposite-slot replacement, re-read, and semantic equality validation;
- schedule updates carry forward the transaction's freshly loaded occurrence journal, so a concurrent due-occurrence commit cannot be erased by a stale schedule payload;
- `save_occurrence_state` advances storage generation without changing the user-visible schedule revision, requires both revision and generation CAS, and returns distinct revision/generation conflicts;
- exact schedule and runtime retries after a lost acknowledgement accept only the immediately following committed generation and return no-write `unchanged`, reducing flash wear without masking different stale updates;
- a corrupt newest slot visibly falls back to the last-known-good generation; equal-generation divergent records, wholly corrupt stores, and intact newer schemas fail closed;
- schema v1 loads with an explicit `legacy-v1-unpinned` timezone marker and can be atomically migrated to v2 without overwriting its rollback slot.

CRC32 detects accidental corruption; it is not authentication. The eventual ESP-IDF backend must provide one exclusive transaction across all store instances, tri-state reads, and atomic replacement per slot (for example, independent NVS blobs); that binding remains unimplemented. These host fault-injection tests do not prove flash endurance, brownout behavior, or physical power-cycle retention.

`evaluate_committed_schedule` is the storage-backed boundary for already-resolved UTC occurrences. It loads one last-known-good snapshot, sorts definitions by scheduled UTC instant and alarm ID, evaluates them against a private copy of the durable journal, and commits each missed/active transition with revision and generation CAS. It returns an alert edge only after that journal commit succeeds. A competing schedule update suppresses the stale edge and returns the newer generation; an identical concurrent admission is returned as a no-effect duplicate rather than a second alert start. Backend write/verification failure also suppresses effects while leaving `persist_before_effects` visible to diagnostics, and unrepresentable wall-time arithmetic stops the entire pass before later alarms are considered.

This evaluator intentionally consumes the UTC instants currently stored in `ScheduleSnapshot`; it does not yet compute those records from weekly recurrence rules or reconcile an invalid-time interval with multiple crossed occurrences. Active snooze/timeout progression and reboot recovery now run through the same persisted evaluator path before exposing alert edges. The test suite is host software evidence only, not ESP32 target or physical alarm evidence.

`resolve_next_occurrence` computes the next weekly occurrence strictly after a UTC anchor from local hour/minute, an ISO weekday mask, and an explicitly named/versioned rule set supplied by an adapter. The pure resolver:

- selects weekdays from the alarm's local calendar rather than UTC;
- crosses month and year boundaries deterministically;
- shifts a spring-gap alarm once to the earliest valid local instant on that date and marks `shifted_for_gap`;
- chooses the first UTC instant in a fall fold, marks `ambiguous_fold`, and never selects the second fold instant as a separate v1 occurrence;
- rejects mismatched timezone name/version provenance, malformed transition chains, invalid wall times/weekday masks, impossible offsets, and unrepresentable epoch arithmetic.

Host fixtures cover the 2026 spring and fall transitions for `America/New_York` and `Europe/Berlin`, plus the fully skipped 2011-12-30 local date in `Pacific/Apia`. `timezone_fixture_reference_tests` reproducibly checks their UTC mappings against the runner's installed IANA `zoneinfo` database. The checked-in firmware does **not** yet carry or update a complete IANA timezone database, and the host database is reference evidence rather than the firmware's pinned data source. The future adapter must provide immutable rule transitions for the schedule's stored version; these tests are software evidence, not target or RTC behavior.

`protocol_service` adds a transport-neutral preflight gate for parsed envelopes before any schedule mutation path runs. The validator enforces the `dawn-dock/1` major protocol string, known message types, strict UTC RFC3339 timestamps, bounded message-ID charset/length, mandatory `expectedRevision` on schedule preview/apply, and a 64 KiB serialized-envelope ceiling. A bounded replay window rejects duplicate message IDs without blocking alarm evaluation internals. Canonical valid/invalid fixtures now live under `docs/protocol/fixtures/v1/`, and `protocol_fixture_contract_tests` verifies expected accept/reject codes against that shared fixture manifest.

## Pinned toolchain

- ESP-IDF release: `v5.5.5` (`.idf-version`)
- Target: `esp32s3` (`sdkconfig.defaults`)
- Reproducible container: `firmware/Dockerfile.verify`
- Immutable multi-architecture OCI index: `sha256:a9231d0697ab8f7517cc072e93b7c83e04907bfbfba80b6440d7dbbf90665cf2`

The index lock selects the corresponding official linux/amd64 or linux/arm64 image without relying on a mutable tag at build time.

## Host build and tests

CMake 3.20+ and a C++20 compiler are required. Ninja is optional.

```bash
cmake -S firmware/host -B build/firmware-host -G "Unix Makefiles"
cmake --build build/firmware-host --parallel
ctest --test-dir build/firmware-host --output-on-failure
```

These are **software tests**, not target or bench evidence.

## Reproducible ESP32-S3 build

```bash
docker build -t dawn-dock-idf-verify \
  -f firmware/Dockerfile.verify firmware

docker run --rm \
  -v "$PWD:/project" -w /project/firmware \
  dawn-dock-idf-verify \
  idf.py set-target esp32s3 build
```

A successful build emits `firmware/build/dawn_dock_firmware.bin`. Build output and generated `sdkconfig` are ignored; release artifacts and checksums will be produced only by the release workflow in issue #7.

For a native ESP-IDF 5.5.5 installation, the equivalent is:

```bash
cd firmware
idf.py set-target esp32s3
idf.py build
```

## Flash, monitor, erase, and recovery

The following commands are documented but **not yet exercised on Dawn Dock hardware**. Set `PORT` to the identified DevKit USB serial device.

```bash
export PORT=/dev/ttyACM0

docker run --rm -it --device "$PORT:$PORT" \
  -v "$PWD:/project" -w /project/firmware \
  dawn-dock-idf-verify idf.py -p "$PORT" flash monitor

# Exit the monitor with Ctrl-].
docker run --rm --device "$PORT:$PORT" \
  -v "$PWD:/project" -w /project/firmware \
  dawn-dock-idf-verify idf.py -p "$PORT" erase-flash
```

Recovery baseline:

1. Disconnect external modules if a short or back-power condition is suspected; use only USB 5 V SELV power.
2. Hold the DevKit BOOT control while pressing/releasing RESET to enter the ROM download path.
3. Confirm the serial port, run `erase-flash` only when destructive reset is intended, then flash the pinned build.
4. Capture the complete serial log and reset cause. Do not claim recovery, rollback, or schedule preservation until storage exists and this procedure is exercised on identified hardware.

## Still open in issue #5

- ESP-IDF rule-data adapter carrying a pinned IANA database and integration of weekly recurrence output into stored UTC occurrences;
- RTC validity/correction reconciliation and multiple crossed occurrences;
- ESP-IDF NVS slot adapter, brownout/flash fault behavior, and 100-cycle physical persistence evidence;
- hardware-abstraction interfaces and real RTC/display/backlight/control/sensor/audio integration;
- authenticated transport/session implementation, device provisioning flow, bounded diagnostics plumbing, factory reset execution path, and update rollback;
- formatter/static-analysis policy beyond compiler warnings;
- target execution, hardware-in-the-loop, power-cycle, radio-loss, RTC retention, brightness, debounce, audio, thermal, and long-duration alarm evidence.

Optional networking must remain outside the alarm-critical path. The core must continue to evaluate committed alarms and physical actions with radios disabled.
