#!/usr/bin/env python3
"""Generate the editable Dawn Dock Rev A carrier PCB from a KiCad netlist.

Run this script inside the pinned KiCad 9 container after exporting a fresh
netlist from ``dawn-dock.kicad_sch``.  It uses KiCad's official ``pcbnew``
Python API to load the assigned footprints, assign every pad net, place the
mechanical/electrical blocks, add board metadata, and enforce the ESP32-S3
antenna keepout.  Routing and copper-zone fill are separate reproducible steps.

This is static layout evidence only.  Exact received-module orientation,
enclosure fit, and all bench behavior remain physical verification gates.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

import pcbnew

MM = pcbnew.FromMM
BOARD_X1, BOARD_Y1 = 20.0, 20.0
BOARD_X2, BOARD_Y2 = 155.0, 115.0


@dataclass
class Component:
    ref: str
    value: str
    footprint: str
    functional_ref: str
    fields: dict[str, str] = field(default_factory=dict)
    dnp: bool = False


@dataclass
class NetNode:
    ref: str
    pin: str
    pinfunction: str = ""
    pintype: str = ""


@dataclass
class Net:
    name: str
    nodes: list[NetNode]


def tokenize(text: str) -> list[str]:
    """Tokenize KiCad's netlist S-expression without executing input."""
    out: list[str] = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch.isspace():
            i += 1
        elif ch in "()":
            out.append(ch)
            i += 1
        elif ch == '"':
            i += 1
            value: list[str] = []
            while i < len(text):
                ch = text[i]
                if ch == '"':
                    i += 1
                    break
                if ch == "\\" and i + 1 < len(text):
                    value.append(text[i + 1])
                    i += 2
                else:
                    value.append(ch)
                    i += 1
            else:
                raise ValueError("unterminated quoted string in netlist")
            out.append("".join(value))
        else:
            start = i
            while i < len(text) and not text[i].isspace() and text[i] not in "()":
                i += 1
            out.append(text[start:i])
    return out


def parse_sexp(text: str) -> list[Any]:
    tokens = tokenize(text)
    stack: list[list[Any]] = []
    root: list[Any] | None = None
    for token in tokens:
        if token == "(":
            node: list[Any] = []
            if stack:
                stack[-1].append(node)
            stack.append(node)
        elif token == ")":
            if not stack:
                raise ValueError("unexpected ')' in netlist")
            node = stack.pop()
            if not stack:
                if root is not None:
                    raise ValueError("multiple top-level expressions in netlist")
                root = node
        else:
            if not stack:
                raise ValueError("token outside expression in netlist")
            stack[-1].append(token)
    if stack:
        raise ValueError("unterminated expression in netlist")
    if root is None:
        raise ValueError("empty netlist")
    return root


def children(node: list[Any], keyword: str) -> list[list[Any]]:
    return [item for item in node[1:] if isinstance(item, list) and item and item[0] == keyword]


def child(node: list[Any], keyword: str) -> list[Any] | None:
    matches = children(node, keyword)
    return matches[0] if matches else None


def atom(node: list[Any], keyword: str, default: str = "") -> str:
    found = child(node, keyword)
    return str(found[1]) if found and len(found) > 1 else default


def locate(root: list[Any], keyword: str) -> list[Any]:
    found = child(root, keyword)
    if found is None:
        raise ValueError(f"netlist missing ({keyword} ...)")
    return found


