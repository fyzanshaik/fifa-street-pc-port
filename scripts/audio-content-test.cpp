// Source PCM diagnostics only; no device, game, window or library initialization.
#include <array>
#include <bit>
#include <cmath>
#include <cstdio>
#include <limits>
#include <rex/perf/runtime_diagnostics.h>

int main() {
  int failures = 0;
  auto check = [&](bool pass, const char* name) {
    std::printf("%s %s\n", pass ? "PASS" : "FAIL", name);
    failures += !pass;
  };
  auto submit = [](rex::perf::diagnostics::AudioProbe& p, uint64_t time,
                   const std::array<float, 6>& samples) {
    std::array<unsigned char, 24> bytes{};
    for (size_t i = 0; i < samples.size(); ++i) {
      const auto bits = std::bit_cast<uint32_t>(samples[i]);
      for (int j = 0; j < 4; ++j) bytes[i * 4 + j] = bits >> (24 - 8 * j);
    }
    p.Submitted(time, bytes.data(), bytes.size(), 1);
  };
  rex::perf::diagnostics::AudioProbe silence;
  for (uint64_t i = 1; i <= 5; ++i) submit(silence, i, {});
  check(silence.zero_pcm_blocks == 5 && silence.silent_pcm_blocks == 5,
        "exact-zero PCM is numerical silence");
  check(silence.repeated_lag1 == 4 && silence.repeated_lag4 == 1,
        "legacy fingerprint counters retain silent repetitions");
  check(silence.nonzero_repeated_lag1 == 0 && silence.nonzero_repeated_lag4 == 0,
        "silent repetitions never count as repeated non-silent audio");
  rex::perf::diagnostics::AudioProbe signed_zero;
  for (uint64_t i = 1; i <= 5; ++i) submit(signed_zero, i, {-0.0f, 0, 0, 0, 0, 0});
  check(signed_zero.zero_pcm_blocks == 0 && signed_zero.silent_pcm_blocks == 5 &&
        signed_zero.nonzero_repeated_lag4 == 0,
        "negative zero is silence even when raw bytes are nonzero");
  rex::perf::diagnostics::AudioProbe music;
  const std::array<float, 6> a{0.125f, -0.25f, 0.5f, -1.0f, 0.75f, 0.0625f};
  submit(music, 1, a); submit(music, 2, a); submit(music, 3, {});
  submit(music, 4, {}); submit(music, 5, a);
  check(music.nonzero_repeated_lag1 == 1 && music.nonzero_repeated_lag4 == 1,
        "non-silent repetitions are separated at one and four block distances");
  check(music.pcm_samples == 30 && music.pcm_nonfinite_samples == 0 &&
        music.pcm_out_of_range_samples == 0 && music.pcm_peak_bits == std::bit_cast<uint32_t>(1.0f),
        "big-endian planar source values preserve normal range and peak");
  rex::perf::diagnostics::AudioProbe damaged;
  submit(damaged, 1, {std::numeric_limits<float>::infinity(),
                     -std::numeric_limits<float>::infinity(),
                     std::numeric_limits<float>::quiet_NaN(), 1.25f, -2.0f, -1.0f});
  check(damaged.pcm_samples == 6 && damaged.pcm_nonfinite_samples == 3 &&
        damaged.pcm_out_of_range_samples == 2 &&
        damaged.pcm_peak_bits == std::bit_cast<uint32_t>(2.0f),
        "NaN/Inf are separate from finite out-of-range samples");
  return failures ? 1 : 0;
}
