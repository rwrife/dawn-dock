#include "dawn/recurrence_resolver.hpp"

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string_view>

namespace {

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

void new_york_spring_gap_shifts_to_earliest_valid_local_instant() {
  const dawn::TimezoneRules rules{
      .name = "America/New_York",
      .version = "2026a",
      .initial_utc_offset_seconds = -5 * 60 * 60,
      .transitions = {{.at_utc_seconds = utc_seconds(2026, 3, 8, 7),
                       .offset_before_seconds = -5 * 60 * 60,
                       .offset_after_seconds = -4 * 60 * 60}},
  };
  const dawn::WeeklyAlarmSchedule alarm{
      .local_hour = 2,
      .local_minute = 30,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::sunday),
      .timezone_name = "America/New_York",
      .timezone_rules_version = "2026a",
  };

  const auto result =
      dawn::resolve_next_occurrence(alarm, rules, utc_seconds(2026, 3, 8, 0));

  expect(result.status == dawn::OccurrenceResolutionStatus::resolved,
         "spring-gap occurrence resolves");
  expect(result.scheduled_utc_seconds == utc_seconds(2026, 3, 8, 7),
         "nonexistent 02:30 shifts to 03:00 EDT / 07:00 UTC");
  expect(result.local_date ==
             dawn::CivilDate{.year = 2026, .month = 3, .day = 8},
         "shift retains the requested local calendar date");
  expect(result.resolved_local_hour == 3 && result.resolved_local_minute == 0,
         "receipt exposes the earliest valid local time after the gap");
  expect(result.shifted_for_gap, "receipt marks spring-gap shift");
  expect(!result.ambiguous_fold, "spring-gap occurrence is not a fold");
}

void new_york_fall_fold_selects_first_occurrence_and_reports_ambiguity() {
  const dawn::TimezoneRules rules{
      .name = "America/New_York",
      .version = "2026a",
      .initial_utc_offset_seconds = -4 * 60 * 60,
      .transitions = {{.at_utc_seconds = utc_seconds(2026, 11, 1, 6),
                       .offset_before_seconds = -4 * 60 * 60,
                       .offset_after_seconds = -5 * 60 * 60}},
  };
  const dawn::WeeklyAlarmSchedule alarm{
      .local_hour = 1,
      .local_minute = 30,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::sunday),
      .timezone_name = "America/New_York",
      .timezone_rules_version = "2026a",
  };

  const auto result =
      dawn::resolve_next_occurrence(alarm, rules, utc_seconds(2026, 11, 1, 0));

  expect(result.status == dawn::OccurrenceResolutionStatus::resolved,
         "fall-fold occurrence resolves");
  expect(result.scheduled_utc_seconds == utc_seconds(2026, 11, 1, 5, 30),
         "ambiguous 01:30 selects the first EDT occurrence");
  expect(result.utc_offset_seconds == -4 * 60 * 60,
         "first fold occurrence retains the pre-transition offset");
  expect(result.ambiguous_fold, "receipt exposes fall-fold ambiguity");
  expect(!result.shifted_for_gap, "fall-fold occurrence is not gap-shifted");
}

void timezone_name_and_rule_version_must_match_supplied_rules() {
  const dawn::TimezoneRules rules{
      .name = "Europe/Berlin",
      .version = "2026b",
      .initial_utc_offset_seconds = 60 * 60,
      .transitions = {},
  };
  const dawn::WeeklyAlarmSchedule alarm{
      .local_hour = 7,
      .local_minute = 0,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::monday),
      .timezone_name = "America/New_York",
      .timezone_rules_version = "2026a",
  };

  const auto result =
      dawn::resolve_next_occurrence(alarm, rules, utc_seconds(2026, 1, 1, 0));

  expect(result.status == dawn::OccurrenceResolutionStatus::invalid_rules,
         "mismatched timezone provenance fails closed");
}

