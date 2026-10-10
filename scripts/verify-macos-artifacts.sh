#!/usr/bin/env bash
#
# verify-macos-artifacts.sh - check the artifacts produced by build-macos.sh.
#
# Compile-only verification: confirms every shipped Mach-O (host, dylibs and the
# bundled Vulkan loader/MoltenVK) has the expected architecture, that the guest
# modules and GPU plugin are present, that the staged runtime and GPU plugin
# byte-match the linker's canonical output, and that runtime dependencies resolve
# to libraries staged next to the host. It does not launch the game and is not
# gameplay validation.
#
# Architecture: the expected architecture comes from --arch / FIFA_ARCH when the
# caller knows it, otherwise the host architecture is detected reliably (Apple
# Silicon is detected even from a Rosetta x86_64 shell). It is never silently
# inferred in a way that would "pass" a binary built for the wrong target.
#
# Usage: scripts/verify-macos-artifacts.sh [--arch ARCH] [output-dir]
#        (default output-dir: ${FIFA_BUILD_ROOT:-<repo>/build/macos}/out)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
OUT=""
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
      if [[ -z "${OUT}" ]]; then OUT="$1"; shift; else echo "Unexpected argument: $1" >&2; exit 2; fi ;;
  esac
done
OUT="${OUT:-${BUILD_ROOT}/out}"

# Apple Silicon is reliably detectable even from a Rosetta (x86_64) shell, where
# `uname -m` reports the translated arch and would silently accept a mismatch.
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

[[ -d "${OUT}" ]] || { echo "output directory not found: ${OUT}" >&2; exit 2; }
cd "${OUT}"

echo "Verifying ${OUT}"
echo "Expected arch: ${ARCH} (host: ${HOST_ARCH})"
echo

REQUIRED=(
  fifastreet
  libfifastreet_fifadllzf_xex.dylib
  libfifastreet_FootballCompEngzf_xex.dylib
  librexgpu-xenos.dylib
)
for name in "${REQUIRED[@]}"; do
  [[ -f "${name}" ]] && ok "present: ${name}" || bad "missing: ${name}"
done
[[ -d vulkan ]] && ok "present: vulkan/ (loader + MoltenVK + ICD)" \
  || bad "missing: vulkan/"
echo

# Every shipped Mach-O must contain the expected architecture and have no
# absolute Homebrew dependency (the host uses an @executable_path rpath). This
# covers the host, the staged dylibs and the bundled Vulkan loader/MoltenVK, so
# a cross-arch or half-staged bundle cannot pass.
abs_dep_check() {
  local bin="$1" dep
  while IFS= read -r dep; do
    case "${dep}" in
      /opt/homebrew/*|/usr/local/*) bad "${bin}: absolute dependency ${dep}" ;;
    esac
  done < <(otool -L "${bin}" 2>/dev/null | tail -n +2 | awk '{print $1}')
}
arch_check() {
  local bin="$1" archs
  archs="$(lipo -archs "${bin}" 2>/dev/null || true)"
  if [[ " ${archs} " == *" ${ARCH} "* ]]; then
    ok "${bin}: Mach-O ${archs}"
  else
    bad "${bin}: expected ${ARCH}, got '${archs}'"
  fi
  abs_dep_check "${bin}"
}
shopt -s nullglob
macho=()
for bin in fifastreet ./*.dylib "${OUT}"/vulkan/lib/*.dylib; do
  [[ -f "${bin}" ]] || continue
  bin="${bin#${OUT}/}"
  macho+=( "${bin#./}" )
done
shopt -u nullglob
for bin in "${macho[@]}"; do
  arch_check "${bin}"
done
echo

# The host must carry an @executable_path rpath so the staged dylibs resolve.
if otool -l fifastreet | grep -A2 LC_RPATH | grep -q "@executable_path"; then
  ok "fifastreet: @executable_path rpath present"
else
  bad "fifastreet: @executable_path rpath missing"
fi
echo

# The staged runtime and GPU plugin must match the linker's canonical output, not
# the stale host-folder POST_BUILD copies that a targeted `--target rexruntime` /
# `--target rexgpu-xenos` build leaves behind (see docs/BUILDING-MACOS.md,
# "Updating the runtime"). The paths are derived from the build root and the arch
# preset, so they can never pick a stale or wrong-arch library from another
# preset.
CANONICAL_DIR="${BUILD_ROOT}/work/FifaStreetRex/out/build/${PRESET_GAME}/runtime"
check_canonical() {
  local name="$1" canonical="$2"
  if [[ ! -f "${canonical}" ]]; then
    note "canonical ${name} not found at ${canonical}; skipping match"
    return
  fi
  if cmp -s "${canonical}" "./${name}"; then
    ok "${name} matches canonical ${canonical}"
  else
    bad "${name} differs from canonical ${canonical}"
  fi
}
check_canonical librexruntime.dylib \
  "${FIFA_CANONICAL_RUNTIME:-${CANONICAL_DIR}/librexruntime.dylib}"
check_canonical librexgpu-xenos.dylib \
  "${FIFA_CANONICAL_GPU:-${CANONICAL_DIR}/librexgpu-xenos.dylib}"
echo

# Recompiled guest modules must be loadable the way the runtime loader now
# resolves them: the registry carries a bare SDK target name, and the Apple
# path maps it to <executable folder>/lib<target>.dylib. Compile a throwaway
# harness for the target architecture that mirrors that mapping and confirm the
# module exports both registration entry points. This exercises the real shipped
# dylibs. A missing compiler or a harness that cannot run is a failure, not a
# silent pass.
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
  elif "${HARNESS_DIR}/dlopen_check" "$(pwd)" \
         fifastreet_fifadllzf_xex fifastreet_FootballCompEngzf_xex >"${HARNESS_DIR}/run.log" 2>&1; then
    ok "guest modules dlopen+symbols: lib<target>.dylib (register + image info)"
  else
    bad "guest module dlopen/symbol check failed for ${ARCH}:"
    sed 's/^/       /' "${HARNESS_DIR}/run.log"
    if [[ "${ARCH}" != "${HOST_ARCH}" ]]; then
      case "${ARCH}" in
        x86_64) note "an x86_64 target needs Rosetta 2 to run here: softwareupdate --install-rosetta" ;;
        arm64)  note "an arm64 target cannot run on an x86_64 host" ;;
      esac
    fi
  fi
else
  bad "clang not found at ${CLANG}; cannot validate recompiled-module loading (run: xcode-select --install)"
fi
echo

if [[ "${fail}" -ne 0 ]]; then
  echo "VERIFICATION FAILED"
  exit 1
fi
echo "VERIFICATION PASSED (compile-only; not gameplay validation)"
