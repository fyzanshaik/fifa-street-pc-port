// Behavioral test for the macOS guest-frame capture helpers.
//
// Drives the real validation, statistics and PPM serialization from
// src/guest_frame_capture_core.h on synthetic R8G8B8X8 images (no ReXGlue, no
// GPU, no generated guest code). It proves the layout handling and the
// failure reporting that the production worker relies on, including the padded
// last-row rule documented for rex::ui::RawImage.
//
// Build/run: scripts/test-macos-frame-capture.sh (header-only, clang++).

#include "../src/guest_frame_capture_core.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace fc = restreet::frame_capture;

namespace {

int g_failures = 0;

#define CHECK(cond)                                               \
  do {                                                            \
    if (!(cond)) {                                                \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      ++g_failures;                                               \
    }                                                             \
  } while (0)

std::string ReadFile(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}

// A 2x2 tightly packed image: red, green, blue, black.
std::vector<uint8_t> TightPixels() {
  return {
      0xFF, 0x00, 0x00, 0xEE,  // red
      0x00, 0xFF, 0x00, 0xEE,  // green
      0x00, 0x00, 0xFF, 0xEE,  // blue
      0x00, 0x00, 0x00, 0xEE,  // black
  };
}

}  // namespace

int main() {
  // 1. Valid tightly packed image: statistics and PPM bytes.
  {
    std::vector<uint8_t> pixels = TightPixels();
    const fc::ImageView view{2, 2, 8, pixels.data(), pixels.size()};
    CHECK(fc::ValidateImage(view) == fc::Validation::kOk);

    const fc::Stats stats = fc::ComputeStats(view);
    CHECK(stats.total_pixels == 4);
    CHECK(stats.non_black_pixels == 3);
    CHECK(stats.max_channel == 0xFF);

    std::vector<uint8_t> ppm;
    CHECK(fc::SerializePpm(view, ppm));
    const std::string header = "P6\n2 2\n255\n";
    CHECK(ppm.size() == header.size() + 3 * 4);
    CHECK(std::string(ppm.begin(), ppm.begin() + header.size()) == header);
    const std::vector<uint8_t> expected_payload = {0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00,
                                                   0x00, 0x00, 0xFF, 0x00, 0x00, 0x00};
    CHECK(std::vector<uint8_t>(ppm.begin() + header.size(), ppm.end()) == expected_payload);
  }

  // 2. Row padding: only the last row must reach the stride; padding is not
  //    copied into the PPM.
  {
    // stride 12 for width 2 (8 used, 4 padding), height 2, last row only 8 bytes.
    std::vector<uint8_t> pixels = {
        0x11, 0x22, 0x33, 0x00, 0x44, 0x55, 0x66, 0x00, 0xAA, 0xAA, 0xAA, 0xAA,  // row 0 + pad
        0x77, 0x88, 0x99, 0x00, 0x12, 0x34, 0x56, 0x00,                          // row 1 packed
    };
    const fc::ImageView view{2, 2, 12, pixels.data(), pixels.size()};
    CHECK(fc::ValidateImage(view) == fc::Validation::kOk);

    std::vector<uint8_t> ppm;
    CHECK(fc::SerializePpm(view, ppm));
    const std::string header = "P6\n2 2\n255\n";
    const std::vector<uint8_t> expected_payload = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
                                                   0x77, 0x88, 0x99, 0x12, 0x34, 0x56};
    CHECK(std::vector<uint8_t>(ppm.begin() + header.size(), ppm.end()) == expected_payload);

    // The X byte must not affect frame identity.
    std::vector<uint8_t> other_x = pixels;
    other_x[3] = 0x7F;
    other_x[7] = 0x01;
    other_x[15] = 0x80;
    const fc::ImageView other_view{2, 2, 12, other_x.data(), other_x.size()};
    CHECK(fc::ComputeStats(other_view).fnv1a == fc::ComputeStats(view).fnv1a);
  }

  // 3. Zero / missing image is empty, not a fabricated frame.
  {
    const fc::ImageView zero_width{0, 2, 0, nullptr, 0};
    CHECK(fc::ValidateImage(zero_width) == fc::Validation::kEmpty);
    const fc::ImageView zero_height{2, 0, 8, nullptr, 0};
    CHECK(fc::ValidateImage(zero_height) == fc::Validation::kEmpty);
    std::vector<uint8_t> pixels = TightPixels();
    const fc::ImageView no_data{2, 2, 8, nullptr, 0};
    CHECK(fc::ValidateImage(no_data) == fc::Validation::kEmpty);
  }

  // 4. Stride smaller than a tightly packed row is rejected.
  {
    std::vector<uint8_t> pixels = TightPixels();
    const fc::ImageView view{2, 2, 4, pixels.data(), pixels.size()};
    CHECK(fc::ValidateImage(view) == fc::Validation::kBadStride);
  }

  // 5. Short buffer is rejected (last row would read out of bounds).
  {
    std::vector<uint8_t> pixels(12);
    const fc::ImageView view{2, 2, 8, pixels.data(), pixels.size()};
    CHECK(fc::ValidateImage(view) == fc::Validation::kTruncated);
  }

  // 6. Serialization refuses invalid images and leaves the output untouched.
  {
    std::vector<uint8_t> pixels = TightPixels();
    const fc::ImageView bad{2, 2, 4, pixels.data(), pixels.size()};
    std::vector<uint8_t> ppm = {0xAB};
    CHECK(!fc::SerializePpm(bad, ppm));
    CHECK(ppm == std::vector<uint8_t>{0xAB});
  }

  // 7. All-black frame reports zero non-black pixels.
  {
    std::vector<uint8_t> pixels(2 * 2 * 4, 0);
    const fc::ImageView view{2, 2, 8, pixels.data(), pixels.size()};
    const fc::Stats stats = fc::ComputeStats(view);
    CHECK(stats.total_pixels == 4);
    CHECK(stats.non_black_pixels == 0);
    CHECK(stats.max_channel == 0);
  }

  // 8. Continuous mode is opt-in: unset disables it; a set value is clamped to
  //    the bounded 250..10000 ms window; junk falls back to the default.
  {
    int interval = -1;
    CHECK(!fc::ParseCaptureIntervalMs(nullptr, &interval));  // unset -> fixed schedule
    CHECK(fc::ParseCaptureIntervalMs("", &interval) && interval == fc::kDefaultCaptureIntervalMs);
    CHECK(fc::ParseCaptureIntervalMs("250", &interval) && interval == 250);
    CHECK(fc::ParseCaptureIntervalMs("500", &interval) && interval == 500);
    CHECK(fc::ParseCaptureIntervalMs("10000", &interval) && interval == 10000);
    CHECK(fc::ParseCaptureIntervalMs("0", &interval) && interval == fc::kMinCaptureIntervalMs);
    CHECK(fc::ParseCaptureIntervalMs("-5", &interval) && interval == fc::kMinCaptureIntervalMs);
    CHECK(fc::ParseCaptureIntervalMs("250000", &interval) && interval == fc::kMaxCaptureIntervalMs);
    CHECK(fc::ParseCaptureIntervalMs("abc", &interval) && interval == fc::kDefaultCaptureIntervalMs);
    CHECK(fc::ParseCaptureIntervalMs("1000ms", &interval) &&
          interval == fc::kDefaultCaptureIntervalMs);
    // A value past long range must fall back, not wrap.
    CHECK(fc::ParseCaptureIntervalMs("999999999999999999999999", &interval) &&
          interval == fc::kDefaultCaptureIntervalMs);
  }

  // 9. Atomic write: writes a complete new file, replaces an existing target
  //    whole, and never leaves the temp file behind.
  {
    const std::string unique =
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
    const std::filesystem::path dir =
        std::filesystem::temp_directory_path() / ("restreet-frame-test-" + unique);
    std::error_code error;
    std::filesystem::remove_all(dir, error);
    CHECK(std::filesystem::create_directories(dir, error));

    const std::filesystem::path target = dir / "latest.ppm";
    const std::vector<uint8_t> first = {'P', '6', '\n', 0x01, 0x02, 0x03};
    CHECK(fc::AtomicWriteFile(target, first));
    CHECK(ReadFile(target) == std::string(first.begin(), first.end()));

    const std::vector<uint8_t> second = {'X', 'Y', 'Z'};
    CHECK(fc::AtomicWriteFile(target, second));
    CHECK(ReadFile(target) == std::string(second.begin(), second.end()));
    CHECK(!std::filesystem::exists(dir / "latest.ppm.tmp"));

    CHECK(fc::AtomicWriteText(dir / "latest-frame.txt", "frame=1 result=ok\n"));
    CHECK(ReadFile(dir / "latest-frame.txt") == "frame=1 result=ok\n");
    CHECK(!std::filesystem::exists(dir / "latest-frame.txt.tmp"));

    // A target whose parent does not exist fails instead of writing a partial
    // file or a stray temp file.
    CHECK(!fc::AtomicWriteFile(dir / "missing" / "latest.ppm", first));
    std::filesystem::remove_all(dir, error);
  }

  if (g_failures == 0) {
    std::printf("All guest-frame capture behavioral tests passed\n");
    return 0;
  }
  std::printf("%d check(s) failed\n", g_failures);
  return 1;
}
