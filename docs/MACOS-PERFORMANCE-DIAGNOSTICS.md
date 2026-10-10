# macOS audio and pipeline measurements

> Historical methodology and experiment record. Current status and all
> consolidated findings are in [LOG/PROGRESS.md](../LOG/PROGRESS.md). Normal
> install/play instructions are in [BUILDING-MACOS.md](BUILDING-MACOS.md).

The recorder is opt-in. `RESTREET_PERF_DIAG` names a JSONL output file; when the
variable is empty or unset, no reporter thread, file or audio probe is created.
The implementation is carried by `rexglue-macos-portability.patch` and compiled
into the native runtime. The GPU plugin uses the same runtime recorder/clock.

## Collect a bounded manual session

After verifying the selected app, run from the repository:

```sh
python3 scripts/run-macos-performance-check.py \
  --app "build/macos/runtime-diagnostics-production/out/FIFA Street.app" \
  --runtime-diagnostics --skip-stack-sample --seconds 120
```

The script launches that app, leaves the controls to the player, and closes only
its own process at the time limit. The current Mac profile uses Enter for Start,
Space for A and arrows for movement. Record when Info/loading appears, when the
main menu appears, whether the
music sounds normal and whether navigation responds immediately. The recorder
does not identify screens automatically and does not inject input or capture frames.

The script prints the session directory under `build/macos/logs/performance-check/`.
It contains `fifastreet.log`, `runtime.jsonl`, `guest-perf.csv`, `cpu.csv`,
`setup.json` and `exit.json`. Without `--skip-stack-sample`, it also collects a
bounded thread sample at 60 seconds. The flag is recommended for performance
comparisons because the first live run paused during that sampling interval.
Read the runtime log with
`tail -f <session>/fifastreet.log`. The exit record distinguishes a scheduled stop
from a natural exit and records whether shutdown needed escalation.

To check paths while leaving the game closed, add `--check-only`. To measure the
same candidate with these probes disabled, omit `--runtime-diagnostics`.
The launcher strips inherited `RESTREET_*` variables before setting its explicit
diagnostics path, so frame readback and virtual input stay off.

## Read the saved data

```sh
python3 scripts/analyze-macos-runtime-diagnostics.py <session-directory>
python3 scripts/analyze-macos-performance.py <session-directory>
```

The first command produces `runtime-analysis.json`. Its audio results distinguish
guest submissions, consumed blocks, intentionally muted blocks and queue-empty
silence. Each block represents 256 guest sample frames at 48 kHz. The inserted
silence fraction is silence blocks divided by consumed plus inserted blocks;
mute is a subgroup of consumed blocks. Startup or pauses may legitimately produce
silence, so a fraction alone is not a music defect verdict.

Each audio client also reports PCM fingerprint repetitions at one/four-block
distances, exact-zero input blocks, producer/callback gaps, callback duration,
queue depth/high-water mark, stream/device format and the device's nominal chunk
size. New traces also separate numerical silence (including signed zero) from
non-silent one/four-block fingerprint repeats. Source sample counters identify
NaN/Inf separately from finite values outside [-1, 1], and report the largest
finite source magnitude. These inspect the guest's planar big-endian float32
samples before output gain, channel conversion and SDL processing. An out-of-range
source value is not by itself proof of audible clipping, and a repeated non-silent
block may be intentional content. The analyzer reports these measurements as
unknown for older traces, rather than treating absent counters as zero.
Fingerprints are computed from copied input PCM; PCM is not stored in the
log. Repeated fingerprints can reflect intentional silence or repeated content.
Driver closure is recorded so retained client totals are distinguishable from
currently active playback. Device chunk size is not end-to-end speaker latency.

Graphics records cover guest shader translation, guest Vulkan shader module
creation and the principal `vkCreateGraphicsPipelines` call. They include start,
end, duration, result and shader keys. In-flight counts expose operations that
have started but not returned. Other startup helper/compute paths are not covered.
Concurrent stage durations can overlap; summing them does not give elapsed stall
time. At most 512 detailed events are queued between reporter drains. Dropped
detail is counted, while aggregate operation counts/durations remain available.

