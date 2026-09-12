#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace dawn {

enum class IsoWeekday : std::uint8_t {
  monday = 0,
  tuesday,
  wednesday,
  thursday,
  friday,
  saturday,
  sunday,
};

[[nodiscard]] constexpr std::uint8_t weekday_bit(IsoWeekday weekday) {
  return static_cast<std::uint8_t>(1U << static_cast<std::uint8_t>(weekday));
}

struct CivilDate {
  int year{};
  unsigned month{};
  unsigned day{};

  bool operator==(const CivilDate &) const = default;
};

struct UtcOffsetTransition {
  std::int64_t at_utc_seconds{};
  std::int32_t offset_before_seconds{};
  std::int32_t offset_after_seconds{};
};

struct TimezoneRules {
  std::string name;
  std::string version;
  std::int32_t initial_utc_offset_seconds{};
  std::vector<UtcOffsetTransition> transitions;
};

struct WeeklyAlarmSchedule {
  std::uint8_t local_hour{};
  std::uint8_t local_minute{};
  std::uint8_t iso_weekday_mask{};
  std::string timezone_name;
  std::string timezone_rules_version;
};

enum class OccurrenceResolutionStatus {
  resolved,
  no_occurrence,
  invalid_schedule,
  invalid_rules,
  out_of_range,
};

struct ResolvedOccurrence {
  OccurrenceResolutionStatus status{OccurrenceResolutionStatus::no_occurrence};
  std::int64_t scheduled_utc_seconds{};
  CivilDate local_date;
  std::uint8_t resolved_local_hour{};
  std::uint8_t resolved_local_minute{};
  std::int32_t utc_offset_seconds{};
  bool shifted_for_gap{};
  bool ambiguous_fold{};
};

// Returns the first scheduled occurrence strictly after after_utc_seconds.
// Rules are supplied by the caller (see dawn/tzif_rules.hpp for the pinned
// TZif-to-rules adapter); this pure component performs no network,
// filesystem, or platform timezone lookup.
[[nodiscard]] ResolvedOccurrence
resolve_next_occurrence(const WeeklyAlarmSchedule &schedule,
                        const TimezoneRules &rules,
                        std::int64_t after_utc_seconds);

} // namespace dawn
