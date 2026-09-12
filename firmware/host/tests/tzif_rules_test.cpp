#include "dawn/recurrence_resolver.hpp"
#include "dawn/tzif_rules.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#ifndef DAWN_TZIF_FIXTURE_ROOT
#error "DAWN_TZIF_FIXTURE_ROOT must be defined"
#endif

namespace {

using dawn::ParsedTzifZone;
using Status = dawn::TzifParseStatus;

int failures = 0;

void expect(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

std::int64_t utc_seconds(int year, unsigned month, unsigned day, unsigned hour,
                         unsigned minute = 0) {
  using namespace std::chrono;
  const auto instant = sys_days{year_month_day{std::chrono::year{year},
                                               std::chrono::month{month},
                                               std::chrono::day{day}}} +
                       hours{hour} + minutes{minute};
  return duration_cast<seconds>(instant.time_since_epoch()).count();
}

std::vector<std::byte> load_file(const std::filesystem::path &path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    std::cerr << "FAIL: cannot open fixture " << path << '\n';
    ++failures;
    return {};
  }
  const std::vector<char> chars{std::istreambuf_iterator<char>(input),
                                std::istreambuf_iterator<char>()};
  std::vector<std::byte> out;
  out.reserve(chars.size());
  for (const char c : chars) {
    out.push_back(static_cast<std::byte>(static_cast<std::uint8_t>(c)));
  }
  return out;
}

// --- synthetic TZif record construction -------------------------------------

void push_byte(std::vector<std::byte> &out, std::uint8_t value) {
  out.push_back(static_cast<std::byte>(value));
}

void push_text(std::vector<std::byte> &out, std::string_view text) {
  for (const char c : text) {
    push_byte(out, static_cast<std::uint8_t>(c));
  }
}

void push_u32(std::vector<std::byte> &out, std::uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8) {
    push_byte(out, static_cast<std::uint8_t>(value >> static_cast<unsigned>(shift)));
  }
}

void push_i64(std::vector<std::byte> &out, std::int64_t value) {
  const auto raw = static_cast<std::uint64_t>(value);
  for (int shift = 56; shift >= 0; shift -= 8) {
    push_byte(out,
              static_cast<std::uint8_t>(
                  raw >> static_cast<unsigned>(shift)));
  }
}

void push_i32(std::vector<std::byte> &out, std::int32_t value) {
  push_u32(out, static_cast<std::uint32_t>(value));
}

struct RawTtinfo {
  std::int32_t gmtoff{};
  std::uint8_t isdst{};
  std::uint8_t abbrind{};
};

struct RawHeader {
  std::uint32_t isut{};
  std::uint32_t isstd{};
  std::uint32_t leap{};
  std::uint32_t time{};
  std::uint32_t type{};
  std::uint32_t character{};
};

RawHeader header_for(std::size_t time_count, std::size_t type_count,
                     std::size_t char_count) {
  return RawHeader{
      .isut = 0,
      .isstd = 0,
      .leap = 0,
      .time = static_cast<std::uint32_t>(time_count),
      .type = static_cast<std::uint32_t>(type_count),
      .character = static_cast<std::uint32_t>(char_count)};
}

// Builds a layout-faithful TZif stream: a 44-byte v1 block with zero counts
// followed by a v2+ block. Declared counts come from the header argument so
// callers can deliberately over- or under-declare to exercise malformed
// inputs.
std::vector<std::byte> make_record(char version, const RawHeader &header,
                                   const std::vector<std::int64_t> &times,
                                   const std::vector<std::uint8_t> &type_indices,
                                   const std::vector<RawTtinfo> &ttinfos,
                                   std::string_view chars) {
  std::vector<std::byte> out;
  push_text(out, std::string_view{"TZif", 4});
  push_byte(out, 0); // v1 version byte (NUL)
  for (int i = 0; i < 15; ++i) {
    push_byte(out, 0);
  }
  for (int i = 0; i < 6; ++i) {
    push_u32(out, 0);
  }
  push_text(out, std::string_view{"TZif", 4});
  push_byte(out, static_cast<std::uint8_t>(version));
  for (int i = 0; i < 15; ++i) {
    push_byte(out, 0);
  }
  push_u32(out, header.isut);
  push_u32(out, header.isstd);
  push_u32(out, header.leap);
  push_u32(out, header.time);
  push_u32(out, header.type);
  push_u32(out, header.character);
  for (const auto value : times) {
    push_i64(out, value);
  }
  for (const auto index : type_indices) {
    push_byte(out, index);
  }
  for (const auto &ttinfo : ttinfos) {
    push_i32(out, ttinfo.gmtoff);
    push_byte(out, ttinfo.isdst);
    push_byte(out, ttinfo.abbrind);
  }
  push_text(out, chars);
  return out;
}

