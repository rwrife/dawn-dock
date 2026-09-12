cmake_minimum_required(VERSION 3.20)
project(dawn_dock_alarm_host LANGUAGES CXX)

include(CTest)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

add_library(dawn_alarm_core
  ../components/alarm_core/alarm_engine.cpp
  ../components/alarm_core/committed_alarm_disable.cpp
  ../components/alarm_core/committed_schedule_evaluator.cpp
  ../components/alarm_core/invalid_time_recovery.cpp
  ../components/alarm_core/json_parser.cpp
  ../components/alarm_core/message_body_validator.cpp
  ../components/alarm_core/protocol_service.cpp
  ../components/alarm_core/recurrence_resolver.cpp
  ../components/alarm_core/schedule_materializer.cpp
  ../components/alarm_core/schedule_store.cpp
  ../components/alarm_core/tzif_rules.cpp
)
target_include_directories(dawn_alarm_core PUBLIC
  ../components/alarm_core/include
)
target_compile_features(dawn_alarm_core PUBLIC cxx_std_20)
target_compile_options(dawn_alarm_core PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(alarm_engine_tests tests/alarm_engine_test.cpp)
target_link_libraries(alarm_engine_tests PRIVATE dawn_alarm_core)
target_compile_options(alarm_engine_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME alarm_engine_tests COMMAND alarm_engine_tests)

add_executable(schedule_store_tests tests/schedule_store_test.cpp)
target_link_libraries(schedule_store_tests PRIVATE dawn_alarm_core)
target_compile_options(schedule_store_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME schedule_store_tests COMMAND schedule_store_tests)

add_executable(recurrence_resolver_tests tests/recurrence_resolver_test.cpp)
target_link_libraries(recurrence_resolver_tests PRIVATE dawn_alarm_core)
target_compile_options(recurrence_resolver_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME recurrence_resolver_tests COMMAND recurrence_resolver_tests)

add_executable(committed_schedule_evaluator_tests
  tests/committed_schedule_evaluator_test.cpp
)
target_link_libraries(committed_schedule_evaluator_tests PRIVATE dawn_alarm_core)
target_compile_options(committed_schedule_evaluator_tests PRIVATE
  -Wall -Wextra -Wpedantic -Werror
)
add_test(NAME committed_schedule_evaluator_tests
  COMMAND committed_schedule_evaluator_tests
)

add_executable(protocol_service_tests tests/protocol_service_test.cpp)
target_link_libraries(protocol_service_tests PRIVATE dawn_alarm_core)
target_compile_options(protocol_service_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME protocol_service_tests COMMAND protocol_service_tests)

add_executable(message_body_validator_tests
  tests/message_body_validator_test.cpp
)
target_link_libraries(message_body_validator_tests PRIVATE dawn_alarm_core)
target_compile_options(message_body_validator_tests PRIVATE
  -Wall -Wextra -Wpedantic -Werror
)
add_test(NAME message_body_validator_tests
  COMMAND message_body_validator_tests
)

add_executable(protocol_fixture_cross_language_tests
  tests/protocol_fixture_cross_language_test.cpp
)
target_link_libraries(protocol_fixture_cross_language_tests PRIVATE
  dawn_alarm_core
)
target_compile_definitions(protocol_fixture_cross_language_tests PRIVATE
  DAWN_FIXTURE_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/../../docs/protocol/fixtures/v1"
)
target_compile_options(protocol_fixture_cross_language_tests PRIVATE
  -Wall -Wextra -Wpedantic -Werror
)
add_test(NAME protocol_fixture_cross_language_tests
  COMMAND protocol_fixture_cross_language_tests
)

add_executable(schedule_materializer_tests tests/schedule_materializer_test.cpp)
target_link_libraries(schedule_materializer_tests PRIVATE dawn_alarm_core)
target_compile_options(schedule_materializer_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME schedule_materializer_tests COMMAND schedule_materializer_tests)

add_executable(committed_alarm_disable_tests
  tests/committed_alarm_disable_test.cpp
)
target_link_libraries(committed_alarm_disable_tests PRIVATE dawn_alarm_core)
target_compile_options(committed_alarm_disable_tests PRIVATE
  -Wall -Wextra -Wpedantic -Werror
)
add_test(NAME committed_alarm_disable_tests
  COMMAND committed_alarm_disable_tests
)

add_executable(invalid_time_recovery_tests
  tests/invalid_time_recovery_test.cpp
)
target_link_libraries(invalid_time_recovery_tests PRIVATE dawn_alarm_core)
target_compile_options(invalid_time_recovery_tests PRIVATE
  -Wall -Wextra -Wpedantic -Werror
)
add_test(NAME invalid_time_recovery_tests COMMAND invalid_time_recovery_tests)

add_executable(tzif_rules_tests tests/tzif_rules_test.cpp)
target_link_libraries(tzif_rules_tests PRIVATE dawn_alarm_core)
target_compile_definitions(tzif_rules_tests PRIVATE
  DAWN_TZIF_FIXTURE_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/fixtures/tzif/2026c"
)
target_compile_options(tzif_rules_tests PRIVATE
  -Wall -Wextra -Wpedantic -Werror
)
add_test(NAME tzif_rules_tests COMMAND tzif_rules_tests)

add_test(
  NAME tzif_adapter_reference_tests
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/tzif_adapter_reference_test.py
)

add_test(
  NAME timezone_fixture_reference_tests
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/timezone_fixture_reference_test.py
)

add_test(
  NAME protocol_fixture_contract_tests
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/protocol_fixture_contract_test.py
)
