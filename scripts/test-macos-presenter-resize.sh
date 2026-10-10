#!/usr/bin/env bash
#
# Regression test for the macOS live-resize blank window: when the presenter
# recreates the swapchain for a resize, MoltenVK's forceUnpresentedImageCompletion
# workaround can leave the CAMetalLayer's drawable size at 1x1, which the
# compositor stretches over the whole window (blank) while the guest keeps
# running. The presenter must restore the layer's drawable size to the extent of
# the swapchain it just created.
#
# It builds and runs scripts/presenter_resize_probe.mm, which drives the real
# VulkanPresenter on a real MoltenVK device and a real CAMetalLayer surface,
# feeds a nonblank synthetic guest output from a separate guest-output thread,
# resizes the window through the production SDL resize path, and asserts that the
# layer's drawable size matches the surface after every resize. It opens only its
# own diagnostic window: no game assets, no game process, no input.
#
# GREEN: against the built runtime, every resize must leave the drawable size
# correct (probe exit 0).
# RED: a negative control puts the layer back into MoltenVK's 1x1 state and the
# same check must fail with the probe's *dedicated defect status* (4) and the
# expected mismatch sentinel - a crash, an initialization failure or any other
# non-zero status is not accepted as a valid RED.
#
# MoltenVK is forced to synchronous queue submission (MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1),
# matching the shipped runtime's host default, so the probe runs on the same
# submission model as the game.
#
#   bash scripts/test-macos-presenter-resize.sh
#
# Env overrides:
#   FIFA_BUILD_ROOT           build root (default build/macos)
#   PRESENTER_RESIZE_RUNTIME  path to librexruntime.dylib (defaults to the
#                             canonical runtime in the build tree, then build/macos/out)
#   PRESENTER_RESIZE_GREEN_LOG  GREEN output log (default <logs>/presenter-resize/green.txt)
#   PRESENTER_RESIZE_RED_LOG    RED output log   (default <logs>/presenter-resize/red.txt)
#   PRESENTER_RESIZE_TIMEOUT    per-run watchdog timeout in seconds (default 120)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
WORK="${ROOT}/build/macos/logs/presenter-resize"
CXX="${CXX:-clang++}"
PROBE_SRC="${ROOT}/scripts/presenter_resize_probe.mm"
VULKAN_ROOT="${VULKAN_ROOT:-${ROOT}/build/macos/out/vulkan}"
CXX23_STD="-std=c++23"
TIMEOUT_SECONDS="${PRESENTER_RESIZE_TIMEOUT:-120}"

fail() { echo "ERROR: $*" >&2; exit 1; }

# Exit statuses emitted by scripts/presenter_resize_probe.mm; keep in sync.
PROBE_EXIT_PASS=0
PROBE_EXIT_HARNESS=3
PROBE_EXIT_DRAWABLE_DEFECT=4
PROBE_PASS_SENTINEL="PROBE PASS:"
PROBE_FAIL_SENTINEL="PROBE FAIL"
PROBE_DEFECT_SENTINEL="PROBE FAIL: drawable-size defect"
# The reported defect transition on the ultrawide display: a resize to
# 1825x1045 that leaves the layer at 1x1.
PROBE_GREEN_RESIZE_LINE="PROBE after-resize: expected_drawable=1825x1045 actual_drawable=1825x1045 OK"
PROBE_RED_MISMATCH_LINE="PROBE after-resize: expected_drawable=1825x1045 actual_drawable=1x1 MISMATCH"

[[ -f "${PROBE_SRC}" ]] || fail "missing ${PROBE_SRC}"
[[ -f "${VULKAN_ROOT}/lib/libvulkan.1.dylib" ]] || fail \
  "Vulkan loader not found at ${VULKAN_ROOT}/lib/libvulkan.1.dylib"
[[ -f "${VULKAN_ROOT}/share/vulkan/icd.d/MoltenVK_icd.json" ]] || fail \
  "MoltenVK ICD not found at ${VULKAN_ROOT}/share/vulkan/icd.d/MoltenVK_icd.json"

