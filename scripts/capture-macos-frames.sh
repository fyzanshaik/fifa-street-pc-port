#!/usr/bin/env bash
#
# capture-macos-frames.sh - launch "FIFA Street.app" with the opt-in guest-frame
# capture enabled, then turn the captured PPMs into PNGs.
#
# The app reads RESTREET_CAPTURE_DIR and reads the guest output image in-process
# through Presenter::CaptureGuestOutput (see Installer/recomp-template/src/
# guest_frame_capture.{h,cpp}). No OS screen capture, accessibility automation or
# window-server permission is used. The run is bounded: only the process this
# script started is stopped and reaped, and a diagnostic sample is taken only if
# it ignores SIGTERM.
#
# Usage: scripts/capture-macos-frames.sh [--duration SEC] [--out DIR]
#        [--gamedata PATH] [--app PATH]
#        Defaults: --duration 80 (clamped to 70..85)
#                  --out      build/macos/logs/renderer-capture
#                  --gamedata private/mac-build/extract/FIFA Street/GameData
#                  --app      build/macos/out/FIFA Street.app/Contents/MacOS/fifastreet
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
APP="${BUILD_ROOT}/out/FIFA Street.app/Contents/MacOS/fifastreet"
GAMEDATA="${FIFA_GAMEDATA:-${ROOT}/private/mac-build/extract/FIFA Street/GameData}"
OUT="${BUILD_ROOT}/logs/renderer-capture"
DURATION=80

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)       [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--app requires a path" >&2; exit 2; }; APP="$2"; shift 2 ;;
    --gamedata)  [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--gamedata requires a path" >&2; exit 2; }; GAMEDATA="$2"; shift 2 ;;
    --out)       [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--out requires a path" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    --duration)  [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--duration requires a number" >&2; exit 2; }; DURATION="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "${DURATION}" =~ ^[0-9]+$ ]] \
  || { echo "duration must be an integer (got ${DURATION})" >&2; exit 2; }
if [[ "${DURATION}" -lt 70 || "${DURATION}" -gt 85 ]]; then
  echo "duration must be within 70..85 seconds (got ${DURATION})" >&2
  exit 2
fi
[[ -x "${APP}" ]] || { echo "executable not found: ${APP}" >&2; exit 2; }
[[ -f "${GAMEDATA}/default.xex" ]] || { echo "game data not found: ${GAMEDATA}" >&2; exit 2; }

mkdir -p "${OUT}"
FRAMES="${OUT}/frames"
rm -rf "${FRAMES}"
mkdir -p "${FRAMES}"

PID=""
stop_started() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill -TERM "${PID}" 2>/dev/null || true
  fi
}
trap stop_started EXIT INT TERM

echo ">>> launching ${APP}"
echo "    capture dir: ${FRAMES}"
RESTREET_CAPTURE_DIR="${FRAMES}" "${APP}" \
  --game_data_root="${GAMEDATA}" \
  --log_file="${OUT}/fifastreet.log" \
  --log_max_file_size_mb=8 --log_max_files=1 \
  > "${OUT}/stdout.log" 2>&1 &
PID=$!

deadline=$(( $(date +%s) + DURATION ))
while kill -0 "${PID}" 2>/dev/null; do
  [[ $(date +%s) -ge ${deadline} ]] && break
  sleep 1
done

if kill -0 "${PID}" 2>/dev/null; then
  echo ">>> ${DURATION}s elapsed; sending SIGTERM to pid ${PID}"
  kill -TERM "${PID}" 2>/dev/null || true
  for _ in $(seq 1 10); do
    kill -0 "${PID}" 2>/dev/null || break
    sleep 0.5
  done
fi

if kill -0 "${PID}" 2>/dev/null; then
  echo ">>> pid ${PID} ignored SIGTERM; sampling it before SIGKILL"
  sample "${PID}" 3 -file "${OUT}/stuck-sample.txt" >/dev/null 2>&1 || true
  kill -KILL "${PID}" 2>/dev/null || true
fi

wait "${PID}" 2>/dev/null || true
PID=""
trap - EXIT INT TERM
if pgrep -f "${APP}" >/dev/null 2>&1; then
  echo ">>> WARNING: a process matching ${APP} is still alive" >&2
else
  echo ">>> process stopped and reaped; no leftover match"
fi

shopt -s nullglob
ppms=( "${FRAMES}"/*.ppm )
if [[ ${#ppms[@]} -eq 0 ]]; then
  echo ">>> no PPM frames were written (see ${FRAMES}/capture-metadata.txt)"
else
  echo ">>> converting ${#ppms[@]} PPM frame(s) to PNG with sips"
  for ppm in "${ppms[@]}"; do
    sips -s format png "${ppm}" --out "${ppm%.ppm}.png" >/dev/null 2>&1 \
      || echo ">>> PNG conversion failed for ${ppm}" >&2
  done
  pngs=( "${FRAMES}"/*.png )
  echo ">>> PNG frames:"
  printf '    %s\n' "${pngs[@]}"
fi

if [[ -f "${FRAMES}/capture-metadata.txt" ]]; then
  echo ""
  echo ">>> capture-metadata.txt"
  cat "${FRAMES}/capture-metadata.txt"
fi
