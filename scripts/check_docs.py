#!/usr/bin/env python3
"""Dependency-free integrity checks for Dawn Dock's staged documentation."""

from __future__ import annotations

import posixpath
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_MARKDOWN_BYTES = 1_000_000
REGULAR_MODES = {"100644", "100755"}
REQUIRED = {
    "README.md",
    "PLAN.md",
    "hardware/requirements.md",
    "docs/system-architecture.md",
    "docs/alarm-semantics.md",
    "docs/threat-model.md",
    "docs/risk-register.md",
    "docs/verification-matrix.md",
    "docs/component-validation.md",
}
REQUIRED_TERMS = {
    "docs/system-architecture.md": ["```mermaid", "1,500 mA", "USB 5 V SELV"],
    "docs/alarm-semantics.md": ["Disabled", "Armed", "Ringing", "Snoozed", "Dismissed", "TimedOut", "Missed"],
    "docs/threat-model.md": ["TM-01", "TM-14", "replay", "factory reset"],
    "docs/risk-register.md": ["R-001", "non-life-safety", "Verification method / evidence class"],
    "docs/verification-matrix.md": ["Static analysis", "Simulation", "Bench test", "Field test"],
    "docs/component-validation.md": [
        "approved for schematic capture",
        "not approved for fabrication",
        "microphone-free",
        "still unverified",
    ],
}
INLINE_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
REQUIREMENT_ID_RE = re.compile(r"^\|\s*([A-Z]+-\d{2})\s*\|", re.MULTILINE)


@dataclass(frozen=True)
class IndexEntry:
    mode: str
    object_id: str
    path: str


def run_git(*args: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=False,
        capture_output=True,
    )


def decode_nul_paths(data: bytes) -> list[str]:
    return [item for item in data.decode("utf-8").split("\0") if item]


def indexed_markdown() -> tuple[list[IndexEntry], str | None]:
    result = run_git("ls-files", "--stage", "-z", "--", "*.md")
    if result.returncode:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        return [], f"cannot list staged Markdown files: {message or 'git failed'}"

    entries: list[IndexEntry] = []
    try:
        records = decode_nul_paths(result.stdout)
        for record in records:
            metadata, separator, path = record.partition("\t")
            fields = metadata.split()
            if not separator or len(fields) != 3:
                return [], f"cannot parse git index record: {record!r}"
            mode, object_id, stage = fields
            if stage != "0":
                return [], f"unmerged Markdown index entry: {path} (stage {stage})"
            entries.append(IndexEntry(mode=mode, object_id=object_id, path=path))
    except UnicodeDecodeError as exc:
        return [], f"staged Markdown path is not UTF-8: {exc}"
    return sorted(entries, key=lambda entry: entry.path), None


def all_indexed_paths() -> tuple[set[str], str | None]:
    result = run_git("ls-files", "--cached", "-z")
    if result.returncode:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        return set(), f"cannot list staged paths: {message or 'git failed'}"
    try:
        return set(decode_nul_paths(result.stdout)), None
    except UnicodeDecodeError as exc:
        return set(), f"staged path is not UTF-8: {exc}"


def read_index_blob(entry: IndexEntry, errors: list[str]) -> str | None:
    if entry.mode not in REGULAR_MODES:
        errors.append(f"{entry.path}: staged Markdown must be a regular file, mode is {entry.mode}")
        return None

    result = run_git("cat-file", "blob", entry.object_id)
    if result.returncode:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        errors.append(f"{entry.path}: cannot read staged blob: {message or 'git failed'}")
        return None
    if len(result.stdout) > MAX_MARKDOWN_BYTES:
        errors.append(f"{entry.path}: staged blob exceeds {MAX_MARKDOWN_BYTES} byte safety limit")
        return None
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        errors.append(f"{entry.path}: staged blob is not UTF-8: {exc}")
        return None


def normalized_local_target(source: str, target: str) -> str | None:
    path_target = target.strip().split("#", 1)[0]
    if not path_target or path_target.startswith(("http://", "https://", "mailto:")):
        return None
    if path_target.startswith("/"):
        return "../ABSOLUTE-PATH-NOT-ALLOWED"
    return posixpath.normpath(posixpath.join(posixpath.dirname(source), path_target))


def requirement_ids(text: str) -> list[str]:
    return REQUIREMENT_ID_RE.findall(text)


def main() -> int:
    errors: list[str] = []
    entries, markdown_error = indexed_markdown()
    indexed_paths, paths_error = all_indexed_paths()
    if markdown_error:
        errors.append(markdown_error)
    if paths_error:
        errors.append(paths_error)

    entries_by_path = {entry.path: entry for entry in entries}
    for rel in sorted(REQUIRED):
        if rel not in entries_by_path:
            errors.append(f"missing required staged file: {rel}")

    contents: dict[str, str] = {}
    inline_link_count = 0
    for entry in entries:
        text = read_index_blob(entry, errors)
        if text is None:
            continue
        contents[entry.path] = text

        for term in REQUIRED_TERMS.get(entry.path, []):
            if term.casefold() not in text.casefold():
                errors.append(f"{entry.path}: missing required marker {term!r}")

        for target in INLINE_LINK_RE.findall(text):
            normalized = normalized_local_target(entry.path, target)
            if normalized is None:
                continue
            inline_link_count += 1
            if normalized == ".." or normalized.startswith("../"):
                errors.append(f"{entry.path}: inline link escapes repository: {target}")
            elif normalized not in indexed_paths:
                errors.append(f"{entry.path}: broken staged inline local path: {target}")

    requirements_text = contents.get("hardware/requirements.md", "")
    matrix_text = contents.get("docs/verification-matrix.md", "")
    required_ids = requirement_ids(requirements_text)
    matrix_ids = requirement_ids(matrix_text)

    for label, ids in (("hardware requirements", required_ids), ("verification matrix", matrix_ids)):
        duplicates = sorted(item for item, count in Counter(ids).items() if count > 1)
        if duplicates:
            errors.append(f"duplicate IDs in {label}: {', '.join(duplicates)}")

    missing_ids = sorted(set(required_ids) - set(matrix_ids))
    orphan_ids = sorted(set(matrix_ids) - set(required_ids))
    if missing_ids:
        errors.append(f"requirements missing from verification matrix: {', '.join(missing_ids)}")
    if orphan_ids:
        errors.append(f"verification rows without hardware/product requirements: {', '.join(orphan_ids)}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1

    print(f"PASS: {len(REQUIRED)} required baseline files exist in the git index")
    print(f"PASS: {len(entries)} staged Markdown blobs are regular, bounded, and UTF-8")
    print(f"PASS: {inline_link_count} staged inline local path links resolve to indexed files")
    print(f"PASS: exact one-to-one coverage for {len(required_ids)} unique hardware/product requirement IDs")
    print("PASS: architecture, alarm, threat, risk, and evidence marker terms are present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
