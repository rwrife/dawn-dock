#include "dawn/committed_schedule_evaluator.hpp"

#include <algorithm>
#include <string_view>
#include <utility>

namespace {

std::string alarm_id_from_occurrence_id(
    std::string_view occurrence_id) {
  const auto first_colon = occurrence_id.find(':');
  if (first_colon == std::string_view::npos) {
    return std::string(occurrence_id);
  }
  return std::string(occurrence_id.substr(0, first_colon));
}

bool commit_occurrence_transition(
    dawn::AtomicScheduleStore &store, dawn::PersistentAlarmState &occurrence_state,
    dawn::CommittedScheduleEvaluation &evaluation,
    dawn::CommittedAlarmEvaluation &alarm_evaluation) {
  if (!alarm_evaluation.result.persist_before_effects) {
    return true;
  }

  const auto committed = store.save_occurrence_state(
      occurrence_state, evaluation.schedule_revision, evaluation.generation);
  evaluation.generation = committed.generation;
  if (committed.status != dawn::StoreStatus::stored &&
      committed.status != dawn::StoreStatus::unchanged) {
    alarm_evaluation.result.start_alert = false;
    alarm_evaluation.result.stop_alert = false;
    evaluation.alarms.push_back(std::move(alarm_evaluation));
    evaluation.status = committed.status == dawn::StoreStatus::revision_conflict ||
                                committed.status ==
                                    dawn::StoreStatus::generation_conflict
                            ? dawn::CommittedEvaluationStatus::persistence_conflict
                            : dawn::CommittedEvaluationStatus::persistence_error;
    return false;
  }

  alarm_evaluation.journal_committed = true;
  alarm_evaluation.result.persist_before_effects = false;
  if (committed.status == dawn::StoreStatus::unchanged) {
    alarm_evaluation.result.status = dawn::EvaluationStatus::duplicate;
    alarm_evaluation.result.start_alert = false;
    alarm_evaluation.result.stop_alert = false;
  }
  return true;
}

}  // namespace

namespace dawn {

CommittedScheduleEvaluation evaluate_committed_schedule(
    AtomicScheduleStore &store, std::int64_t wall_utc_seconds,
    std::int64_t monotonic_seconds, bool time_valid,
    const std::string &boot_id) {
  CommittedScheduleEvaluation evaluation;
  if (!time_valid) {
    evaluation.status = CommittedEvaluationStatus::invalid_time;
    return evaluation;
  }

  const auto loaded = store.load();
  if (loaded.status != LoadStatus::loaded) {
    evaluation.status = loaded.status == LoadStatus::empty
                            ? CommittedEvaluationStatus::empty_store
                            : loaded.status == LoadStatus::io_error
                                  ? CommittedEvaluationStatus::io_error
                                  : CommittedEvaluationStatus::invalid_store;
    return evaluation;
  }

  evaluation.schedule_revision = loaded.snapshot.revision;
  evaluation.generation = loaded.generation;
  auto occurrence_state = loaded.snapshot.occurrence_state;

  if (occurrence_state.active.has_value()) {
    CommittedAlarmEvaluation active_evaluation;
    active_evaluation.from_active_occurrence = true;
    active_evaluation.alarm_id =
        alarm_id_from_occurrence_id(occurrence_state.active->occurrence_id);
    if (active_evaluation.alarm_id.empty()) {
      active_evaluation.alarm_id = occurrence_state.active->occurrence_id;
    }
    active_evaluation.result = boot_id.empty()
                                   ? advance_active(occurrence_state,
                                                    monotonic_seconds)
                                   : recover_after_reboot(
                                         occurrence_state, wall_utc_seconds,
                                         boot_id);

    if (active_evaluation.result.status == EvaluationStatus::invalid_time) {
      evaluation.status = CommittedEvaluationStatus::invalid_time;
      evaluation.alarms.push_back(std::move(active_evaluation));
      return evaluation;
    }
    if (!commit_occurrence_transition(
            store, occurrence_state, evaluation, active_evaluation)) {
      return evaluation;
    }
    evaluation.alarms.push_back(std::move(active_evaluation));
  }

  auto alarms = loaded.snapshot.alarms;
  std::sort(alarms.begin(), alarms.end(), [](const StoredAlarmDefinition &left,
                                              const StoredAlarmDefinition &right) {
    if (left.scheduled_utc_seconds != right.scheduled_utc_seconds) {
      return left.scheduled_utc_seconds < right.scheduled_utc_seconds;
    }
    return left.id < right.id;
  });

  for (const auto &stored_alarm : alarms) {
    AlarmDefinition alarm{
        .id = stored_alarm.id,
        .schedule_revision = stored_alarm.schedule_revision,
        .enabled = stored_alarm.enabled,
        .scheduled_utc_seconds = stored_alarm.scheduled_utc_seconds,
    };
    CommittedAlarmEvaluation alarm_evaluation;
    alarm_evaluation.alarm_id = alarm.id;
    alarm_evaluation.result = evaluate_due(
        alarm, occurrence_state, wall_utc_seconds, monotonic_seconds, true);

    if (alarm_evaluation.result.status == EvaluationStatus::invalid_time) {
      evaluation.status = CommittedEvaluationStatus::invalid_time;
      evaluation.alarms.push_back(std::move(alarm_evaluation));
      return evaluation;
    }
    if (!commit_occurrence_transition(
            store, occurrence_state, evaluation, alarm_evaluation)) {
      return evaluation;
    }
    evaluation.alarms.push_back(std::move(alarm_evaluation));
  }
  return evaluation;
}

} // namespace dawn
