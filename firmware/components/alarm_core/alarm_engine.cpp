#include "dawn/alarm_engine.hpp"

#include <algorithm>
#include <limits>
#include <utility>

namespace dawn {
namespace {

bool checked_add(std::int64_t left, std::int64_t right, std::int64_t& result) {
  if ((right > 0 && left > std::numeric_limits<std::int64_t>::max() - right) ||
      (right < 0 && left < std::numeric_limits<std::int64_t>::min() - right)) {
    return false;
  }
  result = left + right;
  return true;
}

bool checked_elapsed(std::int64_t now, std::int64_t start,
                     std::int64_t& elapsed) {
  if (now < start ||
      (start < 0 && now > std::numeric_limits<std::int64_t>::max() + start)) {
    return false;
  }
  elapsed = now - start;
  return true;
}

EvaluationResult invalid_time_result(const std::string& occurrence_id = {}) {
  EvaluationResult result;
  result.status = EvaluationStatus::invalid_time;
  result.occurrence_id = occurrence_id;
  return result;
}

auto find_high_watermark(PersistentAlarmState& state,
                         const std::string& alarm_id) {
  return std::find_if(
      state.terminal_high_watermarks.begin(),
      state.terminal_high_watermarks.end(),
      [&alarm_id](const TerminalHighWatermark& watermark) {
        return watermark.alarm_id == alarm_id;
      });
}

bool can_track_terminal(const PersistentAlarmState& state,
                        const std::string& alarm_id) {
  return std::any_of(
             state.terminal_high_watermarks.begin(),
             state.terminal_high_watermarks.end(),
             [&alarm_id](const TerminalHighWatermark& watermark) {
               return watermark.alarm_id == alarm_id;
             }) ||
         state.terminal_high_watermarks.size() <
             kTerminalHighWatermarkCapacity;
}

void record_terminal_high_watermark(PersistentAlarmState& state,
                                    const std::string& alarm_id,
                                    std::int64_t scheduled_utc_seconds) {
  auto existing = find_high_watermark(state, alarm_id);
  if (existing == state.terminal_high_watermarks.end()) {
    state.terminal_high_watermarks.push_back(
        {alarm_id, scheduled_utc_seconds});
  } else if (scheduled_utc_seconds > existing->scheduled_utc_seconds) {
    existing->scheduled_utc_seconds = scheduled_utc_seconds;
  }
}

void append_terminal(PersistentAlarmState& state,
                     TerminalOccurrence occurrence) {
  const auto duplicate = std::find_if(
      state.terminal.begin(), state.terminal.end(),
      [&occurrence](const TerminalOccurrence& existing) {
        return existing.occurrence_id == occurrence.occurrence_id;
      });
  if (duplicate != state.terminal.end()) {
    return;
  }
  state.terminal.push_back(std::move(occurrence));
  if (state.terminal.size() > kRecentTerminalRetention) {
    state.terminal.erase(state.terminal.begin(),
                         state.terminal.begin() +
                             (state.terminal.size() - kRecentTerminalRetention));
  }
}

}  // namespace

std::string make_occurrence_id(const AlarmDefinition& alarm) {
  return alarm.id + ":" + std::to_string(alarm.schedule_revision) + ":" +
         std::to_string(alarm.scheduled_utc_seconds);
}

EvaluationResult evaluate_due(const AlarmDefinition& alarm,
                              PersistentAlarmState& state,
                              std::int64_t wall_utc_seconds,
                              std::int64_t monotonic_seconds,
                              bool time_valid) {
  if (!alarm.enabled) {
    EvaluationResult result;
    result.status = EvaluationStatus::disabled;
    return result;
  }
  if (!time_valid) {
    EvaluationResult result;
    result.status = EvaluationStatus::invalid_time;
    return result;
  }
  if (wall_utc_seconds < alarm.scheduled_utc_seconds) {
    return {};
  }

  auto occurrence_id = make_occurrence_id(alarm);
  if (state.active && state.active->occurrence_id != occurrence_id) {
    EvaluationResult result;
    result.status = EvaluationStatus::conflict;
    result.occurrence_id = std::move(occurrence_id);
    return result;
  }
  const bool already_active =
      state.active && state.active->occurrence_id == occurrence_id;
  const auto high_watermark = find_high_watermark(state, alarm.id);
  const bool at_or_below_terminal_high_watermark =
      high_watermark != state.terminal_high_watermarks.end() &&
      alarm.scheduled_utc_seconds <= high_watermark->scheduled_utc_seconds;
  const bool already_terminal = std::any_of(
      state.terminal.begin(), state.terminal.end(),
      [&occurrence_id](const TerminalOccurrence& occurrence) {
        return occurrence.occurrence_id == occurrence_id;
      });
  if (already_active || already_terminal ||
      at_or_below_terminal_high_watermark) {
    EvaluationResult result;
    result.status = EvaluationStatus::duplicate;
    result.occurrence_id = std::move(occurrence_id);
    return result;
  }
  if (!can_track_terminal(state, alarm.id)) {
    EvaluationResult result;
    result.status = EvaluationStatus::conflict;
    result.occurrence_id = std::move(occurrence_id);
    return result;
  }

  std::int64_t lateness{};
  if (!checked_elapsed(wall_utc_seconds, alarm.scheduled_utc_seconds,
                       lateness)) {
    return invalid_time_result(occurrence_id);
  }
  if (lateness > kLateGraceSeconds) {
    record_terminal_high_watermark(state, alarm.id,
                                   alarm.scheduled_utc_seconds);
    append_terminal(state,
                    {occurrence_id, TerminalReason::forward_jump});
    EvaluationResult result;
    result.status = EvaluationStatus::missed;
    result.occurrence_id = std::move(occurrence_id);
    result.persist_before_effects = true;
    result.lateness_seconds = lateness;
    return result;
  }

  ActiveOccurrence active;
  active.alarm_id = alarm.id;
  active.occurrence_id = occurrence_id;
  active.scheduled_utc_seconds = alarm.scheduled_utc_seconds;
  active.first_ring_utc_seconds = wall_utc_seconds;
  active.first_ring_monotonic_seconds = monotonic_seconds;
  state.active = std::move(active);
  EvaluationResult result;
  result.status = EvaluationStatus::ringing;
  result.occurrence_id = std::move(occurrence_id);
  result.start_alert = true;
  result.persist_before_effects = true;
  result.late = lateness > 0;
  result.lateness_seconds = lateness;
  return result;
}

EvaluationResult request_snooze(PersistentAlarmState& state,
                                const std::string& occurrence_id,
                                std::int64_t monotonic_seconds,
                                std::int64_t duration_seconds) {
  EvaluationResult result;
  result.occurrence_id = occurrence_id;
  if (!state.active || state.active->occurrence_id != occurrence_id) {
    result.status = EvaluationStatus::conflict;
    return result;
  }
  if (state.active->snooze_deadline_monotonic_seconds) {
    result.status = EvaluationStatus::conflict;
    return result;
  }
  if (duration_seconds < kMinimumSnoozeSeconds ||
      duration_seconds > kMaximumSnoozeSeconds) {
    result.status = EvaluationStatus::invalid_request;
    return result;
  }
  if (state.active->snooze_count >= kMaximumSnoozes) {
    result.status = EvaluationStatus::snooze_limit_reached;
    return result;
  }

  if (monotonic_seconds < state.active->first_ring_monotonic_seconds) {
    return invalid_time_result(occurrence_id);
  }

  std::int64_t deadline{};
  if (!checked_add(monotonic_seconds, duration_seconds, deadline)) {
    return invalid_time_result(occurrence_id);
  }

  ++state.active->snooze_count;
  state.active->snooze_deadline_monotonic_seconds = deadline;
  result.status = EvaluationStatus::snoozed;
  result.stop_alert = true;
  result.persist_before_effects = true;
  return result;
}

EvaluationResult advance_active(PersistentAlarmState& state,
                                std::int64_t monotonic_seconds) {
  EvaluationResult result;
  if (!state.active) {
    return result;
  }
  result.occurrence_id = state.active->occurrence_id;
  std::int64_t elapsed{};
  if (!checked_elapsed(monotonic_seconds,
                       state.active->first_ring_monotonic_seconds, elapsed)) {
    return invalid_time_result(result.occurrence_id);
  }
  if (elapsed >= kOccurrenceLifetimeSeconds) {
    record_terminal_high_watermark(
        state, state.active->alarm_id, state.active->scheduled_utc_seconds);
    append_terminal(
        state, {state.active->occurrence_id, TerminalReason::timed_out});
    state.active.reset();
    result.status = EvaluationStatus::timed_out;
    result.stop_alert = true;
    result.persist_before_effects = true;
    return result;
  }
  if (!state.active->snooze_deadline_monotonic_seconds) {
    result.status = EvaluationStatus::ringing;
    return result;
  }
  if (monotonic_seconds < *state.active->snooze_deadline_monotonic_seconds) {
    result.status = EvaluationStatus::snoozed;
    return result;
  }

  state.active->snooze_deadline_monotonic_seconds.reset();
  result.status = EvaluationStatus::ringing;
  result.start_alert = true;
  result.persist_before_effects = true;
  return result;
}

EvaluationResult dismiss_active(PersistentAlarmState& state,
                                const std::string& occurrence_id,
                                bool alarm_disabled) {
  EvaluationResult result;
  result.occurrence_id = occurrence_id;
  if (!state.active || state.active->occurrence_id != occurrence_id) {
    result.status = EvaluationStatus::conflict;
    return result;
  }

  record_terminal_high_watermark(state, state.active->alarm_id,
                                 state.active->scheduled_utc_seconds);
  append_terminal(state,
                  {occurrence_id, alarm_disabled ? TerminalReason::alarm_disabled
                                                 : TerminalReason::dismissed});
  state.active.reset();
  result.status = EvaluationStatus::dismissed;
  result.stop_alert = true;
  result.persist_before_effects = true;
  return result;
}

EvaluationResult recover_after_reboot(PersistentAlarmState& state,
                                      std::int64_t wall_utc_seconds,
                                      const std::string& boot_id) {
  EvaluationResult result;
  if (!state.active) {
    return result;
  }
  result.occurrence_id = state.active->occurrence_id;
  if (state.active->last_recovery_boot_id == boot_id) {
    result.status = EvaluationStatus::duplicate;
    return result;
  }

  std::int64_t elapsed{};
  if (!checked_elapsed(wall_utc_seconds, state.active->first_ring_utc_seconds,
                       elapsed)) {
    return invalid_time_result(result.occurrence_id);
  }
  if (elapsed >= kOccurrenceLifetimeSeconds) {
    record_terminal_high_watermark(
        state, state.active->alarm_id, state.active->scheduled_utc_seconds);
    append_terminal(state,
                    {state.active->occurrence_id,
                     TerminalReason::prolonged_power_off});
    state.active.reset();
    result.status = EvaluationStatus::missed;
    result.persist_before_effects = true;
    return result;
  }

  state.active->snooze_deadline_monotonic_seconds.reset();
  state.active->recovered_after_reboot = true;
  state.active->last_recovery_boot_id = boot_id;
  result.status = EvaluationStatus::ringing;
  result.start_alert = true;
  result.persist_before_effects = true;
  result.recovered_after_reboot = true;
  return result;
}

}  // namespace dawn
