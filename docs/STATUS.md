# Validation and known limitations

Last updated: **10 October 2026** for Mac support. The Windows section retains
the upstream **9 October 2026 / ReStreet v1.1** validation record. This page
separates what was tested from what was not.

## What was tested for v1.1

All of this was tested by the developer on one Windows 11 PC with an AMD Radeon RX 9070 XT, at 100% display scale unless stated.

| Check | Result |
|---|---|
| ReStreet logos on the main menu and the Press Start screen (final installer, default `Mods` folder) | Passed |
| Direct play (`--play` and the desktop shortcut) | Passed |
| Direct3D 12: VSync (paced mode) | Passed |
| Vulkan: gameplay with the new "Some" readback | Passed |

Tested on v1.0 and not repeated for v1.1: clean installation from the original ISO, update over an existing installation with a save, Windows display scale 125% and 150%, the exit shortcut and the FPS counter.

**Not yet tested on v1.1:** a clean installation from the ISO with the v1.1 installer, an update of a v1.0 installation with a save using the v1.1 installer, Vulkan with VSync on.

The game binaries (main module, game module and World Tour module) are the same as in v0.4.1. World Tour, Practice, Direct3D 12 and Vulkan were validated on earlier releases; this release changes the graphics readback, VSync, the launcher, the installer and the logo patch.

## Graphics backends

The package contains two validated backend folders, `Game/Backends/D3D12` and `Game/Backends/Vulkan`. The launcher copies the selected backend's `rexruntime.dll` and `rexgpu-xenos.dll` beside `fifastreet.exe` before launch. Direct3D 12 is the default.

### SHA-256 of the backend files in v1.1

| Backend | `rexruntime.dll` | `rexgpu-xenos.dll` |
|---|---|---|
| Direct3D 12 | `809AFAD3E2DBDCD68C88B39365FF54EECBEF4E1DE4698A936C2F2D1CC368F4E0` | `9DDB0DD0BB4916A16AB4B757261CDF37E0B0EAB16F40DC9EA76233510E453E7C` |
| Vulkan | `F3FC94EF7EF154A737C7143FA96874C2225FA84D8577DD9428105524E0B5954E` | `BA05650F760A0C768C60C531854A925CB9E600A8C8E7425B160B6C95FF59251B` |

The installer checks its payload against the hashes in its own manifest before installing.

## Performance options

- **Profiles:** Balanced (the launcher defaults), Quality (2x internal resolution, FXAA Extreme, MSAA), Performance (native resolution, no post-processing, Fast readback, occlusion queries off) and Custom. They only set options the launcher already has.
- **Readback Resolve:** Some is the default in the Balanced and Quality profiles since v1.1: it was reworked to avoid the graphical garbage it used to cause, and it was tested on one GPU only. Full (compatible) is the old default. The Performance profile uses Fast, which gives more FPS under heavy GPU load but has not been validated on other hardware.
- **Shader cache:** a small set of pre-built shaders ships in `Game/shader-seed` and is copied into the player's cache on the first run. It never replaces files the player already has.

## Resolution model

Output resolution and internal rendering scale are independent. Internal resolution is a whole-number multiple of the game's 1280x720 base: 1x is 1280x720, 2x is 2560x1440, 3x is 3840x2160 and 4x is 5120x2880. Higher settings are available for testing and are not a performance guarantee.

## Not tested

- Any GPU other than the AMD Radeon RX 9070 XT (an RX 6700 was used on earlier releases). NVIDIA and Intel graphics have not been tested.
- Weak or old PCs. The system requirements in the README are estimates.
- The Performance profile on a PC where the GPU is the limit.
- Other ISO regions or revisions: the installer accepts only builds that match the three verified module hashes.
- Long World Tour careers, all venues, all controller types and long play sessions.
- Windows 10.

## Known limitations

- No universal hardware, driver or frame-rate guarantee. 3x/4x internal rendering and 4K output are not guaranteed 60 FPS modes.
- No online play in v1.1.
- The window title of the game itself still reads "FIFA Street PC"; the launcher and installer use the ReStreet name.
- The exit prompt only opens with the START + B (START + Circle) shortcut, not from the main menu.
- The installer expands its details panel by 180 px, which does not fit on screens 768 px high or less.
- Free-space requirements depend on extraction and temporary files.

## Development method

SamuelitoDaVila directed and tested the project with AI assistance from ChatGPT, OpenAI Codex and Anthropic's Claude (Claude Code). The statements above separate what was actually tested from what still needs broader coverage.

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
| Acquire/drawable recovery | Resize fixture and classifier/sync checks pass; owner confirms the installed fix works when resizing the game; background recovery remains unverified |
| Save/reload, every mode, multiple controllers, long sessions | Not fully verified |
| Intel Mac | Untested |
| Agentic model matches / deterministic evaluations | Future work; local control/capture tools are experimental |

Use [BUILDING-MACOS.md](BUILDING-MACOS.md) for installation and
[CONTROLS-MACOS.md](CONTROLS-MACOS.md) for keys. The single consolidated
[LOG/PROGRESS.md](../LOG/PROGRESS.md) contains the historical black-screen,
severe-menu/audio reports, measurements, successful fixes, failed comparisons
and operating lessons. Original game files and generated guest code stay local.
