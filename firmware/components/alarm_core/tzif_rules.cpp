#include "dawn/tzif_rules.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <optional>

namespace dawn {
namespace {

constexpr std::size_t kHeaderBytes = 44;
constexpr std::int64_t kSecondsPerDay = 24 * 60 * 60;
constexpr std::int32_t kMaximumZoneNameBytes = 64;

struct BigEndianReader {
  std::span<const std::byte> data;
  std::size_t position{};

  [[nodiscard]] std::optional<std::uint64_t> u32() {
    if (position + 4 > data.size()) {
      return std::nullopt;
    }
    std::uint64_t value = 0;
    for (std::size_t i = 0; i < 4; ++i) {
      value = (value << 8) |
              static_cast<std::uint64_t>(
                  std::to_integer<std::uint8_t>(data[position + i]));
    }
    position += 4;
    return value;
  }

  [[nodiscard]] std::optional<std::int64_t> i64() {
    if (position + 8 > data.size()) {
      return std::nullopt;
    }
    std::uint64_t value = 0;
    for (std::size_t i = 0; i < 8; ++i) {
      value = (value << 8) |
              static_cast<std::uint64_t>(
                  std::to_integer<std::uint8_t>(data[position + i]));
    }
    position += 8;
    return static_cast<std::int64_t>(value);
  }

  [[nodiscard]] std::optional<std::int32_t> i32() {
    const auto raw = u32();
    if (!raw) {
      return std::nullopt;
    }
    return static_cast<std::int32_t>(static_cast<std::uint32_t>(*raw));
  }

  [[nodiscard]] std::optional<std::uint8_t> u8() {
    if (position + 1 > data.size()) {
      return std::nullopt;
    }
    return std::to_integer<std::uint8_t>(data[position++]);
  }

