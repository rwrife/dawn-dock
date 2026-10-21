#include "dawn/quadrature_encoder.hpp"

namespace dawn {
namespace {

// Gray order 00, 01, 11, 10 (phase = A<<1 | B). kStep[from][to] is the
// signed quadrature step: +/-1 for the two adjacent phases, +2/-2 are the
// impossible diagonal jumps, 0 is "no change".
constexpr int kStep[4][4] = {
    {0, 1, -1, 2}, {-1, 0, 2, 1}, {1, 2, 0, -1}, {2, -1, 1, 0}};

} // namespace

std::optional<int> QuadratureEncoder::sample(bool a_high, bool b_high,
                                             bool pressed) {
  const int phase = (a_high ? 2 : 0) | (b_high ? 1 : 0);
  if (!phase_) {
    // First sample only establishes a reference; a knob resting on any
    // detent (or mid-transition) at boot can never emit an event.
    phase_ = phase;
    was_pressed_ = pressed;
    return std::nullopt;
  }
  if (pressed) {
    // While the knob is held down, track the phase but accumulate nothing,
    // so shaft wiggle during a press cannot complete a cycle.
    phase_ = phase;
    progress_ = 0;
    was_pressed_ = true;
    return std::nullopt;
  }
  if (was_pressed_) {
    // Press-to-release boundary: push force can jostle A/B. Discard this
    // one sample and rebase rather than guessing whether it was motion.
    phase_ = phase;
    progress_ = 0;
    was_pressed_ = false;
    return std::nullopt;
  }
  const int step = kStep[*phase_][phase];
  if (step == 0) {
    return std::nullopt;
  }
  if (step == 2 || step == -2) {
    // Diagonal jump crosses both bits at once. The host cannot know how
    // much real rotation was missed, so fail closed: drop all partial
    // progress and rebase. Lost motion is acceptable; invented motion is
    // not.
    // ponytail: hard reset is the ceiling. If bench shows wide glitches
    // eating real rotation, upgrade to a bounded leaky integrator.
    progress_ = 0;
    phase_ = phase;
    return std::nullopt;
  }
  phase_ = phase;
  progress_ += step;
  if (progress_ == 4) {
    progress_ = 0;
    return 1;
  }
  if (progress_ == -4) {
    progress_ = 0;
    return -1;
  }
  return std::nullopt;
}

} // namespace dawn
