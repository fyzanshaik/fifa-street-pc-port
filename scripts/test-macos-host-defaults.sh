#!/usr/bin/env bash
#
# test-macos-host-defaults.sh - verify the macOS host defaults seam.
#
# Two checks, both without a game build, a runtime or game data:
#   1. behavioral: the MoltenVK synchronous-submit default is applied only when
#      the environment does not already set it (real setenv/getenv semantics);
#   2. structural: fifastreet_app.h applies it from OnPreSetup, which runs before
#      the GPU plugin loads and before any Vulkan instance/device is created.
#
# Usage: scripts/test-macos-host-defaults.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${ROOT}/build/macos/logs/host-defaults"
mkdir -p "${OUT}"

CLANGXX="${FIFA_CLANGXX:-/usr/bin/clang++}"
[[ -x "${CLANGXX}" ]] || { echo "clang++ not found at ${CLANGXX}" >&2; exit 1; }

echo "== macOS host defaults =="
"${CLANGXX}" -std=c++23 -O2 -Wall -Wextra -Werror \
  -I "${ROOT}/Installer/recomp-template/src" \
  "${ROOT}/Installer/recomp-template/test/macos_host_defaults_test.cpp" \
  -o "${OUT}/macos-host-defaults-test"
"${OUT}/macos-host-defaults-test"

APP_HEADER="${ROOT}/Installer/recomp-template/src/fifastreet_app.h"
if sed -n '/void OnPreSetup(rex::RuntimeConfig& config) override {/,/^  }/p' "${APP_HEADER}" \
     | grep -q 'ApplyMacHostDefaults()'; then
  echo "OK   host defaults applied from OnPreSetup (before graphics setup)"
else
  echo "FAIL fifastreet_app.h does not apply the macOS host defaults from OnPreSetup" >&2
  exit 1
fi

# The header comment must describe the pinned MoltenVK default honestly: the
# pinned MVKEnvironment.h already defaults MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS
# to 1, so an unset variable is not an asynchronous default.
DEFAULTS_HEADER="${ROOT}/Installer/recomp-template/src/macos_host_defaults.h"
if grep -qi 'internal thread' "${DEFAULTS_HEADER}"; then
  echo "FAIL ${DEFAULTS_HEADER##*/} still claims an unset variable queues asynchronously" >&2
  exit 1
fi
if grep -q 'MVKEnvironment.h' "${DEFAULTS_HEADER}"; then
  echo "OK   host-defaults comment matches the pinned MoltenVK default"
else
  echo "FAIL ${DEFAULTS_HEADER##*/} does not cite the pinned MoltenVK default" >&2
  exit 1
fi

echo
echo "ALL MACOS HOST-DEFAULTS TESTS PASSED"
