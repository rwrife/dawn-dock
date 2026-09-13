#include "dawn/runtime_coordinator.hpp"

#include "dawn/alarm_engine.hpp"

#include <utility>

namespace dawn {
namespace {

RuntimeTickStatus status_from_evaluation(CommittedEvaluationStatus status) {
  switch (status) {
  case CommittedEvaluationStatus::evaluated:
    return RuntimeTickStatus::evaluated;
  case CommittedEvaluationStatus::invalid_time:
    return RuntimeTickStatus::frozen_invalid_time;
  case CommittedEvaluationStatus::empty_store:
    return RuntimeTickStatus::empty_store;
  case CommittedEvaluationStatus::invalid_store:
    return RuntimeTickStatus::invalid_store;
  case CommittedEvaluationStatus::io_error:
    return RuntimeTickStatus::io_error;
  case CommittedEvaluationStatus::persistence_conflict:
    return RuntimeTickStatus::persistence_conflict;
  case CommittedEvaluationStatus::persistence_error:
    return RuntimeTickStatus::persistence_error;
  }
  return RuntimeTickStatus::persistence_error;
}

// Maps a reconciliation outcome onto the coordinator result. Only a
// settled reconciliation (reconciled / nothing_crossed) clears the
// caller's latch; deferrals and failures keep it armed for a later tick.
void apply_reconciliation_outcome(const InvalidTimeRecoveryResult &recovery,
                                  RuntimeTickResult &result) {
  result.reconciliation_status = recovery.status;
  result.reconciliation_crossed = recovery.crossed;
  result.generation = recovery.generation;
  switch (recovery.status) {
  case InvalidTimeRecoveryStatus::reconciled:
    for (const auto &crossed : recovery.crossed) {
      RuntimeTickEffect effect;
      effect.alarm_id = crossed.alarm_id;
      effect.occurrence_id = crossed.occurrence_id;
      effect.status = crossed.outcome;
      effect.stage = RuntimeEffectStage::reconciliation;
      if (recovery.start_alert &&
          crossed.occurrence_id == recovery.ringing_occurrence_id) {
        effect.start_alert = true;
        effect.late = crossed.lateness_seconds > 0;
        effect.lateness_seconds = crossed.lateness_seconds;
      }
      result.effects.push_back(std::move(effect));
    }
    result.status = RuntimeTickStatus::evaluated;
    break;
  case InvalidTimeRecoveryStatus::nothing_crossed:
    result.status = RuntimeTickStatus::evaluated;
    break;
  case InvalidTimeRecoveryStatus::invalid_time:
  case InvalidTimeRecoveryStatus::journal_capacity:
    result.status = RuntimeTickStatus::reconciliation_blocked;
    break;
  case InvalidTimeRecoveryStatus::active_conflict:
    // The active lifecycle keeps settling on later ticks; the latch
    // remains armed so reconciliation retries once the occurrence ends.
    result.status = RuntimeTickStatus::evaluated;
    break;
  case InvalidTimeRecoveryStatus::empty_store:
    result.status = RuntimeTickStatus::empty_store;
    break;
  case InvalidTimeRecoveryStatus::invalid_store:
    result.status = RuntimeTickStatus::invalid_store;
    break;
  case InvalidTimeRecoveryStatus::io_error:
    result.status = RuntimeTickStatus::io_error;
    break;
  case InvalidTimeRecoveryStatus::persistence_conflict:
    result.status = RuntimeTickStatus::persistence_conflict;
    break;
  case InvalidTimeRecoveryStatus::persistence_error:
    result.status = RuntimeTickStatus::persistence_error;
    break;
  }
}

bool reconciliation_clears_latch(const InvalidTimeRecoveryResult &recovery) {
  return recovery.status == InvalidTimeRecoveryStatus::reconciled ||
         recovery.status == InvalidTimeRecoveryStatus::nothing_crossed;
}

enum class SettleStage { settled, frozen, failed };

// Settles a persisted active occurrence for this tick: boot-gated
// recovery on the first valid tick carrying a new boot ID, monotonic
// advance otherwise. Any resulting journal transition commits through the
// runtime CAS before its effect is exposed.
//
// When boot-gated recovery resumes the ring, the occurrence's monotonic
// interval anchor is translated into the rebooted monotonic domain: the
// anchor becomes (current monotonic - wall elapsed since first ring), so
// the frozen 60-minute occurrence lifetime keeps expiring at the original
// wall deadline while snooze intervals stay monotonic-controlled. Without
// the translation the pre-boot anchor would sit in a dead clock domain
// (monotonic restarts at boot) and every later advance would fail closed.
SettleStage settle_active_occurrence(
    AtomicScheduleStore &store, PersistentAlarmState &occurrence_state,
    const RuntimeTickObservation &observation, bool boot_pending,
    std::uint64_t revision, std::uint64_t generation,
    RuntimeTickResult &result) {
  if (!occurrence_state.active) {
    return SettleStage::settled;
  }
  const std::string active_alarm_id = occurrence_state.active->alarm_id;
  const EvaluationResult settle =
      boot_pending ? recover_after_reboot(occurrence_state,
                                          observation.wall_utc_seconds,
                                          observation.boot_id)
                   : advance_active(occurrence_state,
                                    observation.monotonic_seconds);
  if (settle.status == EvaluationStatus::invalid_time) {
    result.status = RuntimeTickStatus::frozen_invalid_time;
    return SettleStage::frozen;
  }
  if (boot_pending && occurrence_state.active) {
    // A resumed occurrence is bounded by recover_after_reboot's wall
    // check, so this elapsed value is representable and below the
    // occurrence lifetime.
    const std::int64_t wall_elapsed_since_ring =
        observation.wall_utc_seconds -
        occurrence_state.active->first_ring_utc_seconds;
    occurrence_state.active->first_ring_monotonic_seconds =
        observation.monotonic_seconds - wall_elapsed_since_ring;
  }
  if (settle.persist_before_effects) {
    const auto committed = store.save_occurrence_state(
        occurrence_state, revision, generation);
    if (committed.status != StoreStatus::stored &&
        committed.status != StoreStatus::unchanged) {
      result.status =
          committed.status == StoreStatus::revision_conflict ||
                                  committed.status ==
                                      StoreStatus::generation_conflict
              ? RuntimeTickStatus::persistence_conflict
              : RuntimeTickStatus::persistence_error;
      return SettleStage::failed;
    }
    result.generation = committed.generation;
  }
  RuntimeTickEffect effect;
  effect.alarm_id = active_alarm_id;
  effect.occurrence_id = settle.occurrence_id;
  effect.status = settle.status;
  effect.start_alert = settle.start_alert;
  effect.stop_alert = settle.stop_alert;
  effect.recovered_after_reboot = settle.recovered_after_reboot;
  effect.stage = RuntimeEffectStage::active_lifecycle;
  result.effects.push_back(std::move(effect));
  return SettleStage::settled;
}

} // namespace

RuntimeTickResult run_runtime_tick(AtomicScheduleStore &store,
                                   RuntimeCoordinatorState &state,
                                   const RuntimeTickObservation &observation) {
  RuntimeTickResult result;

  if (!observation.time_valid) {
    // Frozen: scheduled transitions stop, the store is untouched, and the
    // eventual valid-time tick must reconcile the whole invalid interval
    // before any admission can misclassify crossed occurrences.
    state.reconciliation_pending = true;
    result.status = RuntimeTickStatus::frozen_invalid_time;
    return result;
  }

  const bool boot_pending = !observation.boot_id.empty() &&
                            state.last_handled_boot_id != observation.boot_id;

  if (state.reconciliation_pending) {
    result.reconciliation_attempted = true;
    const auto loaded = store.load();
    if (loaded.status == LoadStatus::io_error) {
      result.status = RuntimeTickStatus::io_error;
      return result;
    }
    if (loaded.status != LoadStatus::loaded) {
      result.status = loaded.status == LoadStatus::empty
                          ? RuntimeTickStatus::empty_store
                          : RuntimeTickStatus::invalid_store;
      return result;
    }

    result.schedule_revision = loaded.snapshot.revision;
    result.generation = loaded.generation;

    auto occurrence_state = loaded.snapshot.occurrence_state;
    const auto settle =
        settle_active_occurrence(store, occurrence_state, observation,
                                 boot_pending, loaded.snapshot.revision,
                                 loaded.generation, result);
    if (settle == SettleStage::frozen || settle == SettleStage::failed) {
      return result;
    }
    if (boot_pending) {
      state.last_handled_boot_id = observation.boot_id;
    }

    const auto recovery = reconcile_after_time_valid(
        store, observation.wall_utc_seconds, observation.monotonic_seconds);
    apply_reconciliation_outcome(recovery, result);
    if (reconciliation_clears_latch(recovery)) {
      state.reconciliation_pending = false;
    }
    return result;
  }

  if (boot_pending) {
    const auto loaded = store.load();
    if (loaded.status == LoadStatus::io_error) {
      result.status = RuntimeTickStatus::io_error;
      return result;
    }
    if (loaded.status != LoadStatus::loaded) {
      result.status = loaded.status == LoadStatus::empty
                          ? RuntimeTickStatus::empty_store
                          : RuntimeTickStatus::invalid_store;
      return result;
    }
    result.schedule_revision = loaded.snapshot.revision;
    result.generation = loaded.generation;
    auto occurrence_state = loaded.snapshot.occurrence_state;
    const auto settle =
        settle_active_occurrence(store, occurrence_state, observation,
                                 /*boot_pending=*/true,
                                 loaded.snapshot.revision, loaded.generation,
                                 result);
    if (settle == SettleStage::frozen || settle == SettleStage::failed) {
      return result;
    }
    state.last_handled_boot_id = observation.boot_id;
  }

  const auto evaluation = evaluate_committed_schedule(
      store, observation.wall_utc_seconds, observation.monotonic_seconds,
      /*time_valid=*/true, /*boot_id=*/"");
  result.status = status_from_evaluation(evaluation.status);
  result.schedule_revision = evaluation.schedule_revision;
  result.generation = evaluation.generation;
  for (const auto &alarm : evaluation.alarms) {
    RuntimeTickEffect effect;
    effect.alarm_id = alarm.alarm_id;
    effect.occurrence_id = alarm.result.occurrence_id;
    effect.status = alarm.result.status;
    effect.start_alert = alarm.result.start_alert;
    effect.stop_alert = alarm.result.stop_alert;
    effect.late = alarm.result.late;
    effect.lateness_seconds = alarm.result.lateness_seconds;
    effect.recovered_after_reboot = alarm.result.recovered_after_reboot;
    effect.stage =
        alarm.from_active_occurrence ? RuntimeEffectStage::active_lifecycle
                                     : RuntimeEffectStage::evaluation;
    result.effects.push_back(std::move(effect));
  }
  return result;
}

} // namespace dawn
