# Building from source

The usual player workflow uses the release installer and a personal ISO. These instructions describe development and packaging. They do not include game data or generated guest code.

Building on macOS is a separate, experimental development workflow; see [BUILDING-MACOS.md](BUILDING-MACOS.md). The instructions below are the Windows x64 path.

## Developer prerequisites

For a development build, follow **Source build walkthrough** below. This builds
Direct3D 12 from source and does not need the release backend DLLs or their hashes.
Installer packaging is a separate release-maintainer workflow.

## Source build walkthrough

Use Windows x64 and a short repository path, for example `C:\src\fifa-street-pc`.
Install Git, .NET 8 SDK, Visual Studio C++ Build Tools with Windows SDK,
LLVM/Clang 18 or newer, CMake 3.25 or newer and Ninja. Open **Developer PowerShell
for VS** with the x64 toolchain, and run all commands from the repository root.
LLVM is expected at `C:\Program Files\LLVM`; CMake and Ninja must be on PATH.

If you have not cloned the project yet:

```powershell
git clone https://gitlab.com/samuelitodavila-group/fifa-street-pc.git
Set-Location fifa-street-pc
```

1. Prepare ReXGlue using the pinned revision and patch in **Prepare ReXGlue** below.
   Apply the patch once to a fresh checkout; do not apply it again on later builds.
2. Build the code generator and SDK with Direct3D 12 explicitly selected:

   ```powershell
   $env:PATH = "C:\Program Files\LLVM\bin;$env:PATH"
   cmake -S ReXGlue --preset win-amd64 -DREXGLUE_USE_D3D12=ON -DREXGLUE_USE_VULKAN=OFF
   cmake --build ReXGlue/out/build/win-amd64 --config Release --parallel 2
   ```

3. Place `extract-xiso.exe` in `Installer/tools/`. Extract your ISO into
   `dist/GameData` (replace the ISO path):

   ```powershell
   New-Item -ItemType Directory -Path dist -Force
   .\Installer\tools\extract-xiso.exe -x -d "$PWD\dist\GameData" "D:\Games\FIFA Street.iso"
   ```

   Stop if extraction fails. `dist/GameData` must contain `default.xex`,
   `fifadllzf.xex.dll`, and
   `dlc/dlc_FootballCompEng/dlc/FootballCompEng/FootballCompEngzf.xex.dll`.
   An existing extracted folder with these files can be used instead.

4. Generate and compile the game and its two guest modules:

   ```powershell
   $env:REXSDK_DIR = (Resolve-Path .\ReXGlue).Path
   .\Installer\BuildFifaStreet.ps1 -SourceBuild -GameData "$PWD\dist\GameData" -Output "$PWD\dist\Game" -Jobs 2
   ```

   The script also builds and installs its own Direct3D 12 runtime/GPU pair and
   runtime dependencies. No `Installer/sdk` bundle is needed. It prints the
   build workspace and full diagnostic log paths. Keep that workspace to resume
   with `-Workspace` after fixing a compilation error. `-Jobs 2` limits memory
   pressure; increase it only if sufficient RAM is available.

5. Build the launcher and copy the default game configuration:

   ```powershell
   dotnet publish Launcher/FifaStreetLauncher/FifaStreetLauncher.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o dist
   Copy-Item Installer/payload/Game/fifastreet.toml dist/Game/fifastreet.toml
   .\dist\FifaStreetLauncher.exe
   ```

   Select **Direct3D 12** and press **PLAY**. The output layout is `dist/Game`,
   `dist/GameData`, and the launcher in `dist`. This source workflow installs
   Direct3D 12 by default. To also build Vulkan, repeat step 4 with
   `-GraphicsApi Vulkan` and the same output directory. Use a new workspace for
   each graphics API; both backend folders remain available to the launcher.
   Vulkan adds the SDK's Vulkan dependencies and build requirements. Select the
   backend you built in the launcher. This workflow does not apply the graphical
   installer's menu-credit patch.

Troubleshooting:

- The first build can take tens of minutes. ReXGlue analyses the main game module
  before compilation, and CMake may repeat code generation when building its SDK
  tool for the first time. Keep the process running while it is making progress.

- `clang.exe not found`: install LLVM in the path above.
- `ReXGlue code generator not found`: complete step 2; the script checks both
  `ReXGlue/out/win-amd64/Release/rexglue.exe` and the single-config output path.
- Windows SDK/linker errors: use the x64 Visual Studio developer terminal.
- Missing original module: check the extracted directory structure, including DLC.
- Backend hash mismatch: use `-SourceBuild`; release-bundle validation deliberately
  retains the official hash checks.

Run the backend installation regression check with:
`powershell -NoProfile -File Installer/TestSourceBackend.ps1`.

Validation on 2026-10-04: the Windows x64 Direct3D 12 source workflow completed
code generation, SDK/game compilation and installation of the executable, both
guest modules and paired runtime/GPU dependencies. The launcher and source
installer package also compiled successfully. This records a development-machine
build, not a clean Windows installation or new gameplay validation. The Vulkan
installation helper is tested; a complete Vulkan source build has not been tested
in this run.

## Release packaging prerequisites

