# ReStreet macOS — progress, findings and diagnostics

Last updated: 11 October 2026. This is the consolidated engineering record for
[fyzanshaik's Mac fork](https://github.com/fyzanshaik/fifa-street-pc-port/tree/main)
of [SamuelitoDaVila's ReStreet](https://github.com/samuelit0davila/fifa-street-pc-port).
Read this before resuming optimization. The original Windows work and licenses
are credited in [README.md](../README.md).

## Outcome and current direction

We started with a Mac-only machine, a game that could not reliably build/boot,
black-screen reports, an unresponsive autosave prompt, severe menu delay and
broken-sounding audio. The native port now reaches matches. Latest owner
feedback: gameplay is good/everything fine; the rebuilt normal-clock menu has
improved music and movement. Further optimization is paused in favor of a
reproducible install/play path, keyboard controls and a durable handoff.

The longer-term objective is human-versus-AI and AI-versus-AI agentic benchmarks.
The experimental local control/capture seams are groundwork, not completed model
evaluations. We have not integrated JEV, OpenAI or another decision API into a
validated match/evaluation pipeline.

This is a source-build Apple Silicon preview. It is not the original EA source;
it recompiles supported original Xbox binaries into native guest code, linked to
our host/runtime. Save/reload, every mode, multiple controllers, background/display transitions,
Intel Macs and sustained 60 FPS remain incompletely validated. Latest late
main-menu measurements are about 25 new displayed outputs/s, not proof of 60 FPS
or a measurement of simulation tick rate. Good gameplay is a human observation,
not an unattended full-match regression suite.

## Technology and reproducible inputs

| Component | Role / constraint |
|---|---|
| ReXGlue SDK | Recompilation, guest runtime, kernel/input/audio/graphics; pin `c94f5ebdcb3c9d1a460ca48e04f9758448f8d518` |
| Generated C++ guest code | Derived locally from the owner's original XEX modules; never committed |
| C++23 / AppleClang | Native host, runtime and guest code; AppleClang 16+ or LLVM Clang 18+ |
| CMake + Ninja | SDK and consumer builds, Mac presets and artifact staging |
| Vulkan + MoltenVK | Xenos translation and host presentation through Metal; bundled SDK dependencies, not Homebrew Vulkan |
| Cocoa / SDL3 | Native window, physical/keyboard controller input and host audio |
| Xbox audio format | Guest planar big-endian float32, 256 frames × 6 channels, 48 kHz |
| Runtime diagnostics | Opt-in JSONL, stage timings, source audio counters, thread CPU and principal-GPU timestamp spans |
| Test machine | Apple M5 MacBook, arm64, 16 GB RAM, macOS 26.6.2; results do not establish compatibility with every Mac |

The exact three supported module hashes are in
[`scripts/supported-macos-inputs.json`](../scripts/supported-macos-inputs.json).
Guest-address hooks make a revision guard essential. Other regions/revisions are
rejected, not silently recompiled at wrong addresses. No game data is published.
The bundle links to the owner's extracted GameData and needs that folder to stay
in place. SDK/generated code/build products and raw diagnostics remain ignored.

Production patch order:

1. `patches/rexglue-macos-base.patch` — saved tested pre-v1.1 project runtime
   adaptations (formerly `rexglue-local-changes.patch`).
2. `patches/rexglue-macos-portability.patch` — saved Mac fixes and opt-in probes.
3. `patches/rexglue-macos-drawable-recovery.patch` — acquire/drawable recovery.

Old input/presentation experiment patches are not in the production stack.
The Mac implementation was tested from upstream `1bd7d9b`. It was first
published on `macos-support`, then merged into the owner's `main` at their
request. Windows v1.1 (`edc0783`) is retained; the Mac stack uses a separate
byte-identical saved base patch so the newer Windows SDK changes are not
silently activated on Mac. Integrating those changes into the Mac runtime needs
fresh patch-stack, ABI, build and gameplay validation.

## Chronological findings

### 1. Mac build and compiler portability

**Problems.** Xcode licensing initially blocked compiler tools. Windows CRT
functions, SDK paths/scopes, module names and generated registration size also
blocked native builds. The repository did not have a complete Mac workflow.

**Changes.** Added `scripts/build-macos.sh`, Mac CMake presets, pinned recursive
SDK preparation, supported-input preflight, Mac manifest/template overrides,
canonical staging, `.app` packaging and artifact/bundle verification. POSIX font
I/O uses `fseeko`; SDK version probing uses the SDK source rather than consumer
Git tags. The Vulkan ICD helper derives its source from `REXSDK_DIR` when the SDK
subdirectory's `REXGLUE_ROOT` does not reach the consumer scope.

**Large registration tables.** Approximately 159k registration calls in one
function were pathological for the Clang backend. A Mac-only generator override
chunks calls into 512-call helpers without changing the registration sequence.
Data-only registration/init tables use `-O0` without PCH; guest hot code remains
optimized. Merely reducing compiler optimization for every guest file would
penalize runtime work and did not address the right compilation seam.

**Evidence.** Native builds/packages and clean-snapshot builds completed during
the investigation. Compile checks prove artifact integrity, not gameplay.
The low default parallelism (`--jobs 2`) protects a 16 GB machine; the first build
takes tens of minutes. The owner completed the Xcode license step manually.

### 2. Guest module loading and startup object lifetime

**Module loading.** Generated modules register bare target names. Windows adds
`.dll`; POSIX `dlopen` does not invent `lib<target>.dylib` or search the same way.
The Mac loader resolves the actual dylib beside the host and reports `dlerror`.
Windows loading behavior is retained. Packaging verifies actual registration and
image info via `dlopen`, rather than treating file existence as success.

**Startup crash.** Guest `sub_820509A8` started its worker before constructing
both CEvent objects that the worker signals. On a multicore host, the worker
could read still-null fields at `this+0x4C/+0x50` and fault at guest address `0x4`.
Two revision-specific mid-assembly hooks construct and publish both events
before spawn, then skip the redundant original constructions. Unexpected state
or allocation/constructor failure is fatal rather than permitting the unsafe
spawn. `guest_start_events_core.h` supplies a testable ordering seam.

**Lesson.** Repeated launch attempts and object-lifecycle theories were too slow
without an exact guest fault, relevant instruction path and an ordering fixture.
Do not treat a successful worker task or a window opening as proof the runtime
started correctly.

### 3. App packaging and black-screen/acquire recovery

**Packaging.** Bundle host/runtime/GPU/guest dylibs/config/Vulkan files together.
The host and its shared libraries must come from one consistent build. Updating
only a next-to-host copy can miss the linker's canonical output. Later work
identified the same stale-copy hazard for the GPU plugin.

**Fresh inodes.** Rewriting signed Mach-O files in place can retain macOS vnode
signature state and cause the next launch to be killed. Packaging uses a fresh
staging directory and a rename/rollback, not an in-place executable overwrite.

**Black-screen investigation.** A render-thread sample in `nextDrawable` can
be a normal wait; it did not by itself prove a permanent freeze. Acquire/recovery
classification and sync-object replacement have 45 unit checks and production
build verification. Recovery is saved in its own stack patch. Early boots
reached title/autosave, but we never proved every reported black screen came
from this acquire path or that resize/background recovery is fully fixed.

**Lesson.** Separate classifier correctness, artifact integration and actual
screen behavior. Neither a unit pass nor a stack dominated by a wait is a
complete live presentation diagnosis.

### 4. Controls and the autosave prompt

The owner reported that Space would not dismiss the autosave prompt. Some
runs later progressed title → autosave → loading → EA logo → main menu via
manual keyboard input. Focus explanations remained inferences until input
routes were inspected. We added opt-in keyboard-to-guest tracing and tested the
real MnK driver without automating the game window.

The stable profile is `config/macos/keyboard-arrows.toml`: arrows move,
Space=A, D/Backspace=B, A=X, S=Y, Q=LT, E=RT, W=LB, R=RB, IJKL=right stick,
Z/C=stick clicks, TGFH=D-pad, Tab=Back, Return=Start. Xbox prompts stay visible.
A real-driver fixture verifies the bindings, releases, move+sprint+pass together,
and the Start+B exit combination. Bare Shift/Ctrl/Alt were avoided because
exact modifier matching can suppress the unmodified movement binding.
See [the complete control reference](../docs/CONTROLS-MACOS.md).

### 5. Idle audio-worker CPU and generated PowerPC fences

**Wait bug.** A multi-object alertable wait polled in 1 ms slices; POSIX duration
rounding could reduce the remaining sleep to zero. The idle worker then spun.
A real-runtime fixture reproduced about 100% of one CPU core before the precision
fix and about 1% after it. Timeout, token selection/consumption, wait-all and
shutdown semantics are tested. This removed wasted idle CPU; the first manual
comparison still had bad menu/audio, so it was not the entire symptom.

**PPC barriers.** Missing `sync`, `lwsync` and `eieio` generation was separately
reproduced. The backport emits the required fences. Checks cover real instruction
emission and ARM64 assembly, and the game rebuild audits 453 generated fences.
Memory correctness matters on ARM; these checks do not imply a measured FPS gain.

### 6. Measure frames and audio before guessing

Added opt-in audio producer/callback counters, stage wall and thread CPU scopes,
frame sequence markers, principal GPU timestamps and thread CPU snapshots.
Detailed bounded queues report lost records; summaries remain available.
Software-only real SDL callback and concurrent recorder tests exercise the actual
runtime seam without opening an audio device. ThreadSanitizer stress tests cover
recorder concurrency.

**Host presents are not new frames.** The old host loop could present one guest
image repeatedly at 60/s while the guest produced near one new output/s. We
tracked swap signature, processor arrival, output publication and host sequence,
so repeated presentation could not masquerade as gameplay FPS.

**Sampling perturbation.** One long gap coincided with external stack sampling;
we collected a comparison without that sample. Phase timing, cache state and
measurement overhead must be recorded. GPU query spans are principal-command
spans, not the complete GPU/host frame time. Stack counts are wall observations,
not CPU percentages. Fence/register/pipeline durations overlap, so adding their
wall totals is invalid.

### 7. Queue submission experiments — partial improvements and a crash

The refined slow-menu run `20261010T005303.522510Z` attributed 101.638 s of long
GPU-Commands queue acquisition to shared queue locking; 99.77% overlapped presenter
submission holding that queue. Principal guest API calls totaled only 0.388 s.

An asynchronous MoltenVK comparison (`20261010T005701.200429Z`) reduced queue
acquisition to 3.962 ms and improved whole-run new-output cadence from 4.06/s to
5.90/s, with smoother early navigation reported. Late cadence still fell below
1/s and resolve fence waits rose to 112.776 s. Removing one wait moved work;
it did not prove end-to-end performance was fixed.

A later asynchronous/unpaced presentation comparison crashed before the main
menu in a MoltenVK callback-copy path (`_block_object_assign`). A standalone
presentation stress fixture passed but did not reproduce the game's lifecycle.
Synchronous submission became the stable comparison setting. Host-only unpaced
presentation is kept separate from guest vsync/time. Do not re-enable async as
an optimization merely because the synthetic fixture passes.

### 8. Hidden overlays caused continuous host redraws

Even with no visible overlay, the achievement toast and exit dialog requested
continuous repaint. A 45-second paint-origin trace recorded 9,211 custom paint
events with two registered dialogs asking for redraw. Fixes let dormant dialogs
sleep and wake on notification/input, retaining animation, expiry, confirm,
cancel and teardown behavior. Actual UI-owned runtime scheduling fixtures failed
before the fix and passed afterward.

**Integration mistake.** Early candidates replaced runtime/GPU dylibs but did
not rebuild the consumer host. `ReXApp` is compiled into that executable, so its
notification-wake integration was missing. Rebuilding all three corrected the
candidate. The full-host run `20261010T092816.972034Z` had improved music/movement:
repeated presents fell from 20,101 to two; queue-acquisition wall time fell from
72.600 s to 0.145 s; audio silence insertion fell from 0.885% to zero on the same
endpoint. Most late windows reached 23–25 new outputs/s. This was a scheduling
improvement, not a 60 FPS result.

### 9. Persistent shader-cache read position on Darwin

The remaining 11.162-second output gap was traced to compilation: the longest
10.848-second GPU command batch contained 10.740 s of graphics pipeline creation
(99.01%). The cache opened description/shader files in `a+b`; the Darwin stream
was initially at EOF. Existing headers were missed and caches reset each launch.

A failing real-file fixture reproduced initial position 4 / zero bytes readable
for a four-byte file. `OpenShaderStorageFile` now seeks to zero before reading,
retaining append writes and closing on seek failure. Header/record reload,
append, second reopen and invalid path tests pass. The next run preloaded all
79 persisted graphics pipelines. Later sessions preloaded about 120.

The cache-fixed restart `20261010T095318.756591Z` reached usable gameplay, with
remaining audio breakup. It stopped at the owner's request: wrapper exit 130
was interruption, while the game exited 0. Do not report that as a game crash.
Existing user shader caches are outside the app bundle; rebuilding/repackaging
the app must not casually wipe them. Correct description reload does not avoid
all new Metal pipeline compilation; cold/warm startup remains a confound.

### 10. Source audio content and a rejected buffering guess

Added numerical-silence, non-silent lag-1/lag-4 repetition, invalid/out-of-range
float sample and peak counters. Guest PCM is decoded as big-endian float32;
positive/negative zero count as silence, NaN/Inf are distinct from range excess.
Legacy byte fingerprints remain for compatibility. Old traces without these
fields are unknown, not measured zero. No PCM recordings are saved.

The content run `20261010T100957.527778Z` had slight audible breakup yet zero
backend-inserted silence and zero invalid/out-of-range source samples. Non-silent
repeats occurred only around elapsed 23–25 s. Later source silence could be an
intentional passage or an upstream gap; aggregate counters cannot distinguish
those. Increasing the queue was not supported by this starvation evidence and
was not promoted. Default remains eight 256-frame blocks (about 42.7 ms of
queue capacity, not measured end-to-end latency).

Seven source-content checks, real SDL callback checks (20 disabled / 30 enabled),
JSONL round-trip/accounting and recorder TSAN stress pass. A fixture measured
roughly 1.10 μs/block disabled and 8.41 μs enabled; probe overhead is a fixture
measurement and diagnostics remain opt-in.

### 11. Native fence polling was slower, not an optimization

A headless MoltenVK benchmark compared full blocking with up to 200 μs of status
polling followed by the same required completion wait. Four alternating-order
rounds per mode checked all 8,100 GPU-written 4 KiB readbacks. Mean round-average
wait was 247.314 μs blocking versus 291.273 μs polling; caller CPU was 9.557 versus
208.639 μs/operation. Polling stayed disabled. A small serial fill is not a game
frame; the benchmark cannot predict FPS. Completion waits cannot be skipped
because the CPU consumes GPU-written data.

### 12. Mac guest clock: fractional time loss and reader contention

The 90-second CPU profile `20261010T101809.575426Z` observed Main XThread largely
in guest `sub_82613E70` → `sub_82725190` → `QueryGuestTickCount`, with a busy deadline
loop. EAAudioCore Dac also read that clock and could block on its shared mutex.
The sample began at 60.5 s; the user confirmed the main menu at about 69.2 s, so
exact sample phase remains uncertain. RenderThread had a separate hot guest path
through `sub_82713710` / `sub_826FCC30`.

**Reproduced clock error.** The real runtime at 50 MHz guest / 24 MHz host floored
every tiny delta, throwing away fractional ticks on each read. Under heavy reads,
nominal 1x guest time measured 0.960726 (one reader) / 0.980007 (eight readers) of
host rate. The existing bypass stayed near 1x. The same-app bypass run
`20261010T102447.092264Z` received “Better” music feedback but late output rates
fell to 18–20/s. Bypass also changes origin and disables scalar/wall-time controls,
so it was not adopted as the solution.

**Fix.** Mac-only anchored rational conversion computes elapsed guest time from
a stable host/guest anchor, independent of read count. Atomic coherent mapping
snapshots allow readers to avoid shared state mutation and the mutex. Rare
config updates use one writer mutex, invalidate readers before sampling the
rebase time, and publish all fields together. An interrupted reader falls back
to the mutex instead of spinning around a descheduled writer. Checked 64-bit
multiplication keeps wide division off the usual path; 128-bit conversion handles
large products. Scalar quantization is preserved; rebasing may lose less than
one guest tick per config change, not per query. Windows clock logic is retained.

**Correctness evidence.** 1,224 mapping assertions pass ordinarily and under
ThreadSanitizer, including eight readers against a scaling writer, exact 25/12
conversion, read-count independence, monotonicity, coherent mapping, interruption,
large products and continuity. Public runtime APIs test 0.5x/1x/2x rate, frequency,
durations, guest wall-time overrides and uptime. The real-runtime rate regression
passes at 0.999924 / 1.000006 with one/eight readers. Fixture throughput improvement
is not extrapolated to game FPS.

**Manual evidence.** The normal-clock candidate `20261010T103730.761417Z` received
“Main menu—music and movement improved.” Confirmation was recorded at elapsed
75.806 s; the remaining section was requested at the main menu. It exited cleanly
at the 120-second bound (121.140 s overall, game exit 0). No audio-buffer change
was made. Later owner feedback described gameplay as good/everything fine and
asked to pause optimization and package/document the work.

## Selected comparable measurements

These are sequential observations, not fully phase/cache-matched benchmarks.
All three recent audio runs used synchronous submission, host unpaced mode,
idle-overlay suppression and frame diagnostics. The bypass changes more than
mutex behavior. Exact earlier menu-entry times are not known.

| Measurement | Content baseline | Clock bypass | Anchored Mac clock |
|---|---:|---:|---:|
| Run suffix (20261010 UTC) | 100957.527778Z | 102447.092264Z | 103730.761417Z |
| Human report | Slight breakup | Better | Menu music/movement improved |
| Late new outputs/s, rows ending 90–120 s | 25.236 | 18.381 | 24.565 |
| Largest producer gap, ms | 30.288 | 38.277 | 26.639 |
| Largest callback gap, ms | 23.318 | 23.402 | 23.317 |
| Inserted backend silence | 0 | 0 | 0 |
| Non-silent repeated blocks, lag-1 / lag-4 | 17 / 13 | 454 / 430 | 1 / 0 |
| Invalid / out-of-range source samples | 0 / 0 | 0 / 0 | 0 / 0 |
| Pipeline creation wall time, whole run | 7.555 s | 0.630 s | 13.481 s |
| Lost detailed frame points | 1,054 | 1,164 | 1,462 |
| Game exit / stop reason | 0 / time limit | 0 / time limit | 0 / time limit |

For the latest recorded thread intervals, RenderThread averaged 98.85% of one
core and Main XThread 90.63%. The clock correction did not remove guest busy
waiting or prove a frame-rate increase. The next performance investigation, if
requested, is a fresh RenderThread/resolve-path profile before changing pacing,
synchronization or readback semantics.

## Evidence and diagnostic locations

Portable summaries of all 17 retained performance-check sessions with an
analysis file are in [LOG/evidence/macos-measurements.json](evidence/macos-measurements.json). Raw traces remain
local under `build/macos/logs/`; they total gigabytes, contain machine paths and
are not a sensible Git payload. Game-derived code/caches and any memory/core dumps
must stay private. The summaries retain run IDs, actual counters, artifact/patch
hashes where available, event losses and limits; they are not complete raw traces.

Historical detailed methodology and experiments remain available:

- [Frame/presentation diagnostics](../docs/MACOS-FRAME-DIAGNOSTICS.md).
- [Audio/runtime diagnostics and collection](../docs/MACOS-PERFORMANCE-DIAGNOSTICS.md).
- [Pinned runtime research and primary-source links](../docs/MACOS-RUNTIME-RESEARCH.md).
- [Build and advanced host/control/capture seams](../docs/BUILDING-MACOS.md).

Important local artifacts: `guest-clock-candidate/out` is the tested normal-clock
candidate; `audio-content-candidate/out` is the baseline/bypass candidate;
`shader-cache-candidate/out` is the earlier playable cache candidate. Canonical
build/play output is `build/macos/out`; normal play must not silently prefer an
old candidate just because it exists. A release-preparation build stages the
current source and stable config there. Experimental paths remain historical.

## Operating rules and mistakes to avoid

1. **Human availability matters.** Bounded tests unexpectedly closed before the
   owner started a match or while they were away. Normal play has no timer;
   announce test duration and keep controls manual under the current instruction.
2. **Inspect worker evidence.** Early iterations relied too heavily on done
   notifications. Read changes, commands and actual results. Parallel workers
   added coordination cost; the owner requested single-agent optimization until
   explicitly authorizing OpenCode again for release preparation.
3. **Persist ignored SDK work.** `ReXGlue/` is not committed. Saved patches, new
   private headers, build inputs and stack tests must reproduce the work.
4. **Patch stacks overlap.** A later patch can invalidate an earlier reverse-check.
   Check the full ordered stack and partial-prefix states before mutating it.
   Twenty real-Git stack checks cover clean, full, partial, conflicted and
   unrelated-edit cases; don't declare an earlier patch missing from one hunk.
5. **Rebuild/stage all consumers.** Host integration and canonical runtime/GPU
   staging matter; a successful targeted library build can leave stale copies.
6. **Preserve fresh Mach-O inodes.** Use package staging/rollback. Verify bundle
   architecture, dependency resolution, byte equality and guest module loading.
7. **Don't overinterpret counters.** 60 host presents/s can mean repeated images;
   zero backend silence can coexist with audible defects. Samples, cache state,
   endpoint and phase have material effects.
8. **Keep failed experiments.** Async crashed in the real game, polling consumed
   more CPU, and clock bypass changed time semantics. Document them to avoid
   repeating plausible but harmful changes.
9. **Don't remove correctness waits or fake guest time.** Prove a bottleneck and
   preserve data visibility/time controls. Smaller native GPU spans don't mean
   every guest resolve may skip completion.
10. **Keep SDK/app ownership clear.** Read dependencies, change persistent source,
    run focused real-seam regressions, then test the rebuilt game manually.
11. **Don't claim original source or full agentic support.** Host/runtime seams
    are editable; the original game was recompiled. Virtual-pad/capture fixtures
    do not establish completed human/AI or AI/AI matches.
12. **Protect private inputs.** Never commit game data, original executables,
    generated guest code, raw PCM, private paths, credentials or giant traces.

## Release preparation: install, controls and reproducibility

The owner paused deeper optimization after good gameplay feedback and requested
publication on their fork. Codex owns README, agent instructions and this log;
OpenCode Build sessions use verified official `deepseek/deepseek-flash` for the
implementation. The game remains closed; all new helper checks use fixtures.

Normal play now selects the canonical `build/macos/out/FIFA Street.app`, has no
shutdown timer and clears diagnostic opt-ins for its child. Historical candidate
folders no longer silently override it. Runtime settings have a single source
in `config/macos/fifastreet-runtime.toml`; both terminal and Finder use that
persisted config. A Mac host helper establishes synchronous MoltenVK submission
before GPU initialization while respecting an explicit environment override.
The pinned MoltenVK already defaults to synchronous; setting it explicitly
makes the intended comparison configuration clear.

The build combines that runtime config with the shipped arrow/Space profile,
stages both canonical runtime and GPU libraries, verifies their bytes and
packages a fresh bundle. The opt-in installer targets `~/Applications` and
preserves an absolute GameData symlink instead of copying assets. It requires
`--force` for replacement, stages before swapping and keeps rollback inside an
owned temporary directory.

Review exposed several useful failures before publication:

- The first profile rewrite stopped at its header and deleted later settings;
  an empty profile could erase the file. Validation must precede replacement,
  with all nonbinding lines and file modes preserved.
- A later rewrite retained real TOML sections but appended keys inside their
  scope. The real SDK/MnK loader reproduced incorrect arrow input, even though
  text-only checks passed. Root bindings must precede tables. Test loaded
  behavior as well as preserved bytes.
- A real GameData directory would copy assets during installation. Require a
  resolving absolute symlink, not merely a file reachable through a directory.
- Textual destination comparisons missed aliases of the source; a public
  `.previous` rollback name could delete an unrelated backup. Canonical path
  comparisons and an owned staging directory avoid those errors.
- Helpers must reject malformed quoted profiles and install destinations inside
  the source bundle, before mutation or copying.

The original reviewed install regression went from 24 passing / 26 failing to
50 passing / zero failing. Play argument checks went from 3 passing / 4 failing
to 7 passing. The final helper suite has 70 passing / zero failing checks,
including root and nested TOML tables loaded by the real MnK driver, strict
quoted-profile refusal, idempotency and refusal of source-descendant installs.
Runtime config (18 checks), host defaults and build portability (72 checks)
also pass. No fixture is a new live-match check.

The owner's fork `main` already contains a newer Windows release and substantial
SDK changes. `macos-support` preserves the upstream baseline (`1bd7d9b`) used
for Mac validation rather than silently combining an untested SDK stack. The
remote `origin` is the owner's fork; `upstream` retains the original repository.
Upstream author/license credit remains intact.

### Final integration evidence (10 October 2026)

The normal `build-macos.sh --gamedata <private-game-data> --jobs 2` invocation
finished with exit 0: SDK preparation, regeneration, host/runtime/GPU compilation,
canonical staging and bundle verification. This was an incremental integration
build, not a new full clean rebuild. Regeneration reported 0 written / 861
unchanged files. Both before and after the CMake generation step, startup hooks
and 453 barriers (29 `eieio`, 393 `lwsync`, 31 `sync`) passed verification.

| Final check | Result |
|---|---|
| Fresh pinned-source patch-stack reproduction | 20 passed, zero failures |
| Clock mapping and concurrency | 1,224 assertions, ordinary and ThreadSanitizer |
| Public runtime clock controls and rate | Passed; normal guest/host rate 0.999764 with one reader, 0.999999 with eight; monotonic |
| Real-runtime idle wait behavior | Zero failures; CPU ratios 0.010 nonalertable / 0.013 alertable |
| Shader storage reload | Existing header, append, second launch reload and invalid-path checks passed |
| Codegen fences | Real decoder/writer and emitted ARM64 `dmb ish` checks passed |
| Startup, controller bridge, frame capture and source-audio fixtures | Passed |
| Install/profile helpers | 70 passed, zero failures, including real SDK section-scoping regressions |
| Play arguments / runtime config / portability / host defaults | 7 / 18 / 72 checks and host-default behavior passed |
| Staged, bundled and installed keyboard configs | 25 bindings, releases, move+sprint+pass and exit chord passed through real MnK |
| Canonical output and packaged `.app` | Architecture, dependencies, canonical runtime/GPU bytes and guest-module loading passed |
| Installed copy at `~/Applications/FIFA Street.app` | Installation and bundle/control verification passed; GameData remains an absolute link |
| Publication hygiene | Script syntax, local documentation links and source whitespace checked; no game assets, generated code, binaries, credentials or raw logs staged |

The new host contains the MoltenVK environment default; it is compiled and
packaged, not merely copied from a previous candidate. The app was not launched
for this release preparation, and the installed copy remains closed. Manual
performance/playability evidence is from the earlier recorded candidates and
owner feedback. No new live-match, save/reload or sustained-frame-rate claim is
made. Final artifact and patch hashes, commands/results and all retained run
summaries are in [the evidence file](evidence/macos-measurements.json).

The normal build currently analyzes the manifest once explicitly and can repeat
that pass through CMake after rebuilding its generator. The final regeneration
was unchanged, but those analyses still take minutes. Incremental compile reuse
does not make the entire build instant; avoid starting full builds during a
manual performance comparison. Optimizing generation caching is future work.

### Integration into the fork's main branch

The owner requested delivery on `main` after the initial `macos-support` push.
Both histories are merged, without a force push. The existing Windows v1.1
installer, launcher, changelog and SDK patch are preserved. README and status
conflicts combine Mac instructions with the upstream Windows v1.1 validation
record rather than downgrading it to v1.0.

`patches/rexglue-macos-base.patch` is an exact copy of the validated base patch
from `9116774` (SHA-256 `d5eac5126ad83fc794ef72be7d59eb9f9d7fedd34bcf8d37cc3ee434597e5e70`).
The Mac builder and two stack/recovery tests select that file. The newer Windows
`rexglue-local-changes.patch` remains byte-identical to `edc0783`. All three Mac
stack payloads are unchanged, so the tested SDK and installed app need no new
rebuild for this path-selection change. There was no game launch.

Fresh stack reproduction passed 20 checks; portability passed 72; drawable
recovery GREEN checks passed and the RED controls failed as intended. Supported
input check-only preflight also passed. These are integration checks, not a
performance comparison against Windows v1.1.

The upstream changes are worth future review: adaptive `Some` readback refreshes
invalidated/sporadic GPU result ranges to reduce stale-data visual artifacts
while avoiding unnecessary GPU-to-guest-memory copies. It is the most relevant
performance experiment for our Mac `Full` path. The upstream VSync improvement
has Direct3D 12 validation, but Vulkan VSync is explicitly untested in its status
record; no MoltenVK improvement is assumed. Logo Mods support and Windows
launcher/direct-play/scaling changes serve customization and Windows usability.
Preserve this working baseline and measure a separate readback candidate before
changing the Mac production defaults.

### Reusable normal-play log viewer

The owner requested a single command for logs before starting the next game.
The original printed `tail -f` path was session-specific: following the previous
file would not follow a new launch. `scripts/logs-macos.sh` follows the latest
normal-play UTC session, waits when no session/log exists and switches when the
next session directory appears. `--session ID` pins a session and `--lines N`
sets the initial history. Ctrl+C ends only the watcher. It reads files and has
no game-process control or log-file mutations.

The play command now prints the exact pinned-session viewer command. The
README and Mac guide explain using two Terminals: viewer first, then normal
play. The viewer follows `fifastreet.log`; direct driver stdout/stderr remains
in the launch Terminal. Finder logs live inside the bundle and do not create
these normal-play session folders.

The initial suite passed 42 behavioral checks on fake logs/processes, covering
late session creation, appends, switching before the next file exists, pinned
sessions, truncation/replacement, argument validation and stop isolation. Review
then reproduced a split-line defect: an initial `first=le` plus a later `ft\n`
was displayed as two lines. Large-log attachment also read the entire file for
a 20-line tail, and disappearance between replacement stat/open could stop the
watcher. New regression fixtures reproduced five failures before the fixes
(51 passing / 5 failing checks). Partial-byte buffering, chunked tail/append
reads and retry on disappearance resolved them. The final suite passes all
57 checks, including split UTF-8 writes and a synthetic 400,000-line log;
launcher argument checks pass 7/7. Codex independently reran both suites and
the original split-line reproducer after reviewing the implementation.

OpenCode Build used the official `deepseek/deepseek-flash` model, verified from
session metadata; Codex owns this documentation and final Git review. No real
game was launched or rebuilt for this CLI-only addition. These fixtures prove
log-viewer behavior, not gameplay or performance improvement. A pathological
single line can still require holding that line in memory; truncation followed
by regrowth beyond the old offset between polls is not detectable. Raw worker
reports and RED/GREEN output remain in ignored local diagnostic storage.


### README structure and attribution

Reorganized the README around status, prerequisites/build/play, session logs,
architecture, controls, measured fixes, future benchmarks and credits. Two
Mermaid diagrams show the local binary-to-arm64 build pipeline and the runtime
Vulkan → MoltenVK → Metal graphics path. Attribution now uses `fyzanshaik` as
requested, while retaining the upstream port and runtime credits. Performance
figures retain screen/cache and measurement limitations; planned AI evaluations
remain clearly marked as future work. This is documentation-only work: no build,
gameplay, runtime setting or keyboard binding changed.

### Fixed blank window after live resize

The owner reports that even a small manual window resize can leave the game
window blank. The supplied MoltenVK log shows an initial three-image swapchain
at 1280×720 and a replacement three-image swapchain at 1825×1045 on an Apple M5
with an LG ULTRAWIDE display. Primitive-restart warnings appeared before the
replacement; the log alone does not identify the cause or establish that
presentation resumed. Earlier acquire classifier/sync tests did not verify this
live resize case.

The owner confirmed that audio continues while the resized window is blank.
OpenCode Build used official `deepseek/deepseek-flash`, verified in T3 execution
metadata. Investigation began while the game was running; builds and packaging
waited until a read-only process check found it closed. The real game was never
launched, automated or stopped by the investigation.

**Reproducer and cause.** A separate SDL fixture drives the real
`VulkanPresenter` and MoltenVK, with a thread publishing synthetic nonblank guest
output. Against the original runtime, resizing to 1600×900 and 1825×1045 left
the `CAMetalLayer` drawable at 1×1, producing a failing dimensions check. In the
pinned MoltenVK, `MVKSwapchain::initCAMetalLayer` sets the new extent and then
can call the old swapchain's `forceUnpresentedImageCompletion`, which assigns
1×1 when presentations remain unfinished. The presenter had no subsequent
restoration. This supplies a concrete failure mechanism consistent with the
owner's symptom; the fixture does not inspect final screen pixels.

**Fix and evidence.** The Mac presenter restores the created swapchain's extent
on its layer after successful recreation and retirement of the old swapchain.
The change is saved in the third production patch, with a new private helper
header. The consumer's `rexruntime` target rebuilt successfully; canonical
runtime staging and fresh-inode packaging refreshed `build/macos/out/FIFA
Street.app`. Host/GPU sources and validated runtime settings did not change.
Codex independently ran the resize fixture: 1600×900, 1825×1045 and 1500×800
all retained the expected dimensions; the forced-1×1 control failed at all
three sizes. Fresh pinned-source patch sequencing passed 20 checks, existing
acquire classifier/sync GREEN and RED checks passed, and canonical artifact
and bundle verification passed. Raw output remains in ignored
`build/macos/logs/presenter-resize/`.

**Review and final verification.** The initial test accepted any nonzero
negative-control exit and cached a queue without retaining its lock for
submission. A fresh follow-up worker added a dedicated drawable-defect exit
status (4), required mismatch/failure sentinels, a process watchdog, Vulkan
result checks, queue locking and GPU resource cleanup before device destruction.
The probe checks successful refresh and paint activity, reads SDL surface pixel
dimensions and no longer explicitly activates its window. Codex reran the
hardened suite: GREEN exit 0, all three sizes correct, 115 successful refreshes,
83 paint events and zero refused refreshes/painter failures; RED exit 4, all
three sizes at 1×1, 114 successful refreshes and zero painter failures. These
activity counts establish fixture activity, not visible game pixels or FPS.

`scripts/install-macos.sh --force` refreshed the existing installed app after
another no-game-process check. Codex independently verified the installed bundle
and its 25 keyboard bindings through the real MnK driver. Installed and canonical
runtime hashes match. Commands, hashes and limits are recorded in
[the resize evidence summary](evidence/macos-resize-recovery.md).

The owner then tested the updated installed game and confirmed “works!” for
resizing, closing the reported manual reproduction. This establishes recovery
for that check on the tested Mac, not every resize/background scenario.
Background recovery and Intel Macs remain unverified. The probe uses pixel
dimensions, but the wrapper's exact 1825×1045
sentinel targets the tested external display's 1× scale; a Retina-only fixture
run needs corresponding wrapper expectations. Do not infer visible nonblank
output solely from drawable sizes. Agents did not launch or control the real
game; the final game check was performed by the owner. The owner requested
publication of this fix on the fork after confirming success.

### Additional macOS credit on title and main menu

The owner asked whether the displayed `PORTED BY` credit could be changed, then
accepted adding `macOS port: fyzanshaik` alongside the existing upstream credit.
The displayed line is baked into menu textures, not a runtime string. The
Windows installer applies a hash-gated texture recipe; the Mac production path
does not invoke that installer or include the newer Windows Mods loader.

Two OpenCode Build tasks used official `deepseek/deepseek-flash`, verified in
T3 execution metadata. They added a Mac helper for the two already-credited
supported screen archives. It edits only the new line's BC3 blocks in a private
cloned `data1.big`; all unrelated entries remain symlinks to original GameData.
Source and output hashes are checked before a staged profile is published. The
original logo and upstream credit blocks remain intact. The line lives in the
press-start and main-menu textures, avoiding an overlay or gameplay redraw cost.

Review found two real encoding mistakes before delivery: the first decoder
ignored the XPR2 fetch constant's `k8in16` byte order, producing pink/blue preview
art instead of the original neutral logo/red banner; it also used BC1's
three-colour rule where BC3 always has four colour entries. Independent golden
vectors, the actual fetch header and the SDK's swap/tiling definitions corrected
both. The initial CoreText renderer was replaced by a deterministic bitmap font
to make pinned output hashes reproducible across systems. In-place mutation and
backup/revert code were removed in favour of a private profile. Check/dry-run
paths perform no mutations, and failed preparation cannot publish half a profile.

Codex visually reviewed the corrected decoded previews and independently ran
all 63 fixture checks: codec/reference vectors, endian transforms, tiling,
container validation, preservation, profile refusal/no-mutation cases,
idempotence and second-target failure safety. The installed bundle and real
25-binding MnK checks pass. Source menu hashes remain the supported originals;
the profile hashes match the pinned outputs. A full source/profile comparison
finds 5,641 differing bytes, zero outside the two texture ranges, with archive
size unchanged; unrelated profile entries resolve to their original files.

Canonical and installed apps now link to the private credit profile. Original
GameData, caches, saves, executable modules, runtime settings and Windows paths
are unchanged. No compilation was needed; packaging used fresh inodes. Agents
did not launch or control the game. Actual in-game visibility of both added
lines remains unverified until the owner checks it. The helper currently
requires the previously credited supported menu archives; plain retail data
is refused. Reproduction and reversal are documented in the
[Mac guide](../docs/BUILDING-MACOS.md#optional-macos-menu-credit). Raw asset
previews and cloned archives remain private, never a repository payload.

## Agent environment design — 11 October 2026

**Direction.** The owner opened the agent-environment design track and selected
a text/JSON LLM against the game's built-in AI as the first playable experiment,
with video for humans. This is evaluation of a fixed model initially; RL training,
vision comparisons and AI/AI are later possibilities. Normal-play optimization
remains paused. Research delegation moved, at the owner's direction, to Codex
subagents through T3 Code. The framework report completed; the port-feasibility
task hit a usage limit, so the parent completed the relevant source inspection.

**Findings.** Existing virtual XInput and continuous presenter capture are useful
seams, not a completed environment. The controller server services one connected
client at a time, so a persistent broker should own the socket. Capture image and
metadata replacements are separately atomic, and checksum changes do not count
simulation ticks. Gameplay field layouts, a coherent state snapshot boundary,
CPU-opponent assignment, direct match launch and repeatable reset remain unproven.
The pinned SDK's running `XThread::Save` returns false and its execution restore
path is unimplemented; subsystem Save/Pause declarations do not establish usable
game savestates or fixed-tick stepping. This rules out assuming a ready-made
checkpoint reset shortcut.

**Proposal.** [Agent environment design](../docs/AGENT-ENVIRONMENT-DESIGN.md)
records repository evidence, current primary framework sources, observation and
action contracts, live versus controlled-step timing, menu/reset options and
acceptance gates. Start with a read-only validated gameplay observation probe,
then a scripted bounded-controller loop, then one supervised JSON-driven LLM
match. Keep the environment independent of model providers; Pi/LangGraph are
optional policy runtimes, and Harbor needs a tested native Mac integration and
reliable episodes before use. Built-in AI determinism is not claimed.

**Evidence and limits.** This was a source/documentation design investigation.
No application code or stable runtime settings changed; no game was launched,
input injected, build run or agent match measured. The proposal is not shipped
environment support. Future game validation remains owner-supervised under the
repository's operating rules. Failed worker execution is not validation evidence.

## REA and gameplay recovery investigation — 11 October 2026

**Question.** Would REA enable reconstructing the compiled game as modern Mac
C/C++ and extracting gameplay for the agent environment?

**Findings.** A T3-delegated Codex Plan audit completed; the parent independently
checked upstream commit `ed1519ddee02739f57136e356786f64c7f74fed0` in a read-only
temporary checkout. REA wraps decompiler evidence, not an automatic source
reconstruction pipeline. Its Ghidra bridge labels pseudocode non-source and
non-compilable. The common target classifier omits PowerPC/XEX and the Ghidra
adapter enforces an architecture allowlist. Mac ARM64 fixture support does not
establish original Xbox import support. Generated guest C++ and known guest hooks
already provide a starting point for targeted semantic recovery.

**Decision proposal.** [REA feasibility](../docs/REA-FEASIBILITY.md) records primary
sources and a bounded investigation: recover score/clock/phase, then ball and
controlled-player state; validate observation during owner-driven transitions;
investigate genuine match start/rematch separately. Exposing gameplay through
the existing engine and extracting an independent gameplay library have different
dependency requirements. Whole-engine recovery should not block the first
JSON-agent-versus-built-in-AI experiment.

**Limits.** Documentation/source research only. No REA installation, application
changes, build, game launch, input injection or live memory validation. Gameplay
layouts, compatible Xbox analysis tooling and subsystem isolation remain open.

## Single-agent controller foundation — 11 October 2026

**Scope.** The owner prioritized one tool-controlled player against built-in AI,
deferring second-controller discovery and multiplayer work. The independent REA
thread continues separately. A T3-delegated OpenCode task ran with the configured
official `deepseek/deepseek-flash`; Codex reviewed the changes and evidence.

**Change.** Experimental `RESTREET_CONTROL_MODE=agent-cpu` exposes only virtual
pad 0 on guest user 0, excludes foreign devices, and rejects commands for slot 1
without perturbing slot 0. The driver reports non-exposed devices not connected.
The protocol stays version 1; normal-play opt-in behavior and both older modes
are preserved. Tests cover mode selection/routing and actual receiver behavior;
a new CLI fixture checks request encoding against a test-double server. See
[single-agent input](../docs/SINGLE-AGENT-INPUT.md) for setup and limits.

**Parent validation.** `bash scripts/test-macos-virtual-input.sh` passed the C++
behavioral checks and Python CLI fixture. `/usr/bin/clang++ -std=gnu++23 -Wall
-Wextra -fsyntax-only`, using pinned SDK/fmt/spdlog/simde include paths, passed
for `Installer/recomp-template/src/control_bridge.cpp`. Documentation link checks
and `git diff --check` passed. A second bounded worker round corrected comments
that inferred CPU team behavior from an empty input slot; it changed no code.

**Review lesson.** The receiver handles one connected client at a time. A new
CLI `release` cannot preempt a holding CLI; release must come from the owning
connection or its disconnect. Documentation now separates adapter presence,
game controller detection and match configuration. Future agent tools should
share a persistent broker.

**Remaining evidence.** No host rebuild, game launch, gameplay input or measured
agent match. The SDK-facing driver was syntax-checked, not runtime-tested; CLI
wire encoding and real receiver behavior were tested separately. Confirm one
controller on the selection screen, manual CPU/team setup, movement/pass/shoot
and release during a later owner-supervised session. Structured observations,
model integration and repeatable episode setup remain outstanding.

## Credit-profile startup regression — 11 October 2026

**Symptom.** The owner reported startup SIGBUS after the optional credit change.
Two saved macOS reports (PIDs 5104 and 5513) agree on a main-guest-thread null
read at host `0x300000000`, with first guest frame `sub_826945B0`. The normal-play
log records `NtCreateFile` failure for `data/loc/locale.big` immediately before
the unhandled guest read. That file exists in the original extract. Primitive
restart warnings also appear in the previous successful long-play log and do
not identify this regression.

**Cause and feedback loop.** The profile builder linked directories as well as
files. The pinned POSIX `ListFiles` classifies symlink directories as files from
`dirent.d_type`; `PopulateEntry` consequently skips their children. Full lazy
`ResolvePath` can succeed, but the actual open path resolves the parent and
calls `GetChild` for the leaf, which remains missing. An OpenCode/official
DeepSeek worker reproduced this using the built runtime against both synthetic
layouts and the real original/profile trees. The parent independently ran
`bash scripts/test-macos-credit-vfs.sh`: old layout has `OPENFILE_LEAF NULL`,
while real-directory layout and fixed synthetic builder output have
`OPENFILE_LEAF OK`. The probe reproduces the lookup seam; it does not launch a
guest or establish live startup recovery.

**Minimal fix.** The helper now materializes real directory structure, keeps
unrelated leaf files linked and preserves the independent patched archive.
Ancestor directory cycles are refused before publication. Staging, hash gates
and original-asset immutability are retained. New tests fail against the previous
builder. Parent validation: `bash scripts/test-macos-credits.sh` passes 95 checks,
the VFS fixture passes, and `git diff --check` is clean. No SDK or runtime changes
are needed; the user preferred this narrow fix over removing the optional credit.

**Local repair applied.** A second OpenCode/official DeepSeek round built the new
private `profile-v3-vfs-fix` from original supported GameData. It contains 18 real
directories and 105 unrelated leaf-file links, with zero directory symlinks or
broken leaf targets. Its patched `data1.big` is byte-identical to the prior
profile; the source comparison still differs by only 5,641 bytes inside the two
permitted texture ranges. Source archive hashes/mtimes and bundle binary/config
hashes remain unchanged. Only canonical and installed GameData links changed;
no rebuild, repackaging or cache/save/settings mutation was needed. Old profiles
remain available.

**Deployment evidence and lesson.** Parent independently compiled the probe
against the existing runtime and tested through both deployed bundle links:
`OPENFILE_LEAF OK`, exit 0; the old profile still yields `OPENFILE_LEAF NULL`,
exit 1. Parent archive hashes confirm old/new credited output is identical.
Both `bash scripts/verify-macos-app.sh` checks passed for canonical and installed
apps. A worker's first `mv` attempt followed a destination directory symlink and
placed a temporary link inside the old profile; that entry was removed without
changing bundle links. Final swaps used adjacent staged symlinks plus
`os.replace`. Parent verified no temporary links remain. This is why link repair
must use rename semantics rather than a directory-following move command.

**Owner validation.** After the link repair, the owner reported that startup
works and supplied a screenshot of the press-start screen. The macOS credit
line is visible beneath the preserved upstream credit. This confirms live
startup recovery and title-screen credit visibility. Agents did not launch or
control the game. Main-menu credit visibility and a post-repair match were not
separately documented by this check; single-agent controller gameplay remains
unverified.

## Owner-driven gameplay slowdown baseline — 11 October 2026

**Symptom and scope.** The owner reports graphics and audio deteriorating
10–20 seconds into gameplay, with controls remaining responsive. They explicitly
authorized the parent to launch the installed app for diagnostics. The existing
bounded launcher ran with `--frame-diagnostics --seconds 300`, without external
stack sampling, input injection, configuration edits or builds. The owner drove
menus and a match, then reported some deterioration and match completion.

**Timing and outcome.** Session `20261011T152259.435263Z` exited 0 after
300.827 seconds at its announced time limit, without forced-kill escalation.
The match-start report was recorded approximately 71.452 seconds from launch;
the combined deterioration/completion report arrived at 314.546 seconds, after
capture ended. These are report receipt times, not precise gameplay boundaries.
No exact slowdown onset or result-screen transition was captured. All three
existing performance/runtime/frame analyzers completed successfully.

**Measurements.** New-output cadence was 19.83/s in fully contained windows
between launch seconds 75–95, 19.76/s at 95–125, 18.91/s at 125–175 and
approximately 17.8/s at 175–275. The final 275–297 segment was 14.77/s, with
unknown gameplay/result phase. These are displayed new outputs, not simulation
FPS, and the early menus are not a valid smooth-gameplay baseline. RenderThread
and Main XThread each consumed roughly one CPU core during post-report windows;
polling/spinning may contribute. Guest fence waits totaled 188.554 seconds wall
time, versus 0.753 seconds calling-thread CPU, across 106,373 waits. Those
durations overlap other scopes and do not establish a root cause. Queue-lock
acquisition totaled 2.183 seconds over the full run; graphics-pipeline creation
totaled 0.968 seconds and was almost absent after the match-start report.

**Audio and trace limits.** Backend consumption stayed near the nominal
187.5 guest blocks/s. Only one inserted-silence block (256 frames, 5.33 ms) was
recorded in the entire run; there were no nonfinite or out-of-range PCM samples.
This does not prove clean audible playback or explain the owner's audio report.
The endpoint was earbuds, so other-device comparisons require care. Detailed
frame points dropped 1,743 records; stage detail reports no drops. Full raw
traces remain ignored locally. Small sanitized measurements and limitations are
in [baseline evidence](evidence/20261011-gameplay-slowdown-baseline.json).

**Next discriminating work.** First obtain a matched owner-driven run without
runtime/GPU probes and with explicit smooth/slow/result phase reports; measurement
overhead is not controlled by this single trace. Then narrow the existing resolve
fence path and guest render/main polling before changing synchronization or
readback. Shader compilation is not supported as the sustained post-report
cause by this trace. Backend audio starvation is likewise not supported as an
explanation for persistent audible degradation. No performance fix, proven
10–20 second onset or causal attribution is claimed.

**Requested redraw/CPU review and graph.** The parent examined the saved trace
and source paint/overlay decisions, and prepared a five-minute graph of output
cadence versus host paint calls, process/per-thread CPU, graphics waits, resident
memory and audio delivery. T3 previews passed at 728 and 360 pixels; actual series
toggle and cross-series hover checks passed with no narrow-screen overflow.
The recorded paint calls are 6,447 requested plus six forced; all 6,452 recorded
UI and toast decisions have continuous repaint false. Cadence logs report only
six repeated outputs among 6,409 presents. These observations argue against an
idle-overlay/repeated-presentation redraw storm in this session, with dropped
point detail retained as a limitation.

Five-second averages over launch seconds 75–125 versus 175–275 put process CPU
at 271.0% versus 329.0% (100% is one logical CPU). Aggregated job-manager threads
rise from 47.6% to 89.3%, and GPU Commands from 9.8% to 18.1%. Main/render remain
near a core each, with possible polling/spinning; these measures do not prove
whole-machine CPU exhaustion or useful guest work. Guest fence wait wall time
is about 69.0% versus 66.1% of reporting intervals, so substantial baseline
waiting does not itself explain the deterioration. All 14,826 recorded long
guest fence waits carry the Resolve reason, totaling 147.609 seconds; the
under-1-ms filter excludes many waits from this detail. Resident memory
fluctuates and falls later; a memory leak is not established. Sanitized evidence
now includes these values and their units. A separate read-only OpenCode Plan
audit through T3 completed on official `deepseek/deepseek-flash`, reporting
execution metadata from its own session. It independently corroborated the
redraw/CPU/long-resolve-wait findings and checked the publication-to-paint
coalescing path. The parent accepted the corroborated observations; a small
principal-submission GPU span is not evidence that whole-frame GPU cost is
negligible, and unsupported static phase labels or per-output attribution are
not promoted. No additional run or application change occurred. Next checks
remain a matched probes-off capture and targeted slow-phase stacks to distinguish
guest work from polling, with exact owner phase reports.

## Probes-off owner-stopped gameplay comparison — 11 October 2026

**Authorization and collection.** The owner requested a comparison launch with
no time limit, stopping only on their `done` report; this overrides the usual
bounded diagnostic duration for this session. A one-off parent orchestration
command launched the installed app with only the same presentation timing and
guest-performance CSV flags, recording process CPU/RSS each second. Runtime
JSONL, detailed GPU timing, external stack sampling, capture and virtual input
were disabled. No tracked launcher or application code, persisted configuration,
game data, caches or saves were changed. The runtime JSONL file is absent.

**Phase reports and shutdown.** In session `20261011T154905.520993Z`, match start
was reported at launch second 71.792 and deterioration at 119.179, about 47.4
seconds after the start report. The owner later confirmed slowdown began while
actively playing in the foreground, before switching to chat. `done` arrived at
238.761 seconds; only then did the collector request graceful termination of
its owned game process. Actual game exit was 0 after 239.922 seconds, stop reason
`owner_done`, without escalation. `done` does not mean the match ended.

**Result.** The existing performance analyzer passed on the saved trace. Fully
contained cadence windows in the first 20 seconds after the match-start report
average 20.29 new outputs/s (15.084 seconds measured); windows at 45–75 seconds
average 8.98/s (25.266 seconds measured), and 75–165 seconds remain roughly
9–10/s. Process CPU averages about 2.64 cores initially and 2.57 cores at 45–75
seconds, remaining close to 2.6 through most of this slow segment. Thus detailed
probes are not required to reproduce the symptom, and increasing total CPU
consumption is not a necessary explanation. The first run's job-manager CPU rise
remains an observation of that run, not an established slowdown cause.

**Comparison limits and next measurement.** Same installed app/settings and
earbuds endpoint are confirmed; teams, arena, exact actions, scenes and cache
state were not matched independently. These two live matches cannot establish
relative diagnostic overhead or explain why the second slowed more. No detailed
waits or stacks were captured in the second run. Targeted smooth/slow stacks are
the next discriminator for useful guest work versus polling and render/readback
waiting; foreground loss no longer explains onset in this run. Defaults and
correctness waits remain unchanged. Small sanitized figures and limits are in
[comparison evidence](evidence/20261011-gameplay-probes-comparison.json). A T3
comparison graph was prepared from both saved sessions; no new run was launched.

**Focused optimization audit.** A fresh T3-delegated OpenCode Plan task completed
on official `deepseek/deepseek-flash`, with session metadata checked by the
worker. It found no evidenced current-path defect. Parent source review confirms
that Full resolve readback waits for queued GPU work before making copied data
available to guest memory; removing that wait is not an established correct fix.
`WAIT_REG_MEM` is a GPU command packet: unmatched values with wait >= `0x100`
sleep under guest vsync, while shorter waits yield. The measured register-wait
CPU/wall split supports waiting rather than CPU saturation at this scope, but
does not classify every individual wait.

The historical October 10 sample identified resolve waits and a guest clock
polling loop, but was taken before the clock fix and before confirmed gameplay.
It is useful for recognizing symbols, not a current smooth/slow baseline. Next
profiling is two owner-marked two-second external samples with runtime/GPU
probes off. The local `sample` usage output confirms that duration is seconds
and interval milliseconds; a 10-ms interval is proposed to reduce collection
frequency. Sampling may disturb playback; sample windows must be excluded from
cadence comparisons, and useful-work/blocked-time claims must respect sample
semantics. No samples, new game launch or optimization change occurred during
the code audit. Owner readiness for a further manual match is pending.

## Full match and performance work paused — 11 October 2026

**Owner direction.** After the third capture, the owner noted that slowdown now
seems irregular and requested analysis and retained findings while leaving
optimization aside. Performance tuning is paused. This supersedes the pending
profiling proposals above; no additional run, sample, tuning change or rebuild
is scheduled. The game is closed.

**Capture and outcome.** Session `20261011T162009.383667Z` used the same installed
app/settings with detailed runtime/GPU probes disabled. One external two-second
sample at a 10-ms interval was taken following match start. The owner played both
halves, reported that the first half had not deteriorated much, then requested
closure after game completion. No clear slow-phase report was received, so the
second planned sample was not taken. Exit 0 after 559.355 seconds on the owner's
request, without forced-kill escalation. This is a full-match performance
capture, not complete structured gameplay state or a completed smooth/slow pair.

**Measured behavior.** Excluding sampling-affected windows with a conservative
five-second margin, launch seconds 100–180 averaged 19.495 new outputs/s;
180–300 averaged 17.166/s; and 360–520 after the halftime report averaged
18.426/s. Corresponding mean process CPU was 2.84, 3.24 and 3.37 logical cores.
The severe sustained 9–10/s regime from the preceding probes-off run did not
clearly recur. Higher CPU therefore coexisted with better cadence, further
weakening rising total CPU as a necessary cause. These are owner-marker phase
proxies with uncontrolled actions/scenes, not a deterministic comparison.

**First sample.** GPU Commands had 159 of 172 wall observations in resolve
fence/condition waiting and eight in register-wait sleep. Main XThread had 133
clock-read observations across disjoint branches, with the prominent path reaching
`mach_absolute_time`; no clock-mutex stall is shown in that path. RenderThread
was predominantly in recompiled guest rendering work. Four job managers were
mostly observed in single-object waits. This describes a short relatively stable
interval and cannot identify what changed during the earlier severe slowdown.
Wall observations are not CPU percentages. The sample disturbed playback;
that dip is excluded rather than treated as the reported bug.

**Memory, review and delivery.** RSS was non-monotonic, peaked at 743.828 MiB
over the entire capture and ended at 426.281 MiB. The sample's physical footprint
`2.3G` is separate accounting; neither metric establishes a leak. A fresh
read-only OpenCode Plan audit on official `deepseek/deepseek-flash` completed,
and the parent independently checked accepted numbers and stack branches.
The existing performance analyzer passed; documentation links, JSON parsing
and `git diff --check` were checked. Consolidated observations, non-claims and
provenance are in [gameplay findings](../docs/MACOS-GAMEPLAY-PERFORMANCE-FINDINGS.md)
and [small sanitized evidence](evidence/20261011-full-match-performance.json).
No code defect or optimization fix is claimed. Raw traces and sample paths stay
ignored locally; no original game material or generated code is published.

## Git delivery validation — 11 October 2026

At the owner's request to commit and push the pending checkout changes, the
parent reran the credit fixtures (95 checks), runtime-backed old/new/built-profile
VFS regression, virtual-controller behavioral tests, CLI wire-format fixture and
SDK-facing controller syntax check; all passed. JSON parsing, 70 local document
links, publication checks for private paths/credential patterns/binary content
and `git diff --check` passed. Raw diagnostics, generated code and original game
data remain ignored. The independent REA worktree is kept separate. No new build
or gameplay validation was performed; single-agent input remains experimental
and performance optimization remains paused.

## Next work

- Use the installed app for a manual match, then validate save/reload, longer
  sessions, additional modes and physical controllers when useful to the owner.
- Keep canonical build/package/install checks as the delivery gate; preserve
  normal-clock and presentation settings for both terminal and Finder launches.
- Performance optimization is paused at the owner's request. Preserve the tested
  `Full` readback stack and retained findings. Any future evaluation of upstream
  adaptive `Some` readback needs a separate controlled Mac comparison; Windows
  results are not MoltenVK validation. Profile RenderThread/resolve work before
  changing correctness waits, guest time or readback semantics.
- For agentic benchmarks, follow the proposed
  [observation/action/reset acceptance gates](../docs/AGENT-ENVIRONMENT-DESIGN.md#10-first-implementation-milestone-and-acceptance-gates).
  Validate structured gameplay fields and one JSON-agent-versus-built-in-AI match
  before expanding to unattended reset, controlled stepping or AI/AI.

See [AGENTS.md](../AGENTS.md) for exact operations and coordination rules. No
remaining frame-rate, full-mode or AI-evaluation guarantee is implied by this log.
