#!/usr/bin/env bash
# Real recorder/OS counters; no game, input, window, or stack sampling.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="${1:-${ROOT}/ReXGlue/out/mac-arm64/Release}"
OUT="${FIFA_FRAME_DIAG_TEST_OUT:-${ROOT}/build/macos/logs/frame-diagnostics/tests}"
mkdir -p "${OUT}"
clang++ -std=c++23 -O2 -fno-char8_t -DSPDLOG_FMT_EXTERNAL -I "${ROOT}/ReXGlue/include" \
  -I "${ROOT}/ReXGlue/thirdparty/vulkan-headers/include" \
  -I "${ROOT}/ReXGlue/thirdparty/spdlog/include" -I "${ROOT}/ReXGlue/thirdparty/fmt/include" \
  "${ROOT}/scripts/frame_diagnostics_test.cpp" -L "${LIBS}" -lrexruntime \
  -Wl,-rpath,"${LIBS}" -o "${OUT}/frame-test" > "${OUT}/compile.log" 2>&1
RESTREET_PERF_DIAG="" "${OUT}/frame-test" | tee "${OUT}/disabled.txt"
RESTREET_PERF_DIAG="${OUT}/fixture.jsonl" "${OUT}/frame-test" --enabled | tee "${OUT}/enabled.txt"
python3 "${ROOT}/scripts/analyze-macos-frame-diagnostics.py" "${OUT}/fixture.jsonl" > "${OUT}/analysis.txt"
python3 - "${ROOT}" "${OUT}" <<'PY'
import importlib.util,json,sys
from pathlib import Path
root,out=map(Path,sys.argv[1:])
r=json.loads((out/'frame-analysis.json').read_text())
assert r['point_counts']['swap_processed']==3
assert r['written_to_processed']['count']==3 and r['written_to_processed']['median_ms']>=2
assert r['published_to_first_present_queued']['count']==3 and r['repeated_present_points']==3
assert r['published_to_first_present_queued']['median_ms']>=1
assert r['gpu_execution_span']['count']==3 and r['gpu_execution_span']['median_ms']==1.5
assert [f['processed_swap_id'] for f in r['frame_timeline']]==[1,2,3]
assert r['dropped_points']>=904
assert all(v==0 for v in r['unmatched'].values())
busy=next(t for t in r['thread_cpu'] if 'diag-busy' in t['names'])
sleep=next(t for t in r['thread_cpu'] if 'diag-sleep' in t['names'])
assert busy['mean_cpu_percent']>50 and sleep['mean_cpu_percent']<5,(busy,sleep)
assert r['stages']['command_idle']['total_us']>=2000000
assert r['stages']['command_idle']['cpu_us']<50000
assert r['stages']['command_batch']['cpu_us']>1000000
assert r['stages']['queue_acquire']['count']==2 and r['stages']['queue_acquire']['max_us']>=40000
assert r['stages']['guest_submit_call']['count']==1 and r['stages']['guest_submit_call']['total_us']>=15000
assert r['stages']['guest_submit_call']['cpu_us']<5000
assert all(s['result']==0 and s['failures']==0 for s in r['thread_collection'])
assert all(s['collection_us']<100000 for s in r['thread_collection'])
spec=importlib.util.spec_from_file_location('frame',root/'scripts/analyze-macos-frame-diagnostics.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
rows=[json.loads(x) for x in (out/'fixture.jsonl').read_text().splitlines()]
# A consumer record precedes publication because instrumentation races mailbox release.
race=[rows[0],{'type':'frame_point','point':'present_queued','elapsed_us':10,'key1':1,'key2':0},
      {'type':'frame_point','point':'output_published','elapsed_us':11,'key1':1,'key2':0}]
path=out/'race.jsonl';path.write_text('\n'.join(map(json.dumps,race))+'\n')
a=m.analyze(path);assert a['publication_marker_races']==1 and a['published_to_first_present_queued']['count']==0
# Termination may leave a partial final JSON line; never invent missing data.
path.write_text(json.dumps(rows[0])+'\n{"type":')
assert m.analyze(path)['truncated_final_record']
path.write_text(json.dumps(rows[0])+'\n{"type":\n')
try:m.analyze(path)
except json.JSONDecodeError:pass
else:raise AssertionError('corrupt complete record accepted')
print('PASS: shared clock/frame correlation, repeated exclusion, busy versus sleeping CPU, loss and corrupt/racing records')
PY