constexpr std::string_view kEstEdt{"EST\0EDT\0", 8};
constexpr std::string_view kEstEdtXdt{"EST\0EDT\0XDT\0", 12};
constexpr std::string_view kUtc{"UTC\0", 4};

Status parse(std::string_view name, const std::vector<std::byte> &record,
             ParsedTzifZone &zone) {
  return dawn::parse_tzif_zone(name, std::span<const std::byte>(record), zone)
      .status;
}

void chain_is_resolver_valid(const dawn::TimezoneRules &rules,
                             std::string_view context) {
  auto running = rules.initial_utc_offset_seconds;
  std::int64_t previous = std::numeric_limits<std::int64_t>::min();
  bool first = true;
  for (const auto &transition : rules.transitions) {
    const std::string label(context);
    expect(transition.offset_before_seconds == running,
           label + ": chain offset_before continuity");
    expect(first || transition.at_utc_seconds > previous,
           label + ": strictly increasing transition times");
    expect(transition.offset_before_seconds !=
               transition.offset_after_seconds,
           label + ": transitions change the offset");
    expect(transition.offset_before_seconds >= -86400 &&
               transition.offset_before_seconds <= 86400 &&
               transition.offset_after_seconds >= -86400 &&
               transition.offset_after_seconds <= 86400,
           label + ": offsets within one day");
    expect(transition.at_utc_seconds < dawn::kTzifTailCutoffUtcSeconds,
           label + ": no tail-sentinel transitions");
    previous = transition.at_utc_seconds;
    running = transition.offset_after_seconds;
    first = false;
  }
}

// --- synthetic record tests --------------------------------------------------

void accepts_minimal_valid_record() {
  const auto record =
      make_record('2', header_for(1, 2, kEstEdt.size()), {1000}, {1},
                  {{-18000, 0, 0}, {-14400, 1, 4}}, kEstEdt);
  ParsedTzifZone zone;
  expect(parse("Test/Zone", record, zone) == Status::ok, "minimal parses");
  expect(zone.initial_utc_offset_seconds == -18000, "initial from first type");
  expect(zone.transitions.size() == 1, "one emitted transition");
  expect(zone.transitions[0].at_utc_seconds == 1000, "transition instant");
  expect(zone.transitions[0].offset_before_seconds == -18000 &&
             zone.transitions[0].offset_after_seconds == -14400,
         "transition offsets");
  expect(!zone.truncated_at_cutoff, "no truncation");
  expect(zone.source_transition_count == 1 &&
             zone.emitted_transition_count == 1,
         "counts reported");
  expect(zone.zone_name == "Test/Zone", "zone name echoed");
}

void rejects_bad_magic_and_versions() {
  ParsedTzifZone zone;
  std::vector<std::byte> garbage;
  push_text(garbage, "NOPE");
  for (int i = 0; i < 100; ++i) {
    push_byte(garbage, 0);
  }
  expect(parse("Test/Zone", garbage, zone) == Status::bad_magic,
         "bad magic rejected");

  // v1-only file: exactly one 44-byte block.
  std::vector<std::byte> v1_only;
  push_text(v1_only, std::string_view{"TZif", 4});
  for (int i = 0; i < 16 + 24; ++i) {
    push_byte(v1_only, 0);
  }
  expect(parse("Test/Zone", v1_only, zone) == Status::unsupported_version,
         "v1-only rejected");

  const auto empty_counts = header_for(0, 0, 0);
  expect(parse("Test/Zone", make_record('4', empty_counts, {}, {}, {}, ""),
               zone) == Status::unsupported_version,
         "version 4 rejected");
  expect(parse("Test/Zone", make_record(' ', empty_counts, {}, {}, {}, ""),
               zone) == Status::unsupported_version,
         "unversioned second block rejected");
}

