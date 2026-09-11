#include "dawn/invalid_time_recovery.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <utility>

namespace {

bool checked_elapsed(std::int64_t now, std::int64_t start,
                     std::int64_t &elapsed) {
  if (now < start ||
      (start < 0 && now > std::numeric_limits<std::int64_t>::max() + start)) {
    return false;
  }
  elapsed = now - start;
  return true;
}

bool is_conflict(dawn::StoreStatus status) {
  return status == dawn::StoreStatus::revision_conflict ||
         status == dawn::StoreStatus::generation_conflict;
}

bool is_terminal(const dawn::PersistentAlarmState &state,
                 const std::string &occurrence_id) {
  return std::any_of(state.terminal.begin(), state.terminal.end(),
                     [&occurrence_id](const dawn::TerminalOccurrence &terminal) {
                       return terminal.occurrence_id == occurrence_id;
                     });
}

bool at_or_below_watermark(const dawn::PersistentAlarmState &state,
                           const std::string &alarm_id,
                           std::int64_t scheduled_utc_seconds) {
  const auto watermark = std::find_if(
      state.terminal_high_watermarks.begin(),
      state.terminal_high_watermarks.end(),
      [&alarm_id](const dawn::TerminalHighWatermark &candidate) {
        return candidate.alarm_id == alarm_id;
      });
  return watermark != state.terminal_high_watermarks.end() &&
         scheduled_utc_seconds <= watermark->scheduled_utc_seconds;
}

} // namespace

namespace dawn {

InvalidTimeRecoveryResult reconcile_after_time_valid(
    AtomicScheduleStore &store, std::int64_t wall_utc_seconds,
    std::int64_t monotonic_seconds, bool time_valid) {
  InvalidTimeRecoveryResult result;
  if (!time_valid) {
    result.status = InvalidTimeRecoveryStatus::invalid_time;
    return result;
  }

  const auto loaded = store.load();
  if (loaded.status == LoadStatus::io_error) {
    result.status = InvalidTimeRecoveryStatus::io_error;
    return result;
  }
  if (loaded.status != LoadStatus::loaded) {
    result.status = loaded.status == LoadStatus::empty
                        ? InvalidTimeRecoveryStatus::empty_store
                        : InvalidTimeRecoveryStatus::invalid_store;
    return result;
  }

  result.schedule_revision = loaded.snapshot.revision;
  result.generation = loaded.generation;
  const auto &stored_state = loaded.snapshot.occurrence_state;
  if (stored_state.active) {
    // An active occurrence is owned by the reboot-recovery / advance-active
    // path; reconciliation must not steal or double-admit it.
    result.status = InvalidTimeRecoveryStatus::active_conflict;
    return result;
  }

  struct CrossedCandidate {
    std::string alarm_id;
    std::string occurrence_id;
    std::int64_t scheduled_utc_seconds{};
    std::int64_t lateness_seconds{};
  };
  std::vector<CrossedCandidate> crossed;
  for (const auto &alarm : loaded.snapshot.alarms) {
    if (!alarm.enabled || alarm.scheduled_utc_seconds > wall_utc_seconds) {
      continue;
    }
    const AlarmDefinition definition{
        .id = alarm.id,
        .schedule_revision = alarm.schedule_revision,
        .enabled = alarm.enabled,
        .scheduled_utc_seconds = alarm.scheduled_utc_seconds,
    };
    const auto occurrence_id = make_occurrence_id(definition);
    if (is_terminal(stored_state, occurrence_id) ||
        at_or_below_watermark(stored_state, alarm.id,
                              alarm.scheduled_utc_seconds)) {
      continue;
    }
    crossed.push_back({alarm.id, std::move(occurrence_id),
                       alarm.scheduled_utc_seconds, 0});
  }

  if (crossed.empty()) {
    result.status = InvalidTimeRecoveryStatus::nothing_crossed;
    return result;
  }

  std::sort(crossed.begin(), crossed.end(),
            [](const CrossedCandidate &left, const CrossedCandidate &right) {
              if (left.scheduled_utc_seconds != right.scheduled_utc_seconds) {
                return left.scheduled_utc_seconds < right.scheduled_utc_seconds;
              }
              return left.alarm_id < right.alarm_id;
            });

  // The newest crossed occurrence is the one with the largest (and so the
  // smallest-lateness) scheduled instant; if even its lateness cannot be
  // represented, the wall reading itself is untrustworthy.
  auto &newest = crossed.back();
  if (!checked_elapsed(wall_utc_seconds, newest.scheduled_utc_seconds,
                       newest.lateness_seconds)) {
    crossed.clear();
    result.status = InvalidTimeRecoveryStatus::invalid_time;
    return result;
  }

  const bool newest_rings = newest.lateness_seconds <= kLateGraceSeconds;

  // Fail closed on journal capacity before any mutation: simulate the
  // whole batch on a copy so a mid-batch capacity failure can never leave
  // a partially journaled reconciliation.
  auto journal = stored_state;
  for (auto &candidate : crossed) {
    const bool rings = &candidate == &newest && newest_rings;
    if (rings) {
      if (!journal_can_accept(journal, candidate.alarm_id)) {
        crossed.clear();
        result.status = InvalidTimeRecoveryStatus::journal_capacity;
        return result;
      }
      continue;
    }
    if (!journal_terminal(journal, candidate.alarm_id,
                          candidate.occurrence_id,
                          candidate.scheduled_utc_seconds,
                          TerminalReason::invalid_time)) {
      crossed.clear();
      result.status = InvalidTimeRecoveryStatus::journal_capacity;
      return result;
    }
  }
  if (newest_rings) {
    // Older missed entries may consume the final watermark slot, so the
    // ring admission is re-checked here while the journal is still a local
    // copy; failure leaves nothing persisted.
    if (!begin_recovered_ring(journal, newest.alarm_id,
                              newest.occurrence_id,
                              newest.scheduled_utc_seconds,
                              wall_utc_seconds, monotonic_seconds)) {
      crossed.clear();
      result.status = InvalidTimeRecoveryStatus::journal_capacity;
      return result;
    }
  }

  for (const auto &candidate : crossed) {
    RecoveredOccurrence record;
    record.alarm_id = candidate.alarm_id;
    record.occurrence_id = candidate.occurrence_id;
    const bool rings = &candidate == &newest && newest_rings;
    record.outcome = rings ? EvaluationStatus::ringing
                           : EvaluationStatus::missed;
    record.lateness_seconds =
        rings || &candidate == &newest ? candidate.lateness_seconds : 0;
    result.crossed.push_back(std::move(record));
  }

  // The complete batch commits through one runtime-journal CAS before any
  // alert effect is exposed.
  const auto committed = store.save_occurrence_state(
      journal, loaded.snapshot.revision, loaded.generation);
  result.generation = committed.generation;
  if (committed.status != StoreStatus::stored &&
      committed.status != StoreStatus::unchanged) {
    result.crossed.clear();
    result.status =
        is_conflict(committed.status)
            ? InvalidTimeRecoveryStatus::persistence_conflict
            : InvalidTimeRecoveryStatus::persistence_error;
    return result;
  }

  result.status = InvalidTimeRecoveryStatus::reconciled;
  result.journal_committed = true;
  if (newest_rings) {
    result.start_alert = true;
    result.ringing_occurrence_id = newest.occurrence_id;
  }
  return result;
}

} // namespace dawn
