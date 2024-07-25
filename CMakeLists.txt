cmake_minimum_required( VERSION 3.17 )

project(disnav CXX C)

add_compile_options(
    -Werror=all
    -Wno-deprecated-declarations
    -Wno-error=deprecated-declarations
    -fdiagnostics-color=always
)

find_package(benchmark REQUIRED)

enable_testing()


add_executable(perf 
  perf.cpp
  func.cpp
)

target_link_libraries(perf PRIVATE
  benchmark::benchmark 
)
