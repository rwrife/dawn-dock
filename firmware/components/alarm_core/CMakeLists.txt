idf_component_register(
  SRCS
    "alarm_engine.cpp"
    "committed_alarm_disable.cpp"
    "committed_schedule_evaluator.cpp"
    "invalid_time_recovery.cpp"
    "json_parser.cpp"
    "message_body_validator.cpp"
    "protocol_service.cpp"
    "recurrence_resolver.cpp"
    "schedule_materializer.cpp"
    "schedule_store.cpp"
    "tzif_rules.cpp"
  INCLUDE_DIRS "include"
)

target_compile_options(${COMPONENT_LIB} PRIVATE
  -Wall
  -Wextra
  -Wpedantic
  -Werror
)