def parse_netlist(path: Path) -> tuple[dict[str, Component], list[Net]]:
    root = parse_sexp(path.read_text(encoding="utf-8"))
    if not root or root[0] != "export":
        raise ValueError("expected KiCad '(export ...)' netlist")

    components: dict[str, Component] = {}
    for comp_node in children(locate(root, "components"), "comp"):
        ref = atom(comp_node, "ref")
        value = atom(comp_node, "value")
        footprint = atom(comp_node, "footprint")
        fields: dict[str, str] = {}
        fields_node = child(comp_node, "fields")
        if fields_node:
            for field_node in children(fields_node, "field"):
                name_node = child(field_node, "name")
                if name_node and len(name_node) > 1:
                    value_atom = next((x for x in field_node[1:] if not isinstance(x, list)), "")
                    fields[str(name_node[1])] = str(value_atom)
        for prop_node in children(comp_node, "property"):
            name = atom(prop_node, "name")
            if name:
                fields.setdefault(name, atom(prop_node, "value"))
        functional_ref = fields.get("Functional Reference", ref)
        dnp_node = child(comp_node, "dnp")
        dnp = bool(dnp_node and len(dnp_node) > 1 and str(dnp_node[1]).lower() == "yes")
        dnp = dnp or "DNP" in value.upper() or "DNP BY DEFAULT" in fields.get("BOM Comments", "").upper()
        if not ref:
            raise ValueError("component without reference")
        components[ref] = Component(ref, value, footprint, functional_ref, fields, dnp)

    nets: list[Net] = []
    for net_node in children(locate(root, "nets"), "net"):
        name = atom(net_node, "name")
        nodes = [
            NetNode(
                ref=atom(node, "ref"),
                pin=atom(node, "pin"),
                pinfunction=atom(node, "pinfunction"),
                pintype=atom(node, "pintype"),
            )
            for node in children(net_node, "node")
        ]
        if name:
            nets.append(Net(name, nodes))
    return components, nets


def v(x_mm: float, y_mm: float) -> pcbnew.VECTOR2I:
    return pcbnew.VECTOR2I(MM(x_mm), MM(y_mm))


def add_segment(board: pcbnew.BOARD, layer: int, start: tuple[float, float], end: tuple[float, float], width: float) -> None:
    shape = pcbnew.PCB_SHAPE(board)
    shape.SetShape(pcbnew.SHAPE_T_SEGMENT)
    shape.SetLayer(layer)
    shape.SetStart(v(*start))
    shape.SetEnd(v(*end))
    shape.SetWidth(MM(width))
    board.Add(shape)


def add_rectangle(board: pcbnew.BOARD, layer: int, x1: float, y1: float, x2: float, y2: float, width: float) -> None:
    for start, end in (
        ((x1, y1), (x2, y1)),
        ((x2, y1), (x2, y2)),
        ((x2, y2), (x1, y2)),
        ((x1, y2), (x1, y1)),
    ):
        add_segment(board, layer, start, end, width)


def add_text(
    board: pcbnew.BOARD,
    text: str,
    x_mm: float,
    y_mm: float,
    *,
    layer: int = pcbnew.F_SilkS,
    size_mm: float = 1.0,
    thickness_mm: float = 0.15,
    angle_deg: float = 0.0,
) -> None:
    item = pcbnew.PCB_TEXT(board)
    item.SetText(text)
    item.SetPosition(v(x_mm, y_mm))
    item.SetLayer(layer)
    item.SetTextSize(v(size_mm, size_mm))
    item.SetTextThickness(MM(thickness_mm))
    item.SetTextAngleDegrees(angle_deg)
    board.Add(item)


def add_rule_area(
    board: pcbnew.BOARD,
    layer: int,
    points: Iterable[tuple[float, float]],
    *,
    block_tracks: bool = True,
    block_vias: bool = True,
    block_copper: bool = True,
    block_pads: bool = False,
    block_footprints: bool = False,
) -> None:
    zone = pcbnew.ZONE(board)
    zone.SetLayer(layer)
    zone.SetIsRuleArea(True)
    zone.SetDoNotAllowTracks(block_tracks)
    zone.SetDoNotAllowVias(block_vias)
    zone.SetDoNotAllowCopperPour(block_copper)
    zone.SetDoNotAllowPads(block_pads)
    zone.SetDoNotAllowFootprints(block_footprints)
    polygon = zone.Outline()
    outline = polygon.NewOutline()
    for x_mm, y_mm in points:
        polygon.Append(MM(x_mm), MM(y_mm), outline)
    board.Add(zone)


