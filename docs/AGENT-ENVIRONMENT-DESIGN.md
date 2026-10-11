# FIFA Street agent environment — experiment proposal

Research and design: 11 October 2026. **Proposed work, not implemented support.**

The first playable experiment selected by the owner is a **text/JSON LLM agent
against FIFA Street's built-in AI**, with video for human review. Later tracks
can compare vision models, two agents, and humans. This session inspected code
and primary documentation; it did not launch the game, inject input, rebuild,
or measure an agent match.

## 1. What we are evaluating

The initial question is: can a pretrained LLM make useful football decisions
when given an explicit gameplay observation and bounded controller actions?
Keep model weights fixed. This is agent evaluation. Reinforcement-learning
training would additionally update a policy from rewards and require separate
training/evaluation scenarios and enough game rollouts. An RL-compatible
interface is useful for both, but does not establish practical training speed.

For the first experiment, the model controls a team's currently selected
player through an ordinary controller slot. Unselected teammates remain
game-controlled. The opposition is the game's built-in AI. This is not yet an
independent agent for every footballer. Controller/team selection and CPU
opponent behavior must be verified in the actual chosen match mode.

The immediate input slice is experimental
[`agent-cpu` single-controller mode](SINGLE-AGENT-INPUT.md): one virtual pad on
guest user 0, with foreign input excluded. Its codec/routing behavior is tested
offline; controller-selection display and gameplay consumption remain unverified.
Second-controller discovery and multiplayer isolation are deferred. Menus and
CPU-opponent setup can remain manual for the first supervised experiment.

The opponent is a useful baseline, but its determinism is **unproven**. Fixed
rules or programmed behavior can still depend on randomness, elapsed time,
physics and scheduling. Do not claim that identical settings yield identical
trajectories, or that we have recovered the original AI algorithm.

## 2. Source access and existing seams

