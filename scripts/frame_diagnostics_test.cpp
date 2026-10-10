// Production recorder fixture: clock alignment, CPU attribution and loss tests.
#include <rex/perf/runtime_diagnostics.h>
#include <rex/ui/vulkan/device.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <thread>

namespace d = rex::perf::diagnostics;
int main(int argc, char** argv) {
  const bool enabled = argc > 1 && std::strcmp(argv[1], "--enabled") == 0;
  if (d::Enabled() != enabled) return 2;
  if (d::CurrentFrame() != 0) return 3;
  { d::FrameScope a(42);
    if (d::CurrentFrame() != 42) return 4;
    { d::FrameScope b(99); if (d::CurrentFrame() != 99) return 5; }
    if (d::CurrentFrame() != 42) return 6;
  }
  if (d::CurrentFrame() != 0) return 7;
  // Exercise the real Vulkan queue's synchronization seam without a GPU/window.
  rex::ui::vulkan::VulkanDevice::Queue queue(VK_NULL_HANDLE);
  std::atomic<bool> held{false};
  std::thread holder([&] {
    auto lock=queue.Acquire();held.store(true);
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
  });
  while (!held.load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  { auto lock=queue.Acquire();
    d::DurationScope fake_driver(d::Stage::kGuestSubmitCall,999);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  holder.join();
  // Reused packet addresses and output sequences mimic separate identifier spaces.
  for (int i = 1; i <= 3; ++i) {
    d::Mark(d::Point::kGuestSwapWritten, 0x1000, 0x2000);
    std::this_thread::sleep_for(std::chrono::milliseconds(3));
    d::Mark(d::Point::kSwapProcessed, 0x1000, i);
    d::Mark(d::Point::kOutputPublished, 100+i, i);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    d::Mark(d::Point::kPresentQueued, 100+i, 50+i);
    d::Mark(d::Point::kPresentQueued, 100+i, 60+i); // repeats excluded from handoff.
    d::Mark(d::Point::kSubmissionQueued, i, i);
    d::Mark(d::Point::kGpuDuration, i, 1500000);
    d::Mark(d::Point::kCompletionObserved, i, 1);
  }
  std::thread sleeper([] {
    pthread_setname_np("diag-sleep");
    d::DurationScope scope(d::Stage::kCommandIdle, 77);
    std::this_thread::sleep_for(std::chrono::milliseconds(2200));
  });
  std::thread busy([] {
    pthread_setname_np("diag-busy");
    d::DurationScope scope(d::Stage::kCommandBatch, 88);
    const auto end = d::NowUs()+2200000;
    while (d::NowUs()<end) std::atomic_signal_fence(std::memory_order_seq_cst);
  });
  sleeper.join();busy.join();
  // Flood after periodic reports, ensuring bounded queue loss is observable.
  for (int i=0;i<5000;++i) d::Mark(d::Point::kGpuQueryStatus, i, 0, 0, -7);
  std::puts("PASS frame recorder fixture: nested frame IDs, ordered markers, CPU/sleep threads, bounded loss");
}