def add_track(
    board: pcbnew.BOARD,
    net: pcbnew.NETINFO_ITEM,
    start: pcbnew.VECTOR2I,
    end: pcbnew.VECTOR2I,
    width_mm: float,
    layer: int = pcbnew.F_Cu,
) -> None:
    track = pcbnew.PCB_TRACK(board)
    track.SetLayer(layer)
    track.SetNet(net)
    track.SetStart(start)
    track.SetEnd(end)
    track.SetWidth(MM(width_mm))
    board.Add(track)


def add_via(
    board: pcbnew.BOARD,
    net: pcbnew.NETINFO_ITEM,
    position: pcbnew.VECTOR2I,
    diameter_mm: float = 0.60,
    drill_mm: float = 0.30,
) -> None:
    via = pcbnew.PCB_VIA(board)
    via.SetPosition(position)
    via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    via.SetNet(net)
    via.SetFrontWidth(MM(diameter_mm))
    via.SetDrill(MM(drill_mm))
    board.Add(via)


def find_pad(footprints: dict[str, pcbnew.FOOTPRINT], reference: str, number: str) -> pcbnew.PAD:
    matches = [item for item in footprints[reference].Pads() if str(item.GetNumber()) == number]
    if not matches:
        raise ValueError(f"missing expected pad {reference}.{number}")
    return matches[0]


def add_fixed_fanout(board: pcbnew.BOARD, footprints: dict[str, pcbnew.FOOTPRINT]) -> None:
    # Aligned USB-C CC resistors and eFuse status/current-limit resistors.
    for source_ref, source_pin, target_ref, target_pin, width in (
        ("J1", "A5", "R1", "1", 0.20),
        ("J1", "B5", "R2", "1", 0.20),
        ("U2", "6", "R4", "2", 0.18),
    ):
        source = find_pad(footprints, source_ref, source_pin)
        target = find_pad(footprints, target_ref, target_pin)
        add_track(board, source.GetNet(), source.GetPosition(), target.GetPosition(), width)

    ilm_source = find_pad(footprints, "U2", "7")
    ilm_target = find_pad(footprints, "R3", "1")
    ilm_bend = pcbnew.VECTOR2I(MM(44.0), ilm_source.GetPosition().y)
    add_track(board, ilm_source.GetNet(), ilm_source.GetPosition(), ilm_bend, 0.18)
    add_track(board, ilm_source.GetNet(), ilm_bend, ilm_target.GetPosition(), 0.18)

    # Fine-pitch USB VBUS and eFuse power pads receive short neckdowns so the
    # autorouter never attempts to force trunk width into 0.30/0.25 mm pads.
    usb_vbus_escapes: list[pcbnew.VECTOR2I] = []
    for connector_pin in ("A4", "A9"):
        source = find_pad(footprints, "J1", connector_pin)
        escape = pcbnew.VECTOR2I(MM(30.0), source.GetPosition().y)
        add_track(
            board,
            source.GetNet(),
            source.GetPosition(),
            escape,
            0.20,
        )
        add_via(board, source.GetNet(), escape)
        usb_vbus_escapes.append(escape)
    add_track(
        board,
        find_pad(footprints, "J1", "A4").GetNet(),
        usb_vbus_escapes[0],
        usb_vbus_escapes[1],
        0.60,
        pcbnew.B_Cu,
    )

    tvs_vbus = find_pad(footprints, "D1", "1")
    add_track(board, tvs_vbus.GetNet(), usb_vbus_escapes[1], tvs_vbus.GetPosition(), 0.20)
    input_cap_1 = find_pad(footprints, "C1", "1")
    input_cap_2 = find_pad(footprints, "C2", "1")
    cap_escape_1 = pcbnew.VECTOR2I(input_cap_1.GetPosition().x, MM(79.8))
    cap_escape_2 = pcbnew.VECTOR2I(input_cap_2.GetPosition().x, MM(79.8))
    for input_cap, escape in ((input_cap_1, cap_escape_1), (input_cap_2, cap_escape_2)):
        add_track(board, input_cap.GetNet(), input_cap.GetPosition(), escape, 0.25)
        add_via(board, input_cap.GetNet(), escape)
    add_track(board, input_cap_1.GetNet(), cap_escape_1, cap_escape_2, 0.50, pcbnew.B_Cu)

    vbus_pads = [find_pad(footprints, "U2", pin) for pin in ("2", "3", "4")]
    for source in vbus_pads:
        add_track(
            board,
            source.GetNet(),
            source.GetPosition(),
            pcbnew.VECTOR2I(MM(39.8), source.GetPosition().y),
            0.18,
        )
    add_track(
        board,
        vbus_pads[0].GetNet(),
        pcbnew.VECTOR2I(MM(39.8), vbus_pads[0].GetPosition().y),
        pcbnew.VECTOR2I(MM(39.8), vbus_pads[-1].GetPosition().y),
        0.25,
    )
    add_track(board, vbus_pads[0].GetNet(), vbus_pads[0].GetPosition(), vbus_pads[-1].GetPosition(), 0.18)

    output = find_pad(footprints, "U2", "5")
    add_track(
        board,
        output.GetNet(),
        output.GetPosition(),
        pcbnew.VECTOR2I(MM(44.2), output.GetPosition().y),
        0.18,
    )
    output_cap = find_pad(footprints, "C4", "1")
    output_bend = pcbnew.VECTOR2I(MM(44.2), output_cap.GetPosition().y)
    add_track(board, output.GetNet(), pcbnew.VECTOR2I(MM(44.2), output.GetPosition().y), output_bend, 0.18)
    add_track(board, output.GetNet(), output_bend, output_cap.GetPosition(), 0.25)

    decoupling_supply = find_pad(footprints, "C8", "1")
    decoupling_ground = find_pad(footprints, "C8", "2")
    u3_supply = find_pad(footprints, "U3", "14")
    u3_ground = find_pad(footprints, "U3", "13")
    add_track(board, u3_supply.GetNet(), u3_supply.GetPosition(), decoupling_supply.GetPosition(), 0.18)
    add_track(board, u3_ground.GetNet(), u3_ground.GetPosition(), decoupling_ground.GetPosition(), 0.18)


