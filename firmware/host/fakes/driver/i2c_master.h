#pragma once
// Test declarations only; the target uses the pinned ESP-IDF headers.
#include "driver/gpio.h"
#include "esp_err.h"

#include <cstddef>
#include <cstdint>

struct i2c_master_dev_t;
struct i2c_master_bus_t;
using i2c_master_dev_handle_t = i2c_master_dev_t *;
using i2c_master_bus_handle_t = i2c_master_bus_t *;

using i2c_port_num_t = int;
constexpr i2c_port_num_t I2C_NUM_0 = 0;
enum i2c_clock_source_t { I2C_CLK_SRC_DEFAULT };
enum i2c_addr_bit_len_t { I2C_ADDR_BIT_LEN_7 };

struct i2c_master_bus_config_t {
  i2c_port_num_t i2c_port{};
  gpio_num_t sda_io_num{};
  gpio_num_t scl_io_num{};
  i2c_clock_source_t clk_source{};
  std::uint8_t glitch_ignore_cnt{};
  int intr_priority{};
  std::size_t trans_queue_depth{};
  struct {
    bool enable_internal_pullup{};
  } flags;
};

struct i2c_device_config_t {
  i2c_addr_bit_len_t dev_addr_length{};
  std::uint16_t device_address{};
  std::uint32_t scl_speed_hz{};
  std::uint32_t scl_wait_us{};
  struct {
    bool disable_ack_check{};
  } flags;
};

extern "C" esp_err_t i2c_new_master_bus(const i2c_master_bus_config_t *,
                                        i2c_master_bus_handle_t *);
extern "C" esp_err_t i2c_master_bus_add_device(
    i2c_master_bus_handle_t, const i2c_device_config_t *,
    i2c_master_dev_handle_t *);
extern "C" esp_err_t i2c_master_bus_rm_device(i2c_master_dev_handle_t);
extern "C" esp_err_t i2c_del_master_bus(i2c_master_bus_handle_t);

extern "C" esp_err_t i2c_master_transmit_receive(
    i2c_master_dev_handle_t, const std::uint8_t *, std::size_t,
    std::uint8_t *, std::size_t, int);
