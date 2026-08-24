# Dawn Dock risk register

**Baseline:** v0.1
**Review cadence:** update when architecture, parts, limits, or evidence changes
**Evidence status:** mitigations are requirements until linked implementation/test evidence exists

Dawn Dock is a convenience appliance. A missed alarm can cause disruption, lost time, or financial consequences, but the product is explicitly not suitable for medication, emergency response, transportation safety, or any life-safety dependency.

## Rating method

- Likelihood: `L` unlikely, `M` plausible, `H` expected without mitigation.
- Impact: `L` minor inconvenience, `M` significant loss of function/privacy/cost, `H` missed alarm, unsafe low-voltage fault, unrecoverable data loss, or major security compromise.
- Residual ratings are targets after all listed mitigations pass. They are not current measured risk.
- Owners are project roles so the register remains actionable without assigning a person prematurely.

## Register

| ID | Risk, cause, and consequence | Initial L/I | Owner | Required mitigation | Verification method / evidence class | Target residual L/I | State |
|---|---|---|---|---|---|---|---|
| R-001 | Alarm does not sound because schedule/time/storage logic fails; user may miss an important convenience alarm | M/H | Firmware | Deterministic state machine, occurrence journal, last-known-good storage, visible next alarm, reset diagnostics, explicit non-life-safety warning | Host transition/DST/corruption fixtures; 100-cycle and staged bench alarm matrix; longer field runs reported separately | L/H | Open—specified, not implemented |
| R-002 | Backward correction or DST fold rings the same occurrence twice | M/M | Firmware | UTC-resolved occurrence ID and durable terminal journal; first-fold policy | Boundary and reboot host fixtures; target bench time-correction fixture | L/M | Open |
| R-003 | Spring gap/forward correction silently skips an alarm | M/H | Firmware / App | Preview shifted/missed semantics, 10-minute grace, visible receipt and diagnostic | IANA timezone fixtures and target bench clock-correction tests | L/H | Open |
| R-004 | Invalid RTC or failed backup loses time during outage | M/H | Hardware / Firmware | Selected DS3231MZ+, noncharged CR2032, validity flag, 24 h retention requirement, visible fault | Datasheet/schematic review; bench retention/drift measurement | L/H | Static selection complete; bench evidence open |
| R-005 | Brownout/reset loop corrupts state or repeatedly starts audio | M/H | Hardware / Firmware | 1.5 A envelope, input/rail margin, atomic storage, occurrence gate, reset-cause diagnostics | Static power review, ERC/DRC, current-limited bring-up, brownout and power-cycle bench tests | L/H | Open |
| R-006 | Display cannot become dark enough for bedside use | H/M | Hardware / UX | Selected display exposes `LCD_BL`; ≤1 cd/m² lowest lit target, true blackout, PWM control, module fallback | Source review then dark-room luminance bench measurement | L/M | Static path selected; luminance unmeasured |
| R-007 | Alarm is inaudible or unexpectedly loud | M/H | Hardware / Firmware | Selected MAX98357A/8-ohm path; bounded adjustable output, 60–75 dBA normal target, ≤80 dBA maximum target, volume UI | Circuit/static review; calibrated A-weighted 1 m enclosure measurement | L/H | Static path selected; acoustic evidence open |
| R-008 | Network/calendar/weather task delays alarm evaluation | M/H | Firmware | Alarm-critical task isolation, bounded queues/deadlines, optional-service failure isolation | Architecture review, overload host/target tests, radio-loss bench test | L/H | Open |
| R-009 | Unauthorized local client changes schedule | M/H | Firmware / App / Security | Physical pairing window, no default secret, authenticated encryption, replay/revision checks, revocation | Threat review, protocol negative fixtures, target pairing/packet tests | L/H | Open |
| R-010 | Crafted calendar/backup/protocol input crashes app/device or consumes resources | M/M | App / Firmware | Strict schema and semantic limits, 64 KiB envelope ceiling, bounded recurrence, fuzz corpus | Unit/property/fuzz tests; target overload test | L/M | Open |
| R-011 | Credentials or calendar details leak through logs/backups | M/M | App / Firmware | Platform secure storage, minimal retained fields, redaction, credential exclusion, erase/export inventory | Static review plus automated log/backup scans and post-erase inspection | L/M | Open |
| R-012 | Accidental or remote reset erases schedule | M/H | Firmware / UX | 5 s physical gesture and on-device confirmation; no remote completion; backup/export | State-machine tests and target gesture/erase bench test | L/H | Open |
| R-013 | Firmware/config update is corrupt or unauthenticated | M/H | Firmware / Release | Authenticity gate before OTA, last-known-good rollback, USB recovery, versioned migration | Build/static review, corrupted-image/config fixtures, target rollback/recovery test | L/H | Open |
| R-014 | Module pinout, revision, back-power, or mechanical assumptions damage hardware or invalidate design | H/H | Hardware | Exact Espressif N8R8 ordering code, manufacturer schematic, pin/resource table, protected carrier input, received-unit/CAD confirmation | Source citations, schematic pin audit, ERC/cross analysis, mechanical cross-check, staged current-limited bring-up | L/H | Static gate closed for schematic capture; blocks layout/fabrication until geometry and received revision are checked |
| R-015 | Input path, cable, or PCB overheats at peak current | M/H | Hardware | 1.5 A design ceiling, ≥2 A certified supply, rated cable/connector/protection/copper, thermal review | Datasheet and IPC/DFM analysis; peak/inrush and 35 °C ambient thermal bench test | L/H | Open |
| R-016 | RTC backup cell is charged despite non-rechargeable chemistry or installed reversed | M/H | Hardware | Selected DS3231MZ+ direct VBAT path, Keystone 3003 holder, Panasonic CR2032, no charging parts, polarity/chemistry silk | Datasheet/schematic review, continuity inspection, staged bring-up | L/H | Static topology selected; schematic and continuity evidence open |
| R-017 | Unit tips or cable/edge exposes a low-voltage mechanical hazard | M/M | Mechanical | 10 N no-tip test, strain relief, rounded edges, serviceable fasteners, stable feet | CAD/static check and assembled bench force/inspection test | L/M | Open |
| R-018 | Controls are inaccessible, ambiguous, or duplicate due to bounce | M/M | Hardware / Firmware / UX | Tactile snooze distinction, spacing/labels, ≤100 ms response, debounced single action, app accessibility targets | Drawing review, host debounce fixture, bench usability/accessibility review | L/M | Open |
| R-019 | Prototype cost or part availability breaks reproducibility | H/M | BOM / Hardware | USD 75 target, dated price/stock, exact MPN/source fields, alternatives only after validation, explicit overage decision | BOM validation and dated sourcing snapshot; no future-availability claim | M/M | Open—2026-08-23 planning subtotal about USD 87 before tax/shipping; reduce before order |
| R-020 | Enclosure traps heat or blocks sensor/audio/light paths | M/M | Mechanical / Hardware | Ventilation, defined openings, sensor/light path, audio path, 35 °C test, service clearances | CAD review, thermal/optical/acoustic bench tests in final enclosure | L/M | Open |
| R-021 | Users infer a medical/emergency or guaranteed-wake capability | M/H | Documentation / UX | Prominent non-life-safety language in README, UI, assembly/release docs; no unsupported health claims | Documentation/release checklist and UI copy review | L/H | Mitigation present in baseline docs; release review pending |
| R-022 | Broad permissions or cloud dependency violates local ownership | M/M | App / Product | Selected-file import, invocation-time permissions, no account/telemetry, local erase/export, optional network isolation | Permission manifest/static review, offline demo, deletion and network-loss tests | L/M | Open |
| R-023 | Incomplete or overstated evidence leads users to fabricate/rely on an unverified prototype | H/H | Release / Documentation | Label static/simulation/bench/field evidence, retain raw outputs, publish candid limitations, no production-ready claim before bring-up | PR/release checklist and artifact audit | L/H | Baseline policy set; ongoing |

## Highest-priority gates

1. **R-014** no longer blocks schematic capture: exact component identities, manufacturer sources, and a GPIO map are recorded. It still blocks PCB outline/enclosure/fabrication until received revisions and geometry are confirmed.
2. **R-001/R-002/R-003/R-004/R-005/R-008** block any alarm-reliability claim until software fixtures and applicable bench tests pass.
3. **R-009/R-010/R-012/R-013** block write-capable pairing/update release until negative and recovery tests exist.
4. **R-006/R-007/R-015/R-017/R-020** block enclosure/fabrication readiness until physical measurements exist.
5. **R-023** applies to every PR and release: unperformed physical tests remain open, never inferred from static checks.
