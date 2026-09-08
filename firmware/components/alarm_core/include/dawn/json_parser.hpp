#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace dawn {

// Hard limits for the untrusted-input JSON subset accepted by the protocol
// stack. Messages are transport payloads; parsing must be bounded and must
// never throw.
constexpr std::size_t kJsonMaximumDepth = 16;
constexpr std::size_t kJsonMaximumNodes = 8192;
constexpr std::size_t kJsonMaximumStringBytes = 2048;

enum class JsonKind {
  object,
  array,
  string,
  integer,
  boolean,
  null_value,
};

// A parsed JSON value. Objects keep members in document order; duplicate
// object keys are rejected by the parser so `members` is always unique.
struct JsonValue {
  JsonKind kind{JsonKind::null_value};
  std::vector<std::pair<std::string, JsonValue>> members;  // object
  std::vector<JsonValue> elements;                         // array
  std::string text;                                        // string
  std::int64_t number{};                                   // integer
  bool boolean{};                                          // boolean

  // Object helpers.
  [[nodiscard]] const JsonValue *find(std::string_view key) const {
    for (const auto &[member_key, member_value] : members) {
      if (member_key == key) {
        return &member_value;
      }
    }
    return nullptr;
  }
  [[nodiscard]] bool has(std::string_view key) const {
    return find(key) != nullptr;
  }
};

enum class JsonParseCode {
  ok,
  input_too_large,
  invalid_json,    // syntax, escapes, UTF-8, lone surrogates
  number_range,    // fractional/exponent notation or out-of-int64 range
  string_limit,    // decoded string exceeds kJsonMaximumStringBytes
  duplicate_key,
  depth_limit,
  node_limit,
  trailing_content,
};

struct JsonParseError {
  JsonParseCode code{JsonParseCode::ok};
  // JSON-pointer-like path to the offending node ("" for the root).
  std::string path;
};

struct JsonParseResult {
  bool ok{false};
  JsonValue value;
  JsonParseError error;
};

// Strict, bounded JSON subset: no fractional or exponent notation, integers
// only within int64 range, mandatory well-formed UTF-8 (raw and \u-decoded,
// surrogates rejected), duplicate keys and trailing content rejected.
// The function never throws; every failure returns a code plus a field path.
[[nodiscard]] JsonParseResult parse_json(std::string_view text);

[[nodiscard]] const char *to_string(JsonParseCode code);

}  // namespace dawn
