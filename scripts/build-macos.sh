#!/usr/bin/env bash
#
# build-macos.sh - native macOS build of ReStreet (FIFA Street 2012 recompiled).
#
# This is the macOS counterpart to the Windows workflow in
# Installer/BuildFifaStreet.ps1 and docs/BUILDING.md. It does not replace or
# modify the Windows path: the PowerShell scripts and MSVC workflow stay as-is.
#
# It prepares a pinned ReXGlue SDK, applies the project patch stack once (project
# changes, then macOS portability, then the macOS drawable/acquire recovery), runs
# the code generator, and compiles the host executable plus the two guest modules:
#
#   fifastreet
#   libfifastreet_fifadllzf_xex.dylib
#   libfifastreet_FootballCompEngzf_xex.dylib
#
# Everything it writes lands in ignored directories:
#   ReXGlue/                     pinned SDK checkout (git-ignored)
#   build/macos/                 workspace, output and logs (git-ignored)
#   private/mac-build/extract/   game data (git-ignored, never committed)
#
# A successful compile is not gameplay validation.
#
set -euo pipefail

# --- pinned inputs -----------------------------------------------------------
REXGLUE_URL="https://github.com/rexglue/rexglue-sdk.git"
REXGLUE_PIN="c94f5ebdcb3c9d1a460ca48e04f9758448f8d518"

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REXGLUE_DIR="${ROOT}/ReXGlue"
PATCH="${ROOT}/patches/rexglue-macos-base.patch"
PATCH_MACOS="${ROOT}/patches/rexglue-macos-portability.patch"
PATCH_RECOVERY="${ROOT}/patches/rexglue-macos-drawable-recovery.patch"
TEMPLATE="${ROOT}/Installer/recomp-template"

BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
WORKSPACE="${BUILD_ROOT}/work/FifaStreetRex"
OUTPUT_DIR="${BUILD_ROOT}/out"
LOG_DIR="${BUILD_ROOT}/logs"
DEFAULT_GAMEDATA="${ROOT}/private/mac-build/extract/FIFA Street/GameData"

# macOS-only register-table override. The embedded register_cpp template puts
# every registrar->SetFunction() call in one function (~159k for fifadllzf),
# which is pathological for the clang backend. The override in the project
# template tree splits it into bounded chunks; it is staged into the workspace
# and activated per-binary via the manifest's template_dir. The Windows build
# never sets template_dir, so it keeps the embedded template.
TEMPLATE_OVERRIDE_DIR="${WORKSPACE}/recomp-templates"

# --- options -----------------------------------------------------------------
GAMEDATA="${FIFA_GAMEDATA:-${DEFAULT_GAMEDATA}}"
JOBS="${FIFA_JOBS:-2}"
ARCH="${FIFA_ARCH:-arm64}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.3}"
CLEAN=0
SKIP_SDK=0
PACKAGE_APP=1
CHECK_ONLY=0

usage() {
  cat <<EOF
Usage: scripts/build-macos.sh [options]

Options:
  --gamedata PATH   Extracted GameData directory
                    (default: ${DEFAULT_GAMEDATA})
  --jobs N          Parallel compile jobs, a positive integer (default: 2; keep
                    low for 16 GB)
  --arch ARCH       macOS architecture: arm64 or x86_64 (default: arm64)
  --clean           Remove the game workspace and output before building
  --skip-sdk        Reuse an already-built SDK under ReXGlue/out
  --no-app          Skip assembling "FIFA Street.app" at the end
  --check-only      Run preflight (tools, game data, module hashes) and exit
  -h, --help        Show this help

Environment: FIFA_GAMEDATA, FIFA_JOBS, FIFA_ARCH, MACOSX_DEPLOYMENT_TARGET,
             FIFA_BUILD_ROOT (workspace/output/logs root; default build/macos)
             FIFA_INSTALLER_MANIFEST (optional precompiled.json from a release
             installer; cross-checked against the supported revision)
             FIFA_SUPPORTED_INPUTS (advanced/test only: override the supported
             input set; the shipped revision guard is then NOT enforced)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gamedata)  [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--gamedata requires a path" >&2; exit 2; }; GAMEDATA="$2"; shift 2 ;;
    --jobs)      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--jobs requires a count" >&2; exit 2; }; JOBS="$2"; shift 2 ;;
    --arch)      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--arch requires a value" >&2; exit 2; }; ARCH="$2"; shift 2 ;;
    --clean)     CLEAN=1; shift ;;
    --skip-sdk)  SKIP_SDK=1; shift ;;
    --no-app)    PACKAGE_APP=0; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] \
  || { echo "Unsupported --jobs '${JOBS}' (must be a positive integer)" >&2; exit 2; }

