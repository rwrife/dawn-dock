#include "dawn/runtime_coordinator.hpp"

#include "dawn/alarm_engine.hpp"

#include <array>
#include <cstddef>
#include <cstdlib>
#include <iostream>
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
    transaction_open = true;
    return true;
  }

  void end_transaction() override { transaction_open = false; }

  [[nodiscard]] dawn::SlotReadResult
  read(dawn::StorageSlot slot) const override {
    const auto &record = slots[index(slot)];
    if (fail_reads && record) {
      return {.status = dawn::SlotReadStatus::io_error, .bytes = {}};
    }
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

  [[nodiscard]] dawn::PersistentAlarmState persisted_state() {
    dawn::AtomicScheduleStore store(*this);
    const auto loaded = store.load();
    return loaded.snapshot.occurrence_state;
  }

  bool transaction_open{};
  bool fail_reads{};
  bool fail_writes{};
  int write_count{};
  int transaction_count{};

private:
  static constexpr std::size_t index(dawn::StorageSlot slot) {
    return slot == dawn::StorageSlot::a ? 0U : 1U;
  }

  std::array<std::optional<std::vector<std::byte>>, 2> slots;
};

dawn::ScheduleSnapshot snapshot_with_alarms(
    const std::vector<std::pair<std::string, std::int64_t>> &alarms) {
  dawn::ScheduleSnapshot snapshot;
  snapshot.revision = 1;
  snapshot.timezone_rules_version = "2026a";
  for (const auto &[id, scheduled] : alarms) {
    snapshot.alarms.push_back({.id = id,
                               .schedule_revision = 1,
                               .enabled = true,
                               .scheduled_utc_seconds = scheduled});
  }
  return snapshot;
}

dawn::RuntimeTickObservation valid_tick(std::int64_t wall,
                                        std::int64_t monotonic,
                                        std::string boot_id = {}) {
  return {.time_valid = true,
          .wall_utc_seconds = wall,
          .monotonic_seconds = monotonic,
          .boot_id = std::move(boot_id)};
}

dawn::RuntimeTickObservation invalid_tick(std::int64_t wall,
                                          std::int64_t monotonic) {
  return {.time_valid = false,
          .wall_utc_seconds = wall,
          .monotonic_seconds = monotonic,
          .boot_id = {}};
}

// Advances one tick whose result this test deliberately ignores.
void ignore_tick(dawn::AtomicScheduleStore &store,
                 dawn::RuntimeCoordinatorState &state,
                 const dawn::RuntimeTickObservation &observation) {
  static_cast<void>(run_runtime_tick(store, state, observation));
}

int start_alerts(const dawn::RuntimeTickResult &result) {
  int count = 0;
  for (const auto &effect : result.effects) {
    if (effect.start_alert) {
      ++count;
    }
  }
  return count;
}

int stop_alerts(const dawn::RuntimeTickResult &result) {
  int count = 0;
  for (const auto &effect : result.effects) {
    if (effect.stop_alert) {
      ++count;
    }
  }
  return count;
}

std::optional<dawn::RuntimeTickEffect>
effect_for(const dawn::RuntimeTickResult &result, std::string_view alarm_id) {
  for (const auto &effect : result.effects) {
    if (effect.alarm_id == alarm_id) {
      return effect;
    }
  }
  return std::nullopt;
}

bool has_terminal(const dawn::PersistentAlarmState &state,
                  std::string_view occurrence_id,
                  dawn::TerminalReason reason) {
  for (const auto &terminal : state.terminal) {
    if (terminal.occurrence_id == occurrence_id && terminal.reason == reason) {
      return true;
    }
  }
  return false;
}