void rejects_truncated_records() {
  ParsedTzifZone zone;
  // Body shorter than the declared table.
  auto record = make_record('2', header_for(2, 2, kEstEdt.size()), {1000}, {1},
                            {{-18000, 0, 0}, {-14400, 1, 4}}, kEstEdt);
  expect(parse("Test/Zone", record, zone) == Status::truncated,
         "missing transition time rejected");

  record = make_record('2', header_for(3, 1, 0), {1000, 2000}, {},
                       {{-18000, 0, 0}}, "");
  expect(parse("Test/Zone", record, zone) == Status::truncated,
         "transition table past end rejected");

  record = make_record('2', header_for(1, 2, kEstEdt.size()), {1000}, {1},
                       {{-18000, 0, 0}, {-14400, 1, 4}}, kEstEdt);
  record.resize(record.size() - 4);
  expect(parse("Test/Zone", record, zone) == Status::truncated,
         "record ending mid-table rejected");
}

void rejects_malformed_tables() {
  ParsedTzifZone zone;
  auto record = make_record('2', header_for(2, 1, 0), {1000, 500}, {0, 0},
                            {{-18000, 0, 0}}, "");
  expect(parse("Test/Zone", record, zone) == Status::bad_transition_order,
         "unsorted transition times rejected");

  record = make_record('2', header_for(2, 1, 0), {1000, 1000}, {0, 0},
                       {{-18000, 0, 0}}, "");
  expect(parse("Test/Zone", record, zone) == Status::bad_transition_order,
         "equal transition times rejected");

  record = make_record('2', header_for(1, 1, 0), {1000}, {2},
                       {{-18000, 0, 0}}, "");
  expect(parse("Test/Zone", record, zone) == Status::bad_local_time_type,
         "type index past table rejected");

  record = make_record('2', header_for(1, 2, 0), {1000}, {1},
                       {{-18000, 0, 0}, {90061, 0, 0}}, "");
  expect(parse("Test/Zone", record, zone) == Status::bad_local_time_type,
         "offset beyond one day rejected");

  record = make_record('2', header_for(0, 0, 0), {}, {}, {}, "");
  expect(parse("Test/Zone", record, zone) == Status::empty_local_time_table,
         "empty ttinfo table rejected");
}

void rejects_capacity_violations() {
  ParsedTzifZone zone;
  const auto over_types = [] {
    auto header = header_for(0, dawn::kMaximumTzifTypes + 1, 0);
    return header;
  }();
  expect(parse("Test/Zone", make_record('2', over_types, {}, {}, {}, ""),
               zone) == Status::excessive_counts,
         "type ceiling enforced");

  const auto over_chars =
      header_for(0, 1, dawn::kMaximumTzifDesignationBytes + 1);
  expect(parse("Test/Zone",
               make_record('2', over_chars, {}, {}, {{-18000, 0, 0}}, ""),
               zone) == Status::excessive_counts,
         "designation ceiling enforced");

  auto oversized = make_record('2', header_for(1, 2, kEstEdt.size()), {1000},
                               {1}, {{-18000, 0, 0}, {-14400, 1, 4}}, kEstEdt);
  for (std::size_t i = 0; i < dawn::kMaximumTzifRecordBytes; ++i) {
    push_byte(oversized, 0);
  }
  expect(parse("Test/Zone", oversized, zone) == Status::excessive_counts,
         "record byte ceiling enforced");

  auto over_count = header_for(900, 0, 0);
  expect(parse("Test/Zone", make_record('2', over_count, {}, {}, {}, ""), zone) ==
             Status::excessive_counts,
         "transition count ceiling enforced");

  expect(parse("", make_record('2', header_for(0, 1, 0), {}, {},
                               {{-18000, 0, 0}}, ""),
               zone) == Status::invalid_zone_name,
         "empty zone name rejected");
  const std::string overlong(65, 'z');
  expect(parse(overlong,
               make_record('2', header_for(0, 1, 0), {}, {}, {{-18000, 0, 0}},
                           ""),
               zone) == Status::invalid_zone_name,
         "overlong zone name rejected");
}

