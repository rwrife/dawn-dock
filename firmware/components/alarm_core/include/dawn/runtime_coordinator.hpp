#pragma once

#include "dawn/committed_schedule_evaluator.hpp"
#include "dawn/invalid_time_recovery.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace dawn {

// One observation feeding a single coordinator tick. `time_valid` is the
// caller's RTC-validity verdict; `wall_utc_seconds` and
// `monotonic_seconds` are the clock readings defined in
// docs/alarm-semantics.md; `boot_id` is the current boot's identifier,
// stable for the whole boot and different after every reset (empty means
// "no boot-recovery pass is requested for this tick").
struct RuntimeTickObservation {
  bool time_valid{};
  std::int64_t wall_utc_seconds{};
  std::int64_t monotonic_seconds{};
  std::string boot_id;
};

// Caller-owned coordinator state. A fresh boot starts with an empty
// `last_handled_boot_id` so the first valid-time tick carrying the new boot
// ID runs the reboot-recovery path. `reconciliation_pending` may be set
// before the first tick when the device knows time was absent (for example
// an RTC-invalid reset cause), which defers all admission until the
// invalid-interval reconciliation succeeds. Both fields are plain data so
// host tests and firmware agree on the exact policy state.
struct RuntimeCoordinatorState {
  std::string last_handled_boot_id;
  bool reconciliation_pending{};
};

enum class RuntimeTickStatus {
  // The tick completed a state-settling pass (evaluation, boot-gated
  // recovery, and/or reconciliation) with no unresolved failure.
  evaluated,
  // The observation reported invalid time, or the settled pass itself
  // encountered unrepresentable time arithmetic. No store access happens
  // while an observation reports invalid time, and scheduled transitions
  // stay frozen until time becomes valid again.
  frozen_invalid_time,
  // An invalid-interval reconciliation is still owed but could not run:
  // the reconciliation failed closed for a non-storage reason
  // (unrepresentable lateness or terminal-journal capacity). The latch
  // stays armed and every later valid tick retries.
  reconciliation_blocked,
  empty_store,
  invalid_store,
  io_error,
  // A compare-and-set lost against a concurrent commit. Nothing was
  // exposed for the failed stage; the tick is retryable.
  persistence_conflict,
  // A storage write or verification failed. Alert edges produced by an
  // earlier successful stage of the same tick remain visible.
  persistence_error,
};

enum class RuntimeEffectStage {
  // Result of the normal committed evaluation (due admission or the active
  // lifecycle inside the evaluator).
  evaluation,
  // Result of the coordinator's own boot-gated or deferral active settle.
  active_lifecycle,
  // Result of an invalid-interval reconciliation pass.
  reconciliation,
};

// One durable-then-visible transition from this tick, aggregated across
// stages. An effect is present only when its journal already committed
// through the corresponding stage's CAS; alert edges obey
// commit-before-effect exactly as in the underlying stages. At most one
// `start_alert` can appear per tick because reconciliation defers while
// any occurrence is active, and admission is suppressed while a latch is
// pending.
struct RuntimeTickEffect {
  std::string alarm_id;
  std::string occurrence_id;
  EvaluationStatus status{EvaluationStatus::armed};
  bool start_alert{};
  bool stop_alert{};
  bool late{};
  std::int64_t lateness_seconds{};
  bool recovered_after_reboot{};
  RuntimeEffectStage stage{RuntimeEffectStage::evaluation};
};

struct RuntimeTickResult {
  RuntimeTickStatus status{RuntimeTickStatus::evaluated};
  std::uint64_t schedule_revision{};
  std::uint64_t generation{};
  // Diagnostics for the invalid-interval stage of this tick.
  bool reconciliation_attempted{};
  InvalidTimeRecoveryStatus reconciliation_status{
      InvalidTimeRecoveryStatus::nothing_crossed};
  std::vector<RecoveredOccurrence> reconciliation_crossed;
  std::vector<RuntimeTickEffect> effects;
};

// Runs one runtime tick, composing the existing host-tested stages into
// the end-to-end order mandated by docs/alarm-semantics.md:
//
// 1. Invalid observations freeze scheduled transitions: no store access,
//    and the invalid-interval latch arms so the eventual valid tick
//    reconciles before any admission can misclassify crossed occurrences.
// 2. While the latch is pending, admission is never run. The coordinator
//    instead settles a persisted active occurrence (boot-gated recovery on
//    the first valid tick carrying a new boot ID, monotonic advance
//    otherwise) and then runs the invalid-interval reconciliation. Only a
//    `reconciled` or `nothing_crossed` result clears the latch;
//    `active_conflict` defers the reconciliation to a later tick while the
//    active path keeps settling, and every other failure leaves the latch
//    armed and retryable.
// 3. When the latch is clear, one committed evaluation pass runs. On the
//    first valid tick carrying a new boot ID the evaluation is
//    boot-gated so the evaluator's reboot-recovery path executes before
//    due admission; later ticks pass an empty boot ID so the active
//    lifecycle advances monotonically and recovery never repeats.
//
// The coordinator performs no I/O beyond the injected store and holds no
// globals; all policy state lives in `state`. Host-software evidence only:
// on-device RTC validity, boot identification, and scheduling of this
// loop remain open target work.
[[nodiscard]] RuntimeTickResult run_runtime_tick(
    AtomicScheduleStore &store, RuntimeCoordinatorState &state,
    const RuntimeTickObservation &observation);

} // namespace dawn
