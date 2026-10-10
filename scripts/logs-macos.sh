#!/usr/bin/env bash
# Live follower for normal-play session logs. Start it before launching the game;
# it waits for the first session, then streams the newest session's fifastreet.log
# and switches automatically when a new session begins. Read-only: it never
# creates or modifies logs and never starts or stops the game. Ctrl+C stops only
# the watcher.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${FIFA_BUILD_ROOT:-${ROOT}/build/macos}"
LOG_ROOT="${BUILD_ROOT}/logs/play"
HELPER="${SCRIPT_DIR}/watch-macos-play-log.py"

usage() {
  cat <<EOF
Usage: scripts/logs-macos.sh [--session ID] [--lines N]

Follows normal-play session logs under \${FIFA_BUILD_ROOT:-<repo>/build/macos}/logs/play.
Prints the last N lines of the newest UTC session (YYYYMMDDTHHMMSSZ), then streams
appended lines. It switches to a newer session as soon as one appears, waits for a
session whose fifastreet.log is not created yet, and keeps reading through log
truncation and file replacement.

Start it before the game: it waits without creating or modifying anything.

Options:
  --session ID   Pin one session directory instead of following the newest.
                 ID is the UTC session name, e.g. 20261010T112440Z.
  --lines N      Initial history size for each session (default 20; 0 = live only).
  -h, --help     Show this help.

Environment:
  FIFA_BUILD_ROOT   Build root that contains logs/play (default: <repo>/build/macos).

Ctrl+C stops the watcher only; the game is never started or stopped.
EOF
}

SESSION=""
LINES=20
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --session)
      [[ $# -ge 2 && -n "$2" ]] || { echo "logs-macos.sh: --session needs a session ID" >&2; exit 2; }
      SESSION="$2"; shift 2 ;;
    --session=*)
      SESSION="${1#*=}"
      [[ -n "${SESSION}" ]] || { echo "logs-macos.sh: --session needs a session ID" >&2; exit 2; }
      shift ;;
    --lines)
      [[ $# -ge 2 && -n "$2" ]] || { echo "logs-macos.sh: --lines needs a value" >&2; exit 2; }
      LINES="$2"; shift 2 ;;
    --lines=*)
      LINES="${1#*=}"
      [[ -n "${LINES}" ]] || { echo "logs-macos.sh: --lines needs a value" >&2; exit 2; }
      shift ;;
    -*) echo "logs-macos.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "logs-macos.sh: unexpected extra argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "${LINES}" =~ ^[0-9]+$ ]] || { echo "logs-macos.sh: --lines must be a non-negative integer: ${LINES}" >&2; exit 2; }
if [[ -n "${SESSION}" && ! "${SESSION}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
  echo "logs-macos.sh: --session must look like YYYYMMDDTHHMMSSZ: ${SESSION}" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "logs-macos.sh: python3 is required" >&2; exit 1; }

ARGS=(--root "${LOG_ROOT}" --lines "${LINES}")
[[ -n "${SESSION}" ]] && ARGS+=(--session "${SESSION}")
exec python3 "${HELPER}" "${ARGS[@]}"
