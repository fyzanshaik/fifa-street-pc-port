// Pure helpers for the macOS guest-frame capture diagnostic.
//
// The capture worker (src/guest_frame_capture.cpp) serializes the rex::ui::RawImage
// returned by Presenter::CaptureGuestOutput into a binary PPM and records frame
// statistics. Everything that can be checked without a GPU - the R8G8B8X8 layout
// validation, the row-stride handling, the PPM encoding and the frame stats -
// lives here with no ReXGlue dependency, so test/guest_frame_capture_test.cpp can
// drive it directly. See docs/BUILDING-MACOS.md, "Rendered-frame capture (macOS)".

#pragma once

#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

namespace restreet::frame_capture {

// Continuous latest-frame capture is opt-in through RESTREET_CAPTURE_INTERVAL_MS.
// The interval is bounded so a caller cannot spin the readback thread flat out or
// starve the renderer; the fixed six-shot schedule stays the default.
inline constexpr int kMinCaptureIntervalMs = 250;
inline constexpr int kMaxCaptureIntervalMs = 10000;
inline constexpr int kDefaultCaptureIntervalMs = 1000;

// Parses RESTREET_CAPTURE_INTERVAL_MS. Returns false when `value` is null (the
// variable is unset), so the caller keeps the fixed schedule. When it is set,
// continuous mode is on and `out_interval_ms` receives a clamped 250..10000
// interval; empty or non-numeric text falls back to the default. No exceptions:
// the text is parsed with strtol and rejects trailing junk.
inline bool ParseCaptureIntervalMs(const char* value, int* out_interval_ms) {
  if (value == nullptr) {
    return false;
  }
  int interval = kDefaultCaptureIntervalMs;
  if (value[0] != '\0') {
    char* end = nullptr;
    errno = 0;
    const long parsed = std::strtol(value, &end, 10);
    if (end != value && *end == '\0' && errno == 0) {
      // Compare and clamp in `long` so a huge value never overflows the int cast.
      if (parsed < kMinCaptureIntervalMs) {
        interval = kMinCaptureIntervalMs;
      } else if (parsed > kMaxCaptureIntervalMs) {
        interval = kMaxCaptureIntervalMs;
      } else {
        interval = static_cast<int>(parsed);
      }
    }
  }
  *out_interval_ms = interval;
  return true;
}

// Writes `data` to `target` by first writing a sibling temp file and then
// renaming it over the target. A concurrent reader therefore always sees a whole
// file - the previous frame or the new one - never a half-written one. Returns
// false and removes the temp file on any IO error.
inline bool AtomicWriteFile(const std::filesystem::path& target, const uint8_t* data, size_t size) {
  std::filesystem::path temp = target;
  temp += ".tmp";
  {
    std::ofstream file(temp, std::ios::binary | std::ios::trunc);
    if (!file) {
      return false;
    }
    file.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(size));
    file.flush();
    if (!file.good()) {
      file.close();
      std::error_code ignored;
      std::filesystem::remove(temp, ignored);
      return false;
    }
  }
  std::error_code error;
  std::filesystem::rename(temp, target, error);
  if (error) {
    std::error_code ignored;
    std::filesystem::remove(temp, ignored);
    return false;
  }
  return true;
}

inline bool AtomicWriteFile(const std::filesystem::path& target, const std::vector<uint8_t>& bytes) {
  return AtomicWriteFile(target, bytes.data(), bytes.size());
}

inline bool AtomicWriteText(const std::filesystem::path& target, const std::string& text) {
  return AtomicWriteFile(target, reinterpret_cast<const uint8_t*>(text.data()), text.size());
}

// R8G8B8X8 image as documented for rex::ui::RawImage: tightly packed RGBA/X
// pixels, but only the last row is required to reach the stride.
struct ImageView {
  uint32_t width = 0;
  uint32_t height = 0;
  size_t stride = 0;
  const uint8_t* data = nullptr;
  size_t data_size = 0;
};

enum class Validation {
  kOk,
  kEmpty,      // no image, zero size, or no backing data
  kBadStride,  // stride smaller than one tightly packed row
  kTruncated,  // fewer bytes than the last row requires
};

inline const char* ValidationName(Validation validation) {
  switch (validation) {
    case Validation::kOk:
      return "ok";
    case Validation::kEmpty:
      return "empty";
    case Validation::kBadStride:
      return "bad_stride";
    case Validation::kTruncated:
      return "truncated";
  }
  return "unknown";
}

// Rejects a RawImage that would read out of bounds or produce a zero-length
// frame, so a failed readback reports clearly instead of fabricating an image.
inline Validation ValidateImage(const ImageView& image) {
  if (image.data == nullptr || image.width == 0 || image.height == 0) {
    return Validation::kEmpty;
  }
  const size_t row_bytes = size_t(image.width) * 4;
  if (image.stride < row_bytes) {
    return Validation::kBadStride;
  }
  const size_t needed = size_t(image.height - 1) * image.stride + row_bytes;
  if (image.data_size < needed) {
    return Validation::kTruncated;
  }
  return Validation::kOk;
}

struct Stats {
  uint64_t total_pixels = 0;
  uint64_t non_black_pixels = 0;
  uint8_t max_channel = 0;
  // FNV-1a over the RGB bytes only, so identical frames (including the X padding
  // byte, which the backend leaves undefined) hash the same.
  uint64_t fnv1a = 0xcbf29ce484222325ull;
};

inline Stats ComputeStats(const ImageView& image) {
  Stats stats;
  stats.total_pixels = uint64_t(image.width) * image.height;
  for (uint32_t y = 0; y < image.height; ++y) {
    const uint8_t* row = image.data + size_t(y) * image.stride;
    for (uint32_t x = 0; x < image.width; ++x) {
      const uint8_t* pixel = row + size_t(x) * 4;
      const uint8_t red = pixel[0];
      const uint8_t green = pixel[1];
      const uint8_t blue = pixel[2];
      if (red | green | blue) {
        ++stats.non_black_pixels;
      }
      stats.max_channel = std::max({stats.max_channel, red, green, blue});
      for (uint8_t channel : {red, green, blue}) {
        stats.fnv1a = (stats.fnv1a ^ channel) * 1099511628211ull;
      }
    }
  }
  return stats;
}

// Appends a binary PPM (P6) of the RGB bytes to out and returns true. The X byte
// is dropped and row padding is not copied. Returns false, leaving out
// untouched, when the image does not validate.
inline bool SerializePpm(const ImageView& image, std::vector<uint8_t>& out) {
  if (ValidateImage(image) != Validation::kOk) {
    return false;
  }
  const std::string header = "P6\n" + std::to_string(image.width) + " " +
                             std::to_string(image.height) + "\n255\n";
  std::vector<uint8_t> bytes;
  bytes.reserve(header.size() + size_t(image.width) * image.height * 3);
  bytes.insert(bytes.end(), header.begin(), header.end());
  for (uint32_t y = 0; y < image.height; ++y) {
    const uint8_t* row = image.data + size_t(y) * image.stride;
    for (uint32_t x = 0; x < image.width; ++x) {
      const uint8_t* pixel = row + size_t(x) * 4;
      bytes.push_back(pixel[0]);
      bytes.push_back(pixel[1]);
      bytes.push_back(pixel[2]);
    }
  }
  out = std::move(bytes);
  return true;
}

}  // namespace restreet::frame_capture
