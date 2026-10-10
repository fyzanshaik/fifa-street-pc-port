#!/usr/bin/env bash
# Bounded repro for the macOS guest null-access fault.
#
# Primary bug: a guest thread dereferences a NULL pointer (object member at
# +0x4C/+0x50 in sub_82050928) and reads guest 0x00000004.
# - On the pre-fix runtime the unhandled fault spun forever: the POSIX
#   exception handler returned to the faulting instruction, so the log rotated
#   at ~24 MB/s while the thread re-faulted. Signature:
#       Unhandled guest access violation: read of guest 0x00000004 ...
# - On the fixed runtime the fault terminates the process (Windows parity), so
#   the same bug surfaces as an abnormal signal exit instead of a storm.
#
# This harness launches the build, watches a single fixed log file for the
# fault string, freezes+captures on the FIRST occurrence, and otherwise reports
# an abnormal (signal) self-exit as a crash. The log is capped hard so a storm
# can never write ~100 MB before we stop it.
#
# Exit codes per run:  0 = clean/no fault, 2 = fault storm (pre-fix), 3 = crash
# (signal exit; the fault on the fixed runtime), 1 = harness error.
# With RUNS>1 the script aggregates and exits non-zero if any run was 2 or 3.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$ROOT/build/macos/run"
GAMEDATA="${1:-$ROOT/private/mac-build/extract/FIFA Street/GameData}"
OUT_DIR="${2:-$ROOT/build/macos/logs/repro-null-fault}"
MAX_WAIT="${MAX_WAIT:-90}"
RUNS="${RUNS:-1}"

case "$OUT_DIR" in /*) ;; *) OUT_DIR="$ROOT/$OUT_DIR" ;; esac

BIN="$RUN_DIR/fifastreet"
FAULT_RE='Unhandled guest access violation: read of guest 0x00000004'

log() { printf '[repro] %s\n' "$*"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

[[ -x "$BIN" ]] || { echo "missing executable: $BIN" >&2; exit 1; }
[[ -d "$GAMEDATA" ]] || { echo "missing game data root: $GAMEDATA" >&2; exit 1; }

run_once() {
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"
  export REX_LOG_FILE="$dir/game.log"
  export REX_LOG_MAX_FILE_SIZE_MB=1
  export REX_LOG_MAX_FILES=1

  cd "$RUN_DIR" || return 1
  "$BIN" --game_data_root="$GAMEDATA" > "$dir/stdout.log" 2>&1 &
  local pid=$!
  local t0; t0=$(now)
  local fault_file="" self_exit=0 exit_code="" elapsed

  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null; exit_code=$?; self_exit=1
      break
    fi
    for f in "$dir/game.log" "$dir/stdout.log"; do
      if grep -qF "$FAULT_RE" "$f" 2>/dev/null; then fault_file="$f"; break 2; fi
    done
    elapsed=$(perl -MTime::HiRes=time -e "printf '%.3f', time-$t0")
    if (( $(echo "$elapsed >= $MAX_WAIT" | bc) )); then break; fi
    sleep 0.1
  done
  elapsed=$(perl -MTime::HiRes=time -e "printf '%.3f', time-$t0")

  if [[ -n "$fault_file" ]]; then
    kill -STOP "$pid" 2>/dev/null; sleep 0.2
    sample "$pid" 1 -file "$dir/sample.txt" >/dev/null 2>&1 && \
      log "sample -> $dir/sample.txt"
    ( lldb -p "$pid" -b -o "thread backtrace all" -o detach -o quit \
        >"$dir/lldb-attach.txt" 2>&1 ) &
    local lpid=$!
    for _ in $(seq 1 60); do kill -0 "$lpid" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$lpid" 2>/dev/null
    echo "storm: fault after ${elapsed}s ($(grep -cF "$FAULT_RE" "$fault_file") lines)" \
      | tee "$dir/verdict.txt"
    kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 2
  fi

  if (( self_exit == 1 )); then
    cp -f "$dir/game.log" "$dir/game.log.kept" 2>/dev/null
    if (( exit_code > 128 )); then
      echo "crash: signal $((exit_code - 128)) after ${elapsed}s" | tee "$dir/verdict.txt"
      return 3
    fi
    echo "clean exit $exit_code after ${elapsed}s" | tee "$dir/verdict.txt"
    return 0
  fi

  kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "no fault within ${MAX_WAIT}s (still alive at ${elapsed}s)" | tee "$dir/verdict.txt"
  return 0
}

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
worst=0
for i in $(seq 1 "$RUNS"); do
  log "run $i/$RUNS"
  run_once "$OUT_DIR/run-$i"
  rc=$?
  [[ $rc -gt $worst ]] && worst=$rc
done
log "done: worst exit=$worst (0=clean, 2=storm, 3=crash)"
exit "$worst"
