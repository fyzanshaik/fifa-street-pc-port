// Real SDL callback, software-only stream: no device, window or guest launch.
#include <algorithm>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <thread>
#include <vector>

#include <rex/audio/downmix.h>
#include <rex/audio/flags.h>
#include <rex/audio/sdl/sdl_audio_driver.h>
#include <rex/cvar.h>
#include <rex/perf/runtime_diagnostics.h>

namespace diag = rex::perf::diagnostics;
namespace {
int failed = 0, checks = 0;
void Check(bool pass, const char* name) {
  std::printf("%s %s\n", pass ? "PASS" : "FAIL", name);
  ++checks; failed += !pass;
}
class CallbackFixture : public rex::audio::sdl::SDLAudioDriver {
 public:
  CallbackFixture(rex::thread::Semaphore* semaphore, uint8_t channels)
      : SDLAudioDriver(nullptr, semaphore) {
    sdl_device_channels_ = channels;
    SDL_AudioSpec format{SDL_AUDIO_F32LE, channels, 48000};
    sdl_stream_ = SDL_CreateAudioStream(&format, &format);
    if (!sdl_stream_) { std::fprintf(stderr, "SDL: %s\n", SDL_GetError()); std::exit(2); }
    diagnostics_ = diag::RegisterAudio(channels, channels, 48000, 512);
  }
  ~CallbackFixture() override { Shutdown(); }
  diag::AudioProbe* Probe() { return diagnostics_.get(); }
  int BlockBytes() const { return 256 * sdl_device_channels_ * sizeof(float); }
  void Push(float left = 0.125f, float right = -0.25f) {
    auto* block = new float[256 * 6]{};
    for (size_t i = 0; i < 256; ++i) {
      block[i] = std::bit_cast<float>(__builtin_bswap32(std::bit_cast<uint32_t>(left)));
      block[256 + i] = std::bit_cast<float>(__builtin_bswap32(std::bit_cast<uint32_t>(right)));
    }
    std::lock_guard<std::mutex> lock(frames_mutex_);
    frames_queued_.push(block);
    if (diagnostics_) diagnostics_->Submitted(diag::NowUs(), block, 256 * 6 * sizeof(float), frames_queued_.size());
  }
  std::vector<float> Request(int bytes) {
    SDL_LockAudioStream(sdl_stream_);
    SDLCallback(this, sdl_stream_, bytes, bytes);
    SDL_UnlockAudioStream(sdl_stream_);
    const int queued = SDL_GetAudioStreamQueued(sdl_stream_);
    if (queued < 0 || queued % sizeof(float)) std::exit(2);
    if (queued == 0) return {};
    std::vector<float> output(queued / sizeof(float));
    const int read = SDL_GetAudioStreamData(sdl_stream_, output.data(), queued);
    if (read != queued) { std::fprintf(stderr, "SDL read=%d queued=%d: %s\n", read, queued, SDL_GetError()); std::exit(2); }
    return output;
  }
};
bool Silent(const std::vector<float>& pcm) {
  return std::all_of(pcm.begin(), pcm.end(), [](float v) { return v == 0; });
}
bool Take(rex::thread::Semaphore* s) {
  return rex::thread::Wait(s, false, std::chrono::milliseconds(0)) == rex::thread::WaitResult::kSuccess;
}
}
int main(int argc, char** argv) {
  if (argc > 1 && std::strcmp(argv[1], "--benchmark") == 0) {
    auto tokens = rex::thread::Semaphore::Create(0, 16);
    if (!tokens) return 2;
    CallbackFixture driver(tokens.get(), 6);
    timespec start{}, end{};
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start);
    constexpr int blocks = 10000;
    for (int i = 0; i < blocks; ++i) {
      driver.Push();
      const auto pcm = driver.Request(driver.BlockBytes());
      if (pcm.size() != 1536 || !Take(tokens.get())) return 2;
    }
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end);
    const double cpu_us = (end.tv_sec-start.tv_sec)*1e6 + (end.tv_nsec-start.tv_nsec)/1000.0;
    std::printf("enabled=%d blocks=%d thread_cpu_us=%.3f cpu_us_per_block=%.3f\n",
                diag::Enabled(), blocks, cpu_us, cpu_us/blocks);
    return 0;
  }
  const bool expected_enabled = argc > 1 && std::strcmp(argv[1], "--enabled") == 0;
  Check(diag::Enabled() == expected_enabled, "opt-in gate matches requested mode");
  rex::audio::SetOutputGain(1.0f);
  rex::audio::SetSurroundMix({});
  REXCVAR_SET(audio_mute, false);
  for (uint8_t channels : {uint8_t{6}, uint8_t{2}}) {
    auto tokens = rex::thread::Semaphore::Create(0, 16);
    if (!tokens) return 2;
    CallbackFixture driver(tokens.get(), channels);
    Check((driver.Probe() != nullptr) == expected_enabled, "disabled mode creates no audio probe");
    auto pcm = driver.Request(0);
    Check(pcm.empty() && !Take(tokens.get()), "zero request writes no audio or semaphore token");
    pcm = driver.Request(driver.BlockBytes() * 2 + 1);
    Check(pcm.size() * sizeof(float) == static_cast<size_t>(driver.BlockBytes() * 3) && Silent(pcm),
          "partial empty request rounds to three silent blocks");
    Check(!Take(tokens.get()), "inserted silence releases no guest producer tokens");
    driver.Push(); driver.Push();
    pcm = driver.Request(driver.BlockBytes() * 3);
    const float scale = channels == 2 ? rex::audio::GetStereoFold().scale : 1.0f;
    Check(std::abs(pcm[0] - 0.125f * scale) < 0.00001f &&
          std::abs(pcm[1] + 0.25f * scale) < 0.00001f, "real callback converts BE planar front channels correctly");
    const size_t block_floats = driver.BlockBytes() / sizeof(float);
    Check(pcm[block_floats] == pcm[0] &&
          std::all_of(pcm.begin() + block_floats * 2, pcm.end(), [](float v) { return v == 0; }),
          "two queued blocks followed by genuine starvation silence");
    Check(Take(tokens.get()) && Take(tokens.get()) && !Take(tokens.get()),
          "callback releases exactly one token per consumed block");
    driver.Push();
    REXCVAR_SET(audio_mute, true);
    pcm = driver.Request(1);
    Check(pcm.size() == block_floats && Silent(pcm) && Take(tokens.get()) && !Take(tokens.get()),
          "muted partial request still consumes exactly one guest block");
    REXCVAR_SET(audio_mute, false);
    if (auto* p = driver.Probe()) {
      Check(p->submitted == 3 && p->consumed == 3 && p->queue_depth == 0 && p->queue_max == 2,
            "probe separates queue submission and consumption");
      Check(p->silence_blocks == 4 && p->muted_blocks == 1,
            "probe distinguishes inserted silence from intentional mute");
      Check(p->callbacks == 4 && p->requested_bytes == static_cast<uint64_t>(driver.BlockBytes() * 5 + 2),
            "probe records varying byte requests including zero request");
      Check(p->repeated_lag1 == 2 && p->put_failures == 0,
            "PCM repetition and put failures are counted independently");
      Check(p->silent_pcm_blocks == 0 && p->nonzero_repeated_lag1 == 2 &&
            p->nonzero_repeated_lag4 == 0 && p->pcm_samples == 3 * 256 * 6 &&
            p->pcm_nonfinite_samples == 0 && p->pcm_out_of_range_samples == 0 &&
            p->pcm_peak_bits == std::bit_cast<uint32_t>(0.25f),
            "real callback probe distinguishes non-silent repeats and valid source PCM");
    }
  }
  // Deterministic content/gap accounting, independent of scheduler variation.
  diag::AudioProbe model;
  const unsigned char a[] = {1,2,3}, b[] = {4,5,6}, c[] = {7,8,9}, d[] = {10,11,12};
  model.Submitted(100, a, sizeof(a), 1); model.Submitted(200, b, sizeof(b), 2);
  model.Submitted(300, c, sizeof(c), 3); model.Submitted(400, d, sizeof(d), 4);
  model.Submitted(700, a, sizeof(a), 5);
  Check(model.repeated_lag4 == 1 && model.repeated_lag1 == 0 && model.submit_gap_max_us == 300,
        "four-block repetition and maximum producer gap measured correctly");
  model.BeginCallback(100, 1); model.EndCallback(100, 130);
  model.BeginCallback(500, 0); model.EndCallback(500, 510);
  Check(model.callback_gap_max_us == 400 && model.callback_max_us == 30 && model.requested_bytes == 1,
        "callback gap and execution duration use separate counters");
  // A readers/writers stress check of the lock-free reporting fields.
  std::thread producer([&] { for (uint64_t i=0;i<10000;++i) model.Submitted(1000+i, a, sizeof(a), 1); });
  std::thread callback([&] { for (uint64_t i=0;i<10000;++i) { model.BeginCallback(1000+i, 24); model.consumed.fetch_add(1); } });
  while (model.consumed.load() != 10000) (void)model.submitted.load();
  producer.join(); callback.join();
  Check(model.submitted == 10005 && model.consumed == 10000, "concurrent probe accounting preserves counts");
  if (expected_enabled) {
    diag::StageScope scope(diag::Stage::kGraphicsPipeline, 123, 456);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    scope.Finish(0); scope.Finish(0);
    { diag::StageScope failure(diag::Stage::kShaderTranslation, 789); }
    std::vector<std::thread> writers;
    for (int t=0;t<4;++t) writers.emplace_back([] {
      for (int i=0;i<150;++i) { diag::StageScope timing(diag::Stage::kShaderModule); timing.Finish(0); }
    });
    for (auto& t : writers) t.join();
  }
  std::printf("Checks: %d/%d passed\n", checks-failed, checks);
  return failed ? 1 : 0;
}
