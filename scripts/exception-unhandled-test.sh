#!/usr/bin/env bash
# Seam-level regression test for the POSIX unhandled-exception fix, plus a
# handled-path control that must be unaffected by it.
#
# Bug: on POSIX/macOS, ExceptionHandlerCallback returned to the faulting
# instruction when no handler consumed a synchronous fault, so the process spun
# forever (the "Unhandled guest access violation" log storm). Windows returns
# EXCEPTION_CONTINUE_SEARCH and lets the process terminate.
#
# Two cases drive the seam, each in its own process:
#   unhandled - install a handler that declines the fault, then fault on address
#               4. After the fix the process must die from the fault signal
#               (SIGSEGV/SIGBUS). Before the fix it re-executes the faulting
#               instruction forever -> the harness times out -> red.
#   handled   - install a handler that repairs the page and declares the fault
#               consumed, then fault on a PROT_NONE page. The store must resume
#               and complete, proving the fixed path does not change the
#               handled-fault behaviour.
#
# Verdict: exit 0 = both cases pass, exit 1 = at least one failed, exit 2 =
# build/link failure. An unexpected normal exit on the unhandled case is a
# failure (it means the fault did not terminate the process), not a pass.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$ROOT/build/macos/run"
OUT_DIR="$ROOT/build/macos/logs/exception-unhandled-test"
TIMEOUT_S="${TIMEOUT_S:-10}"
# Signals that count as "the fault terminated the process". A macOS access
# violation arrives as SIGSEGV (11) or, for a protection fault, SIGBUS (10).
EXPECTED_SIGNALS="${EXPECTED_SIGNALS:-10 11}"

RUNTIME="$RUN_DIR/librexruntime.dylib"
[[ -f "$RUNTIME" ]] || { echo "missing $RUNTIME" >&2; exit 2; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cat > "$OUT_DIR/seam_test.cpp" <<'EOF'
#include <rex/exception_handler.h>

#include <sys/mman.h>

#include <cstdio>
#include <cstring>

// Unhandled path: decline every fault. A fixed runtime makes this fatal; the
// buggy runtime returns to the faulting instruction and spins.
static bool Decline(rex::arch::Exception*, void*) { return false; }

// Handled path: repair the page and declare the fault consumed.
static void* g_page = nullptr;
static const size_t g_len = 4096;
static bool Repair(rex::arch::Exception* ex, void*) {
  if (ex->code() != rex::arch::Exception::Code::kAccessViolation) return false;
  uint64_t addr = ex->fault_address();
  if (addr < reinterpret_cast<uint64_t>(g_page) ||
      addr >= reinterpret_cast<uint64_t>(g_page) + g_len) {
    return false;
  }
  return mprotect(g_page, g_len, PROT_READ | PROT_WRITE) == 0;
}

static int run_unhandled() {
  rex::arch::ExceptionHandler::Install(&Decline, nullptr);
  volatile int* p = reinterpret_cast<volatile int*>(4);
  int value = *p;
  (void)value;
  // Only reached if the handler returned to the faulting instruction (the bug).
  std::printf("UNHANDLED-RETURNED\n");
  return 0;
}

static int run_handled() {
  rex::arch::ExceptionHandler::Install(&Repair, nullptr);
  g_page = mmap(nullptr, g_len, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (g_page == MAP_FAILED) {
    std::perror("mmap");
    return 2;
  }
  volatile int* p = reinterpret_cast<volatile int*>(g_page);
  *p = 0x1234;  // faults, the handler repairs the page, the store re-executes
  if (*p != 0x1234) {
    std::printf("HANDLED-BAD-VALUE\n");
    return 3;
  }
  std::printf("HANDLED-OK\n");
  return 0;
}

int main(int argc, char** argv) {
  const char* mode = argc > 1 ? argv[1] : "unhandled";
  if (std::strcmp(mode, "handled") == 0) return run_handled();
  return run_unhandled();
}
EOF

clang++ -std=c++20 -O0 -g \
  -I"$ROOT/ReXGlue/include" \
  -Wl,-rpath,"$RUN_DIR" -L"$RUN_DIR" \
  "$OUT_DIR/seam_test.cpp" -lrexruntime \
  -o "$OUT_DIR/seam_test" >"$OUT_DIR/build.log" 2>&1 \
  || { echo "compile/link failed:"; tail -20 "$OUT_DIR/build.log"; exit 2; }

CASE_CODE=""
CASE_HANG=0

# Run one case with a hard timeout. Sets CASE_CODE (wait status) and CASE_HANG.
run_case() {
  local mode="$1"
  local dir="$OUT_DIR/$mode"
  mkdir -p "$dir"
  ( cd "$RUN_DIR" && exec "$OUT_DIR/seam_test" "$mode" ) >"$dir/run.log" 2>&1 &
  local pid=$!
  CASE_CODE=""
  CASE_HANG=0
  for _ in $(seq 1 $((TIMEOUT_S * 10))); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    CASE_HANG=1
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return
  fi
  wait "$pid" 2>/dev/null
  CASE_CODE=$?
}

signal_expected() {
  local sig="$1"
  for s in $EXPECTED_SIGNALS; do [[ "$sig" == "$s" ]] && return 0; done
  return 1
}

# Verdict for the unhandled case: 0 = expected fatal signal, 1 = anything else.
classify_unhandled() {
  local code="$1" hang="$2" sig
  if (( hang == 1 )); then
    echo "hung (fault did not terminate; bug present)"
    return 1
  fi
  if (( code > 128 )); then
    sig=$((code - 128))
    if signal_expected "$sig"; then
      echo "terminated by signal $sig"
      return 0
    fi
    echo "terminated by unexpected signal $sig"
    return 1
  fi
  echo "exited $code without a signal (fault not fatal)"
  return 1
}

RC=0

# Self-check: a normal exit and a hang must both be failures, not passes.
if classify_unhandled 0 0 >/dev/null; then
  echo "self-check: FAIL - normal exit misclassified as pass"; RC=1
fi
if classify_unhandled 0 1 >/dev/null; then
  echo "self-check: FAIL - hang misclassified as pass"; RC=1
fi

# --- case 1: unhandled fault must be fatal with an expected signal -----------
run_case unhandled
if VERDICT="$(classify_unhandled "$CASE_CODE" "$CASE_HANG")"; then
  echo "unhandled: PASS - $VERDICT"
else
  echo "unhandled: FAIL - $VERDICT"
  RC=1
fi

# --- case 2: handled fault must resume and complete normally -----------------
run_case handled
if (( CASE_HANG == 1 )); then
  echo "handled: FAIL - hung"
  RC=1
elif (( CASE_CODE == 0 )) && grep -q HANDLED-OK "$OUT_DIR/handled/run.log"; then
  echo "handled: PASS - handler consumed the fault and the store completed"
else
  echo "handled: FAIL - exit=$CASE_CODE (see $OUT_DIR/handled/run.log)"
  RC=1
fi

echo "RESULT: $([[ $RC -eq 0 ]] && echo PASS || echo FAIL)"
exit "$RC"
