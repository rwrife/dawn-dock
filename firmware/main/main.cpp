#include "dawn/nvs_slot_storage.hpp"
#include "dawn/esp_rtc_register_reader.hpp"
#include "dawn/rtc.hpp"
#include "dawn/runtime_loop.hpp"

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <cstdint>
#include <cstdio>
#include <new>
#include <string>
#include <utility>

namespace {
constexpr char kTag[] = "dawn_dock";
constexpr gpio_num_t kI2cSda = GPIO_NUM_8;
constexpr gpio_num_t kI2cScl = GPIO_NUM_9;
constexpr std::uint32_t kI2cClockHz = 100000;

const char *rtc_status_name(dawn::RtcStatus status) {
  switch (status) {
  case dawn::RtcStatus::valid:
    return "valid";
  case dawn::RtcStatus::io_error:
    return "io_error";
  case dawn::RtcStatus::oscillator_stopped:
    return "oscillator_stopped";
  case dawn::RtcStatus::backup_oscillator_disabled:
    return "backup_oscillator_disabled";
  case dawn::RtcStatus::invalid_registers:
    return "invalid_registers";
  case dawn::RtcStatus::unsupported_century:
    return "unsupported_century";
  }
  return "unknown";
}

constexpr std::int64_t kMicrosecondsPerSecond = 1'000'000;
constexpr std::uint32_t kRuntimeStackBytes = 8192;
constexpr UBaseType_t kRuntimePriority = 5;
constexpr std::uint32_t kStepPeriodMilliseconds = 1000;

// Lives for the whole boot: the runtime task borrows it forever.
struct Runtime {
  Runtime(i2c_master_bus_handle_t bus_handle,
          i2c_master_dev_handle_t device_handle, std::string boot_id)
      : bus(bus_handle), device(device_handle), reader(device_handle),
        store(backend), loop(reader, store, std::move(boot_id)) {}

  i2c_master_bus_handle_t bus;
  i2c_master_dev_handle_t device;
  dawn::EspRtcRegisterReader reader;
  dawn::NvsSlotStorage backend;
  dawn::AtomicScheduleStore store;
  dawn::RuntimeLoop loop;
};

std::string make_boot_id() {
  // Distinct per reset; esp_random is hardware-backed once RF/bootloader
  // entropy is active and is only an identifier here, never a secret.
  char buffer[17];
  std::snprintf(buffer, sizeof(buffer), "%08lx%08lx",
                static_cast<unsigned long>(esp_random()),
                static_cast<unsigned long>(esp_random()));
  return buffer;
}

void release_i2c(i2c_master_bus_handle_t bus,
                 i2c_master_dev_handle_t device) {
  if (device != nullptr) {
    const auto remove_error = i2c_master_bus_rm_device(device);
    if (remove_error != ESP_OK) {
      ESP_LOGE(kTag, "RTC I2C device cleanup failed (%d)",
               static_cast<int>(remove_error));
    }
  }
  const auto delete_error = i2c_del_master_bus(bus);
  if (delete_error != ESP_OK) {
    ESP_LOGE(kTag, "RTC I2C bus cleanup failed (%d)",
             static_cast<int>(delete_error));
  }
}

void log_step_changes(const dawn::RuntimeLoopStep &step,
                      const dawn::RuntimeLoopStep &previous, bool first) {
  if (first || step.rtc_status != previous.rtc_status ||
      step.tick.status != previous.tick.status) {
    ESP_LOGI(kTag, "runtime rtc=%s transport=%d tick=%u revision=%llu",
             rtc_status_name(step.rtc_status),
             static_cast<int>(step.transport_error),
             static_cast<unsigned>(step.tick.status),
             static_cast<unsigned long long>(step.tick.schedule_revision));
  }
  for (const auto &effect : step.tick.effects) {
    if (effect.start_alert || effect.stop_alert) {
      // Display/audio effects are not integrated yet; the durable journal
      // commit already happened before this edge was reported.
      ESP_LOGI(kTag, "alarm edge id=%s start=%d stop=%d late=%d",
               effect.alarm_id.c_str(), static_cast<int>(effect.start_alert),
               static_cast<int>(effect.stop_alert),
               static_cast<int>(effect.late));
    }
  }
}

void runtime_task(void *argument) {
  auto &runtime = *static_cast<Runtime *>(argument);
  dawn::RuntimeLoopStep previous;
  bool first = true;
  for (;;) {
    const auto monotonic_seconds =
        esp_timer_get_time() / kMicrosecondsPerSecond;
    auto step = runtime.loop.step(monotonic_seconds);
    log_step_changes(step, previous, first);
    previous = std::move(step);
    first = false;
    vTaskDelay(pdMS_TO_TICKS(kStepPeriodMilliseconds));
  }
}

// Opens the RTC bus and starts the one-second runtime task. On any failure
// the I2C resources are released and no alarm runs (time stays invalid).
void start_runtime() {
  i2c_master_bus_config_t bus_config{};
  bus_config.i2c_port = I2C_NUM_0;
  bus_config.sda_io_num = kI2cSda;
  bus_config.scl_io_num = kI2cScl;
  bus_config.clk_source = I2C_CLK_SRC_DEFAULT;
  bus_config.glitch_ignore_cnt = 7;
  // The selected modules supply external pull-ups; aggregate bus rise time
  // still requires measurement on the received hardware.
  bus_config.flags.enable_internal_pullup = false;

  i2c_master_bus_handle_t bus{};
  auto error = i2c_new_master_bus(&bus_config, &bus);
  if (error != ESP_OK) {
    ESP_LOGE(kTag, "RTC I2C bus unavailable (%d); no alarms started",
             static_cast<int>(error));
    return;
  }

  i2c_device_config_t device_config{};
  device_config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
  device_config.device_address = dawn::kDs3231I2cAddress;
  device_config.scl_speed_hz = kI2cClockHz;
  i2c_master_dev_handle_t device{};
  error = i2c_master_bus_add_device(bus, &device_config, &device);
  if (error != ESP_OK) {
    ESP_LOGE(kTag, "RTC I2C device unavailable (%d); no alarms started",
             static_cast<int>(error));
    release_i2c(bus, nullptr);
    return;
  }

  auto *runtime = new (std::nothrow) Runtime(bus, device, make_boot_id());
  if (runtime == nullptr) {
    ESP_LOGE(kTag, "runtime allocation failed; no alarms started");
    release_i2c(bus, device);
    return;
  }
  if (xTaskCreate(runtime_task, "dawn_runtime", kRuntimeStackBytes, runtime,
                  kRuntimePriority, nullptr) != pdPASS) {
    ESP_LOGE(kTag, "runtime task creation failed; no alarms started");
    release_i2c(bus, device);
    delete runtime;
    return;
  }
}
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
      "alarm storage status=%u revision=%llu rollback=%u",
      static_cast<unsigned>(loaded.status),
      static_cast<unsigned long long>(loaded.snapshot.revision),
      static_cast<unsigned>(loaded.corruption_detected));
  // Storage is verified; the runtime task now samples the RTC every second
  // and evaluates the persisted schedule. Alert effects are log-only until
  // the display/audio paths are integrated.
  start_runtime();
}
