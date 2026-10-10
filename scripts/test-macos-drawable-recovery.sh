#!/usr/bin/env bash
#
# Regression test for the macOS MoltenVK drawable-exhaustion acquire recovery.
#
# It builds the pinned ReXGlue source tree with the normal project + macOS
# portability patches plus the drawable-recovery patch, then compiles
# scripts/drawable_recovery_test.cpp against the real
# src/ui/vulkan/swapchain_acquire_recovery.h from that tree and runs it.
#
# It then re-runs the same test against a throwaway copy of the header with the
# macOS pool-memory -> reconnect mapping removed, to prove the test actually
# binds to the recovery (RED), before reporting the clean run (GREEN).
#
# Usable without an SDK/game build; it only compiles the small standalone test.
#
#   bash scripts/test-macos-drawable-recovery.sh
#
# Env overrides:
#   REXGLUE_TREE  a ReXGlue tree that already has the recovery patch applied;
#                 when set, the pinned tree is not rebuilt.
#   REXGLUE_RECOVERY_WORK  output directory for build logs/binaries
#                 (default build/macos/logs/drawable-recovery).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN=c94f5ebdcb3c9d1a460ca48e04f9758448f8d518
WORK="${REXGLUE_RECOVERY_WORK:-${ROOT}/build/macos/logs/drawable-recovery}"
TEST_SRC="${ROOT}/scripts/drawable_recovery_test.cpp"
SYNC_TEST_SRC="${ROOT}/scripts/drawable_recovery_sync_test.cpp"
RECOVERY_PATCH="${ROOT}/patches/rexglue-macos-drawable-recovery.patch"
LOCAL_PATCH="${ROOT}/patches/rexglue-macos-base.patch"
PORTABILITY_PATCH="${ROOT}/patches/rexglue-macos-portability.patch"
CXX="${CXX:-c++}"
HDR_REL="src/ui/vulkan/swapchain_acquire_recovery.h"
SYNC_HDR_REL="src/ui/vulkan/swapchain_acquire_sync_recovery.h"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${TEST_SRC}" ]] || fail "missing ${TEST_SRC}"
[[ -f "${SYNC_TEST_SRC}" ]] || fail "missing ${SYNC_TEST_SRC}"
[[ -f "${RECOVERY_PATCH}" ]] || fail "missing ${RECOVERY_PATCH}"
[[ -d "${ROOT}/ReXGlue/.git" ]] || fail "ReXGlue checkout not found"

VULKAN_INC="${ROOT}/ReXGlue/thirdparty/vulkan-headers/include"
[[ -f "${VULKAN_INC}/vulkan/vulkan_core.h" ]] || fail \
  "Vulkan headers not found at ${VULKAN_INC} (init the ReXGlue submodules)"

mkdir -p "${WORK}"

# ---------------------------------------------------------------------------
# Source tree: pinned SDK HEAD + normal base patches + recovery patch.
# ---------------------------------------------------------------------------
TREE="${REXGLUE_TREE:-}"
if [[ -z "${TREE}" ]]; then
  TREE="${WORK}/test-tree"
  echo ">>> Building pinned source tree at ${TREE}"
  rm -rf "${TREE}"
  mkdir -p "${TREE}"
  git -C "${ROOT}/ReXGlue" archive "${PIN}" | tar -x -C "${TREE}"
  git -C "${TREE}" init -q
  git -C "${TREE}" -c user.email=t@t -c user.name=t add -A
  git -C "${TREE}" -c user.email=t@t -c user.name=t commit -qm "base ${PIN:0:12}"
  git -C "${TREE}" apply "${LOCAL_PATCH}"
  git -C "${TREE}" apply "${PORTABILITY_PATCH}"
  git -C "${TREE}" apply "${RECOVERY_PATCH}"
fi

HDR="${TREE}/${HDR_REL}"
[[ -f "${HDR}" ]] || fail "recovery header not present at ${HDR}"
HDR_DIR="$(dirname "${HDR}")"
SYNC_HDR="${TREE}/${SYNC_HDR_REL}"
[[ -f "${SYNC_HDR}" ]] || fail "acquire-sync recovery header not present at ${SYNC_HDR}"

run_case() {
  local label="$1" include_dir="$2"
  local bin="${WORK}/drawable_recovery_test.${label}"
  echo ""
  echo ">>> [${label}] compiling test"
  "${CXX}" -std=c++17 -Wall -Wextra \
    -I "${include_dir}" -I "${VULKAN_INC}" \
    "${TEST_SRC}" -o "${bin}"
  echo ">>> [${label}] running test"
  "${bin}"
}

