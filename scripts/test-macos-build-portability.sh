#!/usr/bin/env bash
#
# test-macos-build-portability.sh - regression tests for the macOS build and
# verification scripts (scripts/build-macos.sh, verify-macos-artifacts.sh,
# verify-macos-app.sh).
#
# It needs no game data, no ReXGlue SDK and no build. Fixtures are temporary
# directories and, where a real Mach-O is not required, `lipo`/`otool` are
# replaced with mocks that read a per-file `.arch` / `.deps` sidecar. The one
# test that exercises the real dlopen path copies the already-built dylibs
# read-only from ${FIFA_TEST_LIBS_DIR:-build/macos/out} and is skipped when they
# are absent.
#
# Covers: malformed CLI preflight, the compiler floor, the always-on
# supported-revision guard (default rejection, the FIFA_SUPPORTED_INPUTS test
# seam accepting matching hashes, an altered hash being rejected, and installer
# manifest agreement/disagreement), the shared pure validator, architecture-
# mismatch detection, absolute-Homebrew-dependency detection, FIFA_BUILD_ROOT
# with spaces plus canonical runtime and GPU plugin resolution, the dangling
# GameData symlink diagnosis, and bash/Python syntax of every script.
#
# Usage: scripts/test-macos-build-portability.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD="${ROOT}/scripts/build-macos.sh"
VERIFY_ARTIFACTS="${ROOT}/scripts/verify-macos-artifacts.sh"
VERIFY_APP="${ROOT}/scripts/verify-macos-app.sh"
LIBS_DIR="${FIFA_TEST_LIBS_DIR:-${ROOT}/build/macos/out}"

PASSED=0
FAILED=0
ok()  { printf 'OK   %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Run a command (everything after "--"), assert its exit code and, when given, a
# literal output needle.
expect() {
  local label="$1" want="$2" needle="$3"; shift 3
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne "${want}" ]]; then
    bad "${label} (exit ${rc}, wanted ${want})"
    printf '%s\n' "${out}" | sed 's/^/       /'
    return
  fi
  if [[ -n "${needle}" ]] && ! grep -qF -- "${needle}" <<<"${out}"; then
    bad "${label} (missing output: ${needle})"
    printf '%s\n' "${out}" | sed 's/^/       /'
    return
  fi
  ok "${label}"
}

# Assert an output needle but ignore the exit code, for cases where a real
# dlopen may legitimately fail for environment reasons.
expect_output() {
  local label="$1" needle="$2"; shift 2
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local out
  set +e
  out="$("$@" 2>&1)"
  set -e
  if grep -qF -- "${needle}" <<<"${out}"; then
    ok "${label}"
  else
    bad "${label} (missing output: ${needle})"
    printf '%s\n' "${out}" | sed 's/^/       /'
  fi
}

