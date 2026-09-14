#include "dawn/nvs_slot_storage.hpp"
#include "nvs_flash.h"

#include <mutex>
#include <new>

namespace dawn {
namespace {
// One lock for the fixed partition, not one per adapter. Recursive acquisition
// lets methods check ownership without racing a caller in a different task.
std::recursive_mutex partition_mutex;
const NvsSlotStorage *transaction_owner{};
bool initialized{};
bool write_uncertain{};
const char *key_for(StorageSlot slot) {
  switch (slot) {
  case StorageSlot::a:
    return "slot_a";
  case StorageSlot::b:
    return "slot_b";
  }
  return nullptr;
}
using TryLock = std::unique_lock<std::recursive_mutex>;
} // namespace

NvsSlotStorage::~NvsSlotStorage() { end_transaction(); }

esp_err_t NvsSlotStorage::initialize() {
  TryLock lock(partition_mutex, std::try_to_lock);
  if (!lock || transaction_owner || write_uncertain)
    return ESP_ERR_INVALID_STATE;
  if (initialized)
    return ESP_OK;
  const auto error = nvs_flash_init_partition("alarm_nvs");
  initialized = error == ESP_OK;
  // Never erase on NO_FREE_PAGES, NEW_VERSION_FOUND, or any other failure.
  return error;
}

bool NvsSlotStorage::begin_transaction() {
  TryLock lock(partition_mutex, std::try_to_lock);
  if (!lock || !initialized || transaction_owner || write_uncertain)
    return false;
  if (nvs_open_from_partition("alarm_nvs", "schedule", NVS_READWRITE,
                              &handle_) != ESP_OK)
    return false;
  transaction_owner = this;
  // Retain one acquisition across the full store read/CAS/write/read-back.
  static_cast<void>(lock.release());
  return true;
}

void NvsSlotStorage::end_transaction() {
  TryLock lock(partition_mutex, std::try_to_lock);
  if (!lock || transaction_owner != this)
    return;
  nvs_close(handle_);
  handle_ = 0;
  transaction_owner = nullptr;
  partition_mutex.unlock(); // release the retained begin_transaction lock
}

SlotReadResult NvsSlotStorage::read(StorageSlot slot) const {
  TryLock lock(partition_mutex, std::try_to_lock);
  const auto *key = key_for(slot);
  if (!lock || transaction_owner != this || !key || write_uncertain)
    return {SlotReadStatus::io_error, {}};
  std::size_t size{};
  const auto status = nvs_get_blob(handle_, key, nullptr, &size);
  if (status == ESP_ERR_NVS_NOT_FOUND)
    return {SlotReadStatus::empty, {}};
  if (status != ESP_OK || size > kMaximumStorageRecordBytes)
    return {SlotReadStatus::io_error, {}};
  // Present-but-empty is corruption for the codec, not an absent slot.
  if (size == 0)
    return {SlotReadStatus::present, {}};
  try {
    std::vector<std::byte> bytes(size);
    auto actual = size;
    if (nvs_get_blob(handle_, key, bytes.data(), &actual) != ESP_OK ||
        actual != size)
      return {SlotReadStatus::io_error, {}};
    return {SlotReadStatus::present, std::move(bytes)};
  } catch (const std::bad_alloc &) {
    return {SlotReadStatus::io_error, {}};
  }
}

bool NvsSlotStorage::write(StorageSlot slot, std::span<const std::byte> bytes) {
  TryLock lock(partition_mutex, std::try_to_lock);
  const auto *key = key_for(slot);
  if (!lock || transaction_owner != this || !key || write_uncertain ||
      bytes.empty() || bytes.size() > kMaximumStorageRecordBytes)
    return false;
  if (nvs_set_blob(handle_, key, bytes.data(), bytes.size()) != ESP_OK ||
      nvs_commit(handle_) != ESP_OK) {
    // NVS close is not rollback. Even a failing call may have changed flash or
    // cache; prevent a later load/retry from authorizing effects from those
    // uncertain bytes. Only reboot and NVS recovery may clear this fault.
    write_uncertain = true;
    return false;
  }
  return true;
}
} // namespace dawn
