#include "dawn/committed_alarm_disable.hpp"
#include "dawn/committed_schedule_evaluator.hpp"

#include <array>
#include <cstddef>
#include <cstdlib>
#include <functional>
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

class MemorySlotStorage final : public dawn::SlotStorage {
public:
  bool begin_transaction() override {
    if (transaction_open) {
      return false;
    }
    ++transaction_count;
    if (injector && transaction_count == inject_at_transaction) {
      inject_at_transaction = -1;
      auto injection = std::move(injector);
      injection();
    }
    transaction_open = true;
    return true;
  }

  void end_transaction() override { transaction_open = false; }

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

  // Damages the trailing checksum byte of every present record outside any
  // transaction, simulating silent media corruption between boots.
  void corrupt_all() {
    for (auto &record : slots) {
      if (record && !record->empty()) {
        record->back() ^= std::byte{0xFF};
      }
    }
  }

  bool transaction_open{};
  bool fail_writes{};
  int write_count{};
  int transaction_count{};
  int inject_at_transaction{-1};
  std::function<void()> injector;

private:
  static constexpr std::size_t index(dawn::StorageSlot slot) {
    return slot == dawn::StorageSlot::a ? 0U : 1U;
  }

  std::array<std::optional<std::vector<std::byte>>, 2> slots;
};

dawn::ScheduleSnapshot snapshot_with_alarm(std::string_view id,
                                           std::int64_t scheduled_utc,
                                           bool enabled = true) {
  dawn::ScheduleSnapshot snapshot;
  snapshot.revision = 1;
  snapshot.timezone_rules_version = "2026a";
  snapshot.alarms.push_back({.id = std::string(id),
                             .schedule_revision = 1,
                             .enabled = enabled,
                             .scheduled_utc_seconds = scheduled_utc});
  return snapshot;
}

bool has_terminal(const dawn::ScheduleSnapshot &snapshot,
                  std::string_view occurrence_id,
                  dawn::TerminalReason reason) {
  for (const auto &terminal : snapshot.occurrence_state.terminal) {
    if (terminal.occurrence_id == occurrence_id && terminal.reason == reason) {
      return true;
    }
  }
  return false;
}

bool alarm_is_disabled(const dawn::ScheduleSnapshot &snapshot,
                       std::string_view id) {
  for (const auto &alarm : snapshot.alarms) {
    if (alarm.id == id) {
      return !alarm.enabled;
    }
  }
  return false;
}

// Drives the engine to a ringing occurrence committed through the store so
// the disable operation sees a realistic active journal.
void bring_alarm_to_ringing(dawn::AtomicScheduleStore &store) {
  const auto evaluation = dawn::evaluate_committed_schedule(store, 1'000, 50);
  bool wake_ringing = false;
  for (const auto &alarm : evaluation.alarms) {
    wake_ringing = wake_ringing || (alarm.alarm_id == "wake" &&
                                    alarm.result.status ==
                                        dawn::EvaluationStatus::ringing);
  }
  expect(evaluation.status == dawn::CommittedEvaluationStatus::evaluated &&
             wake_ringing,
         "fixture alarm is ringing before disable");
}

void ringing_dismiss_commits_journal_before_definition() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 1'000), 0).status ==
                 dawn::StoreStatus::stored,
         "fixture schedule is committed");
  bring_alarm_to_ringing(store);

  const auto result = dawn::disable_committed_alarm(store, "wake");
  const auto loaded = store.load();

  expect(result.status == dawn::CommittedDisableStatus::disabled,
         "confirmed disable reaches the disabled status");
  expect(result.journal_committed && result.definition_committed,
         "both the dismiss journal and the definition change are durable");
  expect(result.stop_alert && result.occurrence_id == "wake:1:1000",
         "stop edge is exposed with the dismissed occurrence id");
  expect(result.schedule_revision == 2 && result.generation == 4,
         "disable advances the schedule revision once and follows the "
         "runtime generation");
  expect(backend.write_count == 4,
         "schedule, admit, dismiss journal, and definition use separate "
         "writes");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             loaded.snapshot.revision == 2 && !loaded.snapshot.occurrence_state.active &&
             has_terminal(loaded.snapshot, "wake:1:1000",
                          dawn::TerminalReason::alarm_disabled),
         "durable record carries the alarmDisabled terminal outcome and no "
         "active occurrence");
  expect(alarm_is_disabled(loaded.snapshot, "wake"),
         "definition is durably disabled");
}

