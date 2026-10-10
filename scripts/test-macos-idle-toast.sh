#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="${1:-${ROOT}/build/macos/unpaced-present-candidate/out}"
OUT="${FIFA_IDLE_TOAST_TEST_OUT:-${ROOT}/build/macos/logs/idle-toast/tests}"
mkdir -p "${OUT}"
clang++ -std=c++23 -O2 -fno-char8_t -DSPDLOG_FMT_EXTERNAL \
  -I "${ROOT}/ReXGlue/include" -I "${ROOT}/ReXGlue/thirdparty/imgui" \
  -I "${ROOT}/ReXGlue/thirdparty/simde" \
  -I "${ROOT}/ReXGlue/thirdparty/vulkan-headers/include" \
  -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
  "${ROOT}/scripts/idle_toast_test.cpp" -L "${LIBS}" -lrexruntime \
  -Wl,-rpath,"${LIBS}" -o "${OUT}/idle-toast-test"
"${OUT}/idle-toast-test"
"${OUT}/idle-toast-test" --confirm-exit
