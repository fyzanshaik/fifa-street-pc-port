// Host-side macOS runtime defaults that must be applied before the Vulkan device
// is created. Header-only and SDK-free so a behavioral test can drive it without
// the runtime, a game build or a game-data extract.
//
// MoltenVK reads its MVK_CONFIG_* environment variables lazily, on first use,
// which is during instance/device creation - after the app's OnPreSetup hook and
// before the guest starts. Setting the stable default here therefore also takes
// effect for a Finder double-click, where no shell environment is available,
// exactly as it does for scripts/play-macos.sh. An explicitly supplied value is
// never overwritten.
#pragma once

#if defined(__APPLE__)

#include <cstdlib>

namespace restreet::host {

// MoltenVK synchronous queue submission. The pinned MoltenVK already defaults
// MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS to 1 (see MVKEnvironment.h), so this is
// not a non-default workaround: the app sets it explicitly so a launch and
// human/AI comparisons do not depend on whatever MVK_CONFIG_* values the
// invoking shell happens to export. An explicitly supplied value is still
// respected.
inline constexpr const char* kMoltenVkSynchronousQueueSubmits =
    "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS";

// Applies the default only when the variable is absent. Returns true if this
// call set it, false when an explicit value (any value) was already present.
inline bool EnsureMoltenVkSynchronousSubmits() {
  if (std::getenv(kMoltenVkSynchronousQueueSubmits) != nullptr) {
    return false;
  }
  return ::setenv(kMoltenVkSynchronousQueueSubmits, "1", /*overwrite=*/0) == 0;
}

// All macOS host defaults that must precede Vulkan device creation.
inline void ApplyMacHostDefaults() { EnsureMoltenVkSynchronousSubmits(); }

}  // namespace restreet::host

#endif  // defined(__APPLE__)
