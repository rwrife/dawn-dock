#pragma once
void dawn_test_log(bool error, const char *tag, const char *format, ...);
#define ESP_LOGI(tag, ...) dawn_test_log(false, tag, __VA_ARGS__)
#define ESP_LOGE(tag, ...) dawn_test_log(true, tag, __VA_ARGS__)
