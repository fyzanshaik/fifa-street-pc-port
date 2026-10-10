#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${FIFA_GPU_QUERY_TEST_OUT:-${ROOT}/build/macos/logs/frame-diagnostics/gpu-test}"
VULKAN="${1:-${ROOT}/build/macos/runtime-diagnostics-production/out/vulkan}"
mkdir -p "${OUT}"
clang++ -std=c++23 -O2 -I "${ROOT}/ReXGlue/thirdparty/vulkan-headers/include" \
  "${ROOT}/scripts/gpu_timestamp_test.cpp" "${VULKAN}/lib/libvulkan.1.dylib" \
  -Wl,-rpath,"${VULKAN}/lib" -o "${OUT}/gpu-test"
VK_DRIVER_FILES="${VULKAN}/share/vulkan/icd.d/MoltenVK_icd.json" \
  "${OUT}/gpu-test"
