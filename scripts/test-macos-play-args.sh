#!/usr/bin/env bash
#
# test-macos-play-args.sh - fixture test for scripts/play-macos.sh argument
# handling. Uses a fake bundle whose "fifastreet" is a /bin/sh shim, so the real
# game is never launched and no window/input automation is involved.
#
# Covers:
#   - --help prints usage and exits 0 without launching;
#   - a second positional argument is rejected before launching;
#   - the canonical default and the single positional app override still launch
#     the bundle's executable (no timer is added).
#
# Usage: scripts/test-macos-play-args.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLAY="${ROOT}/scripts/play-macos.sh"
RUNTIME="${ROOT}/config/macos/fifastreet-runtime.toml"

PASSED=0
FAILED=0
ok()  { printf 'OK   %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export FIFA_BUILD_ROOT="${TMP}/build"

mkdir -p "${TMP}/extract/GameData"
printf 'XEX2fake' > "${TMP}/extract/GameData/default.xex"

APP="${TMP}/FIFA Street.app"
MACOS="${APP}/Contents/MacOS"
mkdir -p "${MACOS}/vulkan"
RAN="${TMP}/ran"
printf '#!/bin/sh\ntouch "%s"\n' "${RAN}" > "${MACOS}/fifastreet"
chmod +x "${MACOS}/fifastreet"
cp "${RUNTIME}" "${MACOS}/fifastreet.toml"
ln -s "${TMP}/extract/GameData" "${MACOS}/GameData"

echo "== play-macos.sh arguments =="

# --help must be useful and must not launch.
help_ok=0
help_out=""
if help_out="$("${PLAY}" --help 2>&1)"; then help_ok=1; fi
if [[ "${help_ok}" == "1" ]]; then
  ok "--help exits 0"
else
  bad "--help exited nonzero: ${help_out}"
fi
case "${help_out}" in
  *Usage:*play-macos*) ok "--help prints usage" ;;
  *) bad "--help did not print usage" ;;
esac
[[ ! -e "${RAN}" ]] && ok "--help does not launch" || bad "--help launched the bundle"

# Extra positional arguments must be rejected before anything runs.
if "${PLAY}" "${APP}" extra >"${TMP}/extra.log" 2>&1; then
  bad "play-macos.sh accepted an extra argument"
else
  ok "play-macos.sh rejects an extra argument"
fi
[[ ! -e "${RAN}" ]] && ok "extra argument does not launch" || bad "extra argument launched the bundle"

# The canonical single-positional override still launches the shim.
if "${PLAY}" "${APP}" >"${TMP}/run.log" 2>&1; then
  ok "play-macos.sh launches a positional app path"
else
  bad "play-macos.sh failed on a positional app path"
  sed 's/^/       /' "${TMP}/run.log"
fi
[[ -e "${RAN}" ]] && ok "positional app path ran the executable" || bad "positional app path did not run"

echo
echo "=============================================================="
printf ' play-args tests: %d passed, %d failed\n' "${PASSED}" "${FAILED}"
echo "=============================================================="
[[ "${FAILED}" -eq 0 ]] || exit 1
echo "ALL PLAY-ARGS TESTS PASSED"
