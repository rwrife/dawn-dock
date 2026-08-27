# Rev A0 carrier PCB static layout review

**Review date:** 2026-08-27

**Scope:** editable KiCad PCB, routing, manufacturing exports, and static analyzers

**Verdict:** **fabrication hold** — useful review candidate, not approved for ordering

## Overview

The branch adds the editable `hardware/kicad/dawn-dock.kicad_pcb` synchronized to the Rev A schematic. The 135 mm × 95 mm two-layer board contains 73 footprints, 66 nets, 662 track segments, 152 vias (including return-path stitches), four zones/rule areas, four M3 mounting holes, three front fiducials, and 30 named test points. The PCB analyzer reports all nets routed.

Placement is deterministic in `generate_pcb.py`; FreeRouting 2.3.0 produced the reviewed route; `finalize_pcb.py` adds the protected-5 V control join, dual filled GND planes, edge stitches, and locally safe return vias. The ESP32 antenna end is placed at the board edge with a copper/track/via keepout on both copper layers. Controls, sensor, display connector, USB power entry, RTC/cell, and audio module are separated into documented functional areas.

This review does **not** close the received-unit/mechanical gate in `docs/risk-register.md`. Manufacturer drawings and prior pin review support the source geometry, but no received module or enclosure was available to measure.

## Verification basis

| Source | Evidence | Confidence/limit |
|---|---|---|
| KiCad 9.0.2 ERC | 0 violations | Deterministic schematic structural check |
| KiCad 9.0.2 DRC | 0 violations, 0 unconnected items, 0 schematic-parity items | Deterministic board-rule/connectivity check |
| Schematic analyzer 1.4 | 27 findings; three known voltage-domain classification errors and DS-002 datasheet-cache gap | Internal consistency only for uncached parts; prior manual source citations remain in `docs/schematic-review.md` |
| PCB analyzer 1.4 (`--full --proximity`) | 0 errors, 1 warning, 40 info; routing complete | Deterministic/geometry checks; TE-001 is discussed below |
| Cross analyzer 1.4 | 0 errors, 1 warning | Pad/net sync has no reported mismatch; intentional off-board SPK1 remains schematic-only |
| EMC analyzer 1.4 | 8 errors, 22 warnings, 8 info; risk score 49/100 | Heuristic risk screen, not FCC/CISPR compliance evidence |
| Thermal analyzer, 35 °C | skipped, 0 components assessed | No extraction cache supplied quantifiable dissipation; no temperature claim |
| Gerber analyzer 1.4 | complete/aligned, 0 errors, 1 warning | Static manufacturing-file parser |
| Source BOM gate | fresh KiCad BOM byte-identical to `bom/bom.csv`; 32 rows/37 components complete | Stock/prices remain dated observations, not future availability |

No SPICE simulator was installed. No bench, mechanical-fit, field, ESD, EMC, thermal, current, acoustic, optical, or retention test was performed.

## Power, ground, and return paths

- Project minimums: 0.18 mm track, 0.20 mm clearance, 0.60/0.30 mm minimum via, and 0.50 mm copper-to-edge.
- `/VBUS` uses a 1.2 mm routing class with short 0.20 mm USB/eFuse pad escapes; the USB-C footprint requires 0.20 mm pad spacing, so its VBUS class clearance is explicitly 0.20 mm.
- `/+5V_SYS` uses a 1.0 mm class, with a 0.8 mm low-load control branch at the bottom edge.
- `/+3V3` uses a 0.5 mm class; speaker traces use 0.5 mm; clocks/fast buses use 0.25 mm except unavoidable 0.1874 mm fine-pitch escape segments above the 0.18 mm process floor.
- Both copper layers have filled GND zones. The finalizer adds eight perimeter stitches plus 59 DRC-clean GND vias within 1 mm of signal transitions where geometry and filled copper permit.

