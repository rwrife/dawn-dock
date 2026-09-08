#include "dawn/json_parser.hpp"

#include "dawn/protocol_service.hpp"

#include <charconv>
#include <cstdint>

namespace dawn {
namespace {

// Parsing an envelope-sized payload is the worst legitimate case; anything
// larger is rejected before parsing even starts.
constexpr std::size_t kMaximumInputBytes = kProtocolEnvelopeMaximumBytes;

// Aggregate construction that keeps -Wmissing-field-initializers quiet.
JsonValue make_value(JsonKind kind) {
  JsonValue value;
  value.kind = kind;
  return value;
}

class Parser {
 public:
  Parser(std::string_view text, JsonParseResult &result)
      : text_(text), result_(result) {}

  bool parse() {
    skip_ws();
    if (!parse_value("")) {
      return false;
    }
    skip_ws();
    if (pos_ != text_.size()) {
      return fail(JsonParseCode::trailing_content, "");
    }
    return true;
  }

  JsonValue take_root() { return std::move(current_); }

 private:
  bool fail(JsonParseCode code, std::string_view path) {
    result_.ok = false;
    result_.error = JsonParseError{.code = code, .path = std::string(path)};
    return false;
  }

  void skip_ws() {
    while (pos_ < text_.size()) {
      const char c = text_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        ++pos_;
      } else {
        break;
      }
    }
  }

  bool literal(std::string_view expected) {
    if (text_.substr(pos_, expected.size()) != expected) {
      return false;
    }
    pos_ += expected.size();
    return true;
  }

  bool parse_value(std::string_view path) {
    if (depth_ >= kJsonMaximumDepth) {
      return fail(JsonParseCode::depth_limit, path);
    }
    if (nodes_ >= kJsonMaximumNodes) {
      return fail(JsonParseCode::node_limit, path);
    }
    if (pos_ >= text_.size()) {
      return fail(JsonParseCode::invalid_json, path);
    }
    ++depth_;
    ++nodes_;
    const bool parsed = parse_dispatch(path);
    --depth_;
    return parsed;
  }

  bool parse_dispatch(std::string_view path) {
    switch (text_[pos_]) {
      case '{':
        return parse_object(path);
      case '[':
        return parse_array(path);
      case '"':
        return parse_string_value(path);
      case 't':
        return literal("true") ? store_boolean(true, path) : invalid(path);
      case 'f':
        return literal("false") ? store_boolean(false, path) : invalid(path);
      case 'n':
        return literal("null") ? store_null() : invalid(path);
      default:
        return parse_number(path);
    }
  }

  bool invalid(std::string_view path) {
    return fail(JsonParseCode::invalid_json, path);
  }

  bool store_boolean(bool value, std::string_view path) {
    (void)path;
    current_ = make_value(JsonKind::boolean);
    current_.boolean = value;
    return true;
  }

  bool store_null() {
    current_ = make_value(JsonKind::null_value);
    return true;
  }

