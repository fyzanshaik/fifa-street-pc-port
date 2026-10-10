#!/usr/bin/env bash
# Real native diagnostic window; never operates the game or sends input.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${FIFA_PRESENT_STRESS_OUT:-${ROOT}/build/macos/logs/presentation-stress}"
VULKAN="${1:-${ROOT}/build/macos/unpaced-present-candidate/out/vulkan}"
MODE="${2:-immediate}"
SECONDS_LIMIT="${3:-30}"
mkdir -p "${OUT}"
clang++ -std=c++20 -O2 -Wall -Wextra -Wno-missing-field-initializers \
  -I "${ROOT}/ReXGlue/thirdparty/vulkan-headers/include" \
  "${ROOT}/scripts/presentation_stress_test.mm" "${VULKAN}/lib/libvulkan.1.dylib" \
  -framework AppKit -framework QuartzCore -Wl,-rpath,"${VULKAN}/lib" \
  -o "${OUT}/presentation-stress"
VK_DRIVER_FILES="${VULKAN}/share/vulkan/icd.d/MoltenVK_icd.json" \
  "${OUT}/presentation-stress" "${MODE}" "${SECONDS_LIMIT}"
