#include "dawn/control_debounce.hpp"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string_view>

namespace {

void expect(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

// Establishes the released baseline for a line, finishing at `start + 20`.
void settle_released(dawn::ControlDebounce &control, std::int64_t start) {
  expect(!control.sample(false, start), "baseline released begins");
  expect(!control.sample(false, start + dawn::kDebounceStableMilliseconds),
         "baseline release is never a press edge");
}

void bounce_and_hold_emit_one_edge() {
  dawn::ControlDebounce snooze;
  settle_released(snooze, 0);
  expect(!snooze.sample(true, 25), "press begins");
  expect(!snooze.sample(false, 29), "press bounce cancels candidate");
  expect(!snooze.sample(true, 32), "press begins again");
  expect(!snooze.sample(true, 51), "press not stable before 20 ms");
  expect(snooze.sample(true, 52), "one press edge at 20 ms");
  expect(!snooze.sample(true, 120), "held press does not repeat");
  expect(!snooze.sample(false, 125), "release begins");
  expect(!snooze.sample(true, 131), "release bounce cancels candidate");
  expect(!snooze.sample(false, 140), "release begins again");
  expect(!snooze.sample(false, 160), "release stable without press edge");
  expect(!snooze.sample(true, 165), "new gesture begins");
  expect(snooze.sample(true, 185), "new gesture emits one edge");
  expect(!snooze.sample(true, 270), "second hold does not repeat");
}

void independent_controls_and_startup_hold() {
  dawn::ControlDebounce snooze;
  dawn::ControlDebounce brightness;
  expect(!snooze.sample(true, 0), "startup held needs confirmation");
  expect(!snooze.sample(true, 19), "startup held below threshold");
  expect(!snooze.sample(true, 20), "startup held becomes safe baseline");
  expect(!snooze.sample(true, 41), "startup held never acts later");
  settle_released(brightness, 0);
  expect(!brightness.sample(true, 21), "brightness press begins");
  expect(brightness.sample(true, 41), "brightness press confirms");
  expect(!snooze.sample(false, 42), "snooze release starts");
  expect(!snooze.sample(false, 62), "snooze release re-arms");
  expect(!snooze.sample(true, 63), "new snooze gesture starts");
  expect(snooze.sample(true, 83), "new snooze gesture confirms once");
  expect(!brightness.sample(true, 90), "brightness hold does not repeat");
}

void reversed_clock_restarts_candidate_without_premature_edge() {
  dawn::ControlDebounce control;
  settle_released(control, 100);
  expect(!control.sample(true, 130), "press begins");
  expect(!control.sample(true, 125), "clock regression rejects elapsed time");
  expect(!control.sample(true, 144), "old press deadline no longer applies");
  expect(control.sample(true, 145), "new stable interval emits edge");

  dawn::ControlDebounce startup;
  expect(!startup.sample(false, 100), "startup baseline begins");
  expect(!startup.sample(false, 90), "startup clock regression restarts");
  expect(!startup.sample(false, 109), "startup baseline not yet stable");
  expect(!startup.sample(false, 110), "startup baseline stable without edge");
  expect(!startup.sample(true, 111), "press after startup baseline begins");
  expect(startup.sample(true, 131), "press after startup baseline confirms");
}

void extreme_clock_values_do_not_overflow() {
  constexpr auto kMin = std::numeric_limits<std::int64_t>::min();
  constexpr auto kMax = std::numeric_limits<std::int64_t>::max();
  dawn::ControlDebounce control;
  expect(!control.sample(false, kMin), "extreme minimum begins baseline");
  expect(!control.sample(false, kMax), "extreme span is a stable baseline");
  expect(!control.sample(true, kMin), "extreme minimum press begins");
  expect(control.sample(true, kMax), "extreme span cannot signed-overflow");
}

} // namespace

int main() {
  bounce_and_hold_emit_one_edge();
  independent_controls_and_startup_hold();
  reversed_clock_restarts_candidate_without_premature_edge();
  extreme_clock_values_do_not_overflow();
  std::cout << "control debounce host fixtures passed\n";
}
