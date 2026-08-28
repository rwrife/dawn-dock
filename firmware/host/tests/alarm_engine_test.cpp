#include "dawn/alarm_engine.hpp"

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

void disabled_alarm_stays_disabled() {
  dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 7,
      .enabled = false,
      .scheduled_utc_seconds = 1'000,
  };
  dawn::PersistentAlarmState state;

  const auto result = dawn::evaluate_due(alarm, state, 1'000, 50);

  expect(result.status == dawn::EvaluationStatus::disabled,
         "disabled alarm reports disabled");
  expect(!result.start_alert, "disabled alarm never starts alert output");
  expect(!state.active.has_value(), "disabled alarm creates no active occurrence");
}

void due_alarm_is_journaled_before_alert() {
  dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 7,
      .enabled = true,
      .scheduled_utc_seconds = 1'000,
  };
  dawn::PersistentAlarmState state;

  const auto result = dawn::evaluate_due(alarm, state, 1'000, 50);

  expect(result.status == dawn::EvaluationStatus::ringing,
         "due alarm enters ringing state");
  expect(result.start_alert, "due alarm requests alert output");
  expect(result.persist_before_effects,
         "active journal must persist before alert output");
  expect(state.active.has_value(), "due alarm is durably represented as active");
  expect(state.active && state.active->occurrence_id == "wake:7:1000",
         "occurrence identity includes alarm, revision, and resolved UTC instant");
  expect(state.active && state.active->first_ring_utc_seconds == 1'000,
         "first ring wall instant is journaled");
  expect(state.active && state.active->first_ring_monotonic_seconds == 50,
         "first ring monotonic instant is journaled");
}

