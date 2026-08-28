# Requirements verification matrix

**Baseline:** v0.1
**Current project evidence:** documentation; static KiCad schematic/PCB/ERC/DRC/BOM review; partial alarm-core host tests and ESP32-S3 build; no target execution or physical test evidence

## Evidence classes

| Class | Meaning | Examples | What it does not prove |
|---|---|---|---|
| Static analysis | Inspection or deterministic analysis without executing the physical design | Requirements review, datasheet cross-check, ERC/DRC, analyzer output, schema validation | Electrical behavior, acoustic output, retention, thermals |
| Simulation | Executed model with stated assumptions | SPICE rail/filter simulation, software model/property test | Physical assembly performance outside model accuracy |
| Software test | Executed code on host/CI or target | Unit, fixture, fuzz, build, protocol interoperability test | Real sensor/display/audio/power behavior unless run on target hardware |
| Bench test | Controlled measurement on identified hardware with instruments/method | Rails/current, luminance, SPL, debounce, RTC retention, reset/recovery | Long-duration household reliability or broad field conditions |
| Field test | Extended use in a representative environment | Multi-day alarm/radio-loss observations | Guaranteed operation or life-safety suitability |

Every result records commit, artifact/hardware revision, tool/instrument, method, raw output location, date, operator, and pass/fail limits. A lower evidence class cannot be renamed as a higher one.

## Baseline traceability