# Fixed mechanical and critical-circuit placement.  The coordinate system is
# the 135 x 95 mm carrier outline from (20,20) to (155,115).
PLACEMENT: dict[str, tuple[float, float, float]] = {
    "J_PWR1": (23.675, 75.0, 270.0),
    "R_CC1": (31.5, 72.925, 90.0),
    "R_CC2": (31.5, 75.925, 90.0),
    "D1": (33.0, 78.5, 0.0),
    "C_IN1": (35.0, 81.0, 0.0),
    "C_IN2": (39.0, 81.0, 180.0),
    "U2": (42.0, 74.0, 0.0),
    "C_DVDT1": (39.0, 71.0, 180.0),
    "R_ILIM1": (45.2, 71.5, 90.0),
    "R_FLT1": (46.8, 75.075, 90.0),
    "C_OUT1": (50.0, 79.5, 0.0),
    "C_OUT2": (54.0, 79.5, 0.0),
    "C_BULK1": (59.5, 79.5, 0.0),
    "A1": (135.0, 54.0, 0.0),
    "DS1": (55.0, 26.0, 90.0),
    "R_BL1": (75.0, 34.0, 0.0),
    "R_SD1": (79.0, 34.0, 0.0),
    "U1": (116.0, 96.0, 0.0),
    "BT1": (136.0, 101.0, 0.0),
    "C_RTC1": (113.0, 102.0, 0.0),
    "R_RTC1": (119.0, 102.0, 0.0),
    "A3": (36.0, 46.0, 90.0),
    "R_I2C1": (45.0, 55.0, 0.0),
    "R_I2C2": (49.0, 55.0, 0.0),
    "A2": (48.0, 88.0, 0.0),
    "R_AMP1": (59.0, 88.0, 0.0),
    "U3": (90.0, 88.0, 0.0),
    "C_U3": (95.0, 86.375, 270.0),
    "SW1": (78.0, 108.0, 0.0),
    "SW2": (108.0, 108.0, 0.0),
    "ENC1": (47.0, 104.0, 0.0),
    "R_CTRL1": (70.0, 98.0, 0.0),
    "R_CTRL2": (76.0, 98.0, 0.0),
    "R_CTRL3": (82.0, 98.0, 0.0),
    "R_CTRL4": (88.0, 98.0, 0.0),
    "R_CTRL5": (94.0, 98.0, 0.0),
    "H1": (25.0, 25.0, 0.0),
    "H2": (110.0, 25.0, 0.0),
    "H3": (25.0, 110.0, 0.0),
    "H4": (150.0, 110.0, 0.0),
}

