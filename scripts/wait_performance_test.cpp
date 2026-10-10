// Exercises the real runtime wait used by AudioSystem, without a game/device.
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <memory>
#include <thread>

#include <rex/thread.h>

using namespace std::chrono_literals;

namespace {
int failures = 0;
void Check(bool passed, const char* name) {
  std::printf("%s %s\n", passed ? "PASS" : "FAIL", name);
  failures += !passed;
}
double ThreadCpuMs() {
  timespec value{};
  if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) != 0) {
    std::perror("clock_gettime(CLOCK_THREAD_CPUTIME_ID)");
    std::exit(2);
  }
  return value.tv_sec * 1000.0 + value.tv_nsec / 1000000.0;
}
}  // namespace

int main() {
  // AudioSystem has eight client semaphores and one shutdown event.
  std::array<std::unique_ptr<rex::thread::Semaphore>, 8> clients;
  std::array<rex::thread::WaitHandle*, 9> handles{};
  for (size_t i = 0; i < clients.size(); ++i) {
    clients[i] = rex::thread::Semaphore::Create(0, 8);
    if (!clients[i]) return 2;
    handles[i] = clients[i].get();
  }
  auto shutdown = rex::thread::Event::CreateAutoResetEvent(false);
  if (!shutdown) return 2;
  handles.back() = shutdown.get();

  for (bool alertable : {false, true}) {
    const auto start = std::chrono::steady_clock::now();
    const double cpu_start = ThreadCpuMs();
    const auto result = rex::thread::WaitAny(handles.data(), handles.size(), alertable, 300ms);
    const double cpu_ms = ThreadCpuMs() - cpu_start;
    const double wall_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
    std::printf("idle alertable=%d wall_ms=%.3f thread_cpu_ms=%.3f cpu_ratio=%.3f\n",
                alertable, wall_ms, cpu_ms, cpu_ms / wall_ms);
    Check(result.first == rex::thread::WaitResult::kTimeout, "idle wait times out");
    Check(wall_ms >= 290 && wall_ms < 1000, "timeout duration stays bounded");
    // Allow generous scheduler variation, while catching a nearly busy wait.
    Check(cpu_ms < wall_ms * 0.20, "idle waiting uses less than 20% of one CPU");
  }

  Check(clients[3]->Release(1, nullptr), "release one client token");
  auto result = rex::thread::WaitAny(handles.data(), handles.size(), true, 50ms);
  Check(result.first == rex::thread::WaitResult::kSuccess && result.second == 3,
        "alertable wait returns the correct client index");
  result = rex::thread::WaitAny(handles.data(), handles.size(), false, 0ms);
  Check(result.first == rex::thread::WaitResult::kTimeout, "semaphore token consumed exactly once");

  std::thread signaler([&] { std::this_thread::sleep_for(20ms); shutdown->Set(); });
  const auto start = std::chrono::steady_clock::now();
  result = rex::thread::WaitAny(handles.data(), handles.size(), true, 200ms);
  const auto elapsed = std::chrono::steady_clock::now() - start;
  signaler.join();
  Check(result.first == rex::thread::WaitResult::kSuccess && result.second == 8,
        "shutdown event wakes the alertable wait");
  Check(elapsed < 100ms, "event wake does not wait for the full timeout");

  Check(clients[1]->Release(1, nullptr), "prepare first wait-all token");
  result = rex::thread::WaitMultiple(handles.data() + 1, 2, true, false, 10ms);
  Check(result.first == rex::thread::WaitResult::kTimeout,
        "wait-all does not consume a partial set");
  Check(clients[2]->Release(1, nullptr), "prepare second wait-all token");
  result = rex::thread::WaitMultiple(handles.data() + 1, 2, true, true, 50ms);
  Check(result.first == rex::thread::WaitResult::kSuccess,
        "alertable wait-all consumes the complete set");
  result = rex::thread::WaitAny(handles.data(), handles.size(), false, 0ms);
  Check(result.first == rex::thread::WaitResult::kTimeout,
        "wait-all consumes both tokens and auto-reset shutdown stays reset");

  std::thread infinite_signaler([&] { std::this_thread::sleep_for(20ms); shutdown->Set(); });
  result = rex::thread::WaitAny(handles.data(), handles.size(), true);
  infinite_signaler.join();
  Check(result.first == rex::thread::WaitResult::kSuccess && result.second == 8,
        "infinite alertable wait still wakes on shutdown");

  std::printf("wait performance: %d failures\n", failures);
  return failures ? 1 : 0;
}
