#!/usr/bin/env bash
#
# test-macos-virtual-input.sh - compile and run the behavioral test for the
# macOS virtual-gamepad bridge.
#
# The test drives the real control protocol codec, the latching pad state, the
# slot-routing device-assignment policy and the POSIX receiver server over a
# live Unix-domain socket. It needs only a C++ compiler and the SDK's public
# headers (for rex::input::X_INPUT_STATE); no ReXGlue runtime library, GPU or
# generated guest code is used.
#
# Usage: scripts/test-macos-virtual-input.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT}/Installer/recomp-template/src"
TEST_SRC="${ROOT}/Installer/recomp-template/test/control_bridge_test.cpp"
CXX="${CXX:-/usr/bin/clang++}"

[[ -f "${TEST_SRC}" ]] || { echo "missing test source: ${TEST_SRC}" >&2; exit 2; }
[[ -f "${SRC}/control_bridge_server.cpp" ]] || { echo "missing server source" >&2; exit 2; }
[[ -d "${ROOT}/ReXGlue/include" ]] || { echo "missing SDK headers: ${ROOT}/ReXGlue/include" >&2; exit 2; }
command -v "${CXX}" >/dev/null 2>&1 || { echo "C++ compiler not found: ${CXX}" >&2; exit 2; }

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo ">>> Compiling virtual-gamepad bridge behavioral test..."
"${CXX}" -std=gnu++23 -Wall -Wextra -Werror -O2 \
  -I "${ROOT}/ReXGlue/include" \
  -o "${BUILD_DIR}/control_bridge_test" \
  "${TEST_SRC}" "${SRC}/control_bridge_server.cpp"

echo ">>> Running virtual-gamepad bridge behavioral test..."
"${BUILD_DIR}/control_bridge_test"

echo "OK   virtual-gamepad bridge behavioral tests passed"
