#pragma once

#include "dawn/rtc.hpp"
#include "dawn/runtime_coordinator.hpp"

#include <cstdint>
#include <string>

namespace dawn {

struct RuntimeLoopStep {
  RtcStatus rtc_status{RtcStatus::io_error};
  std::int32_t transport_error{};
  RuntimeTickResult tick;
};

// One-second runtime step: samples the RTC once, derives the validity verdict
// and runs one coordinator tick. An unusable RTC sample is reported to the
// coordinator as invalid time (never substituted with another clock), which
// freezes scheduled transitions and arms invalid-interval reconciliation.
// The boot ID must be non-empty and stable for the whole boot.
// Host-software evidence only; task scheduling and alert effects (display,
// audio) are separate target work.
class RuntimeLoop {
public:
  RuntimeLoop(RtcRegisterReader &rtc, AtomicScheduleStore &store,
              std::string boot_id)
      : rtc_(rtc), store_(store), boot_id_(std::move(boot_id)) {}

  [[nodiscard]] RuntimeLoopStep step(std::int64_t monotonic_seconds);

private:
  RtcRegisterReader &rtc_;
  AtomicScheduleStore &store_;
  std::string boot_id_;
  RuntimeCoordinatorState state_;
};

} // namespace dawn
