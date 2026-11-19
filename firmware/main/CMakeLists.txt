idf_component_register(
  SRCS "main.cpp"
  REQUIRES alarm_core nvs_storage rtc_hardware
)

target_compile_options(${COMPONENT_LIB} PRIVATE
  -Wall
  -Wextra
  -Wpedantic
  -Werror
)
