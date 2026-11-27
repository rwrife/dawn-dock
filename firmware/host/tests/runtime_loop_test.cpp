#include "dawn/runtime_loop.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace {

// 2024-02-29T12:34:56Z, matching the register fixture below.
constexpr std::int64_t kRtcUtc = 1'709'210'096;

int failures = 0;

void expect(bool condition, std::string_view message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
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

class MemorySlotStorage final : public dawn::SlotStorage {
public:
  bool begin_transaction() override {
    if (open) {
      return false;
    }
    open = true;
    ++transactions;
    return true;
  }
  void end_transaction() override { open = false; }
  [[nodiscard]] dawn::SlotReadResult
  read(dawn::StorageSlot slot) const override {
    const auto &record = slots[slot == dawn::StorageSlot::a ? 0U : 1U];
    if (!record) {
      return {.status = dawn::SlotReadStatus::empty, .bytes = {}};
    }
    return {.status = dawn::SlotReadStatus::present, .bytes = *record};
  }
  bool write(dawn::StorageSlot slot,
             std::span<const std::byte> bytes) override {
    if (!open) {
      return false;
    }
    slots[slot == dawn::StorageSlot::a ? 0U : 1U] =
        std::vector<std::byte>(bytes.begin(), bytes.end());
    ++writes;
    return true;
  }

  bool open{};
  int transactions{};
  int writes{};
  std::array<std::optional<std::vector<std::byte>>, 2> slots;
};

dawn::ScheduleSnapshot alarm_at(std::int64_t utc) {
  dawn::ScheduleSnapshot snapshot;
  snapshot.revision = 1;
  snapshot.timezone_rules_version = "2026a";
  snapshot.alarms.push_back({.id = "wake",
                             .schedule_revision = 1,
                             .enabled = true,
                             .scheduled_utc_seconds = utc});
  return snapshot;
}

int start_alerts(const dawn::RuntimeTickResult &tick) {
  return static_cast<int>(std::count_if(
      tick.effects.begin(), tick.effects.end(),
      [](const auto &effect) { return effect.start_alert; }));
}

void due_alarm_rings_once_across_steps() {
  FakeRtc rtc;
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(alarm_at(kRtcUtc), 0).status == dawn::StoreStatus::stored,
         "fixture schedule commits");
  dawn::RuntimeLoop loop(rtc, store, "boot-1");

  const auto first = loop.step(10);
  expect(first.rtc_status == dawn::RtcStatus::valid, "first sample is valid");
  expect(first.tick.status == dawn::RuntimeTickStatus::evaluated,
         "first step evaluates");
  expect(start_alerts(first.tick) == 1, "due alarm starts exactly once");

  const auto second = loop.step(11);
  expect(second.tick.status == dawn::RuntimeTickStatus::evaluated,
         "second step evaluates");
  expect(start_alerts(second.tick) == 0,
         "same boot ID never repeats the start edge");
  expect(rtc.reads == 2, "each step samples the RTC exactly once");
}

void unusable_rtc_freezes_without_store_access() {
  FakeRtc rtc;
  rtc.error = 5;
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(alarm_at(kRtcUtc), 0).status == dawn::StoreStatus::stored,
         "fixture schedule commits");
  const int writes_before = backend.writes;
  const int transactions_before = backend.transactions;
  dawn::RuntimeLoop loop(rtc, store, "boot-1");

  const auto step = loop.step(10);
  expect(step.rtc_status == dawn::RtcStatus::io_error, "I2C failure reported");
  expect(step.transport_error == 5, "transport error is preserved");
  expect(step.tick.status == dawn::RuntimeTickStatus::frozen_invalid_time,
         "unusable RTC freezes scheduling");
  expect(step.tick.effects.empty(), "frozen tick has no effects");
  expect(backend.writes == writes_before &&
             backend.transactions == transactions_before,
         "frozen tick performs no storage access");
}

void oscillator_stopped_freezes_then_recovers() {
  FakeRtc rtc;
  rtc.registers[0x0f] = 0x80; // OSF set: time untrustworthy
  MemorySlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  expect(store.save(alarm_at(kRtcUtc), 0).status == dawn::StoreStatus::stored,
         "fixture schedule commits");
  dawn::RuntimeLoop loop(rtc, store, "boot-1");

  const auto frozen = loop.step(10);
  expect(frozen.rtc_status == dawn::RtcStatus::oscillator_stopped,
         "OSF reported");
  expect(frozen.tick.status == dawn::RuntimeTickStatus::frozen_invalid_time,
         "OSF freezes scheduling");

  rtc.registers[0x0f] = 0x00;
  const auto recovered = loop.step(11);
  expect(recovered.rtc_status == dawn::RtcStatus::valid, "RTC valid again");
  expect(recovered.tick.reconciliation_attempted,
         "the invalid interval is reconciled before admission");
}

} // namespace

int main() {
  due_alarm_rings_once_across_steps();
  unusable_rtc_freezes_without_store_access();
  oscillator_stopped_freezes_then_recovers();
  if (failures != 0) {
    return EXIT_FAILURE;
  }
  std::cout << "runtime_loop_tests passed\n";
  return EXIT_SUCCESS;
}
