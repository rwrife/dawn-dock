#include "dawn/committed_schedule_evaluator.hpp"

#include <algorithm>

namespace dawn {

CommittedScheduleEvaluation evaluate_committed_schedule(
    AtomicScheduleStore &store, std::int64_t wall_utc_seconds,
    std::int64_t monotonic_seconds, bool time_valid) {
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
    if (alarm_evaluation.result.persist_before_effects) {
      const auto committed = store.save_occurrence_state(
          occurrence_state, evaluation.schedule_revision,
          evaluation.generation);
      evaluation.generation = committed.generation;
      if (committed.status != StoreStatus::stored &&
          committed.status != StoreStatus::unchanged) {
        alarm_evaluation.result.start_alert = false;
        alarm_evaluation.result.stop_alert = false;
        evaluation.alarms.push_back(std::move(alarm_evaluation));
        evaluation.status = committed.status == StoreStatus::revision_conflict ||
                                    committed.status ==
                                        StoreStatus::generation_conflict
                                ? CommittedEvaluationStatus::persistence_conflict
                                : CommittedEvaluationStatus::persistence_error;
        return evaluation;
      }
      alarm_evaluation.journal_committed = true;
      alarm_evaluation.result.persist_before_effects = false;
      if (committed.status == StoreStatus::unchanged) {
        alarm_evaluation.result.status = EvaluationStatus::duplicate;
        alarm_evaluation.result.start_alert = false;
        alarm_evaluation.result.stop_alert = false;
      }
    }
    evaluation.alarms.push_back(std::move(alarm_evaluation));
  }
  return evaluation;
}

} // namespace dawn
