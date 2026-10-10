# macOS runtime inventory and performance research

> Historical methodology and experiment record. Current status and all
> consolidated findings are in [LOG/PROGRESS.md](../LOG/PROGRESS.md). Normal
> install/play instructions are in [BUILDING-MACOS.md](BUILDING-MACOS.md).

Checked 2026-10-10 against this checkout and primary upstream sources.

## What we actually run

The game is statically recompiled: Xbox 360 PowerPC instructions become generated
C++, which Apple Clang compiles into native ARM64 Mach-O executables and guest
module dylibs. ReXGlue supplies the Xbox kernel, threading, memory, filesystem,
graphics, audio and input compatibility services. This is the architecture
described by the [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk), confirmed
locally by `scripts/build-macos.sh` and the generated build's Ninja rules.

We can modify the host wrapper, SDK, generator, startup hooks and generated code.
We do not have EA's original source project. The original executable modules and
assets are supplied separately; see [BUILDING-MACOS.md](BUILDING-MACOS.md).

| Layer | Locally verified implementation/version |
|---|---|
| Build | CMake + Ninja; C++23; Apple Clang 21.0.0; ARM64 Release game build |
| SDK | ReXGlue `c94f5ebdcb3c9d1a460ca48e04f9758448f8d518`, v0.10.0 release commit, with project patches |
| CPU/vector translation | Generated PowerPC C++; SIMDe 0.8.2, `71fd833d9666141edcd1d3c109a80e228303d8d7` |
| Graphics | Xbox Xenos → ReXGlue Vulkan backend → bundled Vulkan loader → MoltenVK → Metal/CAMetalLayer |
| Vulkan headers | 1.4.357, `e3b1eec08173d6b825cd3ac88c885a63b621504a` |
| Vulkan loader | 1.4.357 source project, `5f157b62e333c63260d05d81bf66faa216ab0fb8` |
| MoltenVK | 1.4.1 API header/runtime artifact, `db445ff2042d9ce348c439ad8451112f354b8d2a` |
| Window/input/audio | SDL3 development version 3.5.0, `8bf3b7215ad9fc3deb583c6a3a37c6c67f2e24e4`; Cocoa/CoreAudio backends enabled |
| Codec support | Xenia FFmpeg fork, `0604b464c7cb4ebc94940cf1f324a3b26b87717c`; avcodec/avutil for the SDK's XMA path |
| Diagnostics | Tracy 0.13.1, `05cceee0df3b8d7c6fa87e9638af311dbabc63cb`; perf counters, host present timings, thread sampling |

Direct3D 12 is off on macOS. The tested process and its guest dylibs are native
ARM64; this launch does not use Wine, CrossOver or Rosetta. SIMDe compatibility
does not by itself establish how efficiently each guest vector operation runs.
Codec support does not establish which codec is responsible for the audible issue.

Version checks: `git -C ReXGlue submodule status`; SDL's CMake version;
`thirdparty/moltenvk/MoltenVK/MoltenVK/API/mvk_private_api.h`; Vulkan's
`vulkan_core.h`; and the generated game's `CMakeCache.txt`.
The local configure also discovers Homebrew VulkanHeaders package metadata
1.4.363 and warns about it. The generated game compile rules use the SDK's
vendored header include directory. Package-discovery metadata and actual include
paths must be distinguished; the warning alone does not prove a runtime defect.

## Findings that justify focused work

### Guest memory barriers were discarded: reproduced and corrected in the generator

