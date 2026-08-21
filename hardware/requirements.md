# Hardware requirements

Status: initial measurable targets for review, not verified performance.

## Electrical

| ID | Requirement | Initial target / verification |
|---|---|---|
| ELEC-01 | Input power | 5 V USB from certified enclosed supply; no mains circuitry |
| ELEC-02 | Peak input current | Design target ≤1.5 A; measure worst case with display, radio, and audio active |
| ELEC-03 | Brownout behavior | No undefined output state; recover to valid time/alarm state and log reset cause |
| ELEC-04 | Time retention | Maintain RTC time through 24 h main-power removal; verify actual backup implementation |
| ELEC-05 | Alarm persistence | Stored alarms survive 100 controlled power cycles without schema/data loss |
| ELEC-06 | Controls | Dedicated snooze and brightness inputs plus rotary navigation; debounce verified in firmware and test fixture |
| ELEC-07 | Display dimming | Manual blackout plus low setting measured at the display; acceptance threshold set after first dark-room measurement |
| ELEC-08 | Audio | Adjustable alarm output; characterize SPL at 1 m and define a bounded default/max before release |
| ELEC-09 | Protection | Datasheet-derived USB input protection/decoupling and ESD review for user-accessible wired interfaces |
| ELEC-10 | Testability | Test points for 5 V, each generated rail, GND, reset/boot, RTC bus, backlight, audio, and representative controls |

## Mechanical

| ID | Requirement | Initial target / verification |
|---|---|---|
| MECH-01 | Envelope | Target ≤140 × 100 × 75 mm excluding cable; update from measured module/controls |
| MECH-02 | Stability | No tipping during a 10 N downward snooze press on a level surface |
| MECH-03 | Serviceability | Module and carrier removable with common hand tools; no destructive adhesive for primary service items |
| MECH-04 | Controls | Snooze identifiable by touch; other controls have distinct spacing/shape and readable labels |
| MECH-05 | Cable | Rear/side USB entry with strain relief and no sharp bend at connector |
| MECH-06 | Mounting | Carrier/module mounting holes and keepouts represented in PCB/enclosure sources |

## Environmental and usability

| ID | Requirement | Initial target / verification |
|---|---|---|
| ENV-01 | Indoor range | 10–35 °C, non-condensing home/office use |
| ENV-02 | Surface temperature | Measure at 35 °C ambient worst case; no user-accessible hot spot above project limit set in risk review |
| ENV-03 | Night operation | Screen can be blanked without disabling alarms; physical brightness override works offline |
| ENV-04 | Noise | No fan; avoid coil whine and unintended periodic audio in quiet room |
| ENV-05 | Accessibility | High-contrast modes, large text, non-color-only state indicators, and tactile primary controls |

## Connectivity and privacy

| ID | Requirement | Initial target / verification |
|---|---|---|
| CONN-01 | Offline core | Clock, stored alarms, snooze, dismiss, brightness, and menu operate with radios disabled |
| CONN-02 | Pairing | Explicit short pairing window; unique secret; no default universal credential |
| CONN-03 | Sync | Validate protocol version, payload size, schema, revision, and replay/nonce before applying |
| CONN-04 | Failure isolation | Network/calendar/weather failure cannot suppress or delay local alarm evaluation |
| CONN-05 | Data minimization | Store only selected event fields needed for accepted alarms; support erase/export |
| CONN-06 | Recovery | Local factory reset and USB flashing/recovery remain available without cloud service |

## Cost and sourcing

| ID | Requirement | Initial target / verification |
|---|---|---|
| COST-01 | Prototype target | USD 45–70 for electronics, carrier, basic enclosure, cable, and ordinary fasteners; re-price before purchase |
| COST-02 | Hard planning ceiling | Prefer <USD 75 excluding phone/computer and maker tools; any exception requires written rationale |
| COST-03 | Source of truth | Final Manufacturer/MPN/supplier data lives in KiCad symbol properties and exports to `bom/bom.csv` |
| COST-04 | Validation | No purchase until voltage/current/pinout/package/lifecycle/source checks and BOM review are complete |

## Safety exclusions

Dawn Dock is not medical equipment, an emergency notification device, a smoke/CO/security alarm, or a guaranteed wake-up appliance. It must not switch mains loads. Primary power is USB SELV only.
