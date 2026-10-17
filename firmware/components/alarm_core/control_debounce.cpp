#include "dawn/control_debounce.hpp"

namespace dawn {

bool ControlDebounce::sample(bool pressed, std::int64_t now_ms) {
  if (stable_pressed_ && pressed == *stable_pressed_) {
    // Matches the confirmed level; any in-flight opposite candidate was
    // bounce and is discarded.
    candidate_pressed_.reset();
    return false;
  }

  // A non-monotonic poll is untrustworthy: restart the interval instead of
  // trusting an elapsed time computed across the regression.
  // ponytail: the target adapter should also surface a clock-anomaly
  // diagnostic if this path is reachable on device.
  if (!candidate_pressed_ || *candidate_pressed_ != pressed ||
      now_ms < candidate_started_ms_) {
    candidate_pressed_ = pressed;
    candidate_started_ms_ = now_ms;
    return false;
  }

  // now_ms >= candidate_started_ms_, so the unsigned difference is exact and
  // cannot overflow even at the int64 extremes.
  const auto elapsed = static_cast<std::uint64_t>(now_ms) -
                       static_cast<std::uint64_t>(candidate_started_ms_);
  if (elapsed < static_cast<std::uint64_t>(kDebounceStableMilliseconds)) {
    return false;
  }

  const bool had_baseline = stable_pressed_.has_value();
  stable_pressed_ = pressed;
  candidate_pressed_.reset();
  // Only a stable transition into the pressed level, observed after a
  // confirmed baseline, is an event. A control already held at startup
  // becomes the baseline without acting, so a stuck or boot-held button
  // cannot snooze or dismiss; release re-arms the line.
  return had_baseline && pressed;
}

} // namespace dawn
