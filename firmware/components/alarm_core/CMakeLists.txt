idf_component_register(
  SRCS "alarm_engine.cpp"
  INCLUDE_DIRS "include"
)

target_compile_options(${COMPONENT_LIB} PRIVATE
  -Wall
  -Wextra
  -Wpedantic
  -Werror
)
