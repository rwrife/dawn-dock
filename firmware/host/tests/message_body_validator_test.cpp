#include "dawn/json_parser.hpp"
#include "dawn/message_body_validator.hpp"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>

namespace {

int failures = 0;

void expect(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

// Returns a copy of `text` with the first occurrence of `from` replaced by
// `to`, or nullopt when `from` is absent (guards test-data drift).
std::optional<std::string> replaced_once(std::string_view text,
                                         std::string_view from,
                                         std::string_view to) {
  const auto position = text.find(from);
  if (position == std::string_view::npos) {
    return std::nullopt;
  }
  std::string copy(text);
  copy.replace(position, from.size(), to);
  return copy;
}

std::string expect_replaced(std::optional<std::string> candidate,
                            std::string_view needle) {
  if (!candidate.has_value()) {
    std::cerr << "FAIL: test template missing substring: " << needle << '\n';
    ++failures;
    return "{}";
  }
  return std::move(*candidate);
}

void expect_body(const dawn::MessageBodyValidationResult &result,
                 dawn::MessageBodyCode code, std::string_view field_path,
                 std::string_view message) {
  if (result.code != code) {
    std::cerr << "FAIL: " << message << ": got code "
              << dawn::to_string(result.code) << '\n';
    ++failures;
  }
  if (result.field_path != field_path) {
    std::cerr << "FAIL: " << message << ": got path \"" << result.field_path
              << "\" expected \"" << field_path << "\"\n";
    ++failures;
  }
}

// ---------------------------------------------------------------------------
// Parser tests
// ---------------------------------------------------------------------------

void parser_accepts_scalars_and_structure() {
  const auto integer = dawn::parse_json("42");
  expect(integer.ok && integer.value.kind == dawn::JsonKind::integer &&
             integer.value.number == 42,
         "integer parses");

  const auto negative = dawn::parse_json("-7");
  expect(negative.ok && negative.value.number == -7, "negative integer parses");

  const auto minimum = dawn::parse_json("-9223372036854775808");
  expect(minimum.ok && minimum.value.number == INT64_MIN,
         "int64 minimum parses");

  const auto boolean = dawn::parse_json("true");
  expect(boolean.ok && boolean.value.kind == dawn::JsonKind::boolean &&
             boolean.value.boolean,
         "boolean parses");

  const auto null = dawn::parse_json("null");
  expect(null.ok && null.value.kind == dawn::JsonKind::null_value,
         "null parses");

  const auto object = dawn::parse_json(R"({"a":1,"b":[true,null,"s"]})");
  expect(object.ok, "object parses");
  if (object.ok) {
    const auto *member_a = object.value.find("a");
    const auto *member_b = object.value.find("b");
    expect(member_a != nullptr && member_a->number == 1,
           "object member found");
    expect(member_b != nullptr && member_b->elements.size() == 3,
           "array member size");
    expect(member_b != nullptr && member_b->elements[2].text == "s",
           "string element value");
  }

  const auto empty_object = dawn::parse_json("{}");
  expect(empty_object.ok && empty_object.value.members.empty(),
         "empty object parses");

  const auto empty_array = dawn::parse_json("[]");
  expect(empty_array.ok && empty_array.value.elements.empty(),
         "empty array parses");

  const auto whitespace = dawn::parse_json("  \n\t{\t\"a\" : 1}\r\n");
  expect(whitespace.ok, "surrounding whitespace tolerated");
}

void parser_validates_escapes_and_utf8() {
  const auto escapes = dawn::parse_json(
      R"("tab\tquote\"back\\slash\/newline\nrest")");
  expect(escapes.ok &&
             escapes.value.text == "tab\tquote\"back\\slash/newline\nrest",
         "escapes decode");

  // \u00e9 = é, \u20ac = €, \ud83d\ude00 = 😀 (surrogate pair).
  const auto precise = dawn::parse_json(
      "\"a\\u00e9\\u20ac\\ud83d\\ude00\"");
  const std::string expected =
      std::string("a") + "\xc3\xa9" + "\xe2\x82\xac" + "\xf0\x9f\x98\x80";
  expect(precise.ok && precise.value.text == expected,
         "surrogate pair and BMP escapes decode to UTF-8");

  const auto raw_utf8 = dawn::parse_json("\"héllo\"");
  expect(raw_utf8.ok && raw_utf8.value.text == "héllo",
         "raw UTF-8 accepted");
}

void parser_rejects_malformed_input() {
  expect(dawn::parse_json("").error.code == dawn::JsonParseCode::invalid_json,
         "empty input rejected");
  expect(dawn::parse_json("{").error.code == dawn::JsonParseCode::invalid_json,
         "truncated object rejected");
  expect(dawn::parse_json("[1,2,]").error.code ==
             dawn::JsonParseCode::invalid_json,
         "trailing comma array rejected");
  expect(dawn::parse_json("{'a':1}").error.code ==
             dawn::JsonParseCode::invalid_json,
         "single quotes rejected");
  expect(dawn::parse_json("01").error.code == dawn::JsonParseCode::invalid_json,
         "leading-zero number rejected");
  expect(dawn::parse_json("1.5").error.code ==
             dawn::JsonParseCode::number_range,
         "fractional number rejected");
  expect(dawn::parse_json("1e9").error.code == dawn::JsonParseCode::number_range,
         "exponent number rejected");
  expect(
      dawn::parse_json("9223372036854775808").error.code ==
          dawn::JsonParseCode::number_range,
      "out-of-int64 number rejected");
  expect(
      dawn::parse_json("{\"a\":1}{\"b\":2}").error.code ==
          dawn::JsonParseCode::trailing_content,
      "trailing content rejected");
  expect(dawn::parse_json(R"("unclosed)").error.code ==
             dawn::JsonParseCode::invalid_json,
         "unclosed string rejected");
  expect(dawn::parse_json("nul").error.code == dawn::JsonParseCode::invalid_json,
         "broken literal rejected");
  // -9223372036854775809 exceeds int64 (the -9223372036854775808 case parses).
  expect(
      dawn::parse_json("-9223372036854775809").error.code ==
          dawn::JsonParseCode::number_range,
      "out-of-int64 negative number rejected");
}

void parser_rejects_duplicate_keys_with_path() {
  const auto result = dawn::parse_json(R"({"a":{"b":1,"b":2}})");
  expect(!result.ok, "duplicate key rejected");
  expect(result.error.code == dawn::JsonParseCode::duplicate_key,
         "duplicate key reports duplicate_key");
  expect(result.error.path == "/a/b", "duplicate key reports field path");
}

void parser_rejects_bad_strings() {
  expect(
      dawn::parse_json("\"\x01\x02\"").error.code ==
          dawn::JsonParseCode::invalid_json,
      "raw control character rejected");
  expect(dawn::parse_json("\"\\x\"").error.code ==
             dawn::JsonParseCode::invalid_json,
         "unknown escape rejected");
  expect(dawn::parse_json("\"\\u12\"").error.code ==
             dawn::JsonParseCode::invalid_json,
         "short \\u escape rejected");
  // Lone high surrogate without a low surrogate.
  expect(dawn::parse_json("\"\\ud83d\"").error.code ==
             dawn::JsonParseCode::invalid_json,
         "lone high surrogate rejected");
  // Lone low surrogate.
  expect(dawn::parse_json("\"\\ude00\"").error.code ==
             dawn::JsonParseCode::invalid_json,
         "lone low surrogate rejected");
  // High surrogate followed by a non-low surrogate escape.
  expect(dawn::parse_json("\"\\ud83d\\u0041\"").error.code ==
             dawn::JsonParseCode::invalid_json,
         "surrogate pair with non-low half rejected");
  // Invalid UTF-8 continuation byte.
  expect(dawn::parse_json("\"\xc3\x28\"").error.code ==
             dawn::JsonParseCode::invalid_json,
         "invalid UTF-8 continuation rejected");
  // Overlong encoding of '/' (0xC0 0xAF).
  expect(dawn::parse_json("\"\xc0\xaf\"").error.code ==
             dawn::JsonParseCode::invalid_json,
         "overlong UTF-8 rejected");
}

void parser_enforces_limits() {
  std::string deep;
  deep.append(dawn::kJsonMaximumDepth + 1, '[');
  deep.append(dawn::kJsonMaximumDepth + 1, ']');
  expect(dawn::parse_json(deep).error.code == dawn::JsonParseCode::depth_limit,
         "depth limit enforced");

  std::string wide = "[";
  for (std::size_t i = 0; i < dawn::kJsonMaximumNodes + 1; ++i) {
    if (i != 0) {
      wide.push_back(',');
    }
    wide.push_back('1');
  }
  wide.push_back(']');
  expect(dawn::parse_json(wide).error.code == dawn::JsonParseCode::node_limit,
         "node limit enforced");

  const std::string long_string =
      "\"" + std::string(dawn::kJsonMaximumStringBytes + 1, 'x') + "\"";
  expect(dawn::parse_json(long_string).error.code ==
             dawn::JsonParseCode::string_limit,
         "string size limit enforced");

  const std::string boundary =
      "\"" + std::string(dawn::kJsonMaximumStringBytes, 'x') + "\"";
  expect(dawn::parse_json(boundary).ok, "boundary-size string accepted");

  const std::string oversized(dawn::kProtocolEnvelopeMaximumBytes + 1, ' ');
  expect(dawn::parse_json(oversized).error.code ==
             dawn::JsonParseCode::input_too_large,
         "input larger than envelope cap rejected before parsing");
}

// ---------------------------------------------------------------------------
// Body validator tests
// ---------------------------------------------------------------------------

std::string valid_alarm_json(std::string_view id = "wake") {
  return std::string(R"({"id":")") + std::string(id) +
         R"(","label":"Workday","enabled":true,"localTime":"07:00","days":[1,2,3,4,5],"timezone":"America/New_York","snoozeMinutes":9,"volume":45,"sound":"gentle-1","source":"manual","sourceEventId":null})";
}

