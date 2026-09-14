idf_component_register(
  SRCS "nvs_slot_storage.cpp"
  INCLUDE_DIRS "include"
  REQUIRES alarm_core nvs_flash
)
target_compile_features(${COMPONENT_LIB} PUBLIC cxx_std_20)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Wpedantic -Werror)
