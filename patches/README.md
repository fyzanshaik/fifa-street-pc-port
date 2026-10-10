# ReXGlue patch stack

The Mac source build prepares SDK revision
`c94f5ebdcb3c9d1a460ca48e04f9758448f8d518` and applies these patches in order:

1. `rexglue-macos-base.patch` — exact copy of the validated pre-v1.1 ReStreet
   runtime changes. The newer Windows `rexglue-local-changes.patch` remains
   separate and is not part of this Mac stack.
2. `rexglue-macos-portability.patch` — Mac build/runtime fixes, source audio and
   frame diagnostics, cache reload and anchored clock.
3. `rexglue-macos-drawable-recovery.patch` — acquire classification and sync
   replacement/recovery logic.

Use `scripts/rexglue-patches.sh`, as the build does. Its real-Git regression
checks full/partial stacks, conflicts and unrelated edits. A later patch can
change an earlier patch's context, so an earlier reverse-check alone is not a
safe test for whether the stack is installed.

`rexglue-macos-input-diagnostics.patch` and
`rexglue-macos-presentation-candidate.patch` are preserved **optional experiments**.
They are not applied by the production Mac build. Do not stack an old candidate
over the current port casually; its source context and defaults may differ.

The SDK checkout is ignored. An edit there must be saved in a reproducible patch,
including any added private headers. Generate the portability patch against a
base with the local-changes patch already applied, excluding recovery changes
that belong in the next patch. Verify fresh application before shipping.

Read [LOG/PROGRESS.md](../LOG/PROGRESS.md) for why each fix exists, failed
experiments and measurement limits. SDK code keeps its original BSD/Xenia
notices; see [licenses/README.md](../licenses/README.md).
