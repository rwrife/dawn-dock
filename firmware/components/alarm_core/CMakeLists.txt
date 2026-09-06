idf_component_register(
  SRCS
    "alarm_engine.cpp"
    "committed_schedule_evaluator.cpp"
    "protocol_service.cpp"
    "recurrence_resolver.cpp"
    "schedule_store.cpp"
  INCLUDE_DIRS "include"
)

target_compile_options(${COMPONENT_LIB} PRIVATE
  -Wall
  -Wextra
  -Wpedantic
  -Werror
)
