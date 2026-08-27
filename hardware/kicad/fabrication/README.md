# Rev A0 prototype fabrication review bundle

> **FABRICATION HOLD — REVIEW ONLY.** These files are static exports from an unbuilt design. Do not order boards until the received display/module revisions, connector orientation, enclosure geometry, antenna clearance, and remaining EMC return-path findings are resolved. They are not production-ready, bench-tested, or field-tested evidence.

## Bundle identity

- Source PCB: `hardware/kicad/dawn-dock.kicad_pcb`
- Board title/revision: Dawn Dock USB/SELV carrier / A0 PCB prototype
- Outline: 135 mm × 95 mm, two copper layers, nominal 1.6 mm thickness
- Electrical scope: USB 5 V SELV only; no mains; not medical or life-safety
- Export tool: KiCad CLI 9.0.2 from `hardware/kicad/Dockerfile.verify`
- Export date: 2026-08-27
- Gerber archive: `rev-a0-prototype-review/dawn-dock-rev-a0-gerbers-review-only.zip`
- Archive SHA-256: `bcb4005d91638ff80552d669ac73bbddb8f187a79761660a287e6ebff13afc41`

`rev-a0-prototype-review/SHA256SUMS` covers the committed ZIP, placement CSV, and two PNG renders. The deterministic ZIP contains all Gerber and drill outputs; unpacked plots and Gerbers are reproducible exporter scratch rather than tracked duplicates.

## Generated artifacts

- Nine Gerber layers: front/back copper, mask, paste, silkscreen, and Edge.Cuts
- Separate plated and non-plated Excellon drill files plus SVG drill maps
- KiCad `.gbrjob` layer manifest
- Placement CSV in millimetres, both sides, DNP excluded
- Top and perspective PNG renders

The placement CSV has 34 assembly rows. Test points, mounting holes, fiducials, and DNP parts are excluded as intended. Rotation is KiCad-native and has **not** been adjusted or approved for a specific assembly vendor.

## Static checks performed

| Check | Result | Interpretation |
|---|---|---|
| KiCad ERC 9.0.2 | 0 violations | Schematic structural check only |
| KiCad DRC 9.0.2 | 0 violations; 0 unconnected; 0 parity findings | Board-rule and routed-connectivity check |
| PCB analyzer 1.4 | 0 errors, 1 warning, 40 info | Warning is 30/66-net test-point coverage; all 30 intentionally named service nets are present |
| Cross analyzer 1.4 | 0 errors, 1 warning | `SPK1` is an intentional off-board BOM item with no PCB footprint |
| Gerber analyzer 1.4 | Complete and aligned; 1 warning | `GR-004` compares 99 front-paste flashes with 375 copper flashes. The denominator includes through-hole/test/via copper that correctly has no paste; inspect stencil apertures during vendor review |
| EMC risk analyzer 1.4 | 8 errors, 22 warnings, 8 info; heuristic score 49/100 | **Open fabrication hold**, not a compliance prediction |
| Thermal analyzer at 35 °C | Skipped | No datasheet extraction cache supplied quantifiable dissipation; no thermal claim is made |
| SPICE | Not run | No simulator is installed and no layout subcircuit required a substitute claim |
| Physical/mechanical/bench | Not performed | No received modules, enclosure, assembled board, or instruments were available |

The return-path finalizer added 59 DRC-clean GND stitching vias near signal transitions and reduced EMC findings from 59 (score 40) to 38 (score 49). Two congested clock transitions (`I2S_BCLK`, `TFT_SCLK`) still lack a safe GND via within 1 mm. Six error-level heuristic `GP-001` plane-coverage findings also remain. These are unresolved layout risks, not intentional exceptions.

## Required gates before fabrication

1. Measure/confirm the exact received Waveshare 29318 connector orientation and module revision against its manufacturer documentation.
2. Measure the received ESP32-S3 DevKitC-1, display, VEML7700 module, MAX98357A module, encoder, coin-cell retainer, speaker connection, and enclosure mounting geometry.
3. Confirm that enclosure metal, fasteners, and cabling remain outside the ESP32 antenna keepout.
4. Rework or formally review the remaining error-level plane-coverage and clock-transition findings; rerun DRC, PCB, cross, EMC, and Gerber analyses after any change.
5. Review stencil/paste apertures and all pick-and-place rotations with the selected assembler. Through-hole modules and connectors require an explicit assembly process.
6. Perform staged current-limited bring-up, rail/current/thermal checks, control/display/audio/RTC tests, and ESD/EMC pre-compliance measurements on the assembled prototype.

## Reproduce

From the repository root:

```bash
docker build -t dawn-dock-kicad-verify \
  -f hardware/kicad/Dockerfile.verify hardware/kicad

docker run --rm -v "$PWD:/work" -w /work \
  dawn-dock-kicad-verify pcb drc --format json \
  --output hardware/kicad/reports/drc.json --exit-code-violations \
  hardware/kicad/dawn-dock.kicad_pcb

uid=$(id -u); gid=$(id -g)
docker run --rm --user "$uid:$gid" -e HOME=/tmp \
  -v "$PWD:/work" -w /work --entrypoint python3 \
  dawn-dock-kicad-verify hardware/kicad/export_fabrication.py \
  --board hardware/kicad/dawn-dock.kicad_pcb \
  --output hardware/kicad/fabrication/rev-a0-prototype-review

cd hardware/kicad/fabrication/rev-a0-prototype-review
sha256sum --check SHA256SUMS
python3 -m zipfile --test dawn-dock-rev-a0-gerbers-review-only.zip
```

FreeRouting is nondeterministic. The editable committed PCB is the reviewed result; a reroute is a new design revision and must repeat every gate above.
