#include "dawn/protocol_service.hpp"

#include <algorithm>
#include <array>
#include <cctype>

namespace dawn {
namespace {

bool is_valid_message_id_char(char value) {
  const auto ascii = static_cast<unsigned char>(value);
  return std::isalnum(ascii) != 0 || value == '-' || value == '_' ||
         value == ':' || value == '.';
}

bool is_valid_message_id(std::string_view message_id) {
  if (message_id.empty() || message_id.size() > kProtocolMessageIdMaximumBytes) {
    return false;
  }
  return std::all_of(message_id.begin(), message_id.end(),
                     is_valid_message_id_char);
}

bool all_digits(std::string_view value) {
  return !value.empty() &&
         std::all_of(value.begin(), value.end(), [](char c) {
           return std::isdigit(static_cast<unsigned char>(c)) != 0;
         });
}

bool is_valid_iso_utc(std::string_view sent_at_utc) {
  // Strict RFC 3339 UTC form required by protocol examples:
  // YYYY-MM-DDTHH:MM:SSZ (20 bytes)
  if (sent_at_utc.size() != 20) {
    return false;
  }
  if (sent_at_utc[4] != '-' || sent_at_utc[7] != '-' || sent_at_utc[10] != 'T' ||
      sent_at_utc[13] != ':' || sent_at_utc[16] != ':' || sent_at_utc[19] != 'Z') {
    return false;
  }
  if (!all_digits(sent_at_utc.substr(0, 4)) ||
      !all_digits(sent_at_utc.substr(5, 2)) ||
      !all_digits(sent_at_utc.substr(8, 2)) ||
      !all_digits(sent_at_utc.substr(11, 2)) ||
      !all_digits(sent_at_utc.substr(14, 2)) ||
      !all_digits(sent_at_utc.substr(17, 2))) {
    return false;
  }

  const auto month = std::stoi(std::string(sent_at_utc.substr(5, 2)));
  const auto day = std::stoi(std::string(sent_at_utc.substr(8, 2)));
  const auto hour = std::stoi(std::string(sent_at_utc.substr(11, 2)));
  const auto minute = std::stoi(std::string(sent_at_utc.substr(14, 2)));
  const auto second = std::stoi(std::string(sent_at_utc.substr(17, 2)));

  return month >= 1 && month <= 12 && day >= 1 && day <= 31 && hour >= 0 &&
         hour <= 23 && minute >= 0 && minute <= 59 && second >= 0 &&
         second <= 59;
}

bool is_known_request_type(std::string_view type) {
  static constexpr std::array<std::string_view, 11> kKnownTypes = {
      "device.status.get", "time.configure",   "schedule.preview",
      "schedule.apply",    "schedule.get",     "diagnostics.get",
      "backup.export",     "factory.reset",    "event.syncReceipt",
      "event.alarmState",  "error.response",
  };
  return std::find(kKnownTypes.begin(), kKnownTypes.end(), type) !=
         kKnownTypes.end();
}

bool requires_expected_revision(std::string_view type) {
  return type == "schedule.preview" || type == "schedule.apply";
}

}  // namespace

bool ReplayWindow::contains(std::string_view message_id) const {
  return set_.contains(std::string(message_id));
}

void ReplayWindow::remember(std::string message_id) {
  if (capacity_ == 0) {
    return;
  }
  if (set_.contains(message_id)) {
    return;
  }
  order_.push_back(message_id);
  set_.insert(std::move(message_id));
  while (order_.size() > capacity_) {
    set_.erase(order_.front());
    order_.pop_front();
  }
}

ProtocolValidationResult validate_protocol_envelope(
    const ProtocolEnvelope& envelope, ReplayWindow* replay_window) {
  if (envelope.protocol != "dawn-dock/1") {
    return {.code = ProtocolValidationCode::invalid_protocol,
            .accepted = false,
            .retryable = false};
  }
  if (!is_known_request_type(envelope.type)) {
    return {.code = ProtocolValidationCode::unknown_type,
            .accepted = false,
            .retryable = false};
  }
  if (!is_valid_message_id(envelope.message_id)) {
    return {.code = ProtocolValidationCode::invalid_message_id,
            .accepted = false,
            .retryable = false};
  }
  if (replay_window != nullptr && replay_window->contains(envelope.message_id)) {
    return {.code = ProtocolValidationCode::duplicate_message_id,
            .accepted = false,
            .retryable = true};
  }
  if (!is_valid_iso_utc(envelope.sent_at_utc)) {
    return {.code = ProtocolValidationCode::invalid_sent_at,
            .accepted = false,
            .retryable = false};
  }
  if (requires_expected_revision(envelope.type) &&
      !envelope.expected_revision.has_value()) {
    return {.code = ProtocolValidationCode::expected_revision_required,
            .accepted = false,
            .retryable = true};
  }
  if (envelope.serialized_size_bytes > kProtocolEnvelopeMaximumBytes) {
    return {.code = ProtocolValidationCode::envelope_too_large,
            .accepted = false,
            .retryable = false};
  }

  if (replay_window != nullptr) {
    replay_window->remember(envelope.message_id);
  }
  return {.code = ProtocolValidationCode::accepted,
          .accepted = true,
          .retryable = false};
}

const char* to_string(ProtocolValidationCode code) {
  switch (code) {
    case ProtocolValidationCode::accepted:
      return "accepted";
    case ProtocolValidationCode::invalid_protocol:
      return "invalid_protocol";
    case ProtocolValidationCode::unknown_type:
      return "unknown_type";
    case ProtocolValidationCode::invalid_message_id:
      return "invalid_message_id";
    case ProtocolValidationCode::duplicate_message_id:
      return "duplicate_message_id";
    case ProtocolValidationCode::invalid_sent_at:
      return "invalid_sent_at";
    case ProtocolValidationCode::expected_revision_required:
      return "expected_revision_required";
    case ProtocolValidationCode::envelope_too_large:
      return "envelope_too_large";
  }
  return "unknown";
}

}  // namespace dawn
