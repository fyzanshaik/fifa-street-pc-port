#!/usr/bin/env bash
#
# probe-virtual-input.sh - bounded behavioral probe for the macOS virtual-
# gamepad bridge.
#
# Launches "FIFA Street.app" with the bridge enabled and the in-process frame
# capture enabled, sends one input pulse through the Python CLI after the title
# screen is up, and stops/reaps only the process it started. The captured frames
# are converted to PNG so the effect on the guest (if any) can be checked
# against the baselines in build/macos/logs/renderer-capture.summary.txt without
# looking at OS pixels.
#
# Usage: scripts/probe-virtual-input.sh [--mode ai-ai|human-ai] [--player N]
#        [--pulse BUTTON@SECONDS ...] [--duration SEC] [--out DIR]
#        Defaults: --mode ai-ai --player 0 --pulse Start@24
#                  --duration 90 (clamped 90..120) --out
#                  build/macos/logs/virtual-input/probe
#
# Each --pulse sends one button for 1 s through the CLI at the given elapsed
# time, so a Start->A sequence is `--pulse Start@24 --pulse A@42`. Kept to a
# couple of basic pulses: this probe never accepts a legal/EULA prompt or signs
# in, it only holds a button briefly and captures what the guest renders.
#
# The control socket always lives under an owner-only directory and is created
# 0600 by the driver.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
APP="${BUILD_ROOT}/out/FIFA Street.app/Contents/MacOS/fifastreet"
GAMEDATA="${FIFA_GAMEDATA:-${ROOT}/private/mac-build/extract/FIFA Street/GameData}"
MODE="ai-ai"
PLAYER=0
DURATION=90
OUT="${BUILD_ROOT}/logs/virtual-input/probe"
PULSES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)       [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--app requires a path" >&2; exit 2; }; APP="$2"; shift 2 ;;
    --gamedata)  [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--gamedata requires a path" >&2; exit 2; }; GAMEDATA="$2"; shift 2 ;;
    --mode)      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--mode requires a value" >&2; exit 2; }; MODE="$2"; shift 2 ;;
    --player)    [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--player requires a value" >&2; exit 2; }; PLAYER="$2"; shift 2 ;;
    --pulse)     [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--pulse requires BUTTON@SECONDS" >&2; exit 2; }; PULSES+=("$2"); shift 2 ;;
    --duration)  [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--duration requires a number" >&2; exit 2; }; DURATION="$2"; shift 2 ;;
    --out)       [[ $# -ge 2 && -n "${2:-}" ]] || { echo "--out requires a path" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ ${#PULSES[@]} -gt 0 ]] || PULSES=("Start@24")

if [[ "${MODE}" != "ai-ai" && "${MODE}" != "human-ai" ]]; then
  echo "mode must be ai-ai or human-ai (got ${MODE})" >&2
  exit 2
fi
[[ "${PLAYER}" =~ ^[01]$ ]] || { echo "player must be 0 or 1 (got ${PLAYER})" >&2; exit 2; }
[[ "${DURATION}" =~ ^[0-9]+$ ]] \
  || { echo "duration must be an integer (got ${DURATION})" >&2; exit 2; }
if [[ "${DURATION}" -lt 90 || "${DURATION}" -gt 120 ]]; then
  echo "duration must be within 90..120 seconds (got ${DURATION})" >&2
  exit 2
fi
[[ -x "${APP}" ]] || { echo "executable not found: ${APP}" >&2; exit 2; }
[[ -f "${GAMEDATA}/default.xex" ]] || { echo "game data not found: ${GAMEDATA}" >&2; exit 2; }
for pulse in "${PULSES[@]}"; do
  [[ "${pulse}" == *"@"* ]] || { echo "bad --pulse '${pulse}': expected BUTTON@SECONDS" >&2; exit 2; }
done

mkdir -p "${OUT}"
FRAMES="${OUT}/frames"
rm -rf "${FRAMES}"
mkdir -p "${FRAMES}"

# Owner-only directory for the control socket (macOS per-user TMPDIR is already
# 0700; the driver still creates/chmods a missing parent and the socket 0600).
SOCK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/restreet-eval.XXXXXX")"
chmod 700 "${SOCK_DIR}"
SOCK="${SOCK_DIR}/ctl.sock"

PID=""
cleanup() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill -TERM "${PID}" 2>/dev/null || true
    for _ in $(seq 1 10); do kill -0 "${PID}" 2>/dev/null || break; sleep 0.5; done
  fi
  if [[ -n "${PID}" ]]; then kill -0 "${PID}" 2>/dev/null && kill -KILL "${PID}" 2>/dev/null || true; fi
  [[ -n "${PID}" ]] && wait "${PID}" 2>/dev/null || true
  rm -rf "${SOCK_DIR}"
}
trap cleanup EXIT INT TERM

echo ">>> launching ${APP} (mode ${MODE}, socket ${SOCK})"
RESTREET_CONTROL_SOCKET="${SOCK}" \
RESTREET_CONTROL_MODE="${MODE}" \
RESTREET_CAPTURE_DIR="${FRAMES}" \
  "${APP}" \
  --game_data_root="${GAMEDATA}" \
  --log_file="${OUT}/fifastreet.log" \
  --log_max_file_size_mb=8 --log_max_files=1 \
  > "${OUT}/stdout.log" 2>&1 &
PID=$!

echo ">>> waiting for the first pulse"
start=$(date +%s)
: > "${OUT}/cli.txt"
for pulse in "${PULSES[@]}"; do
  button="${pulse%@*}"
  at="${pulse#*@}"
  while kill -0 "${PID}" 2>/dev/null; do
    [[ $(( $(date +%s) - start )) -ge ${at} ]] && break
    sleep 1
  done
  kill -0 "${PID}" 2>/dev/null || break
  echo ">>> sending ${button} pulse to player ${PLAYER} at ~$(( $(date +%s) - start ))s"
  "${SCRIPT_DIR}/gamepad-macos.py" --socket "${SOCK}" press --player "${PLAYER}" \
    --button "${button}" --hold 1.0 2>&1 | tee -a "${OUT}/cli.txt" || true
done

deadline=$(( start + DURATION ))
while kill -0 "${PID}" 2>/dev/null; do
  [[ $(date +%s) -ge ${deadline} ]] && break
  sleep 1
done

if kill -0 "${PID}" 2>/dev/null; then
  echo ">>> ${DURATION}s elapsed; sending SIGTERM to pid ${PID}"
  kill -TERM "${PID}" 2>/dev/null || true
  for _ in $(seq 1 10); do kill -0 "${PID}" 2>/dev/null || break; sleep 0.5; done
fi
if kill -0 "${PID}" 2>/dev/null; then
  sample "${PID}" 3 -file "${OUT}/stuck-sample.txt" >/dev/null 2>&1 || true
  kill -KILL "${PID}" 2>/dev/null || true
fi
wait "${PID}" 2>/dev/null || true
PID=""
rm -rf "${SOCK_DIR}"
trap - EXIT INT TERM

if pgrep -f "${APP}" >/dev/null 2>&1; then
  echo ">>> WARNING: a process matching ${APP} is still alive" >&2
else
  echo ">>> process stopped and reaped; no leftover match"
fi

shopt -s nullglob
ppms=( "${FRAMES}"/*.ppm )
for ppm in "${ppms[@]}"; do
  sips -s format png "${ppm}" --out "${ppm%.ppm}.png" >/dev/null 2>&1 || true
done
shopt -u nullglob

echo ""
echo ">>> capture-metadata.txt"
cat "${FRAMES}/capture-metadata.txt" 2>/dev/null || echo "(none)"
echo ""
echo ">>> bridge log lines"
grep -i "virtual gamepad bridge" "${OUT}/fifastreet.log" 2>/dev/null || echo "(none)"
