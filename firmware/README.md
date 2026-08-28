# Dawn Dock firmware

Status: executable ESP-IDF scaffold plus a host-tested offline alarm occurrence core. No firmware has been flashed to physical hardware, and no RTC, display, controls, audio, storage, transport, or timezone adapter is implemented yet.

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

The caller must persist `PersistentAlarmState` atomically before acting on any result with `persist_before_effects=true`. The 32 recent terminal records are diagnostic history and may be evicted, while a separate index retains the greatest terminal scheduled UTC instant for each of at most 32 distinct alarm IDs. For a tracked alarm ID, any occurrence at or below that high-watermark remains duplicate-suppressed after diagnostic compaction; a later scheduled instant can be admitted. When all 32 alarm-ID slots are occupied, an occurrence for a new alarm ID fails closed with `conflict` rather than being admitted without durable duplicate protection. This bound assumes scheduled UTC instants for a given alarm ID advance over time; intentionally reusing an alarm ID for an earlier instant remains suppressed. Storage serialization, last-known-good rollback, and recurrence/timezone resolution remain outside this component.

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

- recurrence across calendar boundaries and IANA timezone/DST gap/fold resolution;
- RTC validity/correction reconciliation and multiple crossed occurrences;
- versioned atomic storage, migration, corruption rollback, wear bounds, and 100-cycle persistence fixtures;
- hardware-abstraction interfaces and real RTC/display/backlight/control/sensor/audio integration;
- authenticated revisioned protocol, provisioning, diagnostics, factory reset, and update rollback;
- formatter/static-analysis policy beyond compiler warnings;
- target execution, hardware-in-the-loop, power-cycle, radio-loss, RTC retention, brightness, debounce, audio, thermal, and long-duration alarm evidence.

Optional networking must remain outside the alarm-critical path. The core must continue to evaluate committed alarms and physical actions with radios disabled.
