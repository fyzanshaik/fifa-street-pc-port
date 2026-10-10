# Agent guide — ReStreet macOS fork

Read [README.md](README.md), [LOG/PROGRESS.md](LOG/PROGRESS.md) and
[docs/BUILDING-MACOS.md](docs/BUILDING-MACOS.md) before changing this port.
The progress log is the canonical account of findings, measurements, failed
experiments and current limits. Older diagnostic documents retain historical
detail; their early status statements do not describe the latest build.

## Objective and current priority

Make FIFA Street (2012) usable and reproducible on Apple Silicon macOS, using
the owner's own game data. The longer-term goal is human/AI and AI/AI game
benchmarks. Model APIs and deterministic evaluation are future work. Gameplay
is now reported good; deeper optimization is paused. Prefer install/play
reliability, controls and clear documentation to unrequested tuning.

This is a recompilation project, not the original EA source code. The host,
runtime patches, build scripts and generated-code templates can be modified;
generated guest code comes from original binaries and is not committed.

## Agent coordination

- Codex owns scope, architecture, documentation, evidence review and Git delivery.
- By default, delegate implementation, application code and focused tests to
  OpenCode; Codex handles notes and final review. Use a fresh **Build** session
  with the configured official DeepSeek provider (`deepseek/deepseek-flash` at the time
  of this work). Use **Plan** for read-only investigation. Verify the actual
  execution provider/model from session metadata; do not change global models
  or authentication. Do not substitute OpenCode Go silently.
- The latest user direction takes precedence. Do not start extra workers after
  a request to work without agents. For this release preparation the user
  explicitly requested OpenCode for implementation and Codex for notes/README.
- Give bounded tasks, file ownership, acceptance checks and a report. A worker's
  done state is not proof. Shared infrastructure mutations must be serialized;
  parallel writers require isolated worktrees or non-overlapping ownership.
- If actually inside Herdr, read `herdr --skill` and installed help; use one
  separate tab per worker in the current project, preserve cwd and `--no-focus`.
  Capture returned IDs rather than guessing. If not in a verified Herdr pane,
  use the installed OpenCode CLI rather than controlling an arbitrary UI pane.
- Keep tracker work in the parent. Do not create issues, messages or unrelated
  integrations just to execute this repository task.

## Repository layout

| Path | Role |
|---|---|
| `Installer/recomp-template/` | Host, startup hooks, opt-in controller/capture seams and generator templates |
| `patches/` | Saved SDK changes; the ignored SDK checkout is not the deliverable |
| `config/macos/` | Mac runtime/key profiles |
| `scripts/` | Build, package, verify, play, diagnostics and focused tests |
| `docs/BUILDING-MACOS.md` | Current setup/rebuild/install guide |
| `docs/CONTROLS-MACOS.md` | Complete keyboard reference |
| `LOG/PROGRESS.md` | Consolidated engineering history and agent handoff |
| `LOG/evidence/` | Small, sanitized measurement summaries; no original game material |
| `ReXGlue/`, `build/`, `private/` | Ignored local SDK, generated code, binaries, raw traces and game data |

## Build and play

Use the repository root as cwd. Verify Xcode licensing and a supported C++23
toolchain before building. Never accept an agreement or change authentication
on the user's behalf as part of setup.

```sh
./scripts/build-macos.sh --gamedata "/absolute/path/to/GameData" --check-only
./scripts/build-macos.sh --gamedata "/absolute/path/to/GameData" --jobs 2
./scripts/play-macos.sh
```

Use `./scripts/logs-macos.sh` in another Terminal to watch normal-play sessions.
It may start before the game and follows each new session automatically; Ctrl+C
stops the viewer only. Finder launches use separate logs inside the bundle.

Normal play is unbounded. Diagnostic runs are explicitly bounded and must say
when the game will close. **Do not automate the game window or inject game
input under the current user instruction.** Human checks drive menus and
gameplay; headless tests of our own fixtures are permitted. Do not launch the
game while the owner is away or run benchmarks/heavy builds during a manual
performance comparison. Stop only the process you launched, gracefully, and
preserve the actual game exit result.

## Preserve the validated configuration

- Pinned SDK: `c94f5ebdcb3c9d1a460ca48e04f9758448f8d518`.
- Ordered production stack: `rexglue-macos-base.patch`, then
  `rexglue-macos-portability.patch`, then `rexglue-macos-drawable-recovery.patch`.
  Use `scripts/rexglue-patches.sh`; do not apply old presentation/input experiment
  patches on top or decide stack state from one reverse-check.
