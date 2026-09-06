#include "dawn/protocol_service.hpp"

#include <cstdlib>
#include <iostream>
#include <string_view>

namespace {

int failures = 0;

void expect(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

dawn::ProtocolEnvelope baseline_envelope() {
  return {
      .protocol = "dawn-dock/1",
      .message_id = "msg-001",
      .sent_at_utc = "2026-09-06T12:00:00Z",
      .type = "device.status.get",
      .expected_revision = std::nullopt,
      .serialized_size_bytes = 256,
  };
}

void valid_status_request_is_accepted() {
  dawn::ReplayWindow replay(8);
  const auto result =
      dawn::validate_protocol_envelope(baseline_envelope(), &replay);
  expect(result.accepted, "valid envelope is accepted");
  expect(result.code == dawn::ProtocolValidationCode::accepted,
         "accepted envelope reports accepted code");
}

void schedule_apply_requires_expected_revision() {
  auto envelope = baseline_envelope();
  envelope.type = "schedule.apply";
  envelope.expected_revision = std::nullopt;

  const auto missing = dawn::validate_protocol_envelope(envelope);
  expect(!missing.accepted, "schedule.apply without expected revision is rejected");
  expect(missing.code == dawn::ProtocolValidationCode::expected_revision_required,
         "missing expected revision reports explicit code");

  envelope.expected_revision = 42;
  const auto accepted = dawn::validate_protocol_envelope(envelope);
  expect(accepted.accepted, "schedule.apply with expected revision is accepted");
}

void replay_window_rejects_duplicate_message_ids() {
  dawn::ReplayWindow replay(4);
  auto envelope = baseline_envelope();

  const auto first = dawn::validate_protocol_envelope(envelope, &replay);
  expect(first.accepted, "first unique message id is accepted");

  const auto duplicate = dawn::validate_protocol_envelope(envelope, &replay);
  expect(!duplicate.accepted, "duplicate message id is rejected");
  expect(duplicate.code == dawn::ProtocolValidationCode::duplicate_message_id,
         "duplicate rejection reports replay code");
  expect(duplicate.retryable,
         "duplicate rejection is retryable with a fresh message id");
}

void replay_window_capacity_eviction_allows_old_id_after_rollover() {
  dawn::ReplayWindow replay(2);

  auto first = baseline_envelope();
  first.message_id = "first";
  auto second = baseline_envelope();
  second.message_id = "second";
  auto third = baseline_envelope();
  third.message_id = "third";

  expect(dawn::validate_protocol_envelope(first, &replay).accepted,
         "first message accepted");
  expect(dawn::validate_protocol_envelope(second, &replay).accepted,
         "second message accepted");
  expect(dawn::validate_protocol_envelope(third, &replay).accepted,
         "third message accepted and evicts oldest");

  const auto after_rollover = dawn::validate_protocol_envelope(first, &replay);
  expect(after_rollover.accepted,
         "evicted oldest id is accepted after bounded replay rollover");
}

void malformed_sent_at_and_unknown_protocol_are_rejected() {
  auto envelope = baseline_envelope();
  envelope.sent_at_utc = "2026-09-06 12:00:00";

  const auto bad_time = dawn::validate_protocol_envelope(envelope);
  expect(!bad_time.accepted, "non-RFC3339 UTC timestamp is rejected");
  expect(bad_time.code == dawn::ProtocolValidationCode::invalid_sent_at,
         "timestamp rejection reports invalid_sent_at");

  envelope = baseline_envelope();
  envelope.protocol = "dawn-dock/2";
  const auto bad_protocol = dawn::validate_protocol_envelope(envelope);
  expect(!bad_protocol.accepted, "unknown protocol major is rejected");
  expect(bad_protocol.code == dawn::ProtocolValidationCode::invalid_protocol,
         "protocol rejection reports invalid_protocol");
}

void invalid_message_id_and_oversize_frame_are_rejected() {
  auto envelope = baseline_envelope();
  envelope.message_id = "invalid id with spaces";

  const auto bad_id = dawn::validate_protocol_envelope(envelope);
  expect(!bad_id.accepted, "invalid message id charset is rejected");
  expect(bad_id.code == dawn::ProtocolValidationCode::invalid_message_id,
         "message id rejection reports invalid_message_id");

  envelope = baseline_envelope();
  envelope.serialized_size_bytes = dawn::kProtocolEnvelopeMaximumBytes + 1;

  const auto too_large = dawn::validate_protocol_envelope(envelope);
  expect(!too_large.accepted, "oversized envelope is rejected");
  expect(too_large.code == dawn::ProtocolValidationCode::envelope_too_large,
         "oversized envelope reports envelope_too_large");
}

}  // namespace

int main() {
  valid_status_request_is_accepted();
  schedule_apply_requires_expected_revision();
  replay_window_rejects_duplicate_message_ids();
  replay_window_capacity_eviction_allows_old_id_after_rollover();
  malformed_sent_at_and_unknown_protocol_are_rejected();
  invalid_message_id_and_oversize_frame_are_rejected();

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }

  std::cout << "protocol_service_tests: PASS\n";
  return EXIT_SUCCESS;
}