RUNTIME="${PRESENTER_RESIZE_RUNTIME:-}"
if [[ -z "${RUNTIME}" ]]; then
  for candidate in \
    "${BUILD_ROOT}/work/FifaStreetRex/out/build/mac-arm64-release/runtime/librexruntime.dylib" \
    "${BUILD_ROOT}/out/librexruntime.dylib"; do
    if [[ -f "${candidate}" ]]; then
      RUNTIME="${candidate}"
      break
    fi
  done
fi
[[ -n "${RUNTIME}" && -f "${RUNTIME}" ]] || fail \
  "librexruntime.dylib not found; build it or set PRESENTER_RESIZE_RUNTIME"
RUNTIME_DIR="$(cd "$(dirname "${RUNTIME}")" && pwd)"

SDK_INCLUDE="${BUILD_ROOT}/work/FifaStreetRex/out/build/mac-arm64-release/rexglue-sdk/include"
SDL_INCLUDE_REVISION="${BUILD_ROOT}/work/FifaStreetRex/out/build/mac-arm64-release/rexglue-sdk/thirdparty/sdl3/include-revision"

mkdir -p "${WORK}"
BIN="${WORK}/presenter-resize-probe"
GREEN_LOG="${PRESENTER_RESIZE_GREEN_LOG:-${WORK}/green.txt}"
RED_LOG="${PRESENTER_RESIZE_RED_LOG:-${WORK}/red.txt}"

echo ">>> Building the probe against ${RUNTIME}"
"${CXX}" ${CXX23_STD} -O2 -w \
  -DREX_PLATFORM_MAC=1 -DREX_HAS_VULKAN=1 -DREXGLUE_ENABLE_PERF_COUNTERS \
  -DSPDLOG_COMPILED_LIB -DSPDLOG_FMT_EXTERNAL -DREXGLUE_BUILD_CONFIG='"Release"' \
  -I "${ROOT}/ReXGlue/include" \
  -I "${ROOT}/ReXGlue/src" \
  -I "${SDK_INCLUDE}" \
  -I "${ROOT}/ReXGlue/thirdparty/sdl3/include" \
  -I "${SDL_INCLUDE_REVISION}" \
  -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" \
  -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
  -I "${ROOT}/ReXGlue/thirdparty/vulkan-headers/include" \
  -I "${ROOT}/ReXGlue/thirdparty/imgui" \
  -I "${ROOT}/ReXGlue/thirdparty/stb" \
  -I "${ROOT}/ReXGlue/thirdparty/simde" -I "${ROOT}/ReXGlue/thirdparty/simde/simde" \
  -I "${ROOT}/ReXGlue/thirdparty/utfcpp/source" \
  "${PROBE_SRC}" "${RUNTIME_DIR}/librexruntime.dylib" \
  -framework Cocoa -framework QuartzCore -framework Metal -framework CoreVideo \
  -framework CoreMedia -framework IOKit -framework GameController -framework Carbon \
  -framework AudioToolbox -framework AVFoundation -framework ForceFeedback -framework CoreAudio \
  -Wl,-rpath,"${RUNTIME_DIR}" \
  -o "${BIN}"

export VULKAN_SDK="${VULKAN_ROOT}"
export VK_DRIVER_FILES="${VULKAN_ROOT}/share/vulkan/icd.d/MoltenVK_icd.json"
export VK_ICD_FILENAMES="${VULKAN_ROOT}/share/vulkan/icd.d/MoltenVK_icd.json"
# Match the shipped runtime's host default (see macos_host_defaults.h): MoltenVK
# reads this lazily on first use, so an explicit process-local 1 is the same
# submission model the game runs with.
export MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1
echo ">>> MoltenVK synchronous queue submits (shipped host default): MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=${MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS}"

