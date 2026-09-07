#include "dawn/committed_schedule_evaluator.hpp"
#include "dawn/schedule_materializer.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

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
  const auto instant =
      sys_days{year_month_day{std::chrono::year{year}, std::chrono::month{month},
                              std::chrono::day{day}}} +
      hours{hour} + minutes{minute};
  return duration_cast<seconds>(instant.time_since_epoch()).count();
}

class MemorySlotStorage final : public dawn::SlotStorage {
 public:
  bool begin_transaction() override {
    if (transaction_open) {
      return false;
    }
    transaction_open = true;
    return true;
  }

  void end_transaction() override { transaction_open = false; }

  [[nodiscard]] dawn::SlotReadResult read(dawn::StorageSlot slot) const override {
    const auto &record = slots[index(slot)];
    if (!record) {
      return {.status = dawn::SlotReadStatus::empty, .bytes = {}};
    }
    return {.status = dawn::SlotReadStatus::present, .bytes = *record};
  }

  bool write(dawn::StorageSlot slot, std::span<const std::byte> bytes) override {
    if (!transaction_open) {
      return false;
    }
    slots[index(slot)] = std::vector<std::byte>(bytes.begin(), bytes.end());
    ++write_count;
    return true;
  }

  int write_count{};

 private:
  static constexpr std::size_t index(dawn::StorageSlot slot) {
    return slot == dawn::StorageSlot::a ? 0U : 1U;
  }

  bool transaction_open{};
  std::array<std::optional<std::vector<std::byte>>, 2> slots;
};

void successful_materialization_orders_by_utc_then_alarm_id() {
  const dawn::TimezoneRules utc{
      .name = "Etc/UTC",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {},
  };
  const std::array alarms{
      dawn::WeeklyAlarmDefinition{
          .id = "later",
          .schedule_revision = 7,
          .enabled = true,
          .schedule = dawn::WeeklyAlarmSchedule{.local_hour = 7,
                                                .local_minute = 0,
                                                .iso_weekday_mask = 0x7fU,
                                                .timezone_name = "Etc/UTC",
                                                .timezone_rules_version =
                                                    "2026a"}},
      dawn::WeeklyAlarmDefinition{
          .id = "earlier",
          .schedule_revision = 7,
          .enabled = true,
          .schedule = dawn::WeeklyAlarmSchedule{.local_hour = 6,
                                                .local_minute = 30,
                                                .iso_weekday_mask = 0x7fU,
                                                .timezone_name = "Etc/UTC",
                                                .timezone_rules_version =
                                                    "2026a"}},
  };

  const auto result = dawn::materialize_next_schedule_entries(
      alarms, std::span<const dawn::TimezoneRules>(&utc, 1),
      utc_seconds(2026, 1, 1, 0));

  expect(result.status == dawn::MaterializationStatus::materialized,
         "materialization succeeds with valid rules");
  expect(result.failures.empty() && result.alarms.size() == 2,
         "materialization returns both alarms and no failures");
  expect(result.alarms[0].stored_alarm.id == "earlier" &&
             result.alarms[1].stored_alarm.id == "later",
         "alarms are ordered by UTC instant then alarm id");
}

void disabled_alarms_materialize_without_rule_lookup() {
  const dawn::TimezoneRules utc{
      .name = "Etc/UTC",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {},
  };
  const std::array alarms{
      dawn::WeeklyAlarmDefinition{
          .id = "disabled",
          .schedule_revision = 9,
          .enabled = false,
          .schedule = dawn::WeeklyAlarmSchedule{.local_hour = 7,
                                                .local_minute = 0,
                                                .iso_weekday_mask = 0x7fU,
                                                .timezone_name = "Missing/Zone",
                                                .timezone_rules_version =
                                                    "never"}},
  };

  const auto result = dawn::materialize_next_schedule_entries(
      alarms, std::span<const dawn::TimezoneRules>(&utc, 1),
      utc_seconds(2026, 1, 1, 0));

  expect(result.status == dawn::MaterializationStatus::materialized,
         "disabled alarm materialization succeeds");
  expect(result.alarms.size() == 1 && !result.alarms[0].stored_alarm.enabled &&
             result.alarms[0].stored_alarm.scheduled_utc_seconds == 0,
         "disabled alarms keep deterministic disabled schedule entries");
}