void coalesces_abbreviation_only_changes() {
  // Type 2 has the same UTC offset as type 1 but a different abbreviation.
  const auto record = make_record(
      '2', header_for(2, 3, kEstEdtXdt.size()), {1000, 2000}, {1, 2},
      {{-18000, 0, 0}, {-14400, 1, 4}, {-14400, 1, 8}}, kEstEdtXdt);
  ParsedTzifZone zone;
  expect(parse("Test/Zone", record, zone) == Status::ok, "coalesce parses");
  expect(zone.source_transition_count == 2, "source keeps both");
  expect(zone.transitions.size() == 1, "abbreviation-only change dropped");
  expect(zone.transitions[0].at_utc_seconds == 1000, "real transition kept");
  expect(zone.emitted_transition_count == 1, "emitted count");
}

void drops_tail_sentinel_transitions() {
  const auto sentinel = dawn::kTzifTailCutoffUtcSeconds;
  const auto record =
      make_record('2', header_for(3, 2, kEstEdt.size()),
                  {1000, sentinel - 1, sentinel}, {1, 0, 1},
                  {{-18000, 0, 0}, {-14400, 1, 4}}, kEstEdt);
  ParsedTzifZone zone;
  expect(parse("Test/Zone", record, zone) == Status::ok, "sentinel parses");
  expect(zone.transitions.size() == 2, "sentinel transition dropped");
  expect(zone.transitions[1].at_utc_seconds == sentinel - 1,
         "transition before sentinel retained");
  expect(zone.truncated_at_cutoff, "truncation is visible");

  const auto only = make_record('2', header_for(1, 2, kEstEdt.size()),
                                {sentinel}, {1},
                                {{-18000, 0, 0}, {-14400, 1, 4}}, kEstEdt);
  expect(parse("Test/Zone", only, zone) == Status::ok,
         "sentinel-only record parses");
  expect(zone.transitions.empty() && zone.truncated_at_cutoff,
         "sentinel-only record emits nothing and reports truncation");
}

// --- adapter tests -----------------------------------------------------------

std::vector<std::byte> ny_like_record() {
  return make_record('2', header_for(2, 2, kEstEdt.size()), {1000, 2000},
                     {1, 0}, {{-18000, 0, 0}, {-14400, 1, 4}}, kEstEdt);
}

std::vector<std::byte> fixed_record() {
  return make_record('2', header_for(0, 1, kUtc.size()), {}, {},
                     {{7200, 0, 0}}, kUtc);
}

void adapter_windows_and_computes_initial_offset() {
  const auto record = ny_like_record();
  const std::array zones{
      std::pair{std::string_view("Test/New York"),
                std::span<const std::byte>(record)}};

  // Window (1500, 4000]: transition at 1000 folds into the initial offset,
  // transition at 2000 is emitted.
  const auto mid = dawn::TzifAdapterConfig{
      .version = "test-1",
      .from_utc_seconds = 1500,
      .until_utc_seconds = 4000,
      .maximum_total_transitions = 64};
  const auto mid_result = dawn::build_pinned_timezone_rules(zones, mid);
  expect(mid_result.issues.empty(), "clean build has no issues");
  expect(!mid_result.budget_exceeded, "within budget");
  expect(mid_result.zones.size() == 1, "one zone");
  const auto &rules = mid_result.zones[0];
  expect(rules.name == "Test/New York" && rules.version == "test-1",
         "provenance recorded");
  expect(rules.transitions.size() == 1, "only the in-window transition emits");
  expect(rules.transitions[0].at_utc_seconds == 2000, "correct transition");
  expect(rules.initial_utc_offset_seconds == -14400,
         "pre-window transition folds into the initial offset");
  chain_is_resolver_valid(rules, "mid-window synthetic");

  // Window past both transitions: everything folds into the initial offset.
  const auto past = dawn::TzifAdapterConfig{
      .version = "test-1",
      .from_utc_seconds = 2500,
      .until_utc_seconds = 4000,
      .maximum_total_transitions = 64};
  const auto past_result = dawn::build_pinned_timezone_rules(zones, past);
  expect(past_result.zones[0].transitions.empty(),
         "window past both transitions emits none");
  expect(past_result.zones[0].initial_utc_offset_seconds == -18000,
         "both pre-window transitions fold");

  const auto wide = dawn::TzifAdapterConfig{
      .version = "test-1",
      .from_utc_seconds = 500,
      .until_utc_seconds = 1500,
      .maximum_total_transitions = 64};
  const auto wide_result = dawn::build_pinned_timezone_rules(zones, wide);
  expect(wide_result.zones.size() == 1, "wide build keeps zone");
  expect(wide_result.zones[0].transitions.size() == 1,
         "only (from, until] transitions are emitted");
  expect(wide_result.zones[0].transitions[0].at_utc_seconds == 1000,
         "earlier transition emits");
  expect(wide_result.zones[0].initial_utc_offset_seconds == -18000,
         "pre-window offset honored");
  chain_is_resolver_valid(wide_result.zones[0], "windowed synthetic");

  const auto pre = dawn::TzifAdapterConfig{
      .version = "test-1",
      .from_utc_seconds = 900,
      .until_utc_seconds = 500,
      .maximum_total_transitions = 64};
  const auto pre_result = dawn::build_pinned_timezone_rules(zones, pre);
  expect(pre_result.zones.size() == 1, "empty window still builds rules");
  expect(pre_result.zones[0].transitions.empty(),
         "empty window emits no transitions");
}