dawn::JsonValue parse_body(std::string_view json) {
  auto parsed = dawn::parse_json(json);
  if (!parsed.ok) {
    std::cerr << "FAIL: test body failed to parse ("
              << dawn::to_string(parsed.error.code) << " @"
              << parsed.error.path << "): " << json.substr(0, 80) << '\n';
    ++failures;
    return dawn::JsonValue{};
  }
  return std::move(parsed.value);
}

dawn::JsonValue single_alarm_body(std::string_view alarm) {
  return parse_body("{\"alarms\":[" + std::string(alarm) + "]}");
}

void validator_accepts_valid_bodies() {
  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"alarms\":[" + valid_alarm_json("one") + "," +
                             valid_alarm_json("two") + "]}"),
                  "schedule.apply"),
              dawn::MessageBodyCode::accepted, "",
              "two-alarm schedule accepted");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"alarms\":[]}"), "schedule.preview"),
              dawn::MessageBodyCode::accepted, "", "empty alarms array accepted");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body(
                      "{\"code\":\"revision_conflict\",\"summary\":\"Schedule "
                      "revision mismatch\",\"field\":\"expectedRevision\","
                      "\"retryable\":true,\"currentRevision\":13}"),
                  "error.response"),
              dawn::MessageBodyCode::accepted, "",
              "valid error body accepted");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"appliedRevision\":13,\"alarmCount\":1,"
                             "\"nextAlarmUtc\":\"2026-09-07T11:00:00Z\"}"),
                  "event.syncReceipt"),
              dawn::MessageBodyCode::accepted, "",
              "valid sync receipt accepted");

  expect_body(
      dawn::validate_protocol_message_body(
          parse_body("{\"includeDiagnostics\":true}"), "device.status.get"),
      dawn::MessageBodyCode::accepted, "",
      "status body passes through pending schema");
}