void invalid_local_time_and_weekday_masks_are_rejected() {
  const dawn::TimezoneRules rules{
      .name = "Etc/UTC",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {},
  };
  const dawn::WeeklyAlarmSchedule valid{
      .local_hour = 7,
      .local_minute = 30,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::monday),
      .timezone_name = "Etc/UTC",
      .timezone_rules_version = "2026a",
  };

  for (const auto &alarm : {
           dawn::WeeklyAlarmSchedule{
               valid.local_hour, 60, valid.iso_weekday_mask,
               valid.timezone_name, valid.timezone_rules_version},
           dawn::WeeklyAlarmSchedule{
               24, valid.local_minute, valid.iso_weekday_mask,
               valid.timezone_name, valid.timezone_rules_version},
           dawn::WeeklyAlarmSchedule{valid.local_hour, valid.local_minute, 0,
                                     valid.timezone_name,
                                     valid.timezone_rules_version},
           dawn::WeeklyAlarmSchedule{valid.local_hour, valid.local_minute,
                                     static_cast<std::uint8_t>(0x80U),
                                     valid.timezone_name,
                                     valid.timezone_rules_version},
       }) {
    const auto result =
        dawn::resolve_next_occurrence(alarm, rules, utc_seconds(2026, 1, 1, 0));
    expect(result.status == dawn::OccurrenceResolutionStatus::invalid_schedule,
           "malformed weekly schedule fails closed");
  }
}

void malformed_transition_chains_are_rejected() {
  const dawn::WeeklyAlarmSchedule alarm{
      .local_hour = 7,
      .local_minute = 0,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::monday),
      .timezone_name = "Test/Zone",
      .timezone_rules_version = "2026a",
  };
  const dawn::TimezoneRules discontinuous{
      .name = "Test/Zone",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {{.at_utc_seconds = utc_seconds(2026, 3, 1, 0),
                       .offset_before_seconds = 60 * 60,
                       .offset_after_seconds = 2 * 60 * 60}},
  };
  const dawn::TimezoneRules unordered{
      .name = "Test/Zone",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {{.at_utc_seconds = utc_seconds(2026, 10, 1, 0),
                       .offset_before_seconds = 0,
                       .offset_after_seconds = 60 * 60},
                      {.at_utc_seconds = utc_seconds(2026, 3, 1, 0),
                       .offset_before_seconds = 60 * 60,
                       .offset_after_seconds = 0}},
  };
  const dawn::TimezoneRules absurd_offset{
      .name = "Test/Zone",
      .version = "2026a",
      .initial_utc_offset_seconds = 25 * 60 * 60,
      .transitions = {},
  };
  const dawn::TimezoneRules overflowing_transition{
      .name = "Test/Zone",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {{.at_utc_seconds =
                           std::numeric_limits<std::int64_t>::max(),
                       .offset_before_seconds = 0,
                       .offset_after_seconds = 60 * 60}},
  };

  for (const auto &rules :
       {discontinuous, unordered, absurd_offset, overflowing_transition}) {
    const auto result =
        dawn::resolve_next_occurrence(alarm, rules, utc_seconds(2026, 1, 1, 0));
    expect(result.status == dawn::OccurrenceResolutionStatus::invalid_rules,
           "malformed transition chain fails closed");
  }
}

void berlin_gap_and_fold_follow_the_same_v1_policy() {
  const dawn::TimezoneRules rules{
      .name = "Europe/Berlin",
      .version = "2026a",
      .initial_utc_offset_seconds = 60 * 60,
      .transitions = {{.at_utc_seconds = utc_seconds(2026, 3, 29, 1),
                       .offset_before_seconds = 60 * 60,
                       .offset_after_seconds = 2 * 60 * 60},
                      {.at_utc_seconds = utc_seconds(2026, 10, 25, 1),
                       .offset_before_seconds = 2 * 60 * 60,
                       .offset_after_seconds = 60 * 60}},
  };
  const auto alarm = dawn::WeeklyAlarmSchedule{
      .local_hour = 2,
      .local_minute = 30,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::sunday),
      .timezone_name = "Europe/Berlin",
      .timezone_rules_version = "2026a",
  };

  const auto gap =
      dawn::resolve_next_occurrence(alarm, rules, utc_seconds(2026, 3, 29, 0));
  expect(gap.status == dawn::OccurrenceResolutionStatus::resolved &&
             gap.scheduled_utc_seconds == utc_seconds(2026, 3, 29, 1),
         "Berlin spring gap shifts 02:30 to 03:00 CEST / 01:00 UTC");
  expect(gap.shifted_for_gap && gap.resolved_local_hour == 3 &&
             gap.resolved_local_minute == 0,
         "Berlin gap receipt records the local shift");

  const auto fold =
      dawn::resolve_next_occurrence(alarm, rules, utc_seconds(2026, 10, 25, 0));
  expect(fold.status == dawn::OccurrenceResolutionStatus::resolved &&
             fold.scheduled_utc_seconds == utc_seconds(2026, 10, 25, 0, 30),
         "Berlin fold selects first 02:30 occurrence at 00:30 UTC");
  expect(fold.ambiguous_fold && fold.utc_offset_seconds == 2 * 60 * 60,
         "Berlin fold receipt records ambiguity and first offset");
}