void adapter_sorts_and_reports_parse_failures() {
  const auto alpha = ny_like_record();
  const auto zulu = fixed_record();
  std::vector<std::byte> broken;
  push_text(broken, "XXXX");
  for (int i = 0; i < 40; ++i) {
    push_byte(broken, 0);
  }
  const std::array zones{
      std::pair{std::string_view("Test/Zulu"), std::span<const std::byte>(zulu)},
      std::pair{std::string_view("Test/Broken"),
                std::span<const std::byte>(broken)},
      std::pair{std::string_view("Test/Alpha"), std::span<const std::byte>(alpha)}};
  const auto config = dawn::TzifAdapterConfig{
      .version = "test-2",
      .from_utc_seconds = 0,
      .until_utc_seconds = 5000,
      .maximum_total_transitions = 64};
  const auto result = dawn::build_pinned_timezone_rules(zones, config);
  expect(result.zones.size() == 2, "broken zone omitted, valid zones kept");
  expect(result.zones[0].name == "Test/Alpha" &&
             result.zones[1].name == "Test/Zulu",
         "zones deterministically sorted by name");
  expect(result.issues.size() == 1 &&
             result.issues[0].status == Status::bad_magic &&
             result.issues[0].zone_name == "Test/Broken",
         "parse failure surfaced with zone name");
  expect(result.total_emitted_transitions == 2, "emitted totals reported");
}

void adapter_budget_fails_closed() {
  const auto alpha = ny_like_record();
  const auto bravo = ny_like_record();
  const std::array zones{
      std::pair{std::string_view("Test/Alpha"),
                std::span<const std::byte>(alpha)},
      std::pair{std::string_view("Test/Bravo"),
                std::span<const std::byte>(bravo)}};
  const auto config = dawn::TzifAdapterConfig{
      .version = "test-3",
      .from_utc_seconds = 0,
      .until_utc_seconds = 5000,
      .maximum_total_transitions = 2};
  const auto result = dawn::build_pinned_timezone_rules(zones, config);
  expect(result.budget_exceeded, "budget violation visible");
  expect(result.zones.empty(), "budget violation emits no zones");
  expect(result.issues.size() == 1 &&
             result.issues[0].status == Status::excessive_counts,
         "budget violation reported");
}

void schedule_provenance_helper_matches_only_adapter_output() {
  const auto schedule = dawn::WeeklyAlarmSchedule{
      .local_hour = 7,
      .local_minute = 0,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::monday),
      .timezone_name = "Test/Alpha",
      .timezone_rules_version = "test-1"};
  const auto matched = dawn::TimezoneRules{
      .name = "Test/Alpha",
      .version = "test-1",
      .initial_utc_offset_seconds = 0,
      .transitions = {}};
  expect(dawn::adapter_rules_match_schedule(schedule, matched),
         "adapter version and name match");
  const auto wrong_version = dawn::TimezoneRules{
      .name = "Test/Alpha",
      .version = "test-2",
      .initial_utc_offset_seconds = 0,
      .transitions = {}};
  expect(!dawn::adapter_rules_match_schedule(schedule, wrong_version),
         "version drift rejected");
  const auto wrong_name = dawn::TimezoneRules{
      .name = "Test/Zulu",
      .version = "test-1",
      .initial_utc_offset_seconds = 0,
      .transitions = {}};
  expect(!dawn::adapter_rules_match_schedule(schedule, wrong_name),
         "name drift rejected");
}