# ---------------------------------------------------------------------------
# GREEN: the real header must classify the macOS pool result as a reconnect.
# ---------------------------------------------------------------------------
echo "==========================================================================="
echo "GREEN: real recovery helper"
echo "==========================================================================="
run_case green "${HDR_DIR}"
echo "GREEN RESULT: all checks passed (exit 0)"

# ---------------------------------------------------------------------------
# RED: drop the macOS pool-memory -> reconnect mapping in a throwaway copy and
# confirm the test fails, proving it binds to the recovery, not to the header
# merely compiling.
# ---------------------------------------------------------------------------
RED_DIR="${WORK}/red-header"
rm -rf "${RED_DIR}"
mkdir -p "${RED_DIR}"
perl -0777 -pe \
  's/return moltenvk_present \? SwapchainAcquireOutcome::kReconnect\s*\n\s*: SwapchainAcquireOutcome::kFailed;/return SwapchainAcquireOutcome::kFailed;/' \
  "${HDR}" > "${RED_DIR}/swapchain_acquire_recovery.h"
if cmp -s "${HDR}" "${RED_DIR}/swapchain_acquire_recovery.h"; then
  fail "RED mutation did not change the header (mapping text drifted)"
fi

echo ""
echo "==========================================================================="
echo "RED: macOS pool-memory mapping removed in a throwaway header copy"
echo "==========================================================================="
RED_BIN="${WORK}/drawable_recovery_test.red"
"${CXX}" -std=c++17 -Wall -Wextra -I "${RED_DIR}" -I "${VULKAN_INC}" \
  "${TEST_SRC}" -o "${RED_BIN}"
set +e
"${RED_BIN}"
red_rc=$?
set -e
if [[ "${red_rc}" -eq 0 ]]; then
  fail "RED run unexpectedly passed; the test does not bind to the recovery"
fi
echo "RED RESULT: test failed as expected (exit ${red_rc})"

# ---------------------------------------------------------------------------
# Acquire-synchronization recovery: the helper that replaces the acquire
# semaphore/fence after a reconnect, exercised against an instrumented fake
# dispatch. GREEN must replace the potentially-signaled pair at retirement.
# ---------------------------------------------------------------------------
run_sync_case() {
  local label="$1" include_dir="$2"
  local bin="${WORK}/drawable_recovery_sync_test.${label}"
  echo ""
  echo ">>> [${label}] compiling acquire-sync recovery test"
  "${CXX}" -std=c++17 -Wall -Wextra \
    -I "${include_dir}" -I "${VULKAN_INC}" \
    "${SYNC_TEST_SRC}" -o "${bin}"
  echo ">>> [${label}] running acquire-sync recovery test"
  "${bin}"
}

echo ""
echo "==========================================================================="
echo "GREEN: real acquire-sync recovery helper"
echo "==========================================================================="
run_sync_case green "${HDR_DIR}"
echo "GREEN RESULT: all acquire-sync recovery checks passed (exit 0)"

# RED: suppress the replacement loop in a throwaway copy and confirm the test
# fails, proving it binds to the replacement, not to the helper merely
# compiling.
SYNC_RED_DIR="${WORK}/red-sync-header"
rm -rf "${SYNC_RED_DIR}"
mkdir -p "${SYNC_RED_DIR}"
perl -0777 -pe \
  's/for \(uint32_t slot = 0; slot < slot_count; \+\+slot\)/for (uint32_t slot = 0; slot < 0; ++slot)/' \
  "${SYNC_HDR}" > "${SYNC_RED_DIR}/swapchain_acquire_sync_recovery.h"
if cmp -s "${SYNC_HDR}" "${SYNC_RED_DIR}/swapchain_acquire_sync_recovery.h"; then
  fail "RED mutation did not change the acquire-sync header (replacement loop drifted)"
fi

echo ""
echo "==========================================================================="
echo "RED: acquire-sync replacement removed in a throwaway header copy"
echo "==========================================================================="
SYNC_RED_BIN="${WORK}/drawable_recovery_sync_test.red"
"${CXX}" -std=c++17 -w -I "${SYNC_RED_DIR}" -I "${VULKAN_INC}" \
  "${SYNC_TEST_SRC}" -o "${SYNC_RED_BIN}"
set +e
"${SYNC_RED_BIN}"
sync_red_rc=$?
set -e
if [[ "${sync_red_rc}" -eq 0 ]]; then
  fail "RED acquire-sync run unexpectedly passed; the test does not bind to the replacement"
fi
echo "RED RESULT: acquire-sync test failed as expected (exit ${sync_red_rc})"

echo ""
echo "==========================================================================="
echo "PASS: GREEN clean, RED fails without the recovery and the acquire-sync replacement."
echo "==========================================================================="
