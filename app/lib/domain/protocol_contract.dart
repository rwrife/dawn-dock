/// Pure-Dart mirror of the canonical `dawn-dock/1` message contract.
///
/// This file reproduces, in rule order, the firmware validator chain
/// `validate_protocol_envelope` + `parse_json` +
/// `validate_protocol_message_body` (see
/// `firmware/components/alarm_core/{protocol_service,json_parser,
/// message_body_validator}.cpp`) and the Python mirror
/// `firmware/host/tests/protocol_fixture_contract_test.py`. Rule order and
/// stable error codes must stay aligned with `docs/protocol.md` and the
/// shared fixture manifest `docs/protocol/fixtures/v1/manifest.json`.
///
/// The app consumes the *manifest* as the normative expectation set; fixture
/// file bodies are re-parsed from the checked-in `assets/` copies so the Dart
/// side can never drift silently from what firmware validates.
library;

/// Stable error-model codes from `docs/protocol.md` "Error model" that the
/// contract gate can produce, including the sentinel `accepted`.
enum ContractCode {
  accepted,
  invalidProtocol,
  unknownType,
  invalidMessageId,
  duplicateMessageId,
  invalidSentAt,
  expectedRevisionRequired,
  envelopeTooLarge,
  schemaInvalid,
  payloadSemanticError,
}

String contractCodeName(ContractCode code) {
  switch (code) {
    case ContractCode.accepted:
      return 'accepted';
    case ContractCode.invalidProtocol:
      return 'invalid_protocol';
    case ContractCode.unknownType:
      return 'unknown_type';
    case ContractCode.invalidMessageId:
      return 'invalid_message_id';
    case ContractCode.duplicateMessageId:
      return 'duplicate_message_id';
    case ContractCode.invalidSentAt:
      return 'invalid_sent_at';
    case ContractCode.expectedRevisionRequired:
      return 'expected_revision_required';
    case ContractCode.envelopeTooLarge:
      return 'envelope_too_large';
    case ContractCode.schemaInvalid:
      return 'schema_invalid';
    case ContractCode.payloadSemanticError:
      return 'payload_semantic_error';
  }
}

/// Bounds mirrored from the firmware constants and
/// `docs/protocol/schemas/v1/` — a violation here is a contract drift bug.
const int kMaxEnvelopeBytes = 64 * 1024; // kProtocolEnvelopeMaximumBytes
const int kMaxMessageIdBytes = 128; // kProtocolMessageIdMaximumBytes
const int kMaxStoredAlarms = 32; // kBodyMaximumAlarms == kMaximumStoredAlarms
const int kMaxAlarmLabelBytes = 48; // kBodyMaximumLabelBytes
const int kMaxTimezoneBytes = 64; // kBodyMaximumTimezoneBytes
const int kMaxSoundBytes = 32; // kBodyMaximumSoundBytes
const int kMaxSourceEventIdBytes = 128; // kBodyMaximumSourceEventIdBytes

const String kProtocolVersion = 'dawn-dock/1';

const Set<String> kKnownTypes = {
  'device.status.get',
  'time.configure',
  'schedule.preview',
  'schedule.apply',
  'schedule.get',
  'diagnostics.get',
  'backup.export',
  'factory.reset',
  'event.syncReceipt',
  'event.alarmState',
  'error.response',
};

const Set<String> kRevisionRequiredTypes = {
  'schedule.preview',
  'schedule.apply',
};

final RegExp _messageIdPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');
final RegExp _sentAtPattern = RegExp(
  r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$',
);
final RegExp _alarmIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
final RegExp _localTimePattern = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');

const Set<String> _alarmRequiredKeys = {
  'id',
  'label',
  'enabled',
  'localTime',
  'days',
  'timezone',
  'snoozeMinutes',
  'volume',
  'sound',
  'source',
  'sourceEventId',
};

const Set<String> _errorCodeEnum = {
  'invalid_protocol',
  'unknown_type',
  'invalid_message_id',
  'duplicate_message_id',
  'invalid_sent_at',
  'expected_revision_required',
  'envelope_too_large',
  'revision_conflict',
  'schema_invalid',
  'payload_semantic_error',
  'unauthorized',
  'rate_limited',
};

const Set<String> _errorRequiredKeys = {'code', 'summary', 'retryable'};
final Set<String> _errorAllowedKeys = _errorRequiredKeys.union({
  'field',
  'currentRevision',
});

bool _isInt(Object? value) => value is int;

bool _isUtf8Bounded(String value, int maximumBytes) =>
    _utf8Length(value) <= maximumBytes;

int _utf8Length(String value) {
  var bytes = 0;
  for (final unit in value.runes) {
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit < 0x10000) {
      bytes += 3;
    } else {
      bytes += 4;
    }
  }
  return bytes;
}

