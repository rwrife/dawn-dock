#pragma once

#include "dawn/schedule_store.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace dawn {

enum class InvalidTimeRecoveryStatus {
  // One or more crossed occurrences were journaled durably in a single
  // runtime transaction. Inspect `crossed` for outcomes and `start_alert`
  // for the only permitted alert effect.
  reconciled,
  // No enabled committed occurrence was crossed while time was invalid;
  // the store was not written.
  nothing_crossed,
  // The caller reports time as still invalid, or the newest crossed
  // occurrence has an unrepresentable lateness. The store was not written.
  invalid_time,
  // An occurrence is already active; its lifecycle belongs to the reboot
  // recovery / advance-active path. Reconciliation must run only after
  // that path settles. The store was not written.
  active_conflict,
  // The terminal high-watermark table cannot accept every alarm that the
  // reconciliation must journal; failed closed before any mutation.
  journal_capacity,
  empty_store,
  invalid_store,
  io_error,
  // A compare-and-set lost against a concurrent commit. Nothing was
  // exposed; the reconciliation is retryable against fresh state.
  persistence_conflict,
  // A storage write or verification failed. No alert effect was exposed
  // and the reconciliation remains retryable.
  persistence_error,
};

struct RecoveredOccurrence {
  std::string alarm_id;
  std::string occurrence_id;
  // `ringing` only for the newest crossed occurrence when it fell within
  // the frozen late grace; `missed` for every other reconciled entry.
  EvaluationStatus outcome{EvaluationStatus::missed};
  // Wall lateness against the scheduled UTC instant. Meaningful only for
  // the newest crossed occurrence, whose lateness decides ring versus
  // missed; older entries are missed by recency ranking alone and report
  // zero.
  std::int64_t lateness_seconds{};
};

struct InvalidTimeRecoveryResult {
  InvalidTimeRecoveryStatus status{
      InvalidTimeRecoveryStatus::persistence_error};
  std::uint64_t schedule_revision{};
  std::uint64_t generation{};
  // Crossed occurrences in deterministic scheduled-ascending order with
  // alarm-ID tie-break, or empty when the reconciliation failed closed.
  std::vector<RecoveredOccurrence> crossed;
  // True only when the journal batch is durable and the newest crossed
  // occurrence rang within the frozen late grace. At most one alert start
  // is ever exposed for a reconciliation.
  bool start_alert{};
  std::string ringing_occurrence_id;
  // True once the whole journal batch committed through the runtime CAS.
  bool journal_committed{};
};

// Performs the invalid-interval contract from docs/alarm-semantics.md:
// once wall time becomes valid again, every enabled committed occurrence
// whose scheduled UTC instant passed without a durable terminal or active
// record is classified exactly once. The newest crossed occurrence rings
// only if it is within the frozen 10-minute late grace (otherwise it is
// missed); every older crossed occurrence is missed with reason
// `invalid_time` regardless of its own lateness. The complete journal
// batch commits through the runtime-journal CAS before any alert effect
// is exposed, mirroring the evaluator's commit-before-effect discipline.
// Terminal, watermarked, disabled, and future occurrences are never
// re-marked, so a repeated reconciliation performs zero writes.
[[nodiscard]] InvalidTimeRecoveryResult reconcile_after_time_valid(
    AtomicScheduleStore &store, std::int64_t wall_utc_seconds,
    std::int64_t monotonic_seconds, bool time_valid = true);

} // namespace dawn
