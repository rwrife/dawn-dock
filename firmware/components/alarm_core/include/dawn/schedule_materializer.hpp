#pragma once

#include "dawn/recurrence_resolver.hpp"
#include "dawn/schedule_store.hpp"

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace dawn {

struct WeeklyAlarmDefinition {
  std::string id;
  std::uint64_t schedule_revision{};
  bool enabled{};
  WeeklyAlarmSchedule schedule;
};

enum class MaterializationStatus {
  materialized,
  invalid_input,
  missing_timezone_rules,
  invalid_rules,
  invalid_schedule,
  out_of_range,
};

struct MaterializedAlarm {
  StoredAlarmDefinition stored_alarm;
  CivilDate local_date;
  std::uint8_t resolved_local_hour{};
  std::uint8_t resolved_local_minute{};
  std::int32_t utc_offset_seconds{};
  bool shifted_for_gap{};
  bool ambiguous_fold{};
};

struct MaterializationFailure {
  std::string alarm_id;
  OccurrenceResolutionStatus resolver_status{
      OccurrenceResolutionStatus::no_occurrence};
};

struct MaterializationResult {
  MaterializationStatus status{MaterializationStatus::materialized};
  std::vector<MaterializedAlarm> alarms;
  std::vector<MaterializationFailure> failures;
};

[[nodiscard]] MaterializationResult materialize_next_schedule_entries(
    std::span<const WeeklyAlarmDefinition> alarms,
    std::span<const TimezoneRules> timezone_rules,
    std::int64_t after_utc_seconds);

} // namespace dawn