void missing_timezone_rules_fail_closed() {
  const dawn::TimezoneRules utc{
      .name = "Etc/UTC",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {},
  };
  const std::array alarms{
      dawn::WeeklyAlarmDefinition{
          .id = "wake",
          .schedule_revision = 1,
          .enabled = true,
          .schedule = dawn::WeeklyAlarmSchedule{.local_hour = 7,
                                                .local_minute = 0,
                                                .iso_weekday_mask = 0x7fU,
                                                .timezone_name =
                                                    "America/New_York",
                                                .timezone_rules_version =
                                                    "2026a"}},
  };

  const auto result = dawn::materialize_next_schedule_entries(
      alarms, std::span<const dawn::TimezoneRules>(&utc, 1),
      utc_seconds(2026, 1, 1, 0));

  expect(result.status == dawn::MaterializationStatus::missing_timezone_rules,
         "missing timezone rule set fails closed");
  expect(result.alarms.empty() && result.failures.size() == 1,
         "fail-closed result emits no partial alarm list");
}

void invalid_transition_chain_fails_closed() {
  const dawn::TimezoneRules malformed{
      .name = "Test/Zone",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {{.at_utc_seconds = utc_seconds(2026, 3, 1, 0),
                       .offset_before_seconds = 60 * 60,
                       .offset_after_seconds = 2 * 60 * 60}},
  };
  const std::array alarms{
      dawn::WeeklyAlarmDefinition{
          .id = "wake",
          .schedule_revision = 1,
          .enabled = true,
          .schedule = dawn::WeeklyAlarmSchedule{.local_hour = 7,
                                                .local_minute = 0,
                                                .iso_weekday_mask = 0x7fU,
                                                .timezone_name = "Test/Zone",
                                                .timezone_rules_version =
                                                    "2026a"}},
  };

  const auto result = dawn::materialize_next_schedule_entries(
      alarms, std::span<const dawn::TimezoneRules>(&malformed, 1),
      utc_seconds(2026, 1, 1, 0));

  expect(result.status == dawn::MaterializationStatus::invalid_rules,
         "invalid transition chain fails closed");
  expect(result.alarms.empty() && result.failures.size() == 1 &&
             result.failures[0].resolver_status ==
                 dawn::OccurrenceResolutionStatus::invalid_rules,
         "failure exposes invalid-rules resolver status");
}

void spring_gap_and_fall_fold_flags_propagate_to_materialized_entries() {
  const dawn::TimezoneRules rules{
      .name = "America/New_York",
      .version = "2026a",
      .initial_utc_offset_seconds = -5 * 60 * 60,
      .transitions = {{.at_utc_seconds = utc_seconds(2026, 3, 8, 7),
                       .offset_before_seconds = -5 * 60 * 60,
                       .offset_after_seconds = -4 * 60 * 60},
                      {.at_utc_seconds = utc_seconds(2026, 11, 1, 6),
                       .offset_before_seconds = -4 * 60 * 60,
                       .offset_after_seconds = -5 * 60 * 60}},
  };

  const dawn::WeeklyAlarmDefinition gap_alarm{
      .id = "gap",
      .schedule_revision = 4,
      .enabled = true,
      .schedule = dawn::WeeklyAlarmSchedule{.local_hour = 2,
                                            .local_minute = 30,
                                            .iso_weekday_mask =
                                                dawn::weekday_bit(
                                                    dawn::IsoWeekday::sunday),
                                            .timezone_name = "America/New_York",
                                            .timezone_rules_version =
                                                "2026a"},
  };
  const dawn::WeeklyAlarmDefinition fold_alarm{
      .id = "fold",
      .schedule_revision = 4,
      .enabled = true,
      .schedule = dawn::WeeklyAlarmSchedule{.local_hour = 1,
                                            .local_minute = 30,
                                            .iso_weekday_mask =
                                                dawn::weekday_bit(
                                                    dawn::IsoWeekday::sunday),
                                            .timezone_name = "America/New_York",
                                            .timezone_rules_version =
                                                "2026a"},
  };

  const auto gap = dawn::materialize_next_schedule_entries(
      std::span<const dawn::WeeklyAlarmDefinition>(&gap_alarm, 1),
      std::span<const dawn::TimezoneRules>(&rules, 1),
      utc_seconds(2026, 3, 8, 0));
  expect(gap.status == dawn::MaterializationStatus::materialized &&
             gap.alarms.size() == 1 && gap.alarms.front().shifted_for_gap,
         "spring-gap shift marker propagates to materialized entry");

  const auto fold = dawn::materialize_next_schedule_entries(
      std::span<const dawn::WeeklyAlarmDefinition>(&fold_alarm, 1),
      std::span<const dawn::TimezoneRules>(&rules, 1),
      utc_seconds(2026, 11, 1, 0));
  expect(fold.status == dawn::MaterializationStatus::materialized &&
             fold.alarms.size() == 1 && fold.alarms.front().ambiguous_fold,
         "fall-fold ambiguity marker propagates to materialized entry");
}

