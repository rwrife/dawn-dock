#pragma once

#include <optional>

namespace dawn {

// PEC11R-4215F-S0024: 2-bit quadrature, 24 pulses and 24 detents/rev;
// contact bounce <=2 ms at 15 RPM with external filters, max 60 RPM
// (Bourns PEC11R datasheet REV.D04/26, Electrical Characteristics).
// No minimum A/B phase interval or guaranteed detent phase is specified.
// This software-only policy accepts sampled single-bit Gray transitions and
// emits complete cycles. It cannot replace analog filtering or prove that
// every physical detent produces one cycle; bench calibration remains open.
class QuadratureEncoder {
public:
  // Caller resolves SN74LVC14A active-low outputs to high=true; `pressed`
  // resolves the separate encoder push contact. Press suppresses rotation.
  // +1 follows 00,01,11,10,00; -1 follows reverse sequence. Direction is
  // relative to logical A/B ordering, NOT a verified clockwise mapping.
  [[nodiscard]] std::optional<int> sample(bool a_high, bool b_high,
                                          bool pressed);

private:
  std::optional<int> phase_;
  int progress_ = 0;
  bool was_pressed_ = false;
};

} // namespace dawn
