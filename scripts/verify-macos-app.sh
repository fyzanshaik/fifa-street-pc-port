#!/usr/bin/env bash
#
# verify-macos-app.sh - verify the packaged "FIFA Street.app" bundle.
#
# Compile-only + metadata verification: confirms the bundle layout, a valid
# plist, the expected architecture for the host, dylibs and bundled Vulkan
# loader/MoltenVK, the bundled runtime and GPU plugin byte-match the linker's
# canonical output, the recompiled guest modules dlopen from Contents/MacOS, and
# the GameData symlink resolves. It does not launch the game.
#
# Architecture: the expected architecture comes from --arch / FIFA_ARCH when
# given, otherwise the host architecture is detected reliably (Apple Silicon is
# detected even from a Rosetta shell). A moved or copied bundle whose GameData
# symlink no longer resolves is reported explicitly.
#
# Usage: scripts/verify-macos-app.sh [--arch ARCH] [bundle-path]
#        (default bundle: ${FIFA_BUILD_ROOT:-<repo>/build/macos}/out/FIFA Street.app)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
APP=""
ARCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--arch requires a value" >&2; exit 2; }
      ARCH="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --*)  echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "${APP}" ]]; then APP="$1"; shift; else echo "Unexpected argument: $1" >&2; exit 2; fi ;;
  esac
done
APP="${APP:-${BUILD_ROOT}/out/FIFA Street.app}"

# Apple Silicon is reliably detectable even from a Rosetta (x86_64) shell.
host_arch() {
  if [[ -n "${FIFA_ARCH:-}" ]]; then printf '%s\n' "${FIFA_ARCH}"; return; fi
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
    printf 'arm64\n'; return
  fi
  local cc first
  cc="$(command -v clang 2>/dev/null || true)"
  if [[ -n "${cc}" ]]; then
    first="$(lipo -archs "${cc}" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "${first}" ]]; then printf '%s\n' "${first}"; return; fi
  fi
  uname -m
}

ARCH="${ARCH:-$(host_arch)}"
case "${ARCH}" in
  arm64)  PRESET_GAME="mac-arm64-release" ;;
  x86_64) PRESET_GAME="mac-amd64-release" ;;
  *) echo "Unsupported arch '${ARCH}' (use arm64 or x86_64)" >&2; exit 2 ;;
esac
HOST_ARCH="$(host_arch)"

