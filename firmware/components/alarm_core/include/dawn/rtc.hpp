#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace dawn {

constexpr std::size_t kDs3231SnapshotBytes = 16;

class RtcRegisterReader {
public:
  virtual ~RtcRegisterReader() = default;
  // Read registers 0x00..0x0f in one coherent burst. Return zero on success,
  // otherwise the transport's error code. A partial read must report failure.
  [[nodiscard]] virtual std::int32_t read_snapshot(
      std::span<std::uint8_t, kDs3231SnapshotBytes> registers) = 0;
};

enum class RtcStatus {
  valid,
  io_error,
  oscillator_stopped,
  backup_oscillator_disabled,
  invalid_registers,
  unsupported_century,
};

struct RtcObservation {
  RtcStatus status{RtcStatus::io_error};
  std::optional<std::int64_t> utc_seconds;
  std::int32_t transport_error{};
};

// The RTC must be provisioned in UTC, not local civil time. Reading never
// writes time, clears OSF, or substitutes the build/system clock.
[[nodiscard]] RtcObservation read_ds3231_utc(RtcRegisterReader &reader);

} // namespace dawn
