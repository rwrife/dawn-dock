#include "dawn/committed_schedule_evaluator.hpp"

#include <array>
#include <cstddef>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <limits>
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

class MemorySlotStorage final : public dawn::SlotStorage {
public:
  bool begin_transaction() override {
    if (transaction_open) {
      return false;
    }
    transaction_open = true;
    return true;
  }

  void end_transaction() override {
    transaction_open = false;
    if (on_transaction_end) {
      auto callback = std::move(on_transaction_end);
      on_transaction_end = {};
      callback();
    }
  }

  [[nodiscard]] dawn::SlotReadResult
  read(dawn::StorageSlot slot) const override {
    const auto &record = slots[index(slot)];
    if (!record) {
      return {.status = dawn::SlotReadStatus::empty, .bytes = {}};
    }
    return {.status = dawn::SlotReadStatus::present, .bytes = *record};
  }

  bool write(dawn::StorageSlot slot,
             std::span<const std::byte> bytes) override {
    if (!transaction_open || fail_writes) {
      return false;
    }
    slots[index(slot)] = std::vector<std::byte>(bytes.begin(), bytes.end());
    ++write_count;
    return true;
  }

  bool transaction_open{};
  bool fail_writes{};
  int write_count{};
  std::function<void()> on_transaction_end;

private:
  static constexpr std::size_t index(dawn::StorageSlot slot) {
    return slot == dawn::StorageSlot::a ? 0U : 1U;
  }

  std::array<std::optional<std::vector<std::byte>>, 2> slots;
};

dawn::ScheduleSnapshot snapshot_with_alarm(std::int64_t scheduled_utc) {
  dawn::ScheduleSnapshot snapshot;
  snapshot.revision = 1;
  snapshot.timezone_rules_version = "2026a";
  snapshot.alarms.push_back({.id = "wake",
                             .schedule_revision = 1,
                             .enabled = true,
                             .scheduled_utc_seconds = scheduled_utc});
  return snapshot;
}

const dawn::CommittedAlarmEvaluation *find_active_entry(
    const dawn::CommittedScheduleEvaluation &evaluation) {
  for (const auto &alarm : evaluation.alarms) {
    if (alarm.from_active_occurrence) {
      return &alarm;
    }
  }
  return nullptr;
}

std::size_t count_start_alerts(
    const dawn::CommittedScheduleEvaluation &evaluation) {
  std::size_t count = 0;
  for (const auto &alarm : evaluation.alarms) {
    if (alarm.result.start_alert) {
      ++count;
    }
  }
  return count;
}

std::size_t count_stop_alerts(
    const dawn::CommittedScheduleEvaluation &evaluation) {
  std::size_t count = 0;
  for (const auto &alarm : evaluation.alarms) {
    if (alarm.result.stop_alert) {
      ++count;
    }
  }
  return count;
}

void due_alarm_is_committed_before_alert_is_exposed() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm(1'000), 0).status ==
             dawn::StoreStatus::stored,
         "fixture schedule is committed");

  const auto evaluation =
      dawn::evaluate_committed_schedule(store, 1'000, 50, true);
  const auto loaded = store.load();

  expect(evaluation.status == dawn::CommittedEvaluationStatus::evaluated,
         "committed schedule evaluates successfully");
  expect(evaluation.schedule_revision == 1 && evaluation.generation == 2,
         "evaluation reports the committed runtime generation");
  expect(evaluation.alarms.size() == 1,
         "one committed alarm produces one evaluation");
  expect(evaluation.alarms.front().alarm_id == "wake" &&
             evaluation.alarms.front().result.status ==
                 dawn::EvaluationStatus::ringing,
         "due committed alarm enters ringing");
  expect(evaluation.alarms.front().journal_committed,
         "evaluator confirms the occurrence journal commit");
  expect(evaluation.alarms.front().result.start_alert &&
             !evaluation.alarms.front().result.persist_before_effects,
         "alert is exposed only after persistence is complete");
  expect(backend.write_count == 2,
         "schedule and occurrence journal use separate atomic writes");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             loaded.generation == 2 && loaded.snapshot.occurrence_state.active &&
             loaded.snapshot.occurrence_state.active->occurrence_id ==
                 "wake:1:1000",
         "active occurrence is durable before caller receives the alert");
}

