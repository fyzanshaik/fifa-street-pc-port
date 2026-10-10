#!/usr/bin/env bash
#
# test-macos-input-diagnostics.sh - focused regression tests for the macOS
# keyboard-to-guest input chain and for the opt-in input diagnostics gate.
#
# Builds and runs scripts/input-keybinds-test.cpp, which links a real
# librexruntime.dylib and reads the *real* default controller keybind strings
# from the exported REXCVAR_DEFINE_STRING storages. It verifies that every
# default bind token is a known key and that the SDL scancode for that token
# translates to the same VirtualKey - the exact chain the MnK driver walks.
# It also asserts the RESTREET_INPUT_DIAG gate is inert when unset.
#
# This test covers the optional input-diagnostics path only; the default build
# is complete without it and does not depend on the diagnostics header. That
# header (rex/input/input_diagnostics.h) belongs to a diagnostic-only fourth
# patch the default SDK stack never applies, so the test extracts it from
# patches/rexglue-macos-input-diagnostics.patch into a throwaway directory and
# puts that directory first on the include path. Nothing under ReXGlue/ is
# touched. The runtime it links is the isolated input-diagnostics stage
# (build/macos/input-diagnostics/out) - the artifact actually built with the
# instrumentation. A checkout that has not built that optional app has no such
# runtime, and this script reports exactly that rather than silently falling
# back to the default runtime.
#
# No game launch, window, GPU or guest. Compile + run only.
#
# Usage: scripts/test-macos-input-diagnostics.sh [runtime-dir]
#   runtime-dir  directory containing librexruntime.dylib
#                (default: build/macos/input-diagnostics/out - the isolated
#                          input-diagnostics build)
#
# Env: FIFA_INPUT_DIAG_RUNTIME  same as the runtime-dir argument
#      FIFA_INPUT_DIAG_OUT      output dir (default build/macos/input-diagnostics/test)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUNTIME_DIR="${1:-${FIFA_INPUT_DIAG_RUNTIME:-${ROOT}/build/macos/input-diagnostics/out}}"
OUT_DIR="${FIFA_INPUT_DIAG_OUT:-${ROOT}/build/macos/input-diagnostics/test}"
DYLIB="${RUNTIME_DIR}/librexruntime.dylib"

