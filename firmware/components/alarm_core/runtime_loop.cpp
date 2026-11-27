#include "dawn/runtime_loop.hpp"

namespace dawn {

RuntimeLoopStep RuntimeLoop::step(std::int64_t monotonic_seconds) {
  const auto observation = read_ds3231_utc(rtc_);
  const bool valid = observation.status == RtcStatus::valid &&
                     observation.utc_seconds.has_value();
  RuntimeTickObservation tick_observation;
  tick_observation.time_valid = valid;
  tick_observation.wall_utc_seconds = valid ? *observation.utc_seconds : 0;
  tick_observation.monotonic_seconds = monotonic_seconds;
  tick_observation.boot_id = boot_id_;

  RuntimeLoopStep result;
  result.rtc_status = observation.status;
  result.transport_error = observation.transport_error;
  result.tick = run_runtime_tick(store_, state_, tick_observation);
  return result;
}

} // namespace dawn
