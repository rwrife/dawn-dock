#pragma once
// Test declarations only; the target uses the pinned ESP-IDF headers.
#include "esp_err.h"

#include <cstddef>
#include <cstdint>

struct i2c_master_dev_t;
using i2c_master_dev_handle_t = i2c_master_dev_t *;

extern "C" esp_err_t i2c_master_transmit_receive(
    i2c_master_dev_handle_t, const std::uint8_t *, std::size_t,
    std::uint8_t *, std::size_t, int);
