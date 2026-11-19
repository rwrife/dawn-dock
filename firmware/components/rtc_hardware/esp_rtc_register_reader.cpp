#include "dawn/esp_rtc_register_reader.hpp"

namespace dawn {

std::int32_t EspRtcRegisterReader::read_snapshot(
    std::span<std::uint8_t, kDs3231SnapshotBytes> registers) {
  if (device_ == nullptr) {
    return ESP_ERR_INVALID_ARG;
  }
  constexpr std::uint8_t kFirstRegister = 0;
  return i2c_master_transmit_receive(
      device_, &kFirstRegister, 1, registers.data(), registers.size(),
      kRtcReadTimeoutMilliseconds);
}

} // namespace dawn