  bool parse_object(std::string_view path) {
    JsonValue object = make_value(JsonKind::object);
    ++pos_;  // consume '{'
    skip_ws();
    if (pos_ < text_.size() && text_[pos_] == '}') {
      ++pos_;
      current_ = std::move(object);
      return true;
    }
    while (true) {
      skip_ws();
      if (pos_ >= text_.size() || text_[pos_] != '"') {
        return fail(JsonParseCode::invalid_json, path);
      }
      std::string key;
      if (!parse_raw_string(key, path)) {
        return false;
      }
      skip_ws();
      if (pos_ >= text_.size() || text_[pos_] != ':') {
        return fail(JsonParseCode::invalid_json, path);
      }
      ++pos_;
      skip_ws();
      std::string child_path;
      child_path.reserve(path.size() + 1 + key.size());
      child_path.append(path);
      child_path.push_back('/');
      child_path.append(key);
      if (!parse_value(child_path)) {
        return false;
      }
      for (const auto &[existing, unused] : object.members) {
        (void)unused;
        if (existing == key) {
          return fail(JsonParseCode::duplicate_key, child_path);
        }
      }
      object.members.emplace_back(std::move(key), std::move(current_));
      skip_ws();
      if (pos_ >= text_.size()) {
        return fail(JsonParseCode::invalid_json, path);
      }
      if (text_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (text_[pos_] == '}') {
        ++pos_;
        current_ = std::move(object);
        return true;
      }
      return fail(JsonParseCode::invalid_json, path);
    }
  }

  bool parse_array(std::string_view path) {
    JsonValue array = make_value(JsonKind::array);
    ++pos_;  // consume '['
    skip_ws();
    if (pos_ < text_.size() && text_[pos_] == ']') {
      ++pos_;
      current_ = std::move(array);
      return true;
    }
    std::size_t index = 0;
    while (true) {
      skip_ws();
      std::string child_path;
      child_path.reserve(path.size() + 12);
      child_path.append(path);
      child_path.push_back('/');
      child_path.append(std::to_string(index));
      if (!parse_value(child_path)) {
        return false;
      }
      array.elements.push_back(std::move(current_));
      ++index;
      skip_ws();
      if (pos_ >= text_.size()) {
        return fail(JsonParseCode::invalid_json, path);
      }
      if (text_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (text_[pos_] == ']') {
        ++pos_;
        current_ = std::move(array);
        return true;
      }
      return fail(JsonParseCode::invalid_json, path);
    }
  }

  // Parses a JSON string token (must start at '"') into `out`.
  bool parse_raw_string(std::string &out, std::string_view path) {
    ++pos_;  // consume opening quote
    out.clear();
    while (true) {
      if (pos_ >= text_.size()) {
        return fail(JsonParseCode::invalid_json, path);
      }
      const char c = text_[pos_];
      if (c == '"') {
        ++pos_;
        break;
      }
      if (c == '\\') {
        if (!parse_escape(out, path)) {
          return false;
        }
        continue;
      }
      if (static_cast<unsigned char>(c) < 0x20) {
        return fail(JsonParseCode::invalid_json, path);
      }
      out.push_back(c);
      ++pos_;
      if (out.size() > kJsonMaximumStringBytes) {
        return fail(JsonParseCode::string_limit, path);
      }
    }
    if (!is_valid_utf8(out)) {
      return fail(JsonParseCode::invalid_json, path);
    }
    return true;
  }

  bool parse_string_value(std::string_view path) {
    std::string text_value;
    if (!parse_raw_string(text_value, path)) {
      return false;
    }
    current_ = make_value(JsonKind::string);
    current_.text = std::move(text_value);
    return true;
  }

  bool hex4(unsigned &value) {
    if (pos_ + 4 > text_.size()) {
      return false;
    }
    value = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = text_[pos_ + static_cast<std::size_t>(i)];
      unsigned digit = 0;
      if (c >= '0' && c <= '9') {
        digit = static_cast<unsigned>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        digit = static_cast<unsigned>(c - 'a') + 10U;
      } else if (c >= 'A' && c <= 'F') {
        digit = static_cast<unsigned>(c - 'A') + 10U;
      } else {
        return false;
      }
      value = (value << 4U) | digit;
    }
    pos_ += 4;
    return true;
  }

  void append_code_point(std::string &out, unsigned cp) {
    if (cp < 0x80U) {
      out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800U) {
      out.push_back(static_cast<char>(0xC0U | (cp >> 6U)));
      out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
    } else if (cp < 0x10000U) {
      out.push_back(static_cast<char>(0xE0U | (cp >> 12U)));
      out.push_back(static_cast<char>(0x80U | ((cp >> 6U) & 0x3FU)));
      out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
    } else {
      out.push_back(static_cast<char>(0xF0U | (cp >> 18U)));
      out.push_back(static_cast<char>(0x80U | ((cp >> 12U) & 0x3FU)));
      out.push_back(static_cast<char>(0x80U | ((cp >> 6U) & 0x3FU)));
      out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
    }
  }

  bool parse_escape(std::string &out, std::string_view path) {
    ++pos_;  // consume backslash
    if (pos_ >= text_.size()) {
      return fail(JsonParseCode::invalid_json, path);
    }
    const char e = text_[pos_++];
    switch (e) {
      case '"':
        out.push_back('"');
        break;
      case '\\':
        out.push_back('\\');
        break;
      case '/':
        out.push_back('/');
        break;
      case 'b':
        out.push_back('\b');
        break;
      case 'f':
        out.push_back('\f');
        break;
      case 'n':
        out.push_back('\n');
        break;
      case 'r':
        out.push_back('\r');
        break;
      case 't':
        out.push_back('\t');
        break;
      case 'u': {
        unsigned cp = 0;
        if (!hex4(cp)) {
          return fail(JsonParseCode::invalid_json, path);
        }
        if (cp >= 0xD800U && cp <= 0xDBFFU) {
          // High surrogate: require a following \uDC00-\uDFFF low surrogate.
          if (pos_ + 6 > text_.size() || text_[pos_] != '\\' ||
              text_[pos_ + 1] != 'u') {
            return fail(JsonParseCode::invalid_json, path);
          }
          pos_ += 2;
          unsigned low = 0;
          if (!hex4(low) || low < 0xDC00U || low > 0xDFFFU) {
            return fail(JsonParseCode::invalid_json, path);
          }
          cp = 0x10000U + ((cp - 0xD800U) << 10U) + (low - 0xDC00U);
        } else if (cp >= 0xDC00U && cp <= 0xDFFFU) {
          return fail(JsonParseCode::invalid_json, path);
        }
        append_code_point(out, cp);
        break;
      }
      default:
        return fail(JsonParseCode::invalid_json, path);
    }
    if (out.size() > kJsonMaximumStringBytes) {
      return fail(JsonParseCode::string_limit, path);
    }
    return true;
  }

  bool parse_number(std::string_view path) {
    const std::size_t start = pos_;
    bool negative = false;
    if (pos_ < text_.size() && text_[pos_] == '-') {
      negative = true;
      ++pos_;
    }
    if (pos_ >= text_.size() || text_[pos_] < '0' || text_[pos_] > '9') {
      return fail(JsonParseCode::invalid_json, path);
    }
    if (text_[pos_] == '0') {
      ++pos_;
      if (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
        return fail(JsonParseCode::invalid_json, path);  // leading zero
      }
    } else {
      while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
        ++pos_;
      }
    }
    // Fractional / exponent notation is rejected: the protocol carries integer
    // epochs and counters only.
    if (pos_ < text_.size() &&
        (text_[pos_] == '.' || text_[pos_] == 'e' || text_[pos_] == 'E')) {
      return fail(JsonParseCode::number_range, path);
    }
    const std::string_view digits = text_.substr(start, pos_ - start);
    std::int64_t parsed = 0;
    const auto *begin = digits.data();
    const auto *end = digits.data() + digits.size();
    const auto res = std::from_chars(begin, end, parsed);
    if (res.ec != std::errc{} || res.ptr != end) {
      return fail(JsonParseCode::number_range, path);
    }
    (void)negative;
    current_ = make_value(JsonKind::integer);
    current_.number = parsed;
    return true;
  }