void validator_reports_alarm_schema_violations() {
  const auto check = [](const dawn::JsonValue &body) {
    return dawn::validate_protocol_message_body(body, "schedule.apply");
  };

  // Missing required property: first missing key on an empty alarm object.
  expect_body(check(parse_body("{\"alarms\":[{}]}")),
              dawn::MessageBodyCode::schema_invalid, "/alarms/0/id",
              "missing alarm id reports first required path");

  // Wrong type on enabled.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(), "\"enabled\":true",
                                        "\"enabled\":\"yes\""),
                          "\"enabled\":true"))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/enabled",
      "non-boolean enabled rejected");

  // Invalid local time.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(),
                                        "\"localTime\":\"07:00\"",
                                        "\"localTime\":\"24:00\""),
                          "\"localTime\":\"07:00\""))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/localTime",
      "24:00 local time rejected");

  // Empty day list.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(), "\"days\":[1,2,3,4,5]",
                                        "\"days\":[]"),
                          "\"days\":[1,2,3,4,5]"))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/days",
      "empty days rejected");

  // Duplicate weekday.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(), "\"days\":[1,2,3,4,5]",
                                        "\"days\":[1,1]"),
                          "\"days\":[1,2,3,4,5]"))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/days/1",
      "duplicate weekday rejected");

  // Out-of-range weekday.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(), "\"days\":[1,2,3,4,5]",
                                        "\"days\":[7]"),
                          "\"days\":[1,2,3,4,5]"))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/days/0",
      "weekday above 6 rejected");

  // Snooze out of range.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(), "\"snoozeMinutes\":9",
                                        "\"snoozeMinutes\":31"),
                          "\"snoozeMinutes\":9"))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/snoozeMinutes",
      "snooze above 30 rejected");

  // Unknown alarm property.
  expect_body(
      check(single_alarm_body(expect_replaced(
          replaced_once(valid_alarm_json(), "{\"id\":",
                            "{\"extra\":true,\"id\":"),
          "{\"id\":"))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/extra",
      "unknown alarm property rejected");

  // Non-string sourceEventId type.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(),
                                        "\"sourceEventId\":null",
                                        "\"sourceEventId\":42"),
                          "\"sourceEventId\":null"))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/sourceEventId",
      "numeric sourceEventId rejected");

  // Uppercase alarm id violates the id pattern.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json("wake"), "\"id\":\"wake\"",
                                        "\"id\":\"Wake\""),
                          "\"id\":\"wake\""))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/id",
      "uppercase alarm id rejected");

  // Empty label.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(), "\"label\":\"Workday\"",
                                        "\"label\":\"\""),
                          "\"label\":\"Workday\""))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/label",
      "empty label rejected");

  // Unknown source enum.
  expect_body(
      check(single_alarm_body(
          expect_replaced(replaced_once(valid_alarm_json(), "\"source\":\"manual\"",
                                        "\"source\":\"google\""),
                          "\"source\":\"manual\""))),
      dawn::MessageBodyCode::schema_invalid, "/alarms/0/source",
      "unknown source enum rejected");

  // Alarms entry that is not an object.
  expect_body(check(parse_body("{\"alarms\":[7]}")),
              dawn::MessageBodyCode::schema_invalid, "/alarms/0",
              "non-object alarm rejected");

  // Missing alarms list.
  expect_body(check(parse_body("{}")),
              dawn::MessageBodyCode::schema_invalid, "/alarms",
              "missing alarms list rejected");
}

