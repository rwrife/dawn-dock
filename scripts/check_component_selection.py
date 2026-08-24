#!/usr/bin/env python3
"""Validate the Rev A component-selection artifacts without third-party packages."""

from __future__ import annotations

import csv
import datetime as dt
import sys
from collections import Counter
from decimal import Decimal, InvalidOperation
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOM = ROOT / "bom" / "preliminary-bom.csv"
NON_SCHEMATIC = ROOT / "bom" / "non-schematic-items.csv"
PIN_MAP = ROOT / "hardware" / "pin-allocation.csv"
SOURCES = ROOT / "docs" / "source-manifest.csv"
DECISION = ROOT / "docs" / "component-validation.md"

BOM_REQUIRED = {
    "Status",
    "Category",
    "Reference",
    "Qty",
    "Selection",
    "Manufacturer",
    "MPN",
    "Unit_Cost_USD",
    "Extended_Cost_USD",
    "Observed_UTC",
    "Availability_Observation",
    "Datasheet_or_Drawing",
    "Notes",
}
REQUIRED_NETS = {
    "+5V_SYS",
    "+3V3",
    "GND",
    "TFT_SCLK",
    "TFT_MOSI",
    "TFT_MISO",
    "TFT_CS",
    "TFT_DC",
    "TFT_RST",
    "LCD_BL",
    "I2C_SDA",
    "I2C_SCL",
    "RTC_INT_N",
    "I2S_BCLK",
    "I2S_LRCLK",
    "I2S_DOUT",
    "AMP_SD",
    "ENC_A",
    "ENC_B",
    "ENC_SW",
    "SNOOZE_N",
    "BRIGHTNESS_N",
}
FORBIDDEN_APP_GPIOS = {0, 3, 19, 20, 35, 36, 37, 38, 43, 44, 45, 46}
ALLOWED_TBD_CATEGORIES = {"Carrier passives", "Carrier PCB", "Enclosure"}


def read_csv(path: Path, errors: list[str]) -> tuple[list[dict[str, str]], set[str]]:
    if not path.is_file():
        errors.append(f"missing {path.relative_to(ROOT)}")
        return [], set()
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            rows = list(reader)
            return rows, set(reader.fieldnames or [])
    except (csv.Error, UnicodeDecodeError) as exc:
        errors.append(f"{path.relative_to(ROOT)}: cannot parse CSV: {exc}")
        return [], set()


