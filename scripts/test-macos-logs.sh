#!/usr/bin/env bash
#
# test-macos-logs.sh - behavioral fixtures for scripts/logs-macos.sh and its
# Python follower. Everything runs against private temp fake logs and fake
# processes; the game is never launched and no real session data is touched.
#
# Covers:
#   - bash/Python syntax;
#   - --help and invalid/extra argument rejection with real exit codes;
#   - a watcher started before the play root exists waits, creates nothing, then
#     picks up the first session, prints a bounded history and follows appends;
#   - automatic switch to a newer session, including waiting for that session's
#     not-yet-created log, and dropping the old session's later lines;
#   - --session pinning (newer sessions ignored) and waiting for its missing log;
#   - --lines controlling the initial history size (0 = live only);
#   - an incomplete trailing line at attach is completed and emitted once;
#   - split UTF-8 byte sequences across appends decode without corruption;
#   - truncation and inode replacement keeping output alive;
#   - a large existing log is tailed with bounded reads (no whole-file read);
#   - a log that vanishes between stat and reopen is tolerated, not a crash;
#   - stopping the watcher leaves a separate fake sentinel process running.
#
# Usage: scripts/test-macos-logs.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOGS="${ROOT}/scripts/logs-macos.sh"
HELPER="${ROOT}/scripts/watch-macos-play-log.py"

