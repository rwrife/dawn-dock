#!/usr/bin/env python3
"""Finalize the routed Dawn Dock PCB with filled dual-layer GND planes."""
from __future__ import annotations

import argparse
import math
from pathlib import Path

import pcbnew

MM = pcbnew.FromMM


def add_ground_zone(board: pcbnew.BOARD, net: pcbnew.NETINFO_ITEM, layer: int) -> None:
    zone = pcbnew.ZONE(board)
    zone.SetLayer(layer)
    zone.SetNet(net)
    zone.SetLocalClearance(MM(0.25))
    zone.SetMinThickness(MM(0.25))
    zone.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    polygon = zone.Outline()
    outline = polygon.NewOutline()
    for x_mm, y_mm in ((20.5, 20.5), (154.5, 20.5), (154.5, 114.5), (20.5, 114.5)):
        polygon.Append(MM(x_mm), MM(y_mm), outline)
    board.Add(zone)


def add_stitch_via(
    board: pcbnew.BOARD,
    net: pcbnew.NETINFO_ITEM,
    x_mm: float,
    y_mm: float,
    diameter_mm: float = 0.80,
    drill_mm: float = 0.40,
) -> pcbnew.PCB_VIA:
    via = pcbnew.PCB_VIA(board)
    via.SetPosition(pcbnew.VECTOR2I(MM(x_mm), MM(y_mm)))
    via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    via.SetNet(net)
    via.SetFrontWidth(MM(diameter_mm))
    via.SetDrill(MM(drill_mm))
    board.Add(via)
    return via


def add_track(
    board: pcbnew.BOARD,
    net: pcbnew.NETINFO_ITEM,
    start: pcbnew.VECTOR2I,
    end: pcbnew.VECTOR2I,
    width_mm: float,
    layer: int,
) -> None:
    track = pcbnew.PCB_TRACK(board)
    track.SetLayer(layer)
    track.SetNet(net)
    track.SetStart(start)
    track.SetEnd(end)
    track.SetWidth(MM(width_mm))
    board.Add(track)


def distance_mm(a: pcbnew.VECTOR2I, b: pcbnew.VECTOR2I) -> float:
    return math.hypot(pcbnew.ToMM(a.x - b.x), pcbnew.ToMM(a.y - b.y))


def point_segment_distance_mm(
    point: pcbnew.VECTOR2I,
    start: pcbnew.VECTOR2I,
    end: pcbnew.VECTOR2I,
) -> float:
    px, py = pcbnew.ToMM(point.x), pcbnew.ToMM(point.y)
    x1, y1 = pcbnew.ToMM(start.x), pcbnew.ToMM(start.y)
    x2, y2 = pcbnew.ToMM(end.x), pcbnew.ToMM(end.y)
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(px - x1, py - y1)
    t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))


def point_box_distance_mm(point: pcbnew.VECTOR2I, box: pcbnew.BOX2I) -> float:
    px, py = pcbnew.ToMM(point.x), pcbnew.ToMM(point.y)
    left, top = pcbnew.ToMM(box.GetX()), pcbnew.ToMM(box.GetY())
    right = left + pcbnew.ToMM(box.GetWidth())
    bottom = top + pcbnew.ToMM(box.GetHeight())
    dx = max(left - px, 0.0, px - right)
    dy = max(top - py, 0.0, py - bottom)
    return math.hypot(dx, dy)


def return_via_candidate_is_clear(
    board: pcbnew.BOARD,
    ground: pcbnew.NETINFO_ITEM,
    candidate: pcbnew.VECTOR2I,
) -> bool:
    """Conservatively screen a 0.6 mm GND via before native DRC."""
    x_mm, y_mm = pcbnew.ToMM(candidate.x), pcbnew.ToMM(candidate.y)
    # 0.3 mm radius + 0.5 mm copper-edge rule.
    if not (20.8 <= x_mm <= 154.2 and 20.8 <= y_mm <= 114.2):
        return False
    # ESP32 antenna rule area. Keep the complete via outside it.
    if 115.7 <= x_mm <= 154.3 and 20.2 <= y_mm <= 26.3:
        return False

    ground_code = ground.GetNetCode()
    for item in board.GetTracks():
        if item.GetNetCode() == ground_code:
            continue
        if isinstance(item, pcbnew.PCB_VIA):
            required = 0.3 + pcbnew.ToMM(item.GetWidth(pcbnew.F_Cu)) / 2.0 + 0.20
            if distance_mm(candidate, item.GetPosition()) < required - 1e-6:
                return False
        else:
            required = 0.3 + pcbnew.ToMM(item.GetWidth()) / 2.0 + 0.20
            if point_segment_distance_mm(candidate, item.GetStart(), item.GetEnd()) < required - 1e-6:
                return False

    for footprint in board.GetFootprints():
        for pad in footprint.Pads():
            if pad.GetNetCode() == ground_code:
                continue
            if point_box_distance_mm(candidate, pad.GetBoundingBox()) < 0.50 - 1e-6:
                return False
    return True