void late_grace_has_frozen_boundaries() {
  const dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 7,
      .enabled = true,
      .scheduled_utc_seconds = 1'000,
  };

  for (const auto lateness : {599, 600}) {
    dawn::PersistentAlarmState state;
    const auto result =
        dawn::evaluate_due(alarm, state, 1'000 + lateness, 50);
    expect(result.status == dawn::EvaluationStatus::ringing,
           "occurrence within late grace rings");
    expect(result.late, "crossed occurrence is labeled late");
    expect(result.lateness_seconds == lateness,
           "late occurrence records exact lateness");
  }

  dawn::PersistentAlarmState outside_state;
  const auto outside = dawn::evaluate_due(alarm, outside_state, 1'601, 50);
  expect(outside.status == dawn::EvaluationStatus::missed,
         "occurrence one second outside grace is missed");
  expect(!outside.start_alert, "missed occurrence never starts alert output");
  expect(!outside_state.active.has_value(),
         "missed occurrence is not stored as active");
  expect(outside_state.terminal.size() == 1,
         "missed occurrence is durably terminal");
  expect(outside.persist_before_effects,
         "missed journal must persist before visible state changes");
}

void journaled_occurrence_never_retriggers() {
  const dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 7,
      .enabled = true,
      .scheduled_utc_seconds = 1'000,
  };
  dawn::PersistentAlarmState active_state;
  (void)dawn::evaluate_due(alarm, active_state, 1'000, 50);

  const auto active_duplicate =
      dawn::evaluate_due(alarm, active_state, 1'000, 51);
  expect(active_duplicate.status == dawn::EvaluationStatus::duplicate,
         "active occurrence is recognized as duplicate");
  expect(!active_duplicate.start_alert,
         "active duplicate does not request a second alert start");
  expect(active_state.active &&
             active_state.active->first_ring_monotonic_seconds == 50,
         "duplicate evaluation leaves original active journal untouched");

  dawn::PersistentAlarmState terminal_state;
  terminal_state.terminal.push_back(
      {.occurrence_id = "wake:7:1000", .reason = dawn::TerminalReason::dismissed});
  const auto terminal_duplicate =
      dawn::evaluate_due(alarm, terminal_state, 1'000, 52);
  expect(terminal_duplicate.status == dawn::EvaluationStatus::duplicate,
         "terminal occurrence is recognized as duplicate");
  expect(!terminal_duplicate.start_alert,
         "terminal duplicate never requests alert output");
  expect(terminal_state.terminal.size() == 1,
         "terminal duplicate creates no additional journal record");
}

void different_due_occurrence_cannot_replace_active_journal() {
  const dawn::AlarmDefinition original{
      .id = "wake", .schedule_revision = 7, .enabled = true,
      .scheduled_utc_seconds = 1'000};
  const dawn::AlarmDefinition competing{
      .id = "backup", .schedule_revision = 1, .enabled = true,
      .scheduled_utc_seconds = 1'001};
  dawn::PersistentAlarmState state;
  (void)dawn::evaluate_due(original, state, 1'000, 50);

  const auto conflict = dawn::evaluate_due(competing, state, 1'001, 51);
  expect(conflict.status == dawn::EvaluationStatus::conflict,
         "different due occurrence conflicts with an active journal");
  expect(!conflict.start_alert && !conflict.persist_before_effects,
         "active conflict requests no side effect or persistence");
  expect(state.active && state.active->occurrence_id == "wake:7:1000" &&
             state.active->first_ring_monotonic_seconds == 50,
         "active conflict leaves the original journal untouched");

  const auto original_again = dawn::evaluate_due(original, state, 1'001, 52);
  expect(original_again.status == dawn::EvaluationStatus::duplicate &&
             !original_again.start_alert,
         "original active occurrence cannot retrigger after conflict");
}

void snooze_uses_monotonic_deadline_and_enforces_limit() {
  const dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 7,
      .enabled = true,
      .scheduled_utc_seconds = 1'000,
  };
  dawn::PersistentAlarmState state;
  const auto admitted = dawn::evaluate_due(alarm, state, 1'000, 0);
  const auto occurrence_id = admitted.occurrence_id;

  auto snoozed = dawn::request_snooze(state, occurrence_id, 10);
  expect(snoozed.status == dawn::EvaluationStatus::snoozed,
         "valid snooze enters snoozed state");
  expect(snoozed.stop_alert, "snooze stops current alert output");
  expect(snoozed.persist_before_effects,
         "snooze journal persists before stopping alert output");
  expect(state.active && state.active->snooze_deadline_monotonic_seconds == 550,
         "default snooze deadline is nine monotonic minutes");

  const auto repeated = dawn::request_snooze(state, occurrence_id, 20);
  expect(repeated.status == dawn::EvaluationStatus::conflict,
         "already-snoozed occurrence rejects another snooze");
  expect(state.active && state.active->snooze_count == 1,
         "repeated edge does not consume another snooze");
  expect(state.active && state.active->snooze_deadline_monotonic_seconds == 550,
         "repeated edge does not extend the current deadline");

  auto before_deadline = dawn::advance_active(state, 549);
  expect(before_deadline.status == dawn::EvaluationStatus::snoozed,
         "snooze remains paused before monotonic deadline");
  expect(!before_deadline.start_alert, "snooze does not re-ring early");

  auto at_deadline = dawn::advance_active(state, 550);
  expect(at_deadline.status == dawn::EvaluationStatus::ringing,
         "snooze re-enters ringing at monotonic deadline");
  expect(at_deadline.start_alert, "snooze expiry requests alert output");

  std::int64_t now = 550;
  for (int accepted = 1; accepted < dawn::kMaximumSnoozes; ++accepted) {
    snoozed = dawn::request_snooze(state, occurrence_id, now);
    expect(snoozed.status == dawn::EvaluationStatus::snoozed,
           "first six snooze requests are accepted");
    now += dawn::kDefaultSnoozeSeconds;
    (void)dawn::advance_active(state, now);
  }

  const auto rejected = dawn::request_snooze(state, occurrence_id, now);
  expect(rejected.status == dawn::EvaluationStatus::snooze_limit_reached,
         "seventh snooze request is rejected");
  expect(!rejected.stop_alert,
         "rejected snooze leaves the ringing alert active");
  expect(state.active && state.active->snooze_count == dawn::kMaximumSnoozes,
         "rejected snooze does not change durable count");
}

void snooze_duration_range_is_validated() {
  const dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 8,
      .enabled = true,
      .scheduled_utc_seconds = 2'000,
  };

  for (const auto duration : {60, 1'800}) {
    dawn::PersistentAlarmState state;
    const auto admitted = dawn::evaluate_due(alarm, state, 2'000, 0);
    const auto result =
        dawn::request_snooze(state, admitted.occurrence_id, 10, duration);
    expect(result.status == dawn::EvaluationStatus::snoozed,
           "one-to-thirty-minute snooze is accepted at boundaries");
  }

  for (const auto duration : {59, 1'801}) {
    dawn::PersistentAlarmState state;
    const auto admitted = dawn::evaluate_due(alarm, state, 2'000, 0);
    const auto result =
        dawn::request_snooze(state, admitted.occurrence_id, 10, duration);
    expect(result.status == dawn::EvaluationStatus::invalid_request,
           "snooze outside configured range is rejected");
    expect(state.active && state.active->snooze_count == 0,
           "invalid snooze does not mutate durable count");
    expect(state.active &&
               !state.active->snooze_deadline_monotonic_seconds.has_value(),
           "invalid snooze does not create a deadline");
  }
}

void extreme_and_rollback_times_fail_closed() {
  constexpr auto kMin = std::numeric_limits<std::int64_t>::min();
  constexpr auto kMax = std::numeric_limits<std::int64_t>::max();

  dawn::AlarmDefinition extreme{
      .id = "extreme", .schedule_revision = 1, .enabled = true,
      .scheduled_utc_seconds = kMin};
  dawn::PersistentAlarmState extreme_state;
  const auto wall_overflow = dawn::evaluate_due(extreme, extreme_state, kMax, 0);
  expect(wall_overflow.status == dawn::EvaluationStatus::invalid_time,
         "unrepresentable wall lateness fails closed explicitly");
  expect(!extreme_state.active && extreme_state.terminal.empty(),
         "unrepresentable wall lateness does not mutate the journal");

  dawn::AlarmDefinition normal{
      .id = "wake", .schedule_revision = 20, .enabled = true,
      .scheduled_utc_seconds = 1'000};
  dawn::PersistentAlarmState snooze_state;
  const auto admitted = dawn::evaluate_due(normal, snooze_state, 1'000, kMax);
  const auto snooze_overflow = dawn::request_snooze(
      snooze_state, admitted.occurrence_id, kMax, dawn::kMinimumSnoozeSeconds);
  expect(snooze_overflow.status == dawn::EvaluationStatus::invalid_time,
         "overflowing monotonic deadline fails closed explicitly");
  expect(snooze_state.active && snooze_state.active->snooze_count == 0 &&
             !snooze_state.active->snooze_deadline_monotonic_seconds,
         "overflowing snooze deadline leaves active journal unchanged");

  dawn::PersistentAlarmState rollback_state;
  (void)dawn::evaluate_due(normal, rollback_state, 1'000, 100);
  const auto monotonic_rollback = dawn::advance_active(rollback_state, kMin);
  expect(monotonic_rollback.status == dawn::EvaluationStatus::invalid_time,
         "monotonic rollback fails closed explicitly");
  expect(rollback_state.active.has_value() && rollback_state.terminal.empty(),
         "monotonic rollback does not terminate or alter active occurrence");

  const auto wall_rollback =
      dawn::recover_after_reboot(rollback_state, kMin, "boot-rollback");
  expect(wall_rollback.status == dawn::EvaluationStatus::invalid_time,
         "wall rollback during recovery fails closed explicitly");
  expect(rollback_state.active && !rollback_state.active->recovered_after_reboot &&
             rollback_state.active->last_recovery_boot_id.empty(),
         "wall rollback does not mutate reboot recovery journal");
}

void dismiss_requires_matching_occurrence_and_persists_first() {
  const dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 9,
      .enabled = true,
      .scheduled_utc_seconds = 3'000,
  };
  dawn::PersistentAlarmState state;
  const auto admitted = dawn::evaluate_due(alarm, state, 3'000, 0);

  const auto stale = dawn::dismiss_active(state, "wake:8:3000");
  expect(stale.status == dawn::EvaluationStatus::conflict,
         "stale occurrence ID returns conflict");
  expect(!stale.stop_alert, "stale dismiss does not stop current alert");
  expect(state.active.has_value(), "stale dismiss leaves active journal intact");

  const auto dismissed = dawn::dismiss_active(state, admitted.occurrence_id);
  expect(dismissed.status == dawn::EvaluationStatus::dismissed,
         "matching occurrence enters dismissed terminal outcome");
  expect(dismissed.stop_alert, "matching dismiss stops alert output");
  expect(dismissed.persist_before_effects,
         "dismiss terminal record persists before alert stops");
  expect(!state.active.has_value(), "dismiss clears active journal entry");
  expect(state.terminal.size() == 1 &&
             state.terminal.front().reason == dawn::TerminalReason::dismissed,
         "dismiss stores one durable terminal record");
}

void occurrence_times_out_at_sixty_monotonic_minutes() {
  const dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 10,
      .enabled = true,
      .scheduled_utc_seconds = 4'000,
  };
  dawn::PersistentAlarmState state;
  (void)dawn::evaluate_due(alarm, state, 4'000, 100);

  const auto before = dawn::advance_active(state, 3'699);
  expect(before.status == dawn::EvaluationStatus::ringing,
         "occurrence remains active at lifetime minus one second");

  const auto expired = dawn::advance_active(state, 3'700);
  expect(expired.status == dawn::EvaluationStatus::timed_out,
         "occurrence times out at exactly sixty minutes");
  expect(expired.stop_alert, "timeout stops alert output");
  expect(expired.persist_before_effects,
         "timeout terminal record persists before alert stops");
  expect(!state.active.has_value(), "timeout clears active journal entry");
  expect(state.terminal.size() == 1 &&
             state.terminal.front().reason == dawn::TerminalReason::timed_out,
         "timeout stores one durable terminal record");
}

void reboot_recovery_resumes_once_or_records_missed() {
  const dawn::AlarmDefinition alarm{
      .id = "wake",
      .schedule_revision = 11,
      .enabled = true,
      .scheduled_utc_seconds = 5'000,
  };
  dawn::PersistentAlarmState inside_state;
  const auto admitted = dawn::evaluate_due(alarm, inside_state, 5'000, 100);
  (void)dawn::request_snooze(inside_state, admitted.occurrence_id, 110);

  const auto resumed =
      dawn::recover_after_reboot(inside_state, 8'599, "boot-b");
  expect(resumed.status == dawn::EvaluationStatus::ringing,
         "active occurrence resumes inside wall lifetime");
  expect(resumed.start_alert, "recovery requests alert output once");
  expect(resumed.recovered_after_reboot,
         "recovery result is explicitly marked");
  expect(resumed.persist_before_effects,
         "recovery marker persists before alert output");
  expect(inside_state.active &&
             !inside_state.active->snooze_deadline_monotonic_seconds.has_value(),
         "reboot intentionally cancels remaining snooze");

  const auto same_boot =
      dawn::recover_after_reboot(inside_state, 8'599, "boot-b");
  expect(same_boot.status == dawn::EvaluationStatus::duplicate,
         "same boot cannot resume active alert twice");
  expect(!same_boot.start_alert,
         "duplicate recovery produces no second startup alert");

  dawn::PersistentAlarmState expired_state;
  (void)dawn::evaluate_due(alarm, expired_state, 5'000, 100);
  const auto expired =
      dawn::recover_after_reboot(expired_state, 8'600, "boot-c");
  expect(expired.status == dawn::EvaluationStatus::missed,
         "power-off expiry records missed rather than timed out");
  expect(!expired.start_alert, "expired recovery does not start alert output");
  expect(!expired_state.active.has_value(),
         "expired recovery clears active journal entry");
  expect(expired_state.terminal.size() == 1 &&
             expired_state.terminal.front().reason ==
                 dawn::TerminalReason::prolonged_power_off,
         "expired recovery records prolonged-power-off reason");
}

void terminal_journal_retains_only_fixed_recent_horizon() {
  dawn::PersistentAlarmState state;
  constexpr std::size_t kExtraEntries = 5;
  for (std::size_t index = 0;
       index < dawn::kRecentTerminalRetention + kExtraEntries; ++index) {
    const dawn::AlarmDefinition alarm{
        .id = "wake",
        .schedule_revision = index,
        .enabled = true,
        .scheduled_utc_seconds = static_cast<std::int64_t>(index),
    };
    const auto admitted = dawn::evaluate_due(
        alarm, state, static_cast<std::int64_t>(index), 0);
    (void)dawn::dismiss_active(state, admitted.occurrence_id);
  }

  expect(state.terminal.size() == dawn::kRecentTerminalRetention,
         "terminal journal is compacted to the fixed recent bound");
  expect(state.terminal.front().occurrence_id == "wake:5:5",
         "terminal compaction evicts the oldest records first");

  const dawn::AlarmDefinition evicted{
      .id = "wake",
      .schedule_revision = 0,
      .enabled = true,
      .scheduled_utc_seconds = 0,
  };
  const auto evicted_duplicate = dawn::evaluate_due(evicted, state, 0, 1);
  expect(evicted_duplicate.status == dawn::EvaluationStatus::duplicate &&
             !evicted_duplicate.start_alert,
         "evicted terminal occurrence remains duplicate-suppressed");

  const dawn::AlarmDefinition retained{
      .id = "wake",
      .schedule_revision = dawn::kRecentTerminalRetention + kExtraEntries - 1,
      .enabled = true,
      .scheduled_utc_seconds = static_cast<std::int64_t>(
          dawn::kRecentTerminalRetention + kExtraEntries - 1),
  };
  const auto duplicate = dawn::evaluate_due(
      retained, state, retained.scheduled_utc_seconds, 1);
  expect(duplicate.status == dawn::EvaluationStatus::duplicate &&
             !duplicate.start_alert,
         "retained terminal entries continue suppressing duplicates");
  expect(state.terminal.size() == dawn::kRecentTerminalRetention,
         "retained duplicate does not change the bounded journal");

  const dawn::AlarmDefinition newer{
      .id = "wake",
      .schedule_revision = dawn::kRecentTerminalRetention + kExtraEntries,
      .enabled = true,
      .scheduled_utc_seconds = static_cast<std::int64_t>(
          dawn::kRecentTerminalRetention + kExtraEntries),
  };
  const auto admitted_newer = dawn::evaluate_due(
      newer, state, newer.scheduled_utc_seconds, 2);
  expect(admitted_newer.status == dawn::EvaluationStatus::ringing &&
             admitted_newer.start_alert,
         "newer occurrence remains admissible after terminal compaction");
}

void terminal_high_watermark_capacity_fails_closed() {
  dawn::PersistentAlarmState state;
  for (std::size_t index = 0;
       index < dawn::kTerminalHighWatermarkCapacity; ++index) {
    const dawn::AlarmDefinition alarm{
        .id = "alarm-" + std::to_string(index),
        .schedule_revision = 1,
        .enabled = true,
        .scheduled_utc_seconds = 0,
    };
    const auto missed = dawn::evaluate_due(
        alarm, state, dawn::kLateGraceSeconds + 1, 0);
    expect(missed.status == dawn::EvaluationStatus::missed,
           "alarm is tracked before high-watermark capacity is exhausted");
  }

  const dawn::AlarmDefinition untracked{
      .id = "one-too-many",
      .schedule_revision = 1,
      .enabled = true,
      .scheduled_utc_seconds = 1,
  };
  const auto rejected = dawn::evaluate_due(untracked, state, 1, 0);
  expect(rejected.status == dawn::EvaluationStatus::conflict &&
             !rejected.start_alert && !state.active.has_value(),
         "untracked alarm fails closed when high-watermark capacity is full");
  expect(state.terminal_high_watermarks.size() ==
             dawn::kTerminalHighWatermarkCapacity,
         "terminal high-watermark index remains bounded");
}

}  // namespace

int main() {
  disabled_alarm_stays_disabled();
  due_alarm_is_journaled_before_alert();
  late_grace_has_frozen_boundaries();
  journaled_occurrence_never_retriggers();
  different_due_occurrence_cannot_replace_active_journal();
  snooze_uses_monotonic_deadline_and_enforces_limit();
  snooze_duration_range_is_validated();
  extreme_and_rollback_times_fail_closed();
  dismiss_requires_matching_occurrence_and_persists_first();
  occurrence_times_out_at_sixty_monotonic_minutes();
  reboot_recovery_resumes_once_or_records_missed();
  terminal_journal_retains_only_fixed_recent_horizon();
  terminal_high_watermark_capacity_fails_closed();

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "alarm_engine_tests: PASS\n";
  return EXIT_SUCCESS;
}
