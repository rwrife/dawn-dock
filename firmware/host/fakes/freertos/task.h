#pragma once
#include "freertos/FreeRTOS.h"

#include <cstdint>

using TaskHandle_t = void *;
using TaskFunction_t = void (*)(void *);

extern "C" BaseType_t xTaskCreate(TaskFunction_t, const char *, std::uint32_t,
                                  void *, UBaseType_t, TaskHandle_t *);
extern "C" void vTaskDelay(TickType_t);