fail=0
note() { printf '  %s\n' "$*"; }
ok()   { printf 'OK   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fail=1; }

[[ -d "${APP}" ]] || { echo "bundle not found: ${APP}" >&2; exit 2; }
CONTENTS="${APP}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"

echo "Verifying ${APP}"
echo "Expected arch: ${ARCH} (host: ${HOST_ARCH})"
echo

# --- Info.plist --------------------------------------------------------------
PLIST="${CONTENTS}/Info.plist"
if [[ -f "${PLIST}" ]] && plutil -lint "${PLIST}" >/dev/null 2>&1; then
  ok "Info.plist is a valid plist"
  exe="$(plutil -extract CFBundleExecutable raw "${PLIST}" 2>/dev/null || true)"
  ident="$(plutil -extract CFBundleIdentifier raw "${PLIST}" 2>/dev/null || true)"
  name="$(plutil -extract CFBundleName raw "${PLIST}" 2>/dev/null || true)"
  pkgtype="$(plutil -extract CFBundlePackageType raw "${PLIST}" 2>/dev/null || true)"
  [[ "${exe}" == "fifastreet" ]] && ok "CFBundleExecutable=fifastreet" \
    || bad "CFBundleExecutable='${exe}' (expected fifastreet)"
  [[ -n "${ident}" ]] && ok "CFBundleIdentifier=${ident}" || bad "CFBundleIdentifier missing"
  [[ -n "${name}" ]] && ok "CFBundleName=${name}" || bad "CFBundleName missing"
  [[ "${pkgtype}" == "APPL" ]] && ok "CFBundlePackageType=APPL" \
    || bad "CFBundlePackageType='${pkgtype}' (expected APPL)"
else
  bad "Info.plist missing or invalid"
fi
echo

# --- host + dylibs -----------------------------------------------------------
HOST="${MACOS_DIR}/fifastreet"
if [[ -f "${HOST}" && -x "${HOST}" ]]; then
  ok "host present and executable: Contents/MacOS/fifastreet"
else
  bad "host missing or not executable: ${HOST}"
fi

abs_dep_check() {
  local bin="$1" dep
  while IFS= read -r dep; do
    case "${dep}" in
      /opt/homebrew/*|/usr/local/*) bad "${bin}: absolute dependency ${dep}" ;;
    esac
  done < <(otool -L "${bin}" 2>/dev/null | tail -n +2 | awk '{print $1}')
}
arch_check() {
  local label="$1" bin="$2" archs
  archs="$(lipo -archs "${bin}" 2>/dev/null || true)"
  if [[ " ${archs} " == *" ${ARCH} "* ]]; then
    ok "${label}: Mach-O ${archs}"
  else
    bad "${label}: expected ${ARCH}, got '${archs}'"
  fi
  abs_dep_check "${bin}"
}

shopt -s nullglob
bins=( "${MACOS_DIR}/fifastreet" "${MACOS_DIR}"/*.dylib "${MACOS_DIR}"/vulkan/lib/*.dylib )
shopt -u nullglob
for bin in "${bins[@]}"; do
  [[ -f "${bin}" ]] || continue
  arch_check "$(basename "${bin}")" "${bin}"
done
echo

# --- @executable_path rpath --------------------------------------------------
if otool -l "${HOST}" | grep -A2 LC_RPATH | grep -q "@executable_path"; then
  ok "host carries the @executable_path rpath"
else
  bad "host is missing the @executable_path rpath"
fi
echo

# --- config + Vulkan assets --------------------------------------------------
[[ -f "${MACOS_DIR}/fifastreet.toml" ]] && ok "fifastreet.toml beside the host" \
  || bad "fifastreet.toml missing beside the host"
[[ -f "${MACOS_DIR}/vulkan/share/vulkan/icd.d/MoltenVK_icd.json" ]] \
  && ok "bundled Vulkan loader assets present" \
  || bad "bundled Vulkan loader assets missing"
echo

# --- canonical runtime + GPU bytes -------------------------------------------
# Derived from the build root and the arch preset, so it cannot pick a stale or
# wrong-arch library from another preset. The GPU plugin is checked too: like
# the runtime, a targeted rebuild refreshes runtime/librexgpu-xenos.dylib while
# the copy beside the host can stay stale.
CANONICAL_DIR="${BUILD_ROOT}/work/FifaStreetRex/out/build/${PRESET_GAME}/runtime"
check_canonical() {
  local name="$1" canonical="$2"
  if [[ ! -f "${canonical}" ]]; then
    note "canonical ${name} not found at ${canonical}; skipping match"
    return
  fi
  if cmp -s "${canonical}" "${MACOS_DIR}/${name}"; then
    ok "bundled ${name} matches canonical"
  else
    bad "bundled ${name} differs from canonical ${canonical}"
  fi
}
check_canonical librexruntime.dylib \
  "${FIFA_CANONICAL_RUNTIME:-${CANONICAL_DIR}/librexruntime.dylib}"
check_canonical librexgpu-xenos.dylib \
  "${FIFA_CANONICAL_GPU:-${CANONICAL_DIR}/librexgpu-xenos.dylib}"
echo

# --- GameData symlink --------------------------------------------------------
# The symlink points at the private extract. Moving the .app alone keeps it
# valid as long as the original data stays where it was; moving the repository,
# or copying the bundle to another machine, leaves it dangling. Report that case
# explicitly instead of letting discovery silently find nothing.
GAMEDATA="${MACOS_DIR}/GameData"
if [[ -L "${GAMEDATA}" ]]; then
  target="$(readlink "${GAMEDATA}")"
  if [[ -f "${GAMEDATA}/default.xex" ]]; then
    ok "GameData symlink resolves to a tree containing default.xex"
  elif [[ ! -e "${GAMEDATA}" ]]; then
    bad "Contents/MacOS/GameData is a dangling symlink -> ${target}"
    note "the bundle lost its data: restore the original path, move the extract back, or re-run"
    note "package-macos-app.sh --gamedata <abs>/GameData (assets are never copied into the bundle)"
  else
    bad "GameData symlink resolves but has no default.xex (target: ${target})"
  fi
else
  bad "Contents/MacOS/GameData is not a symlink"
fi
echo

# --- guest module dlopen from the bundle -------------------------------------
# Throwaway harness compiled for the target architecture. A missing compiler or
# a harness that cannot run is a failure, not a silent pass.
CLANG="${FIFA_CLANG:-/usr/bin/clang}"
HARNESS_DIR="$(mktemp -d)"
cleanup() { rm -rf "${HARNESS_DIR}"; }
trap cleanup EXIT
if [[ -x "${CLANG}" ]] || command -v "${CLANG}" >/dev/null 2>&1; then
  HARNESS_C="${HARNESS_DIR}/dlopen_check.c"
  cat > "${HARNESS_C}" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>

static int failed = 0;

static void check(const char* lib_dir, const char* target) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/lib%s.dylib", lib_dir, target);
  void* handle = dlopen(path, RTLD_NOW);
  if (!handle) {
    fprintf(stderr, "FAIL %s: %s\n", path, dlerror());
    failed = 1;
    return;
  }
  void* reg = dlsym(handle, "ReXModule_Register");
  void* info = dlsym(handle, "ReXModule_GetImageInfo");
  if (!reg || !info) {
    fprintf(stderr, "FAIL %s: register=%p imageinfo=%p\n", path, reg, info);
    failed = 1;
    return;
  }
  printf("OK   %s\n", path);
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <lib-dir> <target>...\n", argv[0]);
    return 2;
  }
  for (int i = 2; i < argc; ++i) {
    check(argv[1], argv[i]);
  }
  return failed;
}
EOF
  if ! "${CLANG}" -arch "${ARCH}" -o "${HARNESS_DIR}/dlopen_check" "${HARNESS_C}" \
        2>"${HARNESS_DIR}/build.log"; then
    bad "failed to compile the dlopen harness for ${ARCH}:"
    sed 's/^/       /' "${HARNESS_DIR}/build.log"
  elif "${HARNESS_DIR}/dlopen_check" "${MACOS_DIR}" \
         fifastreet_fifadllzf_xex fifastreet_FootballCompEngzf_xex >"${HARNESS_DIR}/run.log" 2>&1; then
    ok "bundled guest modules dlopen from Contents/MacOS (register + image info)"
  else
    bad "bundled guest module dlopen/symbol check failed for ${ARCH}:"
    sed 's/^/       /' "${HARNESS_DIR}/run.log"
    if [[ "${ARCH}" != "${HOST_ARCH}" ]]; then
      case "${ARCH}" in
        x86_64) note "an x86_64 target needs Rosetta 2 to run here: softwareupdate --install-rosetta" ;;
        arm64)  note "an arm64 target cannot run on an x86_64 host" ;;
      esac
    fi
  fi
else
  bad "clang not found at ${CLANG}; cannot validate bundled-module loading (run: xcode-select --install)"
fi
echo

if [[ "${fail}" -ne 0 ]]; then
  echo "BUNDLE VERIFICATION FAILED"
  exit 1
fi
echo "BUNDLE VERIFICATION PASSED (compile-only; not gameplay validation)"
