idf_component_register(
  SRCS "esp_rtc_register_reader.cpp"
  INCLUDE_DIRS "include"
  REQUIRES alarm_core esp_driver_i2c
)
target_compile_features(${COMPONENT_LIB} PUBLIC cxx_std_20)
# ESP-IDF's I2C headers include newlib's GNU #include_next wrapper.
# The same binding is still built with -Wpedantic -Werror by host tests.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
