cmake_minimum_required(VERSION 3.20)
project(dawn_dock_alarm_host LANGUAGES CXX)

include(CTest)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

add_library(dawn_alarm_core
  ../components/alarm_core/alarm_engine.cpp
  ../components/alarm_core/committed_schedule_evaluator.cpp
  ../components/alarm_core/protocol_service.cpp
  ../components/alarm_core/recurrence_resolver.cpp
  ../components/alarm_core/schedule_materializer.cpp
  ../components/alarm_core/schedule_store.cpp
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

add_executable(schedule_materializer_tests tests/schedule_materializer_test.cpp)
target_link_libraries(schedule_materializer_tests PRIVATE dawn_alarm_core)
target_compile_options(schedule_materializer_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME schedule_materializer_tests COMMAND schedule_materializer_tests)

add_test(
  NAME timezone_fixture_reference_tests
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/timezone_fixture_reference_test.py
)

add_test(
  NAME protocol_fixture_contract_tests
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/protocol_fixture_contract_test.py
)
