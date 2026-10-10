# macOS frame and thread measurements

> Historical methodology and experiment record. Current status and all
> consolidated findings are in [LOG/PROGRESS.md](../LOG/PROGRESS.md). Normal
> install/play instructions are in [BUILDING-MACOS.md](BUILDING-MACOS.md).

These probes distinguish slow frame production, GPU command processing/waits,
and output handoff. They do not automatically identify game screens or measure
physical key-to-speaker/display latency. They are diagnostic tools, not a
performance fix. Game code/configuration and the previous app are preserved.

## Collection

```sh
python3 scripts/run-macos-performance-check.py \
  --app "build/macos/frame-diagnostics-refined/out/FIFA Street.app" \
  --frame-diagnostics --seconds 120
```

`--frame-diagnostics` enables the JSONL runtime recorder, existing Vulkan GPU
timestamp queries, and disables external stack sampling. The run ends at its
bounded limit. The player controls the window manually. Record the screen,
music and W/S responsiveness, and approximate phase transition times. Compare
the same candidate with `--runtime-diagnostics --skip-stack-sample` to omit GPU
queries, or with only `--skip-stack-sample` to disable all new recorder probes.
Cache state, selected audio device, screens and manual actions must be matched
before attributing a change to instrumentation. Config and game-data files are
unchanged; the first instrumented run is not a controlled overhead comparison.

## Shared host clock and identity

`runtime.jsonl` contains the session's steady-clock and Unix anchors. All host
markers and operation durations use that steady clock; CPU time uses the calling
thread's CPU clock. GPU timestamps remain in a separate device clock domain.
Only GPU *durations* are reported; they are never treated as host timestamps.

| Marker | Identifier / meaning |
| --- | --- |
| `guest_swap_written` | `key1`: physical address of the swap signature; `key2`: front buffer. The guest has written a swap packet, but may not have submitted it yet |
| `swap_processed` | `key1`: same signature address; `key2`: GPU command processor's swap counter plus one. This is packet arrival at the processor, before `IssueSwap` |
| `output_published` | `key1`: presenter output sequence; `key2`: current processed swap ID, or zero when unassociated. Recorded immediately after mailbox release |
| `present_queued` | `key1`: output sequence; `key2`: presenter submission index. Successful/suboptimal queued presents, including repeats |
| `submission_queued` | `key1`: principal guest GPU submission index; `key2`: command processor swap counter plus one. Accepted by `vkQueueSubmit` |
| `completion_observed` | `key1`: latest guest submission observed complete; `key2`: number retired. This is later than or equal to actual completion |
| `gpu_duration` | `key1`: guest submission; `key2`: top-to-bottom timestamp span in nanoseconds. Covers the principal guest command buffer, not all presenter/GPU work |
| `gpu_query_status` | Query creation/read failure; `result`: actual Vulkan return code. Missing/unavailable timing is not zero GPU work |
| `gpu_capabilities` | `key1`: timestamp valid bits; `key2`: wrap mask; `value`: timestamp period in picoseconds; `result`: unsupported if valid bits are zero |

Addresses are matched FIFO per physical address, not across arbitrary counters.
Output sequence IDs and swap IDs are separate namespaces. Record loss and
unmatched boundaries remain explicit. A host consumer can race the publication
marker; the analyzer flags that race instead of inventing a positive latency.

## CPU scopes and thread accounting

Scopes cover command batches, waiting for guest commands, register waits, swap
packet creation, `IssueSwap`, output refresh, ending submissions, principal queue
submission, guest fence waits, host painting/presentation and presenter fence
waits. `stage_summary` retains all counts, wall time, CPU time, active scopes and
maximum duration. Detailed new-stage events under 1 ms are filtered; existing
shader detail is retained. Completed long operations carry a thread ID and keys.
Scopes nest and overlap: **never add their totals to estimate a frame**.
`DurationScope` records every return path; its result zero means scope completion,
not function success. API scopes carry the real return status.

`queue_submit` covers the original combined queue acquisition and guest submission.
The refined candidate adds `queue_acquire` around the actual shared queue mutex
acquisition, plus `guest_submit_call` and `host_submit_call` around principal
`vkQueueSubmit` calls after acquiring that lock. The queue handle identifies the
shared queue; thread IDs distinguish callers. Other helper/fence-only submissions
are not covered by the principal API scopes, though their queue acquisition is
measured. These additions change measurement, not synchronization policy.