This project recompiles the owner's supported Xbox binaries into generated C++
and native arm64 code. It does not contain EA's original high-level source.
The committed host, generator templates, build scripts and saved runtime
patches are editable. Generated guest code is local, ignored and regenerated;
persistent guest changes need supported-revision hooks/overrides rather than
edits to generated files. [Architecture](../README.md#how-it-works),
[supported inputs](BUILDING-MACOS.md#supported-input-revision).

The [REA feasibility follow-up](REA-FEASIBILITY.md) recommends targeted gameplay
recovery and records a PowerPC/XEX compatibility blocker in the inspected REA
native-target path. Full reconstruction into independent C++ is not a prerequisite
for this environment.

| Capability | Evidence / practical limit |
|---|---|
| Controller input | Opt-in virtual XInput devices on guest slots 0/1, through a local socket; buttons, two sticks and triggers already exist. This is controller-equivalent input, not OS keyboard injection. |
| Controller lifetime | Holds are connection-scoped, use host milliseconds, expire by TTL and clear on disconnect. A socket acknowledgement reports adapter state, not proof that gameplay consumed the action. |
| Controller clients | `ReceiverLoop` accepts a client and services it until disconnect before accepting another. One persistent broker should own the socket and address all required slots. |
| Images | In-process presenter capture supports continuous latest-frame output, clamped to 250–10000 ms intervals. This is an experimental observation seam, not a validated full match stream. |
| Capture consistency | Image and metadata each use atomic replacement, separately. They are not a single transaction. Failure can leave the previous image present; checksum change is not a simulation-tick counter. |
| Guest hooks | Existing startup hooks read/write guest memory and call recompiled routines. This demonstrates a mechanism, not knowledge of gameplay objects or safe match-launch entry points. |
| Gameplay state | No validated score/clock/player/ball observation interface was found in the inspected host/control/capture seams. Locations, layouts and update boundaries remain a discovery task. |
| Reset and stepping | No supported environment-level reset, match-launch or fixed-tick step interface was established by this inspection. |

Sources: [bridge guide](BUILDING-MACOS.md#virtual-gamepad-bridge-macos),
[protocol](../Installer/recomp-template/src/control_protocol.h),
[server](../Installer/recomp-template/src/control_bridge_server.cpp),
[capture implementation](../Installer/recomp-template/src/guest_frame_capture.cpp),
[startup hook](../Installer/recomp-template/src/guest_start_events.cpp),
[hook configuration](../Installer/recomp-template/config/default_overrides.toml).

### Why savestates are not the first reset strategy

The pinned SDK contains kernel, graphics and audio save/restore routines, but
running guest-thread serialization explicitly returns false. The corresponding
thread restoration path also reports that execution restoration is not
implemented. Kernel saving can omit threads whose serialization failed, so
a success result there does not prove a usable checkpoint. Graphics/audio
subsystem pause methods are not a coherent whole-game simulation pause.

These findings were checked in the local pinned SDK and the primary
[pinned thread source](https://github.com/rexglue/rexglue-sdk/blob/c94f5ebdcb3c9d1a460ca48e04f9758448f8d518/src/system/xthread.cpp).
Local locators: `src/system/xthread.cpp:1296` and `:1420`,
`src/system/kernel_state.cpp:1327`, `src/graphics/command_processor.cpp:266`,
`src/graphics/graphics_system.cpp:457`, `src/audio/audio_system.cpp:370`.
Do not build an episode-reset plan around functioning full-game savestates.

## 3. Keep the environment independent of the model

Separate four responsibilities:

1. **Native game adapter:** validated state snapshots, controller input and,
   eventually, match lifecycle hooks. Preserve normal-play defaults.
2. **Environment service:** versioned observations/actions, freshness,
   controller ownership, episode configuration and lifecycle. No model prompts.
3. **Policy adapter:** observation plus bounded history to one action. A
   scripted policy and an LLM must use the same observation/action contract.
4. **Experiment runner:** scenario assignment, budgets, outcomes, failure
   accounting, recordings and repeated comparisons.

A human spectator view should show the game, the latest supplied JSON, the
chosen action, its timing and the running score. It reads the environment
stream; it does not need to know the model provider. Recordings and inspection
are useful even when the policy never receives images.

Use a small local Python adapter first. Keep C++ changes limited to genuinely
native seams. A later Python environment can follow
[Gymnasium's API](https://gymnasium.farama.org/api/env/):

```text
reset(options=match_configuration) -> observation, info
step(action) -> observation, reward, terminated, truncated, info
render() -> human view or RGB frame
close() -> release inputs and clean up owned resources
```

These signatures are a target. During manual setup, report a manual attach or
manual reset explicitly; do not implement a misleading automated `reset()`.
Match completion is termination; an external time/budget cutoff is truncation.
An infrastructure error is also recorded as an error, not silently a defeat.
Python adapter seeding does not seed the game. Until game-side RNG control is
proven, disclose unsupported game seeding instead of promising deterministic
`reset(seed=42)`.

For later two-agent matches,
[PettingZoo's Parallel API](https://pettingzoo.farama.org/api/parallel/) is a
useful interface. A mapping of both agents' actions does not itself make two
socket writes simultaneous; synchronized application needs game-side support.

## 4. JSON observations: extraction is the main research gate

JSON is a representation, not a method of discovering game state. Two distinct
tracks are possible:

- **Privileged state:** read validated guest state through the adapter. This
  is the recommended first track because it isolates decision-making from
  image recognition. Off-screen positions or internal values can exceed what
  a human sees; disclose that advantage.
- **Visible state:** derive JSON solely from rendered images using detection,
  tracking and HUD recognition. Preserve uncertainty, occlusion and unknown
  fields. This evaluates the perception system together with the policy.

Both vision-capable and text-only models can receive the same privileged JSON
for a decision comparison. Separately compare pixels against visible-state
JSON if investigating perception. Do not combine these observation tracks in
one ranking. Hidden opponent plans/internal AI state are not required for the
first track, and verifier-only data should remain outside model inputs.

### Discovery sequence

Start with match phase, score and clock. Then identify controlled-player
identity, ball position, player/team positions, possession and attack direction.
Velocities and additional attributes follow only when useful and validated.
For each candidate field, establish its owning object, layout, byte order,
lifetime, coordinate system and writer/update boundary. The SDK exposes guest
memory access, but does not assign football meaning to its contents.
[Runtime interface](https://github.com/rexglue/rexglue-sdk/blob/c94f5ebdcb3c9d1a460ca48e04f9758448f8d518/include/rex/runtime.h).

Validate candidates across owner-driven goals, passes, player switches, pause,
kickoff, side changes and match transitions. A changing number alone is not
evidence that it is the score or a position. Prefer a coherent snapshot
published at an identified game update boundary; arbitrary background reads
can combine different updates or dereference expired objects. Reject invalid
layouts/pointers and unsupported input revisions. Keep raw memory and
game-derived diagnostics private.

Suggested observation fields (illustrative, not recovered state):

```json
{
  "schema_version": "proposed-v1",
  "episode_id": "example",
  "observation_id": 42,
  "source": "validated_guest_state",
  "simulation_tick": null,
  "phase": "playing",
  "match_clock_seconds": 83.4,
  "score": {"agent_team": 0, "opponent_team": 0},
  "controlled_player_id": "agent_2",
  "ball": {"pitch_xy": [0.62, 0.40], "owner_id": "agent_2"},
  "players": [
    {"id": "agent_2", "team": "agent", "pitch_xy": [0.60, 0.40]},
    {"id": "opponent_1", "team": "opponent", "pitch_xy": [0.72, 0.45]}
  ],
  "valid": true,
  "age_ms": 15
}
```

The sample player list is abbreviated; the real schema must specify coverage
and represent unavailable fields as unknown. Define pitch axes/normalization,
attack direction, units, stable entity IDs, camera/controller mapping, sampling
time and per-field provenance when sources differ. Observation IDs count
snapshots, not simulation ticks. A small recent history can supply motion;
record its size so model comparisons use the same information budget.

The [Google Research Football observation design](https://github.com/google-research/football/blob/master/gfootball/doc/observation.md)
is a useful precedent for ball, teams, possession and active-player fields.
It is another engine, not an adapter for FIFA Street. Its repository is
[archived](https://github.com/google-research/football), so treat it as a design
reference rather than an assumed maintained dependency.

## 5. Actions and tool calls

Preserve a canonical raw-controller layer: normalized stick axes, triggers,
button mask and bounded duration. Existing input is already analogous to a
physical controller; an OS keyboard bridge is unnecessary for this port.
That does not make internal state access equivalent to a desktop-only agent.

For the educational first experiment, put a small, versioned set of controller
macros above it: neutral, move, sprint, pass, shoot, tackle and switch player.
A macro is a declared controller sequence, not a promise that a pass succeeds.
Calibrate direction conventions and button meanings for the fixed camera and
controller layout. Log both the requested macro and raw executed inputs.

Keep a raw-controller track available for finer control and disclose which
action layer each comparison uses. A tool such as “navigate to this location”
or “score a goal” adds a low-level policy; its intelligence and state access
would become part of the evaluated system. Do not conceal that assistance.

Proposed policy tool calls are `observe()` and `act(action, observation_id)`;
`act` can return the next observation to avoid an extra LLM round trip. The
runner owns setup/reset/close and scoring. It rejects stale/duplicate requests,
bounds durations and releases inputs on policy timeout/disconnection. Only one
broker owns the existing bridge connection. One command may set either slot;
the first experiment must verify that the unused controller is not assigned
to the CPU side. Two connected pads are not proof of a correctly configured
agent-versus-CPU match.

## 6. Timing: live and controlled-step are different experiments

**Live play first.** The game keeps running while the model thinks. A delayed
answer may target a ball position that no longer exists. Measure observation
age, inference latency, queue delay, bridge acceptance and effective input
duration separately. Set one outstanding request, a decision deadline,
bounded action holds and a defined neutral fallback. Discard expired answers;
never apply them to a later episode. Select actual cadence and budgets after
pilot measurement, rather than assuming a text LLM can act at game frame rate.

The current capture minimum is 250 ms. It can support development observation
and sampled human replay, but is neither a simulation clock nor full-rate video.
Require image/metadata consistency checks and fresh success status. Tune capture
only with evidence of its effect on gameplay and inference needs.

**Controlled-step later.** Both policies decide from a frozen simulation state,
then the game advances a defined number of updates under submitted actions.
This separates reasoning from reaction speed. It requires identifying a safe
simulation gate and coordinating guest time, threads, physics, AI and dependent
GPU/audio work. Clock scaling, stopping presentation or menu pause does not
establish those semantics. Existing wall-clock action TTLs would also need an
explicit contract while simulation is frozen. Exact stepping and bitwise
determinism are separate claims; prove each independently.

## 7. Direct match launch and reset

The desired public abstraction is a match configuration: mode/rules, teams,
venue, difficulty, controller-to-team assignments and observation/action track.
Episode setup should validate the actual resulting configuration before play.

Implement in increasing order of difficulty:

1. **Manual preparation/attachment:** the owner starts the selected match.
   Useful for early observation/action validation; not unattended evaluation.
2. **Verified menu/setup orchestration:** a state-aware controller sequence
   chooses options and confirms arrival at gameplay. Hide setup behind the
   runner and exclude setup time from gameplay scores while reporting it.
   This reaches gameplay through menus, rather than actually removing them.
3. **Direct match-configuration hook:** reverse-engineer the match creation
   boundary and its initialization prerequisites, then invoke the legitimate
   lifecycle with chosen configuration. This is a separate feasibility task.
4. **Reliable warm restart:** use a verified rematch/reset path when available;
   retain process restart/setup as a slower fallback.

Do not jump into an arbitrary gameplay function with missing initialized
resources. Skipping screens does not remove required asset loading, profile
setup or shader work. Save files do not imply whole-process savestates, and
copying guest RAM alone cannot restore native threads and external handles.
The current SDK's unsupported running-thread serialization makes full
checkpoint restoration a substantial separate project.

## 8. Where Pi, LangGraph and Harbor fit

These are framework recommendations, not required implementation dependencies.
“Pi dev” is interpreted as the Pi agent toolkit; revisit if another project
was intended.

| Tool | Appropriate role | What remains ours |
|---|---|---|
| Gymnasium | Single-agent environment interface | Game observation, input, lifecycle and timing semantics |
| PettingZoo Parallel | Later two-agent interface | Simultaneous game-side application and per-agent observations |
| Pi | Model API and optional tool-execution agent loop | Environment service and experiment rules |
| LangGraph | Optional stateful workflow, recovery and human intervention | Native game state; workflow checkpoints do not restore a match |
| Harbor | Task/trial packaging, artifacts and independent verification | A tested native Mac environment integration and repeatable game episodes |

Pi's current repository is [earendil-works/pi](https://github.com/earendil-works/pi),
with [pi-ai](https://github.com/earendil-works/pi/tree/main/packages/ai) and
[pi-agent-core](https://github.com/earendil-works/pi/tree/main/packages/agent).
The latter supplies stateful tool execution and event streaming. LangGraph
provides [agent orchestration and persistence](https://docs.langchain.com/oss/python/langgraph/overview).
Start with a direct model adapter; either framework can be introduced without
changing the environment contract.

Harbor [tasks](https://docs.harborframework.com/tasks/overview) combine
instructions, environment specification and verification. It supports
[custom sandboxes](https://docs.harborframework.com/sandboxes/custom-sandboxes)
implementing `BaseEnvironment` lifecycle, command execution and file transfer.
It is not limited in principle to Docker, but this does not demonstrate native
Mac game support. A custom Mac adapter or a containerized agent connected to a
native Mac game service is a possible integration design, not a tested solution.
Linux Docker cannot simply host this Cocoa/Metal application. Shared Mac
resources need serialized episode ownership until isolation is proven.

Do not make Harbor the game loop. Add it after local episodes are trustworthy,
with a verifier reading game-owned results rather than the agent's claim that
it won. Private game inputs remain local and outside published tasks.

## 9. Experiment protocol

Begin with one verified goal-scoring match mode, team pairing, venue and low
built-in difficulty. Record exact rules and controller/team assignment. The
first goal is a complete auditable match, not winning.

Compare neutral/random bounded actions, a simple scripted policy, and one LLM
through identical interfaces. Neutral/random policies are plumbing baselines;
the scripted policy tests whether supplied state/actions support useful play.
It does not replace the built-in opponent. Next vary difficulty and introduce
held-out teams/venues. Add other models, vision and AI/AI only after this loop
is reliable.

Freeze model/provider version, prompt, sampling settings, context/history,
tools, observation/action schemas, deadlines, match configuration and build.
Balance sides and alternate comparison order; record machine load, cache state,
capture overhead and setup method. Repeat trials and report sample counts and
uncertainty. An illustrative pilot of five matches per policy is a smoke check,
not enough evidence by itself for a strong ranking. Tune prompts on development
matches and keep held-out evaluation conditions separate.

Primary results: win/draw/loss and score difference. Shots, possession, trick
points or other mode-specific metrics are secondary only after validated
extraction. For future RL, goal difference and terminal outcome are sensible
starting rewards; shaped rewards can teach a different objective and need
separate justification.

Every attempted episode retains its setup result, observations, actions,
timing, final score, terminal/truncation reason, capture failures and actual
process outcome. Report controller/protocol failures, malformed actions,
deadline misses and game crashes separately from football losses. Keep video
and raw traces local; publish only permitted, small sanitized summaries with
provenance and limitations. An action recording is not a deterministic replay
unless repeated execution has been validated.

## 10. First implementation milestone and acceptance gates

**First implement a read-only structured observation probe.** Do not start with
Harbor, autonomous menu navigation or a large model framework.

| Gate | Evidence needed |
|---|---|
| A — trustworthy observation | Score/clock/phase plus controlled-player, ball and player/team state validated across owner-driven gameplay transitions; documented units/layouts/coverage; invalid and stale samples rejected; normal-play defaults preserved. |
| B — bounded useful action loop | Persistent broker and shared raw/macro executor; scripted policy responds to observations in a manually prepared CPU match; verified input consumption, release, deadline and failure behavior. |
| C — first LLM match | One frozen text model receives only the declared JSON/history, produces bounded actions, and completes a supervised match with independently captured outcome and replay/trace. No requirement to win. |
| D — reproducible episodes | Runner confirms configuration and performs repeatable setup/reset without undocumented manual intervention; failed setup is recorded; repeated baseline/LLM trials retain all attempts. |
| E — expanded experiments | Held-out/difficulty comparisons; optional Pi/LangGraph/Harbor integration; separately researched controlled stepping and later AI/AI. |

Fixture checks can validate codecs, schema handling, deadlines and lifecycle
without launching the game. They do not establish the meaning of guest state,
correct controller assignment, match reset or playable agent behavior. Those
need owner-supervised game evidence under the repository's operating rules.

Remaining research is specific: locate and validate gameplay fields; identify
a coherent snapshot boundary; calibrate controller/camera coordinates; verify
CPU-opponent configuration; discover legitimate match start/rematch lifecycle;
measure the live observation/action budget. Exact tick stepping, controlled RNG,
full savestates, headless execution and scalable RL training are not promised.
