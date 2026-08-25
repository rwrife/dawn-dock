# Dawn Dock KiCad source

This directory contains the editable Rev A carrier schematic. It is a static design artifact only: there is no PCB, fabricated assembly, or bench evidence yet.

## Files

- `dawn-dock.kicad_pro` / `dawn-dock.kicad_sch` — KiCad 9 project and schematic.
- `lib/dawn-dock.kicad_sym` — project symbols derived from cited manufacturer pin tables.
- `lib/dawn-dock.pretty/` — project footprints for the DevKit/socket, module headers, PEC11R, and Keystone 3003.
- `generate_schematic.py` — reproducible source generator.
- `validate_hardware.py` — BOM/connectivity/evidence assertions.
- `reports/erc.rpt` — native KiCad 9 ERC output.
- `reports/schematic-analysis.json` / `.txt` — static analyzer output.
- `reports/hardware-validation.json` — project-specific machine-readable checks.

## Rebuild

Use KiCad 9 symbol libraries and Python 3.11+:

```bash
python3 -m venv .venv
.venv/bin/pip install -r hardware/kicad/requirements.txt
.venv/bin/python hardware/kicad/generate_schematic.py \
  --symbol-dir /usr/share/kicad/symbols
```

The generator rewrites the project-local symbol and footprint files and the schematic. UUIDs may change between generations; review the electrical diff, not only textual UUID churn.

## Verify

Native KiCad 9 ERC:

```bash
kicad-cli sch erc \
  --output hardware/kicad/reports/erc.rpt \
  --exit-code-violations \
  hardware/kicad/dawn-dock.kicad_sch
```

Schematic analyzer (from `kicad-happy`):

```bash
python3 /path/to/kicad-happy/skills/kicad/scripts/analyze_schematic.py \
  hardware/kicad/dawn-dock.kicad_sch \
  --output hardware/kicad/reports/schematic-analysis.json
python3 /path/to/kicad-happy/skills/kicad/scripts/analyze_schematic.py \
  hardware/kicad/dawn-dock.kicad_sch --text \
  > hardware/kicad/reports/schematic-analysis.txt
```

Export the source-property BOM with KiCad 9:

```bash
kicad-cli sch export bom hardware/kicad/dawn-dock.kicad_sch \
  --output bom/bom.csv \
  --fields 'Reference,${QUANTITY},Value,Footprint,Manufacturer,MPN,Supplier,Supplier PN,Estimated Unit Cost USD,Price Observed UTC,BOM Comments,${DNP}' \
  --labels 'Reference,Qty,Value,Footprint,Manufacturer,MPN,Supplier,Supplier_PN,Estimated_Unit_Cost_USD,Price_Observed_UTC,Notes,DNP' \
  --group-by 'Value,Footprint,Manufacturer,MPN,Supplier,Supplier PN,Estimated Unit Cost USD,Price Observed UTC,BOM Comments,${DNP}' \
  --sort-field Reference --sort-asc
```

Export a fresh netlist and then run the project gate with explicit fresh inputs:

```bash
kicad-cli sch export netlist --output /tmp/dawn-dock.net \
  hardware/kicad/dawn-dock.kicad_sch
python3 hardware/kicad/validate_hardware.py \
  --netlist /tmp/dawn-dock.net \
  --bom bom/bom.csv \
  --erc hardware/kicad/reports/erc.rpt
python3 scripts/check_component_selection.py
python3 scripts/check_docs.py
```

CI does not trust these committed evidence files in isolation. It builds
`Dockerfile.verify`, runs KiCad 9 ERC, exports a fresh netlist and BOM from the
checked-out schematic, byte-compares the fresh BOM with `bom/bom.csv`, and calls
`validate_hardware.py --netlist ... --bom ... --erc ...` on those fresh outputs.
The validator intentionally has no stale-report fallback: all three inputs are required.

## Verified design facts

- USB-C is a 5 V sink only. CC1 and CC2 have independent 5.1 kΩ Rd resistors; D+/D-/SBU are NC.
- `TPS259531DSGR` pin mapping follows TI SLVSE57C: dVdt 1, EN/UVLO 2, IN 3/4, OUT 5, FLT 6, ILM 7, GND 8/EP.
- `R_ILIM=1.53 kΩ`: TI equation 4 gives approximately 1.347 A nominal; the documented +7.5% limit/-1% resistor bound is approximately 1.463 A.
- `C_DVDT=100 nF`: TI equation 3 gives approximately 0.42 V/ms, or 11.9 ms to 5 V. With the explicitly fitted 480 µF output capacitance, the modeled capacitor inrush is approximately 202 mA; module-internal capacitance still requires measurement.
- DS3231MZ+ uses the manufacturer SO-8 pin map. VBAT connects only to the CR2032 positive terminal; there is no charging component or rail tie.
- SN74LVC14APWR uses TI's TSSOP-14 mapping. Five inputs receive separate 5 V/4.7 kΩ wetted contacts; outputs are 3.3 V logic. The unused sixth input is tied low and its output is NC.
- DevKit header pins follow Espressif DevKitC-1 v1.1. N8R8-reserved GPIO35–37, strap pins 3/45/46, onboard RGB GPIO38, and native USB GPIO19/20 are not application loads.
- Waveshare 29318 logic uses its manufacturer-listed SPI/I²C signals. Its 15-pin socket orientation and the received module revision must be rechecked before PCB placement/fabrication.

## Intentional analyzer exceptions

The generic schematic analyzer reports 5 V/3.3 V crossings on `I2C_SDA`, `I2C_SCL`, and `RTC_INT_N`. These are static-classification false positives: the Waveshare display explicitly includes level conversion and supports 3.3 V logic while powered from 5 V; the Adafruit 4162 is powered from 3.3 V; DS3231MZ+ is powered and pulled up at 3.3 V. No 5 V pull-up is fitted on those nets.

The optional carrier I²C pull-ups are DNP because the display and sensor modules include pull-ups. Populate only after measuring aggregate resistance/rise time on received modules.

## Open evidence gates

- PCB layout, return paths, thermal pad implementation, antenna keepout, and exact enclosure/mechanical placement belong to issue #4.
- Module revision, connector orientation, total module capacitance, current, luminance, audio, RTC retention/drift, ESD/EMC, and thermals require identified physical hardware.
- Price and availability are dated 2026-08-23 planning observations, not purchase-time guarantees.
- The local analyzer has no structured datasheet extraction cache, so its trust rollup remains low even though critical pin tables were manually checked against downloaded manufacturer PDFs. Do not convert this static review into a bench-tested or fabrication-ready claim.
