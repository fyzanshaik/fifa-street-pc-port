#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="${1:-${ROOT}/build/macos/audio-content-candidate/out}"
OUT="${ROOT}/build/macos/logs/clock-read"
mkdir -p "${OUT}"
clang++ -std=c++23 -O2 -fno-char8_t -DSPDLOG_FMT_EXTERNAL \
  -I "${ROOT}/ReXGlue/include" -I "${ROOT}/ReXGlue/thirdparty/simde" \
  -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
  "${ROOT}/scripts/clock-read-benchmark.cpp" -L "${LIBS}" -lrexruntime \
  -Wl,-rpath,"${LIBS}" -o "${OUT}/clock-read-benchmark"
"${OUT}/clock-read-benchmark" "${@:2}"