void normal_tick_rings_once_then_suppresses() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 100'000}}), 0).status ==
             dawn::StoreStatus::stored,
         "fixture schedule is committed");
  dawn::RuntimeCoordinatorState state;

  const auto first = run_runtime_tick(store, state, valid_tick(100'000,
                                                               100'000));
  expect(first.status == dawn::RuntimeTickStatus::evaluated,
         "due tick evaluates");
  const auto ringing = effect_for(first, "wake");
  expect(ringing.has_value() &&
             ringing->status == dawn::EvaluationStatus::ringing &&
             ringing->start_alert &&
             ringing->stage == dawn::RuntimeEffectStage::evaluation,
         "due tick rings with a start edge from evaluation");
  expect(!first.reconciliation_attempted,
         "never-invalid stream never reconciles");

  const auto second = run_runtime_tick(store, state, valid_tick(100'060,
                                                                100'060));
  expect(second.status == dawn::RuntimeTickStatus::evaluated,
         "second tick evaluates");
  expect(start_alerts(second) == 0, "second tick starts no alert");
  const auto active = effect_for(second, "wake");
  expect(active.has_value() &&
             active->status == dawn::EvaluationStatus::ringing &&
             active->stage == dawn::RuntimeEffectStage::active_lifecycle,
         "active occurrence reports ringing without a second start edge");
}

void invalid_tick_freezes_without_store_access() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 200'000}}), 0).status ==
             dawn::StoreStatus::stored,
         "fixture schedule is committed");
  dawn::RuntimeCoordinatorState state;
  const int transactions_before = backend.transaction_count;
  const int writes_before = backend.write_count;

  const auto frozen = run_runtime_tick(store, state, invalid_tick(150'000,
                                                                  150'000));
  expect(frozen.status == dawn::RuntimeTickStatus::frozen_invalid_time,
         "invalid observation freezes");
  expect(frozen.effects.empty(), "frozen tick exposes no effects");
  expect(backend.transaction_count == transactions_before &&
             backend.write_count == writes_before,
         "frozen tick performs no store access");

  // The next valid tick must attempt reconciliation before admission.
  // The only occurrence is still in the future: nothing crossed.
  const auto resumed =
      run_runtime_tick(store, state, valid_tick(150'000, 150'000));
  expect(resumed.reconciliation_attempted,
         "valid tick after freeze attempts reconciliation");
  expect(resumed.reconciliation_status ==
             dawn::InvalidTimeRecoveryStatus::nothing_crossed,
         "uncrossed schedule reconciles with nothing crossed");

  const auto due = run_runtime_tick(store, state, valid_tick(200'060,
                                                             200'060));
  expect(!due.reconciliation_attempted,
         "cleared latch stops reconciliation");
  const auto ringing = effect_for(due, "wake");
  expect(ringing.has_value() && ringing->start_alert &&
             ringing->stage == dawn::RuntimeEffectStage::evaluation,
         "normal admission resumes after the latch clears");
}

void invalid_interval_reconciles_before_admission() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store
             .save(snapshot_with_alarms({{"old", 100'000},
                                         {"newest", 200'000}}),
                   0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");
  dawn::RuntimeCoordinatorState state;

  ignore_tick(store, state, invalid_tick(150'000, 150'000));

  // newest crossed 300 s ago (inside the 600 s grace), old crossed long
  // before: old journals an invalid_time miss, newest rings once late.
  const auto reconciled =
      run_runtime_tick(store, state, valid_tick(200'300, 200'300));
  expect(reconciled.status == dawn::RuntimeTickStatus::evaluated,
         "reconciliation tick evaluates");
  expect(reconciled.reconciliation_status ==
             dawn::InvalidTimeRecoveryStatus::reconciled,
         "crossed occurrences reconcile");
  expect(reconciled.reconciliation_crossed.size() == 2,
         "both crossed occurrences reported");
  const auto old = effect_for(reconciled, "old");
  const auto newest = effect_for(reconciled, "newest");
  expect(old.has_value() && old->status == dawn::EvaluationStatus::missed &&
             !old->start_alert &&
             old->stage == dawn::RuntimeEffectStage::reconciliation,
         "older crossed occurrence journals a miss with no edge");
  expect(newest.has_value() &&
             newest->status == dawn::EvaluationStatus::ringing &&
             newest->start_alert && newest->late &&
             newest->lateness_seconds == 300 &&
             newest->stage == dawn::RuntimeEffectStage::reconciliation,
         "newest crossed occurrence rings late within grace");
  expect(start_alerts(reconciled) == 1, "exactly one start edge per tick");

  expect(has_terminal(backend.persisted_state(), "old:1:100000",
                      dawn::TerminalReason::invalid_time),
         "older crossing carries the invalid_time reason");

  // The latch is cleared: the next tick resumes normal evaluation and the
  // reconciled ring continues without a second start edge.
  const int writes_after_reconcile = backend.write_count;
  const auto next = run_runtime_tick(store, state, valid_tick(200'400,
                                                              200'400));
  expect(!next.reconciliation_attempted,
         "latch cleared after reconciliation");
  expect(start_alerts(next) == 0, "no second start after reconciliation");
  const auto active = effect_for(next, "newest");
  expect(active.has_value() &&
             active->stage == dawn::RuntimeEffectStage::active_lifecycle,
         "reconciled ring advances through the active lifecycle");
  const auto suppressed = effect_for(next, "old");
  expect(suppressed.has_value() &&
             suppressed->status != dawn::EvaluationStatus::ringing &&
             !suppressed->start_alert,
         "journaled crossing is never re-admitted (conflict precedence "
         "while another occurrence is active)");
  expect(backend.write_count == writes_after_reconcile,
         "steady tick after reconciliation is write-free");
}

void active_occurrence_defers_then_reconciles_invalid_time() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store
             .save(snapshot_with_alarms({{"act", 100'000},
                                         {"old", 200'000}}),
                   0)
             .status == dawn::StoreStatus::stored,
         "fixture schedule is committed");
  dawn::RuntimeCoordinatorState state;

  // Ring act before the invalid interval begins.
  const auto rang =
      run_runtime_tick(store, state, valid_tick(100'000, 100'000));
  expect(start_alerts(rang) == 1, "act rings before the invalid interval");

  ignore_tick(store, state, invalid_tick(101'000, 101'000));

  // Active occurrence defers reconciliation; the active path keeps
  // settling and old is not journaled yet.
  const auto deferred =
      run_runtime_tick(store, state, valid_tick(302'000, 100'200));
  expect(deferred.reconciliation_status ==
             dawn::InvalidTimeRecoveryStatus::active_conflict,
         "active occurrence defers reconciliation");
  expect(deferred.status == dawn::RuntimeTickStatus::evaluated,
         "deferred tick is not an error");
  expect(!has_terminal(backend.persisted_state(), "old:1:200000",
                       dawn::TerminalReason::invalid_time),
         "deferred crossing is not journaled early");

  // Monotonic passes the 60-minute lifetime: act times out with a stop
  // edge, then the crossing journals an invalid_time miss in the same
  // tick, outside the late grace so nothing rings.
  const int writes_before = backend.write_count;
  const auto timeout =
      run_runtime_tick(store, state, valid_tick(303'700, 103'700));
  const auto timed_out = effect_for(timeout, "act");
  expect(timed_out.has_value() &&
             timed_out->status == dawn::EvaluationStatus::timed_out &&
             timed_out->stop_alert &&
             timed_out->stage == dawn::RuntimeEffectStage::active_lifecycle,
         "active occurrence times out with a stop edge");
  expect(timeout.reconciliation_status ==
             dawn::InvalidTimeRecoveryStatus::reconciled,
         "reconciliation lands once the occurrence ends");
  const auto old = effect_for(timeout, "old");
  expect(old.has_value() && old->status == dawn::EvaluationStatus::missed &&
             !old->start_alert,
         "deferred crossing misses without any surprise start edge");
  expect(has_terminal(backend.persisted_state(), "old:1:200000",
                      dawn::TerminalReason::invalid_time),
         "deferred crossing journals the invalid_time reason");
  expect(stop_alerts(timeout) == 1, "one stop edge for the timeout");
  expect(start_alerts(timeout) == 0, "no start edge after deferral");

  // Repeat reconciliation is write-free after the latch clears.
  const int writes_after = backend.write_count;
  expect(writes_after > writes_before, "timeout/reconcile wrote journal");
  const auto quiet =
      run_runtime_tick(store, state, valid_tick(304'000, 104'000));
  expect(!quiet.reconciliation_attempted, "latch cleared after reconcile");
  expect(backend.write_count == writes_after,
         "repeat pass after reconciliation is write-free");
}

void boot_gate_runs_recovery_once_per_boot() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 100'000}}), 0).status ==
             dawn::StoreStatus::stored,
         "fixture schedule is committed");

  // Ring with one coordinator, then discard its state to simulate reboot.
  dawn::RuntimeCoordinatorState first_boot;
  ignore_tick(store, first_boot, valid_tick(100'000, 50));
  dawn::RuntimeCoordinatorState state;

  // Wall lifetime is measured from the first ring (100'000), so recovery
  // stays inside the 60-minute window while the boot monotonic clock
  // restarts near zero.
  const auto resumed =
      run_runtime_tick(store, state, valid_tick(100'600, 10, "boot-1"));
  const auto recovery = effect_for(resumed, "wake");
  expect(recovery.has_value() && recovery->start_alert &&
             recovery->recovered_after_reboot &&
             recovery->stage == dawn::RuntimeEffectStage::active_lifecycle,
         "first tick with a new boot id resumes the ring once");
  expect(start_alerts(resumed) == 1,
         "recovery exposes exactly one start edge for the tick");

  const auto same_boot =
      run_runtime_tick(store, state, valid_tick(1'000'900, 300, "boot-1"));
  expect(start_alerts(same_boot) == 0,
         "later ticks in the same boot never re-recover");
  const auto still_ringing = effect_for(same_boot, "wake");
  expect(still_ringing.has_value() &&
             still_ringing->status == dawn::EvaluationStatus::ringing,
         "same-boot tick advances the occurrence monotonically");

  const auto next_boot =
      run_runtime_tick(store, state, valid_tick(101'200, 10, "boot-2"));
  const auto recovery2 = effect_for(next_boot, "wake");
  expect(recovery2.has_value() && recovery2->start_alert &&
             recovery2->recovered_after_reboot,
         "a new boot id resumes recovery once again");
  const auto same_boot2 =
      run_runtime_tick(store, state, valid_tick(101'500, 300, "boot-2"));
  expect(start_alerts(same_boot2) == 0,
         "recovery does not repeat within the second boot");
}

void boot_with_pending_invalid_interval_recovers_then_defers() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"act", 100'000}}), 0).status ==
             dawn::StoreStatus::stored,
         "fixture schedule is committed");
  dawn::RuntimeCoordinatorState first;
  ignore_tick(store, first, valid_tick(100'000, 100'000));

  // Simulated reboot: fresh state with the reset cause known (time was
  // absent), active occurrence persisted in the store. The monotonic
  // clock restarts with the boot.
  dawn::RuntimeCoordinatorState rebooted;
  rebooted.reconciliation_pending = true;
  const auto resumed =
      run_runtime_tick(store, rebooted, valid_tick(101'800, 10, "boot-2"));
  const auto recovery = effect_for(resumed, "act");
  expect(recovery.has_value() && recovery->start_alert &&
             recovery->recovered_after_reboot &&
             recovery->stage == dawn::RuntimeEffectStage::active_lifecycle,
         "boot recovery resumes before touching reconciliation");
  expect(rebooted.last_handled_boot_id == "boot-2",
         "boot gate consumed after recovery settles");
  expect(rebooted.reconciliation_pending,
         "active occurrence keeps the reconciliation latch");
  expect(resumed.reconciliation_status ==
             dawn::InvalidTimeRecoveryStatus::active_conflict,
         "reconciliation defers while the recovered ring is active");

  // Monotonic lifetime expires after the reboot: stop edge, then the
  // latch clears with nothing crossed.
  const auto ended =
      run_runtime_tick(store, rebooted, valid_tick(105'600, 3'700, "boot-2"));
  const auto timed_out = effect_for(ended, "act");
  expect(timed_out.has_value() &&
             timed_out->status == dawn::EvaluationStatus::timed_out &&
             timed_out->stop_alert,
         "post-recovery occurrence times out on the rebooted monotonic "
         "clock");
  expect(ended.reconciliation_status ==
             dawn::InvalidTimeRecoveryStatus::nothing_crossed,
         "latch clears once the deferral resolves");
  expect(!rebooted.reconciliation_pending, "latch is cleared");

  const auto settled =
      run_runtime_tick(store, rebooted, valid_tick(106'000, 4'100, "boot-2"));
  expect(!settled.reconciliation_attempted,
         "cleared latch stops reconciliation");
}

void io_error_leaves_latch_and_boot_gate_retryable() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 100'000}}), 0).status ==
             dawn::StoreStatus::stored,
         "fixture schedule is committed");
  dawn::RuntimeCoordinatorState first;
  ignore_tick(store, first, valid_tick(100'000, 100'000));

  dawn::RuntimeCoordinatorState state;
  state.reconciliation_pending = true;
  backend.fail_reads = true;
  const auto failed =
      run_runtime_tick(store, state, valid_tick(100'600, 100'600, "boot-1"));
  expect(failed.status == dawn::RuntimeTickStatus::io_error,
         "read failure surfaces as io_error");
  expect(start_alerts(failed) == 0, "io_error exposes no edges");

  backend.fail_reads = false;
  const auto retried =
      run_runtime_tick(store, state, valid_tick(100'700, 100'700, "boot-1"));
  const auto recovery = effect_for(retried, "wake");
  expect(recovery.has_value() && recovery->start_alert &&
             recovery->recovered_after_reboot,
         "retry after io_error still runs the boot-gated recovery");
}

void never_invalid_stream_keeps_forward_jump_and_empty_store_passes() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  dawn::RuntimeCoordinatorState empty_state;
  const auto empty =
      run_runtime_tick(store, empty_state, valid_tick(100'000, 100'000));
  expect(empty.status == dawn::RuntimeTickStatus::empty_store,
         "empty store passes through");
  expect(!empty.reconciliation_attempted, "empty store never reconciles");

  expect(store.save(snapshot_with_alarms({{"late", 100'000}}), 0).status ==
             dawn::StoreStatus::stored,
         "fixture schedule is committed");
  dawn::RuntimeCoordinatorState state;
  const auto jumped =
      run_runtime_tick(store, state, valid_tick(101'200, 101'200));
  const auto missed = effect_for(jumped, "late");
  expect(missed.has_value() &&
             missed->status == dawn::EvaluationStatus::missed,
         "crossed occurrence beyond grace misses via the evaluator");
  expect(!jumped.reconciliation_attempted,
         "never-invalid stream never reconciles");
  expect(has_terminal(backend.persisted_state(), "late:1:100000",
                      dawn::TerminalReason::forward_jump),
         "forward-jump reason is preserved for never-invalid streams");
}

void write_failure_suppresses_effects_stays_retryable() {
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(snapshot_with_alarms({{"wake", 100'000}}), 0).status ==
             dawn::StoreStatus::stored,
         "fixture schedule is committed");
  dawn::RuntimeCoordinatorState state;
  backend.fail_writes = true;
  const auto failed =
      run_runtime_tick(store, state, valid_tick(100'000, 100'000));
  expect(failed.status == dawn::RuntimeTickStatus::persistence_error,
         "write failure surfaces as persistence_error");
  expect(start_alerts(failed) == 0, "write failure exposes no start edge");

  backend.fail_writes = false;
  const auto retried =
      run_runtime_tick(store, state, valid_tick(100'060, 100'060));
  const auto ringing = effect_for(retried, "wake");
  expect(ringing.has_value() && ringing->start_alert,
         "retry after write failure lands the ring once");
}

} // namespace

int main() {
  normal_tick_rings_once_then_suppresses();
  invalid_tick_freezes_without_store_access();
  invalid_interval_reconciles_before_admission();
  active_occurrence_defers_then_reconciles_invalid_time();
  boot_gate_runs_recovery_once_per_boot();
  boot_with_pending_invalid_interval_recovers_then_defers();
  io_error_leaves_latch_and_boot_gate_retryable();
  never_invalid_stream_keeps_forward_jump_and_empty_store_passes();
  write_failure_suppresses_effects_stays_retryable();

  if (failures != 0) {
    std::cerr << failures << " runtime coordinator checks failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "runtime coordinator checks passed\n";
  return EXIT_SUCCESS;
}
