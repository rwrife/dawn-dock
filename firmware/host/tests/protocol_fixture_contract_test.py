#!/usr/bin/env python3
"""Validate protocol fixture envelopes, bodies, and expected rejection codes.

This is the cross-language mirror of the firmware-side validator chain:
`validate_protocol_envelope` + `parse_json` + `validate_protocol_message_body`
(see firmware/components/alarm_core/{protocol_service,json_parser,
message_body_validator}.cpp). Rule order and stable error codes must stay
aligned with `docs/protocol.md` and the shared fixture manifest.
"""

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
MAX_STORED_ALARMS = 32
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
ALARM_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
LOCAL_TIME_PATTERN = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
ALARM_REQUIRED_KEYS = {
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
ERROR_CODE_ENUM = {
    "invalid_protocol",
    "unknown_type",
    "invalid_message_id",
    "duplicate_message_id",
    "invalid_sent_at",
    "expected_revision_required",
    "envelope_too_large",
    "revision_conflict",
    "schema_invalid",
    "payload_semantic_error",
    "unauthorized",
    "rate_limited",
}
ERROR_REQUIRED_KEYS = {"code", "summary", "retryable"}
ERROR_ALLOWED_KEYS = ERROR_REQUIRED_KEYS | {"field", "currentRevision"}


class ValidationError(RuntimeError):
    pass


def _assert(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _validate_alarm(alarm: Any) -> str | None:
    """Return a stable code for a single alarm record, or None if valid."""
    if not isinstance(alarm, dict):
        return "schema_invalid"
    if set(alarm.keys()) != ALARM_REQUIRED_KEYS:
        return "schema_invalid"
    if not isinstance(alarm["id"], str) or ALARM_ID_PATTERN.match(
        alarm["id"]
    ) is None:
        return "schema_invalid"
    label = alarm["label"]
    if not isinstance(label, str) or not (1 <= len(label) <= 48):
        return "schema_invalid"
    if not isinstance(alarm["enabled"], bool):
        return "schema_invalid"
    if not isinstance(alarm["localTime"], str) or LOCAL_TIME_PATTERN.match(
        alarm["localTime"]
    ) is None:
        return "schema_invalid"
    days = alarm["days"]
    if (
        not isinstance(days, list)
        or not (1 <= len(days) <= 7)
        or not all(_is_int(day) and 0 <= day <= 6 for day in days)
        or len(set(days)) != len(days)
    ):
        return "schema_invalid"
    timezone = alarm["timezone"]
    if not isinstance(timezone, str) or not (3 <= len(timezone) <= 64):
        return "schema_invalid"
    snooze = alarm["snoozeMinutes"]
    if not _is_int(snooze) or not (1 <= snooze <= 30):
        return "schema_invalid"
    volume = alarm["volume"]
    if not _is_int(volume) or not (0 <= volume <= 100):
        return "schema_invalid"
    sound = alarm["sound"]
    if not isinstance(sound, str) or not (1 <= len(sound) <= 32):
        return "schema_invalid"
    if alarm["source"] not in ("manual", "ics"):
        return "schema_invalid"
    source_event = alarm["sourceEventId"]
    if source_event is not None and (
        not isinstance(source_event, str) or len(source_event) > 128
    ):
        return "schema_invalid"
    return None


def _validate_schedule_body(body: dict[str, Any]) -> str | None:
    alarms = body.get("alarms")
    if not isinstance(alarms, list):
        return "schema_invalid"
    if len(alarms) > MAX_STORED_ALARMS:
        return "payload_semantic_error"
    for alarm in alarms:
        code = _validate_alarm(alarm)
        if code is not None:
            return code
    ids = [alarm["id"] for alarm in alarms]
    if len(set(ids)) != len(ids):
        return "payload_semantic_error"
    return None


def _validate_error_response_body(body: dict[str, Any]) -> str | None:
    if not ERROR_REQUIRED_KEYS <= set(body.keys()):
        return "schema_invalid"
    if not set(body.keys()) <= ERROR_ALLOWED_KEYS:
        return "schema_invalid"
    if body["code"] not in ERROR_CODE_ENUM:
        return "schema_invalid"
    summary = body["summary"]
    if not isinstance(summary, str) or not (1 <= len(summary) <= 160):
        return "schema_invalid"
    if "field" in body:
        field = body["field"]
        if not isinstance(field, str) or len(field) > 64:
            return "schema_invalid"
    if not isinstance(body["retryable"], bool):
        return "schema_invalid"
    if "currentRevision" in body:
        revision = body["currentRevision"]
        if not _is_int(revision) or revision < 0:
            return "schema_invalid"
    return None


def _validate_sync_receipt_body(body: dict[str, Any]) -> str | None:
    for key in ("appliedRevision", "alarmCount", "nextAlarmUtc"):
        if key not in body:
            return "schema_invalid"
    if not _is_int(body["appliedRevision"]) or body["appliedRevision"] < 0:
        return "schema_invalid"
    count = body["alarmCount"]
    if not _is_int(count) or count < 0:
        return "schema_invalid"
    if count > MAX_STORED_ALARMS:
        return "payload_semantic_error"
    if not isinstance(body["nextAlarmUtc"], str) or SENT_AT_PATTERN.match(
        body["nextAlarmUtc"]
    ) is None:
        return "schema_invalid"
    return None


def _serialized_size_bytes(payload: dict[str, Any]) -> int:
    metadata = payload.get("_fixtureMeta", {})
    if isinstance(metadata, dict) and "serializedSizeBytes" in metadata:
        value = metadata["serializedSizeBytes"]
        _assert(isinstance(value, int) and value >= 0,
                "_fixtureMeta.serializedSizeBytes must be a non-negative integer")
        return value
    return len(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8"))


def validate_envelope(payload: dict[str, Any], fixture: str) -> str:
    # Rule order mirrors validate_protocol_envelope in protocol_service.cpp.
    protocol = payload.get("protocol")
    if protocol != "dawn-dock/1":
        return "invalid_protocol"

    msg_type = payload.get("type")
    if not isinstance(msg_type, str) or msg_type not in KNOWN_TYPES:
        return "unknown_type"

    message_id = payload.get("messageId")
    if not isinstance(message_id, str) or not MESSAGE_ID_PATTERN.match(message_id):
        return "invalid_message_id"

    sent_at = payload.get("sentAt")
    if not isinstance(sent_at, str) or not SENT_AT_PATTERN.match(sent_at):
        return "invalid_sent_at"

    if msg_type in REVISION_REQUIRED_TYPES and "expectedRevision" not in payload:
        return "expected_revision_required"

    size = _serialized_size_bytes(payload)
    if size > MAX_ENVELOPE_BYTES:
        return "envelope_too_large"

    body = payload.get("body")
    if not isinstance(body, dict):
        return "schema_invalid"

    if msg_type in REVISION_REQUIRED_TYPES:
        code = _validate_schedule_body(body)
        if code is not None:
            return code
    elif msg_type == "error.response":
        code = _validate_error_response_body(body)
        if code is not None:
            return code
    elif msg_type == "event.syncReceipt":
        code = _validate_sync_receipt_body(body)
        if code is not None:
            return code
    # Remaining known types carry no checked-in body schema yet; they pass
    # through as accepted, matching message_body_validator.cpp.

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
            failures.append(f"{entry['path']}: raised {exc}")

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
