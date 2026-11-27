# Dawn Dock implementation plan

## Scope

Dawn Dock is a low-voltage, offline-first bedside clock. The MVP executes locally stored alarms without Wi-Fi and exposes essential controls physically. A companion app may later add reviewed schedule updates; it is not required for the standalone MVP. The project includes editable KiCad hardware, ESP-IDF firmware, a Flutter companion, protocol fixtures, BOM exports, bring-up documentation, and fabrication artifacts when mature.

### MVP cutline and closure gate

The first MVP is one usable, standalone bedside clock, not a complete mobile product or a production-ready release. It must show RTC-backed local time, retain and execute a user-configured recurring alarm with deterministic timezone/DST behavior while offline, and provide physical snooze/dismiss and brightness controls. Alarm evaluation and recovery must be safe across invalid time and reboot; stored schedules must not be silently erased or applied from an unreviewed source. Configuration may use a documented local service path until an on-device setup UI is implemented.

The phone/desktop companion, calendar import, pairing and network transport, remote updates, weather, production enclosure, manufacturing release, 100-cycle endurance, formal EMC/ESD qualification, and field testing are post-MVP. They must not be represented as delivered or as prerequisites for the standalone MVP. USB 5 V operation from a certified external supply, protected power, bounded audio, correct RTC backup-cell handling, and safe staged bench bring-up remain MVP requirements.

Close the MVP only after the editable prototype board has no unresolved build-blocking electrical/layout issue, at least one assembled device boots and keeps time, a recurring alarm rings and can be snoozed/dismissed with radios disabled, configuration and alarm state survive a controlled power cycle, and basic rail/current/temperature/audio checks are recorded with methods and results. Host tests, static checks, rendered artifacts, and simulations do not substitute for those bench results. A closed MVP is a prototype milestone, not a claim of production readiness or safety certification.

## Architecture

The normative v0.1 design baseline is split into reviewable sources:

- [`docs/system-architecture.md`](docs/system-architecture.md) — boundaries, editable block diagram, 5 V allocation, measurable targets, and open gates.
- [`docs/alarm-semantics.md`](docs/alarm-semantics.md) — deterministic state, DST/time-correction, duplicate-prevention, and reboot behavior.
- [`docs/threat-model.md`](docs/threat-model.md) — assets, trust boundaries, misuse cases, and required controls.
- [`docs/risk-register.md`](docs/risk-register.md) — owned likelihood/impact risks and verification gates.
- [`docs/verification-matrix.md`](docs/verification-matrix.md) — requirement-to-evidence traceability and evidence-class rules.

### Hardware

- **Controller/display selection:** Espressif `ESP32-S3-DEVKITC-1-N8R8` plus Waveshare `29318` display. The integrated microphone-equipped board was rejected; see `docs/component-validation.md`.
- **Carrier PCB:** protected power-only USB-C, DS3231MZ+ RTC/CR2032 backup, tactile snooze/brightness controls, rotary input, VEML7700 sensor, MAX98357A audio, debug/test pads, and mounting.
- **Power:** certified external 5 V USB supply; no mains circuitry. Carrier power budget, inrush, ESD, connector rating, and brownout behavior must be measured.
- **Timekeeping:** selected DS3231MZ+ with replaceable non-rechargeable CR2032 and no charge path; retention/drift remain bench gates.
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

1. **Requirements and risk baseline (v0.1 complete)** — alarm behavior, brightness/acoustic targets, 1.5 A power envelope, mechanical limits, threat model, risk register, privacy, accessibility, and safety exclusions are frozen. Component capability and all physical performance remain unverified.
2. **Component validation and architecture proof (static selection complete)** — manufacturer documents, comparison, GPIO map, dated sourcing snapshot, and physical evidence gaps recorded. Measurements remain in integration/bring-up.
3. **Editable KiCad carrier and BOM (schematic gate complete)** — editable schematic, native ERC, analyzer evidence, source-property BOM export, and review report are complete; PCB layout, DRC, cross-analysis, and fabrication evidence remain pending.
4. **Firmware core** — deterministic alarm engine, persistence, RTC/timezone handling, controls, UI, diagnostics, recovery, build/tests.
5. **Companion and protocol (post-MVP)** — pairing, local schedule model, diff/apply, import/export, accessibility, build/tests. None is needed to configure or operate the standalone MVP.
6. **MVP integration and bring-up** — assemble one prototype, verify the offline clock/alarm and controls, measure basic power/temperature/audio behavior, exercise reboot and DST cases, and document results and troubleshooting.
7. **Production/release readiness (post-MVP)** — enclosure completion, manufacturing/DFM sign-off, endurance/EMC/ESD and field evidence, signed/updateable packages, and release artifacts. Do not infer this readiness from MVP completion.

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

## Baseline change control

Changes to a frozen target update the system architecture, hardware requirements, verification matrix, and affected risk rows in the same PR. Every verification result identifies its evidence class; static/software evidence never substitutes for required bench or field evidence.
