# Requirements verification matrix

**Baseline:** v0.1
**Current project evidence:** documentation/static review only

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
| ELEC-01 | USB 5 V SELV only; certified enclosed ≥2 A external supply; no mains | Static schematic/BOM inspection; assembled visual inspection | Specified only |
| ELEC-02 | Device peak ≤1.5 A at 5 V allocation | Static source-backed current sum + PCB review; bench idle/peak/inrush measurement | Provisional allocation only |
| ELEC-03 | Recover to valid state after brownout; reset cause visible | Software fixtures; bench controlled voltage sag/reset | Specified only |
| ELEC-04 | Valid RTC time after 24 h main-power removal; drift reported | Datasheet/static review then bench retention/drift test | Architecture open |
| ELEC-05 | Schedule intact and no duplicate occurrence after 100 controlled cycles | Software corruption/recovery fixtures + automated bench cycling | Specified only |
| ELEC-06 | Dedicated controls; single action; ≤100 ms valid-press response | Static GPIO review; host debounce fixture; bench latency capture | Specified only |
| ELEC-07 | Blackout; lowest lit target ≤1 cd/m² | Static backlight-path review; dark-room bench luminance measurement | Candidate unmeasured |
| ELEC-08 | 60–75 dBA normal range and ≤80 dBA maximum at 1 m | Static driver review; bench A-weighted slow measurement in enclosure | Audio undecided |
| ELEC-09 | Source-backed input/ESD/decoupling; no undocumented back-power | Datasheet/schematic static review, ERC/cross analysis, staged bring-up | Not designed |
| ELEC-10 | Named test access for rails/reset/RTC/backlight/audio/controls | Schematic/PCB static inspection and continuity bench check | Not designed |
| MECH-01 | ≤140 × 100 × 75 mm excluding cable | CAD dimension check; assembled measurement | Target frozen |
| MECH-02 | No tip under 10 N downward snooze press | Bench force test on assembled enclosure | Target frozen |
| MECH-03 | Serviceable with common tools; no destructive primary adhesive | CAD/assembly review; timed disassembly bench check | Specified only |
| MECH-04 | Tactile snooze and distinct controls | Drawing/static accessibility review; bench user evaluation | Specified only |
| MECH-05 | Strain-relieved USB entry without sharp bend | CAD/static review; assembled pull/inspection method to be finalized | Specified only |
| MECH-06 | Mounting holes and keepouts in editable sources | KiCad/CAD static cross-check | Sources absent |
| ENV-01 | 10–35 °C non-condensing use | Component rating static review; 35 °C chamber/controlled ambient bench run | Specified only |
| ENV-02 | No release until user-surface limit is selected and measured at 35 °C | Risk/material review then bench thermal measurement | Open decision |
| ENV-03 | Blackout and physical brightness override work offline | Software fixture + target bench network-disabled test | Specified only |
| ENV-04 | No fan/unintended periodic sound | BOM/static review; quiet-room bench observation and audio capture | Specified only |
| ENV-05 | Non-color states, large text, tactile primary controls | Static UI review, widget/accessibility tests, device/app bench review | Specified only |
| CONN-01 | 72 h representative alarm run with radios disabled | Software fixture then bench integration run | Specified only |
| CONN-02 | 120 s physical pairing window, unique credentials, no default | Protocol/security static review; software/target negative tests | Specified only |
| CONN-03 | Version/64 KiB/schema/revision/replay validation | Schema/unit/fuzz/interoperability tests; target overload tests | Draft only |
| CONN-04 | Optional service failure cannot delay alarm | Architecture/static review; overload/radio-loss software and bench tests | Specified only |
| CONN-05 | Selected fields only, local export/erase | Static data-model review; unit tests; post-erase inspection | Specified only |
| CONN-06 | Physical-confirmed reset and USB recovery without cloud | Software state tests and target recovery/erase bench test | Specified only |
| COST-01 | Re-priced prototype total <USD 75 | BOM validation and dated sourcing snapshot | Planning estimates only |
| COST-02 | Price/stock observations are dated and non-guaranteed; overage requires a decision record | BOM/documentation review | Planning estimates only |
| COST-03 | KiCad properties are the final electrical BOM source; non-schematic items remain separate | Static KiCad/BOM audit | KiCad source absent |
| COST-04 | Validate MPN/pin/package/thermal/lifecycle/source before purchase | Static BOM/datasheet audit | KiCad source absent |
| ALARM-01 | State transitions match `docs/alarm-semantics.md` | Host state-machine fixture; target interaction tests | Specification only |
| ALARM-02 | Spring gap shifts once; fall fold rings first occurrence once | Host timezone fixtures for at least two zones | Specification only |
| ALARM-03 | Forward correction grace boundaries at 9:59/10:00/10:01 | Host fixtures and target correction test | Specification only |
| ALARM-04 | Snooze defaults/range/count and 60-minute occurrence timeout match the baseline | Host transition/boundary fixtures; target control tests | Specification only |
| ALARM-05 | Reboot resumes only within 60-minute occurrence lifetime and never duplicates the occurrence | Host persistence fixtures; controlled target resets | Specification only |


## Release-report rule

Reports must list skipped tests and remaining evidence gaps. A requirement is not complete merely because its row exists. Hardware targets remain `not tested` until measurements on an identified assembly are archived.
