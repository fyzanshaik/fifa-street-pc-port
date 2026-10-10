#!/usr/bin/env bash
# Interactive normal-play session: no timer, no window automation, no diagnostic
# recorder. It launches the same bundle a double-click would, so the persisted
# fifastreet.toml (unpaced present, idle sleeps, keyboard profile) and the host's
# MoltenVK synchronous-submit default apply identically from the terminal and
# from Finder. Only this child has the diagnostic opt-ins cleared. Exit by
# closing the window or using Enter+D then Space.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
DEFAULT_APP="${BUILD_ROOT}/out/FIFA Street.app"

usage() {
  cat <<EOF
Usage: scripts/play-macos.sh [app-path]

Launches the built "FIFA Street.app" exactly as a double-click would, with the
diagnostic opt-ins cleared for this child only. Normal play is unbounded; no
timer is applied.

Arguments:
  app-path        Bundle to launch (default: ${DEFAULT_APP}); its GameData link
                  must already resolve.

Environment: FIFA_BUILD_ROOT
EOF
}

APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) APP="$1"; shift; break ;;
  esac
done
[[ $# -eq 0 ]] || { echo "Unexpected extra argument: $1" >&2; usage >&2; exit 2; }
APP="${APP:-${DEFAULT_APP}}"
BIN="${APP}/Contents/MacOS/fifastreet"
if [[ ! -f "${BIN}" ]]; then
  echo "App not found: ${APP}" >&2
  echo "Build it first: scripts/build-macos.sh --gamedata <path>/GameData" >&2
  exit 1
fi
MACOS_DIR="$(cd "${APP}/Contents/MacOS" && pwd)"
GAMEDATA="${MACOS_DIR}/GameData"
if [[ ! -f "${GAMEDATA}/default.xex" ]]; then
  echo "Bundle has no usable GameData: ${GAMEDATA}" >&2
  echo "Re-create it with: scripts/package-macos-app.sh --gamedata <path>/GameData" >&2
  exit 1
fi
GAMEDATA="$(cd "${GAMEDATA}" && pwd)"
APP_CONFIG="${MACOS_DIR}/fifastreet.toml"
if [[ -f "${APP_CONFIG}" ]] && ! grep -q 'vulkan_macos_unpaced_present' "${APP_CONFIG}"; then
  echo "WARN: ${APP_CONFIG} has no persisted macOS stable settings." >&2
  echo "      This bundle predates them; rebuild/package for the stable defaults." >&2
fi
if pgrep -x fifastreet >/dev/null; then echo "A game instance is already running." >&2; exit 1; fi
LOGS="${BUILD_ROOT}/logs/play/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${LOGS}"
echo "Logs: ${LOGS}/fifastreet.log"
echo "No time limit. Arrows = movement; Space = select/pass; Enter = Start."
cd "${MACOS_DIR}"
exec env -u RESTREET_PERF_DIAG -u RESTREET_INPUT_DIAG -u RESTREET_CAPTURE_DIR \
  ./fifastreet "--game_data_root=${GAMEDATA}" "--log_file=${LOGS}/fifastreet.log"