def parse_utc(value: str) -> bool:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def main() -> int:
    errors: list[str] = []

    bom_rows, bom_fields = read_csv(BOM, errors)
    missing = BOM_REQUIRED - bom_fields
    if missing:
        errors.append(f"bom/preliminary-bom.csv: missing columns {sorted(missing)}")

    selected = [row for row in bom_rows if row.get("Status") == "Selected"]
    rejected = [row for row in bom_rows if row.get("Status") == "Rejected"]
    total = Decimal("0")
    references: list[str] = []
    for line, row in enumerate(bom_rows, start=2):
        ref = row.get("Reference", "").strip()
        if ref:
            references.append(ref)
        if not parse_utc(row.get("Observed_UTC", "")):
            errors.append(f"bom line {line}: invalid timezone-aware Observed_UTC")
        try:
            qty = Decimal(row.get("Qty", ""))
            unit = Decimal(row.get("Unit_Cost_USD", ""))
            extended = Decimal(row.get("Extended_Cost_USD", ""))
        except InvalidOperation:
            errors.append(f"bom line {line}: Qty and costs must be numeric")
            continue
        if abs((qty * unit) - extended) > Decimal("0.0001"):
            errors.append(f"bom line {line}: extended cost does not equal quantity x unit cost")
        if row.get("Status") == "Selected":
            total += extended
            if row.get("Category") not in ALLOWED_TBD_CATEGORIES:
                for field in ("Manufacturer", "MPN", "Datasheet_or_Drawing"):
                    if not row.get(field, "").strip() or row[field].strip() == "TBD":
                        errors.append(f"bom line {line}: selected part missing {field}")
            if not row.get("Availability_Observation", "").strip():
                errors.append(f"bom line {line}: selected part missing dated availability note")

    duplicate_refs = sorted(ref for ref, count in Counter(references).items() if count > 1)
    if duplicate_refs:
        errors.append(f"duplicate BOM references: {', '.join(duplicate_refs)}")
    if not selected:
        errors.append("BOM has no selected rows")
    if not any("Waveshare" in row.get("Manufacturer", "") and row.get("Status") == "Rejected" for row in rejected):
        errors.append("BOM does not retain the rejected integrated Waveshare comparison")

    decision_text = DECISION.read_text(encoding="utf-8") if DECISION.is_file() else ""
    for marker in (
        "approved for schematic capture",
        "not approved for fabrication",
        "microphone-free",
        "still unverified",
        "2026-08-23",
    ):
        if marker.casefold() not in decision_text.casefold():
            errors.append(f"docs/component-validation.md: missing evidence marker {marker!r}")
    if total > Decimal("75") and "above the $75 target ceiling" not in decision_text:
        errors.append("BOM exceeds $75 but decision record does not explain the overage")

    pin_rows, pin_fields = read_csv(PIN_MAP, errors)
    if not {"Net", "ESP32-S3 GPIO", "Shared bus or conflict rule", "Required test access"} <= pin_fields:
        errors.append("hardware/pin-allocation.csv: missing required columns")
    nets = {row.get("Net", "").strip() for row in pin_rows}
    missing_nets = sorted(REQUIRED_NETS - nets)
    if missing_nets:
        errors.append(f"pin allocation missing required nets: {', '.join(missing_nets)}")
    app_gpio_rows: dict[int, list[str]] = {}
    for line, row in enumerate(pin_rows, start=2):
        raw = row.get("ESP32-S3 GPIO", "").strip()
        subsystem = row.get("Subsystem", "")
        if raw.isdigit() and subsystem not in {"Reserved", "Unavailable", "Service"}:
            gpio = int(raw)
            app_gpio_rows.setdefault(gpio, []).append(row.get("Net", ""))
            if gpio in FORBIDDEN_APP_GPIOS:
                errors.append(f"pin allocation line {line}: application uses reserved GPIO{gpio}")
        if subsystem not in {"Reserved", "Unavailable"} and not row.get("Required test access", "").strip():
            errors.append(f"pin allocation line {line}: missing test-access disposition")
    duplicate_gpios = {gpio: nets for gpio, nets in app_gpio_rows.items() if len(nets) > 1}
    if duplicate_gpios:
        errors.append(f"application GPIO collision(s): {duplicate_gpios}")

    source_rows, source_fields = read_csv(SOURCES, errors)
    if not {"manufacturer", "mpn_or_sku", "url", "retrieved_utc", "status_or_gap"} <= source_fields:
        errors.append("docs/source-manifest.csv: missing required columns")
    for line, row in enumerate(source_rows, start=2):
        if not row.get("url", "").startswith("https://"):
            errors.append(f"source manifest line {line}: URL must use HTTPS")
        if not parse_utc(row.get("retrieved_utc", "")):
            errors.append(f"source manifest line {line}: invalid timezone-aware retrieved_utc")

    non_schematic_rows, non_schematic_fields = read_csv(NON_SCHEMATIC, errors)
    if not {"Item", "MPN_or_product_ID", "Status", "Notes"} <= non_schematic_fields:
        errors.append("bom/non-schematic-items.csv: missing required columns")
    required_non_schematic = {"US USB-C supply with captive cable", "Printed enclosure set", "M3 heat-set inserts", "M3 enclosure screws", "Desk feet", "Encoder knob"}
    present_non_schematic = {row.get("Item", "") for row in non_schematic_rows}
    absent_non_schematic = sorted(required_non_schematic - present_non_schematic)
    if absent_non_schematic:
        errors.append(f"non-schematic item list missing: {', '.join(absent_non_schematic)}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1

    print(f"PASS: parsed {len(bom_rows)} BOM rows ({len(selected)} selected, {len(rejected)} rejected)")
    print(f"PASS: selected planning subtotal is ${total:.2f}; documented target delta is ${total - Decimal('75'):.2f}")
    print(f"PASS: {len(pin_rows)} pin/resource rows cover {len(REQUIRED_NETS)} required nets without application GPIO collisions")
    print(f"PASS: {len(source_rows)} dated source records use HTTPS URLs")
    print(f"PASS: {len(non_schematic_rows)} non-schematic/tooling items are tracked separately")
    return 0


if __name__ == "__main__":
    sys.exit(main())