void materialized_entry_drives_committed_evaluator_without_bypassing_journal() {
  const dawn::TimezoneRules utc{
      .name = "Etc/UTC",
      .version = "2026a",
      .initial_utc_offset_seconds = 0,
      .transitions = {},
  };
  const dawn::WeeklyAlarmDefinition weekly{
      .id = "wake",
      .schedule_revision = 1,
      .enabled = true,
      .schedule = dawn::WeeklyAlarmSchedule{.local_hour = 0,
                                            .local_minute = 0,
                                            .iso_weekday_mask = 0x7fU,
                                            .timezone_name = "Etc/UTC",
                                            .timezone_rules_version = "2026a"},
  };
  const auto materialized = dawn::materialize_next_schedule_entries(
      std::span<const dawn::WeeklyAlarmDefinition>(&weekly, 1),
      std::span<const dawn::TimezoneRules>(&utc, 1), 0);
  expect(materialized.status == dawn::MaterializationStatus::materialized &&
             materialized.alarms.size() == 1,
         "fixture materialization succeeds");

  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  dawn::ScheduleSnapshot snapshot;
  snapshot.revision = 1;
  snapshot.timezone_rules_version = "2026a";
  snapshot.alarms.push_back(materialized.alarms.front().stored_alarm);
  const auto saved = store.save(snapshot, 0);

  const auto evaluation = dawn::evaluate_committed_schedule(
      store, materialized.alarms.front().stored_alarm.scheduled_utc_seconds, 50,
      true);
  const auto loaded = store.load();

  expect(saved.status == dawn::StoreStatus::stored,
         "materialized snapshot commits to atomic schedule store");
  expect(evaluation.status == dawn::CommittedEvaluationStatus::evaluated &&
             evaluation.alarms.size() == 1 &&
             evaluation.alarms.front().result.status ==
                 dawn::EvaluationStatus::ringing,
         "committed evaluator accepts materialized UTC entry");
  expect(evaluation.alarms.front().journal_committed &&
             evaluation.alarms.front().result.start_alert &&
             !evaluation.alarms.front().result.persist_before_effects,
         "journal-before-effect semantics remain enforced for materialized entry");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             loaded.snapshot.occurrence_state.active.has_value() &&
             loaded.snapshot.occurrence_state.active->occurrence_id ==
                 "wake:1:86400",
         "materialized entry produces deterministic occurrence identity");
}

} // namespace

int main() {
  successful_materialization_orders_by_utc_then_alarm_id();
  disabled_alarms_materialize_without_rule_lookup();
  missing_timezone_rules_fail_closed();
  invalid_transition_chain_fails_closed();
  spring_gap_and_fall_fold_flags_propagate_to_materialized_entries();
  materialized_entry_drives_committed_evaluator_without_bypassing_journal();

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }

  std::cout << "schedule_materializer_tests: PASS\n";
  return EXIT_SUCCESS;
}
