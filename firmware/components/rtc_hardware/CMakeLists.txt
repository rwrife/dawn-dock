idf_component_register(
  SRCS "esp_rtc_register_reader.cpp"
  INCLUDE_DIRS "include"
  REQUIRES alarm_core esp_driver_i2c
)
target_compile_features(${COMPONENT_LIB} PUBLIC cxx_std_20)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Wpedantic -Werror)
