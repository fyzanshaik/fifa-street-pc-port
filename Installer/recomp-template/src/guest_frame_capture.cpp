// See guest_frame_capture.h. Only compiled on Apple.

#include "guest_frame_capture.h"

#if defined(__APPLE__)

#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <rex/logging.h>
#include <rex/ui/presenter.h>

#include "guest_frame_capture_core.h"

namespace {

namespace fc = restreet::frame_capture;

// Six captures over the first minute - early enough to catch the loading/menu
// path, spaced out far enough to catch gameplay if the guest advances. The whole
// schedule fits a bounded launch window well under 85 s.
constexpr double kScheduleSeconds[] = {2.0, 5.0, 10.0, 20.0, 40.0, 60.0};

std::string UtcTimestamp() {
  const std::time_t now = std::time(nullptr);
  std::tm utc{};
  gmtime_r(&now, &utc);
  char buffer[32];
  std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
  return buffer;
}

}  // namespace

void GuestFrameCapture::Start(rex::ui::Presenter* presenter) {
  const char* configured = std::getenv("RESTREET_CAPTURE_DIR");
  if (configured == nullptr || configured[0] == '\0') {
    return;  // Opt-in not set: no worker, no capture overhead.
  }

  int interval_ms = 0;
  const bool continuous =
      fc::ParseCaptureIntervalMs(std::getenv("RESTREET_CAPTURE_INTERVAL_MS"), &interval_ms);

  std::error_code error;
  directory_ = std::filesystem::absolute(configured, error);
  if (error) {
    directory_ = std::filesystem::path(configured);
  }
  std::filesystem::create_directories(directory_, error);
  if (error) {
    REXLOG_ERROR("Frame capture: cannot create {}: {}", directory_.string(), error.message());
    return;
  }

  presenter_ = presenter;
  enabled_ = true;
  continuous_ = continuous;
  interval_ms_ = interval_ms;
  {
    std::ostringstream header;
    header << "# ReStreet guest frame capture"
           << " pid=" << static_cast<long>(getpid()) << " started=" << UtcTimestamp();
    if (continuous_) {
      header << " mode=continuous interval_ms=" << interval_ms_
             << " target=latest.ppm source=presenter::CaptureGuestOutput";
    } else {
      header << " mode=fixed schedule=2,5,10,20,40,60 (seconds)"
             << " source=presenter::CaptureGuestOutput";
    }
    WriteMetadataLine(header.str());
    WriteMetadataLine(
        "# fields: frame <i> target <s> elapsed <s> result <...> [width height stride "
        "data_bytes nonblack/total max_channel checksum same_as_prev file]");
  }

  worker_ = std::jthread([this](std::stop_token stop_token) { Run(stop_token); });
  REXLOG_INFO("Frame capture: enabled, writing to {}", directory_.string());
}

void GuestFrameCapture::Stop() {
  if (worker_.joinable()) {
    worker_.request_stop();
    worker_.join();
  }
}

void GuestFrameCapture::Run(std::stop_token stop_token) {
  if (continuous_) {
    RunContinuous(stop_token);
    return;
  }
  const auto start = std::chrono::steady_clock::now();
  for (size_t index = 0; index < std::size(kScheduleSeconds); ++index) {
    const auto deadline = start + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                                      std::chrono::duration<double>(kScheduleSeconds[index]));
    while (!stop_token.stop_requested() && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    if (stop_token.stop_requested()) {
      return;
    }
    const double elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    CaptureAt(index, kScheduleSeconds[index], elapsed);
  }
  WriteMetadataLine("# schedule complete");
}

void GuestFrameCapture::RunContinuous(std::stop_token stop_token) {
  const auto start = std::chrono::steady_clock::now();
  const auto interval = std::chrono::milliseconds(interval_ms_);
  auto next = start;
  size_t count = 0;
  size_t unique = 0;
  bool have_result = false;
  bool last_ok = false;

  while (!stop_token.stop_requested()) {
    // Sleep to the next deadline in small slices so Stop() joins promptly even
    // with a multi-second interval.
    while (!stop_token.stop_requested() && std::chrono::steady_clock::now() < next) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    if (stop_token.stop_requested()) {
      break;
    }

    const double elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const LatestOutcome outcome = CaptureLatest(count, elapsed);
    if (outcome.ok && outcome.new_frame) {
      ++unique;
    }
    // Log only on the first result and on ok/fail transitions, never per frame.
    if (!have_result || outcome.ok != last_ok) {
      if (outcome.ok) {
        REXLOG_INFO("Frame capture: latest frame {} ({}x{}) after {:.2f}s", count, outcome.width,
                    outcome.height, elapsed);
      } else {
        REXLOG_WARN("Frame capture: latest frame {} failed after {:.2f}s", count, elapsed);
      }
      have_result = true;
      last_ok = outcome.ok;
    }
    ++count;

    // Always aim at the newest frame: if the readback fell behind, resync instead
    // of accumulating a backlog.
    next += interval;
    const auto now = std::chrono::steady_clock::now();
    if (next <= now) {
      next = now + interval;
    }
  }

  std::ostringstream summary;
  summary << "# continuous capture stopped frames=" << count << " unique=" << unique
          << " interval_ms=" << interval_ms_ << " ended=" << UtcTimestamp();
  WriteMetadataLine(summary.str());
}

