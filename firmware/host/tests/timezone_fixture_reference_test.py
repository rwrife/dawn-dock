#!/usr/bin/env python3
"""Cross-check committed timezone fixture instants against host IANA zoneinfo."""

from datetime import datetime, timezone
from zoneinfo import ZoneInfo


def utc(text: str) -> datetime:
    return datetime.fromisoformat(text).replace(tzinfo=timezone.utc)


def local_to_utc(zone: str, text: str, *, fold: int = 0) -> datetime:
    local = datetime.fromisoformat(text).replace(tzinfo=ZoneInfo(zone), fold=fold)
    return local.astimezone(timezone.utc)


def expect(zone: str, local: str, expected_utc: str, *, fold: int = 0) -> None:
    actual = local_to_utc(zone, local, fold=fold)
    expected = utc(expected_utc)
    if actual != expected:
        raise AssertionError(
            f"{zone} {local} fold={fold}: expected {expected.isoformat()}, "
            f"got {actual.isoformat()}"
        )


def main() -> None:
    # New York: 02:00-02:59 is absent on March 8; 01:30 repeats on November 1.
    expect("America/New_York", "2026-03-08T01:59", "2026-03-08T06:59")
    expect("America/New_York", "2026-03-08T03:00", "2026-03-08T07:00")
    expect("America/New_York", "2026-11-01T01:30", "2026-11-01T05:30", fold=0)
    expect("America/New_York", "2026-11-01T01:30", "2026-11-01T06:30", fold=1)

    # Berlin: 02:00-02:59 is absent on March 29; 02:30 repeats on October 25.
    expect("Europe/Berlin", "2026-03-29T01:59", "2026-03-29T00:59")
    expect("Europe/Berlin", "2026-03-29T03:00", "2026-03-29T01:00")
    expect("Europe/Berlin", "2026-10-25T02:30", "2026-10-25T00:30", fold=0)
    expect("Europe/Berlin", "2026-10-25T02:30", "2026-10-25T01:30", fold=1)

    # Apia skipped all of December 30, 2011 when moving from UTC-10 to UTC+14.
    expect("Pacific/Apia", "2011-12-29T23:59", "2011-12-30T09:59")
    expect("Pacific/Apia", "2011-12-31T00:00", "2011-12-30T10:00")
    expect("Pacific/Apia", "2012-01-06T07:00", "2012-01-05T17:00")

    print("timezone_fixture_reference_tests: PASS")


if __name__ == "__main__":
    main()