- Windows x64, Git and the .NET 8 SDK with Windows desktop support.
- Microsoft C++ Build Tools and Windows SDK, available through a developer terminal.
- LLVM/Clang, CMake and Ninja.
- The ReXGlue checkout and dependencies, including the project patch.
- A locally built or obtained `extract-xiso.exe` from [XboxDev/extract-xiso](https://github.com/XboxDev/extract-xiso), placed in `Installer/tools/`.
- Your own supported game ISO or extracted `GameData` for game builds.

## Prepare ReXGlue

From the repository root:

    git clone --recursive https://github.com/rexglue/rexglue-sdk.git ReXGlue
    git -C ReXGlue checkout c94f5ebdcb3c9d1a460ca48e04f9758448f8d518
    git -C ReXGlue submodule update --init --recursive
    git -C ReXGlue apply --check ../patches/rexglue-local-changes.patch
    git -C ReXGlue apply ../patches/rexglue-local-changes.patch

The recorded project patch has been checked and applied successfully against this ReXGlue base. It contains project-specific code-generation, graphics, memory, runtime, scaling, diagnostics and window/input compatibility changes.

Do not assume a newer ReXGlue revision is compatible with the patch.

## Build the base SDK

Build and install the base SDK in a configured Windows C++ developer terminal:

    cmake -S ReXGlue --preset win-amd64
    cmake --build ReXGlue/out/build/win-amd64 --config Release --parallel 2
    cmake --install ReXGlue/out/build/win-amd64 --config Release

## Build the Direct3D 12 backend

The v0.3.0 package contains a separate validated Direct3D 12 runtime/GPU pair.

Use the project's configured Clang/Ninja ReXGlue build with Direct3D 12 enabled and Vulkan disabled. Keep `rexruntime.dll` and `rexgpu-xenos.dll` from the same build together.

The release packaging script expects the validated Direct3D 12 pair under the project's D3D12 backend output directory and verifies its SHA-256 hashes before packaging.

Validated release hashes:

- `rexruntime.dll`: `790B6B1B13765249160E53DCE6F28AF0F03B66D5D1AEDB1054949C50B13F04E8`
- `rexgpu-xenos.dll`: `461A88F1D27C605106453B0F3C92BD72BD4BC166DCDC0BBF01E825BCEFB8418D`

## Build the Vulkan backend

Build the separate Vulkan renderer/runtime using the project's Clang/Ninja configuration. Keep the runtime and GPU DLL from the same build together.

The release packaging script expects the validated Vulkan pair under the project's Vulkan backend output directory and verifies its SHA-256 hashes before packaging.

Validated release hashes:

- `rexruntime.dll`: `115722CC5905D07FC6A6212B47692FFE6405DD1BA9F87CDA97F8DA2C25E4767A`
- `rexgpu-xenos.dll`: `71FA61D82FF6134F1F407D682ACEBAC01F2B3B2DCEFCC34151A0C082B746BDD2`

The runtime and GPU DLL from each backend must remain paired.

## Build the launcher

    dotnet publish Launcher/FifaStreetLauncher/FifaStreetLauncher.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o dist/launcher

The launcher expects installed backend pairs under:

    Game/Backends/D3D12/
    Game/Backends/Vulkan/

It activates the selected pair beside `fifastreet.exe` before starting the game.

## Package the installer

The source images and icon are tracked. Compiled SDK tools, `extract-xiso.exe`, compiler binaries and `bundle.zip` remain local and excluded from Git.

    ./Installer/BuildSetup.ps1 -Output "$PWD/dist/FifaStreetSetup.exe"

The packaging script creates the public-tool bundle, publishes the launcher and publishes the self-contained installer.

The v0.3.0 packaging pipeline also:

- includes the validated Direct3D 12 and Vulkan backend pairs;
- verifies all four backend DLL hashes;
- keeps the backend pairs in separate package directories;
- installs Direct3D 12 as the initial active backend;
- rejects game archive/executable extensions from the public bundle.

Review exact-version third-party notices before distributing a public release.

The installer embeds `credit-patch.json.gz` and the managed LZX decoder. The recipe is the small difference needed for the two credit menus; it is not a copy of either menu archive. No original game font or modified BIG archive is included.

## Compile from extracted game data

Set `REXSDK_DIR` to the prepared ReXGlue SDK and run `Installer/BuildFifaStreet.ps1` with your private extracted `GameData` and an output directory.

The build pipeline produces:

    fifastreet.exe
    fifastreet_fifadllzf_xex.dll
    fifastreet_FootballCompEngzf_xex.dll

`FootballCompEngzf.xex.dll` is read from the game's DLC tree and recompiled as an independent guest module for World Tour.

The graphical installer additionally applies the menu credits before recompilation. Do not commit extracted files or generated guest source.

## Verify before publishing

Use [STATUS.md](STATUS.md) as the validation record.

For a release, verify:

- complete ISO-to-install workflow;
- start-screen/main-menu credits;
- all three recompiled outputs;
- Direct3D 12 launch;
- Vulkan launch;
- backend switching;
- output/internal-resolution independence;
- World Tour;
- public-package game-file exclusion;
- ReXGlue patch application against the recorded base.

Upload the installer as a Release asset; commit source, documentation, screenshots and notices. See [GitLab build and migration instructions](GITLAB.md).
