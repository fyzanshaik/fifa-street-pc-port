# Building on macOS

Development build of ReStreet (FIFA Street 2012 recompiled) with ReXGlue for
macOS. This is a development workflow; it does not change the Windows build in
[docs/BUILDING.md](BUILDING.md) or `Installer/BuildFifaStreet.ps1`.

The pinned ReXGlue SDK supports macOS on arm64 and x86_64 through Cocoa. On
macOS the Direct3D 12 backend is unavailable, so the build uses the **Vulkan**
backend on top of the SDK's bundled MoltenVK runtime. A successful compile is
not gameplay validation.

**Status (10 October 2026).** Apple Silicon builds and manual matches are
playable; latest owner feedback reports good gameplay and improved music/menu
response. Normal play uses the stable Mac settings described below. This is a
source-build preview: sustained 60 FPS, save/reload, every mode, multiple
controllers and background/display transitions are not fully verified. Intel is experimental and
untested. See [STATUS.md](STATUS.md), [controls](CONTROLS-MACOS.md) and the
[consolidated progress/diagnostic log](../LOG/PROGRESS.md). Earlier severe menu
slowness and black-screen reports are historical context, not the latest status.

## Idle wait regression

The macOS portability patch also fixes an idle CPU problem in multi-object
alertable waits: the audio worker's 1 ms poll slices previously rounded the
remaining sleep down to zero. A real-runtime benchmark measured about 100% of
one core before the fix and about 1% after it. The first comparison still had poor audio/menu response; later overlay, cache
and clock fixes improved the manual result. After building,
run the focused regression without launching the game:

```sh
bash scripts/test-macos-wait-performance.sh
```

Pass the directory containing `librexruntime.dylib` as the first argument if
using another build root or architecture. The test checks idle CPU use, timeout
duration, client selection, token consumption, wait-all and shutdown wakeups.
It requires a built macOS runtime and uses the calling thread's CPU clock,
separately from wall time.

For a bounded manual performance check of an already-built app:

```sh
python3 scripts/run-macos-performance-check.py --app "/path/to/FIFA Street.app" --seconds 120
```

The check launches the selected app, leaves all controls to you, and closes only
that process when the time expires. It records host present timing, guest GPU
swap counters, process CPU readings and a two-second thread sample under
`build/macos/logs/performance-check/`. Frame capture and virtual input are
disabled. These metrics do not measure audio starvation or simulation speed;
record whether the music sounds normal and menu movement responds promptly.
Use `--check-only` to check paths without launching.

The portability patch also restores the generator's PowerPC `sync`, `lwsync`
and `eieio` memory fences. Test the built SDK generator without game assets:

```sh
bash scripts/test-macos-codegen-barriers.sh
```

This verifies real instruction decoding/emission and, on Apple Silicon, the
generated ARM64 fence instructions. The small SDK fixture is verified; the game
has also been regenerated, compiled and packaged with this change; manual comparisons have completed; their individual benefits are recorded in
the progress log rather than inferred from compilation. The build audits every emitted memory barrier before
compilation. For opt-in audio starvation and pipeline timing collection, see
[MACOS-PERFORMANCE-DIAGNOSTICS.md](MACOS-PERFORMANCE-DIAGNOSTICS.md). See
[MACOS-RUNTIME-RESEARCH.md](MACOS-RUNTIME-RESEARCH.md) for pinned dependencies,
upstream sources and the measurements needed for the remaining audio/menu work.

## Prerequisites

- macOS. Apple Silicon (arm64) is verified; Intel (x86_64) is experimental.
- Xcode command line tools, so `/usr/bin/clang++` exists and the license is
  accepted. ReXGlue requires **AppleClang 16+ (Xcode 16+)** or LLVM Clang 18+
  for C++23; `build-macos.sh` checks this and fails early if the toolchain is
  too old.
- Python 3 available as `python3` (the helpers support Python 3.9+). If it is
  missing, install it with `brew install python`.