All runtime events share a monotonic clock. The session header records its wall
time anchor for comparison with other logs. Counters are cumulative, sampled
about once per second, and read independently; a snapshot is not a transaction
across producer and callback threads. The first audio rate window may include
time before that client was registered. A truncated final JSON record is reported,
not silently treated as a complete shutdown sample.

The second analyzer describes queued host presents and observed guest output
changes. Neither those counters nor GPU guest-swap intervals measure simulation
speed, physical scanout or end-to-end input latency.

For a controlled buffering comparison, `--audio-max-queued-frames 16` overrides
only that child process's guest buffer limit. The SDK default remains 8 blocks;
8 and 16 represent nominal capacities of 42.667 and 85.333 ms at 48 kHz. Capacity
is not measured end-to-end latency. Compare the same screen and audio endpoint,
exclude shutdown silence, and check both breakup and perceived delay before
promoting a larger buffer. A larger buffer cannot repair invalid or repeated
source PCM. Use the current diagnostic candidate with the override omitted first.

## Audio-content candidate, October 10

`build/macos/audio-content-candidate/out/FIFA Street.app` retains the cache and
idle-overlay fixes and adds measurements only. `test-macos-audio-content.sh`
passes seven source-content checks, including signed zero and invalid values.
The software-only real SDL callback tests pass 20 checks with diagnostics off
and 30 with them on; recorder stress passes ThreadSanitizer, bundle verification
passes, and the persisted patch stack passes 20 checks.

In the 10,000-block software callback benchmark, measured thread CPU time was
1.097 microseconds/block with diagnostics off and 8.412 with them on. At 187.5
guest blocks/second, the difference corresponds to about 0.137% of one CPU core.
This measures this fixture and audio probes, not whole-game instrumentation cost.
No playback improvement is established by these diagnostics tests.

## Verification and initial overhead measurement

```sh
bash scripts/test-macos-runtime-diagnostics.sh
bash scripts/test-macos-codegen-barriers.sh
python3 scripts/verify-macos-memory-barriers.py build/macos/work/FifaStreetRex
```

The diagnostics test links the real SDK runtime and calls the real SDL callback
using software-only audio streams. It never opens an audio device or game window.
It checks stereo/5.1 BE planar conversion, zero/partial requests, starvation,
mute, and exactly one producer token per consumed block. The opt-out path passes
20 checks; the enabled path passes 28. JSONL checks cover common timestamps,
closed-client totals, concurrent stage counts, duplicate-finish prevention,
abandoned scopes and bounded event loss.

A separate ThreadSanitizer run exercises the production recorder with 20,000
producer/callback updates and 4,000 concurrent stage scopes while the reporter
samples active writers. It checks the recorder, not the rest of the game or SDK.

The packaged candidate passes the same callback/recorder checks and the real
runtime wait regression. Its bundle architecture, runtime provenance and guest
module loading are verified. The first 120-second live session,
`build/macos/logs/performance-check/20261010T001423.483623Z`, exited cleanly at
the scheduled limit. It recorded 7.137-second audio submission and 6.701-second
callback gaps, but these coincided with the scheduled stack sample: the reporter
also had a 7.499-second reporting interval. Treat that interval as potentially
affected by profiling, and omit stack sampling in the next comparison. The run
received the user's report that music and menu movement improved. This is one
manual observation, without a quantified input-latency measure or an exact
screen/phase timestamp. It does not establish playable matches or prove which
change caused the improvement.

The next run, `20261010T001829.574918Z`, used `--skip-stack-sample` and also
exited cleanly at the limit. The user reported poor music/menu movement again.
The maximum callback gap was 23.392 ms, while observed new game outputs averaged
1.266/s over the last 15 measured seconds. Regular audio block delivery does not
prove correct PCM or music; low output cadence persists without stack sampling.

