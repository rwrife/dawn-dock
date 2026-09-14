#pragma once
// Test double declarations only. Production includes the ESP-IDF v5.5.5
// headers.
#include <cstddef>
#include <cstdint>
using esp_err_t = int;
using nvs_handle_t = std::uint32_t;
enum nvs_open_mode_t { NVS_READONLY, NVS_READWRITE };
constexpr esp_err_t ESP_OK = 0;
constexpr esp_err_t ESP_FAIL = -1;
constexpr esp_err_t ESP_ERR_INVALID_STATE = 0x103;
constexpr esp_err_t ESP_ERR_NVS_NOT_FOUND = 0x1102;
constexpr esp_err_t ESP_ERR_NVS_INVALID_LENGTH = 0x110c;
extern "C" {
esp_err_t nvs_open_from_partition(const char *, const char *, nvs_open_mode_t,
                                  nvs_handle_t *);
void nvs_close(nvs_handle_t);
esp_err_t nvs_get_blob(nvs_handle_t, const char *, void *, std::size_t *);
esp_err_t nvs_set_blob(nvs_handle_t, const char *, const void *, std::size_t);
esp_err_t nvs_commit(nvs_handle_t);
}
