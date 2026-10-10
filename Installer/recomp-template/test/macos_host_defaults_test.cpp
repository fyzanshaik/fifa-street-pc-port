// Behavioral test for the macOS host defaults. It exercises the real setenv /
// getenv seam without an SDK, a runtime or game data: the MoltenVK
// synchronous-submit default is applied only when the environment does not
// already set it, so a Finder double-click gets it and an explicit override is
// never clobbered.
#include "macos_host_defaults.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

int failures = 0;

void check(bool ok, const char* what) {
  if (ok) {
    std::printf("OK   %s\n", what);
  } else {
    std::printf("FAIL %s\n", what);
    ++failures;
  }
}

bool IsValue(const char* name, const char* want) {
  const char* value = std::getenv(name);
  return value != nullptr && std::strcmp(value, want) == 0;
}

}  // namespace

int main() {
  using restreet::host::ApplyMacHostDefaults;
  using restreet::host::EnsureMoltenVkSynchronousSubmits;
  const char* kVar = restreet::host::kMoltenVkSynchronousQueueSubmits;

  unsetenv(kVar);
  check(EnsureMoltenVkSynchronousSubmits(), "unset -> default applied");
  check(IsValue(kVar, "1"), "unset -> value is 1");
  check(!EnsureMoltenVkSynchronousSubmits(), "already set -> not reapplied");

  setenv(kVar, "0", 1);
  check(!EnsureMoltenVkSynchronousSubmits(), "explicit override -> untouched");
  check(IsValue(kVar, "0"), "explicit override value preserved");

  setenv(kVar, "0", 1);
  ApplyMacHostDefaults();
  check(IsValue(kVar, "0"), "ApplyMacHostDefaults respects the override");

  unsetenv(kVar);
  ApplyMacHostDefaults();
  check(IsValue(kVar, "1"), "ApplyMacHostDefaults -> value is 1");

  unsetenv(kVar);
  if (failures != 0) {
    std::printf("FAIL: %d check(s) failed\n", failures);
    return 1;
  }
  std::puts("PASS: macOS host defaults (MoltenVK synchronous submits)");
  return 0;
}