void recurrence_uses_local_weekday_and_crosses_year_boundary() {
  const dawn::TimezoneRules tokyo{
      .name = "Asia/Tokyo",
      .version = "2026a",
      .initial_utc_offset_seconds = 9 * 60 * 60,
      .transitions = {},
  };
  const dawn::WeeklyAlarmSchedule monday{
      .local_hour = 0,
      .local_minute = 30,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::monday),
      .timezone_name = "Asia/Tokyo",
      .timezone_rules_version = "2026a",
  };
  const auto local_monday = dawn::resolve_next_occurrence(
      monday, tokyo, utc_seconds(2026, 12, 27, 15));
  expect(local_monday.status == dawn::OccurrenceResolutionStatus::resolved &&
             local_monday.scheduled_utc_seconds ==
                 utc_seconds(2026, 12, 27, 15, 30),
         "Monday recurrence is selected from Tokyo local calendar Sunday UTC");
  expect(local_monday.local_date ==
             dawn::CivilDate{.year = 2026, .month = 12, .day = 28},
         "receipt reports Monday local date");

  const dawn::TimezoneRules utc{
      .name = "Etc/UTC",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {},
  };
  const dawn::WeeklyAlarmSchedule daily{
      .local_hour = 0,
      .local_minute = 0,
      .iso_weekday_mask = 0x7fU,
      .timezone_name = "Etc/UTC",
      .timezone_rules_version = "2026a",
  };
  const auto next_year = dawn::resolve_next_occurrence(
      daily, utc, utc_seconds(2026, 12, 31, 23, 59));
  expect(next_year.status == dawn::OccurrenceResolutionStatus::resolved &&
             next_year.scheduled_utc_seconds == utc_seconds(2027, 1, 1, 0),
         "daily recurrence crosses month and year boundary");
  expect(next_year.local_date ==
             dawn::CivilDate{.year = 2027, .month = 1, .day = 1},
         "year-boundary receipt preserves next local date");
}

void second_fold_instant_is_never_selected_for_v1_alarm() {
  const dawn::TimezoneRules rules{
      .name = "America/New_York",
      .version = "2026a",
      .initial_utc_offset_seconds = -4 * 60 * 60,
      .transitions = {{.at_utc_seconds = utc_seconds(2026, 11, 1, 6),
                       .offset_before_seconds = -4 * 60 * 60,
                       .offset_after_seconds = -5 * 60 * 60}},
  };
  const dawn::WeeklyAlarmSchedule alarm{
      .local_hour = 1,
      .local_minute = 30,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::sunday),
      .timezone_name = "America/New_York",
      .timezone_rules_version = "2026a",
  };

  const auto next = dawn::resolve_next_occurrence(
      alarm, rules, utc_seconds(2026, 11, 1, 5, 45));
  expect(
      next.status == dawn::OccurrenceResolutionStatus::resolved &&
          next.scheduled_utc_seconds == utc_seconds(2026, 11, 8, 6, 30),
      "after first fold instant resolver advances a week, not to second fold");
}

