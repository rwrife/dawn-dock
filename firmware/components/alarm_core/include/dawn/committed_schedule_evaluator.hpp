#pragma once

#include "dawn/schedule_store.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace dawn {

enum class CommittedEvaluationStatus {
  evaluated,
  invalid_time,
  empty_store,
  invalid_store,
  io_error,
  persistence_conflict,
  persistence_error,
};

struct CommittedAlarmEvaluation {
  std::string alarm_id;
  EvaluationResult result;
  bool journal_committed{};
};

struct CommittedScheduleEvaluation {
  CommittedEvaluationStatus status{CommittedEvaluationStatus::evaluated};
  std::uint64_t schedule_revision{};
  std::uint64_t generation{};
  std::vector<CommittedAlarmEvaluation> alarms;
};

// Loads exactly one committed snapshot and evaluates its stored UTC
// occurrences. Any runtime-journal mutation is committed before an alert
// effect is returned to the caller.
[[nodiscard]] CommittedScheduleEvaluation evaluate_committed_schedule(
    AtomicScheduleStore &store, std::int64_t wall_utc_seconds,
    std::int64_t monotonic_seconds, bool time_valid = true);

} // namespace dawn