void snoozed_dismiss_persists_alarm_disabled_reason() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 1'000), 0).status ==
                 dawn::StoreStatus::stored,
         "fixture schedule is committed");
  bring_alarm_to_ringing(store);

  auto snoozed_state = store.load().snapshot.occurrence_state;
  expect(snoozed_state.active->occurrence_id == "wake:1:1000",
         "fixture reload exposes the active occurrence");
  const auto snooze_commit =
      dawn::request_snooze(snoozed_state, "wake:1:1000", 60);
  expect(snooze_commit.status == dawn::EvaluationStatus::snoozed,
         "snooze applies to the reloaded journal");
  auto pre_commit = store.load();
  expect(store
             .save_occurrence_state(snoozed_state,
                                    pre_commit.snapshot.revision,
                                    pre_commit.generation)
             .status == dawn::StoreStatus::stored,
         "snooze journal is committed");

  const auto result = dawn::disable_committed_alarm(store, "wake");
  const auto loaded = store.load();

  expect(result.status == dawn::CommittedDisableStatus::disabled &&
             result.stop_alert && result.definition_committed,
         "snoozed occurrence is confirmed-disabled end to end");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             !loaded.snapshot.occurrence_state.active &&
             has_terminal(loaded.snapshot, "wake:1:1000",
                          dawn::TerminalReason::alarm_disabled),
         "snooze deadline is replaced by the durable alarmDisabled record");
}

void armed_disable_writes_only_the_definition() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 100'000), 0).status ==
                 dawn::StoreStatus::stored,
         "future fixture schedule is committed");

  const auto result = dawn::disable_committed_alarm(store, "wake");
  const auto loaded = store.load();

  expect(result.status == dawn::CommittedDisableStatus::disabled,
         "armed alarm without an active occurrence disables cleanly");
  expect(!result.stop_alert && !result.journal_committed &&
             result.definition_committed,
         "armed disable exposes no alert effect and no journal phase");
  expect(result.schedule_revision == 2,
         "definition commit advances the revision once");
  expect(backend.write_count == 2,
         "only schedule and definition writes occur");
  expect(alarm_is_disabled(loaded.snapshot, "wake"),
         "armed definition is durably disabled");
}

void disabling_other_alarm_preserves_active_journal() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  auto snapshot = snapshot_with_alarm("wake", 1'000);
  snapshot.alarms.push_back({.id = "weekend",
                             .schedule_revision = 1,
                             .enabled = true,
                             .scheduled_utc_seconds = 500'000});
  expect(store.save(snapshot, 0).status == dawn::StoreStatus::stored,
         "two-alarm fixture schedule is committed");
  bring_alarm_to_ringing(store);

  const auto result = dawn::disable_committed_alarm(store, "weekend");
  const auto loaded = store.load();

  expect(result.status == dawn::CommittedDisableStatus::disabled &&
             !result.stop_alert && !result.journal_committed &&
             result.definition_committed,
         "disabling the non-active alarm commits only the definition");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             loaded.snapshot.occurrence_state.active &&
             loaded.snapshot.occurrence_state.active->occurrence_id ==
                 "wake:1:1000",
         "active journal of the other alarm survives the definition commit");
  expect(alarm_is_disabled(loaded.snapshot, "weekend"),
         "target definition is durably disabled");
  expect(backend.write_count == 3,
         "schedule, active admit, and definition each write once");
}

void disable_after_terminal_outcome_lands_definition() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 0), 0).status ==
                 dawn::StoreStatus::stored,
         "past fixture schedule is committed");
  const auto evaluation = dawn::evaluate_committed_schedule(store, 100'000, 50);
  expect(evaluation.status == dawn::CommittedEvaluationStatus::evaluated &&
             evaluation.alarms.front().result.status ==
                 dawn::EvaluationStatus::missed,
         "fixture occurrence is durably missed before disable");

  const auto result = dawn::disable_committed_alarm(store, "wake");
  const auto loaded = store.load();

  expect(result.status == dawn::CommittedDisableStatus::disabled &&
             !result.stop_alert && !result.journal_committed &&
             result.definition_committed,
         "disable-after-terminal lands the definition without new alert "
         "effects");
  expect(loaded.status == dawn::LoadStatus::loaded &&
             loaded.snapshot.occurrence_state.terminal.size() == 1 &&
             alarm_is_disabled(loaded.snapshot, "wake"),
         "terminal record is retained and definition is disabled");
}

