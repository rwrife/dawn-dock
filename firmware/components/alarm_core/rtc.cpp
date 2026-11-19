#include "dawn/rtc.hpp"

#include <array>

namespace dawn {
namespace {

int decode_bcd(std::uint8_t value, int minimum, int maximum) {
  const int ones = value & 0x0f;
  const int tens = value >> 4;
  const int decoded = tens * 10 + ones;
  return ones <= 9 && tens <= 9 && decoded >= minimum && decoded <= maximum
             ? decoded
             : -1;
}

bool leap_year(int year) {
  return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

} // namespace

RtcObservation read_ds3231_utc(RtcRegisterReader &reader) {
  std::array<std::uint8_t, kDs3231SnapshotBytes> registers{};
  const auto error = reader.read_snapshot(registers);
  if (error != 0) {
    return {RtcStatus::io_error, std::nullopt, error};
  }
  if ((registers[15] & 0x80) != 0) {
    return {RtcStatus::oscillator_stopped, std::nullopt, 0};
  }
  if ((registers[14] & 0x80) != 0) {
    return {RtcStatus::backup_oscillator_disabled, std::nullopt, 0};
  }
  if ((registers[5] & 0x80) != 0) {
    return {RtcStatus::unsupported_century, std::nullopt, 0};
  }

  const int second = decode_bcd(registers[0], 0, 59);
  const int minute = decode_bcd(registers[1], 0, 59);
  int hour = -1;
  if ((registers[2] & 0x40) != 0 && (registers[2] & 0x80) == 0) {
    const int twelve_hour = decode_bcd(registers[2] & 0x1f, 1, 12);
    if (twelve_hour != -1) {
      hour = twelve_hour % 12 + ((registers[2] & 0x20) != 0 ? 12 : 0);
    }
  } else {
    hour = decode_bcd(registers[2], 0, 23);
  }
  const int weekday = decode_bcd(registers[3], 1, 7);
  const int date = decode_bcd(registers[4], 1, 31);
  const int month = decode_bcd(registers[5], 1, 12);
  const int year = decode_bcd(registers[6], 0, 99);
  if (second == -1 || minute == -1 || hour == -1 || weekday == -1 ||
      date == -1 || month == -1 || year == -1) {
    return {RtcStatus::invalid_registers, std::nullopt, 0};
  }

  constexpr std::array<int, 12> kMonthDays{
      31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  const int full_year = 2000 + year;
  const int days_in_month =
      kMonthDays[month - 1] + (month == 2 && leap_year(full_year) ? 1 : 0);
  if (date > days_in_month) {
    return {RtcStatus::invalid_registers, std::nullopt, 0};
  }

  // The supported 2000..2099 range makes this bounded and independent of
  // host/target time_t width, libc timezone state, and weekday numbering.
  std::int64_t days = 10957; // 1970-01-01 to 2000-01-01.
  for (int current = 2000; current < full_year; ++current) {
    days += leap_year(current) ? 366 : 365;
  }
  for (int current = 1; current < month; ++current) {
    days += kMonthDays[current - 1] +
            (current == 2 && leap_year(full_year) ? 1 : 0);
  }
  days += date - 1;
  return {RtcStatus::valid,
          days * 86400 + hour * 3600 + minute * 60 + second, 0};
}

} // namespace dawn