/// Size accounting for the envelope gate. When the payload carries
/// `_fixtureMeta.serializedSizeBytes` (int >= 0), that transport-reported
/// frame size wins; otherwise the canonical serialization size is used:
/// UTF-8 key-sorted, compact JSON — mirroring the Python mirror's
/// `json.dumps(..., separators=(",", ":"), sort_keys=True)`.
int serializedEnvelopeBytes(Map<String, Object?> payload) {
  final metadata = payload['_fixtureMeta'];
  if (metadata is Map && metadata['serializedSizeBytes'] is int) {
    final value = metadata['serializedSizeBytes'] as int;
    if (value >= 0) {
      return value;
    }
  }
  return _utf8Length(_canonicalize(payload));
}

/// Compact, key-sorted JSON text matching Python's canonical dump
/// (`json.dumps(..., separators=(",", ":"), sort_keys=True)`): no
/// significant-fraction floats and `true`/`false`/`null` literals. The
/// Python mirror escapes non-ASCII (`ensure_ascii` default), which yields
/// larger byte counts for non-ASCII strings; every checked-in fixture is
/// pure ASCII, so both serializations are byte-identical there and only
/// synthetic non-ASCII probes could ever differ (never enough to flip the
/// 64 KiB gate at fixture scale).
String _canonicalize(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(value, buffer);
  return buffer.toString();
}

void _writeCanonical(Object? value, StringBuffer out) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is int) {
    out.write(value.toString());
  } else if (value is double) {
    out.write(_canonicalDouble(value));
  } else if (value is String) {
    out.write(_canonicalString(value));
  } else if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) {
        out.write(',');
      }
      _writeCanonical(value[i], out);
    }
    out.write(']');
  } else if (value is Map) {
    final keys = value.keys.cast<Object?>().toList()
      ..sort((a, b) {
        final ak = a is String ? a : '$a';
        final bk = b is String ? b : '$b';
        return ak.compareTo(bk);
      });
    out.write('{');
    var first = true;
    for (final key in keys) {
      if (!first) {
        out.write(',');
      }
      first = false;
      out
        ..write(_canonicalString(key is String ? key : '$key'))
        ..write(':');
      _writeCanonical(value[key], out);
    }
    out.write('}');
  } else {
    throw StateError('non-canonical value ${value.runtimeType}');
  }
}

String _canonicalDouble(double value) {
  if (value != value || value.isInfinite) {
    throw StateError('non-finite double in contract payload');
  }
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toString();
}

String _canonicalString(String value) {
  final out = StringBuffer('"');
  for (final unit in value.runes) {
    switch (unit) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (unit < 0x20) {
          out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(unit);
        }
    }
  }
  out.write('"');
  return out.toString();
}

ContractCode _validateAlarm(Object? alarm) {
  if (alarm is! Map) {
    return ContractCode.schemaInvalid;
  }
  final keys = alarm.keys.map((k) => '$k').toSet();
  if (!keys.containsAll(_alarmRequiredKeys) ||
      !keys.every(_alarmRequiredKeys.contains)) {
    return ContractCode.schemaInvalid;
  }
  final id = alarm['id'];
  if (id is! String || !_alarmIdPattern.hasMatch(id)) {
    return ContractCode.schemaInvalid;
  }
  final label = alarm['label'];
  if (label is! String ||
      label.isEmpty ||
      !_isUtf8Bounded(label, kMaxAlarmLabelBytes)) {
    return ContractCode.schemaInvalid;
  }
  if (alarm['enabled'] is! bool) {
    return ContractCode.schemaInvalid;
  }
  final localTime = alarm['localTime'];
  if (localTime is! String || !_localTimePattern.hasMatch(localTime)) {
    return ContractCode.schemaInvalid;
  }
  final days = alarm['days'];
  if (days is! List || days.isEmpty || days.length > 7) {
    return ContractCode.schemaInvalid;
  }
  final seen = <int>{};
  for (final day in days) {
    if (day is! int || day < 0 || day > 6 || !seen.add(day)) {
      return ContractCode.schemaInvalid;
    }
  }
  final timezone = alarm['timezone'];
  if (timezone is! String ||
      _utf8Length(timezone) < 3 ||
      !_isUtf8Bounded(timezone, kMaxTimezoneBytes)) {
    return ContractCode.schemaInvalid;
  }
  final snooze = alarm['snoozeMinutes'];
  if (!_isInt(snooze) || snooze! < 1 || snooze > 30) {
    return ContractCode.schemaInvalid;
  }
  final volume = alarm['volume'];
  if (!_isInt(volume) || volume! < 0 || volume > 100) {
    return ContractCode.schemaInvalid;
  }
  final sound = alarm['sound'];
  if (sound is! String ||
      sound.isEmpty ||
      !_isUtf8Bounded(sound, kMaxSoundBytes)) {
    return ContractCode.schemaInvalid;
  }
  final source = alarm['source'];
  if (source != 'manual' && source != 'ics') {
    return ContractCode.schemaInvalid;
  }
  final sourceEvent = alarm['sourceEventId'];
  if (sourceEvent != null &&
      (sourceEvent is! String ||
          !_isUtf8Bounded(sourceEvent, kMaxSourceEventIdBytes))) {
    return ContractCode.schemaInvalid;
  }
  return ContractCode.accepted;
}

