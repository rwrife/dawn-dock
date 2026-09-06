#!/usr/bin/env python3
"""Validate protocol fixture envelopes and expected rejection codes."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
FIXTURE_ROOT = ROOT / "docs" / "protocol" / "fixtures" / "v1"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"

MAX_ENVELOPE_BYTES = 64 * 1024
MESSAGE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
SENT_AT_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
KNOWN_TYPES = {
    "device.status.get",
    "time.configure",
    "schedule.preview",
    "schedule.apply",
    "schedule.get",
    "diagnostics.get",
    "backup.export",
    "factory.reset",
    "event.syncReceipt",
    "event.alarmState",
    "error.response",
}
REVISION_REQUIRED_TYPES = {"schedule.preview", "schedule.apply"}


class ValidationError(RuntimeError):
    pass


def _assert(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def _validate_alarm_shape(alarm: dict[str, Any], fixture: str) -> None:
    required = {
        "id",
        "label",
        "enabled",
        "localTime",
        "days",
        "timezone",
        "snoozeMinutes",
        "volume",
        "sound",
        "source",
        "sourceEventId",
    }
    missing = sorted(required - set(alarm.keys()))
    _assert(not missing, f"{fixture}: alarm missing keys: {', '.join(missing)}")
    _assert(bool(re.match(r"^([01][0-9]|2[0-3]):[0-5][0-9]$", str(alarm["localTime"]))),
            f"{fixture}: alarm.localTime invalid")


def _serialized_size_bytes(payload: dict[str, Any]) -> int:
    metadata = payload.get("_fixtureMeta", {})
    if isinstance(metadata, dict) and "serializedSizeBytes" in metadata:
        value = metadata["serializedSizeBytes"]
        _assert(isinstance(value, int) and value >= 0,
                "_fixtureMeta.serializedSizeBytes must be a non-negative integer")
        return value
    return len(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8"))


def validate_envelope(payload: dict[str, Any], fixture: str) -> str:
    protocol = payload.get("protocol")
    if protocol != "dawn-dock/1":
        return "invalid_protocol"

    message_id = payload.get("messageId")
    if not isinstance(message_id, str) or not MESSAGE_ID_PATTERN.match(message_id):
        return "invalid_message_id"

    sent_at = payload.get("sentAt")
    if not isinstance(sent_at, str) or not SENT_AT_PATTERN.match(sent_at):
        return "invalid_sent_at"

    msg_type = payload.get("type")
    if not isinstance(msg_type, str) or msg_type not in KNOWN_TYPES:
        return "unknown_type"

    if msg_type in REVISION_REQUIRED_TYPES and "expectedRevision" not in payload:
        return "expected_revision_required"

    size = _serialized_size_bytes(payload)
    if size > MAX_ENVELOPE_BYTES:
        return "envelope_too_large"

    body = payload.get("body")
    if not isinstance(body, dict):
        return "schema_invalid"

    if msg_type in REVISION_REQUIRED_TYPES:
        alarms = body.get("alarms")
        if not isinstance(alarms, list):
            raise ValidationError(f"{fixture}: schedule body must contain alarms list")
        for alarm in alarms:
            _assert(isinstance(alarm, dict), f"{fixture}: each alarm must be an object")
            _validate_alarm_shape(alarm, fixture)

    if msg_type == "error.response":
        required = {"code", "summary", "retryable"}
        missing = sorted(required - set(body.keys()))
        _assert(not missing, f"{fixture}: error body missing keys: {', '.join(missing)}")

    if msg_type == "event.syncReceipt":
        for key in ("appliedRevision", "alarmCount", "nextAlarmUtc"):
            _assert(key in body, f"{fixture}: sync receipt missing {key}")

    return "accepted"


def main() -> int:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    fixtures = manifest.get("fixtures", [])
    if not isinstance(fixtures, list) or len(fixtures) == 0:
        raise ValidationError("manifest.json must include a non-empty fixtures list")

    failures: list[str] = []
    checked = 0
    for entry in fixtures:
        checked += 1
        path = FIXTURE_ROOT / entry["path"]
        payload = json.loads(path.read_text(encoding="utf-8"))
        try:
            code = validate_envelope(payload, entry["path"])
            if entry["valid"]:
                if code != "accepted":
                    failures.append(f"{entry['path']}: expected accepted, got {code}")
            else:
                expected = entry.get("expected_code")
                if code != expected:
                    failures.append(
                        f"{entry['path']}: expected {expected}, got {code}")
        except ValidationError as exc:
            if entry["valid"]:
                failures.append(f"{entry['path']}: raised {exc}")
            else:
                expected = entry.get("expected_code")
                actual = str(exc)
                failures.append(
                    f"{entry['path']}: expected code {expected}, got exception {actual}")

    if failures:
        print("protocol_fixture_contract_test: FAIL")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"protocol_fixture_contract_test: PASS ({checked} fixtures)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"protocol_fixture_contract_test: FAIL: {exc}")
        raise SystemExit(1)
