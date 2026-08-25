#!/usr/bin/env python3
"""Validate Dawn Dock schematic-derived BOM and analyzer evidence."""
from __future__ import annotations

import csv
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCH = ROOT / "hardware/kicad/dawn-dock.kicad_sch"
PRO = ROOT / "hardware/kicad/dawn-dock.kicad_pro"
OUT = ROOT / "hardware/kicad/reports/hardware-validation.json"

REQUIRED_NETS = {
    "VBUS", "+5V_SYS", "+3V3", "GND", "VBAT_RTC", "CHIP_PU", "BOOT_GPIO0",
    "I2C_SDA", "I2C_SCL", "RTC_INT_N", "LCD_BL", "TFT_SCLK", "TFT_MOSI",
    "TFT_MISO", "TFT_CS", "TFT_DC", "TFT_RST", "TP_INT", "TP_RST", "SD_CS",
    "I2S_BCLK", "I2S_LRCLK", "I2S_DOUT", "AMP_SD", "SPK+", "SPK-", "ENC_A",
    "ENC_B", "ENC_SW", "SNOOZE_N", "BRIGHTNESS_N", "U0TXD", "U0RXD",
    "EFUSE_DVDT", "EFUSE_ILM", "EFUSE_FLT_N",
}
EXPECTED_MPN = {
    "ESP32-S3-DEVKITC-1-N8R8", "3.5inch Capacitive Touch LCD", "DS3231MZ+",
    "CR2032; 3003", "3006", "8ohm 2W Speaker (B)", "4162", "B3F-1000",
    "PEC11R-4215F-S0024", "SN74LVC14APWR", "USB4105-GF-A",
    "TPS259531DSGR", "LESD8LH5.0CT5G", "RC0603FR-075K1L",
    "RC0603FR-071K53L", "RC0603FR-074K7L",
}
PIN_EXPECTATIONS = {
    ("+5V_SYS", "U2", "5"), ("VBAT_RTC", "U1", "6"), ("VBAT_RTC", "BT1", "1"),
    ("I2C_SDA", "A1", "J1-12"), ("I2C_SCL", "A1", "J1-15"),
    ("RTC_INT_N", "A1", "J3-5"), ("LCD_BL", "A1", "J1-6"),
    ("I2S_BCLK", "A1", "J1-9"), ("I2S_LRCLK", "A1", "J1-10"),
    ("I2S_DOUT", "A1", "J1-11"), ("AMP_SD", "A1", "J3-8"),
    ("ENC_A", "A1", "J1-4"), ("ENC_B", "A1", "J1-5"),
    ("ENC_SW", "A1", "J1-7"), ("SNOOZE_N", "A1", "J1-8"),
    ("BRIGHTNESS_N", "A1", "J3-7"), ("BOOT_GPIO0", "A1", "J3-14"),
}


def parse_sexp(text: str):
    tokens = re.findall(r'\(|\)|"(?:\\.|[^"\\])*"|[^\s()]+', text)
    stack: list[list] = []
    root: list = []
    current = root
    for token in tokens:
        if token == "(":
            child: list = []
            current.append(child)
            stack.append(current)
            current = child
        elif token == ")":
            if not stack: raise ValueError("unbalanced closing parenthesis")
            current = stack.pop()
        elif token.startswith('"'):
            current.append(bytes(token[1:-1], "utf-8").decode("unicode_escape"))
        else:
            current.append(token)
    if stack: raise ValueError("unbalanced opening parenthesis")
    return root


def fresh_net_map(path: Path) -> dict[str, list[tuple[str, str]]]:
    tree = parse_sexp(path.read_text(encoding="utf-8"))
    export = next((x for x in tree if isinstance(x, list) and x and x[0] == "export"), None)
    nets_node = next((x for x in export or [] if isinstance(x, list) and x and x[0] == "nets"), None)
    if nets_node is None: raise ValueError("netlist has no nets section")
    result: dict[str, list[tuple[str, str]]] = {}
    for net in nets_node[1:]:
        if not isinstance(net, list) or not net or net[0] != "net": continue
        name_node = next((x for x in net if isinstance(x, list) and x and x[0] == "name"), None)
        if not name_node or len(name_node) < 2: continue
        name = str(name_node[1]).removeprefix("/")
        nodes: list[tuple[str, str]] = []
        for node in net:
            if not isinstance(node, list) or not node or node[0] != "node": continue
            ref_node = next((x for x in node if isinstance(x, list) and x and x[0] == "ref"), None)
            pin_node = next((x for x in node if isinstance(x, list) and x and x[0] == "pin"), None)
            if ref_node and pin_node: nodes.append((str(ref_node[1]), str(pin_node[1])))
        result[name] = nodes
    return result