GuestFrameCapture::LatestOutcome GuestFrameCapture::CaptureLatest(size_t index,
                                                                  double elapsed_seconds) {
  LatestOutcome outcome;
  std::ostringstream meta;
  meta << std::fixed << std::setprecision(3);
  meta << "frame=" << index << " elapsed=" << elapsed_seconds << "s"
       << " timestamp=" << UtcTimestamp() << " interval_ms=" << interval_ms_;

  rex::ui::RawImage image;
  const bool captured = presenter_ != nullptr && presenter_->CaptureGuestOutput(image);
  if (!captured) {
    // Report the readback failure and keep the previously captured latest.ppm.
    meta << " result=" << (presenter_ == nullptr ? "no_presenter" : "no_guest_output");
    fc::AtomicWriteText(directory_ / "latest-frame.txt", meta.str() + "\n");
    return outcome;
  }

  const fc::ImageView view{image.width, image.height, image.stride,
                           image.data.empty() ? nullptr : image.data.data(), image.data.size()};
  const fc::Validation validation = fc::ValidateImage(view);
  if (validation != fc::Validation::kOk) {
    meta << " result=invalid_image reason=" << fc::ValidationName(validation)
         << " width=" << image.width << " height=" << image.height << " stride=" << image.stride
         << " data_bytes=" << image.data.size();
    fc::AtomicWriteText(directory_ / "latest-frame.txt", meta.str() + "\n");
    return outcome;
  }

  const fc::Stats stats = fc::ComputeStats(view);
  outcome.new_frame = !have_last_checksum_ || stats.fnv1a != last_checksum_;
  last_checksum_ = stats.fnv1a;
  have_last_checksum_ = true;

  std::vector<uint8_t> ppm;
  if (!fc::SerializePpm(view, ppm) ||
      !fc::AtomicWriteFile(directory_ / "latest.ppm", ppm)) {
    meta << " result=write_failed width=" << image.width << " height=" << image.height
         << " data_bytes=" << image.data.size();
    fc::AtomicWriteText(directory_ / "latest-frame.txt", meta.str() + "\n");
    return outcome;
  }

  meta << " result=ok width=" << image.width << " height=" << image.height
       << " stride=" << image.stride << " data_bytes=" << image.data.size()
       << " nonblack=" << stats.non_black_pixels << "/" << stats.total_pixels
       << " max_channel=" << static_cast<unsigned>(stats.max_channel) << " checksum=" << std::hex
       << stats.fnv1a << std::dec
       << " new_frame=" << (outcome.new_frame ? "yes" : "no") << " file=latest.ppm";
  fc::AtomicWriteText(directory_ / "latest-frame.txt", meta.str() + "\n");

  outcome.ok = true;
  outcome.width = image.width;
  outcome.height = image.height;
  return outcome;
}

void GuestFrameCapture::CaptureAt(size_t index, double target_seconds, double elapsed_seconds) {
  std::ostringstream line;
  line << std::fixed << std::setprecision(3);
  line << "frame " << index << " target=" << target_seconds << "s elapsed=" << elapsed_seconds
       << "s";

  if (presenter_ == nullptr) {
    line << " result=no_presenter";
    FinishLine(index, line.str(), false);
    return;
  }

  rex::ui::RawImage image;
  const bool captured = presenter_->CaptureGuestOutput(image);
  if (!captured) {
    // The presenter has no active guest output yet (the guest has not produced
    // a frame). Report it; never synthesize an image.
    line << " result=no_guest_output";
    FinishLine(index, line.str(), false);
    return;
  }

  const fc::ImageView view{image.width, image.height, image.stride,
                           image.data.empty() ? nullptr : image.data.data(), image.data.size()};
  const fc::Validation validation = fc::ValidateImage(view);
  if (validation != fc::Validation::kOk) {
    line << " result=invalid_image reason=" << fc::ValidationName(validation)
         << " width=" << image.width << " height=" << image.height << " stride=" << image.stride
         << " data_bytes=" << image.data.size();
    FinishLine(index, line.str(), false);
    return;
  }

  const fc::Stats stats = fc::ComputeStats(view);
  const bool same_as_previous = have_last_checksum_ && stats.fnv1a == last_checksum_;
  last_checksum_ = stats.fnv1a;
  have_last_checksum_ = true;

  char filename[64];
  std::snprintf(filename, sizeof(filename), "frame_%02zu_t%ds.ppm", index,
                static_cast<int>(target_seconds + 0.5));

  std::vector<uint8_t> ppm;
  bool written = fc::SerializePpm(view, ppm);
  if (written) {
    std::ofstream file(directory_ / filename, std::ios::binary | std::ios::trunc);
    if (file) {
      file.write(reinterpret_cast<const char*>(ppm.data()), std::streamsize(ppm.size()));
      written = file.good();
    } else {
      written = false;
    }
  }
  if (!written) {
    line << " result=write_failed width=" << image.width << " height=" << image.height
         << " data_bytes=" << image.data.size();
    FinishLine(index, line.str(), false);
    return;
  }

  line << " result=ok width=" << image.width << " height=" << image.height
       << " stride=" << image.stride << " data_bytes=" << image.data.size()
       << " nonblack=" << stats.non_black_pixels << "/" << stats.total_pixels
       << " max_channel=" << static_cast<unsigned>(stats.max_channel) << " checksum=" << std::hex
       << stats.fnv1a << std::dec << " same_as_prev=" << (same_as_previous ? "yes" : "no")
       << " file=" << filename;
  FinishLine(index, line.str(), true);
}

void GuestFrameCapture::FinishLine(size_t index, const std::string& line, bool ok) {
  WriteMetadataLine(line);
  if (ok) {
    REXLOG_INFO("Frame capture {}: {}", index, line);
  } else {
    REXLOG_WARN("Frame capture {}: {}", index, line);
  }
}

void GuestFrameCapture::WriteMetadataLine(const std::string& line) {
  std::lock_guard<std::mutex> lock(metadata_mutex_);
  std::ofstream file(directory_ / "capture-metadata.txt", std::ios::app);
  if (file) {
    file << line << '\n';
  }
}

#endif  // defined(__APPLE__)