void validator_enforces_alarm_count_and_duplicates() {
  // 33 alarms exceed the storage bound -> semantic conflict.
  std::string many = "{\"alarms\":[";
  for (std::size_t i = 0; i < dawn::kBodyMaximumAlarms + 1; ++i) {
    if (i != 0) {
      many.push_back(',');
    }
    many.append(valid_alarm_json("alarm-" + std::to_string(i)));
  }
  many.append("]}");
  expect(many.size() < dawn::kProtocolEnvelopeMaximumBytes,
         "33-alarm test body stays inside the envelope cap");
  expect_body(
      dawn::validate_protocol_message_body(parse_body(many), "schedule.apply"),
      dawn::MessageBodyCode::payload_semantic_error, "/alarms",
      "alarm count above storage bound is a semantic conflict");

  // Duplicate alarm ids -> semantic conflict at the second entry.
  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"alarms\":[" + valid_alarm_json("dup") + "," +
                             valid_alarm_json("dup") + "]}"),
                  "schedule.apply"),
              dawn::MessageBodyCode::payload_semantic_error, "/alarms/1",
              "duplicate alarm id is a semantic conflict");
}

void validator_reports_error_response_violations() {
  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"code\":\"not-a-real-code\",\"summary\":\"x\","
                             "\"retryable\":false}"),
                  "error.response"),
              dawn::MessageBodyCode::schema_invalid, "/code",
              "unknown stable error code rejected");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"code\":\"schema_invalid\",\"summary\":\"\","
                             "\"retryable\":false}"),
                  "error.response"),
              dawn::MessageBodyCode::schema_invalid, "/summary",
              "empty summary rejected");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body(
                      "{\"code\":\"schema_invalid\",\"summary\":\"x\"}"),
                  "error.response"),
              dawn::MessageBodyCode::schema_invalid, "/retryable",
              "missing retryable rejected");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"code\":\"schema_invalid\",\"summary\":\"x\","
                             "\"retryable\":false,\"unknown\":1}"),
                  "error.response"),
              dawn::MessageBodyCode::schema_invalid, "/unknown",
              "unknown error body property rejected");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"code\":\"schema_invalid\",\"summary\":\"x\","
                             "\"retryable\":false,\"currentRevision\":-1}"),
                  "error.response"),
              dawn::MessageBodyCode::schema_invalid, "/currentRevision",
              "negative currentRevision rejected");
}