PASSED=0
FAILED=0
ok()  { printf 'OK   %s\n' "$1"; PASSED=$((PASSED + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
WATCH_PIDS=()
SENTINELS=()

cleanup() {
  local p
  if [[ "${#WATCH_PIDS[@]}" -gt 0 ]]; then
    for p in "${WATCH_PIDS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  fi
  if [[ "${#SENTINELS[@]}" -gt 0 ]]; then
    for p in "${SENTINELS[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

# wait_for <file> <pattern> [deciseconds] -> 0 if the pattern shows up in time.
wait_for() {
  local file="$1" pat="$2" tries="${3:-50}" i=0
  while [[ "$i" -lt "$tries" ]]; do
    if [[ -f "$file" ]] && grep -qF -- "$pat" "$file" 2>/dev/null; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# absent_for <file> <pattern> [deciseconds] -> 0 if the pattern never shows up.
absent_for() {
  local file="$1" pat="$2" tries="${3:-12}" i=0
  while [[ "$i" -lt "$tries" ]]; do
    if [[ -f "$file" ]] && grep -qF -- "$pat" "$file" 2>/dev/null; then return 1; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# start_watcher <root> <outfile> [extra args...]; sets WATCH_PID.
WATCH_PID=""
start_watcher() {
  local root="$1" out="$2"
  shift 2
  FIFA_BUILD_ROOT="$root" "$LOGS" "$@" >"$out" 2>&1 &
  WATCH_PID=$!
  WATCH_PIDS+=("${WATCH_PID}")
}

# stop_watcher <pid>; sets STOP_CODE to the real exit code.
STOP_CODE=0
stop_watcher() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  STOP_CODE=0
  wait "$pid" 2>/dev/null || STOP_CODE=$?
}

# expect_code <want> [args...] -> 0 if scripts/logs-macos.sh exits with want.
expect_code() {
  local want="$1"
  shift
  local code=0
  FIFA_BUILD_ROOT="${TMP}/no-such-root" "$LOGS" "$@" >/dev/null 2>&1 || code=$?
  if [[ "$code" -eq "$want" ]]; then return 0; fi
  printf '       (expected exit %s, got %s for: %s)\n' "$want" "$code" "$*" >&2
  return 1
}

make_session() { mkdir -p "$1/logs/play/$2"; }

# write_log <path> <line...> : create atomically so the file is never seen
# half-written and only ever appears fully formed.
write_log() {
  local path="$1"
  shift
  local tmp="${path}.tmp.$$"
  printf '%s\n' "$@" >"${tmp}"
  mv "${tmp}" "${path}"
}

session_log() { printf '%s' "$1/logs/play/$2/fifastreet.log"; }

# count_line <file> <literal> -> number of lines exactly equal to the literal.
count_line() {
  local n
  n="$(grep -cxF -- "$2" "$1" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

echo "== logs-macos.sh syntax =="
if bash -n "${LOGS}"; then ok "logs-macos.sh passes bash -n"; else bad "logs-macos.sh fails bash -n"; fi
if python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "${HELPER}" 2>"${TMP}/py.err"; then
  ok "watch-macos-play-log.py compiles"
else
  bad "watch-macos-play-log.py does not compile"
  sed 's/^/       /' "${TMP}/py.err" >&2
fi

echo
echo "== logs-macos.sh arguments =="
help_out=""
if help_out="$("$LOGS" --help 2>&1)"; then
  ok "--help exits 0"
else
  bad "--help exited nonzero"
fi
case "${help_out}" in
  *Usage:*logs-macos*) ok "--help documents usage" ;;
  *) bad "--help did not print usage" ;;
esac
if [[ ! -e "${TMP}/no-such-root" ]]; then ok "--help creates no state"; else bad "--help wrote state"; fi

expect_code 2 --bogus-flag        && ok "unknown option rejected (2)" || bad "unknown option not rejected"
expect_code 2 extra-positional    && ok "extra positional rejected (2)" || bad "extra positional not rejected"
expect_code 2 --lines             && ok "--lines without value rejected (2)" || bad "--lines without value not rejected"
expect_code 2 --lines abc         && ok "non-numeric --lines rejected (2)" || bad "non-numeric --lines not rejected"
expect_code 2 --lines=-3          && ok "negative --lines rejected (2)" || bad "negative --lines not rejected"
expect_code 2 --session           && ok "--session without value rejected (2)" || bad "--session without value not rejected"
expect_code 2 --session nope      && ok "malformed --session rejected (2)" || bad "malformed --session not rejected"

echo
echo "== following sessions =="
ROOT1="${TMP}/run1"
OUT1="${TMP}/run1.out"
start_watcher "${ROOT1}" "${OUT1}"
PID1="${WATCH_PID}"
if wait_for "${OUT1}" "waiting for a play session" 40; then
  ok "waits before any session exists"
else
  bad "did not announce waiting for a session"
fi
if [[ ! -e "${ROOT1}" ]]; then ok "creates no play root while waiting"; else bad "created the play root"; fi

SESSION_A=20260101T000000Z
make_session "${ROOT1}" "${SESSION_A}"
A_LINES=()
i=0
while [[ "$i" -le 24 ]]; do
  A_LINES+=("$(printf 'old-%02d' "$i")")
  i=$((i + 1))
done
A_LOG="$(session_log "${ROOT1}" "${SESSION_A}")"
write_log "${A_LOG}" "${A_LINES[@]}"
if wait_for "${OUT1}" "play session ${SESSION_A}" 30; then ok "printed the session label"; else bad "no session label"; fi
if wait_for "${OUT1}" "old-24" 30; then ok "printed the history tail"; else bad "did not print history"; fi
if absent_for "${OUT1}" "old-04" 10; then ok "history limited to the last 20 lines"; else bad "printed more than the last 20 lines"; fi

printf 'live-01\n' >>"${A_LOG}"
if wait_for "${OUT1}" "live-01" 30; then ok "streamed an appended line"; else bad "missed an appended line"; fi
printf 'live-02\n' >>"${A_LOG}"
if wait_for "${OUT1}" "live-02" 30; then ok "streamed a second appended line"; else bad "missed a second appended line"; fi

SESSION_B=20260102T000000Z
make_session "${ROOT1}" "${SESSION_B}"
if wait_for "${OUT1}" "play session ${SESSION_B}" 30; then ok "switched to a newer session"; else bad "did not switch to a newer session"; fi
if wait_for "${OUT1}" "waiting for log" 30; then ok "waited for the new session's missing log"; else bad "did not wait for the new log"; fi
printf 'old-late-secret\n' >>"${A_LOG}"
if absent_for "${OUT1}" "old-late-secret" 15; then ok "old session lines stop after the switch"; else bad "old session still streamed after switch"; fi
B_LOG="$(session_log "${ROOT1}" "${SESSION_B}")"
write_log "${B_LOG}" "new-01"
if wait_for "${OUT1}" "new-01" 30; then ok "streamed the new session once its log appeared"; else bad "missed the new session log"; fi
printf 'old-late-secret-2\n' >>"${A_LOG}"
printf 'new-02\n' >>"${B_LOG}"
if wait_for "${OUT1}" "new-02" 30; then ok "streamed a new session append"; else bad "missed a new session append"; fi
if absent_for "${OUT1}" "old-late-secret-2" 15; then ok "old lines stay dropped after the switch"; else bad "old lines leaked after the switch"; fi

sleep 300 >/dev/null 2>&1 &
SENT1=$!
disown "${SENT1}" 2>/dev/null || true
SENTINELS+=("${SENT1}")
sleep 0.3
stop_watcher "${PID1}"
if [[ "${STOP_CODE}" -eq 0 ]]; then ok "watcher exits 0 on SIGTERM (real code ${STOP_CODE})"; else bad "watcher exit code ${STOP_CODE}"; fi
if kill -0 "${SENT1}" 2>/dev/null; then ok "separate sentinel process survives the watcher stop"; else bad "sentinel was killed"; fi
kill -TERM "${SENT1}" 2>/dev/null || true

echo
echo "== pinned session =="
ROOT2="${TMP}/run2"
OUT2="${TMP}/run2.out"
SESSION_P=20260201T000000Z
SESSION_Q=20260202T000000Z
make_session "${ROOT2}" "${SESSION_P}"
P_LOG="$(session_log "${ROOT2}" "${SESSION_P}")"
write_log "${P_LOG}" "p-01"
start_watcher "${ROOT2}" "${OUT2}" --session "${SESSION_P}"
PID2="${WATCH_PID}"
wait_for "${OUT2}" "play session ${SESSION_P}" 30 && ok "pinned session labelled" || bad "no pinned session label"
wait_for "${OUT2}" "p-01" 30 && ok "pinned session history printed" || bad "no pinned history"
printf 'p-live\n' >>"${P_LOG}"
wait_for "${OUT2}" "p-live" 30 && ok "pinned session streams" || bad "pinned session not streaming"
make_session "${ROOT2}" "${SESSION_Q}"
write_log "$(session_log "${ROOT2}" "${SESSION_Q}")" "q-01"
absent_for "${OUT2}" "q-01" 15 && ok "newer session ignored while pinned" || bad "pinned watcher switched away"
printf 'p-live-2\n' >>"${P_LOG}"
wait_for "${OUT2}" "p-live-2" 30 && ok "pinned session keeps streaming" || bad "pinned session stopped"
stop_watcher "${PID2}"
[[ "${STOP_CODE}" -eq 0 ]] && ok "pinned watcher exits 0 (real code ${STOP_CODE})" || bad "pinned watcher exit ${STOP_CODE}"

echo
echo "== pinned session waits for its log =="
ROOT3="${TMP}/run3"
OUT3="${TMP}/run3.out"
SESSION_R=20260315T000000Z
start_watcher "${ROOT3}" "${OUT3}" --session "${SESSION_R}"
PID3="${WATCH_PID}"
wait_for "${OUT3}" "play session ${SESSION_R}" 30 && ok "pinned missing session labelled" || bad "no label for missing pinned session"
wait_for "${OUT3}" "waiting for log" 30 && ok "pinned watcher waits for its missing log" || bad "did not wait for the pinned log"
make_session "${ROOT3}" "${SESSION_R}"
write_log "$(session_log "${ROOT3}" "${SESSION_R}")" "r-01"
wait_for "${OUT3}" "r-01" 30 && ok "pinned watcher picks up the log when created" || bad "missed the pinned log"
stop_watcher "${PID3}"

echo
echo "== --lines history size =="
ROOT4="${TMP}/run4"
OUT4="${TMP}/run4.out"
SESSION_L=20260401T000000Z
make_session "${ROOT4}" "${SESSION_L}"
write_log "$(session_log "${ROOT4}" "${SESSION_L}")" h-1 h-2 h-3 h-4 h-5 h-6
start_watcher "${ROOT4}" "${OUT4}" --lines 3
PID4="${WATCH_PID}"
wait_for "${OUT4}" "h-6" 30 && ok "--lines 3 printed the newest history" || bad "--lines 3 missed the history"
absent_for "${OUT4}" "h-3" 10 && ok "--lines 3 dropped older history" || bad "--lines 3 printed too much history"
stop_watcher "${PID4}"

echo
echo "== truncation and replacement =="
ROOT5="${TMP}/run5"
OUT5="${TMP}/run5.out"
SESSION_T=20260501T000000Z
make_session "${ROOT5}" "${SESSION_T}"
T_LOG="$(session_log "${ROOT5}" "${SESSION_T}")"
write_log "${T_LOG}" "t-01" "t-02"
start_watcher "${ROOT5}" "${OUT5}"
PID5="${WATCH_PID}"
wait_for "${OUT5}" "t-02" 30 && ok "baseline session streamed" || bad "baseline not streamed"

: >"${T_LOG}"
sleep 0.6
printf 'after-trunc-01\n' >>"${T_LOG}"
wait_for "${OUT5}" "after-trunc-01" 30 && ok "kept reading after truncation" || bad "stopped after truncation"

write_log "${T_LOG}" "replaced-01"
wait_for "${OUT5}" "replaced-01" 30 && ok "observed inode replacement" || bad "missed inode replacement"
printf 'after-replace-01\n' >>"${T_LOG}"
wait_for "${OUT5}" "after-replace-01" 30 && ok "streamed after replacement" || bad "stopped after replacement"
stop_watcher "${PID5}"

echo
echo "== incomplete trailing line =="
ROOT6="${TMP}/run6"
OUT6="${TMP}/run6.out"
SESSION_U=20260601T000000Z
make_session "${ROOT6}" "${SESSION_U}"
U_LOG="$(session_log "${ROOT6}" "${SESSION_U}")"
printf '%s' "first=le" >"${U_LOG}"          # no trailing newline yet
start_watcher "${ROOT6}" "${OUT6}" --session "${SESSION_U}"
PID6="${WATCH_PID}"
wait_for "${OUT6}" "play session ${SESSION_U}" 30 && ok "partial-line session labelled" || bad "no partial-line session label"
sleep 0.5                                    # let the watcher attach and hold the fragment
printf 'ft\n' >>"${U_LOG}"
if wait_for "${OUT6}" "first=left" 30; then
  ok "completed partial line emitted"
else
  bad "partial line never completed"
fi
if [[ "$(count_line "${OUT6}" "first=left")" -eq 1 ]]; then
  ok "completed partial line emitted exactly once"
else
  bad "partial line emitted $(count_line "${OUT6}" "first=left") times"
fi
if [[ "$(count_line "${OUT6}" "first=le")" -eq 0 ]]; then
  ok "incomplete fragment not printed as its own line"
else
  bad "printed the incomplete fragment as a separate line"
fi
stop_watcher "${PID6}"

echo
echo "== --lines 0 live only and held partial =="
ROOT7="${TMP}/run7"
OUT7="${TMP}/run7.out"
SESSION_V=20260701T000000Z
make_session "${ROOT7}" "${SESSION_V}"
V_LOG="$(session_log "${ROOT7}" "${SESSION_V}")"
printf 'pre-1\npre-2\n' >"${V_LOG}"
start_watcher "${ROOT7}" "${OUT7}" --session "${SESSION_V}" --lines 0
PID7="${WATCH_PID}"
wait_for "${OUT7}" "play session ${SESSION_V}" 30 && ok "--lines 0 session labelled" || bad "no --lines 0 label"
sleep 0.5
if [[ "$(count_line "${OUT7}" "pre-1")" -eq 0 && "$(count_line "${OUT7}" "pre-2")" -eq 0 ]]; then
  ok "--lines 0 suppressed existing history"
else
  bad "--lines 0 printed existing history"
fi
printf 'live-0\n' >>"${V_LOG}"
wait_for "${OUT7}" "live-0" 30 && ok "--lines 0 still streams appends" || bad "--lines 0 missed appends"
printf '%s' "tail=part" >>"${V_LOG}"      # incomplete line, no newline
sleep 0.4
printf 'ial\n' >>"${V_LOG}"               # completes it
if wait_for "${OUT7}" "tail=partial" 30; then
  if [[ "$(count_line "${OUT7}" "tail=partial")" -eq 1 ]]; then
    ok "--lines 0 held a partial append and emitted it once"
  else
    bad "--lines 0 partial append emitted $(count_line "${OUT7}" "tail=partial") times"
  fi
else
  bad "--lines 0 corrupted a partial append"
fi
stop_watcher "${PID7}"

echo
echo "== split UTF-8 append =="
ROOT8="${TMP}/run8"
OUT8="${TMP}/run8.out"
SESSION_W=20260801T000000Z
make_session "${ROOT8}" "${SESSION_W}"
W_LOG="$(session_log "${ROOT8}" "${SESSION_W}")"
printf 'start\n' >"${W_LOG}"
start_watcher "${ROOT8}" "${OUT8}" --session "${SESSION_W}"
PID8="${WATCH_PID}"
wait_for "${OUT8}" "start" 30 && ok "UTF-8 baseline line streamed" || bad "UTF-8 baseline missing"
printf 'caf\xc3' >>"${W_LOG}"                # first byte of the two-byte 'é'
sleep 0.4                                    # force a poll mid-character
printf '\xa9\n' >>"${W_LOG}"                 # second byte completes the character
EXPECT_UTF8="$(printf 'caf\xc3\xa9')"
if wait_for "${OUT8}" "${EXPECT_UTF8}" 30; then
  if [[ "$(count_line "${OUT8}" "${EXPECT_UTF8}")" -eq 1 ]]; then
    ok "split UTF-8 bytes decoded into one correct line"
  else
    bad "split UTF-8 line emitted $(count_line "${OUT8}" "${EXPECT_UTF8}") times"
  fi
else
  bad "split UTF-8 bytes were corrupted"
fi
stop_watcher "${PID8}"

echo
echo "== large log tail is bounded =="
BIGROOT="${TMP}/run-big"
SESSION_BIG=20260610T000000Z
make_session "${BIGROOT}" "${SESSION_BIG}"
BIG_LOG="$(session_log "${BIGROOT}" "${SESSION_BIG}")"
python3 - "${BIG_LOG}" <<'PY'
import sys
with open(sys.argv[1], "wb") as handle:
    for i in range(400000):
        handle.write(b"line-%06d\n" % i)
PY
cat >"${TMP}/bounded_reads.py" <<'PY'
import importlib.util
import os
import sys

helper_path, log_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("watchlog", helper_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

real_open = open
reads = []


class Spy:
    def __init__(self, handle):
        self._handle = handle

    def read(self, size=-1):
        reads.append(size)
        return self._handle.read(size)

    def seek(self, *args):
        return self._handle.seek(*args)

    def tell(self):
        return self._handle.tell()

    def fileno(self):
        return self._handle.fileno()

    def close(self):
        return self._handle.close()


def spy_open(path, mode="r", *args, **kwargs):
    return Spy(real_open(path, mode, *args, **kwargs))


module.open = spy_open
module.announce = lambda *a, **k: None


def unbounded():
    return [n for n in reads if n is None or n < 0]


def requested():
    return sum(n for n in reads if isinstance(n, int) and n > 0)


size = os.path.getsize(log_path)
follower = module.LogFollower(log_path, 20)
assert not unbounded(), "open used an unbounded read: %r" % unbounded()
assert requested() < size // 4, "open requested %d of %d bytes" % (requested(), size)
follower.close()

follower = module.LogFollower(log_path, 0)
reads.clear()
with real_open(log_path, "ab") as handle:
    for i in range(30000):
        handle.write(b"burst-%06d\n" % i)
follower.read_appended()
assert not unbounded(), "read_appended used an unbounded read: %r" % unbounded()
follower.close()
PY
PROBE_LOG="${TMP}/probe-big.log"
cp "${BIG_LOG}" "${PROBE_LOG}"
if python3 "${TMP}/bounded_reads.py" "${HELPER}" "${PROBE_LOG}" 2>"${TMP}/bounded.err"; then
  ok "open and append reads are chunk-bounded"
else
  bad "unbounded whole-file read on a large log"
  sed 's/^/       /' "${TMP}/bounded.err" >&2
fi
OUTBIG="${TMP}/run-big.out"
start_watcher "${BIGROOT}" "${OUTBIG}" --session "${SESSION_BIG}" --lines 20
PIDBIG="${WATCH_PID}"
wait_for "${OUTBIG}" "line-399999" 40 && ok "bounded tail printed the newest line" || bad "bounded tail missed the newest line"
absent_for "${OUTBIG}" "line-399979" 10 && ok "bounded tail printed only the last 20 lines" || bad "bounded tail printed too much history"
printf 'line-after\n' >>"${BIG_LOG}"
wait_for "${OUTBIG}" "line-after" 30 && ok "bounded reader streams appends" || bad "bounded reader missed appends"
stop_watcher "${PIDBIG}"

echo
echo "== replacement race tolerance =="
ROOT9="${TMP}/run9"
SESSION_X=20260901T000000Z
make_session "${ROOT9}" "${SESSION_X}"
X_LOG="$(session_log "${ROOT9}" "${SESSION_X}")"
write_log "${X_LOG}" "x-01"
cat >"${TMP}/race_test.py" <<'PY'
import importlib.util
import os
import sys
import threading
import time

helper_path, root, session = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("watchlog", helper_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

log_path = os.path.join(root, session, module.LOG_NAME)
lines = []
module.announce = lambda message: lines.append(str(message))

real_open = open
real_stat = os.stat
real_listdir = os.listdir

st0 = real_stat(log_path)
fake = os.stat_result((st0.st_mode, st0.st_ino + 999999, st0.st_dev, st0.st_nlink,
                       st0.st_uid, st0.st_gid, st0.st_size,
                       st0.st_atime, st0.st_mtime, st0.st_ctime))
race = {"armed": False}


def fake_stat(path, *args, **kwargs):
    if race["armed"] and path == log_path:
        try:
            real_stat(path)
        except FileNotFoundError:
            race["armed"] = False
            return fake
    return real_stat(path, *args, **kwargs)


module.os.stat = fake_stat

errors = []


def run():
    try:
        module.follow(root, session, 20)
    except BaseException as exc:  # noqa: BLE001 - report any crash
        errors.append(repr(exc))


thread = threading.Thread(target=run, daemon=True)
thread.start()


def wait_for_line(needle, budget=8.0):
    deadline = time.time() + budget
    while time.time() < deadline:
        if any(needle in line for line in lines):
            return True
        time.sleep(0.02)
    return False


if not wait_for_line("play session " + session):
    module.os.stat = real_stat
    module._stop = True
    print("watcher never bound", file=sys.stderr)
    sys.exit(3)

# Arrange: stat reports a fresh inode only once the file is really gone, so the
# reattach opens a path that has already been removed.
time.sleep(0.6)
race["armed"] = True
os.remove(log_path)
time.sleep(1.2)

if errors:
    module.os.stat = real_stat
    module._stop = True
    thread.join(timeout=5)
    print("watcher raised: %s" % errors[0], file=sys.stderr)
    sys.exit(2)

with real_open(log_path + ".new", "wb") as handle:
    handle.write(b"recovered-01\n")
os.rename(log_path + ".new", log_path)

if not wait_for_line("recovered-01"):
    module.os.stat = real_stat
    module._stop = True
    thread.join(timeout=5)
    print("watcher did not recover", file=sys.stderr)
    sys.exit(4)

module.os.stat = real_stat
module._stop = True
thread.join(timeout=5)
if thread.is_alive():
    print("watcher thread did not stop", file=sys.stderr)
    sys.exit(5)
if errors:
    print("watcher raised: %s" % errors[0], file=sys.stderr)
    sys.exit(6)

# A root that disappears between isdir and listdir must not crash either.
phantom = os.path.join(root, "phantom-root")
os.makedirs(phantom, exist_ok=True)


def vanishing_listdir(_path):
    raise FileNotFoundError(phantom)


module.os.listdir = vanishing_listdir
try:
    got = module.session_dirs(phantom)
finally:
    module.os.listdir = real_listdir
assert got == [], "session_dirs did not tolerate a vanishing root: %r" % got
PY
if python3 "${TMP}/race_test.py" "${HELPER}" "${ROOT9}/logs/play" "${SESSION_X}" 2>"${TMP}/race.err"; then
  ok "tolerates a log vanishing between stat and reopen"
else
  bad "crashed when the log vanished during reattach"
  sed 's/^/       /' "${TMP}/race.err" >&2
fi

echo
echo "=============================================================="
printf ' logs tests: %d passed, %d failed\n' "${PASSED}" "${FAILED}"
echo "=============================================================="
if [[ "${FAILED}" -ne 0 ]]; then
  echo "SOME LOGS TESTS FAILED"
  exit 1
fi
echo "ALL LOGS TESTS PASSED"