case "${ARCH}" in
  arm64)  PLATFORM="mac-arm64" ;;
  x86_64) PLATFORM="mac-amd64" ;;
  *) echo "Unsupported --arch '${ARCH}' (use arm64 or x86_64)" >&2; exit 2 ;;
esac

PRESET_SDK="${PLATFORM}"                # ReXGlue SDK preset (Ninja Multi-Config)
PRESET_GAME="${PLATFORM}-release"       # project game preset (Ninja, single-config)

mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}"

die() { echo "ERROR: $*" >&2; exit 1; }

# ============================================================================
# 1. Preflight
# ============================================================================
echo "=============================================================="
echo " ReStreet - macOS native build"
echo "=============================================================="
echo "Root:        ${ROOT}"
echo "GameData:    ${GAMEDATA}"
echo "Platform:    ${PLATFORM} (${ARCH}, min macOS ${DEPLOYMENT_TARGET})"
echo "Jobs:        ${JOBS}"
echo "Logs:        ${LOG_DIR}"
echo ""

[[ "$(uname -s)" == "Darwin" ]] || die "this script only runs on macOS"
command -v git   >/dev/null || die "git not found"
command -v cmake >/dev/null || die "cmake not found (brew install cmake)"
command -v ninja >/dev/null || die "ninja not found (brew install ninja)"
command -v python3 >/dev/null || die "python3 not found (needed to verify the guest startup-ordering hooks)"

CLANG="${FIFA_CLANG:-/usr/bin/clang}"
CLANGXX="${FIFA_CLANGXX:-/usr/bin/clang++}"
[[ -x "${CLANG}" ]]   || die "clang not found at ${CLANG} (run: xcode-select --install)"
[[ -x "${CLANGXX}" ]] || die "clang++ not found at ${CLANGXX}"

# ReXGlue enforces a Clang toolchain and a version floor for C++23 (see
# ReXGlue/CMakeLists.txt): LLVM Clang 18+, or AppleClang 16+ (Xcode 16). Check it
# here so an old toolchain fails fast with an actionable message instead of deep
# inside the SDK configure. The Vulkan loader and MoltenVK are vendored SDK
# submodules built from source (ReXGlue/thirdparty, REQUIRED_SUBMODULES on
# APPLE), so no Homebrew Vulkan packages are needed.
CLANG_BANNER="$("${CLANGXX}" --version 2>/dev/null || true)"
if [[ "${CLANG_BANNER}" == *"Apple clang"* ]]; then CLANG_FLOOR=16; else CLANG_FLOOR=18; fi
CLANG_MAJOR="$("${CLANGXX}" -dumpversion 2>/dev/null | cut -d. -f1)"
[[ "${CLANG_MAJOR}" =~ ^[0-9]+$ ]] \
  || die "cannot determine the clang version at ${CLANGXX}"
(( CLANG_MAJOR >= CLANG_FLOOR )) \
  || die "clang ${CLANG_MAJOR} is too old: ReXGlue needs AppleClang ${CLANG_FLOOR}+ (Xcode 16+) or LLVM Clang 18+ for C++23"

# --- module presence + sanity -----------------------------------------------
[[ -d "${GAMEDATA}" ]] || die "game-data root not found: ${GAMEDATA}
Pass --gamedata /path/to/GameData (the extracted folder containing default.xex)."
DEFAULT_XEX="${GAMEDATA}/default.xex"
FIFA_DLL="${GAMEDATA}/fifadllzf.xex.dll"
COMP_ENG="${GAMEDATA}/dlc/dlc_FootballCompEng/dlc/FootballCompEng/FootballCompEngzf.xex.dll"
for f in "${DEFAULT_XEX}" "${FIFA_DLL}" "${COMP_ENG}"; do
  [[ -f "$f" ]] || die "missing required original module: $f
