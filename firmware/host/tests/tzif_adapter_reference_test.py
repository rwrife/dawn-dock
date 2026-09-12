#!/usr/bin/env python3
"""Cross-check the pinned TZif adapter fixtures against host IANA zoneinfo.

Validates:
  (1) manifest sha256 pins for each checked-in TZif record;
  (2) every pinned record parses as a well-formed RFC 8536 version-2+ record;
  (3) offsets derived from the version-2+ transition block agree with the
      runner's installed IANA zoneinfo database at sampled instants;
  (4) the gap/fold/exact occurrence expectations consumed by the C++ adapter
      tests still match host zoneinfo, so the C++ gap/fold assertions cannot
      silently drift from real IANA behavior.

Note on gap semantics: PEP-495 maps a nonexistent local time with fold=0/1 to
the offsets before/after the gap; the Dawn Dock policy instead shifts such an
occurrence forward to the first valid instant at gap end. This script checks
the pinned local->UTC instant (gap end or first fold pass) directly against
zoneinfo, so the dawn policy is anchored to a real, unambiguous instant even
when the requested local time itself does not exist.
"""

import datetime
import hashlib
import json
import pathlib
import struct
import sys
from zoneinfo import ZoneInfo

ROOT = pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "tzif" / "2026c"
HEADER = 44

failures = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def v2_block(data: bytes):
    """Return (times, type_indices, gmtoffs) from the version-2+ block."""
    assert data[:4] == b"TZif"
    isut, isstd, leap, timec, typec, charc = struct.unpack(">6I", data[20:44])
    v1_len = HEADER + timec * 4 + timec + typec * 6 + charc + leap * 8 + isstd + isut
    assert data[v1_len:v1_len + 4] == b"TZif"
    off = v1_len + 44
    times = list(struct.unpack(f">{timec}q", data[off:off + 8 * timec]))
    off += 8 * timec
    indices = list(data[off:off + timec])
    off += timec
    gmtoffs = []
    for _ in range(typec):
        gmtoff, _isdst, _abbr = struct.unpack(">iBB", data[off:off + 6])
        gmtoffs.append(gmtoff)
        off += 6
    return times, indices, gmtoffs


def offset_at(times, indices, gmtoffs, utc_seconds: int) -> int:
    # RFC 8536 / tzdata convention: the offset before the first transition
    # is the first ttinfo entry.
    offset = gmtoffs[0]
    for when, idx in zip(times, indices):
        if utc_seconds < when:
            break
        offset = gmtoffs[idx]
    return offset


def parse_instant(text: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def main() -> int:
    manifest = json.loads((ROOT / "manifest.json").read_text())

    # (1) sha256 pins
    for entry in manifest["files"]:
        raw = (ROOT / entry["path"]).read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        check(digest == entry["sha256"],
              f"sha256 pin mismatch for {entry['zone']}: {digest}")

    # (2)+(3) structural parse + offset agreement with zoneinfo
    for entry in manifest["files"]:
        raw = (ROOT / entry["path"]).read_bytes()
        try:
            times, indices, gmtoffs = v2_block(raw)
        except Exception as exc:  # noqa: BLE001 - report, don't crash
            check(False, f"{entry['zone']}: unparsable TZif v2 block: {exc}")
            continue
        check(len(times) >= 1 and len(gmtoffs) >= 1,
              f"{entry['zone']}: empty transition/ttinfo table")
        check(all(b > a for a, b in zip(times, times[1:])),
              f"{entry['zone']}: transition times not strictly increasing")
        zone = ZoneInfo(entry["zone"])
        for year in (2012, 2018, 2024, 2026, 2030):
            for month in (1, 3, 6, 9, 11, 12):
                instant = datetime.datetime(
                    year, month, 15, 12, tzinfo=datetime.timezone.utc)
                expected = instant.replace(tzinfo=zone).utcoffset().total_seconds()
                actual = offset_at(times, indices, gmtoffs, int(instant.timestamp()))
                check(int(expected) == int(actual),
                      f"{entry['zone']} {instant.isoformat()}: pinned offset "
                      f"{actual} != zoneinfo {expected}")

    # (4) occurrence expectations still anchor to real zoneinfo instants.
    for item in manifest["occurrence_checks"]:
        zone = ZoneInfo(item["zone"])
        expected = parse_instant(item["expected_utc"])
        if item["kind"] == "exact":
            local = datetime.datetime.fromisoformat(item["local"]).replace(tzinfo=zone)
            check(local.astimezone(datetime.timezone.utc) == expected,
                  f"{item['zone']} {item['label']}: exact mapping drifted "
                  f"({local.astimezone(datetime.timezone.utc).isoformat()})")
        elif item["kind"] == "fold":
            # The requested local time must be ambiguous (fold 0 != fold 1)
            # and fold 0 must map to the pinned first-pass instant.
            l0 = datetime.datetime.fromisoformat(item["local"]).replace(tzinfo=zone, fold=0)
            l1 = datetime.datetime.fromisoformat(item["local"]).replace(tzinfo=zone, fold=1)
            check(l0.utcoffset() != l1.utcoffset(),
                  f"{item['zone']} {item['label']}: local time is not ambiguous")
            check(l0.astimezone(datetime.timezone.utc) == expected,
                  f"{item['zone']} {item['label']}: fold=0 mapping drifted")
        elif item["kind"] == "gap":
            # The requested local time must NOT exist; the pinned gap-end
            # instant must exist and map back to its own local representation.
            req = datetime.datetime.fromisoformat(item["local"]).replace(tzinfo=zone)
            back = req.astimezone(datetime.timezone.utc).astimezone(zone)
            check(back.replace(tzinfo=None) != req.replace(tzinfo=None),
                  f"{item['zone']} {item['label']}: requested local time unexpectedly exists")
            pinned_local = datetime.datetime.fromisoformat(
                item["expected_local"]).replace(tzinfo=zone)
            check(pinned_local.astimezone(datetime.timezone.utc) == expected,
                  f"{item['zone']} {item['label']}: gap-end instant drifted")
            check(pinned_local.replace(fold=1).utcoffset() ==
                      pinned_local.replace(fold=0).utcoffset(),
                  f"{item['zone']} {item['label']}: gap end must be unambiguous")
        else:
            check(False, f"{item['zone']} {item['label']}: unknown check kind")

    apia = manifest["apia_skipped_local_date"]
    check(apia["skipped_local_date"] == "2011-12-30", "apia skipped date drift")
    next_valid = parse_instant(apia["next_valid_local_instant_utc"])
    as_local = next_valid.astimezone(ZoneInfo("Pacific/Apia"))
    check(as_local.strftime("%Y-%m-%d") == "2011-12-31",
          f"apia next-valid instant must be local 2011-12-31, got {as_local.isoformat()}")
    skipped = datetime.datetime(2011, 12, 30, 7, tzinfo=ZoneInfo("Pacific/Apia"))
    back = skipped.astimezone(datetime.timezone.utc).astimezone(ZoneInfo("Pacific/Apia"))
    check(back.strftime("%Y-%m-%d") != "2011-12-30",
          "2011-12-30 unexpectedly exists in Pacific/Apia")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        print(f"tzif_adapter_reference_tests: {len(failures)} failure(s)")
        return 1
    print("tzif_adapter_reference_tests: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
