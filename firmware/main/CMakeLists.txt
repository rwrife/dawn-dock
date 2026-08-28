idf_component_register(
  SRCS "main.cpp"
  REQUIRES alarm_core
)

target_compile_options(${COMPONENT_LIB} PRIVATE
  -Wall
  -Wextra
  -Wpedantic
  -Werror
)
