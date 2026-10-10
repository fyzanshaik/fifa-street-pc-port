# macOS resize recovery — 10 October 2026

Machine: Apple M5, arm64, LG ULTRAWIDE external display, contents scale 1×.
Pinned ReXGlue: `c94f5ebdcb3c9d1a460ca48e04f9758448f8d518`.
Implementation: two fresh OpenCode Build tasks, official
`deepseek/deepseek-flash`, verified through T3 execution metadata; Codex reviewed
source, reran checks and wrote documentation. Agents did not launch the real
game or inject input; the owner performed the final game check.

The owner reported blank output after resize while audio continued. A separate
SDL/MoltenVK fixture using the production presenter reproduced a layer-size
failure with synthetic nonblank guest output. The original runtime left
`CAMetalLayer.drawableSize` at 1×1 after 1600×900 and 1825×1045 resizes. The
saved Mac recovery patch now restores the created swapchain's extent after
recreation and retirement of the old swapchain.

## Validation

| Command | Result |
|---|---|
| `cmake --build --preset mac-arm64-release --parallel 2 --target rexruntime` in consumer workspace (worker) | Exit 0; canonical runtime rebuilt |
| `scripts/package-macos-app.sh --out build/macos/out` (worker) | Exit 0; fresh bundle |
| `bash scripts/test-macos-presenter-resize.sh` with separate parent-final log paths | Exit 0; GREEN exit 0, RED exit 4 with exact defect sentinels |
| `bash scripts/test-macos-patch-sequence.sh` | 20 passed, zero failures |
| `bash scripts/test-macos-drawable-recovery.sh` | Classifier/sync GREEN and expected RED passed |
| `bash scripts/verify-macos-artifacts.sh build/macos/out` | Passed; canonical runtime/GPU bytes match |
| `bash scripts/verify-macos-app.sh "build/macos/out/FIFA Street.app"` | Passed |
| `scripts/install-macos.sh --force` (worker, game closed) | Exit 0 |
| `bash scripts/verify-macos-app.sh "$HOME/Applications/FIFA Street.app"` | Passed; canonical bytes, dependencies and guest module loading |
| `bash scripts/test-macos-keyboard-profile.sh "$HOME/Applications/FIFA Street.app/Contents/MacOS"` | Passed; 25 bindings, releases, movement+sprint+pass, exit chord |
| Owner's manual resize check of the updated installed game | Owner confirmed “works!”; no automated game interaction |

Parent's final resize invocation used
`PRESENTER_RESIZE_GREEN_LOG=build/macos/logs/presenter-resize/green-parent-final.txt`
and `PRESENTER_RESIZE_RED_LOG=build/macos/logs/presenter-resize/red-parent-final.txt`.
The script sets process-local synchronous MoltenVK submission to match normal
play. Sizes 1600×900, 1825×1045 and 1500×800 matched after each resize. GREEN
recorded 115 successful refreshes, 83 paint events and zero refused refreshes or
painter failures. Forced-1×1 RED recorded three mismatches, 114 successful
refreshes, 84 paint events, zero painter failures and the dedicated defect exit
status 4. Crashes, harness errors and watchdog timeouts are not accepted as RED.

## SHA-256

- Recovery patch: `7eba9502a1057a9aaeee44abc9902acf89bfb97496b20aab85a030f6e11925e9`.
- Canonical, packaged and installed runtime: `4d3f7cc54730b38fe982584e2b7250a8624958b3072b499d0b1a6a113610e280`.

## Limits

The fixture checks drawable dimensions and successful synthetic refreshes, not
final screen pixels. The owner confirmed actual game resize recovery on the
tested Mac; background transitions, drawable starvation and Intel Macs are unverified.
The probe reads pixel dimensions, but the wrapper's exact 1825×1045 sentinel
assumes the tested external display's 1× scale. Paint events are not frame-rate
measurements. Raw diagnostics remain in ignored local storage. Existing caches,
saves and normal rendering/audio/clock settings were preserved. Publication was
requested by the owner after confirming the manual result.
