#!/usr/bin/env bash
# Selection/fallback checks against the actual presenter helper; no window/game.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${FIFA_PRESENT_MODE_TEST_OUT:-${ROOT}/build/macos/logs/present-mode/tests}"
mkdir -p "${OUT}"
clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "${ROOT}/ReXGlue/src/ui/vulkan" \
  -I "${ROOT}/ReXGlue/thirdparty/vulkan-headers/include" \
  "${ROOT}/scripts/present_mode_test.cpp" -o "${OUT}/present-mode-test"
"${OUT}/present-mode-test"
