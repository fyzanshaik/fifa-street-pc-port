// Deterministic and concurrent tests of the exact Mac runtime mapping helper.
#include "guest_clock_mapping.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

using rex::chrono::detail::GuestClockMapping;
using rex::chrono::detail::GuestClockSnapshot;
static int checks = 0;
static void Check(bool pass, const char* name) {
  if (!pass) { std::fprintf(stderr, "FAIL %s\n", name); std::exit(1); }
  ++checks;
  std::printf("PASS %s\n", name);
}

int main() {
  uint64_t host = 100;
  auto query = [&] { return host; };
  GuestClockMapping clock(host, 50000000, 123000000);
  clock.Update(query, [](auto& state) { state.numerator = 25; state.denominator = 12; });
  Check(clock.Read(query).Ticks() == 0, "zero guest origin");
  for (host = 101; host <= 112; ++host) {
    Check(clock.Read(query).Ticks() == (host - 100) * 25 / 12,
          "25/12 conversion preserves fractions across frequent reads");
    for (int i = 0; i < 100; ++i) Check(clock.Read(query).Ticks() == (host - 100) * 25 / 12,
                                      "reads at the same host time do not change the clock");
  }
  host = 112;
  Check(clock.Read(query).Ticks() == 25, "twelve host ticks produce twenty-five guest ticks");
  clock.Update(query, [](auto& state) { state.numerator = 25; state.denominator = 24; state.scalar = .5; });
  Check(clock.Read(query).Ticks() == 25, "scalar change preserves tick continuity");
  host = 136;
  Check(clock.Read(query).Ticks() == 50 && clock.Read(query).scalar == .5, "half-speed interval");
  clock.Update(query, [](auto& state) { state.numerator = 25; state.denominator = 6; state.scalar = 2; });
  host = 142;
  Check(clock.Read(query).Ticks() == 75, "double-speed interval");
  clock.Update(query, [](auto& state) { state.system_base = 900000000 - state.SystemOffset(); });
  auto state = clock.Read(query);
  Check(state.system_base + state.SystemOffset() == 900000000, "system time override");
  clock.Update(query, [](auto& state) { state.frequency = 100000000; state.numerator = 25; state.denominator = 3; });
  Check(clock.Read(query).Ticks() == 75, "frequency change preserves tick continuity");
  host = 154;
  Check(clock.Read(query).Ticks() == 175 && clock.Read(query).frequency == 100000000, "new frequency applied");
  Check(GuestClockSnapshot::Convert(UINT64_MAX / 3, 25, 12) ==
        static_cast<uint64_t>(static_cast<unsigned __int128>(UINT64_MAX / 3) * 25 / 12),
        "wide multiplication avoids intermediate overflow");
  Check(GuestClockSnapshot::Convert(UINT64_MAX, 25, 12) == UINT64_MAX, "overflow saturates");
  bool changed = false;
  auto interrupted = clock.Read([&] {
    if (!changed) { changed = true; clock.Update(query, [](auto& s) { s.system_base = 42; }); }
    return host;
  });
  Check(interrupted.system_base == 42, "reader retries a mapping changed during host sampling");

  std::atomic<uint64_t> counter{1000};
  auto concurrent_query = [&] { return counter.fetch_add(1, std::memory_order_relaxed); };
  GuestClockMapping concurrent(1000, 24, 0);
  std::atomic<bool> start{false}, fail{false};
  std::vector<std::thread> readers;
  for (int r = 0; r < 8; ++r) readers.emplace_back([&] {
    while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
    uint64_t previous = 0;
    for (int i = 0; i < 100000; ++i) {
      auto s = concurrent.Read(concurrent_query);
      auto ticks = s.Ticks();
      if (ticks < previous || s.numerator != s.frequency ||
          s.denominator != 24 || s.scalar != double(s.frequency) / 24 ||
          s.system_base != s.frequency * 100) fail.store(true);
      previous = ticks;
    }
  });
  concurrent.Update(concurrent_query, [](auto& s) {
    s.numerator = s.frequency = 24; s.denominator = 24; s.system_base = 2400;
  });
  std::thread writer([&] {
    while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
    for (int i = 0; i < 10000; ++i) concurrent.Update(concurrent_query, [i](auto& s) {
      s.numerator = s.frequency = i % 2 ? 12 : 48;
      s.denominator = 24; s.scalar = double(s.frequency) / 24; s.system_base = s.frequency * 100;
    });
  });
  start.store(true, std::memory_order_release);
  for (auto& reader : readers) reader.join();
  writer.join();
  Check(!fail.load(), "eight readers and scaling writer: coherent state and monotonic ticks");
  std::printf("PASS %d mapping assertions\n", checks);
}
