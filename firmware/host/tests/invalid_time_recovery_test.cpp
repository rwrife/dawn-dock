#include "dawn/invalid_time_recovery.hpp"

#include <array>
#include <cstddef>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <algorithm>
#include <limits>
#include <optional>
#include <span>
#include <string>
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

dawn::ScheduleSnapshot snapshot_with_alarms(
    const std::vector<std::pair<std::string, std::int64_t>> &alarms,
    const std::vector<std::string> &disabled = {}) {
  dawn::ScheduleSnapshot snapshot;
  snapshot.revision = 1;
  snapshot.timezone_rules_version = "2026a";
  for (const auto &[id, scheduled] : alarms) {
    snapshot.alarms.push_back({.id = id,
                               .schedule_revision = 1,
                               .enabled = true,
                               .scheduled_utc_seconds = scheduled});
  }
  for (const auto &id : disabled) {
    snapshot.alarms.push_back({.id = id,
                               .schedule_revision = 1,
                               .enabled = false,
                               .scheduled_utc_seconds = 100});
  }
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

const dawn::RecoveredOccurrence *find_crossed(
    const dawn::InvalidTimeRecoveryResult &result, std::string_view alarm_id) {
  for (const auto &record : result.crossed) {
    if (record.alarm_id == alarm_id) {
      return &record;
    }
  }
  return nullptr;
}

void nothing_crossed_writes_nothing() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store
             .save(snapshot_with_alarms({{"future", 100'000}},
                                        {"past-disabled"}),
                   0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");

  const auto result = dawn::reconcile_after_time_valid(store, 1'000, 500);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::nothing_crossed,
         "future and disabled occurrences report nothing_crossed");
  expect(result.crossed.empty() && !result.start_alert &&
             !result.journal_committed,
         "nothing_crossed exposes no entries and no effects");
  expect(backend.write_count == 1, "nothing_crossed performs zero writes");
}

void terminal_journal_suppresses_reconciliation() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 1'000}}), 0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");

  // Normal admission journals the occurrence durably.
  const auto due = dawn::reconcile_after_time_valid(store, 1'000, 500);
  expect(due.status == dawn::InvalidTimeRecoveryStatus::reconciled &&
             due.start_alert &&
             due.ringing_occurrence_id == "wake:1:1000",
         "the first reconciliation rings the crossed occurrence");
  expect(backend.write_count == 2,
         "the ring reconciliation writes exactly one journal record");

  // While the occurrence is active, reconciliation defers to the
  // active-occurrence owner instead of stealing or duplicating it.
  const auto during = dawn::reconcile_after_time_valid(store, 1'600, 700);
  expect(during.status == dawn::InvalidTimeRecoveryStatus::active_conflict,
         "an active occurrence forces active_conflict");
  expect(!during.start_alert && during.crossed.empty() &&
             backend.write_count == 2,
         "active_conflict exposes no effects and zero writes");

  // After dismissal the terminal record and high-watermark suppress the
  // occurrence entirely.
  auto journal = store.load().snapshot.occurrence_state;
  expect(journal.active.has_value() &&
             dawn::dismiss_active(journal, "wake:1:1000")
                     .status == dawn::EvaluationStatus::dismissed,
         "the recovered ring dismisses cleanly");
  auto pre_commit = store.load();
  expect(store
             .save_occurrence_state(
                 journal, pre_commit.snapshot.revision, pre_commit.generation)
             .status == dawn::StoreStatus::stored,
         "the dismiss journal commits");

  const auto after = dawn::reconcile_after_time_valid(store, 1'600, 800);
  expect(after.status == dawn::InvalidTimeRecoveryStatus::nothing_crossed &&
             backend.write_count == 3,
         "terminal and watermarked occurrences reconcile to nothing with "
         "zero writes");
}

void single_crossed_occurrence_rings_within_grace() {
  for (const auto lateness : {0, 599, 600}) {
    MemorySlotStorage backend;
    dawn::AtomicScheduleStore store(backend);
    expect(store.save(snapshot_with_alarms({{"wake", 1'000}}), 0)
               .status == dawn::StoreStatus::stored,
           "fixture schedule is committed");

    const auto result =
        dawn::reconcile_after_time_valid(store, 1'000 + lateness, 500);
    expect(result.status == dawn::InvalidTimeRecoveryStatus::reconciled &&
               result.start_alert && result.journal_committed,
           "crossed occurrence within grace rings after the journal");
    expect(result.ringing_occurrence_id == "wake:1:1000",
           "ring reports the crossed occurrence id");
    const auto *record = find_crossed(result, "wake");
    expect(record != nullptr &&
               record->outcome == dawn::EvaluationStatus::ringing &&
               record->lateness_seconds == lateness,
           "recovery report carries the ringing outcome with exact lateness");
    expect(result.crossed.size() == 1,
           "single crossed occurrence reports exactly one entry");

    const auto loaded = store.load();
    expect(loaded.status == dawn::LoadStatus::loaded &&
               loaded.snapshot.occurrence_state.active &&
               loaded.snapshot.occurrence_state.active->occurrence_id ==
                   "wake:1:1000" &&
               loaded.snapshot.occurrence_state.active
                       ->first_ring_utc_seconds == 1'000 + lateness,
           "journal durably admits the recovered ring before the effect");
    expect(backend.write_count == 2,
           "ring reconciliation writes the journal exactly once");
  }
}

void single_crossed_occurrence_misses_outside_grace() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 1'000}}), 0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");

  const auto result = dawn::reconcile_after_time_valid(store, 1'601, 500);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::reconciled &&
             !result.start_alert && result.journal_committed,
         "crossed occurrence outside grace is missed without any alert");
  const auto *record = find_crossed(result, "wake");
  expect(record != nullptr &&
             record->outcome == dawn::EvaluationStatus::missed &&
             record->lateness_seconds == 601,
         "recovery report labels the missed newest occurrence with its "
         "lateness");

  const auto loaded = store.load();
  expect(loaded.status == dawn::LoadStatus::loaded &&
               !loaded.snapshot.occurrence_state.active &&
               has_terminal(loaded.snapshot, "wake:1:1000",
                            dawn::TerminalReason::invalid_time),
         "missed reconciliation journals the invalidTime terminal durably");
  expect(backend.write_count == 2,
         "missed reconciliation writes the journal exactly once");

  const auto repeat = dawn::reconcile_after_time_valid(store, 2'000, 900);
  expect(repeat.status == dawn::InvalidTimeRecoveryStatus::nothing_crossed &&
             backend.write_count == 2,
         "a repeated reconciliation after a miss is write-free and inert");
}

void multiple_crossed_occurrences_ring_only_the_newest() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms(
                       {{"earliest", 100}, {"middle", 300}, {"newest", 500}}),
                   0)
             .status == dawn::StoreStatus::stored,
         "three-alarm fixture schedule is committed");

  const auto result = dawn::reconcile_after_time_valid(store, 550, 700);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::reconciled &&
             result.start_alert && result.journal_committed,
         "multi-occurrence reconciliation exposes exactly one start edge");
  expect(result.ringing_occurrence_id == "newest:1:500" &&
             result.crossed.size() == 3,
         "the newest crossed occurrence rings");
  int starts = 0;
  for (const auto &record : result.crossed) {
    starts += record.outcome == dawn::EvaluationStatus::ringing ? 1 : 0;
    expect(record.lateness_seconds ==
               (record.alarm_id == "newest" ? 50 : 0),
           "older crossed entries report zero lateness; only the newest "
           "carries the deciding value");
  }
  expect(starts == 1, "only the newest crossed occurrence rings");
  const auto *earliest = find_crossed(result, "earliest");
  const auto *middle = find_crossed(result, "middle");
  expect(
      earliest != nullptr &&
          earliest->outcome == dawn::EvaluationStatus::missed &&
          middle != nullptr &&
          middle->outcome == dawn::EvaluationStatus::missed,
      "older crossed occurrences are missed regardless of own lateness");

  const auto loaded = store.load();
  expect(loaded.status == dawn::LoadStatus::loaded &&
               loaded.snapshot.occurrence_state.active &&
               loaded.snapshot.occurrence_state.active->occurrence_id ==
                   "newest:1:500",
         "the journal admits only the newest occurrence as active");
  expect(has_terminal(loaded.snapshot, "earliest:1:100",
                      dawn::TerminalReason::invalid_time) &&
             has_terminal(loaded.snapshot, "middle:1:300",
                          dawn::TerminalReason::invalid_time),
         "both older occurrences carry durable invalidTime terminals");
  expect(backend.write_count == 2,
         "the whole batch commits in one runtime journal write");
}

void multiple_crossed_occurrences_all_miss_when_newest_is_late() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms(
                       {{"earliest", 100}, {"middle", 300}, {"newest", 500}}),
                   0)
             .status == dawn::StoreStatus::stored,
         "three-alarm fixture schedule is committed");

  const auto result = dawn::reconcile_after_time_valid(store, 1'101, 900);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::reconciled &&
             !result.start_alert && result.journal_committed &&
             result.ringing_occurrence_id.empty(),
         "newest outside grace suppresses every alert");
  expect(result.crossed.size() == 3 &&
             std::all_of(result.crossed.begin(), result.crossed.end(),
                         [](const dawn::RecoveredOccurrence &record) {
                           return record.outcome ==
                                  dawn::EvaluationStatus::missed;
                         }),
         "every crossed occurrence is missed");

  const auto loaded = store.load();
  expect(loaded.status == dawn::LoadStatus::loaded &&
               !loaded.snapshot.occurrence_state.active &&
               has_terminal(loaded.snapshot, "newest:1:500",
                            dawn::TerminalReason::invalid_time),
         "the late newest occurrence journals an invalidTime terminal like "
         "the older ones");
}

void identical_instants_ring_the_deterministic_newest() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  // Distinct alarm ids keep occurrence ids unique while the scheduled
  // instants stay tied; the tie-break must be the alarm id.
  expect(store
             .save(snapshot_with_alarms(
                 {{"alarm-a", 500}, {"alarm-b", 500}, {"alarm-c", 500}}),
                 0)
             .status == dawn::StoreStatus::stored,
         "tie fixture schedule is committed");

  const auto result = dawn::reconcile_after_time_valid(store, 560, 700);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::reconciled &&
             result.start_alert &&
             result.ringing_occurrence_id == "alarm-c:1:500",
         "identical scheduled instants break ties deterministically by "
         "alarm id");
  expect(result.crossed.size() == 3, "all tied occurrences are reported");
  int starts = 0;
  for (const auto &record : result.crossed) {
    starts += record.outcome == dawn::EvaluationStatus::ringing ? 1 : 0;
  }
  expect(starts == 1, "a tie still produces a single ring");
}

void unrepresentable_lateness_fails_closed() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store
             .save(snapshot_with_alarms(
                 {{"ancient", std::numeric_limits<std::int64_t>::min()}}),
                 0)
             .status == dawn::StoreStatus::stored,
         "extreme-past fixture schedule is committed");

  const auto result = dawn::reconcile_after_time_valid(
      store, std::numeric_limits<std::int64_t>::max(), 500);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::invalid_time,
         "unrepresentable lateness fails closed as invalid_time");
  expect(backend.write_count == 1 && result.crossed.empty(),
         "unrepresentable lateness mutates nothing");
}

