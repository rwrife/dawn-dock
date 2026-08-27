#!/usr/bin/env python3
"""Export deterministic review-only Dawn Dock prototype fabrication artifacts."""
from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import zipfile
from pathlib import Path

LAYERS = "F.Cu,B.Cu,F.Paste,B.Paste,F.SilkS,B.SilkS,F.Mask,B.Mask,Edge.Cuts"
OUTPUT_MARKER = ".dawn-dock-fabrication-output"
MARKER_CONTENT = "dawn-dock export_fabrication.py managed directory\n"
GERBER_MEMBER_NAMES = (
    "dawn-dock-B_Cu.gbl",
    "dawn-dock-B_Mask.gbs",
    "dawn-dock-B_Paste.gbp",
    "dawn-dock-B_Silkscreen.gbo",
    "dawn-dock-Edge_Cuts.gm1",
    "dawn-dock-F_Cu.gtl",
    "dawn-dock-F_Mask.gts",
    "dawn-dock-F_Paste.gtp",
    "dawn-dock-F_Silkscreen.gto",
    "dawn-dock-NPTH-drl_map.svg",
    "dawn-dock-NPTH.drl",
    "dawn-dock-PTH-drl_map.svg",
    "dawn-dock-PTH.drl",
    "dawn-dock-job.gbrjob",
)


def run(*args: str) -> None:
    print("+", " ".join(args))
    subprocess.run(args, check=True)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def normalized_archive_bytes(path: Path) -> bytes:
    """Remove KiCad generation-time metadata while preserving manufacturing data."""
    data = path.read_bytes()
    replacements = (
        (rb"20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00", b"2026-08-27T00:00:00+00:00"),
        (rb"20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d\+0000", b"2026-08-27T00:00:00+0000"),
        (rb"date 20\d\d-\d\d-\d\d \d\d:\d\d:\d\d", b"date 2026-08-27 00:00:00"),
        (rb"date 20\d\d/\d\d/\d\d \d\d:\d\d:\d\d", b"date 2026/08/27 00:00:00"),
    )
    for pattern, replacement in replacements:
        data = re.sub(pattern, replacement, data)
    return data


def export(board: Path, output: Path) -> None:
    board = board.resolve()
    output = output.resolve()
    cwd = Path.cwd().resolve()
    if output == Path(output.anchor) or output == cwd or output == board or output in board.parents:
        raise ValueError(f"refusing unsafe output directory: {output}")
    if output.exists():
        marker = output / OUTPUT_MARKER
        if not output.is_dir() or not marker.is_file() or marker.read_text(encoding="utf-8") != MARKER_CONTENT:
            raise ValueError(f"refusing to replace unmanaged output directory: {output}")
    output.mkdir(parents=True, exist_ok=True)
    (output / OUTPUT_MARKER).write_text(MARKER_CONTENT, encoding="utf-8")
    gerbers = output / "gerbers"
    renders = output / "renders"
    plots = output / "plots"
    for directory in (gerbers, renders, plots):
        directory.mkdir(parents=True, exist_ok=True)

    run("kicad-cli", "pcb", "export", "gerbers", "--output", str(gerbers), "--layers", LAYERS, str(board))
    run(
        "kicad-cli",
        "pcb",
        "export",
        "drill",
        "--output",
        str(gerbers),
        "--format",
        "excellon",
        "--excellon-units",
        "mm",
        "--excellon-separate-th",
        "--generate-map",
        "--map-format",
        "svg",
        str(board),
    )
    run(
        "kicad-cli",
        "pcb",
        "export",
        "pos",
        "--output",
        str(output / "dawn-dock-rev-a0-position.csv"),
        "--side",
        "both",
        "--format",
        "csv",
        "--units",
        "mm",
        "--exclude-dnp",
        str(board),
    )
    run(
        "kicad-cli",
        "pcb",
        "export",
        "svg",
        "--output",
        str(plots / "dawn-dock-top.svg"),
        "--layers",
        "F.Cu,F.Mask,F.SilkS,Edge.Cuts",
        "--subtract-soldermask",
        "--fit-page-to-board",
        "--exclude-drawing-sheet",
        "--mode-single",
        str(board),
    )
    run(
        "kicad-cli",
        "pcb",
        "export",
        "svg",
        "--output",
        str(plots / "dawn-dock-bottom.svg"),
        "--layers",
        "B.Cu,B.Mask,B.SilkS,Edge.Cuts",
        "--subtract-soldermask",
        "--mirror",
        "--fit-page-to-board",
        "--exclude-drawing-sheet",
        "--mode-single",
        str(board),
    )
    run(
        "kicad-cli",
        "pcb",
        "render",
        "--output",
        str(renders / "dawn-dock-top.png"),
        "--width",
        "1600",
        "--height",
        "1200",
        "--side",
        "top",
        "--quality",
        "high",
        "--background",
        "opaque",
        str(board),
    )
    run(
        "kicad-cli",
        "pcb",
        "render",
        "--output",
        str(renders / "dawn-dock-perspective.png"),
        "--width",
        "1600",
        "--height",
        "1200",
        "--side",
        "top",
        "--quality",
        "high",
        "--background",
        "opaque",
        "--perspective",
        "--rotate=325,0,35",
        str(board),
    )

    archive = output / "dawn-dock-rev-a0-gerbers-review-only.zip"
    members = [gerbers / name for name in GERBER_MEMBER_NAMES]
    missing = [str(path) for path in members if not path.is_file()]
    if missing:
        raise RuntimeError(f"KiCad export omitted expected files: {', '.join(missing)}")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in members:
            info = zipfile.ZipInfo(path.relative_to(output).as_posix(), date_time=(2026, 8, 27, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, normalized_archive_bytes(path))

    checksum_targets = [
        archive,
        output / "dawn-dock-rev-a0-position.csv",
        renders / "dawn-dock-perspective.png",
        renders / "dawn-dock-top.png",
    ]
    (output / "SHA256SUMS").write_text(
        "".join(f"{digest(path)}  {path.relative_to(output).as_posix()}\n" for path in checksum_targets),
        encoding="utf-8",
    )
    print(f"exported {output}: {len(members)} Gerber/drill files; archive_sha256={digest(archive)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--board", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    export(args.board, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
