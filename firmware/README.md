# Firmware plan

Status: plan only; no firmware source or build evidence exists yet.

## Responsibilities

- Maintain RTC/system time, timezone, DST data, and monotonic scheduling.
- Evaluate recurring alarms locally and implement ring, snooze, dismiss, timeout, and missed-alarm state transitions.
- Persist versioned alarms/settings safely across reboot and detect/rollback invalid updates.
- Render clock, next alarm, sync state, offline state, menu, and diagnostics.
- Read physical controls and ambient light; enforce user brightness overrides.
- Generate bounded alarm audio and expose explicit volume controls.
- Pair locally, authenticate sessions, preview/apply revisioned schedule changes, and emit sync receipts.
- Provide USB logs, diagnostics, factory reset, and recoverable flashing/update paths.

## Planned interfaces

- RTC and ambient-light devices via manufacturer-documented I²C interfaces.
- Display/touch/backlight and audio via the selected module's documented buses.
- GPIO for dedicated controls and status/test signals.
- Local HTTPS/WebSocket or BLE GATT transport behind a common protocol service.
- NVS/LittleFS storage behind a versioned repository API.

## Provisioning and updates

1. Initial firmware is flashed over USB with a pinned ESP-IDF toolchain.
2. First boot creates a unique device identity and opens a time-limited pairing flow.
3. Wi-Fi is optional; credentials, if stored, use ESP32 secure-storage facilities after threat review.
4. USB recovery remains the baseline. Signed local OTA may be added only after rollback and authenticity tests exist.
5. Factory reset clears pairing, network credentials, imported event data, and alarms only after physical confirmation.

## Test strategy

- Native host tests for recurrence rules, DST gaps/folds, snooze/dismiss, revision conflicts, malformed payloads, and configuration migration.
- Fake interfaces for RTC, storage, controls, display, audio, and transport.
- ESP-IDF builds with warnings treated as errors and reproducible version output.
- On-device tests for boot/recovery, 100 controlled power cycles, radio loss, clock retention, minimum brightness, control debounce, and audio limits.
- Record actual serial/build/test output. Static analysis, simulation, bench testing, and field testing are reported as separate evidence classes.