(Is ${GAMEDATA} the extracted FIFA Street (2012) GameData root?)"
done
# XEX2 magic check - refuse anything that is not an Xbox 360 module.
for f in "${DEFAULT_XEX}" "${FIFA_DLL}" "${COMP_ENG}"; do
  magic="$(head -c 4 "$f" | LC_ALL=C tr -d '\0')"
  [[ "${magic}" == "XEX2" ]] || die "not an XEX2 module: $f (magic='${magic}')"
done

# Supported-revision guard. The recompiled startup hooks are keyed to fixed
# guest instruction addresses, so only the exact original FIFA Street (2012)
# revision this source tree was validated against can be compiled correctly. The
# supported set is source-controlled in scripts/supported-macos-inputs.json,
# measured from our own extracted GameData; it is not an externally published
# official manifest, and no support is claimed for other regions or revisions.
#
# Always enforced, before any SDK download, code generation or build. An optional
# installer manifest (FIFA_INSTALLER_MANIFEST) is cross-checked so it can only
# confirm the same revision, never silently authorize a different one.
SUPPORTED_INPUTS="${FIFA_SUPPORTED_INPUTS:-${SCRIPT_DIR}/supported-macos-inputs.json}"
if [[ "${SUPPORTED_INPUTS}" != "${SCRIPT_DIR}/supported-macos-inputs.json" ]]; then
  echo "WARN: supported-input set overridden by FIFA_SUPPORTED_INPUTS=${SUPPORTED_INPUTS}"
  echo "      test/advanced only; the shipped revision guard is NOT enforced"
fi
echo ">>> Enforcing supported original-module SHA-256 (${SUPPORTED_INPUTS})..."
VERIFY_INPUTS=(--spec "${SUPPORTED_INPUTS}" --gamedata "${GAMEDATA}")
if [[ -n "${FIFA_INSTALLER_MANIFEST:-}" ]]; then
  MANIFEST="${FIFA_INSTALLER_MANIFEST}"
  [[ -f "${MANIFEST}" ]] || die "FIFA_INSTALLER_MANIFEST not found: ${MANIFEST}"
  echo ">>> Cross-checking that the installer manifest describes the same revision..."
  VERIFY_INPUTS+=(--manifest "${MANIFEST}")
fi
python3 "${SCRIPT_DIR}/verify-supported-inputs.py" "${VERIFY_INPUTS[@]}" \
  || die "GameData is not the supported FIFA Street (2012) revision (see above)"
echo "GameData modules OK (XEX2): default.xex, fifadllzf.xex.dll, FootballCompEngzf.xex.dll"

if [[ "${CHECK_ONLY}" == "1" ]]; then
  echo ""
  echo "Preflight OK (--check-only); no build was started."
  exit 0
fi

# ============================================================================
# 2. ReXGlue SDK: clone at the pin, patch once
# ============================================================================
if [[ ! -d "${REXGLUE_DIR}/.git" ]]; then
  echo ""
  echo ">>> Cloning ReXGlue recursively (log: ${LOG_DIR}/rexglue-clone.log)..."
  if ! git clone --recursive "${REXGLUE_URL}" "${REXGLUE_DIR}" \
        >"${LOG_DIR}/rexglue-clone.log" 2>&1; then
    tail -30 "${LOG_DIR}/rexglue-clone.log"
    die "ReXGlue clone failed"
  fi
fi

echo ""
echo ">>> Checking out pinned revision ${REXGLUE_PIN:0:12}..."
git -C "${REXGLUE_DIR}" fetch --tags --quiet origin || true
git -C "${REXGLUE_DIR}" checkout --quiet "${REXGLUE_PIN}" \
  || die "cannot checkout ${REXGLUE_PIN}"
git -C "${REXGLUE_DIR}" submodule update --init --recursive \
  || die "submodule update failed"