void storage_order_cannot_skip_an_older_missed_occurrence() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  auto snapshot = snapshot_with_alarm(1'000);
  snapshot.alarms.front().id = "recent";
  snapshot.alarms.push_back({.id = "older",
                             .schedule_revision = 1,
                             .enabled = true,
                             .scheduled_utc_seconds = 0});
  expect(store.save(snapshot, 0).status == dawn::StoreStatus::stored,
         "reverse-ordered fixture schedule is committed");

  const auto evaluation =
      dawn::evaluate_committed_schedule(store, 1'000, 50, true);
  const auto loaded = store.load();

  expect(evaluation.status == dawn::CommittedEvaluationStatus::evaluated,
         "catch-up evaluation completes");
  expect(evaluation.alarms.size() == 2 &&
             evaluation.alarms[0].alarm_id == "older" &&
             evaluation.alarms[0].result.status ==
                 dawn::EvaluationStatus::missed &&
             evaluation.alarms[1].alarm_id == "recent" &&
             evaluation.alarms[1].result.status ==
                 dawn::EvaluationStatus::ringing,
         "occurrences evaluate by instant rather than storage order");
  expect(evaluation.alarms[0].journal_committed &&
             evaluation.alarms[1].journal_committed &&
             evaluation.alarms[1].result.start_alert,
         "missed and active journals commit before the alert is exposed");
  expect(evaluation.generation == 3 && backend.write_count == 3,
         "each durable transition advances the atomic generation");
  expect(loaded.snapshot.occurrence_state.terminal.size() == 1 &&
             loaded.snapshot.occurrence_state.terminal.front().occurrence_id ==
                 "older:1:0" &&
             loaded.snapshot.occurrence_state.active &&
             loaded.snapshot.occurrence_state.active->occurrence_id ==
                 "recent:1:1000",
         "durable journal contains both ordered outcomes");
}

void schedule_race_fails_closed_and_reports_new_generation() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm(1'000), 0).status ==
             dawn::StoreStatus::stored,
         "race fixture schedule is committed");
  backend.on_transaction_end = [&] {
    auto replacement = snapshot_with_alarm(2'000);
    replacement.revision = 2;
    replacement.alarms.front().schedule_revision = 2;
    expect(store.save(replacement, 1).status == dawn::StoreStatus::stored,
           "competing schedule update commits after evaluator load");
  };

  const auto evaluation =
      dawn::evaluate_committed_schedule(store, 1'000, 50, true);
  const auto loaded = store.load();

  expect(evaluation.status ==
             dawn::CommittedEvaluationStatus::persistence_conflict,
         "stale evaluator reports the schedule race");
  expect(evaluation.schedule_revision == 1 && evaluation.generation == 2,
         "race result identifies loaded revision and newer store generation");
  expect(evaluation.alarms.size() == 1 &&
             evaluation.alarms.front().result.status ==
                 dawn::EvaluationStatus::ringing &&
             !evaluation.alarms.front().result.start_alert &&
             !evaluation.alarms.front().journal_committed,
         "uncommitted stale occurrence exposes no alert effect");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             loaded.snapshot.revision == 2 && loaded.generation == 2 &&
             !loaded.snapshot.occurrence_state.active,
         "competing schedule remains authoritative without stale journal");
}

void concurrent_identical_admission_emits_only_one_alert_edge() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm(1'000), 0).status ==
             dawn::StoreStatus::stored,
         "duplicate-race fixture schedule is committed");
  backend.on_transaction_end = [&] {
    const auto concurrent = store.load();
    auto state = concurrent.snapshot.occurrence_state;
    const dawn::AlarmDefinition due{.id = "wake",
                                    .schedule_revision = 1,
                                    .enabled = true,
                                    .scheduled_utc_seconds = 1'000};
    const auto admitted = dawn::evaluate_due(due, state, 1'000, 50);
    expect(admitted.start_alert && admitted.persist_before_effects,
           "competing evaluator admits the same occurrence");
    expect(store.save_occurrence_state(state, concurrent.snapshot.revision,
                                       concurrent.generation)
                   .status == dawn::StoreStatus::stored,
           "competing evaluator commits the occurrence first");
  };

  const auto evaluation =
      dawn::evaluate_committed_schedule(store, 1'000, 50, true);
  const auto loaded = store.load();

  expect(evaluation.status == dawn::CommittedEvaluationStatus::evaluated &&
             evaluation.generation == 2,
         "idempotent race resolves against the durable generation");
  expect(evaluation.alarms.size() == 1 &&
             evaluation.alarms.front().result.status ==
                 dawn::EvaluationStatus::duplicate &&
             !evaluation.alarms.front().result.start_alert &&
             !evaluation.alarms.front().result.stop_alert &&
             evaluation.alarms.front().journal_committed,
         "losing evaluator exposes no duplicate alert edge");
  expect(backend.write_count == 2 &&
             loaded.snapshot.occurrence_state.active &&
             loaded.snapshot.occurrence_state.active->occurrence_id ==
                 "wake:1:1000",
         "exactly one occurrence journal write is durable");
}

void journal_write_failure_suppresses_alert_effects() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm(1'000), 0).status ==
             dawn::StoreStatus::stored,
         "write-failure fixture schedule is committed");
  backend.fail_writes = true;

  const auto evaluation =
      dawn::evaluate_committed_schedule(store, 1'000, 50, true);
  const auto loaded = store.load();

  expect(evaluation.status ==
             dawn::CommittedEvaluationStatus::persistence_error,
         "journal write failure is explicit");
  expect(evaluation.schedule_revision == 1 && evaluation.generation == 1,
         "failed write leaves the loaded generation current");
  expect(evaluation.alarms.size() == 1 &&
             evaluation.alarms.front().result.status ==
                 dawn::EvaluationStatus::ringing &&
             evaluation.alarms.front().result.persist_before_effects &&
             !evaluation.alarms.front().result.start_alert &&
             !evaluation.alarms.front().result.stop_alert &&
             !evaluation.alarms.front().journal_committed,
         "undurable transition preserves persistence requirement without effects");
  expect(backend.write_count == 1 &&
             loaded.status == dawn::LoadStatus::loaded &&
             !loaded.snapshot.occurrence_state.active,
         "failed runtime write leaves the committed schedule untouched");
}

void unrepresentable_lateness_stops_later_alarm_admission() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  auto snapshot = snapshot_with_alarm(1'000);
  snapshot.alarms.front().id = "recent";
  snapshot.alarms.push_back(
      {.id = "extreme",
       .schedule_revision = 1,
       .enabled = true,
       .scheduled_utc_seconds = std::numeric_limits<std::int64_t>::min()});
  expect(store.save(snapshot, 0).status == dawn::StoreStatus::stored,
         "extreme-time fixture schedule is committed");

  const auto evaluation =
      dawn::evaluate_committed_schedule(store, 1'000, 50, true);
  const auto loaded = store.load();

  expect(evaluation.status == dawn::CommittedEvaluationStatus::invalid_time,
         "unrepresentable lateness fails the whole evaluation closed");
  expect(evaluation.alarms.size() == 1 &&
             evaluation.alarms.front().alarm_id == "extreme" &&
             evaluation.alarms.front().result.status ==
                 dawn::EvaluationStatus::invalid_time,
         "evaluation stops at the invalid stored occurrence");
  expect(backend.write_count == 1 && loaded.generation == 1 &&
             !loaded.snapshot.occurrence_state.active &&
             loaded.snapshot.occurrence_state.terminal.empty(),
         "invalid time cannot journal or expose a later due alarm");
}

void active_snooze_expiry_commits_before_rering_edge() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm(1'000), 0).status ==
             dawn::StoreStatus::stored,
         "snooze-orchestration fixture schedule is committed");

  const auto admitted = dawn::evaluate_committed_schedule(store, 1'000, 50, true);
  const auto admitted_state = store.load();
  expect(admitted.status == dawn::CommittedEvaluationStatus::evaluated &&
             admitted_state.status == dawn::LoadStatus::loaded &&
             admitted_state.snapshot.occurrence_state.active,
         "fixture occurrence is active before snooze orchestration");

  auto snoozed_state = admitted_state.snapshot.occurrence_state;
  const auto occurrence_id = snoozed_state.active->occurrence_id;
  const auto snoozed = dawn::request_snooze(snoozed_state, occurrence_id, 60);
  expect(snoozed.status == dawn::EvaluationStatus::snoozed &&
             snoozed.persist_before_effects,
         "fixture occurrence enters durable snooze");
  expect(store.save_occurrence_state(snoozed_state,
                                     admitted_state.snapshot.revision,
                                     admitted_state.generation)
                 .status == dawn::StoreStatus::stored,
         "fixture snooze state is committed");

  const auto resumed = dawn::evaluate_committed_schedule(store, 1'000, 600, true);
  const auto resumed_state = store.load();
  const auto *active = find_active_entry(resumed);

  expect(resumed.status == dawn::CommittedEvaluationStatus::evaluated &&
             resumed.generation == 4,
         "snooze-expiry orchestration completes with updated generation");
  expect(active && active->alarm_id == "wake" &&
             active->result.status == dawn::EvaluationStatus::ringing &&
             active->journal_committed && active->result.start_alert &&
             !active->result.persist_before_effects,
         "active snooze expiry is journaled before exposing re-ring");
  expect(count_start_alerts(resumed) == 1,
         "snooze expiry emits exactly one start-alert edge");
  expect(resumed_state.status == dawn::LoadStatus::loaded &&
             resumed_state.snapshot.occurrence_state.active &&
             resumed_state.snapshot.occurrence_state.active->snooze_count == 1 &&
             !resumed_state.snapshot.occurrence_state.active
                  ->snooze_deadline_monotonic_seconds.has_value(),
         "durable active state clears the snooze deadline after re-ring");
  expect(backend.write_count == 4,
         "schedule, initial admit, snooze, and re-ring each commit once");
}

void active_timeout_commits_before_stop_edge() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm(1'000), 0).status ==
             dawn::StoreStatus::stored,
         "timeout-orchestration fixture schedule is committed");

  const auto admitted = dawn::evaluate_committed_schedule(store, 1'000, 100, true);
  expect(admitted.status == dawn::CommittedEvaluationStatus::evaluated,
         "fixture occurrence admits before timeout orchestration");

  const auto timed_out = dawn::evaluate_committed_schedule(store, 4'600, 3'700, true);
  const auto loaded = store.load();
  const auto *active = find_active_entry(timed_out);

  expect(timed_out.status == dawn::CommittedEvaluationStatus::evaluated &&
             timed_out.generation == 3,
         "timeout orchestration completes with updated generation");
  expect(active && active->result.status == dawn::EvaluationStatus::timed_out &&
             active->journal_committed && active->result.stop_alert &&
             !active->result.persist_before_effects,
         "active timeout is journaled before exposing stop-alert edge");
  expect(count_stop_alerts(timed_out) == 1,
         "timeout emits exactly one stop-alert edge");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             !loaded.snapshot.occurrence_state.active &&
             loaded.snapshot.occurrence_state.terminal.size() == 1 &&
             loaded.snapshot.occurrence_state.terminal.front().reason ==
                 dawn::TerminalReason::timed_out,
         "timeout transition is durable with one terminal timeout record");
  expect(backend.write_count == 3,
         "schedule, initial admit, and timeout each commit once");
}

void reboot_recovery_orchestration_resumes_once_per_boot() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm(5'000), 0).status ==
             dawn::StoreStatus::stored,
         "recovery-orchestration fixture schedule is committed");

  const auto admitted = dawn::evaluate_committed_schedule(store, 5'000, 100, true);
  const auto admitted_state = store.load();
  expect(admitted.status == dawn::CommittedEvaluationStatus::evaluated &&
             admitted_state.status == dawn::LoadStatus::loaded &&
             admitted_state.snapshot.occurrence_state.active,
         "fixture occurrence is active before reboot-recovery orchestration");

  auto snoozed_state = admitted_state.snapshot.occurrence_state;
  const auto occurrence_id = snoozed_state.active->occurrence_id;
  expect(dawn::request_snooze(snoozed_state, occurrence_id, 110).status ==
             dawn::EvaluationStatus::snoozed,
         "fixture occurrence enters snoozed state before reboot");
  expect(store.save_occurrence_state(snoozed_state,
                                     admitted_state.snapshot.revision,
                                     admitted_state.generation)
                 .status == dawn::StoreStatus::stored,
         "fixture snooze state is committed before reboot");

  const auto recovered =
      dawn::evaluate_committed_schedule(store, 8'599, 120, true, "boot-b");
  const auto duplicate =
      dawn::evaluate_committed_schedule(store, 8'599, 130, true, "boot-b");
  const auto loaded = store.load();
  const auto *recovered_active = find_active_entry(recovered);
  const auto *duplicate_active = find_active_entry(duplicate);

  expect(recovered.status == dawn::CommittedEvaluationStatus::evaluated &&
             recovered.generation == 4,
         "reboot recovery orchestration persists exactly one resume");
  expect(recovered_active && recovered_active->result.status ==
                                dawn::EvaluationStatus::ringing &&
             recovered_active->result.recovered_after_reboot &&
             recovered_active->journal_committed &&
             recovered_active->result.start_alert &&
             !recovered_active->result.persist_before_effects,
         "reboot recovery resumes ringing only after durable journal update");
  expect(count_start_alerts(recovered) == 1,
         "reboot recovery emits exactly one start-alert edge");

  expect(duplicate.status == dawn::CommittedEvaluationStatus::evaluated &&
             duplicate_active && duplicate_active->result.status ==
                                     dawn::EvaluationStatus::duplicate &&
             !duplicate_active->result.start_alert,
         "same-boot recovery is duplicate-suppressed");
  expect(count_start_alerts(duplicate) == 0,
         "duplicate same-boot recovery emits no extra start edge");

  expect(loaded.status == dawn::LoadStatus::loaded &&
             loaded.snapshot.occurrence_state.active &&
             loaded.snapshot.occurrence_state.active->recovered_after_reboot &&
             loaded.snapshot.occurrence_state.active->last_recovery_boot_id ==
                 "boot-b" &&
             !loaded.snapshot.occurrence_state.active
                  ->snooze_deadline_monotonic_seconds.has_value(),
         "durable recovered state records boot marker and clears snooze");
  expect(backend.write_count == 4,
         "schedule, initial admit, snooze, and first recovery each commit once");
}

} // namespace

int main() {
  due_alarm_is_committed_before_alert_is_exposed();
  storage_order_cannot_skip_an_older_missed_occurrence();
  schedule_race_fails_closed_and_reports_new_generation();
  concurrent_identical_admission_emits_only_one_alert_edge();
  journal_write_failure_suppresses_alert_effects();
  unrepresentable_lateness_stops_later_alarm_admission();
  active_snooze_expiry_commits_before_rering_edge();
  active_timeout_commits_before_stop_edge();
  reboot_recovery_orchestration_resumes_once_per_boot();

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "committed_schedule_evaluator_tests: PASS\n";
  return EXIT_SUCCESS;
}
