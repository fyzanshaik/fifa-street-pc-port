// Calls the real runtime clock from competing readers. No game or device.
#include <rex/chrono/clock.h>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <thread>
#include <vector>
#include <algorithm>

using Clock = rex::chrono::Clock;
static double CpuUs() {
  timespec t{};
  if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)) std::exit(2);
  return double(t.tv_sec) * 1e6 + double(t.tv_nsec) / 1000;
}
int main(int argc, char**) {
  Clock::set_guest_tick_frequency(50000000);
  Clock::set_guest_time_scalar(1.0);
  bool fail = false;
  for (bool unscaled : {false, true}) {
    REXCVAR_SET(clock_no_scaling, unscaled);
    for (int readers : {1, 8}) {
      struct Result {double cpu_us = 0; bool monotonic = true; std::vector<double> samples;};
      std::array<Result, 8> results;
      std::atomic<int> ready{0}; std::atomic<bool> start{false};
      std::vector<std::thread> threads;
      constexpr int calls = 100000;
      for (int t = 0; t < readers; ++t) threads.emplace_back([&, t] {
        results[t].samples.reserve(calls / 64 + 1);
        ready.fetch_add(1);
        while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
        const double cpu_start = CpuUs();
        uint64_t previous = Clock::QueryGuestTickCount();
        for (int i = 0; i < calls; ++i) {
          const bool sample = (i % 64) == 0;
          const auto before = sample ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
          const auto value = Clock::QueryGuestTickCount();
          if (value < previous) results[t].monotonic = false;
          previous = value;
          if (sample) results[t].samples.push_back(
              std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - before).count());
        }
        results[t].cpu_us = CpuUs() - cpu_start;
      });
      while (ready.load() != readers) std::this_thread::yield();
      const auto wall_start = std::chrono::steady_clock::now();
      const auto host_start = Clock::QueryHostTickCount(), guest_start = Clock::QueryGuestTickCount();
      start.store(true, std::memory_order_release);
      for (auto& thread : threads) thread.join();
      const auto guest_end = Clock::QueryGuestTickCount(), host_end = Clock::QueryHostTickCount();
      const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall_start).count();
      std::vector<double> samples; double cpu = 0; bool monotonic = true;
      for (int t = 0; t < readers; ++t) {
        cpu += results[t].cpu_us; monotonic &= results[t].monotonic;
        samples.insert(samples.end(), results[t].samples.begin(), results[t].samples.end());
      }
      std::sort(samples.begin(), samples.end());
      const double p95 = samples[samples.size() * 95 / 100];
      const double clock_rate = double(guest_end - guest_start) / double(host_end - host_start) *
                                double(Clock::QueryHostTickFrequency()) / double(Clock::guest_tick_frequency());
      std::printf("clock_no_scaling=%d readers=%d calls=%d queries_per_s=%.0f "
                  "median_us=%.3f p95_us=%.3f max_us=%.3f cpu_us_per_query=%.3f "
                  "guest_to_host_rate=%.6f monotonic=%d\n", unscaled, readers, readers*calls,
                  readers*calls/wall, samples[samples.size()/2], p95, samples.back(),
                  cpu/(readers*calls), clock_rate, monotonic);
      fail |= !monotonic;
      // The clock must preserve normal-speed elapsed time under a read-heavy load.
      // This real-host timing check complements deterministic conversion tests.
      if (argc > 1 && (clock_rate < 0.995 || clock_rate > 1.005)) {
        std::puts("FAIL elapsed-clock rate: query load changes nominal 1x time by more than 0.5%");
        fail = true;
      }
    }
  }
  return fail ? 1 : 0;
}
