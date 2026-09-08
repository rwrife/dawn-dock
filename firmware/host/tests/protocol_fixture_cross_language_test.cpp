#include "dawn/json_parser.hpp"
#include "dawn/message_body_validator.hpp"

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#ifndef DAWN_FIXTURE_ROOT
#error "DAWN_FIXTURE_ROOT must be defined by the build"
#endif

namespace {

int failures = 0;

const std::filesystem::path kFixtureRoot{DAWN_FIXTURE_ROOT};

std::string read_file(const std::filesystem::path &path) {
  std::ifstream stream(path, std::ios::binary);
  std::ostringstream buffer;
  buffer << stream.rdbuf();
  return buffer.str();
}

const dawn::JsonValue *member(const dawn::JsonValue &object,
                              std::string_view key) {
  return object.find(key);
}

// Compact serialization used only to reproduce the fixture's serialized-size
// field for the envelope stage. Emitted in document order, matching the
// compact form the Python contract test uses when no explicit size metadata
// is present.
std::string compact(const dawn::JsonValue &value) {
  std::string out;
  switch (value.kind) {
    case dawn::JsonKind::object: {
      out.push_back('{');
      bool first = true;
      for (const auto &[key, child] : value.members) {
        if (!first) {
          out.push_back(',');
        }
        first = false;
        out.push_back('"');
        out.append(key);
        out.append("\":");
        out.append(compact(child));
      }
      out.push_back('}');
      break;
    }
    case dawn::JsonKind::array: {
      out.push_back('[');
      for (std::size_t i = 0; i < value.elements.size(); ++i) {
        if (i != 0) {
          out.push_back(',');
        }
        out.append(compact(value.elements[i]));
      }
      out.push_back(']');
      break;
    }
    case dawn::JsonKind::string:
      out.push_back('"');
      for (const char c : value.text) {
        switch (c) {
          case '"':
            out.append("\\\"");
            break;
          case '\\':
            out.append("\\\\");
            break;
          case '\n':
            out.append("\\n");
            break;
          case '\t':
            out.append("\\t");
            break;
          case '\r':
            out.append("\\r");
            break;
          default:
            out.push_back(c);
        }
      }
      out.push_back('"');
      break;
    case dawn::JsonKind::integer:
      out.append(std::to_string(value.number));
      break;
    case dawn::JsonKind::boolean:
      out.append(value.boolean ? "true" : "false");
      break;
    case dawn::JsonKind::null_value:
      out.append("null");
      break;
  }
  return out;
}

// Mirrors the stable-string mapping performed by validate_protocol_message,
// but drives the two stages with values already parsed from a fixture file.
std::string validate_fixture(const dawn::JsonValue &envelope_json) {
  dawn::ProtocolEnvelope envelope;
  if (const auto *protocol = member(envelope_json, "protocol");
      protocol != nullptr && protocol->kind == dawn::JsonKind::string) {
    envelope.protocol = protocol->text;
  }
  if (const auto *id = member(envelope_json, "messageId");
      id != nullptr && id->kind == dawn::JsonKind::string) {
    envelope.message_id = id->text;
  }
  if (const auto *sent = member(envelope_json, "sentAt");
      sent != nullptr && sent->kind == dawn::JsonKind::string) {
    envelope.sent_at_utc = sent->text;
  }
  if (const auto *type = member(envelope_json, "type");
      type != nullptr && type->kind == dawn::JsonKind::string) {
    envelope.type = type->text;
  }
  if (const auto *revision = member(envelope_json, "expectedRevision");
      revision != nullptr && revision->kind == dawn::JsonKind::integer &&
      revision->number >= 0) {
    envelope.expected_revision =
        static_cast<std::uint64_t>(revision->number);
  }

  // Fixture metadata may override the serialized size; otherwise the compact
  // document length is authoritative.
  std::size_t size = compact(envelope_json).size();
  if (const auto *meta = member(envelope_json, "_fixtureMeta");
      meta != nullptr && meta->kind == dawn::JsonKind::object) {
    if (const auto *reported = meta->find("serializedSizeBytes");
        reported != nullptr && reported->kind == dawn::JsonKind::integer) {
      size = static_cast<std::size_t>(reported->number);
    }
  }
  envelope.serialized_size_bytes = size;

  // Envelope stage uses the production preflight gate (no replay window:
  // fixtures are independent single messages).
  const auto envelope_result = dawn::validate_protocol_envelope(envelope);
  if (!envelope_result.accepted) {
    return dawn::to_string(envelope_result.code);
  }

  const auto *body = member(envelope_json, "body");
  if (body == nullptr) {
    return "schema_invalid";
  }
  const auto body_result =
      dawn::validate_protocol_message_body(*body, envelope.type);
  if (!body_result.accepted) {
    return body_result.code == dawn::MessageBodyCode::schema_invalid
               ? "schema_invalid"
               : "payload_semantic_error";
  }
  return "accepted";
}

struct FixtureEntry {
  std::string path;
  bool valid{};
  std::string expected_code;
};

std::vector<FixtureEntry> load_manifest() {
  const auto manifest_path = kFixtureRoot / "manifest.json";
  auto parsed = dawn::parse_json(read_file(manifest_path));
  if (!parsed.ok) {
    std::cerr << "FAIL: manifest.json did not parse ("
              << dawn::to_string(parsed.error.code) << ")\n";
    ++failures;
    return {};
  }
  const auto *fixtures = parsed.value.find("fixtures");
  if (fixtures == nullptr || fixtures->kind != dawn::JsonKind::array ||
      fixtures->elements.empty()) {
    std::cerr << "FAIL: manifest.json fixtures list missing or empty\n";
    ++failures;
    return {};
  }
  std::vector<FixtureEntry> entries;
  for (const auto &entry : fixtures->elements) {
    const auto *path = entry.find("path");
    const auto *valid = entry.find("valid");
    if (path == nullptr || valid == nullptr ||
        path->kind != dawn::JsonKind::string ||
        valid->kind != dawn::JsonKind::boolean) {
      std::cerr << "FAIL: manifest entry missing path/valid\n";
      ++failures;
      continue;
    }
    std::string expected;
    if (const auto *code = entry.find("expected_code");
        code != nullptr && code->kind == dawn::JsonKind::string) {
      expected = code->text;
    }
    entries.push_back(FixtureEntry{
        .path = path->text, .valid = valid->boolean,
        .expected_code = std::move(expected)});
  }
  return entries;
}

}  // namespace

int main() {
  const auto entries = load_manifest();
  std::size_t checked = 0;
  for (const auto &entry : entries) {
    ++checked;
    const auto fixture_path = kFixtureRoot / entry.path;
    auto parsed = dawn::parse_json(read_file(fixture_path));
    if (!parsed.ok) {
      std::cerr << "FAIL: " << entry.path << ": fixture did not parse ("
                << dawn::to_string(parsed.error.code) << ")\n";
      ++failures;
      continue;
    }
    const auto code = validate_fixture(parsed.value);
    if (entry.valid) {
      if (code != "accepted") {
        std::cerr << "FAIL: " << entry.path << ": expected accepted, got "
                  << code << '\n';
        ++failures;
      }
    } else if (code != entry.expected_code) {
      std::cerr << "FAIL: " << entry.path << ": expected "
                << entry.expected_code << ", got " << code << '\n';
      ++failures;
    }
  }

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }

  std::cout << "protocol_fixture_cross_language_tests: PASS (" << checked
            << " fixtures)\n";
  return EXIT_SUCCESS;
}