The 10,000-block software fixture measured 1.202 microseconds of calling-thread
CPU per block with probes off and 7.084 with probes on. These numbers include
software queuing, conversion and draining; they exclude reporter-thread CPU and
are not hardware scheduling or gameplay measurements. Whole-game overhead still
requires a bounded off/on comparison. The SDL callback records lock-free atomic
counters; it performs no new file writes or session-lock acquisition. PCM
fingerprinting occurs on the producer side under the existing queue mutex.

Repeating this benchmark against the packaged candidate measured 1.280
microseconds with probes off and 6.956 with them on. The raw results are in
`build/macos/logs/runtime-diagnostics/candidate-tests/benchmark-*.txt`.

The generator regression previously failed all three PowerPC memory-barrier
checks. Its correction passes five emission and four ARM64 assembly checks.
The full guest audit found 31 `sync`, 393 `lwsync` and 29 `eieio` instructions,
each followed by the expected fence. This is evidence for the corrected code
generation, not evidence of improved music or menu responsiveness.

## Comparison discipline

The previous candidate remains at
`build/macos/performance-production/out/FIFA Street.app`. Its identity is saved
in `build/macos/logs/runtime-diagnostics/baseline-hashes.json`. The new candidate
uses a separate output directory. Both use the same owned game modules and copied
configuration. The SDK normally shares the player's user-data/cache directory;
cache warmth and save/menu state must be controlled or recorded when comparing
runs. Do not infer a barrier speedup from a cold-versus-warm loading comparison.

Use one behavioral change per comparison, keep the audio endpoint/settings
constant, and record whether each run reaches the same screen. Objective
starvation/timing data plus the player's audible/menu observations are required
before selecting another fix. See [MACOS-RUNTIME-RESEARCH.md](MACOS-RUNTIME-RESEARCH.md)
for the pinned stack and primary upstream references.


The October 10 frame-correlated run (`20261010T003649.880885Z`) reached the main
menu but remained too slow. Across 3,761 completed guest submission scopes,
the combined queue-acquisition/driver-call path accumulated 93.997 s wall time
versus 0.422 s calling-thread CPU time. Principal guest GPU timestamp spans had
median 0.477 ms and p95 4.266 ms; those spans exclude other GPU work. This locates
a major host-side wait but does not establish its exact cause. A separate refined
candidate adds queue-lock and principal driver-call timings; it is built and
verified, **not live tested**. See [MACOS-FRAME-DIAGNOSTICS.md](MACOS-FRAME-DIAGNOSTICS.md)
for collection semantics, tests and evidence locations. No usability fix is claimed.

The refined probe run `20261010T005303.522510Z` is now complete: main menu, still
slow, clean time-limit exit. It attributes the large host delay to the shared
queue mutex: principal guest API calls totaled 0.388 s; recorded long queue
acquisitions on GPU Commands totaled 101.638 s, with 99.77% overlap with presenter
submission calls holding that same queue. Twelve detailed stage events were lost;
aggregate totals remain available. A per-process asynchronous MoltenVK comparison
is prepared; changing submission mode is an experiment, not a verified fix.
See the frame diagnostics document and that session's `evidence.md`.

The same-app asynchronous comparison `20261010T005701.200429Z` exited cleanly.
The user reported smoother progression to the main screen and slightly better
music, with persistent menu audio lag. Whole-run new outputs rose from 4.06/s to
5.90/s, but the final windows remained below 1/s. Queue acquisitions fell to
3.962 ms total; guest fence waits rose to 112.776 s, all recorded long guest
waits labeled Resolve. The setting removes host mutex contention while moving
waiting to resolve completion. Pipeline/cache and manual phase timing confound
the whole-run rate comparison; audio callback delivery also had a larger gap.
No permanent app default is changed and no end-to-end fix is claimed. Both raw
sessions and comparison evidence are preserved; next work targets presentation
and resolve-completion serialization with correctness intact.