// --- pinned real-data tests (IANA 2026c fixtures) -----------------------------

const dawn::TzifAdapterResult *g_pinned_result = nullptr;
std::vector<std::byte> g_new_york;
std::vector<std::byte> g_berlin;
std::vector<std::byte> g_apia;

bool build_pinned_once() {
  static dawn::TzifAdapterResult cached = [] {
    const auto root = std::filesystem::path(DAWN_TZIF_FIXTURE_ROOT);
    g_new_york = load_file(root / "America__New_York.tzif");
    g_berlin = load_file(root / "Europe__Berlin.tzif");
    g_apia = load_file(root / "Pacific__Apia.tzif");
    if (g_new_york.empty() || g_berlin.empty() || g_apia.empty()) {
      return dawn::TzifAdapterResult{};
    }
    const auto config = dawn::TzifAdapterConfig{
        .version = "iana-2026c",
        .from_utc_seconds = utc_seconds(2010, 1, 1, 0),
        .until_utc_seconds = utc_seconds(2040, 1, 1, 0),
        .maximum_total_transitions = 1024};
    const std::array zones{
        std::pair{std::string_view("America/New_York"),
                  std::span<const std::byte>(g_new_york)},
        std::pair{std::string_view("Europe/Berlin"),
                  std::span<const std::byte>(g_berlin)},
        std::pair{std::string_view("Pacific/Apia"),
                  std::span<const std::byte>(g_apia)}};
    return dawn::build_pinned_timezone_rules(zones, config);
  }();
  g_pinned_result = &cached;
  return cached.zones.size() == 3;
}

const dawn::TimezoneRules *find_rules(std::string_view name) {
  for (const auto &rules : g_pinned_result->zones) {
    if (rules.name == name) {
      return &rules;
    }
  }
  return nullptr;
}

dawn::ResolvedOccurrence resolve_daily(const dawn::TimezoneRules &rules,
                                       unsigned hour, unsigned minute,
                                       std::uint8_t weekday_mask,
                                       std::int64_t anchor) {
  const auto schedule = dawn::WeeklyAlarmSchedule{
      .local_hour = static_cast<std::uint8_t>(hour),
      .local_minute = static_cast<std::uint8_t>(minute),
      .iso_weekday_mask = weekday_mask,
      .timezone_name = rules.name,
      .timezone_rules_version = rules.version};
  return dawn::resolve_next_occurrence(schedule, rules, anchor);
}

void pinned_fixtures_build_and_satisfy_resolver_contracts() {
  expect(build_pinned_once(), "pinned fixtures build three zones");
  if (!build_pinned_once()) {
    return;
  }
  expect(g_pinned_result->issues.empty(), "pinned fixtures parse cleanly");
  expect(!g_pinned_result->budget_exceeded, "pinned set fits the budget");
  for (const auto &rules : g_pinned_result->zones) {
    expect(rules.version == "iana-2026c", "adapter provenance version");
    chain_is_resolver_valid(rules, rules.name);
    const auto probe =
        resolve_daily(rules, 7, 0, 0x7f, utc_seconds(2026, 1, 1, 0));
    expect(probe.status == dawn::OccurrenceResolutionStatus::resolved,
           "resolver accepts the adapter chain");
  }
  if (const auto *ny = find_rules("America/New_York")) {
    expect(ny->initial_utc_offset_seconds == -5 * 3600,
           "New York window starts in EST");
  }
  ParsedTzifZone apia_zone;
  const auto apia_issue =
      dawn::parse_tzif_zone("Pacific/Apia", std::span<const std::byte>(g_apia),
                            apia_zone);
  expect(apia_issue.status == Status::ok, "apia parses");
  // Apia's 2026c table carries a final transition at the 32-bit sentinel;
  // the adapter must report the truncation deterministically.
  expect(apia_zone.truncated_at_cutoff, "apia sentinel truncation visible");
}

