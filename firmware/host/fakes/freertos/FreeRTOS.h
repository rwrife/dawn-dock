#pragma once
// Test declarations only; the target uses the pinned ESP-IDF headers.
#include <cstdint>

using BaseType_t = int;
using UBaseType_t = unsigned;
using TickType_t = std::uint32_t;
constexpr BaseType_t pdPASS = 1;
constexpr BaseType_t pdFAIL = 0;
constexpr TickType_t pdMS_TO_TICKS(std::uint32_t ms) { return ms; }
