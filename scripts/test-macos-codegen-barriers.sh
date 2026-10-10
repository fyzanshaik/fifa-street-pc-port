#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_LIBS="${1:-${ROOT}/ReXGlue/out/mac-arm64/Release}"
OUT="${FIFA_BARRIER_TEST_OUT:-${ROOT}/build/macos/logs/codegen-barriers}"
[[ -f "${SDK_LIBS}/librexcodegen.a" ]] || {
  echo "ERROR: built SDK code generator not found in ${SDK_LIBS}" >&2
  exit 2
}
mkdir -p "${OUT}"
FIXTURE="$(mktemp -d "${OUT}/fixture.XXXXXX")"
clang++ -std=c++23 -fno-char8_t -DSPDLOG_FMT_EXTERNAL -Wall -Wextra \
  -I "${ROOT}/ReXGlue/include" \
  -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" \
  -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
  -I "${ROOT}/ReXGlue/thirdparty/tomlplusplus/include" \
  "${ROOT}/scripts/codegen_barrier_test.cpp" \
  "${SDK_LIBS}/librexcodegen.a" "${SDK_LIBS}/libdisasm.a" \
  "${SDK_LIBS}/libxxhash.a" "${SDK_LIBS}/libspdlog.a" "${SDK_LIBS}/libfmt.a" \
  -L "${SDK_LIBS}" -lrexruntime -Wl,-rpath,"${SDK_LIBS}" \
  -o "${FIXTURE}/codegen-barrier-test"
"${FIXTURE}/codegen-barrier-test" "${FIXTURE}" | tee "${FIXTURE}/result.txt"
if [[ "$(uname -m)" == arm64 ]]; then
  clang++ -std=c++23 -O2 -fno-char8_t \
    -I "${ROOT}/ReXGlue/include" -I "${ROOT}/ReXGlue/thirdparty/simde" \
    -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" \
    -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
    -S "${FIXTURE}/generated/barriers_recomp.0.cpp" -o "${FIXTURE}/barriers.s"
  python3 - "${FIXTURE}/barriers.s" <<'PY' | tee "${FIXTURE}/assembly-result.txt"
import re
import sys
from pathlib import Path

assembly = Path(sys.argv[1]).read_text()
for name, needs_barrier in (("xstart", True), ("sub_82000008", True),
                            ("sub_82000010", True), ("sub_82000018", False)):
    match = re.search(r"^___imp__" + name + r":.*?^\s*\.cfi_endproc", assembly,
                      re.MULTILINE | re.DOTALL)
    if not match:
        raise SystemExit(f"FAIL ARM64 assembly missing {name}")
    fences = re.findall(r"^\s*dmb\s+ish\s*$", match.group(), re.MULTILINE)
    if len(fences) != int(needs_barrier):
        raise SystemExit(f"FAIL ARM64 {name}: expected {int(needs_barrier)} fence, got {len(fences)}")
    print(f"PASS ARM64 {name}: {len(fences)} dmb ish")
PY
fi
