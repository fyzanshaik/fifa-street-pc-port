# Targeted gameplay recovery and REA feasibility

Investigated 11 October 2026. Research only; no installation, build, game launch
or gameplay-state extraction was performed. A T3-delegated Codex Plan audit
completed; the parent independently checked the target classifier, Ghidra
admission guard and pseudocode classification in a read-only checkout.

## Recommendation

Invest in targeted reverse engineering for the selected **text/JSON agent
against built-in AI** experiment. Whole-engine reconstruction into independent,
readable C++ is a separate project with uncertain scope. Do not make it a
prerequisite for the first playable experiment.

The port already compiles generated C++ into a native Mac executable. The missing
piece is semantic knowledge: which objects represent the match, ball and players;
which fields describe their state; and which functions own match transitions.
Generated code retains guest-level operations rather than the original EA types,
names and source structure. Existing [guest hooks](../Installer/recomp-template/src/guest_start_events.cpp)
demonstrate a seam for guest memory and function calls; they do not establish
gameplay layouts. See [environment design](AGENT-ENVIRONMENT-DESIGN.md#2-source-access-and-existing-seams).

Two meanings of “extract gameplay” need different evidence:

- Expose state and invoke existing gameplay through a small host interface:
  investigate this first while retaining the running engine.
- Recover gameplay as an independently runnable library: discover and reproduce
  its dependency closure, potentially including physics, animation, collision,
  assets, jobs, timing, RNG and initialization. The current evidence does not
  establish a clean subsystem boundary.

## What REA provides

Inspected upstream commit `ed1519ddee02739f57136e356786f64c7f74fed0`.
REA exposes installed decompilers through CLI/MCP, including assembly, pseudocode,
strings, callers/callees and references. Agents must interpret that evidence and
write and validate recovered implementations. Its
[native guide](https://rea.tools/guides/native/) illustrates a small function
recovery with original-behavior checks, not whole-engine reconstruction.

The Ghidra bridge explicitly describes output as
`decompiler-generated-non-source`, with `compilable: false`. It warns that inferred
types and calling conventions are decompiler observations. This is evidence for
investigation, not recovered original source or a build-ready replacement.
[Bridge implementation](https://github.com/morluto/rea/blob/ed1519ddee02739f57136e356786f64c7f74fed0/bridge/ghidra/ReaGhidraBridge.java#L1865-L1886).

## Compatibility gate

The standard native-target path in the inspected REA source does not admit the
original game's PowerPC/XEX targets. The architecture list contains x86, x86-64,
ARM, ARM64 and MIPS; its executable formats omit XEX. The Ghidra adapter separately
rejects architectures outside its allowlist.
[Target types](https://github.com/morluto/rea/blob/ed1519ddee02739f57136e356786f64c7f74fed0/src/domain/binaryTargetTypes.ts#L1-L8),
[formats](https://github.com/morluto/rea/blob/ed1519ddee02739f57136e356786f64c7f74fed0/src/domain/binaryTargetTypes.ts#L66-L89),
[adapter guard](https://github.com/morluto/rea/blob/ed1519ddee02739f57136e356786f64c7f74fed0/src/ghidra/GhidraProvider.ts#L176-L183).

Ghidra language overrides do not remove those admission checks. An original-guest
route requires a verified Xbox-compatible import/address mapping and a compatible
agent interface; REA integration or an alternative interface remains an open
choice. A bundled backend's capabilities alone do not establish wrapper support.
[Import configuration](https://github.com/morluto/rea/blob/ed1519ddee02739f57136e356786f64c7f74fed0/docs/installation.md#L747-L766).

REA documents Mac ARM64 native fixtures. That makes analysis of the existing
Mach-O artifact plausible, but does not prove Xbox compatibility or local setup.
For gameplay discovery, generated C++ plus original guest addresses should be
the starting point: decompiling their compiled ARM64 output adds another
translation layer. Use it when it supplies evidence unavailable from that input.
[Backend verification](https://github.com/morluto/rea/blob/ed1519ddee02739f57136e356786f64c7f74fed0/docs/ghidra-provider.md#L79-L93).

## Bounded first investigation

1. Calibrate original-address mapping against an already understood guest hook.
   Trace score, clock and match phase first, then ball state and active-player
   identity. Record candidate offsets, units, byte order, readers/writers and
   object lifetime assumptions. Offline findings remain hypotheses.
2. Compare a small set of functions using a compatible decompiler interface only
   if it is available. Measure whether it adds useful cross-references or control
   flow over generated-code inspection. Stop at an unsupported import; loader
   development needs its own scope.
3. In a later owner-supervised session, validate candidates across goals,
   pause/resume, passes, player switches, match end and rematch. Establish a
   coherent observation boundary and reject stale pointers/samples.
4. Build a small typed observation facade around validated state. Discover match
   configuration and genuine start/rematch lifecycle separately; reading score
   does not prove reset, tick stepping or RNG control.

The deliverable should be a validated state map and JSON observation for the
first experiment, followed by lifecycle evidence. No standalone engine,
deterministic built-in AI, savestate reset or scalable RL training is established.
Preserve the current playable configuration; guest code/data and raw evidence
remain private. The [environment acceptance gates](AGENT-ENVIRONMENT-DESIGN.md#10-first-implementation-milestone-and-acceptance-gates)
still govern implementation.
