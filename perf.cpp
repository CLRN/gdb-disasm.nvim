#include "func.h"
// #include <benchmark/benchmark.h>
// #include <string>
//
//
// template <typename MatcherType>
// void bm_book(benchmark::State& state)
// {
//     size_t test = 0;
//     test = calc(test, test + 1);
//     std::string s(test, 'a');
//     s.size();
//     // for (auto _ : state) {
//     // }
//
//     // state.SetItemsProcessed(static_cast<int64_t>(state.iterations()) *
//     //                         messages.size());
//     state.counters["updates"] = test;
// }
//
// BENCHMARK(bm_book<int>)->Unit(benchmark::kMillisecond)->Repetitions(1);
//
// BENCHMARK_MAIN();
#include <string>


int main(int argc, char** argv) {

    size_t test = 1;

    test = calc(test, test + 1);

    // test
    test = calc2(test);

    std::string s(argc, 'a');
    return s.size();
}