void unknown_alarm_reports_not_found_without_writes() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 1'000), 0).status ==
                 dawn::StoreStatus::stored,
         "fixture schedule is committed");

  const auto result = dawn::disable_committed_alarm(store, "ghost");

  expect(result.status == dawn::CommittedDisableStatus::alarm_not_found,
         "unknown id reports alarm_not_found");
  expect(!result.stop_alert && !result.journal_committed &&
             !result.definition_committed,
         "unknown id exposes no effects");
  expect(backend.write_count == 1,
         "unknown id produces no storage writes");
}

void already_disabled_is_a_no_op() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 1'000, false), 0).status ==
                 dawn::StoreStatus::stored,
         "disabled fixture schedule is committed");

  const auto result = dawn::disable_committed_alarm(store, "wake");

  expect(result.status == dawn::CommittedDisableStatus::already_disabled,
         "repeated disable reports already_disabled");
  expect(!result.stop_alert && !result.journal_committed &&
             !result.definition_committed && result.schedule_revision == 1,
         "already-disabled leaves the revision untouched");
  expect(backend.write_count == 1,
         "already-disabled produces no additional writes");
}

void journal_write_failure_suppresses_everything_then_recovers() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 1'000), 0).status ==
                 dawn::StoreStatus::stored,
         "fixture schedule is committed");
  bring_alarm_to_ringing(store);

  backend.fail_writes = true;
  const auto failed = dawn::disable_committed_alarm(store, "wake");
  backend.fail_writes = false;

  expect(failed.status == dawn::CommittedDisableStatus::persistence_error,
         "journal write failure reports persistence_error");
  expect(!failed.stop_alert && !failed.journal_committed &&
             !failed.definition_committed,
         "failed journal phase exposes no stop edge and no definition claim");
  const auto after_failure = store.load();
  expect(after_failure.status == dawn::LoadStatus::loaded &&
             after_failure.snapshot.revision == 1 &&
             after_failure.snapshot.occurrence_state.active &&
             alarm_is_disabled(after_failure.snapshot, "wake") == false,
         "failed disable leaves the occurrence active and the definition "
         "enabled for retry");

  const auto retried = dawn::disable_committed_alarm(store, "wake");
  const auto after_retry = store.load();
  expect(retried.status == dawn::CommittedDisableStatus::disabled &&
             retried.journal_committed && retried.definition_committed &&
             retried.stop_alert,
         "retry after transient failure completes both phases");
  expect(after_retry.status == dawn::LoadStatus::loaded &&
             after_retry.snapshot.revision == 2 &&
             !after_retry.snapshot.occurrence_state.active &&
             alarm_is_disabled(after_retry.snapshot, "wake"),
         "retry lands the durable end state exactly once");
}

