#include "dawn/alarm_engine.hpp"

#include "esp_log.h"

namespace {
constexpr char kTag[] = "dawn_dock";
}

extern "C" void app_main() {
  dawn::PersistentAlarmState alarm_state;
  ESP_LOGI(kTag, "offline alarm core initialized (terminal records: %u)",
           static_cast<unsigned>(alarm_state.terminal.size()));
}
