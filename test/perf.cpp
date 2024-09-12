#include "func.h"
#include <benchmark/benchmark.h>


int test_call(int arg) {
    return arg + 42;
}

void bm_book(benchmark::State &state) {
  size_t test = 0;

  // another use case is a jump to a call under cursor
  for (int i = 0; i < 100; ++i) {
    test += 1;
    test = calc(test_call(std::string("test").size()), test + 1);
  }
}

BENCHMARK(bm_book)->Unit(benchmark::kMillisecond)->Repetitions(1);

BENCHMARK_MAIN();
