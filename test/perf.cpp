#include "func.h"
#include <benchmark/benchmark.h>

void bm_book(benchmark::State &state) {
  size_t test = 0;

  // another use case is a quick asm diff
  for (int i = 0; i < 100; ++i) {
    test += 0;
    test = calc(test, test + 1);
  }
}

BENCHMARK(bm_book)->Unit(benchmark::kMillisecond)->Repetitions(1);

BENCHMARK_MAIN();
