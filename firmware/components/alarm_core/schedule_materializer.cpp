#include "dawn/schedule_materializer.hpp"

#include <algorithm>

namespace dawn {
namespace {

MaterializationStatus map_status(OccurrenceResolutionStatus status) {
  switch (status) {
    case OccurrenceResolutionStatus::invalid_schedule:
      return MaterializationStatus::invalid_schedule;
    case OccurrenceResolutionStatus::invalid_rules:
      return MaterializationStatus::invalid_rules;
    case OccurrenceResolutionStatus::out_of_range:
      return MaterializationStatus::out_of_range;
    case OccurrenceResolutionStatus::no_occurrence:
      return MaterializationStatus::invalid_schedule;
    case OccurrenceResolutionStatus::resolved:
      return MaterializationStatus::materialized;
  }
  return MaterializationStatus::invalid_schedule;
}

const TimezoneRules *find_matching_rules(std::span<const TimezoneRules> rules,
                                         const WeeklyAlarmSchedule &schedule) {
  for (const auto &candidate : rules) {
    if (candidate.name == schedule.timezone_name &&
        candidate.version == schedule.timezone_rules_version) {
      return &candidate;
    }
  }
  return nullptr;
}

bool valid_alarm_definition(const WeeklyAlarmDefinition &alarm) {
  return !alarm.id.empty() && alarm.schedule_revision != 0;
}

} // namespace

MaterializationResult materialize_next_schedule_entries(
    std::span<const WeeklyAlarmDefinition> alarms,
    std::span<const TimezoneRules> timezone_rules,
    std::int64_t after_utc_seconds) {
  MaterializationResult result;
  result.alarms.reserve(alarms.size());

  for (const auto &alarm : alarms) {
    if (!valid_alarm_definition(alarm)) {
      result.status = MaterializationStatus::invalid_input;
      result.failures.push_back(
          {.alarm_id = alarm.id,
           .resolver_status = OccurrenceResolutionStatus::invalid_schedule});
      continue;
    }

    if (!alarm.enabled) {
      result.alarms.push_back({
          .stored_alarm = StoredAlarmDefinition{.id = alarm.id,
                                                .schedule_revision =
                                                    alarm.schedule_revision,
                                                .enabled = false,
                                                .scheduled_utc_seconds = 0},
          .local_date = CivilDate{.year = 0, .month = 0, .day = 0},
          .resolved_local_hour = 0,
          .resolved_local_minute = 0,
          .utc_offset_seconds = 0,
          .shifted_for_gap = false,
          .ambiguous_fold = false,
      });
      continue;
    }

    const auto *rules = find_matching_rules(timezone_rules, alarm.schedule);
    if (rules == nullptr) {
      result.status = MaterializationStatus::missing_timezone_rules;
      result.failures.push_back(
          {.alarm_id = alarm.id,
           .resolver_status = OccurrenceResolutionStatus::invalid_rules});
      continue;
    }

    const auto occurrence =
        resolve_next_occurrence(alarm.schedule, *rules, after_utc_seconds);
    if (occurrence.status != OccurrenceResolutionStatus::resolved) {
      result.status = map_status(occurrence.status);
      result.failures.push_back(
          {.alarm_id = alarm.id, .resolver_status = occurrence.status});
      continue;
    }

    result.alarms.push_back({
        .stored_alarm =
            StoredAlarmDefinition{.id = alarm.id,
                                  .schedule_revision = alarm.schedule_revision,
                                  .enabled = true,
                                  .scheduled_utc_seconds =
                                      occurrence.scheduled_utc_seconds},
        .local_date = occurrence.local_date,
        .resolved_local_hour = occurrence.resolved_local_hour,
        .resolved_local_minute = occurrence.resolved_local_minute,
        .utc_offset_seconds = occurrence.utc_offset_seconds,
        .shifted_for_gap = occurrence.shifted_for_gap,
        .ambiguous_fold = occurrence.ambiguous_fold,
    });
  }

  if (!result.failures.empty()) {
    result.alarms.clear();
    return result;
  }

  std::sort(result.alarms.begin(), result.alarms.end(),
            [](const MaterializedAlarm &left, const MaterializedAlarm &right) {
              if (left.stored_alarm.scheduled_utc_seconds !=
                  right.stored_alarm.scheduled_utc_seconds) {
                return left.stored_alarm.scheduled_utc_seconds <
                       right.stored_alarm.scheduled_utc_seconds;
              }
              return left.stored_alarm.id < right.stored_alarm.id;
            });

  return result;
}

} // namespace dawn
