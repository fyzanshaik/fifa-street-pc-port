# Validation and known limitations

Last updated: **10 October 2026** for Mac support. The Windows section retains
the original **8 October 2026 / ReStreet v1.0** (offline-only) validation record.
This page separates what was tested from what was not.

## What was tested for v1.0

All of this was tested by the developer on one Windows 11 PC with an AMD Radeon RX 9070 XT, at 100% display scale unless stated.

| Check | Result |
|---|---|
| Clean installation from the original ISO with the final installer | Passed |
| Update over an existing installation that has a save | Passed, save kept |
| Direct3D 12: gameplay | Passed |
| Vulkan: gameplay | Passed |
| Windows display scale 125% and 150% (launcher and installer) | Passed |
| Exit shortcut (START + B) and FPS counter (Home) | Passed |
| Small screens: launcher shrinks to fit a reduced work area | Checked in a simulated 700 px high work area |

The game binaries (main module, game module and World Tour module) are the same as in v0.4.1. World Tour, Practice, Direct3D 12 and Vulkan were validated on earlier releases; this release changes the launcher, installer, overlays and performance options.

## Graphics backends

The package contains two validated backend folders, `Game/Backends/D3D12` and `Game/Backends/Vulkan`. The launcher copies the selected backend's `rexruntime.dll` and `rexgpu-xenos.dll` beside `fifastreet.exe` before launch. Direct3D 12 is the default.

### SHA-256 of the backend files in v1.0

| Backend | `rexruntime.dll` | `rexgpu-xenos.dll` |
|---|---|---|
| Direct3D 12 | `941DA42DFBA505F7F011ED81A6C7F6FD31EA2B3ED717810EF8C3E6EF89B56030` | `CC583314A05B11E49910CE0600E69EDD8B51B4C84D63641B7088916BB95551A2` |
| Vulkan | `E4DD721D6D080705B8685E14F8437583CCE7DE2A35298BEAE04B4A91372E5E0F` | `B53E030B6C41EC017F97D53F657C9B8850BB5BEDFE2A0A034EE4871F182DC688` |

The installer checks its payload against the hashes in its own manifest before installing.

## Performance options

- **Profiles:** Balanced (the launcher defaults), Quality (2x internal resolution, FXAA Extreme, MSAA), Performance (native resolution, no post-processing, Fast readback, occlusion queries off) and Custom. They only set options the launcher already has.
- **Readback Resolve:** Full is the validated mode and the default. The Performance profile uses Fast, which gives more FPS under heavy GPU load but has not been validated on other hardware. Some can cause visible graphical corruption and is not used by any profile.
- **Shader cache:** a small set of pre-built shaders ships in `Game/shader-seed` and is copied into the player's cache on the first run. It never replaces files the player already has.

## Resolution model

Output resolution and internal rendering scale are independent. Internal resolution is a whole-number multiple of the game's 1280x720 base: 1x is 1280x720, 2x is 2560x1440, 3x is 3840x2160 and 4x is 5120x2880. Higher settings are available for testing and are not a performance guarantee.

## macOS source-build preview — 10 October 2026

Apple Silicon is the tested target. The owner reports good gameplay, and the
latest normal-clock main-menu comparison reports improved music and movement.
Further performance work is paused to finish install/play reliability and
controls. This is not a prebuilt Mac release or a claim of sustained 60 FPS.

| Check | Current evidence |
|---|---|
| Native arm64 build, `.app`, dependencies and guest dylib loading | Passed on the test MacBook |
| Manual progress to menu and playable matches | Reported by owner |
| Latest normal-clock main-menu music / movement | Improved; bounded run exited cleanly |
| Late new displayed outputs in that menu check | About 24.6/s; not simulation FPS |
| Keyboard profile | Real MnK fixture checks 25 bindings, releases and simultaneous movement+sprint+pass |
| Guest clock | Rate defect reproduced before fix; anchored conversion/concurrency/TSAN and public time controls pass |
| Idle waits, dormant overlays and shader-cache reload | Focused regressions pass; manual comparisons show improvements |
| Acquire/drawable recovery | Classifier/sync tests and build pass; all live resize/background cases remain unverified |
| Save/reload, every mode, multiple controllers, long sessions | Not fully verified |
| Intel Mac | Untested |
| Agentic model matches / deterministic evaluations | Future work; local control/capture tools are experimental |

Use [BUILDING-MACOS.md](BUILDING-MACOS.md) for installation and
[CONTROLS-MACOS.md](CONTROLS-MACOS.md) for keys. The single consolidated
[LOG/PROGRESS.md](../LOG/PROGRESS.md) contains the historical black-screen,
severe-menu/audio reports, measurements, successful fixes, failed comparisons
and operating lessons. Original game files and generated guest code stay local.