void invalid_time_input_short_circuits() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 1'000}}), 0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");

  const auto result =
      dawn::reconcile_after_time_valid(store, 5'000, 500, false);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::invalid_time &&
             !result.start_alert && backend.write_count == 1,
         "time_valid=false short-circuits with zero writes");
}

void active_occurrence_blocks_reconciliation() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 1'000}}), 0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");

  // Admit an occurrence through the normal evaluator path so the active
  // slot is owned by the standard lifecycle.
  auto journal = store.load().snapshot.occurrence_state;
  dawn::AlarmDefinition definition{
      .id = "wake",
      .schedule_revision = 1,
      .enabled = true,
      .scheduled_utc_seconds = 1'000,
  };
  expect(dawn::evaluate_due(definition, journal, 1'000, 40)
                 .status == dawn::EvaluationStatus::ringing,
         "engine admits the fixture occurrence as ringing");
  expect(store
             .save_occurrence_state(journal,
                                    store.load().snapshot.revision,
                                    store.load().generation)
             .status == dawn::StoreStatus::stored,
         "active journal is committed");

  const auto result =
      dawn::reconcile_after_time_valid(store, 5'000, 5'100);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::active_conflict &&
             !result.start_alert && backend.write_count == 2,
         "a pre-existing active occurrence defers with zero writes");
}

