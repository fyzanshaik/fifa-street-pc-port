#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/build/macos/logs/audio-content"
mkdir -p "${OUT}"
clang++ -std=c++23 -O2 -Wall -Wextra -I "${ROOT}/ReXGlue/include" \
  "${ROOT}/scripts/audio-content-test.cpp" -o "${OUT}/audio-content-test"
"${OUT}/audio-content-test"
