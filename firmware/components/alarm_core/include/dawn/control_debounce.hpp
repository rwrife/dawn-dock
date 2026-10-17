#pragma once

#include <cstdint>
#include <optional>

// Inversion note: hardware SN74LVC14A output is active-low for a press.
// Caller translates it to `pressed` before passing a sample.

namespace dawn {

// Frozen software debounce policy for the post-SN74LVC14A push inputs
// (snooze, brightness, encoder switch). The Omron B3F datasheet specifies
// push-switch bounce time as 5 ms max. Requiring the input to hold one stable
// logic level for 20 ms gives a 4x margin before any transition is accepted.
// Encoder A/B rotation needs its own quadrature state machine and PEC11R
// timing basis; do not reuse this press-edge policy on those phases.
// The valid-press response budget from docs/system-architecture.md is 100 ms;
// the 20 ms stable window leaves 80 ms for polling and alarm-engine dispatch.
inline constexpr std::int64_t kDebounceStableMilliseconds = 20;
inline constexpr std::int64_t kValidPressResponseBudgetMilliseconds = 100;

// One independent button/encoder-switch line. `sample` receives the already
// polarity-resolved logic state (true = pressed) and a caller-supplied
// monotonic clock in milliseconds. It returns true exactly once when a press
// becomes stable; release, bounce, and continued holding return false.
// The class owns no clock, no GPIO, and no globals, so host tests and the
// future target adapter drive identical policy code.
class ControlDebounce {
public:
  [[nodiscard]] bool sample(bool pressed, std::int64_t now_ms);

private:
  // The confirmed stable state. Absent until the input has held one level
  // for a full stable window, so an input already held at startup must
  // re-confirm before it can act.
  std::optional<bool> stable_pressed_;
  std::optional<bool> candidate_pressed_;
  std::int64_t candidate_started_ms_{};
};

} // namespace dawn
