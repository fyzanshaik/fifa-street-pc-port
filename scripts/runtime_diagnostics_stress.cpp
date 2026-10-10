// Focused ThreadSanitizer check of the production recorder, without SDL/game.
#include <rex/perf/runtime_diagnostics.h>

#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

int main() {
  namespace diag = rex::perf::diagnostics;
  auto probe = diag::RegisterAudio(6, 2, 48000, 512);
  if (!probe) return 2;
  constexpr int blocks = 20000;
  std::thread producer([&] {
    const unsigned char pcm[]{1,2,3,4,5,6};
    for (int i=0;i<blocks;++i) {
      probe->Submitted(diag::NowUs(), pcm, sizeof(pcm), 1);
      if (i%400==0) std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
  });
  std::thread callback([&] {
    for (int i=0;i<blocks;++i) {
      const auto start = diag::NowUs();
      probe->BeginCallback(start, 6144);
      probe->consumed.fetch_add(1);
      probe->EndCallback(start, diag::NowUs());
      if (i%400==0) std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
  });
  std::vector<std::thread> stages;
  for (int i=0;i<4;++i) stages.emplace_back([] {
    for (int j=0;j<1000;++j) {
      diag::StageScope scope(diag::Stage::kGraphicsPipeline);
      scope.Finish(0);
      diag::Mark(diag::Point::kGpuQueryStatus, j, 0, 0, -7);
      if (j%20==0) std::this_thread::sleep_for(std::chrono::milliseconds(35));
    }
  });
  producer.join(); callback.join();
  for (auto& stage : stages) stage.join();
  // The paced writers span the reporter's one-second snapshot interval.
  probe->closed.store(true);
  if (probe->submitted != blocks || probe->consumed != blocks || probe->callbacks != blocks) return 1;
  std::puts("PASS recorder stress: 20000 producer/callback blocks, 4000 concurrent stage scopes");
}