| Requirement | Acceptance target | Primary evidence class and method | Current status |
|---|---|---|---|
| ELEC-01 | USB 5 V SELV only; certified enclosed ≥2 A external supply; no mains | Static schematic/BOM inspection; assembled visual inspection | Schematic/BOM contain only protected USB-C 5 V input; SC0218 is a separate supply item; received-unit inspection remains open |
| ELEC-02 | Device peak ≤1.5 A at 5 V allocation | Static source-backed current sum + PCB review; bench idle/peak/inrush measurement | 1.53 kΩ ILM and 100 nF dVdt network calculate to about 1.347 A nominal/1.463 A conservative and 0.42 V/ms; actual module current/inrush/thermals remain unmeasured |
| ELEC-03 | Recover to valid state after brownout; reset cause visible | Software fixtures; bench controlled voltage sag/reset | Specified only |
| ELEC-04 | Valid RTC time after 24 h main-power removal; drift reported | Datasheet/static review then bench retention/drift test | DS3231MZ+/CR2032 VBAT net is captured with no rail/charge connection; bench retention/drift open |
| ELEC-05 | Schedule intact and no duplicate occurrence after 100 controlled cycles | Software corruption/recovery fixtures + automated bench cycling | Host core suppresses active/terminal duplicate occurrence IDs; storage integrity, 100-cycle software fixture, and automated bench cycling remain open |
| ELEC-06 | Dedicated controls; single action; ≤100 ms valid-press response | Static GPIO review; host debounce fixture; bench latency capture | Five separate 5 V/4.7 kΩ wetted-contact paths and LVC14 outputs are captured on conflict-free GPIOs; behavior untested |
| ELEC-07 | Blackout; lowest lit target ≤1 cd/m² | Static backlight-path review; dark-room bench luminance measurement | Separate `LCD_BL` PWM path selected; luminance unmeasured |
| ELEC-08 | 60–75 dBA normal range and ≤80 dBA maximum at 1 m | Static driver review; bench A-weighted slow measurement in enclosure | MAX98357A and 8-ohm/2-watt speaker selected; acoustic/thermal evidence open |
| ELEC-09 | Source-backed input/ESD/decoupling; no undocumented back-power | Datasheet/schematic static review, ERC/cross analysis, staged bring-up | USB-C/TVS/eFuse/decoupling and official DevKit Schottky boundary are captured; native ERC is clean; layout/ESD path and bring-up remain open |
| ELEC-10 | Named test access for rails/reset/RTC/backlight/audio/controls | Schematic/PCB static inspection and continuity bench check | Thirty named schematic test points cover rails, reset/boot, buses, display, audio, UART, eFuse fault, and controls; PCB pads/continuity remain open |
| MECH-01 | ≤140 × 100 × 75 mm excluding cable | CAD dimension check; assembled measurement | Display module outline sourced; system CAD/measurement open |
| MECH-02 | No tip under 10 N downward snooze press | Bench force test on assembled enclosure | Target frozen |
| MECH-03 | Serviceable with common tools; no destructive primary adhesive | CAD/assembly review; timed disassembly bench check | Specified only |
| MECH-04 | Tactile snooze and distinct controls | Drawing/static accessibility review; bench user evaluation | Exact switches/encoder and enclosure differentiation concept selected; CAD/bench open |
| MECH-05 | Strain-relieved USB entry without sharp bend | CAD/static review; assembled pull/inspection method to be finalized | Specified only |
| MECH-06 | Mounting holes and keepouts in editable sources | KiCad/CAD static cross-check | Four mounting-hole symbols are captured; PCB hole placement, antenna keepout, and CAD cross-check remain open |
| ENV-01 | 10–35 °C non-condensing use | Component rating static review; 35 °C chamber/controlled ambient bench run | Critical IC ratings reviewed; complete BOM and assembled 35 °C test open |
| ENV-02 | No release until user-surface limit is selected and measured at 35 °C | Risk/material review then bench thermal measurement | Open decision |
| ENV-03 | Blackout and physical brightness override work offline | Software fixture + target bench network-disabled test | Specified only |
| ENV-04 | No fan/unintended periodic sound | BOM/static review; quiet-room bench observation and audio capture | Fanless and microphone-free hardware selected; quiet-room evidence open |
| ENV-05 | Non-color states, large text, tactile primary controls | Static UI review, widget/accessibility tests, device/app bench review | Specified only |
| CONN-01 | 72 h representative alarm run with radios disabled | Software fixture then bench integration run | Specified only |
| CONN-02 | 120 s physical pairing window, unique credentials, no default | Protocol/security static review; software/target negative tests | Specified only |
| CONN-03 | Version/64 KiB/schema/revision/replay validation | Schema/unit/fuzz/interoperability tests; target overload tests | Draft only |
| CONN-04 | Optional service failure cannot delay alarm | Architecture/static review; overload/radio-loss software and bench tests | Specified only |
| CONN-05 | Selected fields only, local export/erase; no microphone/camera hardware | Static hardware/data-model review; unit tests; post-erase inspection | Microphone-free component selection complete; software/storage evidence open |
| CONN-06 | Physical-confirmed reset and USB recovery without cloud | Software state tests and target recovery/erase bench test | Specified only |
| COST-01 | Re-priced prototype total <USD 75 | BOM validation and dated sourcing snapshot | Not met: 2026-08-23 planning subtotal about USD 87 before tax/shipping; reduction required before order |
| COST-02 | Price/stock observations are dated and non-guaranteed; overage requires a decision record | BOM/documentation review | Dated snapshot and overage decision recorded; live recheck still required at order |
| COST-03 | KiCad properties are the final electrical BOM source; non-schematic items remain separate | Static KiCad/BOM audit | `bom/bom.csv` is exported from KiCad properties; enclosure/supply/cable/fasteners remain in `bom/non-schematic-items.csv` |
| COST-04 | Validate MPN/pin/package/thermal/lifecycle/source before purchase | Static BOM/datasheet audit | Electrical BOM has exact active/passive MPNs, supplier source, dated estimates, notes, and DNP pull-ups; received revisions, lifecycle/stock, layout thermal implementation, and purchase-time recheck remain open |
| ALARM-01 | State transitions match `docs/alarm-semantics.md` | Host state-machine fixture; target interaction tests | Host software tests cover due/disabled admission, duplicate suppression, snooze/re-ring, dismiss, timeout, missed, and reboot-recovery transitions; recurrence, disable-after-terminal, invalid-time reconciliation, storage, target, and bench paths remain open |
| ALARM-02 | Spring gap shifts once; fall fold rings first occurrence once | Host timezone fixtures for at least two zones | Specification only |
| ALARM-03 | Forward correction grace boundaries at 9:59/10:00/10:01 | Host fixtures and target correction test | Host boundary fixture passes; target correction test remains open |
| ALARM-04 | Snooze defaults/range/count and 60-minute occurrence timeout match the baseline | Host transition/boundary fixtures; target control tests | Host tests cover 1/30-minute range boundaries, 9-minute default, repeated-edge rejection, six-snooze limit, deadline, and 60-minute timeout; target controls remain open |
| ALARM-05 | Reboot resumes only within 60-minute occurrence lifetime and never duplicates the occurrence | Host persistence fixtures; controlled target resets | Host in-memory recovery fixture covers once-per-boot resume, snooze cancellation, and prolonged-power-off missed classification; serialized persistence and controlled target resets remain open |


## Release-report rule

Reports must list skipped tests and remaining evidence gaps. A requirement is not complete merely because its row exists. Hardware targets remain `not tested` until measurements on an identified assembly are archived.