The pinned `src/codegen/builders/system.cpp` treated `sync`, `lwsync` and `eieio`
as no-ops. These instructions occur in the actual game's generated modules.
Upstream corrected their fence emission on October 2 in
[commit bd833a2](https://github.com/rexglue/rexglue-sdk/commit/bd833a2ab69d305f99ddf57418fc38ffec8af93d).
Apple explains that different memory ordering can expose concurrency defects
when moving Intel code to ARM64, and recommends runtime race detection in
[its porting guidance](https://developer.apple.com/videos/play/wwdc2020/10214/).

We added a synthetic PPC fixture using the real SDK decoder and code writer:

```sh
bash scripts/test-macos-codegen-barriers.sh
```

Before: 2/5 checks passed; all three barriers failed. After the narrow backport:
5/5 emission checks pass. Four additional ARM64 assembly checks confirm one
`dmb ish` in each original barrier function and none in the `nop` control.
The persisted change is in `patches/rexglue-macos-portability.patch`; the patch
sequence regression passes 20/20. Logs and generated fixtures are under
`build/macos/logs/codegen-barriers/`.

This is a demonstrated code-generation correctness defect. It is not evidence
that missing barriers caused the measured loading stalls or distorted music.
The game has now been regenerated, rebuilt and packaged as a separate candidate
under `build/macos/runtime-diagnostics-production/out/`. All 453 emitted barrier
instructions pass the build audit (31 sync, 393 lwsync, 29 eieio), and the startup
hooks, artifact architecture/dependencies and bundled guest-module loading are
verified. The first 120-second live check exited cleanly, and the user reported
improved music and menu movement. This is one manual observation, without a
controlled comparison that isolates the fence change. A pause coincided with
stack sampling; performance comparisons should omit that potential confound.
An immediate rerun without stack sampling received a poor music/menu report:
observed new output averaged 1.266/s in the last 15 measured seconds, despite
regular audio callbacks (largest gap 23.392 ms). The first report's improvement
is not consistently reproduced, and the cause remains unresolved.

Upstream also changed store-conditional atomics in
[commit 7f7c92e](https://github.com/rexglue/rexglue-sdk/commit/7f7c92ef62a13b6aea66ab3f55a6803c4ae1f2f6).
We have not backported that separate change. It needs its own tests of reservation,
endianness and condition-register behavior before adoption.

### Audio needs sample-content and starvation measurements

The driver uses 256 sample frames per block at 48 kHz: a nominal 5.333 ms of
audio per block. `SubmitFrame` queues guest PCM; the SDL callback consumes it,
converts/mixes channels, and inserts zeros when the queue is empty. See
`ReXGlue/src/audio/sdl/sdl_audio_driver.cpp`.

SDL's [callback contract](https://wiki.libsdl.org/SDL3/SDL_AudioStreamCallback)
uses byte requests, which can vary with resampling. Its
[queued-data API](https://wiki.libsdl.org/SDL3/SDL_GetAudioStreamQueued)
reports input bytes, not converted output or physical speaker latency. Thus our
metrics must label their format and distinguish submitted audio, consumed audio,
inserted silence and device buffering.

The SDK already includes the earlier
[audio timer fix, PR #403](https://github.com/rexglue/rexglue-sdk/pull/403).
That Windows investigation found repeated PCM despite plausible submission
counts. Its diagnosis is a useful measurement example, not proof of the same
cause on this Mac. Our initializer already omits the offending timer override.

Next probe: timestamp submission and consumption, count inserted-silence sample
frames, measure callback/producer gaps and queue depth, and compare bounded PCM
fingerprints for repetition. Repeated or silent samples can be intentional, so
fingerprints need interpretation alongside playback phase and timing.
Use counters published outside the callback; avoid synchronous per-block logging
on the audio path. Add deterministic tests for partial requests, silence,
conversion and token release before changing queue behavior.

These probes are now implemented behind `RESTREET_PERF_DIAG` and verified with
software-only streams calling the real SDL callback: 20 checks pass with the
gate off and 28 with it on. A focused ThreadSanitizer recorder stress run passes.
The packaged candidate also passes these tests. See
[MACOS-PERFORMANCE-DIAGNOSTICS.md](MACOS-PERFORMANCE-DIAGNOSTICS.md) for collection,
analysis, CPU-overhead measurements and their limits.

### Graphics pipeline compilation is a measurable candidate

The principal pipeline creation path in
`ReXGlue/src/graphics/vulkan/pipeline_cache.cpp` passes `VK_NULL_HANDLE` as the
Vulkan driver cache. The SDK does cache guest shaders and pipeline objects;
those caches are distinct from a driver's serialized `VkPipelineCache`.

[Khronos' pipeline guidance](https://github.khronos.org/Vulkan-Site/samples/latest/samples/performance/pipeline_cache/README.html)
describes compilation costs and cache reuse. The
[MoltenVK guide](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md#shader_load_time)
also describes storing converted shaders through Vulkan pipeline caching.
This supports investigating compilation, not assigning every long frame to it.

Next probe: measure wall time around shader translation and native pipeline
creation, with counts and a common monotonic timestamp. Compare cold and warm
runs of the same loading path. Adopt a driver cache only if measurements justify
it, with device/driver compatibility, concurrency and invalid-data tests.
Changing async flags can skip incomplete guest frames, so it is not a reliable
standalone test of improvement.

The candidate now contains the timing probes and an independent one-second
reporter. Software fixture records verify shared timestamps, concurrent stage
counts and explicit bounded-event loss. Native Vulkan call costs during the
game's loading path still require the manual session; no driver-cache or async
behavior change has been made.

## Baseline and acceptance

The last bounded manual session is documented in
[`performance-check/.../evidence.md`](../build/macos/logs/performance-check/20261009T232444.934520Z/evidence.md).
It showed repeated host presentation, long gaps between new guest outputs and
poor music/menu responsiveness reported by the user. The process exited normally
at the scheduled time limit. The screen transition after Info was not timestamped;
we cannot yet attribute a specific measured interval to that transition.

Host present rate is not simulation speed. Guest GPU swap intervals are not an
audio clock. Wall stack samples are not CPU-time percentages. The existing idle
wait regression proves reduced waiting-thread CPU use, while the user's live
check establishes that the overall symptoms persist.

Order of work: the baseline is retained, the backport's game build is complete,
and the audio/pipeline probes and controlled tests pass. Next compare a bounded manual run
with the same assets, settings and audio endpoint. Keep one behavioral change per
comparison. The game remains closed, and no window automation or virtual input
is used. A usable port requires responsive menus, stable music, a complete match,
save/reload, controls and window behavior, followed by a clean reproducible build
and packaging check. None of those unverified outcomes follows from compile success.


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


### Pipeline stalls and persistence

The local full-host trace contains a 10.848-second command batch with 10.740
seconds of nested graphics pipeline creation. The native shader/pipeline-file
loader also has a reproduced Darwin append-read position defect; see the frame
diagnostics document and `test-macos-shader-storage.sh`. Correct cache reload is
the first targeted fix before introducing a second cache format.

MoltenVK's [runtime guide](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md)
recommends Vulkan pipeline cache serialization to retain converted MSL.
Its pinned 1.4.1 source serializes MSL and shader conversion configuration;
this is not evidence that serialized data eliminates all Metal pipeline
compilation. The guest backend currently passes `VK_NULL_HANDLE` to
`vkCreateGraphicsPipelines`. A future native driver cache could reduce conversion
work, but must be measured separately from restoring existing pipeline preloading.
The Vulkan [pipeline cache guide](https://docs.vulkan.org/guide/latest/pipeline_cache.html)
provides the supported cache object path; cache identity, persistence and lifecycle
must be validated before adopting it.


### October 10 source audio and native fence follow-up

The content diagnostic run `20261010T100957.527778Z` recorded slight audible
breakup, yet zero backend-inserted silence and no invalid/out-of-range source
samples. Non-silent repeats appeared only around elapsed 23-25 seconds. The later
source counters do not support repeated music as the explanation. Source silence
can still be intentional or an upstream gap; this probe does not measure physical
output continuity. The SDL get callback requests input-format bytes and permits
overdelivery, so the driver's block rounding remains consistent with the
[official callback contract](https://wiki.libsdl.org/SDL3/SDL_SetAudioStreamGetCallback).

A headless native MoltenVK experiment compared immediate full fence blocking
with status polling for up to 200 microseconds before the same completion wait.
Four alternating-order rounds per mode verified all 8,100 GPU-written 4 KiB
readbacks. The mean of round-average wait times was 247.314 microseconds blocking
and 291.273 with polling; caller CPU time averaged 9.557 versus 208.639
microseconds per operation. Thus short polling remains disabled. The workload is
a small serial fill, not a game frame; it cannot predict whole-game FPS. Source,
runner, raw logs and analysis are `scripts/fence-wait-benchmark.cpp`,
`scripts/benchmark-macos-fence-wait.sh` and `build/macos/logs/fence-wait-benchmark/`.

Next distinguish guest render-thread work from busy waiting with a bounded CPU
profile. Mark the sample interval separately because sampling can cause a hitch.
Do not turn aggregate fence/register-wait durations into an elapsed stall total,
and do not remove guest completion waits merely because native GPU spans are short.


### Mac clock contention and fractional-tick loss

The CPU profile `20261010T101809.575426Z` observed frequent guest timer
queries on Main XThread and shared clock-mutex blocking on EAAudioCore Dac.
The scheduled sample started at elapsed 60.5 s; the human confirmed the main
menu at about 69.2 s, so its exact phase is uncertain. Sample counts represent
wall-stack observations, not CPU fractions. RenderThread has a separate hot
guest path through `sub_82713710` / `sub_826FCC30`.

A public-runtime fixture (`scripts/benchmark-macos-clock.sh ... --check-rate`)
reproduces nominal 1x time running at roughly 0.96–0.98 of the host rate with
many clock queries. The old implementation repeatedly floors each short host
delta at the 50 MHz guest / 24 MHz host ratio, discarding fractional ticks, and
shares a mutex between all readers. The existing bypass preserves rate and the
human reported better music in run `20261010T102447.092264Z`, but later observed
output cadence did not improve. Bypass also changes clock origin and disables
time controls, so it is a diagnostic comparison rather than the final fix.

The replacement is Mac-only: a host/guest anchor and rational conversion make
elapsed time independent of read count. All snapshot fields are atomic; rare
config changes serialize under a writer mutex and invalidate readers before
sampling the rebase time. Successful reads acquire no mutex, and an interrupted
read falls back to the mutex instead of spinning while a writer is descheduled.
This uses the atomic-payload sequence-lock ordering described in
[Abseil's implementation](https://github.com/abseil/abseil-cpp/blob/master/absl/flags/internal/sequence_lock.h).
Scalar quantization remains unchanged. Rebasing may round away less than one
guest tick per configuration change, rather than per clock read. Ordinary
64-bit multiplication is used where it fits, with a checked 128-bit fallback.

`scripts/test-macos-guest-clock.sh` checks exact 25/12 conversion, read-count
independence, continuity across scalar/frequency changes, guest wall time,
wide products, interrupted reads and eight readers against a changing writer.
Both ordinary and ThreadSanitizer runs pass. Public runtime API tests exercise
0.5x/1x/2x rates, durations, uptime and system-time controls. The elapsed-rate
regression now passes at both one and eight readers. These tests prove clock
behavior; audible improvement and game FPS require another manual run.

Candidate: `build/macos/guest-clock-candidate/out/FIFA Street.app`. Tests,
provenance and results: `build/macos/logs/guest-clock/`. The launcher still
selects the previous playable cache candidate unless given this path explicitly.


The anchored-clock manual run `20261010T103730.761417Z` is complete. The user
confirmed improved main-menu music and movement with the bypass off. The game
closed cleanly at the 120-second test bound. Backend-inserted silence and invalid
source samples remain zero, and clock-rate/concurrency tests pass. Confirmed late
menu output cadence is still about 24.6 new outputs/s; this does not establish
60 FPS. RenderThread remains near one full core. Next profile its guest loop and
resolve-completion waits before altering synchronization. Full evidence and
comparison caveats are in the run's `evidence.md`; the new timer still needs a
match check before replacing the existing interactive default.
