# Mac keyboard controls

Native Mac builds use [the arrow-key profile](../config/macos/keyboard-arrows.toml).
The game shows Xbox button prompts. These keyboard keys emulate those buttons;
in-game custom controller layouts can change the gameplay actions.

For a first match: **arrows** move, **E** sprints, **Space** passes and **D** shoots.
Menus use arrows, Space to confirm and D or the Mac Delete key to go back.

| Xbox input | Mac key | Use |
|---|---|---|
| Left stick | Arrows | Movement / menus |
| A | Space | Confirm / ground pass |
| B | D or Backspace (Mac Delete) | Back / shoot |
| X | A | Lob pass / manual tackle |
| Y | S | Through pass / hold to rush goalkeeper |
| LT | Q | Street Ball Control / defensive jockey |
| RT | E | Sprint |
| LB | W | Flair modifier / switch defender |
| RB | R | Flick ball up / juggling |
| Right stick | I / J / K / L | Up / left / down / right skill directions |
| Left stick click | Z | Left-stick press |
| Right stick click | C | Right-stick press / stand on ball |
| D-pad | T / F / G / H | Up / left / down / right tactics |
| Back | Tab | Controller Back |
| Start | Enter | Start / pause |
| Guide | Unbound | No keyboard guide shortcut |

Gameplay actions follow [EA's FIFA Street Xbox 360 manual](https://eaassets-a.akamaihd.net/eahelp/manuals/fifa-street-manuals_Microsoft%20XBOX360.pdf).
Right-stick skill moves are relative to the player; keyboard stick emulation
uses discrete directions, so a physical controller is more suitable for analog
tricks. Manual gameplay with every skill combination and multiple physical
controllers has not been validated.

## Exit and overlays

Close the game window, or hold **Enter** and press **D** to open the host exit
prompt. **Space** confirms; **D** cancels. The host FPS overlay uses Home; many
MacBook keyboards send Home with Fn+Left. Overlay access is separate from guest
controller bindings, and Fn shortcuts have not been tested on every keyboard.

## Customize or restore the profile

The active bundle reads `FIFA Street.app/Contents/MacOS/fifastreet.toml`, not the
source profile. Edit its `keybind_*` settings while the game is closed. For a
persistent source-build change, edit `config/macos/keyboard-arrows.toml` and
rebuild. The build combines it with `config/macos/fifastreet-runtime.toml`.

To restore the shipped keys in the staged config and then refresh the bundle:

```sh
./scripts/apply-macos-keyboard-profile.sh
./scripts/package-macos-app.sh --gamedata "/absolute/path/to/GameData"
```

To update an installed bundle directly, target its active config explicitly:

```sh
./scripts/apply-macos-keyboard-profile.sh \
  --config "$HOME/Applications/FIFA Street.app/Contents/MacOS/fifastreet.toml"
```

The helper validates a conservative key-name string format, writes bindings in
root TOML scope and preserves other settings, comments and file permissions.
It changes bindings, not saved-game settings. Rebuilding regenerates the
staged config from the source templates, so manual edits there can be replaced.
Avoid bare Shift/Ctrl/Alt sprint bindings: this SDK uses exact modifier matching,
which can suppress an unmodified arrow binding while the modifier is held. The
shipped letter bindings allow movement, sprint and passing together.

## Verification

```sh
bash scripts/test-macos-keyboard-profile.sh build/macos/out
```

This uses the real MnK driver and checks 25 key bindings, button releases,
movement+sprint+pass together and the exit chord. It does not automate the game
window or prove every game move; manual matches provide that evidence.