# --- script syntax -----------------------------------------------------------
echo "== script syntax =="
for f in "${ROOT}"/scripts/*.sh; do
  if bash -n "$f" 2>"${TMP}/syn.err"; then
    ok "bash -n $(basename "$f")"
  else
    bad "bash -n $(basename "$f")"
    sed 's/^/       /' "${TMP}/syn.err"
  fi
done
for f in "${ROOT}"/scripts/*.py; do
  if python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f" 2>"${TMP}/py.err"; then
    ok "python compile $(basename "$f")"
  else
    bad "python compile $(basename "$f")"
    sed 's/^/       /' "${TMP}/py.err"
  fi
done

# --- build-macos.sh argument + compiler preflight ----------------------------
echo "== build-macos.sh CLI preflight =="
expect "jobs 0 rejected"        2 "positive integer"    -- "${BUILD}" --jobs 0
expect "jobs abc rejected"      2 "positive integer"    -- "${BUILD}" --jobs abc
expect "jobs missing value"     2 "--jobs requires"     -- "${BUILD}" --jobs
expect "arch sparc rejected"    2 "Unsupported --arch"  -- "${BUILD}" --arch sparc
expect "arch missing value"     2 "--arch requires"     -- "${BUILD}" --arch
expect "gamedata missing value" 2 "--gamedata requires" -- "${BUILD}" --gamedata
expect "unknown option"         2 "Unknown option"      -- "${BUILD}" --nope

MOCKBIN="${TMP}/mock-bin"
mkdir -p "${MOCKBIN}"
cat > "${MOCKBIN}/clang-old" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version)     echo "Apple clang version 15.0.0 (clang-1500.0.0.0)"; exit 0 ;;
  -dumpversion)  echo "15.0.0"; exit 0 ;;
esac
exit 0
SH
chmod +x "${MOCKBIN}/clang-old"

GD="${TMP}/GameData"
mkdir -p "${GD}/dlc/dlc_FootballCompEng/dlc/FootballCompEng"
printf 'XEX2%s' "default" > "${GD}/default.xex"
printf 'XEX2%s' "fifadll" > "${GD}/fifadllzf.xex.dll"
printf 'XEX2%s' "compeng" > "${GD}/dlc/dlc_FootballCompEng/dlc/FootballCompEng/FootballCompEngzf.xex.dll"

expect "compiler below the SDK floor rejected" 1 "too old" -- \
  env FIFA_CLANG="${MOCKBIN}/clang-old" FIFA_CLANGXX="${MOCKBIN}/clang-old" \
      FIFA_BUILD_ROOT="${TMP}/root-compiler" \
      "${BUILD}" --gamedata "${GD}" --check-only

# --- module presence / exact-version preflight -------------------------------
echo "== build-macos.sh module preflight =="
GD_MISSING="${TMP}/GameDataMissing"
mkdir -p "${GD_MISSING}"
printf 'XEX2%s' "default" > "${GD_MISSING}/default.xex"
printf 'XEX2%s' "fifadll" > "${GD_MISSING}/fifadllzf.xex.dll"
expect "missing required module rejected" 1 "missing required original module" -- \
  env FIFA_BUILD_ROOT="${TMP}/root-missing" "${BUILD}" --gamedata "${GD_MISSING}" --check-only

GD_BAD="${TMP}/GameDataBad"
cp -R "${GD}" "${GD_BAD}"
printf 'NOPE%s' "notxex" > "${GD_BAD}/fifadllzf.xex.dll"
expect "non-XEX2 module rejected" 1 "not an XEX2 module" -- \
  env FIFA_BUILD_ROOT="${TMP}/root-bad" "${BUILD}" --gamedata "${GD_BAD}" --check-only

# --- supported-revision guard ------------------------------------------------
# The default guard must reject anything that is not the source-controlled
# supported revision, before any download/codegen/build. The fixtures are tiny
# fake modules, so they never match the shipped hashes. A fixture spec supplied
# through the FIFA_SUPPORTED_INPUTS test seam exercises the accept path without
# copying the real ~28 MB modules.
echo "== supported-revision guard =="
GUARD_ROOT="${TMP}/root-guard-default"
expect "default guard rejects non-supported GameData" 1 "not the supported" -- \
  env FIFA_BUILD_ROOT="${GUARD_ROOT}" "${BUILD}" --gamedata "${GD}" --check-only
# Fail-early: the guard runs in preflight, so no workspace was created.
[[ ! -e "${GUARD_ROOT}/work" ]] \
  && ok "guard fails before download/codegen/build" \
  || bad "guard did not fail early (${GUARD_ROOT}/work exists)"

# --- shared pure validator + FIFA_SUPPORTED_INPUTS test seam -----------------
echo "== verify-supported-inputs.py =="
VERIFY_SUPPORTED="${ROOT}/scripts/verify-supported-inputs.py"
SPEC="${TMP}/supported.json"
python3 - "${GD}" "${SPEC}" <<'PY'
import hashlib, json, os, sys
gd, out = sys.argv[1], sys.argv[2]
rels = [
    "default.xex",
    "fifadllzf.xex.dll",
    "dlc/dlc_FootballCompEng/dlc/FootballCompEng/FootballCompEngzf.xex.dll",
]
modules = {r: hashlib.sha256(open(os.path.join(gd, r), "rb").read()).hexdigest() for r in rels}
json.dump({"schema": "restreet-macos-supported-inputs/1", "modules": modules}, open(out, "w"))
PY
GD_ALT="${TMP}/GameDataAltered"
cp -R "${GD}" "${GD_ALT}"
printf 'X' >> "${GD_ALT}/default.xex"
printf '{"modules": {"default.xex": "nothex"}}' > "${TMP}/bad-spec.json"

expect "validator accepts the supported fixture" 0 "match the supported revision" -- \
  python3 "${VERIFY_SUPPORTED}" --spec "${SPEC}" --gamedata "${GD}"
expect "validator rejects an altered module" 1 "SHA-256 mismatch" -- \
  python3 "${VERIFY_SUPPORTED}" --spec "${SPEC}" --gamedata "${GD_ALT}"
expect "validator rejects a malformed spec" 2 "invalid SHA-256" -- \
  python3 "${VERIFY_SUPPORTED}" --spec "${TMP}/bad-spec.json" --gamedata "${GD}"

expect "supported hashes accepted (override seam)" 0 "match the supported revision" -- \
  env FIFA_BUILD_ROOT="${TMP}/root-guard-ok" FIFA_SUPPORTED_INPUTS="${SPEC}" \
      "${BUILD}" --gamedata "${GD}" --check-only
expect "altered module hash rejected before build" 1 "SHA-256 mismatch" -- \
  env FIFA_BUILD_ROOT="${TMP}/root-guard-bad" FIFA_SUPPORTED_INPUTS="${SPEC}" \
      "${BUILD}" --gamedata "${GD_ALT}" --check-only

# Installer manifest compatibility: a manifest describing the supported revision
# passes; one describing a different revision is rejected rather than silently
# authorizing a build with the fixed hooks.
MAN="${TMP}/precompiled.json"
python3 - "${SPEC}" "${MAN}" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
json.dump({"Inputs": spec["modules"]}, open(sys.argv[2], "w"))
PY
BADMAN="${TMP}/precompiled-bad.json"
python3 - "${MAN}" "${BADMAN}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["Inputs"]["default.xex"] = "0" * 64
json.dump(data, open(sys.argv[2], "w"))
PY
expect "installer manifest agreeing with supported revision accepted" 0 \
  "describes the same revision" -- \
  env FIFA_BUILD_ROOT="${TMP}/root-man-ok" FIFA_SUPPORTED_INPUTS="${SPEC}" \
      FIFA_INSTALLER_MANIFEST="${MAN}" "${BUILD}" --gamedata "${GD}" --check-only
expect "installer manifest for another revision rejected" 1 "not the supported" -- \
  env FIFA_BUILD_ROOT="${TMP}/root-man-bad" FIFA_SUPPORTED_INPUTS="${SPEC}" \
      FIFA_INSTALLER_MANIFEST="${BADMAN}" "${BUILD}" --gamedata "${GD}" --check-only
expect "validator rejects a foreign manifest" 1 "not the supported" -- \
  python3 "${VERIFY_SUPPORTED}" --spec "${SPEC}" --gamedata "${GD}" --manifest "${BADMAN}"

# The shipped spec must stay well-formed: three modules, lowercase SHA-256.
if python3 - "${ROOT}/scripts/supported-macos-inputs.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
mods = data["modules"]
assert len(mods) == 3, mods
for rel, digest in mods.items():
    assert isinstance(digest, str) and len(digest) == 64, (rel, digest)
    assert all(c in "0123456789abcdef" for c in digest), (rel, digest)
PY
then ok "shipped supported-input spec: three lowercase 64-hex module hashes"
else bad "shipped supported-input spec is malformed"
fi

# --- verifier arch / dependency detection with mock lipo/otool ---------------
echo "== verifier arch + dependency detection (mock lipo/otool) =="
cat > "${MOCKBIN}/lipo" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-archs" && -n "${2:-}" && -f "${2}.arch" ]]; then
  cat "${2}.arch"; exit 0
fi
exec /usr/bin/lipo "$@"
SH
cat > "${MOCKBIN}/otool" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-L" && -n "${2:-}" && -f "${2}.deps" ]]; then
  printf '%s:\n' "$2"; cat "${2}.deps"; exit 0
fi
exec /usr/bin/otool "$@"
SH
chmod +x "${MOCKBIN}/lipo" "${MOCKBIN}/otool"

FX="${TMP}/fx"
mkdir -p "${FX}/vulkan/lib"
for f in fifastreet libfifastreet_fifadllzf_xex.dylib \
         libfifastreet_FootballCompEngzf_xex.dylib librexgpu-xenos.dylib \
         vulkan/lib/libvulkan.1.dylib; do
  : > "${FX}/${f}"
  printf 'arm64' > "${FX}/${f}.arch"
done

expect "architecture mismatch detected" 1 "expected x86_64, got 'arm64'" -- \
  env PATH="${MOCKBIN}:${PATH}" FIFA_ARCH= \
      "${VERIFY_ARTIFACTS}" --arch x86_64 "${FX}"

for f in fifastreet libfifastreet_fifadllzf_xex.dylib \
         libfifastreet_FootballCompEngzf_xex.dylib librexgpu-xenos.dylib \
         vulkan/lib/libvulkan.1.dylib; do
  printf '\t/opt/homebrew/lib/libbad.dylib (compatibility version 1.0.0, current version 1.0.0)\n' \
    > "${FX}/${f}.deps"
done
expect "absolute Homebrew dependency detected" 1 "absolute dependency" -- \
  env PATH="${MOCKBIN}:${PATH}" "${VERIFY_ARTIFACTS}" --arch arm64 "${FX}"

# --- FIFA_BUILD_ROOT with spaces + canonical runtime (real dylibs) -----------
echo "== FIFA_BUILD_ROOT with spaces + canonical runtime =="
if [[ -d "${LIBS_DIR}" && -f "${LIBS_DIR}/librexruntime.dylib" ]]; then
  SPACE_ROOT="${TMP}/root with spaces"
  SOUT="${SPACE_ROOT}/out"
  mkdir -p "${SOUT}"
  cp "${LIBS_DIR}/fifastreet" "${SOUT}/"
  cp "${LIBS_DIR}"/*.dylib "${SOUT}/"
  cp -R "${LIBS_DIR}/vulkan" "${SOUT}/vulkan"
  CANON_DIR="${SPACE_ROOT}/work/FifaStreetRex/out/build/mac-arm64-release/runtime"
  mkdir -p "${CANON_DIR}"
  cp "${LIBS_DIR}/librexruntime.dylib" "${CANON_DIR}/librexruntime.dylib"
  cp "${LIBS_DIR}/librexgpu-xenos.dylib" "${CANON_DIR}/librexgpu-xenos.dylib"
  expect_output "FIFA_BUILD_ROOT with spaces resolves the canonical runtime" \
    "librexruntime.dylib matches canonical" -- \
    env FIFA_BUILD_ROOT="${SPACE_ROOT}" DYLD_FALLBACK_LIBRARY_PATH="${SOUT}" \
        "${VERIFY_ARTIFACTS}"
  expect_output "FIFA_BUILD_ROOT with spaces resolves the canonical GPU plugin" \
    "librexgpu-xenos.dylib matches canonical" -- \
    env FIFA_BUILD_ROOT="${SPACE_ROOT}" DYLD_FALLBACK_LIBRARY_PATH="${SOUT}" \
        "${VERIFY_ARTIFACTS}"
else
  echo "SKIP FIFA_BUILD_ROOT/canonical test: no built dylibs at ${LIBS_DIR}"
fi

# --- dangling GameData symlink ----------------------------------------------
echo "== bundle GameData symlink =="
APP="${TMP}/FIFA Street.app"
AMAC="${APP}/Contents/MacOS"
mkdir -p "${AMAC}"
if [[ -d "${LIBS_DIR}" ]]; then
  cp "${LIBS_DIR}/fifastreet" "${AMAC}/"
  cp "${LIBS_DIR}"/*.dylib "${AMAC}/"
  cp -R "${LIBS_DIR}/vulkan" "${AMAC}/vulkan"
  cp "${LIBS_DIR}/fifastreet.toml" "${AMAC}/"
fi
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>fifastreet</string>
<key>CFBundleIdentifier</key><string>org.restreet.fifastreet.test</string>
<key>CFBundleName</key><string>FIFA Street</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
ln -s "${TMP}/does-not-exist-game-data" "${AMAC}/GameData"
expect "dangling GameData symlink reported" 1 "dangling symlink" -- \
  "${VERIFY_APP}" "${APP}"

# --- summary -----------------------------------------------------------------
echo
echo "=============================================================="
printf ' portability tests: %d passed, %d failed\n' "${PASSED}" "${FAILED}"
echo "=============================================================="
[[ "${FAILED}" -eq 0 ]] || exit 1
echo "ALL PORTABILITY TESTS PASSED"
