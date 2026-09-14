#include "dawn/nvs_slot_storage.hpp"

#include "esp_log.h"

namespace {
constexpr char kTag[] = "dawn_dock";
}

extern "C" void app_main() {
  const auto error = dawn::NvsSlotStorage::initialize();
  if (error != ESP_OK) {
    ESP_LOGE(kTag,
             "alarm storage unavailable (%d); preserving partition, no alarms "
             "started",
             static_cast<int>(error));
    return;
  }
  dawn::NvsSlotStorage backend;
  dawn::AtomicScheduleStore store(backend);
  const auto loaded = store.load();
  if (loaded.status != dawn::LoadStatus::loaded &&
      loaded.status != dawn::LoadStatus::empty) {
    ESP_LOGE(
        kTag,
        "alarm storage fault status=%u; preserving records, no alarms started",
        static_cast<unsigned>(loaded.status));
    return;
  }
  ESP_LOGI(
      kTag,
      "alarm storage status=%u revision=%llu rollback=%u; runtime not wired",
      static_cast<unsigned>(loaded.status),
      static_cast<unsigned long long>(loaded.snapshot.revision),
      static_cast<unsigned>(loaded.corruption_detected));
  // Diagnostic only: no sample schedule, automatic erase, or alert effects.
}
