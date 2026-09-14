#pragma once

#include "dawn/schedule_store.hpp"
#include "nvs.h"

namespace dawn {
// Fixed alarm_nvs partition / schedule namespace. Initialize at startup; never
// erase automatically. Contended transactions fail immediately (caller
// retries). Begin/end and destruction of an active adapter must occur in the
// same task; adapter lifetime must outlive all users. Do not access these keys
// outside this class. Write uncertainty faults the whole partition until
// reboot, not merely this instance. initialize() cannot clear that fault.
class NvsSlotStorage final : public SlotStorage {
public:
  NvsSlotStorage() = default;
  ~NvsSlotStorage() override;
  NvsSlotStorage(const NvsSlotStorage &) = delete;
  NvsSlotStorage &operator=(const NvsSlotStorage &) = delete;
  [[nodiscard]] static esp_err_t initialize();
  bool begin_transaction() override;
  void end_transaction() override;
  [[nodiscard]] SlotReadResult read(StorageSlot slot) const override;
  bool write(StorageSlot slot, std::span<const std::byte> bytes) override;

private:
  nvs_handle_t handle_{};
};
} // namespace dawn