void maximum_utc_anchor_returns_out_of_range_without_overflow() {
  const dawn::TimezoneRules rules{
      .name = "Etc/UTC",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {},
  };
  const dawn::WeeklyAlarmSchedule alarm{
      .local_hour = 0,
      .local_minute = 0,
      .iso_weekday_mask = 0x7fU,
      .timezone_name = "Etc/UTC",
      .timezone_rules_version = "2026a",
  };

  const auto result = dawn::resolve_next_occurrence(
      alarm, rules, std::numeric_limits<std::int64_t>::max());

  expect(result.status == dawn::OccurrenceResolutionStatus::out_of_range,
         "maximum UTC anchor cannot have a representable later occurrence");

  const auto minimum = dawn::resolve_next_occurrence(
      alarm, rules, std::numeric_limits<std::int64_t>::min());
  expect(minimum.status == dawn::OccurrenceResolutionStatus::out_of_range,
         "unrepresentable minimum-epoch local day fails without overflow");
}

void local_to_utc_overflow_and_civil_year_narrowing_fail_closed() {
  const dawn::WeeklyAlarmSchedule daily{
      .local_hour = 0,
      .local_minute = 0,
      .iso_weekday_mask = 0x7fU,
      .timezone_name = "Test/Fixed",
      .timezone_rules_version = "2026a",
  };
  const dawn::TimezoneRules west{
      .name = "Test/Fixed",
      .version = "2026a",
      .initial_utc_offset_seconds = -24 * 60 * 60,
      .transitions = {},
  };
  const auto utc_overflow = dawn::resolve_next_occurrence(
      daily, west, std::numeric_limits<std::int64_t>::max() - 1);
  expect(utc_overflow.status == dawn::OccurrenceResolutionStatus::out_of_range,
         "local candidate beyond maximum UTC fails closed");

  auto utc_daily = daily;
  utc_daily.timezone_name = "Etc/UTC";
  const dawn::TimezoneRules utc{
      .name = "Etc/UTC",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {},
  };
  const auto civil_year_overflow = dawn::resolve_next_occurrence(
      utc_daily, utc, 1'000'000'000'000'000'000LL);
  expect(civil_year_overflow.status ==
             dawn::OccurrenceResolutionStatus::out_of_range,
         "civil year outside public int range fails closed");
}

void fully_skipped_local_date_advances_to_next_matching_weekday() {
  const dawn::TimezoneRules apia{
      .name = "Pacific/Apia",
      .version = "2026a",
      .initial_utc_offset_seconds = -10 * 60 * 60,
      .transitions = {{.at_utc_seconds = utc_seconds(2011, 12, 30, 10),
                       .offset_before_seconds = -10 * 60 * 60,
                       .offset_after_seconds = 14 * 60 * 60}},
  };
  const dawn::WeeklyAlarmSchedule friday{
      .local_hour = 7,
      .local_minute = 0,
      .iso_weekday_mask = dawn::weekday_bit(dawn::IsoWeekday::friday),
      .timezone_name = "Pacific/Apia",
      .timezone_rules_version = "2026a",
  };

  const auto result =
      dawn::resolve_next_occurrence(friday, apia, utc_seconds(2011, 12, 29, 0));

  expect(result.status == dawn::OccurrenceResolutionStatus::resolved &&
             result.scheduled_utc_seconds == utc_seconds(2012, 1, 5, 17),
         "skipped Friday advances to next Friday 07:00 local");
  expect(result.local_date ==
             dawn::CivilDate{.year = 2012, .month = 1, .day = 6},
         "receipt never labels a shifted instant as the absent local date");
  expect(!result.shifted_for_gap,
         "next-week occurrence is ordinary, not a cross-date gap shift");
}

} // namespace

int main() {
  new_york_spring_gap_shifts_to_earliest_valid_local_instant();
  new_york_fall_fold_selects_first_occurrence_and_reports_ambiguity();
  timezone_name_and_rule_version_must_match_supplied_rules();
  invalid_local_time_and_weekday_masks_are_rejected();
  malformed_transition_chains_are_rejected();
  berlin_gap_and_fold_follow_the_same_v1_policy();
  recurrence_uses_local_weekday_and_crosses_year_boundary();
  second_fold_instant_is_never_selected_for_v1_alarm();
  maximum_utc_anchor_returns_out_of_range_without_overflow();
  local_to_utc_overflow_and_civil_year_narrowing_fail_closed();
  fully_skipped_local_date_advances_to_next_matching_weekday();

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "recurrence_resolver_tests: PASS\n";
  return EXIT_SUCCESS;
}
