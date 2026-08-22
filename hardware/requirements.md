# Hardware and product requirements

**Baseline:** v0.1
**Status:** frozen MVP targets for downstream design; performance remains unverified until the named evidence exists
**Architecture:** [system baseline](../docs/system-architecture.md)
**Traceability:** [verification matrix](../docs/verification-matrix.md)

The word *target* defines an acceptance limit, not a measurement claim. Open decisions are explicit and block the affected release claim.

## Electrical

| ID | Requirement | Acceptance and evidence |
|---|---|---|
| ELEC-01 | Input power | USB 5 V SELV only from a certified enclosed supply rated at least 2 A; no mains circuitry. Static schematic/BOM inspection plus assembled visual inspection. |
| ELEC-02 | Peak input current | Device design ceiling 1.5 A (7.5 W) at 5 V. Replace provisional allocations with source-backed maxima, then measure idle, simultaneous display/radio/audio peak, and inrush at the device input. |
| ELEC-03 | Brownout behavior | No undefined output state. Recover to validated time/schedule state, expose reset cause, and avoid duplicate ring side effects. Verify by host fixtures and controlled bench voltage sag/reset. |
| ELEC-04 | Time retention | Maintain valid RTC time through at least 24 h main-power removal and report measured drift/interval. RTC/backup implementation is open pending issue #2 source review. |
| ELEC-05 | Alarm persistence | Committed schedule survives 100 controlled power cycles with no schema loss, partial update, or duplicate occurrence. Requires automated bench evidence plus storage fixtures. |
| ELEC-06 | Controls | Dedicated snooze and brightness plus rotary navigation. One debounced action per gesture and valid-press response within 100 ms under normal load; verify with host and bench timing. |
| ELEC-07 | Display dimming | Manual blackout without disabling alarms. Lowest non-black target ≤1 cd/m² normal to display in a dark room; measure candidate and change module/control path if unmet. |
| ELEC-08 | Audio | Adjustable normal range target 60–75 dBA at 1 m; maximum target ≤80 dBA at 1 m, A-weighted slow response in final enclosure. This is not a wake guarantee. |
| ELEC-09 | Protection | Manufacturer-derived input protection/decoupling and ESD review for user-accessible wired interfaces; no undocumented header/USB back-power path. Verify by datasheet/schematic review, ERC/cross analysis, and staged bring-up. |
| ELEC-10 | Testability | Named test access for 5 V, every generated rail, GND, reset/boot, RTC bus, backlight, audio, and representative controls. Verify in schematic/PCB and by assembled continuity. |

## Mechanical

| ID | Requirement | Acceptance and evidence |
|---|---|---|
| MECH-01 | Envelope | Maximum 140 × 100 × 75 mm excluding cable; verify in CAD and on the assembly. |
| MECH-02 | Stability | No tipping during a 10 N downward snooze press on a level surface; bench force test required. |
| MECH-03 | Serviceability | Module and carrier removable with common hand tools; no destructive adhesive for primary service items. Review CAD/assembly and perform disassembly check. |
| MECH-04 | Controls | Snooze identifiable by touch; controls have distinct spacing/shape and readable labels. Static accessibility review plus assembled evaluation. |
| MECH-05 | Cable | Rear/side USB entry with strain relief and no sharp connector bend. Verify CAD and assembled routing. |
| MECH-06 | Mounting | Carrier/module holes, antenna/module keepouts, and service clearances represented in editable PCB/enclosure sources and cross-checked to manufacturer drawings. |

## Environmental and usability

| ID | Requirement | Acceptance and evidence |
|---|---|---|
| ENV-01 | Indoor range | 10–35 °C, non-condensing. Validate all selected component ratings, then run worst-case operation at 35 °C ambient. |
| ENV-02 | Surface temperature | A numeric user-accessible limit is an open decision pending enclosure material/contact review. No release claim until a limit is recorded and measured at 35 °C ambient. |
| ENV-03 | Night operation | Screen blackout does not disable alarms; physical brightness override works with radios disabled. Software and target bench tests required. |
| ENV-04 | Noise | No fan. No unintended periodic audio or objectionable coil noise in a quiet-room bench observation. |
| ENV-05 | Accessibility | High-contrast/non-color states, text scaling to 200%, app targets ≥48 × 48 logical pixels, logical focus/screen-reader/reduced-motion support, and tactile primary controls. Text contrast target WCAG 2.2 AA. |

