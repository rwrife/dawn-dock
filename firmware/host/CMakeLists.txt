cmake_minimum_required(VERSION 3.20)
project(dawn_dock_alarm_host LANGUAGES CXX)

include(CTest)
find_package(Python3 REQUIRED COMPONENTS Interpreter)

add_library(dawn_alarm_core
  ../components/alarm_core/alarm_engine.cpp
  ../components/alarm_core/recurrence_resolver.cpp
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

add_test(
  NAME timezone_fixture_reference_tests
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tests/timezone_fixture_reference_test.py
)
