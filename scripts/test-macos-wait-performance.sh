#!/usr/bin/env bash
# Real runtime CPU/behavior regression test. No game, SDL device or window.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${1:-${ROOT}/build/macos/work/FifaStreetRex/out/build/mac-arm64-release/runtime}"
OUT="${FIFA_WAIT_TEST_OUT:-${ROOT}/build/macos/logs/wait-performance}"
[[ -f "${RUNTIME_DIR}/librexruntime.dylib" ]] || {
  echo "ERROR: runtime not found: ${RUNTIME_DIR}/librexruntime.dylib" >&2
  exit 2
}
mkdir -p "${OUT}"
clang++ -std=c++20 -fno-char8_t -Wall -Wextra \
  -I "${ROOT}/ReXGlue/include" \
  -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" \
  -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
  "${ROOT}/scripts/wait_performance_test.cpp" \
  -L "${RUNTIME_DIR}" -lrexruntime -Wl,-rpath,"${RUNTIME_DIR}" \
  -o "${OUT}/wait-performance-test"
"${OUT}/wait-performance-test" | tee "${OUT}/result.txt"
