#!/usr/bin/env bash
# Software-only callback tests. Does not initialize an audio device or window.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="${1:-${ROOT}/ReXGlue/out/mac-arm64/Release}"
OUT="${FIFA_RUNTIME_DIAG_TEST_OUT:-${ROOT}/build/macos/logs/runtime-diagnostics/tests}"
mkdir -p "${OUT}"
clang++ -std=c++23 -O2 -fno-char8_t -DSPDLOG_FMT_EXTERNAL \
  -I "${ROOT}/ReXGlue/include" -I "${ROOT}/ReXGlue/thirdparty/simde" \
  -I "${ROOT}/ReXGlue/thirdparty/sdl3/include" \
  -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
  "${ROOT}/scripts/runtime_diagnostics_test.cpp" -L "${LIBS}" -lrexruntime \
  -Wl,-rpath,"${LIBS}" -o "${OUT}/runtime-diagnostics-test" > "${OUT}/compile.log" 2>&1
RESTREET_PERF_DIAG= "${OUT}/runtime-diagnostics-test" | tee "${OUT}/disabled.txt"
RESTREET_PERF_DIAG="${OUT}/fixture.jsonl" "${OUT}/runtime-diagnostics-test" --enabled | tee "${OUT}/enabled.txt"
python3 - "${OUT}/fixture.jsonl" <<'PY'
import json
import sys
from pathlib import Path
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert rows[0]['type'] == 'session' and rows[0]['version'] == 1
assert rows[0]['steady_anchor_us'] > 0 and rows[0]['unix_anchor_us'] > 0
audio = {r['id']: r for r in rows if r['type'] == 'audio'}
assert len(audio) == 2
assert all(r['consumed'] == 3 and r['silence_blocks'] == 4 and r['closed'] == 1 for r in audio.values())
assert {r['stream_channels'] for r in audio.values()} == {2,6}
events = [r for r in rows if r['type'] == 'stage_event']
assert all(r['end_us'] >= r['start_us'] >= 0 and r['duration_us'] == r['end_us']-r['start_us'] for r in events)
summary = {r['stage']:r for r in rows if r['type'] == 'stage_summary'}
assert summary['graphics_pipeline']['count'] == 1  # Finish + destructor never double record.
assert summary['shader_translation']['count'] == 1 and summary['shader_translation']['failures'] == 1
assert summary['shader_module']['count'] == 600
assert all(r['active'] == 0 for r in summary.values())
dropped = summary['shader_module']['dropped_events']
assert len(events) + dropped == 602  # Bounded event queue reports lost detail.
print('PASS JSONL: two audio probes, aligned stage timestamps, exact concurrent totals, bounded event loss')
PY
RESTREET_PERF_DIAG= "${OUT}/runtime-diagnostics-test" --benchmark | tee "${OUT}/benchmark-disabled.txt"
RESTREET_PERF_DIAG="${OUT}/benchmark.jsonl" "${OUT}/runtime-diagnostics-test" --benchmark | tee "${OUT}/benchmark-enabled.txt"
clang++ -std=c++23 -O1 -g -fsanitize=thread -I "${ROOT}/ReXGlue/include" \
  "${ROOT}/scripts/runtime_diagnostics_stress.cpp" \
  "${ROOT}/ReXGlue/src/core/runtime_diagnostics.cpp" -o "${OUT}/recorder-stress"
RESTREET_PERF_DIAG="${OUT}/stress.jsonl" TSAN_OPTIONS=halt_on_error=1 \
  "${OUT}/recorder-stress" | tee "${OUT}/stress.txt"
python3 - "${OUT}/stress.jsonl" <<'PY'
import json,sys
from pathlib import Path
rows=[json.loads(x) for x in Path(sys.argv[1]).read_text().splitlines()]
points=sum(r['type']=='frame_point' for r in rows)
summary=[r for r in rows if r['type']=='frame_summary'][-1]
assert points+summary['dropped_points']==4000
print('PASS concurrent frame markers: exact recorded-plus-dropped accounting under ThreadSanitizer')
PY
