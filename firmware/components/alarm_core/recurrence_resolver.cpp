#include "dawn/recurrence_resolver.hpp"

#include <algorithm>
#include <limits>
#include <optional>

namespace dawn {
namespace {

constexpr std::int64_t kSecondsPerDay = 24 * 60 * 60;
constexpr std::uint8_t kAllIsoWeekdays = 0x7fU;

constexpr bool valid_utc_offset(std::int32_t offset) noexcept {
  return offset >= -kSecondsPerDay && offset <= kSecondsPerDay;
}

constexpr bool can_add(std::int64_t value, std::int32_t offset) noexcept {
  return (offset >= 0 &&
          value <= std::numeric_limits<std::int64_t>::max() - offset) ||
         (offset < 0 &&
          value >= std::numeric_limits<std::int64_t>::min() - offset);
}

constexpr std::optional<CivilDate> civil_from_days(std::int64_t days) noexcept {
  days += 719468;
  const auto era = (days >= 0 ? days : days - 146096) / 146097;
  const auto day_of_era =
      static_cast<unsigned>(days - era * 146097); // [0, 146096]
  const auto year_of_era = (day_of_era - day_of_era / 1460U +
                            day_of_era / 36524U - day_of_era / 146096U) /
                           365U;
  auto year = static_cast<std::int64_t>(year_of_era) + era * 400;
  const auto day_of_year =
      day_of_era - (365U * year_of_era + year_of_era / 4U - year_of_era / 100U);
  const auto month_prime = (5U * day_of_year + 2U) / 153U;
  const auto day = day_of_year - (153U * month_prime + 2U) / 5U + 1U;
  const auto month = month_prime < 10U ? month_prime + 3U : month_prime - 9U;
  year += month <= 2U;
  if (year < std::numeric_limits<int>::min() ||
      year > std::numeric_limits<int>::max()) {
    return std::nullopt;
  }
  return CivilDate{.year = static_cast<int>(year), .month = month, .day = day};
}

constexpr std::int64_t floor_div(std::int64_t numerator,
                                 std::int64_t denominator) noexcept {
  const auto quotient = numerator / denominator;
  const auto remainder = numerator % denominator;
  return remainder < 0 ? quotient - 1 : quotient;
}

constexpr IsoWeekday weekday_from_days(std::int64_t days) noexcept {
  // 1970-01-01 was Thursday (ISO weekday index 3).
  auto index = (days + 3) % 7;
  if (index < 0) {
    index += 7;
  }
  return static_cast<IsoWeekday>(index);
}

std::optional<std::int64_t> start_of_day_seconds(std::int64_t day) {
  if (day > std::numeric_limits<std::int64_t>::max() / kSecondsPerDay ||
      day < std::numeric_limits<std::int64_t>::min() / kSecondsPerDay) {
    return std::nullopt;
  }
  return day * kSecondsPerDay;
}

std::int32_t offset_at_utc(const TimezoneRules &rules,
                           std::int64_t utc_seconds) {
  auto offset = rules.initial_utc_offset_seconds;
  for (const auto &transition : rules.transitions) {
    if (utc_seconds < transition.at_utc_seconds) {
      break;
    }
    offset = transition.offset_after_seconds;
  }
  return offset;
}

bool has_valid_transition_chain(const TimezoneRules &rules) {
  auto active_offset = rules.initial_utc_offset_seconds;
  if (!valid_utc_offset(active_offset)) {
    return false;
  }
  std::optional<std::int64_t> previous_transition;
  for (const auto &transition : rules.transitions) {
    if ((previous_transition &&
         transition.at_utc_seconds <= *previous_transition) ||
        transition.offset_before_seconds != active_offset ||
        !valid_utc_offset(transition.offset_before_seconds) ||
        !valid_utc_offset(transition.offset_after_seconds) ||
        !can_add(transition.at_utc_seconds, transition.offset_before_seconds) ||
        !can_add(transition.at_utc_seconds, transition.offset_after_seconds) ||
        transition.offset_before_seconds == transition.offset_after_seconds) {
      return false;
    }
    previous_transition = transition.at_utc_seconds;
    active_offset = transition.offset_after_seconds;
  }
  return true;
}

struct LocalMapping {
  std::int64_t utc_seconds{};
  std::int64_t resolved_local_seconds{};
  std::int32_t offset_seconds{};
  bool shifted_for_gap{};
  bool ambiguous_fold{};
};

std::optional<LocalMapping> map_local(const TimezoneRules &rules,
                                      std::int64_t local_seconds) {
  for (const auto &transition : rules.transitions) {
    if (transition.offset_after_seconds <= transition.offset_before_seconds) {
      continue;
    }
    const auto gap_start =
        transition.at_utc_seconds + transition.offset_before_seconds;
    const auto gap_end =
        transition.at_utc_seconds + transition.offset_after_seconds;
    if (local_seconds >= gap_start && local_seconds < gap_end) {
      return LocalMapping{.utc_seconds = transition.at_utc_seconds,
                          .resolved_local_seconds = gap_end,
                          .offset_seconds = transition.offset_after_seconds,
                          .shifted_for_gap = true,
                          .ambiguous_fold = false};
    }
  }

  std::vector<std::int32_t> offsets;
  offsets.reserve(rules.transitions.size() + 1U);
  const auto add_offset = [&](std::int32_t offset) {
    if (std::find(offsets.begin(), offsets.end(), offset) == offsets.end()) {
      offsets.push_back(offset);
    }
  };
  add_offset(rules.initial_utc_offset_seconds);
  for (const auto &transition : rules.transitions) {
    add_offset(transition.offset_after_seconds);
  }

  std::optional<LocalMapping> earliest;
  std::size_t valid_mapping_count = 0;
  for (const auto offset : offsets) {
    const auto inverse_offset = static_cast<std::int32_t>(-offset);
    if (!can_add(local_seconds, inverse_offset)) {
      continue;
    }
    const auto candidate_utc = local_seconds + inverse_offset;
    if (offset_at_utc(rules, candidate_utc) != offset) {
      continue;
    }
    ++valid_mapping_count;
    if (!earliest || candidate_utc < earliest->utc_seconds) {
      earliest = LocalMapping{.utc_seconds = candidate_utc,
                              .resolved_local_seconds = local_seconds,
                              .offset_seconds = offset,
                              .shifted_for_gap = false,
                              .ambiguous_fold = false};
    }
  }
  if (earliest) {
    earliest->ambiguous_fold = valid_mapping_count > 1U;
  }
  return earliest;
}

} // namespace

ResolvedOccurrence resolve_next_occurrence(const WeeklyAlarmSchedule &schedule,
                                           const TimezoneRules &rules,
                                           std::int64_t after_utc_seconds) {
  if (schedule.local_hour > 23U || schedule.local_minute > 59U ||
      schedule.iso_weekday_mask == 0U ||
      (schedule.iso_weekday_mask & ~kAllIsoWeekdays) != 0U) {
    ResolvedOccurrence result;
    result.status = OccurrenceResolutionStatus::invalid_schedule;
    return result;
  }
  if (schedule.timezone_name.empty() ||
      schedule.timezone_rules_version.empty() || rules.name.empty() ||
      rules.version.empty() || schedule.timezone_name != rules.name ||
      schedule.timezone_rules_version != rules.version ||
      !has_valid_transition_chain(rules)) {
    ResolvedOccurrence result;
    result.status = OccurrenceResolutionStatus::invalid_rules;
    return result;
  }
  if (after_utc_seconds == std::numeric_limits<std::int64_t>::max()) {
    ResolvedOccurrence result;
    result.status = OccurrenceResolutionStatus::out_of_range;
    return result;
  }
  const auto anchor_offset = offset_at_utc(rules, after_utc_seconds);
  if ((anchor_offset > 0 &&
       after_utc_seconds >
           std::numeric_limits<std::int64_t>::max() - anchor_offset) ||
      (anchor_offset < 0 &&
       after_utc_seconds <
           std::numeric_limits<std::int64_t>::min() - anchor_offset)) {
    ResolvedOccurrence result;
    result.status = OccurrenceResolutionStatus::out_of_range;
    return result;
  }
  const auto anchor_local_seconds = after_utc_seconds + anchor_offset;
  const auto anchor_day = floor_div(anchor_local_seconds, kSecondsPerDay);

  for (std::int64_t day_delta = 0; day_delta <= 14; ++day_delta) {
    const auto candidate_day = anchor_day + day_delta;
    const auto weekday = weekday_from_days(candidate_day);
    if ((schedule.iso_weekday_mask & weekday_bit(weekday)) == 0U) {
      continue;
    }
    const auto day_start = start_of_day_seconds(candidate_day);
    const auto seconds_in_requested_day =
        static_cast<std::int64_t>(schedule.local_hour) * 60 * 60 +
        static_cast<std::int64_t>(schedule.local_minute) * 60;
    if (!day_start || *day_start > std::numeric_limits<std::int64_t>::max() -
                                       seconds_in_requested_day) {
      ResolvedOccurrence result;
      result.status = OccurrenceResolutionStatus::out_of_range;
      return result;
    }
    const auto local_seconds = *day_start + seconds_in_requested_day;
    const auto mapping = map_local(rules, local_seconds);
    if (!mapping || mapping->utc_seconds <= after_utc_seconds) {
      continue;
    }
    const auto resolved_day =
        floor_div(mapping->resolved_local_seconds, kSecondsPerDay);
    if (mapping->shifted_for_gap && resolved_day != candidate_day) {
      continue;
    }
    const auto seconds_in_day =
        mapping->resolved_local_seconds - resolved_day * kSecondsPerDay;
    const auto local_date = civil_from_days(candidate_day);
    if (!local_date) {
      ResolvedOccurrence result;
      result.status = OccurrenceResolutionStatus::out_of_range;
      return result;
    }
    return {
        .status = OccurrenceResolutionStatus::resolved,
        .scheduled_utc_seconds = mapping->utc_seconds,
        .local_date = *local_date,
        .resolved_local_hour =
            static_cast<std::uint8_t>(seconds_in_day / (60 * 60)),
        .resolved_local_minute =
            static_cast<std::uint8_t>((seconds_in_day / 60) % 60),
        .utc_offset_seconds = mapping->offset_seconds,
        .shifted_for_gap = mapping->shifted_for_gap,
        .ambiguous_fold = mapping->ambiguous_fold,
    };
  }
  ResolvedOccurrence result;
  result.status = OccurrenceResolutionStatus::no_occurrence;
  return result;
}

} // namespace dawn
