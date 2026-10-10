#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VULKAN="${1:-${ROOT}/build/macos/audio-content-candidate/out/vulkan}"
OUT="${ROOT}/build/macos/logs/fence-wait-benchmark"
mkdir -p "${OUT}"
clang++ -std=c++20 -O2 -Wall -Wextra -Wno-missing-field-initializers \
  -I "${ROOT}/ReXGlue/thirdparty/vulkan-headers/include" \
  "${ROOT}/scripts/fence-wait-benchmark.cpp" "${VULKAN}/lib/libvulkan.1.dylib" \
  -Wl,-rpath,"${VULKAN}/lib" -o "${OUT}/fence-wait-benchmark"
VK_DRIVER_FILES="${VULKAN}/share/vulkan/icd.d/MoltenVK_icd.json" \
MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 \
  "${OUT}/fence-wait-benchmark"
