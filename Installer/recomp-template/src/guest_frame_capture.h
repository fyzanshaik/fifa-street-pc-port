// Mac-only, opt-in guest frame capture for rendered-frame evidence.
//
// Uses the SDK's existing presenter readback (Presenter::CaptureGuestOutput),
// which runs inside the process: no OS screen capture, accessibility automation
// or window-server permission is involved. A background worker reads the latest
// guest output image and writes it as a PPM plus a small metadata log.
//
// Two modes, both inert unless RESTREET_CAPTURE_DIR names a directory:
//   * fixed (default): six captures at 2,5,10,20,40,60 s, one file each;
//   * continuous: when RESTREET_CAPTURE_INTERVAL_MS is also set, the worker
//     overwrites a single latest.ppm every bounded 250..10000 ms interval and
//     updates a single latest-frame.txt atomically, so a local consumer can read
//     the newest frame without per-frame files piling up.
//
// With RESTREET_CAPTURE_DIR unset, no worker and no file are created, so a
// normal build pays no capture cost. macOS-only because that is the only
// platform this fork packages; on other platforms the type is an empty stub so
// the shared app template stays platform-neutral.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace rex::ui {
class Presenter;
}

#if defined(__APPLE__)

#include <filesystem>
#include <mutex>
#include <thread>

class GuestFrameCapture {
 public:
  GuestFrameCapture() = default;
  ~GuestFrameCapture() = default;
  GuestFrameCapture(const GuestFrameCapture&) = delete;
  GuestFrameCapture& operator=(const GuestFrameCapture&) = delete;

  // True only when RESTREET_CAPTURE_DIR enabled the opt-in.
  bool enabled() const { return enabled_; }

  // Reads RESTREET_CAPTURE_DIR and starts the bounded capture worker.
  // `presenter` may be null; captures then report "no_presenter". It only needs
  // to stay valid until Stop() returns.
  void Start(rex::ui::Presenter* presenter);

  // Stops and joins the worker. Idempotent, and must be called before the
  // presenter and runtime are destroyed.
  void Stop();

 private:
  // Result of one continuous capture, used to bound logging and count unique
  // frames without another file.
  struct LatestOutcome {
    bool ok = false;
    bool new_frame = false;
    uint32_t width = 0;
    uint32_t height = 0;
  };

  void Run(std::stop_token stop_token);
  void RunContinuous(std::stop_token stop_token);
  void CaptureAt(size_t index, double target_seconds, double elapsed_seconds);
  LatestOutcome CaptureLatest(size_t index, double elapsed_seconds);
  void FinishLine(size_t index, const std::string& line, bool ok);
  void WriteMetadataLine(const std::string& line);

  bool enabled_ = false;
  bool continuous_ = false;
  int interval_ms_ = 0;
  std::filesystem::path directory_;
  rex::ui::Presenter* presenter_ = nullptr;
  std::jthread worker_;
  std::mutex metadata_mutex_;
  uint64_t last_checksum_ = 0;  // worker-thread only
  bool have_last_checksum_ = false;
};

#else

// Non-Apple platforms: no capture support, no state, no overhead.
class GuestFrameCapture {
 public:
  GuestFrameCapture() = default;
  bool enabled() const { return false; }
  void Start(rex::ui::Presenter*) {}
  void Stop() {}
};

#endif
