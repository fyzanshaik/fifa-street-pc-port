#!/usr/bin/env bash
#
# test-macos-runtime-config.sh - fixture test for the shipped macOS runtime
# configuration and its build wiring, no game data or game build required.
#
# Covers:
#   - the stable-launch cvars are persisted in the runtime template, so a Finder
#     double-click and scripts/play-macos.sh read the same settings;
#   - build-macos.sh writes fifastreet.toml from that template plus the keyboard
#     profile, and stages the canonical GPU plugin like the runtime;
#   - the keyboard profile has exactly 25 non-empty bindings, no duplicate keys,
#     and the required controls (arrows move, Space = A/select-pass, Return =
#     Start);
#   - the merged file - exactly what the app loads - drives the real MnK driver
#     (reuses scripts/test-macos-keyboard-profile.sh) when a runtime is present.
#
# Usage: scripts/test-macos-runtime-config.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME="${ROOT}/config/macos/fifastreet-runtime.toml"
PROFILE="${ROOT}/config/macos/keyboard-arrows.toml"
BUILD="${ROOT}/scripts/build-macos.sh"
OUT="${ROOT}/build/macos/logs/runtime-config"
mkdir -p "${OUT}"

PASSED=0
FAILED=0
ok()  { printf 'OK   %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

echo "== runtime config fixture =="
[[ -f "${RUNTIME}" ]] && ok "runtime template present" || { bad "runtime template missing: ${RUNTIME}"; exit 1; }
[[ -f "${PROFILE}" ]] && ok "keyboard profile present" || { bad "keyboard profile missing: ${PROFILE}"; exit 1; }

# --- stable-launch cvars -----------------------------------------------------
for line in \
  'vulkan_macos_unpaced_present = true' \
  'macos_idle_toast_sleep = true' \
  'macos_idle_exit_overlay_sleep = true'
do
  if grep -qF -- "${line}" "${RUNTIME}"; then
    ok "stable cvar: ${line}"
  else
    bad "stable cvar missing from ${RUNTIME##*/}: ${line}"
  fi
done

# --- build wiring ------------------------------------------------------------
if grep -qF 'config/macos/fifastreet-runtime.toml' "${BUILD}"; then
  ok "build-macos.sh writes the runtime template"
else
  bad "build-macos.sh no longer references config/macos/fifastreet-runtime.toml"
fi
if grep -qF 'config/macos/keyboard-arrows.toml' "${BUILD}"; then
  ok "build-macos.sh appends the keyboard profile"
else
  bad "build-macos.sh no longer references config/macos/keyboard-arrows.toml"
fi
if grep -qF 'runtime/librexgpu-xenos.dylib' "${BUILD}"; then
  ok "build-macos.sh stages the canonical GPU plugin"
else
  bad "build-macos.sh does not stage runtime/librexgpu-xenos.dylib"
fi

# --- keyboard profile shape --------------------------------------------------
# "Bindings" counts comma-separated key tokens, so keybind_b = "D,Backspace"
# is two bindings and the empty keybind_guide is not one: 24 assignments, 25
# bindings, matching the profile and scripts/macos-keyboard-profile-test.cpp.
count="$(grep -oE '^[[:space:]]*keybind_[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*".+"' "${PROFILE}" \
  | sed -E 's/^[^"]*"//; s/"[[:space:]]*$//' | tr ',' '\n' | grep -c . || true)"
if [[ "${count}" -eq 25 ]]; then
  ok "profile has 25 key bindings across its assignments"
else
  bad "profile has ${count} key bindings (expected 25)"
fi

if grep -qE '^[[:space:]]*keybind_' "${RUNTIME}"; then
  bad "runtime template also defines keybind_* (would duplicate the profile)"
else
  ok "runtime template defines no keybind_* (no cross-file duplicates)"
fi

dupes="$(grep -oE 'keybind_[A-Za-z0-9_]+' "${PROFILE}" | sort | uniq -d || true)"
if [[ -z "${dupes}" ]]; then
  ok "profile has no duplicate keybind keys"
else
  bad "profile has duplicate keybind keys: ${dupes}"
fi

# The user-facing controls must stay the documented arrows + Space + Enter set;
# do not let an unsupported layout sneak in.
for line in \
  'keybind_lstick_up = "Up"' \
  'keybind_lstick_down = "Down"' \
  'keybind_lstick_left = "Left"' \
  'keybind_lstick_right = "Right"' \
  'keybind_a = "Space"' \
  'keybind_start = "Return"'
do
  if grep -qF -- "${line}" "${PROFILE}"; then
    ok "required control: ${line}"
  else
    bad "required control missing: ${line}"
  fi
done

# --- merged config drives the real MnK driver --------------------------------
MERGED="${OUT}/fifastreet.toml"
cat "${RUNTIME}" "${PROFILE}" > "${MERGED}"
LIBS="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}/out"
if [[ -f "${LIBS}/librexruntime.dylib" ]]; then
  if bash "${ROOT}/scripts/test-macos-keyboard-profile.sh" "${LIBS}" "${MERGED}" >"${OUT}/merged-mnk.log" 2>&1; then
    ok "merged config drives the real MnK driver: $(tail -n1 "${OUT}/merged-mnk.log")"
  else
    bad "merged config failed the MnK driver test (see ${OUT}/merged-mnk.log)"
    sed 's/^/       /' "${OUT}/merged-mnk.log"
  fi
else
  echo "SKIP merged MnK seam test: no ${LIBS}/librexruntime.dylib"
fi

echo
echo "=============================================================="
printf ' runtime-config tests: %d passed, %d failed\n' "${PASSED}" "${FAILED}"
echo "=============================================================="
[[ "${FAILED}" -eq 0 ]] || exit 1
echo "ALL RUNTIME-CONFIG TESTS PASSED"
