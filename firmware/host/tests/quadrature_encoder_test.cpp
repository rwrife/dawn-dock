#include "dawn/quadrature_encoder.hpp"

#include <cstdlib>
#include <iostream>
#include <optional>
#include <string_view>

namespace {

void expect(std::optional<int> actual, std::optional<int> expected,
            std::string_view message) {
  if (actual != expected) {
    std::cerr << "FAIL: " << message << " expected "
              << (expected ? *expected : 0) << " got "
              << (actual ? *actual : 0) << '\n';
    std::exit(1);
  }
}

// Logical forward Gray order: 00 -> 01 -> 11 -> 10 -> 00.
void forward_and_reverse() {
  dawn::QuadratureEncoder e;
  expect(e.sample(false, false, false), {}, "startup baseline");
  expect(e.sample(false, true, false), {}, "forward B rise");
  expect(e.sample(true, true, false), {}, "forward A rise");
  expect(e.sample(true, false, false), {}, "forward B fall");
  expect(e.sample(false, false, false), 1, "forward cycle");
  expect(e.sample(true, false, false), {}, "reverse A rise");
  expect(e.sample(true, true, false), {}, "reverse B rise");
  expect(e.sample(false, true, false), {}, "reverse A fall");
  expect(e.sample(false, false, false), -1, "reverse cycle");
}

void twenty_four_cycles_without_coalescing() {
  dawn::QuadratureEncoder e;
  expect(e.sample(false, false, false), {}, "baseline");
  for (int turn = 0; turn < 24; ++turn) {
    expect(e.sample(false, true, false), {}, "B rise");
    expect(e.sample(true, true, false), {}, "A rise");
    expect(e.sample(true, false, false), {}, "B fall");
    expect(e.sample(false, false, false), 1, "one cycle per sampled turn");
  }
}

void partial_turn_returns_without_action() {
  dawn::QuadratureEncoder e;
  expect(e.sample(false, false, false), {}, "baseline");
  expect(e.sample(false, true, false), {}, "one step");
  expect(e.sample(true, true, false), {}, "two steps");
  expect(e.sample(false, true, false), {}, "one step back");
  expect(e.sample(false, false, false), {}, "back to baseline");
  expect(e.sample(false, false, false), {}, "holding does not repeat");
}

void first_edge_bounce_self_cancels() {
  dawn::QuadratureEncoder e;
  expect(e.sample(false, false, false), {}, "baseline");
  expect(e.sample(false, true, false), {}, "bounce B high");
  expect(e.sample(false, false, false), {}, "bounce B low");
  expect(e.sample(false, true, false), {}, "B high again");
  expect(e.sample(true, true, false), {}, "A high");
  expect(e.sample(true, false, false), {}, "B low");
  expect(e.sample(false, false, false), 1, "one full cycle");
}

void diagonal_rebases_and_drops_partial_motion() {
  dawn::QuadratureEncoder e;
  expect(e.sample(false, false, false), {}, "baseline");
  expect(e.sample(false, true, false), {}, "first step");
  expect(e.sample(true, false, false), {}, "diagonal cross-two-bit jump");
  expect(e.sample(false, false, false), {}, "rebase and advance");
  expect(e.sample(false, true, false), {}, "fresh first step");
  expect(e.sample(true, true, false), {}, "fresh second step");
  expect(e.sample(true, false, false), 1, "fresh full cycle");
}

void push_suppresses_rotation_and_release_rebases() {
  dawn::QuadratureEncoder e;
  expect(e.sample(false, false, false), {}, "baseline");
  expect(e.sample(false, true, false), {}, "pre-press step");
  expect(e.sample(true, true, true), {}, "press during turn");
  expect(e.sample(true, false, true), {}, "turn while held");
  expect(e.sample(false, false, false), {}, "release discards boundary");
  expect(e.sample(false, true, false), {}, "fresh first step");
  expect(e.sample(true, true, false), {}, "fresh second step");
  expect(e.sample(true, false, false), {}, "fresh third step");
  expect(e.sample(false, false, false), 1, "fresh cycle after press");
}

void nonzero_startup_and_boot_held_push() {
  dawn::QuadratureEncoder e;
  expect(e.sample(true, true, true), {}, "held push at boot baseline");
  expect(e.sample(false, true, true), {}, "motion while held");
  expect(e.sample(false, false, false), {}, "release rebase");
  expect(e.sample(false, true, false), {}, "first free step");
  expect(e.sample(true, true, false), {}, "second free step");
  expect(e.sample(true, false, false), {}, "third free step");
  expect(e.sample(false, false, false), 1, "first free cycle");
}

} // namespace

int main() {
  forward_and_reverse();
  twenty_four_cycles_without_coalescing();
  partial_turn_returns_without_action();
  first_edge_bounce_self_cancels();
  diagonal_rebases_and_drops_partial_motion();
  push_suppresses_rotation_and_release_rebases();
  nonzero_startup_and_boot_held_push();
  std::cout << "quadrature encoder host fixtures passed\n";
}
