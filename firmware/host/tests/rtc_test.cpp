#include "dawn/esp_rtc_register_reader.hpp"
#include "dawn/rtc.hpp"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <iostream>
#include <string_view>
#include <utility>

struct i2c_master_dev_t {};

namespace {
i2c_master_dev_t device;
std::array<std::uint8_t, dawn::kDs3231SnapshotBytes> bus_registers{};
esp_err_t bus_error{};
int bus_reads{};
bool correct_transaction{};
} // namespace

extern "C" esp_err_t i2c_master_transmit_receive(
    i2c_master_dev_handle_t handle, const std::uint8_t *write_data,
    std::size_t write_size, std::uint8_t *read_data, std::size_t read_size,
    int timeout_ms) {
  ++bus_reads;
  correct_transaction =
      handle == &device && write_size == 1 && write_data[0] == 0 &&
      read_size == dawn::kDs3231SnapshotBytes && timeout_ms == 20;
  if (correct_transaction) {
    std::copy(bus_registers.begin(), bus_registers.end(), read_data);
  }
  return bus_error;
}

namespace {

void expect(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

class FakeRtc final : public dawn::RtcRegisterReader {
public:
  std::array<std::uint8_t, dawn::kDs3231SnapshotBytes> registers{
      0x56, 0x34, 0x12, 0x01, 0x29, 0x02, 0x24};
  std::int32_t error{};
  int reads{};

  std::int32_t read_snapshot(
      std::span<std::uint8_t, dawn::kDs3231SnapshotBytes> output) override {
    ++reads;
    std::copy(registers.begin(), registers.end(), output.begin());
    return error;
  }
};

void expect_invalid(FakeRtc &rtc, dawn::RtcStatus status) {
  const auto result = dawn::read_ds3231_utc(rtc);
  expect(result.status == status && !result.utc_seconds,
         "invalid RTC observation never exposes a usable timestamp");
}

void calendar_and_hour_modes() {
  FakeRtc rtc;
  auto result = dawn::read_ds3231_utc(rtc);
  expect(result.status == dawn::RtcStatus::valid &&
             result.utc_seconds == 1709210096 && rtc.reads == 1,
         "one burst decodes leap day 2024-02-29T12:34:56Z");
  rtc.registers[2] = 0x72;
  expect(dawn::read_ds3231_utc(rtc).utc_seconds == result.utc_seconds,
         "12 PM equals 24-hour noon");
  rtc.registers[2] = 0x52;
  expect(dawn::read_ds3231_utc(rtc).utc_seconds == 1709166896,
         "12 AM is midnight");
  rtc.registers[2] = 0x61;
  expect(dawn::read_ds3231_utc(rtc).utc_seconds == 1709213696,
         "1 PM is 13:34:56");
  rtc.registers = {0, 0, 0, 7, 1, 1, 0};
  expect(dawn::read_ds3231_utc(rtc).utc_seconds == 946684800,
         "lower bound is 2000-01-01T00:00:00Z");
  rtc.registers = {0x59, 0x59, 0x23, 1, 0x31, 0x12, 0x99};
  expect(dawn::read_ds3231_utc(rtc).utc_seconds == 4102444799LL,
         "2099 upper bound is not limited by signed 32-bit time_t");
}

void untrusted_time_and_transport_failures() {
  FakeRtc rtc;
  rtc.registers[15] = 0x80;
  expect_invalid(rtc, dawn::RtcStatus::oscillator_stopped);
  expect(rtc.registers[15] == 0x80, "reading must not clear the stop flag");
  rtc.registers[15] = 0;
  rtc.registers[14] = 0x80;
  expect_invalid(rtc, dawn::RtcStatus::backup_oscillator_disabled);
  rtc.registers[14] = 0;
  rtc.registers[5] = 0x82;
  expect_invalid(rtc, dawn::RtcStatus::unsupported_century);
  rtc.error = -37;
  const auto failed = dawn::read_ds3231_utc(rtc);
  expect(failed.status == dawn::RtcStatus::io_error &&
             !failed.utc_seconds && failed.transport_error == -37,
         "transport failure wins over even plausible or invalid register bytes");
  rtc.error = 0;
  rtc.registers[5] = 2;
  expect(dawn::read_ds3231_utc(rtc).status == dawn::RtcStatus::valid,
         "a successful later observation recovers without stale failure state");
  rtc.registers[15] = 0x0b;
  rtc.registers[14] = 0x1f;
  expect(dawn::read_ds3231_utc(rtc).status == dawn::RtcStatus::valid,
         "alarm flags and unrelated control bits do not invalidate time");
}

void malformed_registers_fail_closed() {
  constexpr std::array<std::pair<std::size_t, std::uint8_t>, 24> kInvalid{
      {{0, 0x1a}, {0, 0x60}, {0, 0x80}, {1, 0x60}, {1, 0x8a},
       {2, 0x24}, {2, 0x40}, {2, 0x53}, {2, 0xc1}, {2, 0x2a},
       {3, 0}, {3, 8}, {3, 0x81}, {4, 0}, {4, 0x32},
       {4, 0x81}, {5, 0}, {5, 0x13}, {5, 0x21}, {5, 0x41},
       {6, 0x1a}, {6, 0xa0}, {1, 0x7f}, {0, 0xff}}};
  for (const auto &[index, value] : kInvalid) {
    FakeRtc rtc;
    rtc.registers[index] = value;
    expect_invalid(rtc, dawn::RtcStatus::invalid_registers);
  }
  FakeRtc rtc;
  rtc.registers[6] = 0x23;
  expect_invalid(rtc, dawn::RtcStatus::invalid_registers);
  rtc.registers[6] = 0;
  expect(dawn::read_ds3231_utc(rtc).status == dawn::RtcStatus::valid,
         "2000 is a Gregorian leap year");
  rtc.registers[4] = 0x31;
  rtc.registers[5] = 0x04;
  expect_invalid(rtc, dawn::RtcStatus::invalid_registers);
}

void esp_idf_transaction_and_error_contract() {
  dawn::EspRtcRegisterReader absent(nullptr);
  auto result = dawn::read_ds3231_utc(absent);
  expect(result.status == dawn::RtcStatus::io_error &&
             result.transport_error == ESP_ERR_INVALID_ARG && bus_reads == 0,
         "null device is an explicit error without an SDK call");
  FakeRtc fixture;
  bus_registers = fixture.registers;
  dawn::EspRtcRegisterReader reader(&device);
  result = dawn::read_ds3231_utc(reader);
  expect(result.utc_seconds == 1709210096 && correct_transaction &&
             bus_reads == 1,
         "IDF adapter makes one bounded combined register-pointer/read call");
  bus_error = ESP_ERR_TIMEOUT;
  result = dawn::read_ds3231_utc(reader);
  expect(result.status == dawn::RtcStatus::io_error &&
             result.transport_error == ESP_ERR_TIMEOUT &&
             !result.utc_seconds && bus_reads == 2,
         "timeout propagates without retries or trusting the receive buffer");
}

} // namespace

int main() {
  calendar_and_hour_modes();
  untrusted_time_and_transport_failures();
  malformed_registers_fail_closed();
  esp_idf_transaction_and_error_contract();
  std::cout << "RTC host fixtures passed\n";
}
