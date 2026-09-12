#pragma once

#include "dawn/recurrence_resolver.hpp"

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace dawn {

constexpr std::size_t kMaximumTzifRecordBytes = 8192;
constexpr std::size_t kMaximumTzifTransitions = 250;
constexpr std::size_t kMaximumTzifTypes = 128;
constexpr std::size_t kMaximumTzifDesignationBytes = 1024;
// Explicit transition tables in current IANA data end shortly after 2037,
// and some zones carry a final transition at the 32-bit maximum as a
// end-of-table sentinel. Transitions at or after this instant are dropped
// deterministically; the POSIX-style footer is never interpreted.
constexpr std::int64_t kTzifTailCutoffUtcSeconds = 2147483647LL;

enum class TzifParseStatus {
  ok,
  invalid_zone_name,
  truncated,
  bad_magic,
  unsupported_version,
  excessive_counts,
  bad_local_time_type,
  bad_transition_order,
  empty_local_time_table,
};

struct TzifParseIssue {
  std::string zone_name;
  TzifParseStatus status{TzifParseStatus::ok};
  std::size_t detail_index{};
};

struct ParsedTzifZone {
  std::string zone_name;
  std::int32_t initial_utc_offset_seconds{};
  std::vector<UtcOffsetTransition> transitions;
  std::size_t source_transition_count{};
  std::size_t emitted_transition_count{};
  // True when the zone's own table extends beyond the tail cutoff and later
  // transitions were dropped deterministically.
  bool truncated_at_cutoff{};
};

// Deterministically converts one TZif (RFC 8536) record into the resolver's
// flat transition model. Only the version-2+ data block is consumed; the
// version-1 block is skipped, and the POSIX-style footer is ignored, so
// behavior past the explicit table depends solely on the pinned data
// version. Transitions that do not change the UTC offset (abbreviation-only
// changes) are coalesced away because the resolver models offsets only.
// Every malformed, truncated, or over-capacity record fails closed with a
// stable status and produces no output.
[[nodiscard]] TzifParseIssue parse_tzif_zone(std::string_view zone_name,
                                             std::span<const std::byte> data,
                                             ParsedTzifZone &out);

struct TzifAdapterConfig {
  // Provenance string recorded on every emitted TimezoneRules (for example
  // "iana-2026c"); schedules must name exactly this version to resolve.
  std::string version;
  // Only transitions with from_utc_seconds < at <= until_utc_seconds are
  // emitted. The window's initial offset is computed by walking every
  // preceding transition, so a mid-history window is still correct.
  std::int64_t from_utc_seconds{};
  std::int64_t until_utc_seconds{};
  // Aggregate budget across all zones. Exceeding it fails the whole adapter
  // deterministically so a pinned set can never silently lose zones.
  std::size_t maximum_total_transitions{};
};

struct TzifAdapterResult {
  std::string version;
  std::vector<TimezoneRules> zones;
  std::vector<TzifParseIssue> issues;
  std::size_t total_emitted_transitions{};
  // True when the aggregate budget forced a fail-closed empty result.
  bool budget_exceeded{};
};

// Builds a named, versioned rule set from a pinned set of TZif records for
// one window. A zone whose record fails to parse is omitted and reported in
// `issues`; valid zones are still returned. Exceeding the aggregate
// transition budget returns no zones at all with `budget_exceeded`.
[[nodiscard]] TzifAdapterResult build_pinned_timezone_rules(
    std::span<const std::pair<std::string_view, std::span<const std::byte>>>
        zones,
    const TzifAdapterConfig &config);

// Adapter-side provenance check: the rule set was produced by this adapter
// version and carries the schedule's timezone name. The resolver performs
// the same equality checks itself; this helper lets callers reject a
// mismatch before resolution with a clear reason.
[[nodiscard]] bool adapter_rules_match_schedule(
    const WeeklyAlarmSchedule &schedule, const TimezoneRules &rules);

} // namespace dawn