  [[nodiscard]] bool skip(std::size_t bytes) {
    if (bytes > data.size() - position) {
      return false;
    }
    position += bytes;
    return true;
  }
};

bool has_tzif_magic(std::span<const std::byte> data, std::size_t offset) {
  if (offset + 4 > data.size()) {
    return false;
  }
  const char magic[4] = {
      static_cast<char>(std::to_integer<char>(data[offset])),
      static_cast<char>(std::to_integer<char>(data[offset + 1])),
      static_cast<char>(std::to_integer<char>(data[offset + 2])),
      static_cast<char>(std::to_integer<char>(data[offset + 3]))};
  return std::memcmp(magic, "TZif", 4) == 0;
}

bool fits_size(std::uint64_t value) {
  return value <= std::numeric_limits<std::size_t>::max();
}

struct Counts {
  std::uint64_t isut{};
  std::uint64_t isstd{};
  std::uint64_t leap{};
  std::uint64_t time{};
  std::uint64_t type{};
  std::uint64_t character{};
};

std::optional<Counts> read_counts(BigEndianReader &reader) {
  Counts counts;
  const auto isut = reader.u32();
  const auto isstd = reader.u32();
  const auto leap = reader.u32();
  const auto time = reader.u32();
  const auto type = reader.u32();
  const auto character = reader.u32();
  if (!isut || !isstd || !leap || !time || !type || !character) {
    return std::nullopt;
  }
  counts = {*isut, *isstd, *leap, *time, *type, *character};
  return counts;
}

// v1 blocks store 32-bit transition times and 4-byte leap pairs.
std::optional<std::size_t> block_byte_length(const Counts &counts,
                                             bool version_one) {
  const std::uint64_t time_size = version_one ? 4 : 8;
  const std::uint64_t leap_size = version_one ? 8 : 12;
  const std::uint64_t total =
      kHeaderBytes + counts.time * time_size + counts.time +
      counts.type * 6 + counts.character + counts.leap * leap_size +
      counts.isstd + counts.isut;
  if (!fits_size(total)) {
    return std::nullopt;
  }
  return static_cast<std::size_t>(total);
}

TzifParseIssue issue_for(std::string_view zone_name, TzifParseStatus status,
                         std::size_t detail = 0) {
  return TzifParseIssue{
      .zone_name = std::string(zone_name), .status = status,
      .detail_index = detail};
}

bool valid_offset(std::int32_t offset) {
  return offset >= -kSecondsPerDay && offset <= kSecondsPerDay;
}

} // namespace

TzifParseIssue parse_tzif_zone(std::string_view zone_name,
                               std::span<const std::byte> data,
                               ParsedTzifZone &out) {
  out = ParsedTzifZone{};
  if (zone_name.empty() || zone_name.size() > kMaximumZoneNameBytes) {
    return issue_for(zone_name, TzifParseStatus::invalid_zone_name,
                     zone_name.size());
  }
  if (data.size() > kMaximumTzifRecordBytes) {
    return issue_for(zone_name, TzifParseStatus::excessive_counts,
                     data.size());
  }
  if (!has_tzif_magic(data, 0)) {
    return issue_for(zone_name, TzifParseStatus::bad_magic);
  }

  BigEndianReader first{.data = data};
  // The first block occupies [0, N); its declared counts give N.
  first.position = 20;
  const auto first_counts = read_counts(first);
  if (!first_counts) {
    return issue_for(zone_name, TzifParseStatus::truncated);
  }
  const auto first_length = block_byte_length(*first_counts, true);
  if (!first_length) {
    return issue_for(zone_name, TzifParseStatus::excessive_counts);
  }
  const std::size_t second_start = *first_length;

  if (second_start + 5 > data.size() || !has_tzif_magic(data, second_start)) {
    return issue_for(zone_name, TzifParseStatus::unsupported_version);
  }
  const char version_char =
      static_cast<char>(std::to_integer<char>(data[second_start + 4]));
  if (version_char != '2' && version_char != '3') {
    return issue_for(zone_name, TzifParseStatus::unsupported_version);
  }

  if (second_start > data.size() - kHeaderBytes) {
    return issue_for(zone_name, TzifParseStatus::truncated);
  }
  BigEndianReader reader{.data = data};
  reader.position = second_start + 20;
  const auto counts = read_counts(reader);
  if (!counts) {
    return issue_for(zone_name, TzifParseStatus::truncated);
  }
  if (counts->time > kMaximumTzifTransitions ||
      counts->type > kMaximumTzifTypes ||
      counts->character > kMaximumTzifDesignationBytes) {
    return issue_for(zone_name, TzifParseStatus::excessive_counts);
  }
  if (counts->type == 0U) {
    // No ttinfo entries: the offset in effect before the first transition is
    // undefined. Fail closed rather than invent one.
    return issue_for(zone_name, TzifParseStatus::empty_local_time_table);
  }
  // Leap-second records do not influence civil UTC scheduling here: the
  // resolver model consumes whole UTC epoch seconds only.
  const auto second_length = block_byte_length(*counts, false);
  if (!second_length || *second_length > data.size() - second_start) {
    return issue_for(zone_name, TzifParseStatus::truncated);
  }

  std::vector<std::int64_t> times;
  times.reserve(static_cast<std::size_t>(counts->time));
  for (std::uint64_t i = 0; i < counts->time; ++i) {
    const auto value = reader.i64();
    if (!value) {
      return issue_for(zone_name, TzifParseStatus::truncated);
    }
    if (!times.empty() && *value <= times.back()) {
      return issue_for(zone_name, TzifParseStatus::bad_transition_order, i);
    }
    times.push_back(*value);
  }

  std::vector<std::uint8_t> type_indices;
  type_indices.reserve(static_cast<std::size_t>(counts->time));
  for (std::uint64_t i = 0; i < counts->time; ++i) {
    const auto index = reader.u8();
    if (!index || *index >= counts->type) {
      return issue_for(zone_name, TzifParseStatus::bad_local_time_type, i);
    }
    type_indices.push_back(*index);
  }

  struct LocalTimeType {
    std::int32_t gmtoff{};
  };
  std::vector<LocalTimeType> types;
  types.reserve(static_cast<std::size_t>(counts->type));
  for (std::uint64_t i = 0; i < counts->type; ++i) {
    const auto gmtoff = reader.i32();
    const auto isdst = reader.u8();
    const auto abbrind = reader.u8();
    if (!gmtoff || !isdst || !abbrind) {
      return issue_for(zone_name, TzifParseStatus::truncated);
    }
    if (!valid_offset(*gmtoff)) {
      return issue_for(zone_name, TzifParseStatus::bad_local_time_type, i);
    }
    types.push_back(LocalTimeType{*gmtoff});
  }

  // Convention (RFC 8536, as realized by tzdata and glibc): the offset in
  // effect before the first transition is the first ttinfo entry.
  const std::int32_t initial_offset = types.front().gmtoff;

  out.zone_name = zone_name;
  out.initial_utc_offset_seconds = initial_offset;
  out.source_transition_count = times.size();

  std::int32_t running_offset = initial_offset;
  for (std::size_t i = 0; i < times.size(); ++i) {
    const std::int32_t after_offset = types[type_indices[i]].gmtoff;
    if (times[i] >= kTzifTailCutoffUtcSeconds) {
      out.truncated_at_cutoff = true;
      break;
    }
    if (after_offset == running_offset) {
      continue; // Abbreviation-only change: invisible to offset model.
    }
    out.transitions.push_back(UtcOffsetTransition{
        .at_utc_seconds = times[i],
        .offset_before_seconds = running_offset,
        .offset_after_seconds = after_offset,
    });
    running_offset = after_offset;
  }
  out.emitted_transition_count = out.transitions.size();
  return issue_for(zone_name, TzifParseStatus::ok);
}

TzifAdapterResult build_pinned_timezone_rules(
    std::span<const std::pair<std::string_view, std::span<const std::byte>>>
        zones,
    const TzifAdapterConfig &config) {
  TzifAdapterResult result;
  result.version = config.version;

  std::vector<TimezoneRules> prepared;
  prepared.reserve(zones.size());
  std::size_t total = 0;

  for (const auto &[zone_name, bytes] : zones) {
    ParsedTzifZone parsed;
    const auto parse_issue = parse_tzif_zone(zone_name, bytes, parsed);
    if (parse_issue.status != TzifParseStatus::ok) {
      result.issues.push_back(parse_issue);
      continue;
    }

    // Window: initial offset at `from` comes from walking all preceding
    // transitions, then only (from, until] transitions are emitted.
    TimezoneRules rules;
    rules.name = parsed.zone_name;
    rules.version = config.version;
    // Phase 1: fold every transition at or before the window start into the
    // initial offset. Phase 2: emit only (from, until] transitions. The
    // parsed chain is continuous, so the folded offset equals the first
    // emitted transition's offset_before.
    std::int32_t running = parsed.initial_utc_offset_seconds;
    for (const auto &transition : parsed.transitions) {
      if (transition.at_utc_seconds > config.from_utc_seconds) {
        break;
      }
      running = transition.offset_after_seconds;
    }
    rules.initial_utc_offset_seconds = running;
    for (const auto &transition : parsed.transitions) {
      if (transition.at_utc_seconds <= config.from_utc_seconds) {
        continue;
      }
      if (transition.at_utc_seconds > config.until_utc_seconds) {
        break;
      }
      rules.transitions.push_back(transition);
      ++total;
      if (total > config.maximum_total_transitions) {
        result.budget_exceeded = true;
        result.zones.clear();
        result.issues.push_back(
            TzifParseIssue{.zone_name = parsed.zone_name,
                           .status = TzifParseStatus::excessive_counts,
                           .detail_index = total});
        return result;
      }
    }
    prepared.push_back(std::move(rules));
  }

  std::sort(prepared.begin(), prepared.end(),
            [](const TimezoneRules &left, const TimezoneRules &right) {
              return left.name < right.name;
            });
  for (const auto &rules : prepared) {
    result.total_emitted_transitions += rules.transitions.size();
  }
  result.zones = std::move(prepared);
  return result;
}

bool adapter_rules_match_schedule(const WeeklyAlarmSchedule &schedule,
                                  const TimezoneRules &rules) {
  return !schedule.timezone_name.empty() && rules.name == schedule.timezone_name &&
         schedule.timezone_rules_version == rules.version;
}

} // namespace dawn