# Thirty named test pads in a regular, probe-accessible central field.
for index in range(1, 31):
    col = (index - 1) % 6
    row = (index - 1) // 6
    PLACEMENT[f"TP{index}"] = (66.0 + 9.0 * col, 42.0 + 7.0 * row, 0.0)

LOCKED = {"J_PWR1", "A1", "DS1", "A3", "SW1", "SW2", "ENC1", "BT1", "H1", "H2", "H3", "H4"}


def footprint_library(project_dir: Path, library: str) -> Path:
    if library == "dawn-dock":
        return project_dir / "lib" / "dawn-dock.pretty"
    return Path("/usr/share/kicad/footprints") / f"{library}.pretty"


def load_footprint(project_dir: Path, component: Component) -> pcbnew.FOOTPRINT:
    if ":" not in component.footprint:
        raise ValueError(f"{component.ref}: invalid footprint id {component.footprint!r}")
    library, name = component.footprint.split(":", 1)
    library_path = footprint_library(project_dir, library)
    source = library_path / f"{name}.kicad_mod"
    if not source.is_file():
        raise FileNotFoundError(f"{component.ref}: footprint source not found: {source}")
    footprint = pcbnew.FootprintLoad(str(library_path), name)
    if footprint is None:
        raise ValueError(f"{component.ref}: KiCad failed to load footprint {component.footprint}")
    footprint.SetReference(component.ref)
    footprint.SetValue(component.value)
    footprint.SetFPID(pcbnew.LIB_ID(library, name))
    footprint.SetDNP(component.dnp)
    if component.functional_ref.startswith("TP") or component.functional_ref.startswith("H"):
        footprint.SetExcludedFromBOM(True)
        footprint.SetExcludedFromPosFiles(True)
    return footprint


