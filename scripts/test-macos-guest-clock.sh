#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/build/macos/logs/guest-clock"
mkdir -p "${OUT}"
FLAGS=(-std=c++23 -Wall -Wextra -pthread -I "${ROOT}/ReXGlue/src/core")
clang++ "${FLAGS[@]}" -O2 "${ROOT}/scripts/guest-clock-mapping-test.cpp" -o "${OUT}/mapping-test"
"${OUT}/mapping-test" > "${OUT}/mapping-test.log"
tail -n 12 "${OUT}/mapping-test.log"
clang++ "${FLAGS[@]}" -O1 -g -fsanitize=thread "${ROOT}/scripts/guest-clock-mapping-test.cpp" -o "${OUT}/mapping-test-tsan"
"${OUT}/mapping-test-tsan" > "${OUT}/mapping-test-tsan.log" 2>&1
tail -n 3 "${OUT}/mapping-test-tsan.log"