def add_return_path_stitching(
    board: pcbnew.BOARD,
    ground: pcbnew.NETINFO_ITEM,
) -> tuple[list[pcbnew.PCB_VIA], int]:
    """Place a nearby GND via for every non-ground signal transition possible."""
    ground_code = ground.GetNetCode()
    signal_vias = [
        item
        for item in board.GetTracks()
        if isinstance(item, pcbnew.PCB_VIA) and item.GetNetCode() not in (0, ground_code)
    ]
    ground_vias = [
        item
        for item in board.GetTracks()
        if isinstance(item, pcbnew.PCB_VIA) and item.GetNetCode() == ground_code
    ]
    added: list[pcbnew.PCB_VIA] = []
    unresolved = 0
    angles = tuple(range(0, 360, 15))
    for signal_via in signal_vias:
        origin = signal_via.GetPosition()
        if any(distance_mm(origin, stitch.GetPosition()) <= 1.0 for stitch in ground_vias):
            continue
        placed = False
        for radius_mm in (0.82, 0.90, 0.98):
            for angle_deg in angles:
                angle = math.radians(angle_deg)
                candidate = pcbnew.VECTOR2I(
                    origin.x + MM(radius_mm * math.cos(angle)),
                    origin.y + MM(radius_mm * math.sin(angle)),
                )
                if not return_via_candidate_is_clear(board, ground, candidate):
                    continue
                stitch = add_stitch_via(
                    board,
                    ground,
                    pcbnew.ToMM(candidate.x),
                    pcbnew.ToMM(candidate.y),
                    0.60,
                    0.30,
                )
                ground_vias.append(stitch)
                added.append(stitch)
                placed = True
                break
            if placed:
                break
        if not placed:
            unresolved += 1
    return added, unresolved


def remove_unconnected_return_vias(
    board: pcbnew.BOARD,
    ground: pcbnew.NETINFO_ITEM,
    return_vias: list[pcbnew.PCB_VIA],
) -> int:
    """Remove trial stitches that filled GND copper cannot reach on both layers."""
    zones_by_layer = {
        zone.GetLayer(): zone
        for zone in board.Zones()
        if not zone.GetIsRuleArea() and zone.GetNetCode() == ground.GetNetCode()
    }
    removed = 0
    for via in return_vias:
        if all(
            layer in zones_by_layer
            and zones_by_layer[layer].HasFilledPolysForLayer(layer)
            and zones_by_layer[layer].HitTestFilledArea(layer, via.GetPosition())
            for layer in (pcbnew.F_Cu, pcbnew.B_Cu)
        ):
            continue
        board.Remove(via)
        removed += 1
    return removed


def finalize(board_path: Path, output_path: Path) -> None:
    board = pcbnew.LoadBoard(str(board_path.resolve()))
    # FreeRouting preserves the requested trunk widths but uses 0.1874 mm for
    # fourteen short fine-pitch escape segments.  Declare a 0.18 mm process
    # floor rather than widening those segments after routing and disturbing
    # the verified clearances.
    board.GetDesignSettings().m_TrackMinWidth = MM(0.18)

    # Preserve rule areas such as the antenna keepout; replace only copper pours.
    for zone in list(board.Zones()):
        if not zone.GetIsRuleArea():
            board.Remove(zone)

    ground = next(
        (net for name, net in board.GetNetsByName().items() if str(name).lstrip("/") == "GND"),
        None,
    )
    if ground is None:
        raise ValueError("GND net not found in routed PCB")
    protected_5v = next(
        (net for name, net in board.GetNetsByName().items() if str(name).lstrip("/") == "+5V_SYS"),
        None,
    )
    if protected_5v is None:
        raise ValueError("+5V_SYS net not found in routed PCB")

    for footprint in board.GetFootprints():
        if str(footprint.GetReference()).startswith("FID"):
            for pad in footprint.Pads():
                pad.SetNet(ground)

    for x_mm, y_mm in (
        (45.0, 22.0),
        (100.0, 22.0),
        (22.0, 50.0),
        (153.0, 50.0),
        (22.0, 95.0),
        (153.0, 95.0),
        (35.0, 112.0),
        (130.0, 112.0),
    ):
        add_stitch_via(board, ground, x_mm, y_mm)

    return_vias, unresolved_transitions = add_return_path_stitching(board, ground)

    # Join the encoder-side and switch-side +5 V route trees through the clear
    # bottom-edge corridor.  This low-load module/control branch uses 0.8 mm;
    # its centerline at y=114 mm preserves 0.6 mm copper-to-edge clearance.
    control_5v_points = [
        pcbnew.VECTOR2I(MM(47.0), MM(111.5)),
        pcbnew.VECTOR2I(MM(47.0), MM(114.0)),
        pcbnew.VECTOR2I(MM(87.0), MM(114.0)),
        pcbnew.VECTOR2I(MM(87.0), MM(108.0)),
        pcbnew.VECTOR2I(MM(84.5), MM(108.0)),
    ]
    for start, end in zip(control_5v_points, control_5v_points[1:]):
        add_track(board, protected_5v, start, end, 0.80, pcbnew.B_Cu)

    add_ground_zone(board, ground, pcbnew.F_Cu)
    add_ground_zone(board, ground, pcbnew.B_Cu)
    filler = pcbnew.ZONE_FILLER(board)
    if not filler.Fill(board.Zones()):
        raise RuntimeError("KiCad zone fill failed")
    removed_return_vias = remove_unconnected_return_vias(board, ground, return_vias)
    if removed_return_vias and not filler.Fill(board.Zones()):
        raise RuntimeError("KiCad zone refill failed after pruning isolated return vias")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if not pcbnew.SaveBoard(str(output_path.resolve()), board):
        raise RuntimeError(f"KiCad failed to save {output_path}")
    print(
        f"finalized {output_path}: 2 filled GND planes; "
        f"return_vias_added={len(return_vias) - removed_return_vias}; "
        f"unresolved_transitions={unresolved_transitions + removed_return_vias}; "
        "routing geometry and rule areas preserved"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--board", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    finalize(args.board, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