ContractCode _validateScheduleBody(Map<Object?, Object?> body) {
  final alarms = body['alarms'];
  if (alarms is! List) {
    return ContractCode.schemaInvalid;
  }
  // kMaximumStoredAlarms is a storage design limit: violating it is a
  // domain conflict rather than a malformed payload.
  if (alarms.length > kMaxStoredAlarms) {
    return ContractCode.payloadSemanticError;
  }
  for (final alarm in alarms) {
    final code = _validateAlarm(alarm);
    if (code != ContractCode.accepted) {
      return code;
    }
  }
  final ids = alarms
      .map((a) => (a as Map)['id'])
      .cast<String>()
      .toList(growable: false);
  if (ids.toSet().length != ids.length) {
    return ContractCode.payloadSemanticError;
  }
  return ContractCode.accepted;
}

ContractCode _validateErrorResponseBody(Map<Object?, Object?> body) {
  final keys = body.keys.map((k) => '$k').toSet();
  if (!keys.containsAll(_errorRequiredKeys) ||
      !keys.every(_errorAllowedKeys.contains)) {
    return ContractCode.schemaInvalid;
  }
  if (!_errorCodeEnum.contains(body['code'])) {
    return ContractCode.schemaInvalid;
  }
  final summary = body['summary'];
  if (summary is! String || summary.isEmpty || !_isUtf8Bounded(summary, 160)) {
    return ContractCode.schemaInvalid;
  }
  if (body.containsKey('field')) {
    final field = body['field'];
    if (field is! String || !_isUtf8Bounded(field, 64)) {
      return ContractCode.schemaInvalid;
    }
  }
  if (body['retryable'] is! bool) {
    return ContractCode.schemaInvalid;
  }
  if (body.containsKey('currentRevision')) {
    final revision = body['currentRevision'];
    if (!_isInt(revision) || (revision as int) < 0) {
      return ContractCode.schemaInvalid;
    }
  }
  return ContractCode.accepted;
}

ContractCode _validateSyncReceiptBody(Map<Object?, Object?> body) {
  for (final key in ['appliedRevision', 'alarmCount', 'nextAlarmUtc']) {
    if (!body.containsKey(key)) {
      return ContractCode.schemaInvalid;
    }
  }
  final applied = body['appliedRevision'];
  if (!_isInt(applied) || (applied as int) < 0) {
    return ContractCode.schemaInvalid;
  }
  final count = body['alarmCount'];
  if (!_isInt(count) || (count as int) < 0) {
    return ContractCode.schemaInvalid;
  }
  if (count > kMaxStoredAlarms) {
    return ContractCode.payloadSemanticError;
  }
  final next = body['nextAlarmUtc'];
  if (next is! String || !_sentAtPattern.hasMatch(next)) {
    return ContractCode.schemaInvalid;
  }
  return ContractCode.accepted;
}

/// Validates one decoded message payload through the full gate in the
/// documented rule order: protocol -> known type -> messageId -> replay ->
/// sentAt -> expectedRevision -> size -> body. [replayWindow] (optional)
/// detects duplicate message ids the same bounded way the firmware
/// `ReplayWindow` does; a valid message is remembered only after full
/// acceptance.
ContractCode validateContractMessage(
  Map<String, Object?> payload, {
  Set<String>? replayWindow,
}) {
  if (payload['protocol'] != kProtocolVersion) {
    return ContractCode.invalidProtocol;
  }
  final type = payload['type'];
  if (type is! String || !kKnownTypes.contains(type)) {
    return ContractCode.unknownType;
  }
  final messageId = payload['messageId'];
  if (messageId is! String || !_messageIdPattern.hasMatch(messageId)) {
    return ContractCode.invalidMessageId;
  }
  if (replayWindow != null && replayWindow.contains(messageId)) {
    return ContractCode.duplicateMessageId;
  }
  final sentAt = payload['sentAt'];
  if (sentAt is! String || !_sentAtPattern.hasMatch(sentAt)) {
    return ContractCode.invalidSentAt;
  }
  if (kRevisionRequiredTypes.contains(type) &&
      !payload.containsKey('expectedRevision')) {
    return ContractCode.expectedRevisionRequired;
  }
  if (serializedEnvelopeBytes(payload) > kMaxEnvelopeBytes) {
    return ContractCode.envelopeTooLarge;
  }
  final body = payload['body'];
  if (body is! Map) {
    return ContractCode.schemaInvalid;
  }
  ContractCode code;
  if (kRevisionRequiredTypes.contains(type)) {
    code = _validateScheduleBody(body.cast<Object?, Object?>());
  } else if (type == 'error.response') {
    code = _validateErrorResponseBody(body.cast<Object?, Object?>());
  } else if (type == 'event.syncReceipt') {
    code = _validateSyncReceiptBody(body.cast<Object?, Object?>());
  } else {
    // Remaining known v1 types carry no checked-in body schema yet and
    // pass through as accepted (body object shape enforced above),
    // matching message_body_validator.cpp.
    code = ContractCode.accepted;
  }
  if (code == ContractCode.accepted && replayWindow != null) {
    replayWindow.add(messageId);
  }
  return code;
}