void validator_reports_sync_receipt_violations() {
  expect_body(
      dawn::validate_protocol_message_body(
          parse_body("{\"alarmCount\":1,\"nextAlarmUtc\":"
                     "\"2026-09-07T11:00:00Z\"}"),
          "event.syncReceipt"),
      dawn::MessageBodyCode::schema_invalid, "/appliedRevision",
      "missing appliedRevision rejected");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"appliedRevision\":1,\"alarmCount\":33,"
                             "\"nextAlarmUtc\":\"2026-09-07T11:00:00Z\"}"),
                  "event.syncReceipt"),
              dawn::MessageBodyCode::payload_semantic_error, "/alarmCount",
              "alarmCount above storage bound is a semantic conflict");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"appliedRevision\":1,\"alarmCount\":-2,"
                             "\"nextAlarmUtc\":\"2026-09-07T11:00:00Z\"}"),
                  "event.syncReceipt"),
              dawn::MessageBodyCode::schema_invalid, "/alarmCount",
              "negative alarmCount rejected");

  expect_body(dawn::validate_protocol_message_body(
                  parse_body("{\"appliedRevision\":1,\"alarmCount\":1,"
                             "\"nextAlarmUtc\":\"2026-09-07T11:00:00\"}"),
                  "event.syncReceipt"),
              dawn::MessageBodyCode::schema_invalid, "/nextAlarmUtc",
              "non-UTC nextAlarmUtc rejected");
}

void validator_rejects_non_object_bodies() {
  expect_body(
      dawn::validate_protocol_message_body(parse_body("[]"),
                                           "device.status.get"),
      dawn::MessageBodyCode::schema_invalid, "/body", "array body rejected");
}

// ---------------------------------------------------------------------------
// Composite gate tests
// ---------------------------------------------------------------------------

dawn::ProtocolEnvelope baseline_envelope(std::string_view type =
                                             "schedule.apply") {
  return dawn::ProtocolEnvelope{
      .protocol = "dawn-dock/1",
      .message_id = "msg-body-001",
      .sent_at_utc = "2026-09-06T12:00:00Z",
      .type = std::string(type),
      .expected_revision = std::optional<std::uint64_t>(12),
      .serialized_size_bytes = 512,
  };
}