HEAD_SHA="$(git -C "${REXGLUE_DIR}" rev-parse HEAD)"
[[ "${HEAD_SHA}" == "${REXGLUE_PIN}" ]] || die "SDK HEAD ${HEAD_SHA} != pin ${REXGLUE_PIN}"

# Apply the patch stack exactly once, in order: project changes, then the macOS
# portability fix, then the macOS drawable/acquire recovery. A later patch edits
# context an earlier one also matches, so no single patch's reverse-check is
# authoritative on its own; scripts/rexglue-patches.sh finds the topmost
# already-applied patch and applies only what sits above it, rejecting a
# conflicting tree instead of guessing. See that file for the reasoning.
"${SCRIPT_DIR}/rexglue-patches.sh" "${REXGLUE_DIR}" \
  "${PATCH}" "${PATCH_MACOS}" "${PATCH_RECOVERY}" \
  || die "failed to apply the ReXGlue patch stack to ${REXGLUE_PIN:0:12}"

# ============================================================================
# 3. Build the ReXGlue SDK (Vulkan/MoltenVK on macOS, D3D12 forced off)
# ============================================================================
SKIP_SDK_BUILD="${SKIP_SDK}"
if [[ "${SKIP_SDK_BUILD}" == "1" && ! -x "${REXGLUE_DIR}/out/${PLATFORM}/Release/rexglue" ]]; then
  echo "WARN: --skip-sdk given but no SDK build found; building anyway."
  SKIP_SDK_BUILD=0
fi

if [[ "${SKIP_SDK_BUILD}" == "0" ]]; then
  echo ""
  echo ">>> Configuring ReXGlue SDK (${PRESET_SDK})..."
  CC="${CLANG}" CXX="${CLANGXX}" \
  cmake --preset "${PRESET_SDK}" -S "${REXGLUE_DIR}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DREXGLUE_USE_VULKAN=ON -DREXGLUE_USE_D3D12=OFF \
    -DREXGLUE_ENABLE_TRACY=ON \
    >"${LOG_DIR}/sdk-configure.log" 2>&1 \
    || { echo "SDK configure failed; tail of log:"; tail -40 "${LOG_DIR}/sdk-configure.log"; die "SDK configure failed"; }
  echo "    configure log: ${LOG_DIR}/sdk-configure.log"

  echo ">>> Building ReXGlue SDK (Release, ${JOBS} jobs)..."
  cmake --build "${REXGLUE_DIR}/out/build/${PRESET_SDK}" --config Release --parallel "${JOBS}" \
    >"${LOG_DIR}/sdk-build.log" 2>&1 \
    || { echo "SDK build failed; tail of log:"; tail -60 "${LOG_DIR}/sdk-build.log"; die "SDK build failed"; }
  echo "    build log: ${LOG_DIR}/sdk-build.log"
fi

REXGLUE_BIN="${REXGLUE_DIR}/out/${PLATFORM}/Release/rexglue"
[[ -x "${REXGLUE_BIN}" ]] || REXGLUE_BIN="${REXGLUE_DIR}/out/${PLATFORM}/rexglue"
[[ -x "${REXGLUE_BIN}" ]] || die "rexglue code generator not found under ${REXGLUE_DIR}/out/${PLATFORM}"
echo ">>> Code generator: ${REXGLUE_BIN}"

# ============================================================================
# 4. Prepare the game workspace
# ============================================================================
if [[ "${CLEAN}" == "1" ]]; then
  echo ">>> Cleaning workspace and output..."
  rm -rf "${WORKSPACE}" "${OUTPUT_DIR}"
  mkdir -p "${OUTPUT_DIR}"
fi

