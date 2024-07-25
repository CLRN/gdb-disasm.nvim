#include <benchmark/benchmark.h>


template <typename MatcherType>
void bm_book(benchmark::State& state)
{
    int test = 0;
    for (auto _ : state) {
        ++test;
    }

    // state.SetItemsProcessed(static_cast<int64_t>(state.iterations()) *
    //                         messages.size());
    state.counters["updates"] = test;
}

BENCHMARK(bm_book<int>)->Unit(benchmark::kMillisecond)->Repetitions(1);

BENCHMARK_MAIN();
