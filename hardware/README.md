# Dawn Dock hardware

## System block description

The normative editable system diagram, responsibility boundaries, provisional 5 V power allocation, and design gates live in [`docs/system-architecture.md`](../docs/system-architecture.md). The compact diagram below is only an overview.

```text
Certified USB 5 V supply
          |
          v
ESP32-S3 touch-display module ---- Wi-Fi/BLE ---- local companion app
   |       |       |       |
   |       |       |       +-- RTC / backup domain (to validate)
   |       |       +---------- audio output / alarm transducer
   |       +------------------ display and backlight control
   +-------------------------- carrier PCB
                                  |-- snooze button
                                  |-- brightness button
                                  |-- rotary encoder + push
                                  |-- ambient-light sensor
                                  |-- debug/programming and rail test points
```

The MVP is module-first to lower assembly risk. A custom KiCad carrier provides the physical controls, sensing, testability, mounting, and documented interconnect. It must not duplicate or modify mains power circuitry.

## Controller choice

The current candidate is the Waveshare `ESP32-S3-Touch-LCD-3.5` family because it integrates an ESP32-S3, 320×480 touch display, RTC, and audio support in one documented module. Selection is provisional. The backlog requires manufacturer schematic/datasheet review, exact variant identification, pinout validation, minimum-backlight testing, current measurement, and lifecycle/availability review before it can be locked.

A less-integrated ESP32-S3 module plus separate display remains the fallback if the candidate cannot dim sufficiently, exposes too few safe GPIOs, or has undocumented RTC/audio behavior.

## Interfaces

- USB 5 V power and USB serial/JTAG or documented programming path.
- GPIO/I²C for ambient-light sensor and tactile controls.
- GPIO/PWM or module audio interface for alarm tones with bounded gain/volume.
- Local Wi-Fi and/or BLE for pairing, schedule transfer, time sync, and diagnostics.
- Test points for input power, logic rails, ground, reset/boot, RTC bus, backlight, audio drive, and selected control signals.

## Power plan

- External certified 5 V USB supply only.
- The baseline device ceiling is 1.5 A (7.5 W) at 5 V with a certified external supply rated at least 2 A. This is a design allocation, not a module measurement.
- Measure module peak current with display, audio, Wi-Fi, and BLE active before sizing connector/protection and any carrier regulation.
- Add only datasheet-supported input protection/decoupling. Do not assume the development board's USB port may be back-powered through headers.
- Document brownout behavior and confirm alarms/config survive expected power loss.
- Validate any RTC backup cell holder and ensure no charging path is connected to a non-rechargeable cell.

## Enclosure and assembly concept

A two-piece printable enclosure holds the display at a readable bedside angle. The top/front exposes a large snooze control, separate brightness control, and rotary menu input by touch. Fasteners remain accessible; the module and carrier can be replaced independently. USB strain relief, speaker openings, sensor window, and ventilation are included in CAD after measurements.

The first assembled revision should use through-hole controls and module headers where practical. Fine-pitch reflow is deferred unless assembly-service requirements and inspection evidence are documented.

## Safety limits

- SELV/USB only; no mains, medical, fire, security, or life-safety use.
- Use enclosed certified power supplies and insulated assemblies.
- Do not describe an unassembled design as bench-tested.
- Limit acoustic output; prolonged loud sound near the bed is not an MVP goal.
- Keep the enclosure away from liquids and fabrics that block ventilation.

## Expected KiCad deliverables

Planned real editable sources:

- `hardware/kicad/dawn-dock.kicad_pro`
- `hardware/kicad/dawn-dock.kicad_sch`
- `hardware/kicad/dawn-dock.kicad_pcb`

Expected evidence includes symbol properties with manufacturer/MPN/source data, annotated schematic, named nets, power/protection, connectors, programming/debug, test points, board outline, placement/routing, ground strategy, mounting, silkscreen, ERC/DRC reports, BOM export, and fabrication outputs. These artifacts have not been created yet.

Requirements and their required evidence are tracked in [`hardware/requirements.md`](requirements.md) and [`docs/verification-matrix.md`](../docs/verification-matrix.md). The provisional module must pass issue #2 manufacturer-document and mechanical validation before schematic capture.
