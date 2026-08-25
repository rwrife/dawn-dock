# Component validation and Rev A selection

Issue: [#2](https://github.com/rwrife/dawn-dock/issues/2)

Decision date: 2026-08-23 UTC

Decision state: **approved for schematic capture; not approved for fabrication or a hardware-test claim**

## Decision summary

Rev A will use a separated, microphone-free controller/display architecture:

- **Controller:** Espressif `ESP32-S3-DEVKITC-1-N8R8` (8 MB flash, 8 MB octal PSRAM).
- **Display/touch:** Waveshare `3.5inch Capacitive Touch LCD`, SKU `29318` (ST7796S over SPI and FT6336U over I2C).
- **RTC:** Analog Devices/Maxim `DS3231MZ+` with a Panasonic `CR2032` primary cell in a Keystone `3003` holder. There is intentionally **no charge path** to the CR2032.
- **Audio:** Adafruit `3006` MAX98357A I2S class-D breakout driving Waveshare `8ohm 2W Speaker (B)`, SKU `27859`.
- **Controls:** two Omron `B3F-1000` tactile switches and one Bourns `PEC11R-4215F-S0024` rotary encoder with push switch, conditioned through a TI `SN74LVC14APWR` 5 V-tolerant Schmitt interface. The enclosure makes the snooze surface substantially larger than the brightness control.
- **Ambient light:** Adafruit `4162` VEML7700 breakout on the shared 3.3 V I2C bus.
- **Power input:** carrier-board `USB4105-GF-A` power-only USB-C receptacle, two independent Yageo `RC0603FR-075K1L` 5.1 kΩ CC sink resistors, LRC `LESD8LH5.0CT5G` VBUS TVS, and TI `TPS259531DSGR` eFuse with Yageo `RC0603FR-071K53L` 1.53 kΩ ILM resistor. The calculated nominal limit is about 1.347 A and a conservative combined upper estimate is about 1.463 A.
- **External supply/cable:** Raspberry Pi `SC0218` 15 W US USB-C supply with captive 1.5 m cable; regional variants require a separate orderable MPN and a compliance review.
- **Enclosure:** two-piece printed PETG prototype with a display bezel, speaker grille, ambient-light aperture, oversized snooze plunger, separate brightness actuator, encoder opening, rear power inlet, battery service access, and hidden service-only DevKit USB ports.

This split architecture costs more than the integrated candidate, but it avoids installing an unwanted microphone, uses manufacturer-controlled controller documentation, exposes the required GPIO/test points, and lets the carrier schematic control RTC backup, power protection, and audio loading.

## Why the integrated candidate was rejected

The Waveshare `ESP32-S3-Touch-LCD-3.5`, SKU `30733`, remains a useful comparison board. Its manufacturer schematic confirms an ESP32-S3, ST7796 display, FT6336 touch controller, PCF85063 RTC, AXP2101 PMIC, ES8311 codec, NS4150B amplifier, USB ESD diode, and a 2x16 expansion header. Its 2026-08-23 product page listed a one-unit price of $25.99 and an orderable SKU.

It was rejected as the Rev A baseline for three reasons:

1. **Privacy conflict:** the board contains a fitted analog MEMS microphone (`MIC1`). Dawn Dock's baseline explicitly excludes a microphone. Firmware-disable is not equivalent to absence, and production rework to depopulate the part would be difficult to verify consistently.
2. **Mechanical/source-control gap:** the available board-level schematic and raster dimension drawings are useful, but no dimension-controlled STEP model or lifecycle/PCN commitment was found. The carrier would depend on one module vendor and revision.
3. **Test/power limits:** the expansion header exposes useful signals, but the backlight node is not on that header, and the product documentation does not specify full-board peak input current, minimum nighttime luminance, or RTC holdover for the exact board/battery path.

No claim is made that the integrated board is electrically defective. It is rejected because its installed hardware and evidence package do not fit Dawn Dock's privacy and verification requirements.

## Compatibility, package, lifecycle, and availability review

| Selected item | Electrical/current review | Package/mechanical review | Temperature/lifecycle review | Availability observed 2026-08-23 | Gate carried forward |
|---|---|---|---|---|---|
| ESP32-S3-DEVKITC-1-N8R8 | Protected 5 V feeds the board's `5V` header; GPIOs are 3.3 V; complete board peak current is not specified | Official v1.1 two-row header map and dimensional drawing reviewed | WROOM module limits are published; no separate DevKit assembly range or PCN commitment was found; Espressif lists the exact order code | Authorized-distributor listings were orderable from $13.9579 | Received revision, antenna clearance, full-load current, and thermal test |
| Waveshare 29318 display | 3.3 V/5 V module; SPI and I2C level translation; independent backlight input; no full-white maximum current published | Manufacturer raster drawing and 15-pin interface reviewed; exact connector seating remains sample-dependent | ST7796S/FT6336U IC data exist; Waveshare does not publish an assembly operating-temperature or longevity program | Manufacturer listed orderable at $18.99 | Measure dimensions, connector orientation, current, luminance, and viewing quality |
| DS3231MZ+ / CR2032 / Keystone 3003 | RTC VCC/VBAT domains and switchover documented; primary cell has no charge path | 8-SOIC RTC and through-hole 20 mm cell holder drawings available | RTC is -40 °C to +85 °C and active; battery/holder ratings cover indoor target but battery shelf life must be checked at purchase | RTC/holder/battery listings were orderable; RTC budgeted at $5.50 | Polarity/clearance check, 24 h holdover, drift, and replacement test |
| Adafruit 3006 / Waveshare 27859 | 2.7-5.5 V MAX98357A path; selected 8-ohm/2-watt load is within the documented 4-8 ohm class | Breakout headers and PH1.25 speaker cable documented; enclosure acoustic volume unknown | IC limits are published; breakout/speaker assembly range and product-lifetime guarantee are not | Manufacturer pages listed both products; $5.95 and $1.99 | Measure peak current, SPL, distortion, temperature, and safe maximum volume |
| Adafruit 4162 / VEML7700 | 3.3 V supply and I2C address 0x10; breakout pull-ups enter the bus calculation | Breakout/connector drawings published; optical opening remains CAD-dependent | VEML7700 IC is rated beyond 10-35 °C; breakout longevity program not published | Manufacturer listed in stock at $4.95 | I2C rise-time, sensor placement, lux correlation, and display-leakage test |
| B3F-1000 / PEC11R / SN74LVC14APWR | Contacts are wetted at 5 V through 4.7 kΩ; 3.3 V LVC14A accepts 5 V inputs; contact outputs do not drive ESP32 pins directly | Through-hole controls plus TSSOP-14 buffer; knob and plunger clearances remain CAD items | B3F/PEC11R/LVC14A ranges cover indoor use; LVC14A is active; mechanical wear remains a prototype test | All three were listed in stock; lower-bound prices $0.093, $1.6301, and $0.1498 | Verify contact network, debounce, force, latency, and no-tip behavior |
| USB4105-GF-A / TPS259531DSGR / LESD8LH5.0CT5G | 5 V power-only sink; 5 A connector collective rating; adjustable eFuse; TVS at the inlet; 1.5 A product ceiling | Top-mount USB-C with shell tabs; WSON exposed-pad thermal layout is mandatory | GCT/TI list current products; TVS vendor data exist but require procurement recheck | All were listed orderable; eFuse snapshot showed 276 units | Calculate CC/ILIM/capacitors, review ESD return, verify inrush/clamp/thermal behavior |
| SC0218 supply | 5.1 V, 3 A source capacity; carrier eFuse, not adapter rating, sets the product ceiling | US wall adapter with captive 1.5 m USB-C cable | Official product brief/compliance portal available; markings on the received regional unit remain controlling | Multiple authorized sellers listed the US order code; budgeted at $12 | Verify received marks/order code, output droop, cable loss, and regional suitability |

Module and breakout vendors generally do not publish component-style longevity commitments. “Listed/orderable” is therefore a dated sourcing observation, not a future-availability claim.

## Controller and display review

### ESP32-S3-DEVKITC-1-N8R8

Manufacturer evidence confirms:

- exact ordering code `ESP32-S3-DEVKITC-1-N8R8`;
- `ESP32-S3-WROOM-1-N8R8` module with 8 MB quad flash and 8 MB octal PSRAM;
- two 22-pin 2.54 mm headers with the official J1/J3 mapping;
- USB-to-UART and native USB interfaces;
- three documented, mutually exclusive board-power methods; and
- a v1.1 schematic showing Schottky isolation (`D1`, `1N5819HW-7-F`) between USB VBUS and the board `VCC_5V` rail.

The carrier feeds the DevKit through its 5 V header. The carrier USB-C is the deployed power input. The DevKit USB-to-UART connector is a service/programming port; the onboard Schottky isolates its VBUS from a powered carrier. Do not connect any other 5 V source to the 5 V header.

The selected N8R8 variant uses octal PSRAM. GPIO35 through GPIO37 are therefore treated as unavailable. GPIO0, GPIO3, GPIO45, and GPIO46 remain unallocated because of boot/strapping behavior. GPIO19/GPIO20 remain reserved for native USB; GPIO43/GPIO44 remain reserved for UART0. The full assignment is in [`hardware/pin-allocation.csv`](../hardware/pin-allocation.csv).

### Waveshare 3.5inch Capacitive Touch LCD, SKU 29318

Manufacturer evidence confirms:

- 320 x 480 IPS panel;
- ST7796S display controller over 4-wire SPI;
- FT6336U capacitive-touch controller over I2C;
- 3.3 V or 5 V module supply;
- active display area 48.96 x 73.44 mm;
- module dimensions 61.00 x 92.44 mm; and
- separately accessible `LCD_BL`, `TP_INT`, and `TP_RST` signals.

The carrier powers the display from protected 5 V and uses only 3.3 V MCU logic. `LCD_BL` receives a dedicated PWM GPIO and a named test pad. The microSD `SD_CS` line is routed and held inactive unless firmware explicitly enables removable storage.

The manufacturer does not publish minimum luminance, contrast at the planned minimum PWM duty, full-white current, or a quantified display lifetime for this assembly. Those remain bench/field gates.

## RTC and backup-domain validation

`DS3231MZ+` is an active, orderable 8-SOIC RTC with an internal MEMS resonator, battery switchover, I2C up to 400 kHz, 2.3 V to 5.5 V supply operation, -40 °C to +85 °C operation, and a published ±5 ppm accuracy class. It avoids an external 32.768 kHz crystal and its PCB-load-capacitance uncertainty.

The carrier connects:

- `VCC` to protected 3.3 V;
- `VBAT` only to the replaceable Panasonic `CR2032` through the Keystone `3003` holder;
- `SDA`/`SCL` to the shared 3.3 V I2C bus;
- `/INT/SQW` to a dedicated GPIO and named test pad; and
- no resistor, diode, or IC that can charge the primary cell.

The CR2032 is explicitly non-rechargeable. The schematic must place a `DO NOT CHARGE` note at the battery and must not copy charging circuits used by some low-cost DS3231 modules.

A capacity/current quotient is not accepted as a retention result. Even a large theoretical margin ignores leakage, self-discharge, holder contamination, temperature, battery age, and board assembly. The required 24-hour powered-off holdover and drift tests remain open until measured on assembled hardware.

## Audio and control validation

### Audio path

The Adafruit `3006` board provides a documented MAX98357A I2S class-D path with no microphone or analog input. It operates from 2.7 V to 5.5 V and is intended for 4 Ω to 8 Ω speakers. The selected Waveshare SKU `27859` is an enclosed 8 Ω, 2 W speaker with a PH1.25 2-pin cable.

Carrier connections are `I2S_BCLK`, `I2S_LRCLK`, `I2S_DOUT`, `AMP_SD`, 5 V, and GND. `AMP_SD` defaults low with a hardware pull-down so reset/boot is quiet. Firmware must use conservative digital gain and volume limits. Safe impedance compatibility is supported by the amplifier and speaker documentation, but loudness, distortion, enclosure resonance, wake-up click, and thermal rise require bench testing.

### Controls

- `B3F-1000` is selected for both discrete push controls to reduce unique parts. Its manufacturer minimum applicable load is treated as a real constraint rather than assuming a high-impedance 3.3 V GPIO is sufficient.
- `PEC11R-4215F-S0024` provides 24 detents, incremental A/B outputs, and an integrated push switch for menu navigation and confirmation; its published contact rating is 10 mA at 5 V DC.
- Each of the five contacts switches 5 V into an individual 4.7 kΩ pull-down, providing about 1.06 mA wetting current. A 3.3 V-powered TI `SN74LVC14APWR` receives the 5 V levels on its tolerant Schmitt inputs and presents clean 3.3 V logic to the ESP32-S3. The sixth input is tied to a defined level.
- The five post-buffer user-input lines use individual GPIOs and named pads; none share boot-strapping or USB pins. Firmware debounce remains required and must account for the inversion.

### Ambient-light sensor

Adafruit `4162` carries Vishay's VEML7700, an I2C ambient-light sensor. It is powered from 3.3 V and shares the I2C bus with the touch controller and RTC. The expected addresses are distinct (`0x10` sensor, `0x38` touch, `0x68` RTC), but the schematic review must verify actual address strapping and aggregate pull-up strength. Automatic brightness remains advisory and locally overrideable.

## Power path and current envelope

The deployed path is:

`SC0218 supply -> carrier USB-C -> VBUS TVS -> TPS259531 eFuse -> +5V_SYS -> display, audio, and DevKit 5V header -> onboard 3.3 V regulation`

Design rules for issue #3:

1. Use the USB-C receptacle as a **5 V sink only**. Leave D+/D- unconnected and expose no USB-PD negotiation.
2. Use two independent 5.1 kΩ, 1% CC pull-downs (`RC0603FR-075K1L`) and keep D+/D- unconnected.
3. Place `LESD8LH5.0CT5G` from VBUS to the shortest available ground return at the inlet.
4. Feed VBUS through `TPS259531DSGR`. Use `RC0603FR-071K53L` (1.53 kΩ, 1%) at ILM: TI equation 4 gives about 1.347 A nominal; combining +7.5% current-limit error and -1% resistor tolerance conservatively gives about 1.463 A. The Rev A schematic repeats that calculation and uses 100 nF dVdt with 10 µF ceramic plus 470 µF electrolytic output bulk; PCB thermal implementation and measured module inrush remain open.
5. Route at least the controller, display/backlight, amplifier, and peripheral branches separately from the protected 5 V node so each can be measured.
6. Do not treat adapter capability (5.1 V, 3 A) as permission for the product to draw 3 A; the carrier limit remains below 1.5 A.
7. Put the two DevKit USB connectors behind a service opening. The enclosure's user-facing inlet is the protected carrier USB-C.

The following are provisional allocations, not measurements: controller/Wi-Fi 450 mA, display/backlight 200 mA, capped audio transient 350 mA, and RTC/sensor/control margin 50 mA. Their 1,050 mA total preserves at least 25% headroom to the 1.5 A source ceiling, but is not verified consumption. Measure full-white display + Wi-Fi transmit + alarm playback before fabrication approval.

## Mechanical approach

Rev A uses a two-piece PETG enclosure rather than a purchased box because the display bezel, oversized snooze plunger, encoder shaft, speaker grille, sensor aperture, and hidden service ports require custom geometry.

- Display mounts directly behind the front bezel.
- The carrier and DevKit stack behind the display; their 2.54 mm socket headers are through-hole and replaceable.
- The speaker mounts in a rear acoustic pocket; wiring is strain-relieved.
- The CR2032 has a service opening that cannot short the cell with a metal tool.
- Four Adafruit `4255` M3 x 4 mm heat-set inserts and four M3 x 4 mm nylon screws from Adafruit kit `4685` retain the rear cover.
- Four 3M `SJ-5003` feet provide clearance and slip resistance.
- Antenna copper and the region immediately in front of the ESP32-S3-WROOM-1 PCB antenna remain free of carrier copper, batteries, speaker magnets, screws, and metallized enclosure material.

The display module's published 61.00 x 92.44 mm outline and 48.96 x 73.44 mm active area support schematic/enclosure planning. Final hole locations, connector insertion direction, bezel clearance, standoff height, and speaker cavity volume require a dimension-controlled CAD drawing or physical sample. Therefore this decision authorizes schematic capture, not final PCB outline or enclosure release.

## Candidate comparison

| Criterion | Selected discrete architecture | Waveshare SKU 30733 integrated board |
| --- | --- | --- |
| Microphone-free hardware | Yes | **No; fitted MIC1** |
| Controller documentation/lifecycle | Espressif guide, schematic, module datasheet, broad distribution | Vendor schematic/docs; module-level PCN/lifecycle not found |
| Display | Separate SKU 29318, independent BL/INT/RST access | Integrated ST7796/FT6336; backlight not on expansion header |
| RTC | DS3231MZ+, ±5 ppm class, replaceable noncharged CR2032 | PCF85063 + AXP2101 backup charger; exact board holdover unpublished |
| Audio | Digital-only MAX98357A breakout, no input path | ES8311 codec plus analog microphone and NS4150B amp |
| GPIO/test access | Two official 22-pin headers; named carrier pads | 2x16 header; several functions remain module-internal |
| One-unit observed core cost | Higher; full prototype planning subtotal about $87 before tax/shipping | Lower; module observed at $25.99 |
| Main risk | Carrier complexity and cost | Privacy violation, sole-source module/revision, limited internal test access |

## Price and availability snapshot

All observations are dated 2026-08-23 UTC and are snapshots, not future-availability promises. Manufacturer pages establish identity/specifications; distributor/product pages establish only dated orderability/price observations. The normalized records are in [`bom/preliminary-bom.csv`](../bom/preliminary-bom.csv) and [`docs/source-manifest.csv`](source-manifest.csv).

The planning subtotal is approximately **$87 before tax and shipping**, about **$12 above the $75 target ceiling**. The overage is accepted for schematic capture because it buys a microphone-free architecture, a documented backup RTC, protected dedicated power input, and an independently controllable audio path. Cost reduction is a required pre-order task; candidates include integrating the MAX98357A IC rather than its breakout, consolidating headers, and using quantity PCB/enclosure pricing. Privacy, RTC retention, and input protection may not be removed to hit the target.

## Evidence classification and remaining gates

### Supported by manufacturer documents/static analysis

- Selected part identities, interfaces, package classes, nominal ratings, and pin functions.
- No microphone in the selected controller/display/audio hardware.
- GPIO assignment avoids known N8R8 PSRAM pins, USB pins, boot straps, and UART service pins.
- RTC has a dedicated battery input and the proposed CR2032 path contains no charger.
- Amplifier and speaker nominal impedance classes are compatible.
- Carrier USB-C sink/power-protection topology is feasible with the selected components.

### Still unverified; do not convert to a pass without hardware

- 24-hour RTC retention and drift over the intended temperature range.
- Full-path current and the 25% headroom target under simultaneous Wi-Fi, white display, and alarm audio.
- Minimum useful nighttime luminance, flicker, and automatic-brightness behavior.
- Alarm SPL, distortion, thermal rise, start/stop clicks, and enclosure acoustics.
- Exact mechanical fit, connector orientation, standoff height, service access, and antenna clearance.
- DevKit/display revision identity on received units.
- EMC/ESD performance of the assembled carrier and enclosure.
- Supplier stock, price, and lifecycle at order time.

## Schematic result and handoff to PCB/bring-up

Issue #3 produced the editable KiCad schematic using this selection and [`hardware/pin-allocation.csv`](../hardware/pin-allocation.csv). Manufacturer, MPN, supplier, datasheet, dated cost, and BOM-note properties are stored on electrical BOM symbols; [`bom/bom.csv`](../bom/bom.csv) is exported from those properties. The preliminary CSV remains planning/history data only. See [`schematic-review.md`](schematic-review.md) and [`hardware/kicad/README.md`](../hardware/kicad/README.md).

Native KiCad 9 ERC and schematic analysis now exist. Fabrication remains blocked until the editable PCB exists and passes DRC, schematic/PCB cross analysis, layout/thermal/EMC review, received-module/mechanical checks, and fabrication-file review. Structured datasheet extraction and lifecycle/stock checks also remain open. Physical acceptance remains blocked until the bench and field checks above produce recorded evidence.
