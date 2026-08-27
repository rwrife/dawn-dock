# Dawn Dock KiCad source

This directory contains the editable Rev A carrier schematic and routed two-layer PCB. These are static design artifacts only: there is no fabricated assembly or bench evidence yet.

## Files

- `dawn-dock.kicad_pro` / `dawn-dock.kicad_sch` / `dawn-dock.kicad_pcb` — KiCad 9 project, schematic, and routed PCB.
- `lib/dawn-dock.kicad_sym` — project symbols derived from cited manufacturer pin tables.
- `lib/dawn-dock.pretty/` — project footprints for the DevKit/socket, module headers, PEC11R, and Keystone 3003.
- `generate_schematic.py` — reproducible source generator.
- `generate_pcb.py` — deterministic board outline, placement, antenna rule area, and fine-pitch fanout generator from a fresh KiCad netlist.
- `specctra_io.py` — KiCad-native DSN export / SES import bridge with current-aware routing classes.
- `finalize_pcb.py` — deterministic final +5 V join, GND stitching, and filled dual-layer GND planes.
- `export_fabrication.py` — reproducible review-only Gerber/drill/placement/render export and checksum generator.
- `validate_hardware.py` — BOM/connectivity/evidence assertions.
- `reports/erc.rpt` — native KiCad 9 ERC output.
- `reports/drc.json` — native KiCad 9 PCB DRC/parity output for the committed board.
- `reports/schematic-analysis.json` / `.txt` — static analyzer output.
- `reports/pcb.json`, `cross-analysis.json`, `emc.json`, `thermal.json`, and `gerber.json` — layout/cross-domain risk evidence and disclosed gaps.
- `reports/hardware-validation.json` — project-specific machine-readable checks.
- `fabrication/README.md` / `fabrication/rev-a0-prototype-review/` — checked review bundle under an explicit fabrication hold.

## Rebuild

Use KiCad 9 symbol libraries and Python 3.11+:

```bash
python3 -m venv .venv
.venv/bin/pip install -r hardware/kicad/requirements.txt
.venv/bin/python hardware/kicad/generate_schematic.py \
  --symbol-dir /usr/share/kicad/symbols
```

The schematic generator rewrites the project-local symbol and footprint files and the schematic. UUIDs may change between generations; review the electrical diff, not only textual UUID churn.

## Rebuild and route the PCB

The accepted Rev A board was built with KiCad `9.0.2+dfsg-1`, FreeRouting `2.3.0`, and Eclipse Temurin `25.0.4+7`. FreeRouting is nondeterministic; the committed `.kicad_pcb` is the reviewed editable result. The deterministic generator/finalizer and these commands make rerouting auditable, but a new SES result must pass the same DRC before replacing the committed board.

```bash
docker build -t dawn-dock-kicad-verify \
  -f hardware/kicad/Dockerfile.verify hardware/kicad

route_dir="$(mktemp -d)"
curl -fL \
  https://github.com/freerouting/freerouting/releases/download/v2.3.0/freerouting-2.3.0.jar \
  -o "$route_dir/freerouting-2.3.0.jar"
printf '%s  %s\n' \
  '3cf18d608437740bc497db6b8ef5888e2e60a08de0def20691d1bad0c0e0ee24' \
  "$route_dir/freerouting-2.3.0.jar" | sha256sum --check

docker run --rm -v "$PWD:/work" -v "$route_dir:/route" -w /work \
  dawn-dock-kicad-verify sch export netlist \
  --output /route/dawn-dock.net hardware/kicad/dawn-dock.kicad_sch
docker run --rm -v "$PWD:/work" -v "$route_dir:/route" -w /work \
  --entrypoint python3 dawn-dock-kicad-verify \
  hardware/kicad/generate_pcb.py --netlist /route/dawn-dock.net \
  --output hardware/kicad/dawn-dock.kicad_pcb
docker run --rm -v "$PWD:/work" -v "$route_dir:/route" -w /work \
  --entrypoint python3 dawn-dock-kicad-verify \
  hardware/kicad/specctra_io.py export \
  --board hardware/kicad/dawn-dock.kicad_pcb --dsn /route/dawn-dock.dsn
docker run --rm -v "$route_dir:/route" eclipse-temurin:25-jre \
  java -jar /route/freerouting-2.3.0.jar \
  -de /route/dawn-dock.dsn -do /route/dawn-dock.ses \
  -mp 30 -mt 4 -da --gui.enabled=false \
  --logging.file.enabled=false --logging.console.level=INFO \
  --user_data_path=/tmp/freerouting
docker run --rm -v "$PWD:/work" -v "$route_dir:/route" -w /work \
  --entrypoint python3 dawn-dock-kicad-verify \
  hardware/kicad/specctra_io.py import \
  --board hardware/kicad/dawn-dock.kicad_pcb --ses /route/dawn-dock.ses \
  --output /route/dawn-dock-routed.kicad_pcb
docker run --rm -v "$PWD:/work" -v "$route_dir:/route" -w /work \
  --entrypoint python3 dawn-dock-kicad-verify \
  hardware/kicad/finalize_pcb.py --board /route/dawn-dock-routed.kicad_pcb \
  --output hardware/kicad/dawn-dock.kicad_pcb
```

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

- The routed Rev A0 board and review-only manufacturing outputs exist, but six error-level heuristic plane-coverage findings and two error-level clock-transition return-path findings remain open. The finalizer added 59 DRC-clean return vias; see `reports/emc.json` and `fabrication/README.md`.
- Exact received-unit dimensions, connector orientation, enclosure/mechanical placement, and antenna metal clearance still block fabrication.
- Module revision, connector orientation, total module capacitance, current, luminance, audio, RTC retention/drift, ESD/EMC, and thermals require identified physical hardware.
- Price and availability are dated 2026-08-23 planning observations, not purchase-time guarantees.
- The local analyzer has no structured datasheet extraction cache, so its trust rollup remains low even though critical pin tables were manually checked against downloaded manufacturer PDFs. Do not convert this static review into a bench-tested or fabrication-ready claim.
