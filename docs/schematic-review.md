# Rev A carrier schematic static review

**Date:** 2026-08-25
**Evidence class:** static analysis and datasheet cross-check only
**Artifact:** `hardware/kicad/dawn-dock.kicad_sch`
**Verdict:** passes the issue #3 schematic/ERC/BOM gate; not PCB-ready, fabrication-ready, or bench-tested

## Executive result

- Native KiCad 9.0.2 ERC: **0 errors, 0 warnings**.
- Project validation: **pass** — 71 analyzed components, 66 nets, 36 required nets, 17 critical pin mappings, and a 32-row/37-component KiCad-derived BOM.
- Component sourcing: all active and DNP electrical BOM rows have Manufacturer, MPN, supplier/source, supplier identifier, datasheet/source URL, dated estimated unit cost, and notes.
- DNP policy: only the two optional 4.7 kΩ carrier I²C pull-ups (`R8,R9`) are DNP. The display and ambient sensor modules already contain bus pull-ups; measured aggregate resistance/rise time is the population gate.
- Physical tests: **none**. No prototype, PCB, DRC, instrument reading, photo, thermal run, EMC run, audio result, luminance result, or RTC-retention result exists.

## Sources and pin-level checks

| Part/block | Ground truth | Static check performed | Result / limit |
|---|---|---|---|
| TI `TPS259531DSGR` | [SLVSE57C](https://www.ti.com/lit/ds/symlink/tps2595.pdf), pin functions p. 4; application equations pp. 20–21 | Custom symbol maps dVdt=1, EN/UVLO=2, IN=3/4, OUT=5, FLT=6, ILM=7, GND=8/EP. `R3=1.53 kΩ`; `C3=100 nF`. | Equation 4: `2000/1530 + 0.04 = 1.347 A` nominal. Documented +7.5% limit/-1% resistor bound: `1.463 A`, below 1.5 A. Equation 3: about `0.42 V/ms`, or `11.9 ms` to 5 V. Fitted 480 µF gives about 202 mA modeled capacitive ramp current; module capacitance remains unknown. |
| Analog Devices `DS3231MZ+` | [DS3231M datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/DS3231M.pdf), SO-8 pin description and typical operating circuit | Standard KiCad DS3231M SO-8 symbol; VCC at +3.3 V, I²C bus at +3.3 V, open-drain INT/SQW with 10 kΩ pull-up, RST and 32 kHz NC. | `VBAT_RTC` analyzer net has exactly `U1.6` and `BT1.1`. Battery negative is GND. No resistor, diode, regulator, or main-power rail connects to VBAT. Primary CR2032 is explicitly marked **DO NOT CHARGE**. |
| TI `SN74LVC14APWR` | [SCAS295](https://www.ti.com/lit/ds/symlink/sn74lvc14a.pdf), pin functions p. 4 and recommended conditions | Custom symbol follows TSSOP-14 pin map. Five gates translate separately wetted snooze, brightness, encoder A/B, and encoder switch contacts. Sixth input is tied to GND; unused output NC. | VCC is +3.3 V. Each contact is fed from protected +5 V and uses its own 4.7 kΩ series/pull path, so no unpowered high input is created by a shared resistor. Firmware debounce remains required. |
| Espressif `ESP32-S3-DEVKITC-1-N8R8` | [DevKitC-1 v1.1 guide](https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide_v1.1.html) and linked schematic | Custom 2×22 header symbol/footprint uses official J1/J3 pin names. Application mappings match `hardware/pin-allocation.csv`. | GPIO35–37 (N8R8 memory), strap GPIO3/45/46, onboard RGB GPIO38, and native USB GPIO19/20 have no application loads. GPIO0 and EN have named service test access. |
| GCT `USB4105-GF-A` | [USB4105 drawing](https://gct.co/files/drawings/usb4105.pdf) | Standard matching KiCad USB4105 16-pin footprint and USB-C USB2 symbol. | Independent 5.1 kΩ CC1/CC2 Rd; VBUS TVS and eFuse; D+/D-/SBU NC; shield grounded. This is power-only, 5 V SELV. |
| Waveshare `29318` | [Manufacturer wiki](https://www.waveshare.com/wiki/3.5inch_Capacitive_Touch_LCD), interface section | Captures the published SPI display, I²C touch, touch reset/interrupt, backlight, and microSD CS signal set. | 5 V module input; 3.3 V logic. The exact received 15-pin socket orientation/revision remains a mandatory check before PCB placement/fabrication because the physical numbering is image-only. |
| Adafruit `3006` | [Product guide](https://www.adafruit.com/product/3006) | VIN=+5 V, I²S BCLK/LRC/DIN from GPIO16/17/18, SD on GPIO40 with 100 kΩ default-off pulldown, differential speaker output. | No microphone path. Gain is left at module default. Volume, SPL, distortion, and heating require the final speaker/enclosure bench test. |
| Adafruit `4162` | [Product pinout](https://learn.adafruit.com/adafruit-veml7700/pinouts) | Powered from +3.3 V and shares I²C. | The breakout exposes VIN, 3Vo, GND, SCL, and SDA only; it does **not** expose VEML7700 INT. `GPIO1/J3-4` is therefore NC and reserved rather than connected to a fictitious `ALS_INT` test point. |
| Bourns `PEC11R-4215F-S0024` | [PEC11R datasheet](https://www.bourns.com/docs/product-datasheets/pec11r.pdf) | A/common/B and switch contacts map to separate Schmitt channels; project footprint includes shaft tabs. | 24 pulse/24 detent selection retained. Mechanical orientation, knob/shaft fit, and enclosure clearance remain issue #4 checks. |
| Keystone `3003` + Panasonic CR2032 | [Keystone drawing](https://www.keyelco.com/product.cfm/product_id/140) and selected cell source | Project footprint models retainer contacts plus PCB negative contact; schematic battery component is primary-cell only. | Footprint polarity, solder mask, cell insertion/retention, and service access must be checked against the received retainer before fabrication. |

## Power and signal topology

`USB-C VBUS → TVS → TPS259531 input/current limit/soft-start → +5V_SYS`.

`+5V_SYS` supplies the DevKit 5 V header, display, MAX98357A module, and wetted controls. The DevKit’s official onboard regulator supplies `+3V3`, which powers DS3231M, VEML7700 module, LVC14, I²C pull-ups, and open-drain pull-ups. The schematic does not expose or connect any mains voltage.

The display/touch/SD paths are SPI/I²C plus explicit `TFT_CS`, `TFT_DC`, `TFT_RST`, `TP_INT`, `TP_RST`, `LCD_BL`, and `SD_CS`. Audio is I²S plus hardware-default-off `AMP_SD`. Named test points cover rails, GND, reset/boot, RTC/I²C, display SPI/control, I²S, speaker outputs, controls, UART, and eFuse fault.

## Automated analysis and false-positive triage

The committed analyzer output contains 26 findings: 23 information and three `VM-001` errors.

The three `VM-001` reports (`I2C_SDA`, `I2C_SCL`, and `RTC_INT_N`) are classification false positives, not 5 V drivers:

1. The analyzer infers the entire display module domain from its +5 V supply even though the Waveshare interface is level-converted and documented for 3.3 V logic.
2. The ESP32 DevKit consumes +5 V but its exposed GPIO domain is its onboard +3.3 V rail.
3. DS3231M and the RTC interrupt pull-up are both physically powered from +3.3 V.
4. The VEML7700 breakout is physically powered from +3.3 V.
5. No 5 V pull-up or output pin is present on any of these three nets.

Native KiCad ERC, which evaluates the actual pin types and connections, reports 0 errors and 0 warnings. The exceptions are documented rather than hidden or downgraded in generated analyzer data.

Other informational analyzer notes are retained. In particular, lifecycle audit and structured datasheet extraction were not run; the generic analyzer labels the eFuse as an LDO and cannot identify module-internal ESD/level shifting. Those limitations do not replace the manual source checks above.

## BOM review

`bom/bom.csv` is exported directly from KiCad symbol properties and is the electrical source BOM. `bom/preliminary-bom.csv` remains selection history. `bom/non-schematic-items.csv` separately tracks enclosure, USB supply/cable, fasteners, consumables, and other non-schematic purchasing items.

The prices are dated planning observations from 2026-08-23. No present or future stock claim is made. Recheck price, stock, lifecycle, package, and received-module revision immediately before purchase. The design remains over the USD 75 target based on the prior planning snapshot.

## Not performed / limits

- PCB analyzer, schematic/PCB cross analysis, PCB EMC analysis, PCB thermal analysis, DRC, Gerber analysis, assembly checks, and fabrication exports: **not applicable yet because no PCB exists**.
- SPICE: not run; no validated vendor model set was available. The eFuse arithmetic is a static datasheet-equation calculation, not simulation.
- Lifecycle distributor audit: not run; no distributor API credentials were available and no current stock claim is made.
- Structured datasheet extraction cache: not built. Critical pin/equation checks were made manually from manufacturer PDFs/pages; analyzer trust remains low for automatic datasheet-backed claims.
- Bench/field tests: none. All rail, current, inrush, brownout, control, display, touch, sensor, audio, RTC, RF, thermal, ESD/EMC, mechanical, and long-duration criteria remain open.

## Evidence artifacts

- `hardware/kicad/reports/erc.rpt`
- `hardware/kicad/reports/schematic-analysis.json`
- `hardware/kicad/reports/schematic-analysis.txt`
- `hardware/kicad/reports/hardware-validation.json`
- `hardware/kicad/reports/dawn-dock-schematic.pdf`
- `bom/bom.csv`
