#!/usr/bin/env bash
#
# test-macos-frame-capture.sh - compile and run the behavioral test for the
# macOS guest-frame capture helpers.
#
# The test drives the real validation, statistics and PPM serialization from
# Installer/recomp-template/src/guest_frame_capture_core.h on synthetic
# R8G8B8X8 images. It is header-only, so it needs only a C++ compiler (no
# ReXGlue SDK, no generated guest code, no rebuild).
#
# Usage: scripts/test-macos-frame-capture.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_SRC="${ROOT}/Installer/recomp-template/test/guest_frame_capture_test.cpp"
CXX="${CXX:-/usr/bin/clang++}"

[[ -f "${TEST_SRC}" ]] || { echo "missing test source: ${TEST_SRC}" >&2; exit 2; }
command -v "${CXX}" >/dev/null 2>&1 || { echo "C++ compiler not found: ${CXX}" >&2; exit 2; }

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo ">>> Compiling guest-frame capture behavioral test..."
"${CXX}" -std=c++23 -Wall -Wextra -Werror -O2 \
  -o "${BUILD_DIR}/guest_frame_capture_test" "${TEST_SRC}"

echo ">>> Running guest-frame capture behavioral test..."
"${BUILD_DIR}/guest_frame_capture_test"

echo "OK   guest-frame capture behavioral tests passed"