void full_watermark_table_fails_closed() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  auto snapshot = snapshot_with_alarms({{"crossed", 1'000}});
  for (std::size_t index = 0;
       index < dawn::kTerminalHighWatermarkCapacity; ++index) {
    snapshot.occurrence_state.terminal_high_watermarks.push_back(
        {"filler" + std::to_string(index), 1});
  }
  expect(store.save(snapshot, 0).status == dawn::StoreStatus::stored,
         "capacity fixture schedule is committed");

  const auto result = dawn::reconcile_after_time_valid(store, 1'601, 500);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::journal_capacity &&
             !result.journal_committed && result.crossed.empty(),
         "a full watermark table fails closed before mutating the journal");
  expect(backend.write_count == 1,
         "journal_capacity performs zero writes");
}

void journal_write_failure_is_retryable() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store
             .save(snapshot_with_alarms(
                 {{"earliest", 100}, {"newest", 500}}),
                 0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");

  backend.fail_writes = true;
  const auto failed = dawn::reconcile_after_time_valid(store, 550, 700);
  backend.fail_writes = false;

  expect(failed.status == dawn::InvalidTimeRecoveryStatus::persistence_error,
         "journal write failure reports persistence_error");
  expect(!failed.start_alert && !failed.journal_committed &&
             failed.crossed.empty(),
         "failed reconciliation exposes no alert effect or entries");
  const auto after_failure = store.load();
  expect(after_failure.status == dawn::LoadStatus::loaded &&
             !after_failure.snapshot.occurrence_state.active &&
             after_failure.snapshot.occurrence_state.terminal.empty(),
         "failed reconciliation leaves the journal untouched for retry");

  const auto retried = dawn::reconcile_after_time_valid(store, 550, 701);
  expect(retried.status == dawn::InvalidTimeRecoveryStatus::reconciled &&
             retried.start_alert && retried.journal_committed &&
             retried.ringing_occurrence_id == "newest:1:500",
         "retry after transient failure reconciles exactly once");
  const auto after_retry = store.load();
  expect(after_retry.status == dawn::LoadStatus::loaded &&
             after_retry.snapshot.occurrence_state.active &&
             has_terminal(after_retry.snapshot, "earliest:1:100",
                          dawn::TerminalReason::invalid_time),
         "retry lands the durable end state exactly once");
}

void concurrent_runtime_commit_forces_generation_conflict() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 1'000}}), 0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");

  // A third-party runtime commit lands just before the reconciliation
  // journal transaction, invalidating the loaded generation CAS (txn
  // order: fixture save, reconciliation load, journal commit).
  backend.inject_at_transaction = 3;
  backend.injector = [&store]() {
    auto journal = store.load().snapshot.occurrence_state;
    journal.terminal.push_back({"telemetry:1:900",
                                dawn::TerminalReason::dismissed});
    auto racing = store.load();
    expect(store
               .save_occurrence_state(journal, racing.snapshot.revision,
                                      racing.generation)
               .status == dawn::StoreStatus::stored,
           "racing runtime commit lands");
  };

  const auto result = dawn::reconcile_after_time_valid(store, 1'600, 700);
  expect(result.status ==
             dawn::InvalidTimeRecoveryStatus::persistence_conflict,
         "journal commit reports the generation conflict");
  expect(!result.start_alert && !result.journal_committed &&
             result.crossed.empty(),
         "conflicted reconciliation exposes no effects");

  backend.injector = {};
  const auto retried = dawn::reconcile_after_time_valid(store, 1'601, 701);
  expect(retried.status == dawn::InvalidTimeRecoveryStatus::reconciled &&
             !retried.start_alert && retried.journal_committed,
         "retry against fresh state lands the miss");
  const auto loaded = store.load();
  expect(has_terminal(loaded.snapshot, "wake:1:1000",
                      dawn::TerminalReason::invalid_time) &&
             has_terminal(loaded.snapshot, "telemetry:1:900",
                          dawn::TerminalReason::dismissed),
         "the retry carries the racing terminal forward alongside its own");
}

void concurrent_schedule_commit_forces_revision_conflict() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 1'000}}), 0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");

  // A third-party schedule commit lands just before the reconciliation
  // journal transaction, invalidating the revision CAS.
  backend.inject_at_transaction = 3;
  backend.injector = [&]() {
    auto racing = snapshot_with_alarms({{"wake", 100'000}});
    racing.revision = 2;
    expect(store.save(racing, 1).status == dawn::StoreStatus::stored,
           "racing schedule commit lands");
  };

  const auto result = dawn::reconcile_after_time_valid(store, 1'600, 700);
  expect(result.status ==
             dawn::InvalidTimeRecoveryStatus::persistence_conflict,
         "journal commit reports the revision conflict");
  expect(!result.start_alert && !result.journal_committed,
         "revision conflict exposes no effects");

  backend.injector = {};
  const auto retried = dawn::reconcile_after_time_valid(store, 1'600, 701);
  expect(retried.status == dawn::InvalidTimeRecoveryStatus::nothing_crossed,
         "retry against the new revision sees the rescheduled occurrence as "
         "no longer crossed");
}

void store_status_passthrough() {
  MemorySlotStorage empty_backend;
  dawn::AtomicScheduleStore empty_store(empty_backend);
  expect(
      dawn::reconcile_after_time_valid(empty_store, 1'000, 500).status ==
          dawn::InvalidTimeRecoveryStatus::empty_store,
      "empty store reports empty_store");

  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 1'000}}), 0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");
  backend.corrupt_all();

  const auto result = dawn::reconcile_after_time_valid(store, 1'600, 700);
  expect(result.status == dawn::InvalidTimeRecoveryStatus::invalid_store &&
             !result.start_alert && !result.journal_committed,
         "corrupted store reports invalid_store with no effects");
  expect(backend.write_count == 1,
         "corrupted store produces no additional writes");
}

} // namespace

int main() {
  nothing_crossed_writes_nothing();
  terminal_journal_suppresses_reconciliation();
  single_crossed_occurrence_rings_within_grace();
  single_crossed_occurrence_misses_outside_grace();
  multiple_crossed_occurrences_ring_only_the_newest();
  multiple_crossed_occurrences_all_miss_when_newest_is_late();
  identical_instants_ring_the_deterministic_newest();
  unrepresentable_lateness_fails_closed();
  invalid_time_input_short_circuits();
  active_occurrence_blocks_reconciliation();
  full_watermark_table_fails_closed();
  journal_write_failure_is_retryable();
  concurrent_runtime_commit_forces_generation_conflict();
  concurrent_schedule_commit_forces_revision_conflict();
  store_status_passthrough();

  if (failures != 0) {
    std::cerr << failures << " invalid-time recovery checks failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "invalid-time recovery checks passed\n";
  return EXIT_SUCCESS;
}