def source_label(path: Path) -> str:
    try: return str(path.resolve().relative_to(ROOT.resolve()))
    except ValueError: return path.name


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--netlist", type=Path, required=True, help="fresh KiCad-exported netlist")
    parser.add_argument("--bom", type=Path, required=True, help="fresh KiCad-exported BOM")
    parser.add_argument("--erc", type=Path, required=True, help="fresh KiCad ERC report")
    parser.add_argument("--output", type=Path, default=OUT)
    args = parser.parse_args()
    errors: list[str] = []
    for path in (SCH, PRO, args.bom, args.erc, args.netlist):
        if not path.is_file():
            try: shown = path.relative_to(ROOT)
            except ValueError: shown = path
            errors.append(f"missing {shown}")
    if errors:
        for error in errors: print("ERROR:", error)
        return 1
    rows = list(csv.DictReader(args.bom.open(newline="", encoding="utf-8-sig")))
    required_columns = {"Reference", "Qty", "Value", "Footprint", "Manufacturer", "MPN", "Supplier", "Estimated_Unit_Cost_USD", "Price_Observed_UTC", "Notes", "DNP"}
    missing_columns = required_columns - set(rows[0]) if rows else required_columns
    if missing_columns: errors.append(f"BOM missing columns: {sorted(missing_columns)}")
    for row in rows:
        for field in ("Reference", "Qty", "Value", "Manufacturer", "MPN", "Supplier", "Estimated_Unit_Cost_USD", "Price_Observed_UTC", "Notes"):
            if not row.get(field, "").strip(): errors.append(f"BOM {row.get('Reference','?')} missing {field}")
        if row.get("Price_Observed_UTC") != "2026-08-23": errors.append(f"BOM {row.get('Reference')} has unexpected price date")
    mpns = {row["MPN"] for row in rows}
    if missing := EXPECTED_MPN - mpns: errors.append(f"BOM missing selected MPNs: {sorted(missing)}")
    dnp = [r for r in rows if r.get("DNP")]
    if len(dnp) != 1 or dnp[0]["MPN"] != "RC0603FR-074K7L" or int(dnp[0]["Qty"]) != 2:
        errors.append("expected one grouped DNP line containing two RC0603FR-074K7L pull-ups")
    fresh_nets = fresh_net_map(args.netlist)
    net_names = set(fresh_nets)
    observed = {(net, ref, pin) for net, nodes in fresh_nets.items() for ref, pin in nodes}
    connected_refs = {ref for nodes in fresh_nets.values() for ref, _ in nodes}
    vbat = set(fresh_nets.get("VBAT_RTC", []))
    connectivity_source = source_label(args.netlist)
    if missing := REQUIRED_NETS - net_names: errors.append(f"connectivity source missing required nets: {sorted(missing)}")
    if missing := PIN_EXPECTATIONS - observed: errors.append(f"critical pin mappings missing: {sorted(missing)}")
    if vbat != {("U1", "6"), ("BT1", "1")}:
        errors.append(f"VBAT_RTC must contain only U1.6 and BT1.1, found {sorted(vbat)}")

    erc = args.erc.read_text(encoding="utf-8")
    if "ERC messages: 0  Errors 0  Warnings 0" not in erc:
        errors.append("native ERC report is not clean")
    result = {
        "status": "fail" if errors else "pass",
        "evidence_class": "static_analysis",
        "schematic": str(SCH.relative_to(ROOT)),
        "bom_rows": len(rows),
        "bom_component_quantity": sum(int(r["Qty"]) for r in rows),
        "netlist_connected_components": len(connected_refs),
        "netlist_nets": len(fresh_nets),
        "required_nets_checked": len(REQUIRED_NETS),
        "critical_pin_mappings_checked": len(PIN_EXPECTATIONS),
        "connectivity_source": connectivity_source,
        "bom_source": source_label(args.bom),
        "erc_source": source_label(args.erc),
        "fresh_inputs_required": True,
        "native_erc": {"errors": 0, "warnings": 0} if not errors else "see errors",
        "intentional_dnp": [r["Reference"] for r in dnp],
        "physical_tests_performed": False,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if errors:
        for error in errors: print("ERROR:", error)
        return 1
    print(f"PASS: native ERC 0 errors/0 warnings; {len(connected_refs)} connected components; {len(fresh_nets)} fresh nets")
    print(f"PASS: {len(rows)} BOM rows / {result['bom_component_quantity']} components; required sourcing fields complete")
    print(f"PASS: {len(REQUIRED_NETS)} required nets and {len(PIN_EXPECTATIONS)} critical pin mappings present")
    print("PASS: VBAT_RTC has only U1.6 and BT1.1; no schematic charge path")
    print("PASS: physical_tests_performed=false")
    return 0

if __name__ == "__main__":
    sys.exit(main())
