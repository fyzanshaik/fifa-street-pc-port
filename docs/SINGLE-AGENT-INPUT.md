# Single-agent input (`agent-cpu`) — experimental report

Status: **experimental input foundation, verified offline only.** This slice adds
one explicitly named bridge mode for a tool/agent playing against the game's
built-in CPU. It does not run a model, does not launch the game, and does not
claim the game has seen a controller yet. Menus, team/controller selection and
the CPU-opponent side stay manual for now.

## What changed

A third opt-in mode, `agent-cpu`, exposes **exactly one** virtual Xbox 360 pad on
guest user 0 and drops every foreign device. This assignment policy gives guest
user 1 no input device. Team assignment and CPU-opponent setup remain separate
game configuration and have not been verified in-game.

| Mode | Virtual pads | Foreign devices |
|---|---|---|
| `ai-ai` (default) | user 0 **and** user 1 | dropped |
| `human-ai` | user 1 only | follow the SDK default (physical pads by ordinal; keyboard/synthetic devices on user 0) |
| `agent-cpu` | user 0 only | dropped |

- [control_protocol.h](../Installer/recomp-template/src/control_protocol.h)
  adds `Mode::kAgentCpu`; `ModeName` returns `"agent-cpu"`; `PlayerBridged`
  exposes only player 0 for it.
- `ModeFromName` adds a runtime-free parser. Unset,
  empty or unrecognised text still yields `ai-ai`, so normal play and the older
  modes are unchanged.
- [control_bridge.cpp](../Installer/recomp-template/src/control_bridge.cpp)
  makes the driver's `PlayerFor` respect `PlayerBridged`. A pad the mode does
  not expose is reported `X_ERROR_DEVICE_NOT_CONNECTED`, matching
  `EnumerateDevices`. The driver was syntax-checked, not exercised in a guest.
- `InstallControlBridge` uses `ModeFromName` instead of its old local parser.
- No wire-format change: the protocol version stays 1 and the 24-byte request /
  16-byte response layout is untouched.

The server already refuses a non-bridged slot before touching any state
([control_bridge_server.cpp](../Installer/recomp-template/src/control_bridge_server.cpp)),
so an `agent-cpu` command for player 1 returns
`player_not_bridged` and leaves both pads as they were.

## Using it

