#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="${1:-${FIFA_BUILD_ROOT:-${ROOT}/build/macos}/out}"
PROFILE="${2:-${ROOT}/config/macos/keyboard-arrows.toml}"
OUT="${ROOT}/build/macos/logs/keyboard-profile"
mkdir -p "${OUT}"
clang++ -std=c++23 -O2 -fno-char8_t -DSPDLOG_FMT_EXTERNAL \
  -I "${ROOT}/ReXGlue/include" -I "${ROOT}/ReXGlue/thirdparty/simde" \
  -I "${ROOT}/ReXGlue/thirdparty/vulkan-headers/include" \
  -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
  "${ROOT}/scripts/macos-keyboard-profile-test.cpp" -L "${LIBS}" -lrexruntime \
  -Wl,-rpath,"${LIBS}" -o "${OUT}/keyboard-profile-test"
"${OUT}/keyboard-profile-test" "${PROFILE}"
