#pragma once

#include "dawn/json_parser.hpp"
#include "dawn/protocol_service.hpp"

#include <cstddef>
#include <string>
#include <string_view>

namespace dawn {

// Bounds mirrored from docs/protocol/schemas/v1/alarm.schema.json plus the
// storage limits in dawn/schedule_store.hpp.
constexpr std::size_t kBodyMaximumAlarms = 32;             // == kMaximumStoredAlarms
constexpr std::size_t kBodyMaximumAlarmIdBytes = 64;       // alarm id pattern cap
constexpr std::size_t kBodyMaximumLabelBytes = 48;
constexpr std::size_t kBodyMaximumTimezoneBytes = 64;
constexpr std::size_t kBodyMaximumSoundBytes = 32;
constexpr std::size_t kBodyMaximumSourceEventIdBytes = 128;
constexpr std::size_t kBodyMaximumSummaryBytes = 160;
constexpr std::size_t kBodyMaximumFieldBytes = 64;

// Stable error-model codes (docs/protocol.md "Error model") that body-level
// validation is able to produce. Envelope preflight codes live in
// ProtocolValidationCode; parser failures map to schema_invalid.
enum class MessageBodyCode {
  accepted,
  schema_invalid,
  payload_semantic_error,
};

struct MessageBodyValidationResult {
  MessageBodyCode code{MessageBodyCode::accepted};
  bool accepted{};
  bool retryable{};
  // JSON-pointer-like path of the first violation ("" when accepted or when
  // the failure is body-wide).
  std::string field_path;
};

// Validates one decoded message body against the checked-in v1 schema rules
// for its envelope type. `type` must already be a known protocol type and
// `body` must be a JSON object (the caller enforces envelope shape).
//
// schedule.preview / schedule.apply: body.alarms must be an array of 0..32
// alarm records; every alarm property is schema-checked and duplicate alarm
// ids are a semantic conflict.
// error.response: body matches error_response.schema.json, including the
// stable error-code enum.
// event.syncReceipt: bounded appliedRevision/alarmCount/nextAlarmUtc fields;
// alarmCount must be within the storage bound.
// Remaining known v1 types carry no checked-in body schema yet and pass
// through as accepted (body object shape was enforced by the envelope gate).
[[nodiscard]] MessageBodyValidationResult validate_protocol_message_body(
    const JsonValue& body, std::string_view type);

// Composite gate: envelope preflight (protocol, type, ids, replay, revision
// requirement, size) -> body parsing -> body validation. The `code` field
// carries the stable error-model string from docs/protocol.md, so the same
// values appear in fixture manifests and wire-level error responses. Parse
// failures map to schema_invalid with the parser-reported field path. The
// replay window follows the envelope gate: an id is remembered once the
// envelope stage accepts, and later retries must use a fresh id.
struct ProtocolMessageValidationResult {
  bool accepted{};
  bool retryable{};
  std::string code;       // stable error-model code string
  std::string field_path;  // first violation path, empty when accepted
};

[[nodiscard]] ProtocolMessageValidationResult validate_protocol_message(
    const ProtocolEnvelope& envelope,
    std::string_view body_json,
    ReplayWindow* replay_window = nullptr);

[[nodiscard]] const char* to_string(MessageBodyCode code);

}  // namespace dawn
