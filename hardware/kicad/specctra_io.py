#!/usr/bin/env python3
"""Export/import Specctra routing data using KiCad's official pcbnew API."""
from __future__ import annotations

import argparse
import re
import shlex
from pathlib import Path

import pcbnew


ROUTING_CLASSES = [
    ("VBUS_1A5", {"VBUS"}, 1200, 250),
    ("Protected5V", {"+5V_SYS"}, 1000, 250),
    ("Ground", {"GND"}, 600, 250),
    ("LogicPower", {"+3V3", "VBAT_RTC"}, 500, 250),
    ("Audio", {"SPK+", "SPK-"}, 500, 200),
    (
        "FastDigital",
        {
            "I2C_SCL", "I2C_SDA", "I2S_BCLK", "I2S_DOUT", "I2S_LRCLK",
            "TFT_CS", "TFT_DC", "TFT_MISO", "TFT_MOSI", "TFT_RST", "TFT_SCLK",
        },
        250,
        200,
    ),
]


def _balanced_block(text: str, start: int) -> tuple[int, int]:
    depth = 0
    quoted = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return start, index + 1
    raise ValueError("unterminated Specctra class block")


def _dsn_atom(value: str) -> str:
    return value if re.fullmatch(r"[A-Za-z0-9_+/.]+", value) else '"' + value.replace('"', '\\"') + '"'


def inject_routing_classes(dsn_path: Path) -> None:
    text = dsn_path.read_text(encoding="utf-8")
    start = text.find("(class kicad_default")
    if start < 0:
        raise ValueError("KiCad DSN lacks expected kicad_default class")
    block_start, block_end = _balanced_block(text, start)
    block = text[block_start:block_end]
    circuit_at = block.find("(circuit")
    if circuit_at < 0:
        raise ValueError("KiCad DSN default class lacks circuit settings")
    header = block[len("(class kicad_default"):circuit_at]
    all_nets = shlex.split(header)
    assigned: set[str] = set()
    class_blocks: list[str] = []
    via_rule = '(circuit\n        (use_via "Via[0-1]_600:300_um")\n      )'
    for name, bare_names, width_um, clearance_um in ROUTING_CLASSES:
        members = [net for net in all_nets if net.removeprefix("/") in bare_names]
        if members:
            assigned.update(members)
            class_blocks.append(
                f"(class {name} {' '.join(_dsn_atom(net) for net in members)}\n"
                f"      {via_rule}\n"
                f"      (rule\n        (width {width_um})\n        (clearance {clearance_um})\n      )\n"
                f"    )"
            )
    default_members = [net for net in all_nets if net not in assigned]
    default_block = (
        f"(class kicad_default {' '.join(_dsn_atom(net) for net in default_members)}\n"
        f"      {via_rule}\n"
        f"      (rule\n        (width 250)\n        (clearance 200)\n      )\n"
        f"    )"
    )
    replacement = default_block + "\n    " + "\n    ".join(class_blocks)
    dsn_path.write_text(text[:block_start] + replacement + text[block_end:], encoding="utf-8")
    print("injected DSN net classes: " + ", ".join(["Default"] + [x[0] for x in ROUTING_CLASSES]))


def export_dsn(board_path: Path, dsn_path: Path) -> None:
    board = pcbnew.LoadBoard(str(board_path.resolve()))
    dsn_path.parent.mkdir(parents=True, exist_ok=True)
    if not pcbnew.ExportSpecctraDSN(board, str(dsn_path.resolve())):
        raise RuntimeError(f"KiCad failed to export {dsn_path}")
    inject_routing_classes(dsn_path)
    print(f"exported {dsn_path}")


def import_ses(board_path: Path, ses_path: Path, output_path: Path) -> None:
    board = pcbnew.LoadBoard(str(board_path.resolve()))
    if not pcbnew.ImportSpecctraSES(board, str(ses_path.resolve())):
        raise RuntimeError(f"KiCad failed to import {ses_path}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if not pcbnew.SaveBoard(str(output_path.resolve()), board):
        raise RuntimeError(f"KiCad failed to save {output_path}")
    print(f"imported {ses_path} into {output_path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    exp = sub.add_parser("export")
    exp.add_argument("--board", required=True, type=Path)
    exp.add_argument("--dsn", required=True, type=Path)
    imp = sub.add_parser("import")
    imp.add_argument("--board", required=True, type=Path)
    imp.add_argument("--ses", required=True, type=Path)
    imp.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "export":
        export_dsn(args.board, args.dsn)
    else:
        import_ses(args.board, args.ses, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