## Alarm behavior

`docs/alarm-semantics.md` is the normative state/timing specification.

| ID | Requirement | Acceptance and evidence |
|---|---|---|
| ALARM-01 | Deterministic states | Implement disabled, armed, ringing, snoozed, dismissed, timed-out, and missed outcomes with durable occurrence identity. Host transition fixtures and target tests. |
| ALARM-02 | DST | Spring gaps shift once to earliest valid instant; fall folds ring once at the first occurrence by default and surface ambiguity in preview. Host fixtures for at least two IANA zones. |
| ALARM-03 | Time correction | Forward correction crossing due by ≤10 min rings late once; >10 min records missed. Backward correction never replays a journaled occurrence. Boundary fixtures at 9:59/10:00/10:01. |
| ALARM-04 | Snooze/timeout | Default 9 min, configurable 1–30 min, maximum 6 consecutive snoozes, 60 min total occurrence lifetime. Host and target interaction tests. |
| ALARM-05 | Reboot recovery | Resume active occurrence only inside its lifetime; outside it record missed. Preserve schedule and prevent duplicate occurrence admission/journal records across reset; intentional recovered alert output may resume once after stable boot. Persistence fixtures plus bench resets/power cycling. |

## Connectivity, security, and privacy

| ID | Requirement | Acceptance and evidence |
|---|---|---|
| CONN-01 | Offline core | Clock, committed alarms, snooze, dismiss, brightness, menu, and diagnostics operate with radios disabled. Require a 72 h bench integration run; longer operation is field evidence. |
| CONN-02 | Pairing | Physical pairing window ≤120 s, unique device material, no universal credential, close after 5 failures; lockout never affects physical alarm controls. |
| CONN-03 | Sync | Validate protocol major, ≤64 KiB envelope, operation limits, schema, nonce/message replay, and expected revision before atomic apply. |
| CONN-04 | Failure isolation | Network, calendar, weather, discovery, and pairing failure cannot suppress or delay local alarm evaluation. Verify with overload/radio-loss software and bench tests. |
| CONN-05 | Data minimization | Retain only fields needed for accepted alarms and minimal provenance. No account or telemetry; support local erase/export and selected-file import. |
| CONN-06 | Recovery | Local factory reset requires a target 5 s physical gesture plus on-device confirmation. USB flash/recovery remains available without cloud service. |

Security details and deferred cryptographic decisions are in [the threat model](../docs/threat-model.md).

## Cost and sourcing

| ID | Requirement | Acceptance and evidence |
|---|---|---|
| COST-01 | Prototype target | Re-priced total under USD 75 for electronics, carrier, basic enclosure, cable, supply, and ordinary fasteners; exclude user phone/computer and maker tools. |
| COST-02 | Price truth | Every price/stock observation is dated and identified as non-guaranteed. Any amount above USD 75 requires a recorded architecture/risk decision. |
| COST-03 | Source of truth | Final Manufacturer/MPN/supplier/datasheet/notes live in KiCad symbol properties and export to `bom/bom.csv`; non-schematic items are tracked separately. |
| COST-04 | Validation | No purchase before voltage/current/pinout/package/thermal/lifecycle/source checks and BOM review. Alternatives require equal validation. |

## Safety exclusions

Dawn Dock is not medical equipment, an emergency notification device, a smoke/CO/security alarm, or a guaranteed wake-up appliance. It must not switch mains loads. Primary power is USB 5 V SELV only. Static analysis, simulation, software tests, bench tests, and field tests are reported as distinct evidence classes; an unbuilt prototype is never described as physically tested.