mkdir -p "${WORKSPACE}"
# Copy the template, but keep any already-generated code for incremental builds.
for entry in "${TEMPLATE}"/*; do
  name="$(basename "${entry}")"
  [[ "${name}" == "fifastreet_manifest.toml" ]] && continue
  cp -R "${entry}" "${WORKSPACE}/"
done
mkdir -p "${WORKSPACE}/config"

# The manifest below advertises template_dir, so the override must be present or
# codegen silently falls back to the single-function embedded template.
[[ -f "${TEMPLATE_OVERRIDE_DIR}/codegen/register_cpp.inja" ]] \
  || die "register template override missing: ${TEMPLATE_OVERRIDE_DIR}/codegen/register_cpp.inja"

# Absolute, forward-slash paths for the manifest (TOML). Backslashes are the
# Windows form; macOS uses '/'.
GAMEDATA_POSIX="$(cd "${GAMEDATA}" && pwd)"
cat > "${WORKSPACE}/fifastreet_manifest.toml" <<EOF
[project]
name = "fifastreet"
sdk_version = "0.10.0"
game_root = "${GAMEDATA_POSIX}"

[entrypoint]
file_path = "${GAMEDATA_POSIX}/default.xex"
out_directory_path = "generated/default"
template_dir = "${TEMPLATE_OVERRIDE_DIR}"
includes = ["config/default_overrides.toml"]

[[modules]]
guest_path = "game:\\\\fifadllzf.xex.dll"
file_path = "${GAMEDATA_POSIX}/fifadllzf.xex.dll"
out_directory_path = "generated/fifadllzf_xex"
template_dir = "${TEMPLATE_OVERRIDE_DIR}"
includes = ["config/fifadllzf_overrides.toml"]

[[modules]]
guest_path = "game:\\\\FootballCompEngzf.xex.dll"
file_path = "${GAMEDATA_POSIX}/dlc/dlc_FootballCompEng/dlc/FootballCompEng/FootballCompEngzf.xex.dll"
out_directory_path = "generated/FootballCompEngzf_xex"
template_dir = "${TEMPLATE_OVERRIDE_DIR}"
includes = ["config/footballcompeng_overrides.toml"]
EOF

# ============================================================================
# 5. Run the code generator (must precede configure so dll_targets.cmake exists)
# ============================================================================
echo ""
echo ">>> Generating recompiled guest sources (first run can take a while)..."
( cd "${WORKSPACE}" && "${REXGLUE_BIN}" --log-file "${LOG_DIR}/codegen.log" codegen fifastreet_manifest.toml ) \
  >"${LOG_DIR}/codegen-console.log" 2>&1 \
  || { echo "codegen failed; tail of log:"; tail -40 "${LOG_DIR}/codegen-console.log"; die "codegen failed"; }

for d in generated/default generated/fifadllzf_xex generated/FootballCompEngzf_xex; do
  [[ -f "${WORKSPACE}/${d}/sources.cmake" ]] || die "codegen did not produce ${d}/sources.cmake"
done
[[ -f "${WORKSPACE}/generated/default/dll_targets.cmake" ]] || die "codegen did not produce dll_targets.cmake"

# The worker-start ordering fix is a codegen [[midasm_hook]] keyed by guest
# instruction address (config/default_overrides.toml). If the guest image, the
# SDK or the config ever drift so that address stops matching, codegen drops the
# hook silently and the race returns. Fail the build if the hooks did not land.
echo ""
echo ">>> Verifying guest startup-ordering hooks (sub_820509A8)..."
python3 "${SCRIPT_DIR}/verify-macos-startup-order.py" "${WORKSPACE}" \
  || die "guest startup-ordering hooks did not land (see scripts/verify-macos-startup-order.py)"
python3 "${SCRIPT_DIR}/verify-macos-memory-barriers.py" "${WORKSPACE}" \
  || die "generated guest memory barriers are missing"

# ============================================================================
# 6. Configure and build the game
# ============================================================================
echo ""
echo ">>> Configuring game (${PRESET_GAME})..."
( cd "${WORKSPACE}" && \
  # The workspace lives under this repository, whose own release tags (v1.0)
  # are newer than the SDK floor (0.10). Hide the outer repo from the in-tree
  # SDK's git-describe so it uses its own fallback version, as the Windows
  # temp-workspace build does.
  GIT_CEILING_DIRECTORIES="${ROOT}" \
  CC="${CLANG}" CXX="${CLANGXX}" cmake --preset "${PRESET_GAME}" \
    -DREXSDK_DIR="${REXGLUE_DIR}" \
    -DREXGLUE_USE_VULKAN=ON -DREXGLUE_USE_D3D12=OFF \
    -DREXGLUE_OUTPUT_DIRECTORY="${WORKSPACE}/out/build/${PRESET_GAME}/runtime" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
) >"${LOG_DIR}/game-configure.log" 2>&1 \
  || { echo "game configure failed; tail of log:"; tail -40 "${LOG_DIR}/game-configure.log"; die "game configure failed"; }
echo "    configure log: ${LOG_DIR}/game-configure.log"

echo ""
echo ">>> Compiling FIFA Street (Release, ${JOBS} jobs - first build takes tens of minutes)..."
( cd "${WORKSPACE}" && cmake --build --preset "${PRESET_GAME}" --parallel "${JOBS}" ) \
  >"${LOG_DIR}/game-build.log" 2>&1 \
  || { echo "game build failed; tail of log:"; tail -60 "${LOG_DIR}/game-build.log"; die "game build failed"; }
echo "    build log: ${LOG_DIR}/game-build.log"

# ============================================================================
# 7. Collect and verify outputs
# ============================================================================
BUILD_DIR="${WORKSPACE}/out/build/${PRESET_GAME}"
mkdir -p "${OUTPUT_DIR}"
host="${BUILD_DIR}/fifastreet"
[[ -f "${host}" ]] || die "build finished but 'fifastreet' was not produced"
# Replace the host rather than overwriting it in place: macOS caches the code
# signature per vnode, and rewriting a signed Mach-O in place makes the kernel
# kill the next launch. Removing it first forces a fresh inode.
rm -f "${OUTPUT_DIR}/fifastreet"
cp -f "${host}" "${OUTPUT_DIR}/"
# Guest modules are named lib<target>.dylib on macOS.
modules=(
  "${BUILD_DIR}/libfifastreet_fifadllzf_xex.dylib"
  "${BUILD_DIR}/libfifastreet_FootballCompEngzf_xex.dylib"
)
for m in "${modules[@]}"; do
  [[ -f "${m}" ]] || die "build finished but guest module not found: ${m}"
  cp -f "${m}" "${OUTPUT_DIR}/"
done
# Shared runtime libraries are staged next to the host by the SDK POST_BUILD
# step: librexruntime, libTracyClient and the runtime-loaded GPU plugin
# (librexgpu-xenos). The host resolves these via its @executable_path rpath, so
# copy every dylib rather than a hand-maintained subset.
shopt -s nullglob
build_dylibs=( "${BUILD_DIR}"/*.dylib )
shopt -u nullglob
[[ ${#build_dylibs[@]} -gt 0 ]] || die "no dylibs found next to the host in ${BUILD_DIR}"
for lib in "${build_dylibs[@]}"; do
  cp -f "${lib}" "${OUTPUT_DIR}/"
done
# Targeted rebuilds (`--target rexruntime` or `--target rexgpu-xenos`) refresh
# the canonical library under runtime/, but the copy next to the host comes from
# the host's POST_BUILD step, which a targeted build does not re-run, so it can
# be stale. Stage each canonical library last and verify it byte-for-byte, so a
# full and a targeted build both ship the current runtime and GPU plugin. The
# GPU plugin matters just as much as the runtime: it is loaded by name at
# runtime, so a stale copy renders with old code (see docs/BUILDING-MACOS.md,
# "Updating the runtime").
stage_canonical() {
  local canonical="$1" name="$2"
  if [[ ! -f "${canonical}" ]]; then
    echo "WARN: canonical ${name} not found at ${canonical}"
    echo "      keeping the copy already staged beside the host"
    return 0
  fi
  cp -f "${canonical}" "${OUTPUT_DIR}/${name}"
  cmp -s "${canonical}" "${OUTPUT_DIR}/${name}" \
    || die "staged ${name} does not match ${canonical}"
}
stage_canonical "${BUILD_DIR}/runtime/librexruntime.dylib" librexruntime.dylib
stage_canonical "${BUILD_DIR}/runtime/librexgpu-xenos.dylib" librexgpu-xenos.dylib
# The GPU plugin is loaded by name at runtime; a build without it cannot render.
[[ -f "${OUTPUT_DIR}/librexgpu-xenos.dylib" ]] \
  || die "GPU plugin librexgpu-xenos.dylib was not produced by the build"
if [[ -d "${BUILD_DIR}/vulkan" ]]; then cp -R "${BUILD_DIR}/vulkan" "${OUTPUT_DIR}/"; fi

# Runtime configuration, read from the executable folder as fifastreet.toml
# (ReXApp builds the config path as <exe_dir>/<app_name>.toml). Rendering and
# input cvars take effect because the config is loaded before presentation and
# input bring-up. Game data is discovered at launch: the app looks for
# default.xex in the executable folder, a GameData subfolder, or the parent
# folder, and --game_data_root=<abs> overrides that. A game_data_root entry in
# this file is intentionally omitted: ReXApp resolves path CVars before it loads
# the config, so writing it here would not take effect.
RUNTIME_CONFIG="${ROOT}/config/macos/fifastreet-runtime.toml"
KEYBOARD_PROFILE="${ROOT}/config/macos/keyboard-arrows.toml"
[[ -f "${RUNTIME_CONFIG}" ]] || die "runtime config template missing: ${RUNTIME_CONFIG}"
[[ -f "${KEYBOARD_PROFILE}" ]] || die "keyboard profile missing: ${KEYBOARD_PROFILE}"
# The template carries the macOS stable-launch cvars (vulkan_macos_unpaced_present
# and the idle sleep flags), so a Finder double-click of the bundle gets them
# from the config exactly like scripts/play-macos.sh; the host itself defaults the
# MoltenVK synchronous-submit variable before the Vulkan device is created.
cp -f "${RUNTIME_CONFIG}" "${OUTPUT_DIR}/fifastreet.toml"
cat "${KEYBOARD_PROFILE}" >> "${OUTPUT_DIR}/fifastreet.toml"

# --- application bundle ------------------------------------------------------
# Assemble the double-clickable "FIFA Street.app" (Contents/MacOS + Info.plist +
# GameData symlink). Re-runnable on its own via scripts/package-macos-app.sh;
# --no-app skips it. See docs/BUILDING-MACOS.md, "Application bundle (macOS)".
APP_PATH=""
if [[ "${PACKAGE_APP}" == "1" ]]; then
  echo ""
  echo ">>> Assembling ${OUTPUT_DIR}/FIFA Street.app..."
  "${SCRIPT_DIR}/package-macos-app.sh" --out "${OUTPUT_DIR}" --gamedata "${GAMEDATA}" \
    || die "app packaging failed"
  APP_PATH="${OUTPUT_DIR}/FIFA Street.app"
fi

# ============================================================================
# 8. Verify what was produced (compile-only; not gameplay validation)
# ============================================================================
echo ""
echo ">>> Verifying staged artifacts (${ARCH})..."
"${SCRIPT_DIR}/verify-macos-artifacts.sh" --arch "${ARCH}" "${OUTPUT_DIR}" \
  || die "artifact verification failed (see output above)"
if [[ -n "${APP_PATH}" ]]; then
  echo ">>> Verifying bundle (${ARCH})..."
  "${SCRIPT_DIR}/verify-macos-app.sh" --arch "${ARCH}" "${APP_PATH}" \
    || die "bundle verification failed (see output above)"
fi

echo ""
echo "=============================================================="
echo " BUILD COMPLETE (compile only - not gameplay validation)"
echo "=============================================================="
echo "Output:  ${OUTPUT_DIR}"
ls -1 "${OUTPUT_DIR}"
if [[ -n "${APP_PATH}" ]]; then
  echo "App:     ${APP_PATH}"
fi
echo ""
echo "Logs:    ${LOG_DIR}"
echo "Workspace (resume with --skip-sdk): ${WORKSPACE}"
echo ""
echo "Run:"
if [[ -n "${APP_PATH}" ]]; then
  echo "  open \"${APP_PATH}\""
  echo "  # or run the bundle executable directly:"
  echo "  \"${APP_PATH}/Contents/MacOS/fifastreet\" --game_data_root=\"${GAMEDATA}\""
else
  echo "  \"${OUTPUT_DIR}/fifastreet\" --game_data_root=\"${GAMEDATA}\""
fi
echo "  # or place GameData beside the host, then:"
echo "  (cd \"${OUTPUT_DIR}\" && ./fifastreet)"