- Mac uses Vulkan/MoltenVK, synchronous queue submission, unpaced **host**
  presentation and idle toast/exit suppression. Guest vsync stays enabled;
  resolve readback remains `full`. Keep `clock_no_scaling=false`; the clock
  bypass is a diagnostic experiment, not the fix.
- Do not change audio queue capacity or remove completion waits without a
  failing correctness test and a controlled measurement supporting the change.
- Keep the runtime/key templates in root TOML scope; the build concatenates
  them. Real-table profile tests must load through the SDK, because text-only
  preservation tests missed bindings accidentally scoped under `[custom]`.
- Keep arrow/Space controls and avoid bare Shift/Ctrl/Alt bindings: the SDK's
  exact modifier matching can suppress simultaneous movement.
- Keep Windows behavior and original license/author notices. Intel Macs remain
  unverified; successful compilation on Apple Silicon says nothing about Intel.

## Rebuild and patch pitfalls

1. Edit source in `Installer/recomp-template/`; the build workspace is a copy.
   Generated guest source is overwritten. Persistent guest changes need an
   override/template/hook and supported-input validation.
2. SDK edits in ignored `ReXGlue/` must be represented in the appropriate saved
   patch. Generate portability diffs against the local-changes-applied SDK base,
   excluding recovery changes that belong to the following patch.
3. Rebuild the **consumer host**, runtime and GPU plugin after UI/host integration
   changes. `ReXApp` is compiled into the host; updating only dylibs missed a
   real wakeup fix during this investigation.
4. Stage canonical `runtime/librexruntime.dylib` and
   `runtime/librexgpu-xenos.dylib` from the game build tree, not possibly stale
   copies beside the executable. Bundle verification compares actual bytes.
5. Package Mach-O files through fresh staging inodes. In-place overwrites can
   retain macOS code-signature vnode state and cause a launch to be killed.
6. A moved `.app` still needs its absolute GameData link to resolve. No game data
   is embedded. Preserve existing shader caches and saves during diagnostics.
7. Mac builds use `rexglue-macos-base.patch`, an exact copy of the tested
   pre-v1.1 base patch. Windows keeps its newer `rexglue-local-changes.patch`.
   Do not switch the Mac builder to that Windows patch without separate stack,
   ABI, rebuild and gameplay validation.

## Validation and measurement

Run checks appropriate to the change, and capture exact commands/results:

```sh
bash scripts/test-macos-patch-sequence.sh
bash scripts/test-macos-guest-clock.sh
bash scripts/test-macos-runtime-clock.sh build/macos/out
bash scripts/test-macos-keyboard-profile.sh build/macos/out
bash scripts/test-macos-install.sh
bash scripts/test-macos-logs.sh
bash scripts/test-macos-host-defaults.sh
bash scripts/test-macos-runtime-config.sh
bash scripts/test-macos-shader-storage.sh build/macos/out
bash scripts/verify-macos-artifacts.sh build/macos/out
bash scripts/verify-macos-app.sh "build/macos/out/FIFA Street.app"
```

Tests require their documented SDK/runtime inputs. Inspect each script's help
and arguments; some older diagnostic fixtures default to a historical candidate
directory, so pass the intended output explicitly. Use `rg --files --no-ignore`
when inspecting ignored generated code/logs. Do not invent a pass for a test
that was only syntax-checked or a manual run that was never performed.

Host presents can repeat the same frame. New-output cadence is not simulation
FPS. Stack sample counts are wall observations, not CPU percentages. Fence,
register and nested pipeline durations overlap; do not add them. GPU timestamp
spans cover the instrumented principal commands, not the whole frame. Preserve
dropped-event counts, cache state, instrumentation, screen boundaries, machine
and audio-device differences. Zero backend-inserted silence does not prove
perfect physical playback. An interrupted wrapper (130) is not a game crash
when its child exits cleanly.

## Publication and handoff

`origin` is the owner's fork, `upstream` is SamuelitoDaVila's repository. The
Mac support is merged into `main`; `macos-support` retains the original delivery
checkpoint. Push only when requested, after review and checks;
never force-push or replace unrelated upstream history. Do not publish original
game assets, generated guest code, private absolute paths, provider credentials,
core dumps, binaries or large raw traces. Preserve raw diagnostics locally and
commit sanitized small evidence with provenance and limitations instead.

Update `LOG/PROGRESS.md` after meaningful work: problem, hypothesis, change,
evidence, outcome, failures/lessons and remaining verification. Keep README and
build/control instructions consistent with the shipped scripts. Describe
agent/evaluation features as experimental until actual matches and measured
model comparisons prove them.
