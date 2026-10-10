// Public runtime APIs, rather than an independent implementation of the clock.
#include <rex/chrono/clock.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>

using Clock = rex::chrono::Clock;
static void Check(bool pass, const char* name) {
  if (!pass) { std::fprintf(stderr, "FAIL %s\n", name); std::exit(1); }
  std::printf("PASS %s\n", name);
}
static double Rate() {
  auto h0 = Clock::QueryHostTickCount(), g0 = Clock::QueryGuestTickCount();
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  auto g1 = Clock::QueryGuestTickCount(), h1 = Clock::QueryHostTickCount();
  return double(g1-g0) / double(h1-h0) * Clock::QueryHostTickFrequency() / Clock::guest_tick_frequency();
}
int main() {
  REXCVAR_SET(clock_no_scaling, false);
  Clock::set_guest_tick_frequency(50000000);
  for (double scalar : {.5, 1., 2.}) {
    auto before = Clock::QueryGuestTickCount();
    Clock::set_guest_time_scalar(scalar);
    Check(Clock::QueryGuestTickCount() >= before, "scalar change preserves monotonic ticks");
    Check(Clock::guest_time_scalar() == scalar, "scalar getter");
    Check(std::abs(Rate() - scalar) < .01, "public clock runs at selected scalar");
    Check(Clock::ScaleGuestDurationMillis(100) == unsigned(100 * scalar), "scaled millisecond duration");
    int32_t seconds = 2, micros = 100;
    Clock::ScaleGuestDurationTimeval(&seconds, &micros);
    Check(seconds == int32_t(2 * scalar) && micros == int32_t(100 * scalar), "scaled timeval duration");
  }
  Clock::set_guest_time_scalar(1.);
  auto before = Clock::QueryGuestTickCount();
  Clock::set_guest_tick_frequency(100000000);
  Check(Clock::QueryGuestTickCount() >= before, "frequency change preserves monotonic ticks");
  Check(std::abs(Rate() - 1.) < .01, "public clock honors new frequency");
  Clock::set_guest_tick_frequency(50000000);
  constexpr uint64_t target = 123456789000000000;
  Clock::SetGuestSystemTime(target);
  auto now = Clock::QueryGuestSystemTime();
  Check(now >= target && now - target < 1000000, "public system-time override");
  auto uptime = Clock::QueryGuestUptimeMillis();
  std::this_thread::sleep_for(std::chrono::milliseconds(10));
  Check(Clock::QueryGuestUptimeMillis() >= uptime + 9, "guest uptime advances independently of system-time override");
  Clock::set_guest_system_time_base(target);
  Check(Clock::guest_system_time_base() == target, "public system-time base setter");
  REXCVAR_SET(clock_no_scaling, true);
  Clock::set_guest_time_scalar(.5);
  Check(Clock::guest_time_scalar() == 1., "legacy bypass ignores scalar setter");
  auto host_time = Clock::QueryHostSystemTime();
  Clock::SetGuestSystemTime(100);
  now = Clock::QueryGuestSystemTime();
  Check(now >= host_time && now - host_time < 1000000, "legacy bypass uses host system time");
  Check(Clock::ScaleGuestDurationMillis(100) == 100, "legacy bypass leaves duration unchanged");
}