def build_board(netlist_path: Path, output_path: Path) -> None:
    components, nets = parse_netlist(netlist_path)
    project_dir = output_path.parent
    board = pcbnew.BOARD()
    design = board.GetDesignSettings()
    design.m_TrackMinWidth = MM(0.18)
    design.m_MinClearance = MM(0.20)
    design.m_HoleClearance = MM(0.19)
    design.m_HoleToHoleMin = MM(0.25)
    design.m_CopperEdgeClearance = MM(0.50)
    design.m_MinThroughDrill = MM(0.25)
    design.m_ViasMinSize = MM(0.60)
    design.m_ViasMinAnnularWidth = MM(0.15)

    title = board.GetTitleBlock()
    title.SetTitle("Dawn Dock USB/SELV carrier")
    title.SetRevision("A0 PCB prototype")
    title.SetDate("2026-08-26")
    title.SetCompany("Open hardware design — rwrife/dawn-dock")
    title.SetComment(0, "USB 5 V SELV only; no mains; not medical/life-safety")
    title.SetComment(1, "Prototype static layout; verify module orientation and enclosure fit before fabrication")
    title.SetComment(2, "CR2032 primary cell: DO NOT CHARGE")

    # Rectangular 135 x 95 mm outline, below the 140 x 100 mm product envelope.
    add_rectangle(board, pcbnew.Edge_Cuts, BOARD_X1, BOARD_Y1, BOARD_X2, BOARD_Y2, 0.10)

    # Load and place every component with a physical footprint.
    footprints: dict[str, pcbnew.FOOTPRINT] = {}
    missing_placement: list[str] = []
    for component in components.values():
        if not component.footprint:
            continue
        key = component.functional_ref
        placement = PLACEMENT.get(key) or PLACEMENT.get(component.ref)
        if placement is None:
            missing_placement.append(f"{component.ref}/{key}")
            continue
        footprint = load_footprint(project_dir, component)
        x_mm, y_mm, angle_deg = placement
        footprint.SetPosition(v(x_mm, y_mm))
        footprint.SetOrientationDegrees(angle_deg)
        footprint.SetLocked(key in LOCKED or component.ref in LOCKED)
        if component.ref == "J1":
            footprint.Reference().SetVisible(False)
        elif component.ref in {"U2", "R3", "R4"}:
            footprint.Reference().SetLayer(pcbnew.F_Fab)
        board.Add(footprint)
        footprints[component.ref] = footprint
    if missing_placement:
        raise ValueError("components lack deterministic placement: " + ", ".join(sorted(missing_placement)))

    # Three global front-side fiducials support optical assembly alignment for
    # the fine-pitch WSON/TSSOP parts.  They are board-only copper features,
    # excluded from BOM and placement files.
    fiducial_library = Path("/usr/share/kicad/footprints/Fiducial.pretty")
    for reference, position in (
        ("FID1", (31.0, 31.0)),
        ("FID2", (105.0, 35.0)),
        ("FID3", (31.0, 104.0)),
    ):
        fiducial = pcbnew.FootprintLoad(str(fiducial_library), "Fiducial_1mm_Mask2mm")
        if fiducial is None:
            raise ValueError("KiCad failed to load Fiducial:Fiducial_1mm_Mask2mm")
        fiducial.SetReference(reference)
        fiducial.SetValue("GLOBAL FIDUCIAL")
        fiducial.SetFPID(pcbnew.LIB_ID("Fiducial", "Fiducial_1mm_Mask2mm"))
        fiducial.Reference().SetVisible(False)
        fiducial.Value().SetVisible(False)
        fiducial.SetPosition(v(*position))
        fiducial.SetBoardOnly(True)
        fiducial.SetExcludedFromBOM(True)
        fiducial.SetExcludedFromPosFiles(True)
        fiducial.SetLocked(True)
        board.Add(fiducial)

    # Add named nets and assign every matching physical pad.  Missing pads are
    # fatal because they indicate a symbol/footprint pin-number mismatch.
    net_items: dict[str, pcbnew.NETINFO_ITEM] = {}
    pad_lookup: dict[tuple[str, str], list[pcbnew.PAD]] = {}
    for ref, footprint in footprints.items():
        for pad in footprint.Pads():
            pad_lookup.setdefault((ref, str(pad.GetNumber())), []).append(pad)

    missing_pads: list[str] = []
    assigned_pad_objects: set[int] = set()
    for net in nets:
        net_item = pcbnew.NETINFO_ITEM(board, net.name)
        board.Add(net_item)
        net_items[net.name] = net_item
        for node in net.nodes:
            if node.ref not in footprints:
                continue
            pads = pad_lookup.get((node.ref, node.pin), [])
            if not pads:
                missing_pads.append(f"{node.ref}.{node.pin} ({net.name})")
                continue
            for pad in pads:
                pad.SetNet(net_item)
                if node.pinfunction:
                    pad.SetPinFunction(node.pinfunction)
                if node.pintype:
                    pad.SetPinType(node.pintype)
                assigned_pad_objects.add(id(pad))
    if missing_pads:
        raise ValueError("netlist nodes have no matching footprint pad: " + ", ".join(sorted(missing_pads)))

    unassigned: list[str] = []
    for ref, footprint in footprints.items():
        for pad in footprint.Pads():
            number = str(pad.GetNumber())
            # SWIG may create a fresh Python proxy on every Pads() iteration,
            # so object identity is not stable.  Query KiCad's persisted pad
            # net state instead.  Empty is valid only for schematic NC pads;
            # those are reported for review but are not a generation failure.
            if number and not pad.GetNetname():
                unassigned.append(f"{ref}.{number}")
    if unassigned:
        print(
            "generate_pcb.py: intentionally/unmapped numbered pads (expected schematic NCs): "
            + ", ".join(sorted(unassigned)),
            file=sys.stderr,
        )

    add_fixed_fanout(board, footprints)

    # The ESP32-S3 module antenna sits at A1's negative-Y end.  The custom
    # socket rows begin at y=27.33 mm; this copper-free strip protects the
    # 4.7 mm overhang between the module outline and first header row.  It is a
    # conservative project rule based on the official DevKit/module orientation;
    # the received module and enclosure still require physical confirmation.
    antenna_keepout = [(116.0, 20.5), (154.0, 20.5), (154.0, 26.0), (116.0, 26.0)]
    for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
        add_rule_area(board, layer, antenna_keepout)
    add_rectangle(board, pcbnew.Dwgs_User, 116.0, 20.5, 154.0, 26.0, 0.25)

    # Silk legends and assembly constraints.  A later overlap gate may move
    # standalone text, but must not remove these meanings.
    add_text(board, "DAWN DOCK", 94.0, 81.5, size_mm=1.5, thickness_mm=0.25)
    add_text(board, "REV A0 PROTOTYPE", 94.0, 78.5, size_mm=0.9)
    add_text(board, "USB 5V SELV ONLY", 29.0, 84.0, size_mm=0.9, angle_deg=90.0)
    add_text(board, "SNOOZE", 78.0, 102.0, size_mm=0.9)
    add_text(board, "BRIGHT", 108.0, 102.0, size_mm=0.9)
    add_text(board, "MENU", 47.0, 113.0, size_mm=0.9)
    add_text(board, "SENSOR WINDOW", 27.0, 46.0, size_mm=0.8, angle_deg=90.0)
    add_text(board, "DISPLAY PIN 1", 35.0, 33.0, size_mm=0.8)
    add_text(board, "VERIFY DISPLAY ORIENTATION", 55.0, 31.0, size_mm=0.8)
    add_text(board, "ESP32 ANTENNA — NO COPPER/METAL", 135.0, 21.5, layer=pcbnew.F_Fab, size_mm=0.8)
    add_text(board, "CR2032 +", 126.0, 89.5, size_mm=0.9)
    add_text(board, "DO NOT CHARGE", 136.0, 113.0, size_mm=0.9)
    add_text(board, "OPEN HARDWARE CERN-OHL-S-2.0", 92.0, 22.0, layer=pcbnew.F_Fab, size_mm=0.8)

    # Net labels beside the probe field provide serviceability without putting
    # long value strings on production silkscreen.
    test_labels = [
        "VBUS", "5V", "3V3", "GND", "EN", "BOOT", "SDA", "SCL", "RTC", "BL",
        "SCLK", "MOSI", "MISO", "CS", "DC", "RST", "BCLK", "LRCLK", "DOUT", "AMP",
        "SPK+", "SPK-", "ENC-A", "ENC-B", "ENC-SW", "SNZ", "BRT", "TX", "RX", "FLT",
    ]
    for index in range(1, 31):
        comp = components.get(f"TP{index}")
        if comp is None:
            continue
        x_mm, y_mm, _ = PLACEMENT[f"TP{index}"]
        add_text(board, test_labels[index - 1], x_mm, y_mm + 2.2, size_mm=0.8, thickness_mm=0.12)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if not pcbnew.SaveBoard(str(output_path), board):
        raise RuntimeError(f"KiCad failed to save {output_path}")
    print(
        f"generated {output_path}: footprints={len(list(board.GetFootprints()))} nets={len(net_items)} "
        f"assigned_pads={len(assigned_pad_objects)} outline=135x95mm"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--netlist", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    build_board(args.netlist.resolve(), args.output.resolve())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # fail closed with a concise actionable message
        print(f"generate_pcb.py: error: {exc}", file=sys.stderr)
        raise