Requirements are the same as the existing bridge (a macOS dev build; see
[BUILDING-MACOS.md](BUILDING-MACOS.md#virtual-gamepad-bridge-macos)). The
installed app was **not** rebuilt for this work, so a build is required before
these can be exercised in-game:

Input isolation applies to menus as well as gameplay. In an `agent-cpu` launch,
normal keyboard/physical-controller navigation is excluded; manual setup means
owner-driven commands through virtual pad 0. There is no implemented in-session
handover from human controls to agent controls.

```sh
RESTREET_CONTROL_SOCKET=/tmp/restreet-control/ctl.sock RESTREET_CONTROL_MODE=agent-cpu \
  "build/macos/out/FIFA Street.app/Contents/MacOS/fifastreet" \
  --game_data_root="/path/to/GameData"
```

The socket is created mode 0600; a newly created parent directory is set to 0700,
while existing directories keep their permissions. With the socket variable
unset, the bridge is absent and the default input factory is unchanged.

`scripts/probe-virtual-input.sh` still accepts only `ai-ai`/`human-ai` (it is
outside this slice and belongs to the parent's reconciliation); launch manually
with the environment above for now.

## Tool-input mapping

Input is controller state, not OS keyboard events. The existing CLI
(`scripts/gamepad-macos.py`) already covers the raw contract; it was **not**
modified. One connection-scoped request sets the whole pad:

| Field | CLI flag | Range |
|---|---|---|
| Buttons | `--buttons A,X` / `--button Start` | XInput bitmask |
| Left / right trigger | `--lt`, `--rt` | 0.0–1.0 → 0–255 |
| Left / right stick | `--lx --ly --rx --ry` | -1.0–1.0 → -32767–32767 |
| Hold | `--hold` seconds (`0` = until Ctrl-C) | clamped to 10 min |

```sh
# One bounded action: A + X, left stick hard right, left trigger half, 0.5 s.
scripts/gamepad-macos.py --socket /tmp/restreet-control/ctl.sock \
  state --player 0 --buttons A,X --lx 1.0 --lt 0.5 --hold 0.5

# Release through a fresh connection when the server is available.
scripts/gamepad-macos.py --socket /tmp/restreet-control/ctl.sock release --player 0 --all
```

CLI commands: `state` replaces the pad, `press` ORs buttons in, and `release`
clears buttons (`--all` clears everything). The protocol also supports `ping`;
the CLI does not expose it as a subcommand.

### Client lifetime limits (important for an agent loop)

- The server services **one client at a time**:
  `ReceiverLoop` handles a client until it disconnects before accepting the next.
  A second concurrent client can queue at the socket but is not serviced until
  the first closes; it can exceed the CLI's 3 s timeout. A separate `release`
  CLI cannot preempt another CLI's held action. Stop that holding client to
  trigger disconnect release, or send release through the same owning
  connection. One persistent broker should own the socket and issue every command.
- State is **connection-scoped**: a command lives while its connection is open
  and, with `--hold`, no longer than the hold. Disconnect clears everything the
  connection set, so a crashed tool cannot leave a button stuck.
- A response acknowledges **adapter state**, not that gameplay consumed the
  action. Do not treat `ok` as proof that the guest acted on it.
- Non-bridged slots are refused without side effects; they are the correct
  failure signal for a two-slot design later.

The future environment contract (proposed, not implemented here) is a bounded
`observe()` / `act(action, observation_id)` pair over the same raw layer, with
the runner owning one socket, rejecting stale actions by `observation_id`,
applying one outstanding request with a deadline, and releasing on timeout or
disconnect. See [AGENT-ENVIRONMENT-DESIGN.md](AGENT-ENVIRONMENT-DESIGN.md) §5.

## Test evidence (offline, no game)

All run from the repository root on the owner's Mac:

```sh
bash scripts/test-macos-virtual-input.sh
python3 scripts/test-macos-gamepad-cli.py
/usr/bin/clang++ -std=gnu++23 -Wall -Wextra -fsyntax-only \
  -isystem ReXGlue/include -isystem ReXGlue/thirdparty/fmt/include \
  -isystem ReXGlue/thirdparty/spdlog/include -isystem ReXGlue/thirdparty/simde \
  Installer/recomp-template/src/control_bridge.cpp
git diff --check
```

Results:

- `test-macos-virtual-input.sh`: `All virtual-gamepad bridge behavioral tests
  passed` and `OK virtual-gamepad bridge behavioral tests passed`, then
  `OK gamepad CLI wire-format fixture passed`. New checks cover mode parsing/
  default preservation, single-pad selection policy for `agent-cpu`, foreign-input
  exclusion in assignment, a full buttons/triggers/sticks sample on slot 0,
  rejection of slot 1 without perturbing slot 0, explicit release, and release
  on disconnect. The `ai-ai` and `human-ai` cases from the existing test still
  pass unchanged.
- `test-macos-gamepad-cli.py`: `OK gamepad CLI wire-format fixture passed`. A
  test-double server asserts the exact request frames the CLI emits for
  `state` (buttons, both triggers, four stick axes), `press` and `release --all`,
  and that each bounded connection closes.
- `control_bridge.cpp` syntax check: exit 0 (the SDK-facing file is not compiled
  by the fixture, so it is checked directly against the pinned headers).
- `git diff --check`: clean.

Prerequisites and honesty notes: the C++ fixture needs the pinned
`ReXGlue/include` checkout present (it was, locally); no SDK library, GPU,
generated guest code or game data is used. No game binary was launched, no input
was injected into the game, and no app was built or installed. These checks
prove codec/state/routing/CLI behavior, not guest behavior.

## Still needs owner-supervised checks

- Rebuild and launch, then confirm the controller-selection screen shows **one**
  controllable pad for the agent's side while the CPU side is not agent-driven.
- Verify movement, pass and shoot from slot 0 actually reach the game, and that
  the CPU opponent controls its own team.
- Confirm menus, team selection and CPU opponent are chosen manually for this
  first slice; nothing here automates setup.
- Validate one persistent broker (single client) driving a live match, and that
  disconnecting mid-action releases the pad.

Determinism, observation capture and a full LLM match remain future work.
