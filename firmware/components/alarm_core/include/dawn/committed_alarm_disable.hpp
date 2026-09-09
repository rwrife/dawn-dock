#pragma once

#include "dawn/schedule_store.hpp"

#include <cstdint>
#include <string>

namespace dawn {

enum class CommittedDisableStatus {
  // The requested alarm definition is durably disabled (or its pending
  // dismiss journal committed while the definition was already disabled).
  disabled,
  // No stored alarm definition carries this ID; nothing was written.
  alarm_not_found,
  // The definition is already disabled with no active occurrence; the
  // schedule revision was intentionally left unchanged.
  already_disabled,
  empty_store,
  invalid_store,
  io_error,
  // A compare-and-set lost against a concurrent commit. Inspect
  // journal_committed/definition_committed to see which phase landed.
  persistence_conflict,
  // A storage write or verification failed. No un-backstopped alert effect
  // was exposed and the definition change did not land.
  persistence_error,
};

struct CommittedAlarmDisableResult {
  CommittedDisableStatus status{CommittedDisableStatus::persistence_error};
  // Occurrence ID of the journal record dismissed during confirmed
  // disable; empty when no active occurrence belonged to the target.
  std::string occurrence_id;
  // True when the dismiss record is durably committed via the runtime
  // journal (phase 1). True stop_alert may only be exposed alongside this.
  bool journal_committed{};
  // True when the enabled=false definition change is durably committed via
  // a new schedule revision (phase 2).
  bool definition_committed{};
  // True only after the terminal dismiss journal was committed.
  bool stop_alert{};
  // Effective schedule revision: observed at load, advanced once the
  // definition commit lands.
  std::uint64_t schedule_revision{};
  std::uint64_t generation{};
};

// Performs the confirmed-disable contract from docs/alarm-semantics.md:
// when an active occurrence belongs to the target alarm, its terminal
// dismiss record (reason alarm_disabled) is committed through the runtime
// journal CAS *before* the alert stop effect is exposed, and only then is
// the definition change committed as a new schedule revision. With no
// matching active occurrence, only the definition commit runs and no alert
// effect is produced. Both phases carry the occurrence journal forward, so
// disabling one alarm never erases another alarm's runtime state.
[[nodiscard]] CommittedAlarmDisableResult disable_committed_alarm(
    AtomicScheduleStore &store, const std::string &alarm_id);

} // namespace dawn
