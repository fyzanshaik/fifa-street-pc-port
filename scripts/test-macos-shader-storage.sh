#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="${1:-${ROOT}/build/macos/idle-overlays-candidate/out}"
OUT="${ROOT}/build/macos/logs/shader-storage"
mkdir -p "${OUT}"
clang++ -std=c++23 -Wall -Wextra -I "${ROOT}/ReXGlue/include" \
  -I "${ROOT}/ReXGlue/src/graphics/vulkan" \
  "${ROOT}/scripts/shader-storage-file-test.cpp" -L "${LIBS}" -lrexruntime \
  -Wl,-rpath,"${LIBS}" -o "${OUT}/shader-storage-test"
"${OUT}/shader-storage-test" "${OUT}/shader-storage-fixture.bin"