# Runs one probe invocation with a bounded watchdog, writing its full output to
# `log`, echoing it to this script's stdout, and returning the probe's status
# (124 if the watchdog had to kill it). The probe is the only target so a GPU
# deadlock cannot hang the suite.
run_bounded() {
  local seconds="$1"
  local log="$2"
  shift 2
  : >"${log}"
  "$@" >>"${log}" 2>&1 &
  local pid=$!
  local deadline=$((SECONDS + seconds))
  while kill -0 "${pid}" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      {
        echo ""
        echo "WATCHDOG: probe exceeded ${seconds}s; terminating (pid ${pid})"
      } >>"${log}"
      kill -TERM "${pid}" 2>/dev/null || true
      local grace
      for grace in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.2
      done
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      cat "${log}"
      return 124
    fi
    sleep 0.2
  done
  wait "${pid}"
  local rc=$?
  cat "${log}"
  return "${rc}"
}

# A short, deterministic sequence including the reported 1280x720 -> 1825x1045
# transition on the ultrawide display.
RESIZE_ARGS=("${VULKAN_ROOT}" 1280 720 1600 900 1825 1045 1500 800)

echo ""
echo "==========================================================================="
echo "GREEN: drawable size restored after every resize"
echo "==========================================================================="
set +e
run_bounded "${TIMEOUT_SECONDS}" "${GREEN_LOG}" "${BIN}" "${RESIZE_ARGS[@]}"
green_rc=$?
set -e
echo "GREEN exit status: ${green_rc} (log: ${GREEN_LOG})"
if [[ "${green_rc}" -ne "${PROBE_EXIT_PASS}" ]]; then
  fail "GREEN exited ${green_rc}, expected ${PROBE_EXIT_PASS} (status is not the pass status)"
fi
grep -qF "${PROBE_PASS_SENTINEL}" "${GREEN_LOG}" \
  || fail "GREEN log is missing the '${PROBE_PASS_SENTINEL}' sentinel"
if grep -qF "${PROBE_FAIL_SENTINEL}" "${GREEN_LOG}"; then
  fail "GREEN log contains a '${PROBE_FAIL_SENTINEL}' sentinel"
fi
if grep -qF "MISMATCH" "${GREEN_LOG}"; then
  fail "GREEN log contains a drawable-size MISMATCH"
fi
grep -qF "${PROBE_GREEN_RESIZE_LINE}" "${GREEN_LOG}" \
  || fail "GREEN log is missing the expected 1825x1045 OK resize line"
echo "GREEN RESULT: every resize check passed (exit ${green_rc}, sentinel present)"

echo ""
echo "==========================================================================="
echo "RED: negative control - layer forced back to MoltenVK's 1x1 before checking"
echo "==========================================================================="
export PROBE_FORCE_CLOBBER=1
set +e
run_bounded "${TIMEOUT_SECONDS}" "${RED_LOG}" "${BIN}" "${RESIZE_ARGS[@]}"
red_rc=$?
set -e
unset PROBE_FORCE_CLOBBER
echo "RED exit status: ${red_rc} (log: ${RED_LOG})"
if [[ "${red_rc}" -eq "${PROBE_EXIT_HARNESS}" ]]; then
  fail "RED exited ${red_rc} (harness failure): the probe did not reach the drawable-size check"
fi
if [[ "${red_rc}" -ne "${PROBE_EXIT_DRAWABLE_DEFECT}" ]]; then
  fail "RED exited ${red_rc}, expected the dedicated defect status ${PROBE_EXIT_DRAWABLE_DEFECT}"
fi
grep -qF "${PROBE_RED_MISMATCH_LINE}" "${RED_LOG}" \
  || fail "RED log is missing the expected 1825x1045 -> 1x1 MISMATCH line"
grep -qF "${PROBE_DEFECT_SENTINEL}" "${RED_LOG}" \
  || fail "RED log is missing the '${PROBE_DEFECT_SENTINEL}' sentinel"
echo "RED RESULT: failed with the dedicated defect status ${red_rc} and the expected sentinels"

echo ""
echo "==========================================================================="
echo "PASS: drawable size correct after every resize (GREEN), and the check"
echo "      fails with status ${PROBE_EXIT_DRAWABLE_DEFECT} when the layer is left at 1x1 (RED)."
echo "==========================================================================="
