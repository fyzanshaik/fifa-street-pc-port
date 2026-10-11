# Gameplay performance findings — 11 October 2026

Optimization is paused at the owner's request. Three owner-driven captures show
variable gameplay performance, including one severe sustained slowdown and one
complete match without a clearly reported recurrence. No performance fix or
current code defect was established. Preserve the validated runtime settings.

These captures contain performance logs and one stack sample. They do not
provide complete structured gameplay state, recovered score/clock/player data,
or a deterministic benchmark. The canonical engineering history remains
[LOG/PROGRESS.md](../LOG/PROGRESS.md).

## Captures and observed behavior

- `20261011T152259.435263Z`: detailed runtime/GPU probes enabled, external stack
  sampling disabled. The owner reported some deterioration and match completion.
  Post-start output cadence declined from roughly 20/s to 18/s, while process
  CPU rose from roughly 2.7 to 3.3 logical cores. The deterioration/completion
  report arrived after the five-minute capture ended, so exact onset and result
  boundaries are unknown. Exit 0 at the announced time limit.
- `20261011T154905.520993Z`: detailed probes and stack sampling disabled. The
  owner reported match start at launch second 71.792, deterioration at 119.179,
  and explicitly confirmed onset while actively playing in the foreground.
  Cadence fell from 20.29/s initially to 8.98/s in the measured 45–75-second
  post-start window, then stayed around 9–10/s. CPU remained around 2.6 cores
  during the sustained slow segment. Exit 0 after 239.922 seconds, following
  the owner's `done` request; that request did not mean the match ended.
- `20261011T162009.383667Z`: detailed probes disabled, one two-second external
  stack sample at a 10-ms interval. The owner played both halves, reported that
  the first half had not deteriorated much, and requested closure after the
  game was done. No clear slow-phase trigger was received; the second planned
  stack sample was not taken. Exit 0 after 559.355 seconds, following the owner's
  close request, with no forced-kill escalation.

The same installed app path and runtime settings were used, and logs show the
same six-channel 48-kHz earbuds endpoint. Teams, arena, manual actions, scenes
and cache state were not independently matched. Different outcomes therefore
show variable reproduction, not a controlled comparison of probe overhead.

## Complete-match measurements

The third run's report receipt times were 68.288 seconds for match start,
347.601 for halftime/new half, and 558.264 for game done/close. These are
approximate markers, not exact simulation or screen-transition boundaries.

The stack-sampling command ran from 88.432 to 91.243 seconds. Its tool interval
includes setup and symbolization, beyond the two-second requested sampling
period. Cadence visibly dipped during sampling and recovered afterward. For
the following summaries, exclude every cadence window intersecting
83.432–96.243 seconds, a conservative five-second margin on each side.

- Early first-half proxy, launch seconds 100–180: 19.495 new outputs/s over
  75.301 measured seconds; mean process CPU 284.444% (2.84 cores).
- Later first-half proxy, seconds 180–300: 17.166/s over 115.750 measured
  seconds; mean CPU 323.816% (3.24 cores).
- Post-halftime-report proxy, seconds 360–520: 18.426/s over 155.816 measured
  seconds; mean CPU 336.511% (3.37 cores).
- All post-start report windows, including unclassified pauses/transitions and
  the final phase: 18.329/s over 467.407 measured seconds. This mixed-phase
  aggregate is not pure gameplay FPS.

Short isolated dips remain. The third run did not exhibit the earlier sustained
9–10/s regime, and CPU was often higher than in that severely slow run. Rising
total CPU is consequently not a necessary explanation for the reported slowdown.
That does not rule out a bottleneck in one thread or useful-work-versus-polling
differences.

Resident memory is non-monotonic: peak `ps` RSS 743.828 MiB over the whole run,
719.297 MiB over the post-start interval, and 426.281 MiB in the final observation.
The sample separately reports physical footprint `2.3G`. These counters measure
different things; neither this RSS trace nor one footprint snapshot establishes
or rules out a leak.

## What the first stack sample establishes

Each relevant thread has 172 wall observations in this sample. Counts describe
where sampled threads were observed, including blocked threads; they are not
CPU utilization percentages, and nested branch counts must not be added.

- GPU Commands: 159 observations in `vkWaitForFences` through the resolve
  readback path and condition-variable waiting; eight in `WAIT_REG_MEM` sleep.
  This corroborates expensive graphics completion waiting during relatively
  stable gameplay, rather than proving a new slowdown-specific defect.
- Main XThread: 133 observations in `QueryGuestTickCount` across two disjoint
  sibling branches. The prominent branch reaches `ReadGuestClock` and
  `mach_absolute_time`, rather than the old clock-mutex contention path. Guest
  clock polling remains visible, but this single sample does not establish a
  clock regression or a cause of deterioration.
- RenderThread: predominantly recompiled guest rendering work. No game function
  semantics or standalone gameplay subsystem were recovered from this sample.
- Four job-manager threads: 165, 167, 169 and 128 observations respectively in
  single-object/condition waits. This short snapshot does not characterize
  their activity later in either half.

There is no slow-phase stack sample, so the intended smooth-versus-slow stack
comparison was not completed. The older October 10 sample predates the clock
fix and confirmed gameplay; it is not a current control.

## Findings retained and limits

Repeated redraw/continuous idle-overlay rendering is not supported by the first
instrumented trace: UI/toast continuous repaint decisions were false, and only
six outputs repeated among 6,409 cadence presents. The complete-match run also
records only six repeats among 11,184 presents, with no acquire timeouts.

The first instrumented trace measured 188.554 seconds of guest fence-wait wall
time versus 0.753 seconds of calling-thread CPU. All recorded long waits were
resolve waits. Full resolve mode preserves completion ordering before guest
memory reads; deleting these waits is not an established correct optimization.
They are a substantial baseline cost, not a proven explanation for deterioration.

Audio delivery in the first trace was near its expected rate, with one inserted
silence block across the run. This does not explain or disprove the owner's
audible degradation. Detailed audio measurements were disabled in the later
runs; placeholder CSV fields do not establish clean playback.

New-output cadence is not simulation FPS. Principal GPU timestamp spans do not
measure the whole frame, and stage wall durations overlap. The first trace
dropped 1,743 detailed frame points; aggregate counters and their limitations
remain in the evidence. Neither severe-slowdown cause nor a performance fix has
been demonstrated.

## Evidence and validation

Small sanitized artifacts:

- [Initial baseline](../LOG/evidence/20261011-gameplay-slowdown-baseline.json)
- [Probes comparison](../LOG/evidence/20261011-gameplay-probes-comparison.json)
- [Complete-match findings](../LOG/evidence/20261011-full-match-performance.json)

Raw logs, CSVs, stack samples and graph pages remain in ignored local
`build/macos/logs/performance-check/<session>/` directories. They are not
repository payloads. No original game assets or generated code are copied into
the findings.

The existing performance analyzer completed successfully on all three saved
captures. Runtime/frame analyzers completed on the first capture only; later
runs did not enable those probes. Parent-derived window summaries use fully
contained cadence windows, CPU/RSS observations and the stated sample exclusion.
A read-only OpenCode Plan audit on official `deepseek/deepseek-flash`
independently reviewed the completed run and sample; Codex checked and documented
the accepted observations. Document links, JSON parsing and `git diff --check`
are the appropriate checks for this documentation-only delivery.

No more profiling, tuning or rebuild is scheduled. Resume the performance track
only when useful to the owner; the agent-environment work can proceed with this
unresolved variability explicitly retained as an experimental limitation.
