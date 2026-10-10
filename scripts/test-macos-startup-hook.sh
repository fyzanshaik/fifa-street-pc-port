#!/usr/bin/env bash
#
# test-macos-startup-hook.sh - compile and run the behavioral test for the
# macOS guest startup-ordering hoist.
#
# The test drives the real HoistStartEvents/StartEventsHoisted logic from
# Installer/recomp-template/src/guest_start_events_core.h with an injected guest
# allocator, event constructor and base memory. It is header-only, so it needs
# only a C++ compiler (no ReXGlue SDK, no generated guest code, no rebuild).
#
# Usage: scripts/test-macos-startup-hook.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_SRC="${ROOT}/Installer/recomp-template/test/guest_start_events_test.cpp"
CXX="${CXX:-/usr/bin/clang++}"

[[ -f "${TEST_SRC}" ]] || { echo "missing test source: ${TEST_SRC}" >&2; exit 2; }
command -v "${CXX}" >/dev/null 2>&1 || { echo "C++ compiler not found: ${CXX}" >&2; exit 2; }

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT

echo ">>> Compiling startup-hoist behavioral test..."
"${CXX}" -std=c++23 -Wall -Wextra -Werror -O2 \
  -o "${BUILD_DIR}/guest_start_events_test" "${TEST_SRC}"

echo ">>> Running startup-hoist behavioral test..."
"${BUILD_DIR}/guest_start_events_test"

echo "OK   guest startup-hoist behavioral tests passed"
