#include "dawn/message_body_validator.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <span>
#include <string_view>

namespace dawn {
namespace {

MessageBodyValidationResult reject(MessageBodyCode code, std::string path,
                                   bool retryable = false) {
  return MessageBodyValidationResult{
      .code = code,
      .accepted = false,
      .retryable = retryable,
      .field_path = std::move(path),
  };
}

MessageBodyValidationResult accept_body() {
  return MessageBodyValidationResult{
      .code = MessageBodyCode::accepted,
      .accepted = true,
      .retryable = false,
      .field_path = std::string(),
  };
}

std::string child_path(std::string_view parent, std::string_view key) {
  std::string joined;
  joined.reserve(parent.size() + 1 + key.size());
  joined.append(parent);
  joined.push_back('/');
  joined.append(key);
  return joined;
}

bool check_missing_required(const JsonValue &object,
                            std::string_view path_prefix,
                            std::span<const std::string_view> required,
                            MessageBodyValidationResult &failure) {
  for (const auto &key : required) {
    if (!object.has(key)) {
      failure = reject(MessageBodyCode::schema_invalid,
                       child_path(path_prefix, key));
      return false;
    }
  }
  return true;
}

bool check_no_unknown_keys(const JsonValue &object,
                           std::string_view path_prefix,
                           std::span<const std::string_view> allowed,
                           MessageBodyValidationResult &failure) {
  for (const auto &[key, value] : object.members) {
    (void)value;
    if (std::find(allowed.begin(), allowed.end(), std::string_view(key)) ==
        allowed.end()) {
      failure = reject(MessageBodyCode::schema_invalid,
                       child_path(path_prefix, key));
      return false;
    }
  }
  return true;
}

bool require_string(const JsonValue &object, std::string_view key,
                    std::string_view path_prefix, std::string_view &out,
                    MessageBodyValidationResult &failure) {
  const auto *value = object.find(key);
  const auto path = child_path(path_prefix, key);
  if (value == nullptr || value->kind != JsonKind::string) {
    failure = reject(MessageBodyCode::schema_invalid, path);
    return false;
  }
  out = value->text;
  return true;
}

bool require_boolean(const JsonValue &object, std::string_view key,
                     std::string_view path_prefix, bool &out,
                     MessageBodyValidationResult &failure) {
  const auto *value = object.find(key);
  const auto path = child_path(path_prefix, key);
  if (value == nullptr || value->kind != JsonKind::boolean) {
    failure = reject(MessageBodyCode::schema_invalid, path);
    return false;
  }
  out = value->boolean;
  return true;
}

bool require_integer(const JsonValue &object, std::string_view key,
                     std::string_view path_prefix, std::int64_t &out,
                     MessageBodyValidationResult &failure) {
  const auto *value = object.find(key);
  const auto path = child_path(path_prefix, key);
  if (value == nullptr || value->kind != JsonKind::integer) {
    failure = reject(MessageBodyCode::schema_invalid, path);
    return false;
  }
  out = value->number;
  return true;
}

bool is_lower_alnum(char c) {
  return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
}

bool is_id_tail_char(char c) {
  return is_lower_alnum(c) || c == '.' || c == '_' || c == '-';
}

// ^[a-z0-9][a-z0-9._-]{0,63}$ from alarm.schema.json.
bool is_valid_alarm_id(std::string_view id) {
  if (id.empty() || id.size() > kBodyMaximumAlarmIdBytes) {
    return false;
  }
  if (!is_lower_alnum(id.front())) {
    return false;
  }
  return std::all_of(id.begin() + 1, id.end(), is_id_tail_char);
}

// ^([01][0-9]|2[0-3]):[0-5][0-9]$ from alarm.schema.json.
bool is_valid_local_time(std::string_view value) {
  if (value.size() != 5 || value[2] != ':') {
    return false;
  }
  const auto tens = static_cast<unsigned char>(value[0]);
  const auto ones = static_cast<unsigned char>(value[1]);
  const auto minute_tens = static_cast<unsigned char>(value[3]);
  const auto minute_ones = static_cast<unsigned char>(value[4]);
  if (tens < '0' || tens > '2' || ones < '0' || ones > '9' ||
      minute_tens < '0' || minute_tens > '5' || minute_ones < '0' ||
      minute_ones > '9') {
    return false;
  }
  if (tens == '2' && ones > '3') {
    return false;  // 24:00-29:59 are invalid; 0x/1x hours accept all ones.
  }
  return true;
}

MessageBodyValidationResult validate_alarm(const JsonValue &alarm,
                                           std::string_view path) {
  if (alarm.kind != JsonKind::object) {
    return reject(MessageBodyCode::schema_invalid, std::string(path));
  }
  static constexpr std::array<std::string_view, 11> kRequired = {
      "id",       "label",          "enabled",        "localTime",
      "days",     "timezone",       "snoozeMinutes",  "volume",
      "sound",    "source",         "sourceEventId"};
  static constexpr std::array<std::string_view, 11> kAllowed = kRequired;

  MessageBodyValidationResult failure;
  if (!check_missing_required(alarm, path, kRequired, failure) ||
      !check_no_unknown_keys(alarm, path, kAllowed, failure)) {
    return failure;
  }

  std::string_view text;
  if (!require_string(alarm, "id", path, text, failure)) {
    return failure;
  }
  if (!is_valid_alarm_id(text)) {
    return reject(MessageBodyCode::schema_invalid, child_path(path, "id"));
  }

  if (!require_string(alarm, "label", path, text, failure)) {
    return failure;
  }
  if (text.empty() || text.size() > kBodyMaximumLabelBytes) {
    return reject(MessageBodyCode::schema_invalid, child_path(path, "label"));
  }

  bool enabled = false;
  if (!require_boolean(alarm, "enabled", path, enabled, failure)) {
    return failure;
  }

  if (!require_string(alarm, "localTime", path, text, failure)) {
    return failure;
  }
  if (!is_valid_local_time(text)) {
    return reject(MessageBodyCode::schema_invalid,
                  child_path(path, "localTime"));
  }

  const auto *days = alarm.find("days");
  const auto days_path = child_path(path, "days");
  if (days == nullptr || days->kind != JsonKind::array ||
      days->elements.empty() || days->elements.size() > 7) {
    return reject(MessageBodyCode::schema_invalid, days_path);
  }
  std::array<bool, 7> seen{};
  for (std::size_t index = 0; index < days->elements.size(); ++index) {
    const auto &day = days->elements[index];
    const auto day_path = child_path(days_path, std::to_string(index));
    if (day.kind != JsonKind::integer || day.number < 0 || day.number > 6) {
      return reject(MessageBodyCode::schema_invalid, day_path);
    }
    if (seen[static_cast<std::size_t>(day.number)]) {
      return reject(MessageBodyCode::schema_invalid, day_path);
    }
    seen[static_cast<std::size_t>(day.number)] = true;
  }

  if (!require_string(alarm, "timezone", path, text, failure)) {
    return failure;
  }
  if (text.size() < 3 || text.size() > kBodyMaximumTimezoneBytes) {
    return reject(MessageBodyCode::schema_invalid,
                  child_path(path, "timezone"));
  }

  std::int64_t number = 0;
  if (!require_integer(alarm, "snoozeMinutes", path, number, failure)) {
    return failure;
  }
  if (number < 1 || number > 30) {
    return reject(MessageBodyCode::schema_invalid,
                  child_path(path, "snoozeMinutes"));
  }

  if (!require_integer(alarm, "volume", path, number, failure)) {
    return failure;
  }
  if (number < 0 || number > 100) {
    return reject(MessageBodyCode::schema_invalid, child_path(path, "volume"));
  }

  if (!require_string(alarm, "sound", path, text, failure)) {
    return failure;
  }
  if (text.empty() || text.size() > kBodyMaximumSoundBytes) {
    return reject(MessageBodyCode::schema_invalid, child_path(path, "sound"));
  }

  if (!require_string(alarm, "source", path, text, failure)) {
    return failure;
  }
  if (text != "manual" && text != "ics") {
    return reject(MessageBodyCode::schema_invalid, child_path(path, "source"));
  }

  const auto *source_event = alarm.find("sourceEventId");
  if (source_event == nullptr) {
    return reject(MessageBodyCode::schema_invalid,
                  child_path(path, "sourceEventId"));
  }
  if (source_event->kind == JsonKind::null_value) {
    return accept_body();
  }
  if (source_event->kind != JsonKind::string ||
      source_event->text.size() > kBodyMaximumSourceEventIdBytes) {
    return reject(MessageBodyCode::schema_invalid,
                  child_path(path, "sourceEventId"));
  }
  return accept_body();
}

MessageBodyValidationResult validate_schedule_body(const JsonValue &body) {
  const auto *alarms = body.find("alarms");
  if (alarms == nullptr || alarms->kind != JsonKind::array) {
    return reject(MessageBodyCode::schema_invalid, "/alarms");
  }
  // kMaximumStoredAlarms is a storage design limit, not a wire-schema limit:
  // violating it is a domain conflict rather than a malformed payload.
  if (alarms->elements.size() > kBodyMaximumAlarms) {
    return reject(MessageBodyCode::payload_semantic_error, "/alarms");
  }
  for (std::size_t index = 0; index < alarms->elements.size(); ++index) {
    const auto alarm_path =
        child_path("/alarms", std::to_string(index));
    const auto result = validate_alarm(alarms->elements[index], alarm_path);
    if (!result.accepted) {
      return result;
    }
  }
  // Duplicate alarm ids break the storage journal's per-id high-watermark
  // assumptions; this is a domain conflict, not a schema violation.
  for (std::size_t first = 0; first < alarms->elements.size(); ++first) {
    const auto *first_id = alarms->elements[first].find("id");
    if (first_id == nullptr) {
      continue;  // schema issues were already returned above
    }
    for (std::size_t second = first + 1; second < alarms->elements.size();
         ++second) {
      const auto *second_id = alarms->elements[second].find("id");
      if (second_id != nullptr && second_id->text == first_id->text) {
        return reject(MessageBodyCode::payload_semantic_error,
                      child_path("/alarms", std::to_string(second)));
      }
    }
  }
  return accept_body();
}

// The stable error-model codes from error_response.schema.json.
bool is_valid_error_code(std::string_view code) {
  static constexpr std::array<std::string_view, 12> kCodes = {
      "invalid_protocol",        "unknown_type",
      "invalid_message_id",      "duplicate_message_id",
      "invalid_sent_at",         "expected_revision_required",
      "envelope_too_large",      "revision_conflict",
      "schema_invalid",          "payload_semantic_error",
      "unauthorized",            "rate_limited"};
  return std::find(kCodes.begin(), kCodes.end(), code) != kCodes.end();
}

MessageBodyValidationResult validate_error_response_body(
    const JsonValue &body) {
  static constexpr std::array<std::string_view, 3> kRequired = {
      "code", "summary", "retryable"};
  static constexpr std::array<std::string_view, 5> kAllowed = {
      "code", "summary", "field", "retryable", "currentRevision"};

  MessageBodyValidationResult failure;
  if (!check_missing_required(body, "", kRequired, failure) ||
      !check_no_unknown_keys(body, "", kAllowed, failure)) {
    return failure;
  }

  std::string_view text;
  if (!require_string(body, "code", "", text, failure)) {
    return failure;
  }
  if (!is_valid_error_code(text)) {
    return reject(MessageBodyCode::schema_invalid, "/code");
  }

  if (!require_string(body, "summary", "", text, failure)) {
    return failure;
  }
  if (text.empty() || text.size() > kBodyMaximumSummaryBytes) {
    return reject(MessageBodyCode::schema_invalid, "/summary");
  }

  if (body.has("field")) {
    if (!require_string(body, "field", "", text, failure)) {
      return failure;
    }
    if (text.size() > kBodyMaximumFieldBytes) {
      return reject(MessageBodyCode::schema_invalid, "/field");
    }
  }

  bool retryable = false;
  if (!require_boolean(body, "retryable", "", retryable, failure)) {
    return failure;
  }

  if (body.has("currentRevision")) {
    std::int64_t revision = 0;
    if (!require_integer(body, "currentRevision", "", revision, failure)) {
      return failure;
    }
    if (revision < 0) {
      return reject(MessageBodyCode::schema_invalid, "/currentRevision");
    }
  }
  return accept_body();
}

bool is_strict_utc_instant(std::string_view value) {
  // Same strict form the envelope gate applies to sentAt.
  if (value.size() != 20 || value[4] != '-' || value[7] != '-' ||
      value[10] != 'T' || value[13] != ':' || value[16] != ':' ||
      value[19] != 'Z') {
    return false;
  }
  const auto digit = [](char c) { return c >= '0' && c <= '9'; };
  return digit(value[0]) && digit(value[1]) && digit(value[2]) &&
         digit(value[3]) && digit(value[5]) && digit(value[6]) &&
         digit(value[8]) && digit(value[9]) && digit(value[11]) &&
         digit(value[12]) && digit(value[14]) && digit(value[15]) &&
         digit(value[17]) && digit(value[18]);
}

MessageBodyValidationResult validate_sync_receipt_body(const JsonValue &body) {
  // event.syncReceipt has no checked-in JSON Schema yet; the fixture
  // contract requires these three keys, so this core pins bounded types for
  // them and tolerates additional keys until a schema is committed.
  for (const auto &key :
       std::array<std::string_view, 3>{"appliedRevision", "alarmCount",
                                       "nextAlarmUtc"}) {
    if (!body.has(key)) {
      return reject(MessageBodyCode::schema_invalid, child_path("", key));
    }
  }

  MessageBodyValidationResult failure;
  std::int64_t number = 0;
  if (!require_integer(body, "appliedRevision", "", number, failure)) {
    return failure;
  }
  if (number < 0) {
    return reject(MessageBodyCode::schema_invalid, "/appliedRevision");
  }

  if (!require_integer(body, "alarmCount", "", number, failure)) {
    return failure;
  }
  if (number < 0) {
    return reject(MessageBodyCode::schema_invalid, "/alarmCount");
  }
  if (static_cast<std::uint64_t>(number) > kBodyMaximumAlarms) {
    // Storage can never hold that many alarms: a domain conflict.
    return reject(MessageBodyCode::payload_semantic_error, "/alarmCount");
  }

  std::string_view text;
  if (!require_string(body, "nextAlarmUtc", "", text, failure)) {
    return failure;
  }
  if (!is_strict_utc_instant(text)) {
    return reject(MessageBodyCode::schema_invalid, "/nextAlarmUtc");
  }
  return accept_body();
}

}  // namespace

MessageBodyValidationResult validate_protocol_message_body(
    const JsonValue &body, std::string_view type) {
  if (body.kind != JsonKind::object) {
    return reject(MessageBodyCode::schema_invalid, "/body");
  }
  if (type == "schedule.preview" || type == "schedule.apply") {
    return validate_schedule_body(body);
  }
  if (type == "error.response") {
    return validate_error_response_body(body);
  }
  if (type == "event.syncReceipt") {
    return validate_sync_receipt_body(body);
  }
  // Remaining known v1 types (device.status.get, time.configure,
  // schedule.get, diagnostics.get, backup.export, factory.reset,
  // event.alarmState) carry no checked-in body schema yet; the envelope
  // gate already enforced the object shape, so the body passes through.
  return accept_body();
}

ProtocolMessageValidationResult validate_protocol_message(
    const ProtocolEnvelope &envelope, std::string_view body_json,
    ReplayWindow *replay_window) {
  const auto envelope_result =
      validate_protocol_envelope(envelope, replay_window);
  if (!envelope_result.accepted) {
    return ProtocolMessageValidationResult{
        .accepted = false,
        .retryable = envelope_result.retryable,
        .code = to_string(envelope_result.code),
        .field_path = std::string(),
    };
  }

  auto parsed = parse_json(body_json);
  if (!parsed.ok) {
    if (parsed.error.code == JsonParseCode::input_too_large) {
      return ProtocolMessageValidationResult{
          .accepted = false,
          .retryable = false,
          .code = "envelope_too_large",
          .field_path = std::string(),
      };
    }
    std::string path = "/body";
    if (!parsed.error.path.empty()) {
      path.append(parsed.error.path);
    }
    return ProtocolMessageValidationResult{
        .accepted = false,
        .retryable = false,
        .code = "schema_invalid",
        .field_path = std::move(path),
    };
  }

  const auto body_result =
      validate_protocol_message_body(parsed.value, envelope.type);
  if (!body_result.accepted) {
    return ProtocolMessageValidationResult{
        .accepted = false,
        .retryable = body_result.retryable,
        .code = body_result.code == MessageBodyCode::schema_invalid
                    ? "schema_invalid"
                    : "payload_semantic_error",
        .field_path = body_result.field_path,
    };
  }
  return ProtocolMessageValidationResult{
      .accepted = true,
      .retryable = false,
      .code = "accepted",
      .field_path = std::string(),
  };
}

const char *to_string(MessageBodyCode code) {
  switch (code) {
    case MessageBodyCode::accepted:
      return "accepted";
    case MessageBodyCode::schema_invalid:
      return "schema_invalid";
    case MessageBodyCode::payload_semantic_error:
      return "payload_semantic_error";
  }
  return "unknown";
}

}  // namespace dawn
