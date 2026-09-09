#include "dawn/committed_alarm_disable.hpp"

#include <algorithm>
#include <utility>

namespace {

bool is_conflict(dawn::StoreStatus status) {
  return status == dawn::StoreStatus::revision_conflict ||
         status == dawn::StoreStatus::generation_conflict;
}

} // namespace

namespace dawn {

CommittedAlarmDisableResult disable_committed_alarm(
    AtomicScheduleStore &store, const std::string &alarm_id) {
  CommittedAlarmDisableResult result;

  const auto loaded = store.load();
  if (loaded.status == LoadStatus::io_error) {
    result.status = CommittedDisableStatus::io_error;
    return result;
  }
  if (loaded.status != LoadStatus::loaded) {
    result.status = loaded.status == LoadStatus::empty
                        ? CommittedDisableStatus::empty_store
                        : CommittedDisableStatus::invalid_store;
    return result;
  }

  result.schedule_revision = loaded.snapshot.revision;
  result.generation = loaded.generation;

  const auto target = std::find_if(loaded.snapshot.alarms.begin(),
                                   loaded.snapshot.alarms.end(),
                                   [&alarm_id](const StoredAlarmDefinition &alarm) {
                                     return alarm.id == alarm_id;
                                   });
  if (target == loaded.snapshot.alarms.end()) {
    result.status = CommittedDisableStatus::alarm_not_found;
    return result;
  }

  const bool has_matching_active = loaded.snapshot.occurrence_state.active &&
                                   loaded.snapshot.occurrence_state.active->alarm_id == alarm_id;

  // Phase 1: confirmed dismiss. The terminal record must be durable through
  // the runtime-journal CAS before any alert stop effect is exposed, and
  // before the definition change may be considered.
  if (has_matching_active) {
    auto occurrence_state = loaded.snapshot.occurrence_state;
    result.occurrence_id = occurrence_state.active->occurrence_id;
    const auto dismissed =
        dismiss_active(occurrence_state, result.occurrence_id, true);
    if (!dismissed.persist_before_effects || !dismissed.stop_alert) {
      result.status = CommittedDisableStatus::persistence_error;
      return result;
    }

    const auto committed = store.save_occurrence_state(
        occurrence_state, loaded.snapshot.revision, loaded.generation);
    result.generation = committed.generation;
    if (committed.status != StoreStatus::stored &&
        committed.status != StoreStatus::unchanged) {
      result.status = is_conflict(committed.status)
                          ? CommittedDisableStatus::persistence_conflict
                          : CommittedDisableStatus::persistence_error;
      // Phase 1 failed: neither the stop effect nor the definition change
      // may be exposed. The occurrence remains active and retryable.
      result.stop_alert = false;
      return result;
    }
    result.journal_committed = true;
    // The dismiss record is durable; exposing the stop effect is now safe.
    result.stop_alert = true;
  }

  // Phase 2: definition change. save() reloads and carries the current
  // occurrence journal forward, so this write never erases another alarm's
  // runtime state (including a phase-1 dismiss committed moments ago).
  if (!target->enabled) {
    // Nothing to persist for the definition. Without a phase-1 dismiss this
    // is a no-op request; with one, the end state is already disabled.
    result.status =
        result.journal_committed
            ? CommittedDisableStatus::disabled
            : CommittedDisableStatus::already_disabled;
    return result;
  }

  ScheduleSnapshot disabled_snapshot = loaded.snapshot;
  for (auto &alarm : disabled_snapshot.alarms) {
    if (alarm.id == alarm_id) {
      alarm.enabled = false;
    }
  }
  disabled_snapshot.revision = loaded.snapshot.revision + 1U;
  if (disabled_snapshot.revision == 0U) {
    result.status = CommittedDisableStatus::persistence_error;
    return result;
  }

  const auto committed =
      store.save(disabled_snapshot, loaded.snapshot.revision);
  result.generation = committed.generation;
  if (committed.status == StoreStatus::stored ||
      committed.status == StoreStatus::unchanged) {
    result.definition_committed = true;
    result.schedule_revision = disabled_snapshot.revision;
    result.status = CommittedDisableStatus::disabled;
    return result;
  }
  // The definition change did not land. A phase-1 dismiss remains durable,
  // so the report is honest: journal committed, definition pending.
  result.status = is_conflict(committed.status)
                      ? CommittedDisableStatus::persistence_conflict
                      : CommittedDisableStatus::persistence_error;
  return result;
}

} // namespace dawn
