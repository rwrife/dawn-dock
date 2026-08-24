# Dawn Dock hardware

## System block description

The normative editable system diagram, responsibility boundaries, provisional 5 V power allocation, and design gates live in [`docs/system-architecture.md`](../docs/system-architecture.md). The compact diagram below is only an overview.

```text
Certified USB 5 V supply
          |
          v
carrier USB-C + TVS + eFuse ---- +5V_SYS
          |                         |-- ESP32-S3 DevKitC-1-N8R8
          |                         |-- 3.5-inch SPI/I2C touch display
          |                         |-- I2S amplifier + 8-ohm speaker
          |                         +-- 3.3 V RTC/sensor/control domain
          |
          +-- snooze, brightness, encoder, test pads, mounting
```

The MVP is module-first to lower assembly risk, but the controller and display are separate replaceable modules. A custom KiCad carrier provides the physical controls, sensing, protected 5 V input, RTC backup, audio, testability, mounting, and documented interconnect. It contains no mains circuitry.

## Controller and component choice

The schematic-capture baseline is:

- Espressif `ESP32-S3-DEVKITC-1-N8R8` controller;
- Waveshare `29318` 3.5-inch capacitive-touch display;
- Analog Devices `DS3231MZ+` RTC with a replaceable Panasonic CR2032 and no charging path;
- Adafruit `3006` MAX98357A I2S amplifier and Waveshare `27859` 8-ohm/2-watt speaker;
- Adafruit `4162` VEML7700 ambient-light breakout;
- Omron `B3F-1000` switches and Bourns `PEC11R-4215F-S0024` encoder through a TI `SN74LVC14APWR` 5 V-tolerant Schmitt interface; and
- GCT `USB4105-GF-A`, LRC `LESD8LH5.0CT5G`, and TI `TPS259531DSGR` protected input path.

The integrated Waveshare `ESP32-S3-Touch-LCD-3.5` was reviewed and rejected because its fitted microphone conflicts with the microphone-free baseline. The source-backed comparison and remaining gaps are in [`docs/component-validation.md`](../docs/component-validation.md); the proposed GPIO/resource map is [`pin-allocation.csv`](pin-allocation.csv).

## Interfaces

- Protected carrier USB-C 5 V input plus service-only DevKit USB serial/JTAG.
- Shared 3.3 V I2C for touch, RTC, and ambient-light sensing, with address/pull-up review.
- SPI for display, I2S for audio, PWM for backlight, and individual GPIOs for controls.
- Local Wi-Fi and/or BLE for pairing, schedule transfer, time sync, and diagnostics.
- Named test pads for input power, logic rails, ground, reset/boot, RTC/I2C, backlight, audio drive, SPI, UART, and controls.

## Power plan

- External certified 5 V USB supply only; selected US planning part is Raspberry Pi `SC0218`.
- The baseline device ceiling is 1.5 A (7.5 W) at 5 V. This is a design allocation, not a measurement.
- The selected carrier input is GCT `USB4105-GF-A` -> LRC `LESD8LH5.0CT5G` -> TI `TPS259531DSGR` -> `+5V_SYS`. Use Yageo `RC0603FR-071K53L` at ILM: about 1.347 A nominal and a conservative combined upper estimate of about 1.463 A. Recalculate and review thermal/dV/dt details in the schematic.
- Measure peak current with display, audio, Wi-Fi, and BLE active before fabrication release; the present 1.05 A allocation is not a measurement and must remain at or below 1.125 A for 25% source headroom.
- Feed the DevKit 5 V header from the protected carrier rail. The official v1.1 schematic's USB Schottky is the documented anti-backfeed boundary; clone boards are not approved substitutions.
- Document brownout behavior and confirm alarms/config survive expected power loss.
- Keep the primary CR2032 completely isolated from any charging path and mark polarity/chemistry on silkscreen.

## Enclosure and assembly concept

A two-piece printable PETG enclosure holds the display at a readable bedside angle. The top/front exposes a large snooze control, separate brightness control, and rotary menu input by touch. Fasteners remain accessible; modules and carrier can be replaced independently. USB strain relief, speaker openings, sensor window, antenna clearance, battery access, and ventilation are included in CAD after measurements.

The first assembled revision should use through-hole controls and module sockets where practical. Fine-pitch reflow is limited to the protected-input eFuse and other parts whose footprints/layout follow manufacturer guidance.

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

Expected evidence includes symbol properties with manufacturer/MPN/source data, annotated schematic, named nets, power/protection, connectors, programming/debug, test points, board outline, placement/routing, ground strategy, mounting, silkscreen, ERC/DRC reports, BOM export, and fabrication outputs. These artifacts have not been created yet. `bom/preliminary-bom.csv` is planning input and is not the final KiCad-derived BOM.

Requirements and their required evidence are tracked in [`requirements.md`](requirements.md) and [`docs/verification-matrix.md`](../docs/verification-matrix.md). Issue #2 closes the source-review gate for schematic capture only; PCB outline, enclosure fit, and all physical performance still require later evidence.
