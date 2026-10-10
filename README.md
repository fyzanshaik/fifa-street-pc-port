<div align="center">

<img src="docs/images/project-icon.png" alt="ReStreet" width="64">

# ReStreet on macOS

**FIFA Street (2012), recompiled for Mac. Bring your own game.**

[Mac setup](docs/BUILDING-MACOS.md) · [Controls](docs/CONTROLS-MACOS.md) · [Progress and diagnostics](LOG/PROGRESS.md) · [Agent instructions](AGENTS.md)

</div>

This is [FyZan Shaik's macOS fork](https://github.com/fyzanshaik/fifa-street-pc-port/tree/main) of **[SamuelitoDaVila's ReStreet](https://github.com/samuelit0davila/fifa-street-pc-port)**. SamuelitoDaVila created the original Windows port, installer and launcher. This fork builds on that work to make the game usable, buildable and easy to experiment with on macOS.

Our longer-term goal is **agentic game benchmarks**: human versus AI and AI versus AI, with repeatable observations, actions and evaluation results. Getting a reliable Mac game comes first. Experimental capture and virtual-controller tools exist; an end-to-end AI benchmark, model integration and deterministic evaluation environment are future work.

## Current status

On the tested Apple Silicon MacBook, the game builds natively, boots, accepts keyboard input and has reached playable matches. The latest manual feedback reports good gameplay and improved music and menu response. We have paused further performance tuning to finish the play/install experience.

This is a **source-build Mac preview**, not a downloadable Mac binary release. Sustained 60 FPS, every game mode, save/reload, multiple controllers and live resizing are not fully validated. Late main-menu diagnostics measured around 25 new displayed outputs per second. Intel Macs are untested. See [validation status](docs/STATUS.md) and the [complete engineering log](LOG/PROGRESS.md) for evidence and limitations.

## Build and play on Mac

You need an Apple Silicon Mac, Xcode 16+ / AppleClang 16+ (or LLVM Clang 18+), CMake, Ninja, Python 3 and your own extracted FIFA Street (2012) Xbox 360 `GameData`. Only the [validated module revision](scripts/supported-macos-inputs.json) is supported. Game assets and original executables are not included.

```sh
git clone --branch main https://github.com/fyzanshaik/fifa-street-pc-port.git
cd fifa-street-pc-port
brew install cmake ninja

./scripts/build-macos.sh --gamedata "/absolute/path/to/GameData" --jobs 2
./scripts/play-macos.sh
```

The build pins and prepares ReXGlue, applies the Mac patches, recompiles your game and packages `build/macos/out/FIFA Street.app`. The first build takes time; later builds reuse the SDK and generated code. `--check-only` validates prerequisites and game inputs before compiling.

To install the built app for Finder access without copying game assets:

```sh
./scripts/install-macos.sh
```

This installs into `~/Applications`; an existing app is replaced only with
`--force`. The normal play command has **no time limit**. You can also open the produced `.app` in Finder. Keep the original `GameData` folder in place: the app links to it instead of copying it. Follow the [Mac setup guide](docs/BUILDING-MACOS.md) for installation, toolchain troubleshooting, rebuilding and logs.

## Basic keyboard controls

The shipped profile keeps **arrows for movement** and **Space to confirm/pass**. Xbox button prompts remain in the game.

| Key | Action / Xbox button |
|---|---|
| Arrow keys | Move player or menu selection / left stick |
| Space | Confirm, pass / A |
| D or Backspace | Back in menus, shoot / B |
| A | Lob pass, manual tackle / X |
| S | Through pass, hold to rush goalkeeper / Y |
| E | Sprint / RT |
| Q | Street Ball Control, defensive jockey / LT |
| W | Flair modifier, change defender / LB |
| R | Flick ball up / RB |
| I, J, K, L | Skill-stick directions / right stick |
| Enter | Start / pause |

For a first match, use **arrows + E** to run, **Space** to pass, and **D** to shoot. Hold Enter and press D to open the host exit prompt; Space confirms. Closing the game window also exits.

The [full key reference](docs/CONTROLS-MACOS.md) includes stick clicks, tactics and customization. Gameplay actions follow [EA's FIFA Street Xbox 360 manual](https://eaassets-a.akamaihd.net/eahelp/manuals/fifa-street-manuals_Microsoft%20XBOX360.pdf); custom in-game controller layouts can change them.

## What changed for Mac

- Native Apple Silicon build and `.app` packaging with Vulkan through bundled MoltenVK.
- Mac module loading, build portability and bounded generated registration tables.
- Guest startup event ordering and PowerPC memory barriers.
- Precise idle waits, dormant-overlay redraw suppression and stable host presentation settings.
- Correct shader-cache reload on Darwin and an accurate Mac guest clock without a shared mutex on every read.
- Arrow-key controls and opt-in frame, audio and CPU diagnostics with focused regression tests.

All SDK changes are saved as patches applied to the pinned source. `ReXGlue/` and generated guest code are local build products. Read [LOG/PROGRESS.md](LOG/PROGRESS.md) before changing performance settings: it records successful fixes, unsuccessful comparisons, measurement limits and mistakes to avoid.

## Windows and upstream

The original Windows installer, launcher and build path are preserved. Use [SamuelitoDaVila's releases](https://github.com/samuelit0davila/fifa-street-pc-port/releases) for Windows downloads and [docs/BUILDING.md](docs/BUILDING.md) to build the Windows version. Those `.exe` downloads are not Mac installers. The Windows v1.1 changes are retained. Mac builds use a separate saved base patch from the version we tested; the newer Windows SDK changes have not been validated on Mac.

## Credits and license

- **[SamuelitoDaVila](https://github.com/samuelit0davila/fifa-street-pc-port)** — original ReStreet port, Windows installer and launcher.
- **FyZan Shaik** — this Mac fork, direction, manual gameplay checks and future agent-benchmark goal; development assisted by OpenAI Codex and OpenCode with DeepSeek.
- **Emran_Ahm3d** — upstream investigations into patch line endings, module registration and game-data paths, FootballCompEng boundaries and resource-compiler compatibility.
- **[ReXGlue](https://github.com/rexglue/rexglue-sdk)** and **[Xenia](https://github.com/xenia-project/xenia)** — recompilation/runtime foundations; SDL, Vulkan, MoltenVK, LLVM, CMake, Ninja and other dependencies retain their own notices.

Original project-authored code uses the [MIT License](LICENSE), with its existing copyright notice retained. SDK patches and third-party components retain their own licenses; see [third-party notices](licenses/README.md). This repository does not include game assets, original Xbox executables, generated game code or a Mac game binary. FIFA Street content, artwork and trademarks belong to their respective owners. This is an unofficial community project, unaffiliated with EA, Microsoft or Xbox.