Every second the reporter uses `task_threads` and `thread_info` on its own process
to read cumulative per-thread user/system CPU time and names. It does not suspend
threads or walk stacks. Each row is timestamped at its observation. CPU deltas
are calculated only between two observations of the same stable Mach thread ID;
100% corresponds to one logical CPU. Work outside that interval and very short
lived threads may be absent. Collection status, failures and duration are logged.
Mach ports and returned arrays are released each collection. See Apple's
[task_threads](https://developer.apple.com/documentation/kernel/1537751-task_threads)
and [thread_info](https://developer.apple.com/documentation/kernel/1418630-thread_info).

GPU query results are read after existing completion checks, without a query wait
flag or any additional game GPU wait. Period and valid bits determine conversion
and wrap handling, per the [Vulkan query specification](https://docs.vulkan.org/spec/latest/chapters/queries.html).
Submission-to-observed-completion includes queue residence, execution and polling
delay; it must not be described as GPU execution duration.

## Tests and analysis

```sh
bash scripts/test-macos-frame-diagnostics.sh
bash scripts/test-macos-gpu-timestamps.sh
bash scripts/test-macos-runtime-diagnostics.sh
python3 scripts/analyze-macos-frame-diagnostics.py <session-directory>
python3 scripts/analyze-macos-runtime-diagnostics.py <session-directory>
python3 scripts/analyze-macos-performance.py <session-directory>
```

The frame fixture tests disabled/enabled recording, nested frame context,
reused physical address correlation, repeats, delayed handoffs, CPU busy versus
sleeping threads, contention on the actual queue mutex separated from a simulated
driver wait, bounded event loss, malformed/truncated records and publication
marker races. It tests recorder/analyzer behavior, not game correctness. The
GPU fixture exercises the packaged loader/MoltenVK with a 2 MiB buffer fill,
bounded fence wait, capability checks and a nonwaiting query result read. It
creates no window and runs no game. On this M5, timestamp support is 64 bits at
1 ns/tick; the first fixture measured a 0.041 ms GPU span versus 62.175 ms from
host submission to result retrieval. Those are distinct measurements, not
interchangeable clocks or representative gameplay costs.

Existing real SDL callback checks and focused recorder ThreadSanitizer stress
remain required. In the CPU fixture the busy thread measured 99.06%, the sleeping
thread 0%, and maximum collection time was 46 microseconds. These fixture values
do not establish whole-game overhead. Detailed stage and point queues are bounded
at 512/4096; separate cumulative drop counters identify incomplete trace detail.

## First live trace and next candidate

The first-trace candidate (`frame-diagnostics-production`) ran for a bounded
120 seconds without external stack sampling. The user reached the main menu and
reported it was still too slow. New output averaged 4.1375/s over measured windows;
last-window rates were 0.4–1.6/s. Across 3,761 completed guest submission scopes,
the combined queue-acquisition/API path consumed 93.997 s wall time but only
0.422 s calling-thread CPU time. Principal guest GPU spans had median 0.477 ms
and p95 4.266 ms. These observations locate a major host-side wait but do not
establish whole-device utilization or distinguish the mutex from the driver.

Full evidence and raw analyses are in
`build/macos/logs/performance-check/20261010T003649.880885Z/`.
The exact original patch is saved as
`build/macos/logs/frame-diagnostics/portability-first-trace.patch`.
The current patch and `frame-diagnostics-refined` candidate add the lock/API
split. Its live results follow below.

## Shared-queue contention captured

The refined run `20261010T005303.522510Z` reached the main menu with a still-slow
manual report. Principal guest driver submission calls totaled 0.388 s, while
all queue acquisitions totaled 101.977 s wall time. Of 101.638 s in recorded
long acquisitions on the GPU Commands thread, 99.77% overlapped principal
presenter API submission calls holding the same queue mutex. Twelve detailed
stage events were dropped; aggregate counts remain intact and the overlap applies
only to recorded intervals. This identifies host queue contention, with the
presenter's exact driver-internal wait still unmeasured.

A reversible comparison on the same app is available:

```sh
python3 scripts/run-macos-performance-check.py \
  --app "build/macos/frame-diagnostics-refined/out/FIFA Street.app" \
  --frame-diagnostics --moltenvk-submit-mode asynchronous --seconds 120
```

The mode applies only to the launched process and is recorded in `setup.json`.
`inherit` is the default; `synchronous` explicitly selects value 1 for a later
controlled comparison. No app default or global environment is changed.
Supported behavior is documented by [MoltenVK](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Configuration_Parameters.md).
The bundled library's global configuration and headless GPU query fixture pass
with asynchronous mode. A live/manual comparison is needed to establish benefit;
lock waits may move to driver queue/fence stages.

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

## Immediate host presentation experiment: stability failure

The opt-in `--macos-unpaced-present` experiment changes only the host's present
mode selection, leaving guest `vsync=true`, guest timers and Full resolve
readbacks intact. The SDK cvar defaults to false; unsupported/prohibited
IMMEDIATE falls back to FIFO. The actual selection helper passes 12 checks,
including a red run before the change; those checks establish selection
behavior, not game stability or a performance fix.

Candidate `unpaced-present-candidate`, session `20261010T010803.079911Z`,
selected IMMEDIATE with asynchronous submission, then crashed with SIGSEGV
after 18.125 seconds. The user reported no main-menu arrival. The native report
preserves an asynchronous MoltenVK queue stack copying a presentation callback
(`_Block_object_assign` / `presentCAMetalDrawable`). Drawable lifetime is a
hypothesis; the original fault address was obscured by signal re-raising.
This candidate is not promoted. The preceding app remains available.

The short startup trace cannot establish a speedup against full menu runs.
Audio also selected earbuds instead of the earlier MacBook speakers, so it is
not a controlled audio comparison. Raw trace, analyses, crash report, hashes
and limitations are saved in the session's `evidence.md`.

`scripts/test-macos-presentation-stress.sh` creates its own small native
diagnostic window and exercises the packaged Vulkan loader/MoltenVK with three
submission slots, per-image presentation semaphores and actual image clears.
It never operates the game or sends input. This is a driver-path smoke/stress
test, not yet a reproducible test of the game's crash. Use the process-only
`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0` or `1`, with `immediate` or `fifo`:

```sh
MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 \
  bash scripts/test-macos-presentation-stress.sh \
  build/macos/unpaced-present-candidate/out/vulkan immediate 30
```

The synchronous/immediate game comparison `20261010T011649.089557Z` completed
120 seconds cleanly. The user reported much smoother startup, with janky main
menu, broken voice/music and slow key responses. New outputs averaged 10.10/s,
but the final windows remained around 1–2/s. Host presents averaged 172.23/s,
mostly repeats; completed host submit calls totaled 118.44 s while all queue
acquisitions totaled 85.23 s. These overlapping scopes cannot be added.
13,977 detailed stage records were dropped; aggregate totals and frame points
remain available. Both immediate comparisons used earbuds. This surviving run
narrows the crash hypothesis but does not establish its cause or absence.

## Idle achievement overlay redraw experiment

`ReXApp` creates an achievement notification dialog at launch. It remains in
ImGui's registered dialog list even with an empty toast queue; the original
drawer requests another UI paint whenever that list is nonempty. Thus an
invisible notification can drive repeated host presentations independently of
new guest frames. This is a source-level cause of unnecessary redraw requests;
its contribution to full game slowness requires a live comparison.

`macos_idle_toast_sleep=true` (wrapper: `--macos-idle-toast-sleep`) makes the
toast request continuous repaint only while its queue contains notifications.
Ordinary dialogs retain their existing repaint policy. macOS notification
delivery is deferred onto the UI thread using weak ownership, then explicitly
wakes the window, so an idle toast still appears and queued delivery is cancelled
if its owner is destroyed. The new policy defaults off. Guest timing, readbacks
and fence ordering are unchanged.

The real packaged runtime integration test substitutes only the platform window
and GPU drawing, exercising toast -> ImGui -> Presenter -> Window scheduling:

```sh
bash scripts/test-macos-idle-toast.sh build/macos/idle-overlays-candidate/out
```

Before the fix it failed: `empty toast schedules another host present`.
After the fix it verifies idle suppression, ordinary dialog repaint, notification
wakeup from a guest thread, active animation, expiry back to idle, default-off
behavior and cancellation after owner destruction. This locks down the redundant
repaint defect; it is not a test proving game frame rate or audio usability.


## Hidden exit overlay and consumer rebuild

The idle-toast game run remained janky. A subsequent 45-second paint-origin
trace (`20261010T090751.849750Z`) recorded 9,211 custom paint events and only
one exposed event. Every UI repaint decision had two registered dialogs and
continuous repaint enabled. No toast policy records were reached because the
first continuous dialog short-circuited the scan. Source inspection and a failing
integration test identified the permanently registered, hidden exit confirmation
as another requester. The trace rules out an expose-event storm for this run.

`macos_idle_exit_overlay_sleep=true` (wrapper: `--macos-idle-exit-sleep`)
makes the exit overlay request continuous repaint only while open. The input
system posts a deferred UI wake on the real shortcut edge. Startup and teardown
now own the overlay on the UI thread; deferred work holds a weak dialog reference.
Cancel releases guide capture and re-arms the shortcut immediately, since idle
redraw no longer supplies a later cleanup pass. The policy defaults off.

The runtime integration fixture failed before both the scheduling fix and the
cancel cleanup fix. It now verifies closed-idle behavior, guest-thread shortcut
wakeup, open-dialog repaint/capture, cancellation, pending-wake teardown, and
actual confirmation exit in a separate fixture process. This drives the actual
SDK input/overlay/presenter/window chain with a fake controller and platform
renderer, without sending any input to the game. Logs are under
`build/macos/logs/frame-diagnostics/idle-exit-red.log`,
`idle-exit-controls-red.log`, and `idle-overlays-green.log`.

**Build correction:** `src/ui/rex_app.cpp` is compiled into the consuming host
executable, not the runtime dylib. Earlier idle-toast and paint-origin candidates
replaced only dylibs and therefore omitted the deferred-notification startup
change. They remain partial diagnostic artifacts; they must not be promoted.
The `idle-overlays-candidate` rebuilds and packages the host plus both SDK dylibs.
Its host references the new exit startup/teardown APIs, with hashes recorded in
`idle-overlays-provenance.json`. Guest configuration is unchanged. Bundle checks,
20 patch-stack tests and frame-recorder checks pass; live usability still requires
measurement and the user's observations.


The full-host idle-overlays run `20261010T092816.972034Z` completed cleanly.
The user reached the main menu and reported improved music and movement.
Repeated presents fell from 20,101 to two, queue acquisition wall time from
72.600 s to 0.145 s, and audio silence insertion from 0.885% to zero on the
same earbuds endpoint. Most late windows delivered 23–25 new outputs/s instead
of roughly 1–2/s. The final window had an 11.162-second output gap; its screen
boundary was not recorded. Frame points lost 1,702 records, but detailed stage
events lost zero and aggregate totals remain available. This is a verified
scheduling improvement, with gameplay and repeat-run stability still unverified.
The test time limit closed the game before a match was started. Raw data and
comparison caveats are saved in that session's `evidence.md`.


## Cache reload defect behind repeated compilation

Detailed pipeline spans account for 99.01% of the longest 10.848-second GPU
command batch in `20261010T092816.972034Z`: roughly 10.740 seconds in graphics
pipeline creation. This attributes the late pause to compilation, separately
from the steady frame-rate limit.

The loader opened both persistent shader and pipeline-description files with
`a+b` and immediately read their headers. Darwin's initial read position is the
end of an existing append-read file. A test using the actual SDK `OpenFile`
returned `initial_position=4; header_read_count=0; expected=1`. The loader thus
mistook populated cache files for invalid headers and took its reset path.

Both files now use `OpenShaderStorageFile`, which seeks to the beginning before
reading and still appends writes. The actual helper test failed before the fix
and passes header/record reload, append preservation, second-open persistence,
and invalid-path rejection afterward:

```sh
bash scripts/test-macos-shader-storage.sh
```

Evidence and backups of the previous caches are under
`build/macos/logs/shader-storage/`. The `shader-cache-candidate` carries the fix
and the previously verified arrow-key profile. Builds, package verification and
20 patch-stack tests pass. Live checks must confirm preload hits and remaining
frame pacing; a passing cache test does not prove sustained 60 FPS. Compilation
of previously unseen shaders can still stall, and preload moves work into startup.


## Cache-fixed gameplay report and audio follow-up

The restart `20261010T095318.756591Z` loaded all 79 persisted graphics pipelines.
The user reported usable gameplay with remaining audio breakup and requested
further optimization before keymapping. The game stopped at the user's request
after 278.455 seconds, exit code 0, without forced termination. The wrapper's
exit 130 records the interruption; it is not a game crash.

Nine inserted-silence blocks precede shutdown, while 27 more occur in the final
shutdown window. The producer's largest gap was 41.284 ms and the audio callback's
23.761 ms against a nominal 21.333 ms device chunk. These shortages alone do not
explain the reported distortion. Earlier fingerprint counters combine silent and
non-silent repetitions, so they cannot establish repeated music.

Frame windows between elapsed 100 and 270 seconds show about 17-23 published
outputs/s. Screen/phase timestamps were not recorded and 160 frame points were
dropped; these are output cadence measurements, not sustained gameplay FPS.
New pipelines still compile: total creation time 7.469 seconds across 121 calls
includes cache preload, with a maximum individual call of 1.300 seconds.

The new `audio-content-candidate` adds opt-in non-silent repetition, numerical
silence, invalid-value and source-range counters without changing playback.
See MACOS-PERFORMANCE-DIAGNOSTICS.md for the tested candidate and collection limits.
Raw measurements and manual observations remain in the session's `evidence.md`.
