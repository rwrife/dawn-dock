#pragma once

#include "dawn/rtc.hpp"

#include "driver/i2c_master.h"

namespace dawn {

constexpr std::uint16_t kDs3231I2cAddress = 0x68;
constexpr int kRtcReadTimeoutMilliseconds = 20;

// Borrows a synchronous ESP-IDF device handle configured for address 0x68.
// The bus/device owner retains lifecycle and shared-bus scheduling ownership.
// Do not register asynchronous callbacks on this handle.
class EspRtcRegisterReader final : public RtcRegisterReader {
public:
  explicit EspRtcRegisterReader(i2c_master_dev_handle_t device)
      : device_(device) {}

  [[nodiscard]] std::int32_t read_snapshot(
      std::span<std::uint8_t, kDs3231SnapshotBytes> registers) override;

private:
  i2c_master_dev_handle_t device_;
};

} // namespace dawn