void pinned_fixtures_reproduce_committed_gap_and_fold_instants() {
  if (!build_pinned_once()) {
    return;
  }
  const auto sunday = dawn::weekday_bit(dawn::IsoWeekday::sunday);
  constexpr std::uint8_t kAllDays = 0x7f;

  if (const auto *ny = find_rules("America/New_York")) {
    const auto gap = resolve_daily(*ny, 2, 30, sunday,
                                   utc_seconds(2026, 3, 7, 0));
    expect(gap.status == dawn::OccurrenceResolutionStatus::resolved,
           "NY gap resolves");
    expect(gap.scheduled_utc_seconds == utc_seconds(2026, 3, 8, 7),
           "NY 02:30 gap alarm shifts once to 03:00 local");
    expect(gap.shifted_for_gap && !gap.ambiguous_fold, "NY gap receipt");
    expect(
        gap.local_date == dawn::CivilDate{.year = 2026, .month = 3, .day = 8},
        "NY gap keeps its calendar date");

    const auto fold = resolve_daily(*ny, 1, 30, sunday,
                                    utc_seconds(2026, 10, 31, 0));
    expect(fold.status == dawn::OccurrenceResolutionStatus::resolved,
           "NY fold resolves");
    expect(fold.scheduled_utc_seconds == utc_seconds(2026, 11, 1, 5, 30),
           "NY fold rings the first 01:30 occurrence only");
    expect(fold.ambiguous_fold && !fold.shifted_for_gap, "NY fold receipt");
  }

  if (const auto *berlin = find_rules("Europe/Berlin")) {
    const auto gap = resolve_daily(*berlin, 2, 30, sunday,
                                   utc_seconds(2026, 3, 28, 0));
    expect(gap.scheduled_utc_seconds == utc_seconds(2026, 3, 29, 1),
           "Berlin 02:30 gap alarm shifts once to 03:00 local");
    expect(gap.shifted_for_gap && !gap.ambiguous_fold, "Berlin gap receipt");

    const auto fold = resolve_daily(*berlin, 2, 30, sunday,
                                    utc_seconds(2026, 10, 24, 0));
    expect(fold.scheduled_utc_seconds == utc_seconds(2026, 10, 25, 0, 30),
           "Berlin fold rings the first 02:30 occurrence only");
    expect(fold.ambiguous_fold && !fold.shifted_for_gap,
           "Berlin fold receipt");
  }

  if (const auto *apia = find_rules("Pacific/Apia")) {
    // Local 2011-12-30 did not exist. A daily 07:00 alarm anchored just
    // after the 2011-12-29 ring must skip the deleted Friday entirely and
    // ring on Saturday 2011-12-31 local.
    const auto next =
        resolve_daily(*apia, 7, 0, kAllDays, utc_seconds(2011, 12, 29, 18));
    expect(next.status == dawn::OccurrenceResolutionStatus::resolved,
           "Apia skipped-day window resolves");
    expect(next.scheduled_utc_seconds == utc_seconds(2011, 12, 30, 17),
           "Apia skips the fully deleted local date");
    expect(next.local_date ==
               dawn::CivilDate{.year = 2011, .month = 12, .day = 31},
           "Apia lands on the next existing local date");
  }
}

} // namespace

int main() {
  accepts_minimal_valid_record();
  rejects_bad_magic_and_versions();
  rejects_truncated_records();
  rejects_malformed_tables();
  rejects_capacity_violations();
  coalesces_abbreviation_only_changes();
  drops_tail_sentinel_transitions();
  adapter_windows_and_computes_initial_offset();
  adapter_sorts_and_reports_parse_failures();
  adapter_budget_fails_closed();
  schedule_provenance_helper_matches_only_adapter_output();
  pinned_fixtures_build_and_satisfy_resolver_contracts();
  pinned_fixtures_reproduce_committed_gap_and_fold_instants();

  if (failures != 0) {
    std::cerr << "tzif_rules_tests: " << failures << " failure(s)\n";
    return 1;
  }
  std::cout << "tzif_rules_tests: PASS\n";
  return 0;
}
