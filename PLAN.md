# Dawn Dock implementation plan

## Scope

Dawn Dock is a low-voltage, offline-first bedside clock. The MVP executes locally stored alarms without Wi-Fi, exposes essential controls physically, and accepts reviewed schedule updates from a companion app. The project includes editable KiCad hardware, ESP-IDF firmware, a Flutter companion, protocol fixtures, BOM exports, bring-up documentation, and fabrication artifacts when mature.

## Architecture

### Hardware

- **Controller/display candidate:** Waveshare ESP32-S3-Touch-LCD-3.5 module, subject to datasheet and schematic review.
- **Carrier PCB:** tactile snooze/brightness controls, rotary input, ambient-light sensor, audio/power interconnect, debug/test points, mounting, and protected external interfaces.
- **Power:** certified external 5 V USB supply; no mains circuitry. Carrier power budget, inrush, ESD, connector rating, and brownout behavior must be measured.
- **Timekeeping:** validate the module RTC and backup implementation; add or substitute a documented external RTC only if requirements are not met.
- **Enclosure:** printable or laser-cut bedside enclosure with strain relief, ventilation, accessible controls, and serviceable fasteners.

### Firmware

- ESP-IDF tasks/components for time, timezone/DST, alarm evaluation, storage, UI, controls, audio, brightness, transport, update/recovery, and diagnostics.
- Alarm execution remains independent of companion or internet connectivity.
- Double-buffered/versioned configuration with validation and rollback.
- Host-testable domain logic for recurrence, DST edges, sync diffs, and protocol parsing.

### Companion app

- Flutter application targeting Android and iOS first, then Windows/macOS where CI permits.
- Local SQLite or structured file storage for paired devices, schedules, import provenance, and backups.
- Explicit pairing, schedule diff/review, `.ics` import, JSON export/restore, diagnostics, and local-only transfer.
- Platform adapters isolate BLE/LAN discovery, file picker, notifications, and optional calendar access.

### Protocol

- Versioned canonical JSON messages over authenticated local HTTPS/WebSocket or BLE GATT framing.
- Device-generated pairing secret/QR or short code; no factory default credential.
- Sequence/revision checks, size limits, validation, replay resistance, and user-visible sync receipts.
- The transport choice will be proven with a spike before freezing the API.

## Technology choices

- **ESP32-S3 / ESP-IDF:** mature networking, BLE, USB, secure storage primitives, and deterministic native builds.
- **KiCad:** open, editable design source and reproducible ERC/DRC/fabrication workflow.
- **Flutter/Dart:** shared accessible UI across mobile and desktop while retaining platform adapters.
- **JSON + JSON Schema:** inspectable protocol and backup format; compact binary transport can be considered later only with measured need.
- **LittleFS/NVS:** local device persistence with schema versioning; final partitioning follows measured data size and endurance analysis.

## Milestones and dependency order

1. **Requirements and risk baseline** — define alarm behavior, brightness, acoustic target, power budget, mechanical envelope, connectivity, privacy, and safety exclusions.
2. **Component validation and architecture proof** — collect manufacturer docs, compare display/RTC/audio options, measure module behavior, and record MPN/manufacturer fields.
3. **Editable KiCad carrier and BOM** — complete schematic, ERC, layout, DRC, source-property BOM export, and review evidence.
4. **Firmware core** — deterministic alarm engine, persistence, RTC/timezone handling, controls, UI, diagnostics, recovery, build/tests.
5. **Companion and protocol** — pairing, local schedule model, diff/apply, import/export, accessibility, build/tests.
6. **Integration and bring-up** — assemble, measure rails/current/audio/brightness/time retention, exercise offline and DST cases, and document troubleshooting.
7. **Fabrication/release** — verified Gerbers/drills/CPL where applicable, BOM, schematic PDF, renders, source archives, licenses, and release checklist.

## Testing strategy

### Static and simulation

- KiCad ERC/DRC, schematic/PCB analyzers, BOM field/footprint checks, and protocol schema tests.
- Circuit simulation only where models are meaningful; label simulation separately from bench results.

### Firmware

- Host unit tests for recurrence, snooze/dismiss state, timezone/DST transitions, malformed configuration, revision conflicts, and offline reboot behavior.
- ESP-IDF build matrix and hardware-abstraction fakes for RTC, storage, controls, audio, display, and transport.
- On-device integration tests with captured logs and repeatable flashing/recovery instructions.

### Companion

- Dart unit tests for schedule diffing, `.ics` normalization, backup migration, and protocol framing.
- Widget/accessibility tests for dynamic text, screen readers, focus order, contrast, reduced motion, and touch target sizing.
- Android/iOS builds; Windows/macOS builds once supported runners and signing boundaries are documented.

### Physical verification

- Measure 5 V and regulated rails, idle/peak current, brownout recovery, RTC retention/drift, minimum/maximum luminance, control debounce, audio output, Wi-Fi/BLE recovery, enclosure temperature, and alarm behavior after network loss.
- Distinguish untested, static-checked, simulated, bench-tested, and field-tested claims in every report.

## Packaging and distribution

- Firmware: reproducible versioned binaries, checksums, flash manifest, serial recovery path, and optional signed OTA only after threat review.
- Companion: unsigned development artifacts first; later Android APK/AAB, iOS archive instructions, Windows package, and macOS app bundle subject to platform signing requirements.
- Hardware: editable KiCad source plus fabrication ZIP, BOM/CPL, schematic PDF, assembly drawings, and enclosure source.
- Licensing target: permissive software license and OSHWA-compatible hardware documentation license, finalized before the first release.

## Risks and mitigations

- **Display too bright at night:** measure minimum luminance early; support manual blackout and hardware backlight control; swap module if minimum is unacceptable.
- **RTC/module documentation mismatch:** do not assume board-level pinout or backup behavior; verify against manufacturer schematic/datasheets and bench measurements.
- **Missed alarm after corruption or DST change:** deterministic state machine, redundant validated configuration, explicit timezone data, regression fixtures, watchdog/brownout tests, and visible next-alarm status.
- **Local pairing attack:** no default password, short pairing window, authenticated encryption, revision/nonce checks, and local reset path.
- **Calendar ambiguity/privacy:** import only selected data, show every proposed alarm, store minimal fields, and require confirmation.
- **Supply-chain changes:** use schematic MPN/manufacturer properties, alternatives only after pinout/package validation, and re-check lifecycle/stock before orders.
- **Scope creep into smart display:** enforce the non-goals and keep weather/news outside the alarm-critical path.

## Explicit non-goals

Voice assistants, cameras, cloud accounts, remote surveillance, medical/emergency use, battery-powered primary operation, mains design, automatic unreviewed calendar alarms, and broad smart-home control are outside the MVP.
