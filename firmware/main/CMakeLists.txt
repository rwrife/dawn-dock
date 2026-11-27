idf_component_register(
  SRCS "main.cpp"
  REQUIRES alarm_core nvs_storage rtc_hardware esp_driver_gpio esp_driver_i2c
)

target_compile_options(${COMPONENT_LIB} PRIVATE
  -Wall
  -Wextra
  -Wpedantic
  -Werror
)
