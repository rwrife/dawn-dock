#include "dawn/nvs_slot_storage.hpp"
#include "dawn/esp_rtc_register_reader.hpp"
#include "dawn/rtc.hpp"

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "esp_log.h"

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

void sample_rtc_at_startup() {
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
    ESP_LOGE(kTag, "RTC I2C bus unavailable (%d); time remains invalid",
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
    ESP_LOGE(kTag, "RTC I2C device unavailable (%d); time remains invalid",
             static_cast<int>(error));
    const auto delete_error = i2c_del_master_bus(bus);
    if (delete_error != ESP_OK) {
      ESP_LOGE(kTag, "RTC I2C bus cleanup failed (%d)",
               static_cast<int>(delete_error));
    }
    return;
  }

  dawn::EspRtcRegisterReader reader(device);
  const auto observation = dawn::read_ds3231_utc(reader);
  if (observation.status == dawn::RtcStatus::valid &&
      observation.utc_seconds.has_value()) {
    ESP_LOGI(kTag, "RTC startup sample valid; UTC seconds=%lld",
             static_cast<long long>(*observation.utc_seconds));
  } else {
    ESP_LOGE(kTag, "RTC startup sample unusable; status=%s transport=%d",
             rtc_status_name(observation.status),
             static_cast<int>(observation.transport_error));
  }

  const auto remove_error = i2c_master_bus_rm_device(device);
  if (remove_error != ESP_OK) {
    ESP_LOGE(kTag, "RTC I2C device cleanup failed (%d)",
             static_cast<int>(remove_error));
  }
  const auto delete_error = i2c_del_master_bus(bus);
  if (delete_error != ESP_OK) {
    ESP_LOGE(kTag, "RTC I2C bus cleanup failed (%d)",
             static_cast<int>(delete_error));
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
  // One read-only sample validates RTC transport/time at startup. Runtime
  // scheduling and alert effects remain disabled until their target paths
  // are integrated.
  sample_rtc_at_startup();
}