PASSED=0
FAILED=0
ok()  { printf 'OK   %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

if [[ ! -f "${DYLIB}" ]]; then
  cat >&2 <<EOF
ERROR: input-diagnostics artifact unavailable: ${DYLIB}
       This test exercises the optional input-diagnostics build, which this
       checkout has not produced. Build it first (it applies the diagnostic-only
       fourth patch), for example:

         FIFA_BUILD_ROOT=${ROOT}/build/macos/input-diagnostics \\
           scripts/build-macos.sh

       or pass a runtime-dir argument pointing at a librexruntime.dylib built
       with patches/rexglue-macos-input-diagnostics.patch. The default SDK and
       the default build do not carry the instrumentation.
EOF
  exit 2
fi

# Materialise the diagnostic-only header from its patch without mutating the
# root SDK checkout or copying the SDK (or its submodules). The header is a new
# file in the patch, so extracting just that path reproduces it byte-for-byte.
DIAG_PATCH="${ROOT}/patches/rexglue-macos-input-diagnostics.patch"
[[ -f "${DIAG_PATCH}" ]] || { echo "ERROR: missing patch: ${DIAG_PATCH}" >&2; exit 2; }
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fifa-input-diag.XXXXXX")"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT
DIAG_INC="${TMP_DIR}/include"
mkdir -p "${DIAG_INC}"
if ! ( cd "${TMP_DIR}" \
        && git apply --include='include/rex/input/input_diagnostics.h' "${DIAG_PATCH}" ); then
  echo "ERROR: could not extract rex/input/input_diagnostics.h from ${DIAG_PATCH}" >&2
  exit 2
fi
[[ -f "${DIAG_INC}/rex/input/input_diagnostics.h" ]] \
  || { echo "ERROR: diagnostics header missing after extraction" >&2; exit 2; }

mkdir -p "${OUT_DIR}"
BIN="${OUT_DIR}/input-keybinds-test"

SDL_INC="${ROOT}/ReXGlue/thirdparty/sdl3/include"
SDK_INC="${ROOT}/ReXGlue/include"
SPDLOG_INC="${ROOT}/ReXGlue/thirdparty/spdlog/include"
FMT_INC="${ROOT}/ReXGlue/thirdparty/fmt/include"

echo "== building input-keybinds-test =="
# DIAG_INC first: it holds only the one diagnostic-only header, so every other
# SDK header still resolves to the real (default) SDK the runtime was built from.
if clang++ -std=c++20 -fno-char8_t \
    -I "${DIAG_INC}" -I "${SDK_INC}" -I "${SDL_INC}" -I "${SPDLOG_INC}" -I "${FMT_INC}" \
    "${SCRIPT_DIR}/input-keybinds-test.cpp" \
    -L "${RUNTIME_DIR}" -lrexruntime \
    -Wl,-rpath,"${RUNTIME_DIR}" \
    -o "${BIN}" >"${OUT_DIR}/compile.log" 2>&1; then
  ok "compiled ${BIN}"
else
  bad "compile failed (see ${OUT_DIR}/compile.log)"
  sed 's/^/       /' "${OUT_DIR}/compile.log" | head -40
  exit 1
fi

echo ""
echo "== keybind -> scancode chain =="
if "${BIN}" >"${OUT_DIR}/keybinds.log" 2>&1; then
  ok "$(tail -n 1 "${OUT_DIR}/keybinds.log")"
else
  bad "chain test failed"
  sed 's/^/       /' "${OUT_DIR}/keybinds.log" | head -40
fi

echo ""
echo "== RESTREET_INPUT_DIAG gate =="
if env -u RESTREET_INPUT_DIAG "${BIN}" --diag-gate disabled >"${OUT_DIR}/gate-disabled.log" 2>&1; then
  ok "unset -> diagnostics inert"
else
  bad "unset -> diagnostics were active"
  sed 's/^/       /' "${OUT_DIR}/gate-disabled.log" | head -5
fi
if RESTREET_INPUT_DIAG=1 "${BIN}" --diag-gate enabled >"${OUT_DIR}/gate-enabled.log" 2>&1; then
  ok "RESTREET_INPUT_DIAG=1 -> diagnostics active"
else
  bad "RESTREET_INPUT_DIAG=1 -> diagnostics stayed off"
  sed 's/^/       /' "${OUT_DIR}/gate-enabled.log" | head -5
fi

echo ""
echo "== runtime emit (real logging path) =="
rm -f "${OUT_DIR}/emit-off.log" "${OUT_DIR}/emit-on.log"
env -u RESTREET_INPUT_DIAG "${BIN}" --emit-check "${OUT_DIR}/emit-off.log" >/dev/null 2>&1 || true
if ! grep -q "\[input-diag\]" "${OUT_DIR}/emit-off.log" 2>/dev/null; then
  ok "unset -> no [input-diag] line written"
else
  bad "unset -> a [input-diag] line was written"
fi

RESTREET_INPUT_DIAG=1 "${BIN}" --emit-check "${OUT_DIR}/emit-on.log" >/dev/null 2>&1 || true
if grep -q "\[input-diag\]" "${OUT_DIR}/emit-on.log" 2>/dev/null \
    && grep -q "a_hits=1" "${OUT_DIR}/emit-on.log" \
    && grep -q "u0_a=1" "${OUT_DIR}/emit-on.log"; then
  ok "$(grep -o '\[input-diag\].*' "${OUT_DIR}/emit-on.log" | head -1)"
else
  bad "RESTREET_INPUT_DIAG=1 -> no expected aggregated line"
  sed 's/^/       /' "${OUT_DIR}/emit-on.log" 2>/dev/null | head -5
fi

echo ""
echo "=============================================================="
printf ' input-diagnostics tests: %d passed, %d failed\n' "${PASSED}" "${FAILED}"
echo "=============================================================="
[[ "${FAILED}" -eq 0 ]] || exit 1
echo "ALL INPUT-DIAGNOSTICS TESTS PASSED"