- [Homebrew](https://brew.sh) packages:

  ```sh
  brew install cmake ninja
  ```

  The Vulkan loader and MoltenVK are **not** Homebrew packages here: they ship
  as pinned SDK submodules (`ReXGlue/thirdparty/vulkan-loader` and
  `ReXGlue/thirdparty/moltenvk`) and are built from source as part of the SDK, so
  the Homebrew `vulkan-loader`/`molten-vk` formulae are unused.
- Your own extracted FIFA Street (2012) game data, containing the three original
  modules: `default.xex`, `fifadllzf.xex.dll` and
  `dlc/dlc_FootballCompEng/dlc/FootballCompEng/FootballCompEngzf.xex.dll`.

The three modules are validated for the XEX2 magic and their SHA-256 values are
checked against the source-controlled supported set before a build starts; see
[Supported input revision](#supported-input-revision). Game data and generated
guest code are ignored by Git and must never be committed.

## Supported input revision

The recompiled guest startup hooks are keyed to fixed guest instruction addresses
(see [Guest startup ordering (macOS)](#guest-startup-ordering-macos)), so only
the exact original FIFA Street (2012) revision this source tree was validated
against can be recompiled correctly. `scripts/supported-macos-inputs.json`
records the SHA-256 of the three original modules, measured from our own
extracted GameData. It is a local, validated revision, **not** an externally
published official manifest.

`build-macos.sh` always enforces this set in preflight - before the SDK is
downloaded, guest code is generated or anything is compiled - and fails closed
with a clear error when a module hash differs:

```text
default.xex: SHA-256 mismatch (supported f4902a..., got ...)
GameData is not the supported FIFA Street (2012) revision.
Recompiled startup hooks target fixed guest addresses, so a different region or
revision cannot be compiled correctly.
```

If `FIFA_INSTALLER_MANIFEST` points at a release installer's `precompiled.json`,
it is cross-checked against the same set: a manifest describing a different
revision is rejected rather than silently authorizing a build.
`FIFA_SUPPORTED_INPUTS` can override the supported set, but that is an
advanced/test-only seam that prints a loud warning and does **not** enforce the
shipped revision guard; do not use it for a normal build.

**Version limitation.** Only this retail revision is supported and tested. Other
regions and revisions are unsupported and are rejected; none has been tested and
none is claimed.

## Quick start

From the repository root:

```sh
scripts/build-macos.sh --gamedata "/path/to/GameData"
```

The script:

1. clones ReXGlue recursively into `ReXGlue/` and checks out the pinned
   revision `c94f5ebdcb3c9d1a460ca48e04f9758448f8d518`;
2. verifies and applies `patches/rexglue-macos-base.patch` once
   (`git apply --check`, then `git apply`), then applies
   `patches/rexglue-macos-portability.patch` and
   `patches/rexglue-macos-drawable-recovery.patch` on top, in that order (the
   Windows code paths in the project patch are unchanged, including the
   recompiled-module loader);
3. configures and builds the ReXGlue SDK for `mac-arm64` with Vulkan enabled
   and Direct3D 12 disabled;
4. copies `Installer/recomp-template` into a build workspace, writes the
   manifest, and runs the code generator;
5. configures and compiles the host and the two guest modules.

It is idempotent: re-running reuses the SDK, the workspace and any generated
code. Use `--skip-sdk` to skip the SDK build once it exists, `--clean` to wipe
the game workspace and output, `--jobs N` to change the parallel job count
(default 2 for 16 GB machines), and `--arch x86_64` for an (experimental,
unverified) Intel build.

## Install and launch

After a successful build:

```sh
./scripts/install-macos.sh                 # installs into ~/Applications
open "$HOME/Applications/FIFA Street.app"
```

The installer copies only the built app and retains the absolute GameData
symlink. Keep the extract in place. It refuses a broken link or an existing
destination; use `--force` for an intentional update. `--dest` selects another
writable directory without sudo. You can also run the app directly from
`build/macos/out`, using Finder or `scripts/play-macos.sh`. Normal play has no
time limit; `run-macos-performance-check.py` is a separate bounded diagnostic.

For an incremental rebuild, rerun the build command. `--skip-sdk` reuses the
SDK tool build while the consumer still compiles its in-tree runtime. Package
verification compares host runtime and GPU plugin against canonical outputs.
SDK patches and source changes must be saved before a fresh clone can reproduce
them; read [AGENTS.md](../AGENTS.md) for the update/staging pitfalls.

## Logs and troubleshooting

The build writes configure/build logs under `build/macos/logs`. Every launch
through `scripts/play-macos.sh` writes its own
`build/macos/logs/play/<UTC>/fifastreet.log`. A `tail -f` command on that path
stays on that one session.

For a reusable live viewer, start this from the repository in Terminal 1:

```sh
./scripts/logs-macos.sh
```

Then launch in Terminal 2:

```sh
./scripts/play-macos.sh "$HOME/Applications/FIFA Street.app"
```

The viewer shows the latest session's last 20 lines and follows new lines. It
waits if no session exists and switches automatically when a newer session
starts, even if that session's log file has not appeared yet. You can keep it
open across multiple launches. **Ctrl+C stops only the viewer**, leaving the
game running. `FIFA_BUILD_ROOT` selects the same alternate build root for both
commands.

To pin an older session or change the initial history length:

```sh
./scripts/logs-macos.sh --session 20261010T112440Z --lines 50
```

This viewer follows normal-play sessions created by `play-macos.sh`. A Finder
double-click writes the runtime's default logs inside
`FIFA Street.app/Contents/MacOS/logs/`; it does not create a normal-play session
in the repository. Build logs and bounded performance-check traces are also
separate from normal-play logs. Driver messages written directly to stdout or
stderr (such as MoltenVK notices) remain in the launch Terminal; this viewer
streams the runtime's `fifastreet.log`.

- Compiler/licensing failure: install/select the required Xcode tools; review
  and accept the license yourself using `sudo xcodebuild -license` if needed.
- Unsupported game revision: inspect the hash mismatch; do not bypass the
  address-hook guard to force an untested revision.
- App cannot locate GameData: rerun packaging with the current absolute extract
  path; the installer does not copy or download the game.
- Stale runtime/GPU verification: rebuild and stage canonical outputs; a
  targeted dylib rebuild can leave next-to-host copies old.
- Keyboard profile differs: restore using the control guide and refresh the
  bundle or target its active config explicitly.
- First-launch compilation pause: cache state matters. Retain existing caches;
  new pipelines may still compile even with the Darwin reload fix.

The remaining sections document implementation details and opt-in development
tools, not extra steps required for normal play.

## Register table override (macOS only)

The code generator's embedded `register_cpp` template puts every
`registrar->SetFunction()` call in a single registration function. For the
`fifadllzf` module that is roughly 159k calls in one function, which is
pathological for the clang backend even at `-O0`.

The macOS build avoids that with a template override: `recomp-templates/` under
`Installer/recomp-template/` holds an alternative `codegen/register_cpp.inja`.
The script stages it into the workspace and writes a `template_dir` entry for
the entrypoint and each module in `fifastreet_manifest.toml`. The override
splits the calls into bounded chunk helpers (512 calls each) that the exported
entry point (`ReXModule_Register` for the DLLs, `fifastreet_RegisterFunctions`
for the entrypoint) calls in source order, so the registered address-to-symbol
sequence is identical to the unchunked output.

`template_dir` is set only by the macOS manifest; the Windows workflow keeps the
embedded template byte-for-byte. To force regeneration after editing the
override, re-run the build (the template files are codegen inputs, so the
codegen step reruns on their change).

## Recompiled module loading (macOS)

The code generator registers each recompiled guest module by its bare target
name (for example `fifastreet_fifadllzf_xex`). On Windows the loader appends
`.dll` and searches the loader path, so the name resolves the DLL staged next to
the host. POSIX `dlopen` uses the string verbatim and never rewrites it, so the
bare name does not match the CMake output `lib<target>.dylib`.

`patches/rexglue-macos-portability.patch` makes the Apple loader path map that
name to `<executable folder>/lib<target>.dylib` and reports the exact
`dlerror()` text when a load still fails. Windows stays byte-for-byte. The
`verify-macos-artifacts.sh` script exercises the mapping against the built
modules by `dlopen`-ing each `lib<target>.dylib` and checking that
`ReXModule_Register` and `ReXModule_GetImageInfo` resolve.

## Drawable/acquire recovery (macOS)

`patches/rexglue-macos-drawable-recovery.patch` closes a source gap in the
Vulkan presenter's handling of a MoltenVK swapchain-acquire failure. MoltenVK
reports `VK_ERROR_OUT_OF_POOL_MEMORY` from an acquire that could not obtain a
`CAMetalDrawable` to request that the swapchain be re-established, and it can
leave the acquire semaphore signaled even though the presenter drops the frame.
The patch classifies that result as a reconnect
(`src/ui/vulkan/swapchain_acquire_recovery.h`) and, at the safe
swapchain-retirement boundary where no in-flight work references them, replaces
the affected submission slot's acquire semaphore and fence
(`src/ui/vulkan/swapchain_acquire_sync_recovery.h`). Non-macOS paths are
unchanged.

The same patch also restores the `CAMetalLayer` drawable size after successful
swapchain recreation. In the pinned MoltenVK, a workaround for unfinished
presentations can reset that size to 1×1 after assigning the new extent. A
fixture reproduced this on resize while synthetic guest output continued. The
Mac presenter now restores the extent of the newly created swapchain.

What is and is not verified:

- Verified: the classification and the semaphore replacement are unit-tested
  (`scripts/test-macos-drawable-recovery.sh`: 45 checks - 22 classifier, 23
  acquire-sync - each RED-failing without the change), and the patch applies,
  reverses and coexists with the presentation-candidate patch.
- Verified: `scripts/test-macos-presenter-resize.sh` drives the real presenter,
  MoltenVK and an SDL diagnostic window with synthetic guest output. The
  original runtime left the drawable at 1×1 after resize; the updated runtime
  retains the surface extent. This checks drawable dimensions, not final screen
  pixels, and opens only its own fixture window without game assets or input.
- Manually verified: the owner confirmed that resizing the updated installed
  game works on the tested Mac. This and the fixture do not establish that every
  historical black screen, background transition or drawable-starvation case
  is fixed.

`scripts/test-macos-patch-sequence.sh` exercises the ordered application of the
three patches (through `scripts/rexglue-patches.sh`) against real pinned source
trees in temporary directories: a fresh apply, an incremental apply on top of the
base patches, a no-op re-run on a fully patched tree, and rejection of a
conflicting tree. It also covers the cases the ordering makes easy to get wrong:
a fully patched tree with an earlier patch's file reverted, a higher patch
present with a lower one missing, and a conflict in only the last patch (all
rejected with the tree left unchanged), plus an unrelated edit outside the hunks
(accepted and kept). The helper dry-runs the whole stack in an isolated copy of
the touched files before it writes anything, so a failure never leaves a
half-applied SDK.

## Guest startup ordering (macOS)

The recompiled entrypoint routine `sub_820509A8` (default.xex) spawns its worker
thread and only afterwards constructs the two `CEvent` objects at `this+0x4C` /
`this+0x50` that the worker signals on entry (`sub_82050928`). That ordering is
not synchronised in the guest: Xbox 360 is multicore, so the creating thread is
not guaranteed to reach the constructions before the worker runs. The host
scheduler exposes the race far more often, and when the worker wins it reaches
the signal path first and reads the still-NULL members, which faults as a guest
read of `0x00000004`.

The macOS build corrects the order at the guest level rather than changing the
runtime scheduler. `Installer/recomp-template/config/default_overrides.toml`
carries two codegen `[[midasm_hook]]` entries: one hoists both event
constructions ahead of the spawn, and one skips the now-redundant original
constructions (so the early wrappers are not overwritten and leaked). The hooks
call `ReStreetHoistStartEvents` / `ReStreetStartEventsHoisted` in
`Installer/recomp-template/src/guest_start_events.cpp`, which the host links on
Apple only. The hoist logic lives in the runtime-free
`Installer/recomp-template/src/guest_start_events_core.h` so it can be driven by
a behavioral test. This is a host-concurrency correction, not unmodified Xbox
semantics: no guard, fake success, timeout or scheduler change is involved, and
the guest instructions that follow the spawn are byte-for-byte unchanged.

The fix fails closed. If the object is not in the expected pre-spawn state (an
event slot or the thread handle is already set) or the guest allocator/constructor
fails, the hook logs a fatal diagnostic and terminates the process instead of
continuing into the spawn with a half-initialised object. It cannot reproduce
the original guest's out-of-memory behaviour, and returning into the known
unsafe spawn is the crash this fix removes, so failing before the spawn is the
deliberate choice. On the successful path each slot is written exactly once and
the generated skip then suppresses the original constructions.

`scripts/test-macos-startup-hook.sh` compiles and runs a behavioral test of that
logic against an injected guest allocator, event constructor and base memory: it
covers the normal case (exactly two constructions, both slots published, the
skip prevents double allocation) and every failure path (either allocation
fails, either constructor yields 0, or the precondition is violated) and asserts
that no failure publishes a slot.

`scripts/build-macos.sh` sets the entrypoint's `includes` to that config and,
after codegen, runs `scripts/verify-macos-startup-order.py`. The verifier aborts
the build if the hooks did not land at the expected guest instructions, so a
drift in the guest image, SDK or config fails closed instead of silently
dropping the fix. The Windows manifest keeps the entrypoint `includes` empty, so
the Windows guest code is unchanged.

## Output layout

Everything is written under git-ignored paths:

```text
ReXGlue/                             pinned SDK checkout
build/macos/work/FifaStreetRex/       game build workspace (resume here)
build/macos/out/                      final binaries
build/macos/logs/                     configure, build and codegen logs
private/mac-build/extract/            extracted game data
```

`build/macos/out` contains:

```text
fifastreet
libfifastreet_fifadllzf_xex.dylib
libfifastreet_FootballCompEngzf_xex.dylib
librexgpu-xenos.dylib                GPU emulation plugin (runtime-loaded)
vulkan/                              bundled Vulkan loader + MoltenVK + ICD
librexruntime.dylib, ...             runtime libraries staged beside the host
fifastreet.toml                      macOS runtime configuration
```

To run, put `GameData` next to the host and launch `fifastreet`. The app looks
for `default.xex` in the executable folder, a `GameData` subfolder, or the
parent folder; `--game_data_root=/absolute/path/GameData` overrides that. The
two recompiled guest modules are loaded by their bare codegen target name, which
the runtime maps to `lib<target>.dylib` beside the host (the Portability patch
below explains why POSIX needs that mapping).

## Application bundle (macOS)

`scripts/build-macos.sh` also assembles a normal, double-clickable bundle at

```text
build/macos/out/FIFA Street.app
```

so the game can be launched through Finder or `open` instead of only from a
terminal. The bundle is produced by `scripts/package-macos-app.sh`, which can be
re-run on existing staged files without rebuilding:

```sh
scripts/package-macos-app.sh --out build/macos/out --gamedata "/path/to/GameData"
```

Layout (executable and every `@executable_path` dependency stay in
`Contents/MacOS`, because the host's rpath is `@executable_path` and the runtime
resolves the recompiled modules, the GPU plugin, the Vulkan loader and the
config relative to the executable folder):

```text
FIFA Street.app/Contents/Info.plist          bundle metadata (APPL, org.restreet.fifastreet.dev)
FIFA Street.app/Contents/PkgInfo
FIFA Street.app/Contents/MacOS/fifastreet    host executable
FIFA Street.app/Contents/MacOS/lib*.dylib    runtime, guest modules, GPU plugin
FIFA Street.app/Contents/MacOS/fifastreet.toml
FIFA Street.app/Contents/MacOS/vulkan/       Vulkan loader + MoltenVK + ICD
FIFA Street.app/Contents/MacOS/GameData      symlink to the private extract
```

`GameData` is a symlink to the private game-data tree, never a copy, so no game
assets land in the repository or the bundle. Automatic discovery finds it
(`<exe folder>/GameData`), and `--game_data_root=` still overrides it. The bundle
is assembled in a temporary directory and moved into place so every repackage
yields fresh inodes; rewriting a signed Mach-O in place keeps the old vnode and
macOS then kills the next launch (see the staging note in
`build/macos/logs/startup-order-fix.summary.txt`).

`scripts/verify-macos-app.sh` checks the bundle: plist validity, the host and
dylibs at the expected architecture, the bundled runtime byte-matches the
linker's canonical output, the recompiled modules `dlopen` from
`Contents/MacOS`, and the `GameData` symlink resolves to a directory containing
`default.xex`.

## Rendered-frame capture (macOS)

To prove the guest actually renders, the app has an opt-in diagnostic that reads
the guest output image through the SDK's existing presenter readback
(`rex::ui::Presenter::CaptureGuestOutput`). It runs entirely inside the process -
no OS screen capture, accessibility automation or window-server permission is
used - and the Vulkan backend already implements the GPU copy-to-buffer, so no
extra renderer code is involved.

It is enabled only when `RESTREET_CAPTURE_DIR` names a directory. With the
variable unset the worker is never started and a normal run has no capture cost
or side effects. When set, a background worker spawned in `OnPostSetup` captures
at 2, 5, 10, 20, 40 and 60 seconds and writes each frame as a binary PPM plus a
`capture-metadata.txt` line (time, dimensions, stride, byte count, non-black
pixel count and an RGB checksum). A readback that returns no guest output is
reported as `result=no_guest_output` and no image is written. The worker is
stopped and joined in `OnShutdown`, before the runtime and presenter are
destroyed.

Setting `RESTREET_CAPTURE_INTERVAL_MS` as well switches the worker to
**continuous latest-frame mode**, which is the observation stream for ongoing
evaluation: instead of the fixed six-shot schedule it re-reads the newest guest
frame every bounded interval and overwrites a single `latest.ppm`, so a local
consumer can always open the most recent frame and no per-frame files pile up.
The interval is clamped to 250..10000 ms; empty or non-numeric text falls back to
1000 ms. The image is written by a sibling temp file and an atomic rename, so a
reader sees a whole frame (the previous one or the new one), never a partial
write, and the paired `latest-frame.txt` (frame index, elapsed, UTC timestamp,
interval, dimensions, checksum, `new_frame`, and the result) is updated the same
way. Readback failures update `latest-frame.txt` but leave the last good
`latest.ppm` in place. The worker is never started, and no file is created, when
`RESTREET_CAPTURE_DIR` is unset; logs are emitted only on the first capture and
on ok/fail transitions, never per frame.

```sh
RESTREET_CAPTURE_DIR=/tmp/frames \
  "build/macos/out/FIFA Street.app/Contents/MacOS/fifastreet" \
  --game_data_root="/path/to/GameData"

# Continuous latest-frame stream every 1000 ms.
RESTREET_CAPTURE_DIR=/tmp/frames RESTREET_CAPTURE_INTERVAL_MS=1000 \
  "build/macos/out/FIFA Street.app/Contents/MacOS/fifastreet" \
  --game_data_root="/path/to/GameData"
```

`scripts/capture-macos-frames.sh` wraps this: it launches the bundle binary with
a bounded runtime (70–85 s), stops and reaps only the process it started, and
converts the PPMs to PNG with `sips`. The layout validation, statistics and PPM
encoding live in `src/guest_frame_capture_core.h`, free of any SDK dependency, so
`scripts/test-macos-frame-capture.sh` can drive them with synthetic images.

## Virtual gamepad bridge (macOS)

For AI evaluation and scripted control, an opt-in bridge exposes a purpose-built
SDK input driver as one or two virtual Xbox 360 gamepads. It does not use OS
keyboard events, window automation, accessibility permissions or screen capture:
the driver answers the guest's `XamInputGetState` polls exactly like a physical
pad would. It is off by default and inert unless an environment variable is set.

Two environment variables control it:

- `RESTREET_CONTROL_SOCKET` - absolute path of the Unix-domain socket the driver
  binds. Unset, the whole bridge is absent: the SDK's default input factory is
  used unchanged and no thread or socket is created.
- `RESTREET_CONTROL_MODE` - `ai-ai` (default) or `human-ai`.

Modes:

- `ai-ai`: virtual pads on guest users 0 and 1. Physical pads, the keyboard and
  the NOP stand-in are dropped, so nothing else can contaminate either slot.
- `human-ai`: virtual pad 1 is added on guest user 1; every other device behaves
  as before (physical pads by ordinal, keyboard/mouse and synthetic devices on
  user 0). Keyboard-as-player-1 is not implemented and is not claimed.

The socket lives under an owner-only directory and is created mode 0600. An
existing regular file or another live bridge socket at that path is never
unlinked: the driver fails explicitly and leaves the default input in place. A
stale (dead) socket is replaced.

### Control protocol

One request per 24-byte little-endian frame, one 16-byte response:

```text
magic u32 "RSTP" = 0x52535450   version u8 = 1
command u8 (1 state, 2 press, 3 release, 4 ping)
player u8 (0 or 1)              reserved u8 = 0
buttons u16                     (XInput bitmask)
left_trigger u8 right_trigger u8
thumb_lx/ly/rx/ry i16           (little-endian, -32768..32767)
hold_ms u32                     (0 = until released; clamped to 10 minutes)
```

The response echoes magic/version/status/player and the effective button mask
plus the driver's packet number. Wrong magic, version, command or player, or a
short frame, is rejected with a status and does not change state.

State is connection-scoped: a command sets state that lives while its socket
connection is open (and no longer than `hold_ms` if set). A client that
disconnects has everything it held cleared, so a crash cannot leave a button
stuck. The guest poll never touches the socket - a receiver thread owns it - so
a stalled client cannot stall the guest. The packet number only advances when the
effective state changes, and state is written into the big-endian
`X_INPUT_STATE`.

### CLI

`scripts/gamepad-macos.py` (Python 3 stdlib) speaks the protocol:

```sh
# ai-ai: Start pulse on the AI player (slot 0), 0.6 s by default.
RESTREET_CONTROL_SOCKET=/tmp/restreet-ctl.sock \
  scripts/gamepad-macos.py press --player 0 --button Start

# ai-ai: full state - A held with the left stick hard right for 1.5 s.
scripts/gamepad-macos.py state --player 1 --buttons A --lx 1.0 --hold 1.5

# release a button, or --all / no --button to release everything.
scripts/gamepad-macos.py release --player 0 --button Start

# human-ai: only player 1 is bridged; player 0 is refused.
scripts/gamepad-macos.py press --player 1 --button Start
```

Run the game with the bridge, e.g. from the bundle:

```sh
RESTREET_CONTROL_SOCKET=/tmp/restreet-ctl.sock RESTREET_CONTROL_MODE=ai-ai \
  "build/macos/out/FIFA Street.app/Contents/MacOS/fifastreet" \
  --game_data_root="/path/to/GameData"
```

`scripts/probe-virtual-input.sh` runs a bounded behavioural probe: it launches
the app with the bridge and the frame capture enabled, sends a short pulse
sequence after the title screen is up, stops and reaps only its own process, and
converts the captured frames to PNG. It never accepts a legal/EULA prompt or
signs in; it only holds a button briefly.

### Tests

`scripts/test-macos-virtual-input.sh` compiles and runs the behavioural test
(`Installer/recomp-template/test/control_bridge_test.cpp`) against the real
protocol codec, pad state, slot assignment and receiver server: slot 0/1 routing
and isolation, big-endian guest state, packet/TTL/release, invalid
player/axes/protocol, socket collision, client-death cleanup and shutdown/unlink.

### Keyboard mappings and normal play

See [CONTROLS-MACOS.md](CONTROLS-MACOS.md) for the full arrow/Space profile and
customization. The source profile is `config/macos/keyboard-arrows.toml`; native
builds append it to the runtime config. Xbox prompts remain in the game.

```sh
./scripts/play-macos.sh
```

This uses the canonical `${FIFA_BUILD_ROOT:-build/macos}/out/FIFA Street.app`
with no timer. Pass another bundle as its positional argument. It never selects
a historical candidate automatically. Logs are under
`build/macos/logs/play/<UTC time>` (or the selected build root).

A normal Finder launch and the play script both use the persisted stable Mac
config: host unpaced presentation, sleeping idle toast/exit overlays and a
process-local synchronous MoltenVK default applied before Vulkan creation.
Explicit MoltenVK environment overrides are respected. Guest vsync and full
resolve readback are retained; the Mac clock fix does not use the bypass.

```sh
./scripts/apply-macos-keyboard-profile.sh
./scripts/package-macos-app.sh --gamedata "/absolute/path/to/GameData"
bash scripts/test-macos-keyboard-profile.sh build/macos/out
```

The reapply helper restores bindings in an existing staged config; repackage to
refresh its separate bundle copy. To update an installed app, pass its config
path explicitly. The real MnK test covers releases, movement+sprint+pass and the
exit shortcut; individual skill moves still need manual checks.

The optional input diagnostic patch remains outside the normal build and off by
default. Preserve the current instruction against automating the owner's game
window: old virtual-input/probe helpers are development tools, not authorization
to run them during manual play.

## Runtime configuration

The build writes `fifastreet.toml` beside the host. ReXApp reads it from the
executable folder as `<app_name>.toml`, and it carries the macOS rendering and
input defaults: a 1280x720 windowed video mode, vsync, MoltenVK device
auto-selection, and the same GPU workarounds the Windows release uses. It also
enables `mnk_mode`, so a keyboard can drive the emulated controller with the
arrow/Space profile; SDL gamepads are supported alongside. The source config is
`config/macos/fifastreet-runtime.toml`, combined with the keyboard profile by the
build. Rebuilding rewrites the staged config from these templates.

Game data location is not set from this file: ReXApp resolves the path CVars
before it loads the configuration, so a `game_data_root` entry would be ignored.
Use the automatic discovery above or pass `--game_data_root=` on the command
line. Any other cvar can be set in the file or with `--<cvar>=<value>`.

## Configuration, logs and saves (macOS)

The macOS runtime uses ReXGlue's POSIX defaults, which are not macOS-native:

- The configuration is read from, and logs are written to, the executable
  folder: `<exe folder>/fifastreet.toml` and `<exe folder>/logs/`. In the bundle
  that is `FIFA Street.app/Contents/MacOS/`.
- User data (saves and settings) and the shader cache are written under
  `$HOME/.local/share/fifastreet` and `$HOME/.local/share/fifastreet/cache`
  (ReXGlue's POSIX user-folder default, honouring `XDG_DATA_HOME` if set).

Because the configuration and `logs/` live inside the bundle, an app copied to a
read-only location cannot save settings or write logs; keep the bundle in a
writable folder for now. Moving these paths to `~/Library/Application Support`
is a known follow-up that needs runtime (SDK) changes and is deliberately not
part of this workflow.

## Updating the runtime (targeted rebuild)

`librexruntime.dylib` is the one shared library that can be rebuilt on its own:

```sh
cmake --build --preset mac-arm64-release --parallel 2 --target rexruntime
```

The linker writes the canonical library to
`build/macos/work/FifaStreetRex/out/build/mac-arm64-release/runtime/librexruntime.dylib`.
The copy next to the host in that same build directory comes from the host's
POST_BUILD step, which a `--target rexruntime` build does not re-run, so it can
be stale. `scripts/build-macos.sh` stages the canonical file last and refuses to
continue if the staged copy does not match it, so both a full and a targeted
build ship the current runtime. To update an existing `out/` by hand, copy the
canonical file over `out/librexruntime.dylib`; `scripts/verify-macos-artifacts.sh`
compares the two and fails on a mismatch.

## Manual steps

The script mirrors these commands; run them from the repository root if you
prefer to drive the build yourself. The examples below use the `mac-arm64`
presets; for an (experimental) Intel build substitute `mac-amd64` and
`mac-amd64-release`, or just run `scripts/build-macos.sh --arch x86_64`, which
mirrors all of this (and is the source of truth).

### 1. Prepare ReXGlue

```sh
git clone --recursive https://github.com/rexglue/rexglue-sdk.git ReXGlue
git -C ReXGlue checkout c94f5ebdcb3c9d1a460ca48e04f9758448f8d518
git -C ReXGlue submodule update --init --recursive
# -C ReXGlue runs git as if started in ReXGlue/, so a patch path relative to
# that directory (../patches) resolves to the repository's patches/. Use the
# absolute path anyway, so the command works from any shell directory.
git -C ReXGlue apply --check "$PWD/patches/rexglue-macos-base.patch"
git -C ReXGlue apply "$PWD/patches/rexglue-macos-base.patch"
# macOS portability fix applied on top of the project patch.
git -C ReXGlue apply --check "$PWD/patches/rexglue-macos-portability.patch"
git -C ReXGlue apply "$PWD/patches/rexglue-macos-portability.patch"
# macOS drawable/acquire recovery, applied last (after the portability fix).
# The three patches form a stack: scripts/rexglue-patches.sh dry-runs the whole
# stack in an isolated copy, then applies exactly the missing ones in this order,
# and rejects a conflicting or partially patched tree without writing anything.
git -C ReXGlue apply --check "$PWD/patches/rexglue-macos-drawable-recovery.patch"
git -C ReXGlue apply "$PWD/patches/rexglue-macos-drawable-recovery.patch"
```

Do not assume a newer ReXGlue revision is compatible with the patch. The patch
stack can also be applied with `scripts/rexglue-patches.sh ReXGlue <patch>...`,
and `scripts/test-macos-patch-sequence.sh` verifies the apply/idempotence/conflict
behaviour of that helper against real pinned trees.

### 2. Build the SDK

```sh
CC=/usr/bin/clang CXX=/usr/bin/clang++ \
cmake --preset mac-arm64 -S ReXGlue \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
  -DREXGLUE_USE_VULKAN=ON -DREXGLUE_USE_D3D12=OFF \
  -DREXGLUE_ENABLE_TRACY=ON
cmake --build ReXGlue/out/build/mac-arm64 --config Release --parallel 2
```

`REXGLUE_ENABLE_TRACY=ON` is what `build-macos.sh` passes; without it the
`libTracyClient` the host links is not built. The code generator is written to
`ReXGlue/out/mac-arm64/Release/rexglue`.

### 3. Generate guest code

The project game CMake includes `generated/default/dll_targets.cmake` at
configure time, so code generation must run before the game is configured. Copy
the template (including `recomp-templates/`), write `fifastreet_manifest.toml`
with absolute game-data paths and, for the entrypoint and each module, a
`template_dir` pointing at the staged `recomp-templates` directory, plus the
entrypoint `includes = ["config/default_overrides.toml"]` for the startup
ordering hooks (see "Guest startup ordering (macOS)"), then:

```sh
cd build/macos/work/FifaStreetRex
"/path/to/ReXGlue/out/mac-arm64/Release/rexglue" codegen fifastreet_manifest.toml
```

### 4. Compile the game

```sh
cd build/macos/work/FifaStreetRex
CC=/usr/bin/clang CXX=/usr/bin/clang++ \
cmake --preset mac-arm64-release \
  -DREXSDK_DIR=/path/to/ReXGlue \
  -DREXGLUE_USE_VULKAN=ON -DREXGLUE_USE_D3D12=OFF \
  -DREXGLUE_OUTPUT_DIRECTORY="$PWD/out/build/mac-arm64-release/runtime" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
cmake --build --preset mac-arm64-release --parallel 2
```

## Windows path

The Windows source workflow is unchanged. `Installer/BuildFifaStreet.ps1`,
`docs/BUILDING.md` and the MSVC/D3D12 presets remain the supported path for
producing the released Windows build.

## Troubleshooting

- `clang++ not found` or a license error: run `xcode-select --install` and
  `sudo xcodebuild -license`, then review and accept the agreement yourself.
- `cmake not found`: `brew install cmake ninja`.
- Vulkan runtime errors at launch: confirm the `vulkan/` folder sits next to
  `fifastreet`. The SDK stages the loader, MoltenVK and `MoltenVK_icd.json`
  there on every link.
- Missing original module: check `GameData`, including the DLC subtree for
  `FootballCompEngzf.xex.dll`.
- Out-of-memory while linking: keep `--jobs 2`.
- Stale or partial generated code: re-run with `--clean`.