void concurrent_commit_forces_phase_two_revision_conflict() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 1'000), 0).status ==
                 dawn::StoreStatus::stored,
         "fixture schedule is committed");
  bring_alarm_to_ringing(store);

  // A third-party schedule commit lands just before the phase-two
  // definition transaction begins (txn order: fixture save, evaluator
  // load, admit journal, disable load, phase-one journal, phase two).
  backend.inject_at_transaction = 6;
  backend.injector = [&]() {
    auto racing = snapshot_with_alarm("wake", 1'000);
    racing.revision = 2;
    racing.timezone_rules_version = "2026b";
    expect(store.save(racing, 1).status == dawn::StoreStatus::stored,
           "racing schedule commit lands");
    expect(backend.write_count == 4,
           "racing commit follows schedule, admit, and phase-one writes");
  };

  const auto result = dawn::disable_committed_alarm(store, "wake");

  expect(result.status == dawn::CommittedDisableStatus::persistence_conflict,
         "phase two reports the revision conflict");
  expect(result.journal_committed && result.stop_alert &&
             !result.definition_committed,
         "durable dismiss journal and stop edge are reported while the "
         "definition remains pending");
  const auto conflicted = store.load();
  expect(conflicted.status == dawn::LoadStatus::loaded &&
             conflicted.snapshot.revision == 2 &&
             !conflicted.snapshot.occurrence_state.active &&
             has_terminal(conflicted.snapshot, "wake:1:1000",
                          dawn::TerminalReason::alarm_disabled),
         "racing commit carries the durable dismiss forward");

  backend.injector = {};
  const auto retried = dawn::disable_committed_alarm(store, "wake");
  const auto after_retry = store.load();
  expect(retried.status == dawn::CommittedDisableStatus::disabled &&
             retried.definition_committed && retried.schedule_revision == 3,
         "disable retry against the new revision lands the definition");
  expect(after_retry.status == dawn::LoadStatus::loaded &&
             alarm_is_disabled(after_retry.snapshot, "wake"),
         "retry durably disables the definition");
}

void concurrent_commit_forces_phase_one_generation_conflict() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 1'000), 0).status ==
                 dawn::StoreStatus::stored,
         "fixture schedule is committed");
  bring_alarm_to_ringing(store);

  // A third-party runtime commit lands just before the phase-one journal
  // transaction, invalidating the loaded generation CAS (txn order: fixture
  // save, evaluator load, admit journal, disable load, phase one).
  backend.inject_at_transaction = 5;
  backend.injector = [&store]() {
    auto journal = store.load().snapshot.occurrence_state;
    expect(static_cast<bool>(journal.active),
           "racing reload observes the active occurrence");
    journal.active->snooze_count = 1;
    expect(store
               .save_occurrence_state(journal,
                                      store.load().snapshot.revision,
                                      store.load().generation)
               .status == dawn::StoreStatus::stored,
           "racing runtime commit lands");
  };

  const auto result = dawn::disable_committed_alarm(store, "wake");

  expect(result.status == dawn::CommittedDisableStatus::persistence_conflict,
         "phase one reports the CAS conflict");
  expect(!result.stop_alert && !result.journal_committed &&
             !result.definition_committed,
         "conflicted phase one exposes no stop edge or definition claim");
  expect(backend.write_count == 3,
         "only schedule, admit, and racing commit wrote before the conflict");
}

void store_status_passthrough() {
  MemorySlotStorage empty_backend;
  dawn::AtomicScheduleStore empty_store(empty_backend);
  expect(dawn::disable_committed_alarm(empty_store, "wake").status ==
                 dawn::CommittedDisableStatus::empty_store,
         "empty store reports empty_store");

  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarm("wake", 1'000), 0).status ==
                 dawn::StoreStatus::stored,
         "fixture schedule is committed");
  backend.corrupt_all();

  const auto result = dawn::disable_committed_alarm(store, "wake");
  expect(result.status == dawn::CommittedDisableStatus::invalid_store,
         "corrupted store reports invalid_store");
  expect(!result.stop_alert && !result.journal_committed &&
             !result.definition_committed,
         "corrupted store exposes no effects");
  expect(backend.write_count == 1,
         "corrupted store produces no additional writes");
}

} // namespace

int main() {
  ringing_dismiss_commits_journal_before_definition();
  snoozed_dismiss_persists_alarm_disabled_reason();
  armed_disable_writes_only_the_definition();
  disabling_other_alarm_preserves_active_journal();
  disable_after_terminal_outcome_lands_definition();
  unknown_alarm_reports_not_found_without_writes();
  already_disabled_is_a_no_op();
  journal_write_failure_suppresses_everything_then_recovers();
  concurrent_commit_forces_phase_two_revision_conflict();
  concurrent_commit_forces_phase_one_generation_conflict();
  store_status_passthrough();

  if (failures != 0) {
    std::cerr << failures << " assertion(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "committed_alarm_disable_tests: PASS\n";
  return EXIT_SUCCESS;
}