void composite_accepts_valid_message() {
  dawn::ReplayWindow replay(8);
  const auto result = dawn::validate_protocol_message(
      baseline_envelope(), "{\"alarms\":[" + valid_alarm_json() + "]}",
      &replay);
  expect(result.accepted && result.code == "accepted",
         "valid schedule.apply message accepted");
}

void composite_maps_envelope_failures_to_stable_strings() {
  auto envelope = baseline_envelope();
  envelope.protocol = "dawn-dock/2";
  const auto bad_protocol = dawn::validate_protocol_message(envelope, "{}");
  expect(!bad_protocol.accepted && bad_protocol.code == "invalid_protocol",
         "composite reports invalid_protocol as stable string");

  envelope = baseline_envelope();
  envelope.expected_revision = std::nullopt;
  const auto missing_revision =
      dawn::validate_protocol_message(envelope, "{}");
  expect(!missing_revision.accepted &&
             missing_revision.code == "expected_revision_required" &&
             missing_revision.retryable,
         "composite keeps revision-required retryability");
}

void composite_maps_parse_failures_to_schema_invalid() {
  const auto result = dawn::validate_protocol_message(
      baseline_envelope(), "{\"alarms\":[", nullptr);
  expect(!result.accepted && result.code == "schema_invalid" &&
             result.field_path.rfind("/body", 0) == 0,
         "unparseable body reports schema_invalid under /body");

  const auto dup = dawn::validate_protocol_message(
      baseline_envelope(), "{\"alarms\":[],\"alarms\":[]}", nullptr);
  expect(!dup.accepted && dup.code == "schema_invalid" &&
             dup.field_path == "/body/alarms",
         "duplicate body key reports parser path under /body");
}

void composite_maps_body_failures_to_stable_strings() {
  const auto result = dawn::validate_protocol_message(
      baseline_envelope(), "{\"alarms\":{}}", nullptr);
  expect(!result.accepted && result.code == "schema_invalid" &&
             result.field_path == "/alarms",
         "non-array alarms reports schema_invalid at /alarms");

  const auto conflict = dawn::validate_protocol_message(
      baseline_envelope(),
      "{\"alarms\":[" + valid_alarm_json("dup") + "," +
          valid_alarm_json("dup") + "]}",
      nullptr);
  expect(!conflict.accepted &&
             conflict.code == "payload_semantic_error" &&
             conflict.field_path == "/alarms/1",
         "duplicate ids map to payload_semantic_error");
}

void composite_replay_window_follows_envelope_gate() {
  dawn::ReplayWindow replay(8);
  const auto envelope = baseline_envelope();

  // First send: envelope stage accepts (id remembered) but the body fails.
  const auto first = dawn::validate_protocol_message(envelope, "{bad", &replay);
  expect(!first.accepted && first.code == "schema_invalid",
         "first send with bad body rejected");

  // Retry with a fresh body but the same id: the envelope gate now reports a
  // replay, matching the documented retry-with-fresh-id contract.
  const auto second =
      dawn::validate_protocol_message(envelope, "{\"alarms\":[]}", &replay);
  expect(!second.accepted && second.code == "duplicate_message_id" &&
             second.retryable,
         "same message id is remembered after envelope acceptance");
}

}  // namespace

int main() {
  // Parser
  parser_accepts_scalars_and_structure();
  parser_validates_escapes_and_utf8();
  parser_rejects_malformed_input();
  parser_rejects_duplicate_keys_with_path();
  parser_rejects_bad_strings();
  parser_enforces_limits();

  // Body validator
  validator_accepts_valid_bodies();
  validator_reports_alarm_schema_violations();
  validator_enforces_alarm_count_and_duplicates();
  validator_reports_error_response_violations();
  validator_reports_sync_receipt_violations();
  validator_rejects_non_object_bodies();

  // Composite gate
  composite_accepts_valid_message();
  composite_maps_envelope_failures_to_stable_strings();
  composite_maps_parse_failures_to_schema_invalid();
  composite_maps_body_failures_to_stable_strings();
  composite_replay_window_follows_envelope_gate();

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }

  std::cout << "message_body_validator_tests: PASS\n";
  return EXIT_SUCCESS;
}