The return-path pass improved the EMC screen from 59 findings/score 40 to 38 findings/score 49. It did not make the design EMC-ready. Two congested clock transitions (`/I2S_BCLK` at 107.2731,50.8567 mm and `/TFT_SCLK` at 108.823,49.0 mm) cannot accept a 0.6/0.3 mm GND via within 1 mm without violating clearance or landing in a copper void. Six high-speed/error-level `GP-001` plane-coverage findings remain. These are blockers for an order-ready claim.

## Placement and mechanical intent

- Board outline: 135 mm × 95 mm within the 140 mm × 100 mm planning envelope.
- Mounting holes: four 3.2 mm M3 clearances near corners.
- ESP32 DevKit antenna: edge-facing with explicit F.Cu/B.Cu no-copper/no-track/no-via rule areas.
- Controls: encoder/menu, snooze, and brightness positioned on the user edge with readable legends.
- Ambient sensor: edge placement and `SENSOR WINDOW` legend preserve a planned light path.
- Display: edge connector and pin-1/orientation warnings remain visible.
- RTC/cell: cell polarity and `DO NOT CHARGE` legends are present.
- Test access: 30 labeled test pads cover every intentionally selected power, service, bus, audio, control, and eFuse diagnostic net.

These positions are source-backed intent, not measured fit evidence. Received-unit connector orientation, module overhangs, enclosure wall/fastener clearance, cable bend radius, sensor aperture, speaker path, and coin-cell insertion/removal must be measured before fabrication.

## Finding triage

| Finding | Triage |
|---|---|
| PCB `TE-001`, 30/66 nets (45%) | Expected. Thirty named service nets are intentionally exposed; NC nets and every low-value internal passive node are not test-point targets. |
| Cross `XV-001`, schematic-only SPK1 | Expected. SPK1 is the external 8 Ω speaker tracked in the BOM/non-schematic assembly path; the PCB carries `SPK+`/`SPK-` to the amplifier module connection. |
| Gerber `GR-004`, 99 paste vs 375 copper flashes | Heuristic denominator includes vias, test pads, and through-hole copper that correctly has no paste. Gerber layers are complete/aligned, but stencil apertures still require assembler review. |
| Schematic `VM-001` on I²C/RTC nets | Previously triaged in `docs/schematic-review.md`: 3.3 V pull-ups and module-level conversion; no 5 V pull-up fitted. Datasheet extraction cache remains absent, so this is not re-labeled as automated verification. |
| EMC `GP-001` / `RP-001` errors | Real unresolved layout risk. Not suppressed. Fabrication hold remains. |
| EMC `DC-001`, RTC decoupler 6.2 mm away | Review warning. Move closer during the next layout revision if mechanics permit. |
| EMC `CK-002`, 110–113 mm I²S clocks | Real routing-length concern caused by module placement; review with speaker/enclosure geometry and reroute if possible. |

## Manufacturing outputs

`hardware/kicad/fabrication/rev-a0-prototype-review/` contains the deterministic archive of nine expected Gerbers plus separate PTH/NPTH drills and maps, a 34-row DNP-filtered placement CSV, top/perspective PNG renders, and checksums. `export_fabrication.py` also creates front/back SVG plots as reproducible scratch outputs. The Gerber/drill archive SHA-256 is:

```text
bcb4005d91638ff80552d669ac73bbddb8f187a79761660a287e6ebff13afc41
```

The ZIP and every listed checksum pass. PNG headers are valid and both generated images are nontrivial; KiCad 9.0.2 emitted 1568×1176 pixel canvases from the requested 1600×1200 render bounds. Ray-traced PNG bytes are not claimed deterministic; `SHA256SUMS` records this export’s integrity.

## Blockers before issue #4 can close

1. Measure and confirm received display/module/encoder/holder geometry and connector orientation.
2. Integrate the enclosure and cable/service clearances from those measurements.
3. Resolve or formally redesign around the six error-level plane-coverage findings and two clock return transitions; repeat DRC/analyzers afterward.
4. Review assembly rotations and paste apertures with the selected fabricator/assembler.
5. Perform the issue’s physical fit and staged bring-up checks; keep those results separate from this static review.

Until those gates close, the committed archive is for review/reproducibility only and must not be uploaded as an approved fabrication package.
