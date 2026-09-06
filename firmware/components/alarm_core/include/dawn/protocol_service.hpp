#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_set>

namespace dawn {

constexpr std::size_t kProtocolEnvelopeMaximumBytes = 64 * 1024;
constexpr std::size_t kProtocolMessageIdMaximumBytes = 128;

// Transport-neutral envelope for protocol preflight validation. Parsing and
// body-schema validation are intentionally out of scope for this component.
struct ProtocolEnvelope {
  std::string protocol;
  std::string message_id;
  std::string sent_at_utc;
  std::string type;
  std::optional<std::uint64_t> expected_revision;
  std::size_t serialized_size_bytes{};
};

enum class ProtocolValidationCode {
  accepted,
  invalid_protocol,
  unknown_type,
  invalid_message_id,
  duplicate_message_id,
  invalid_sent_at,
  expected_revision_required,
  envelope_too_large,
};

struct ProtocolValidationResult {
  ProtocolValidationCode code{ProtocolValidationCode::accepted};
  bool accepted{};
  bool retryable{};
};

// Bounded duplicate detector keyed by message ID.
class ReplayWindow {
 public:
  explicit ReplayWindow(std::size_t capacity) : capacity_(capacity) {}

  [[nodiscard]] bool contains(std::string_view message_id) const;
  void remember(std::string message_id);

 private:
  std::size_t capacity_{};
  std::deque<std::string> order_;
  std::unordered_set<std::string> set_;
};

[[nodiscard]] ProtocolValidationResult validate_protocol_envelope(
    const ProtocolEnvelope& envelope, ReplayWindow* replay_window = nullptr);

[[nodiscard]] const char* to_string(ProtocolValidationCode code);

}  // namespace dawn