  static bool is_valid_utf8(const std::string &text) {
    std::size_t i = 0;
    const auto byte_at = [&text](std::size_t index) {
      return static_cast<unsigned char>(text[index]);
    };
    while (i < text.size()) {
      const unsigned char b0 = byte_at(i);
      if (b0 < 0x80U) {
        ++i;
        continue;
      }
      std::size_t extra = 0;
      unsigned cp = 0;
      if (b0 >= 0xC2U && b0 <= 0xDFU) {
        extra = 1;
        cp = b0 & 0x1FU;
      } else if (b0 >= 0xE0U && b0 <= 0xEFU) {
        extra = 2;
        cp = b0 & 0x0FU;
      } else if (b0 >= 0xF0U && b0 <= 0xF4U) {
        extra = 3;
        cp = b0 & 0x07U;
      } else {
        return false;  // continuation lead, overlong C0/C1, or >U+10FFFF F5+
      }
      // Ensure all continuation bytes are present.
      if (i + extra >= text.size()) {
        return false;
      }
      for (std::size_t k = 1; k <= extra; ++k) {
        const unsigned char b = byte_at(i + k);
        if (b < 0x80U || b > 0xBFU) {
          return false;
        }
        cp = (cp << 6U) | (b & 0x3FU);
      }
      // Reject overlong forms and surrogates explicitly.
      if (extra == 2 && cp < 0x800U) {
        return false;
      }
      if (extra == 3 && cp < 0x10000U) {
        return false;
      }
      if (cp > 0x10FFFFU) {
        return false;
      }
      if (cp >= 0xD800U && cp <= 0xDFFFU) {
        return false;
      }
      i += extra + 1;
    }
    return true;
  }

  std::string_view text_;
  JsonParseResult &result_;
  std::size_t pos_{0};
  std::size_t depth_{0};
  std::size_t nodes_{0};
  JsonValue current_;
};

}  // namespace

JsonParseResult parse_json(std::string_view text) {
  JsonParseResult result;
  if (text.empty()) {
    result.error = JsonParseError{
        .code = JsonParseCode::invalid_json, .path = std::string()};
    return result;
  }
  if (text.size() > kMaximumInputBytes) {
    result.error = JsonParseError{
        .code = JsonParseCode::input_too_large, .path = std::string()};
    return result;
  }
  Parser parser(text, result);
  if (!parser.parse()) {
    return result;
  }
  result.value = parser.take_root();
  result.ok = true;
  return result;
}

const char *to_string(JsonParseCode code) {
  switch (code) {
    case JsonParseCode::ok:
      return "ok";
    case JsonParseCode::input_too_large:
      return "input_too_large";
    case JsonParseCode::invalid_json:
      return "invalid_json";
    case JsonParseCode::number_range:
      return "number_range";
    case JsonParseCode::string_limit:
      return "string_limit";
    case JsonParseCode::duplicate_key:
      return "duplicate_key";
    case JsonParseCode::depth_limit:
      return "depth_limit";
    case JsonParseCode::node_limit:
      return "node_limit";
    case JsonParseCode::trailing_content:
      return "trailing_content";
  }
  return "unknown";
}

}  // namespace dawn
