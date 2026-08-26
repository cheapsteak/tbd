# Embedded terminal render cost: what was measured — 2026-08-25

This is an evidence record, not a design. It captures what was measured on
2026-08-25 against a live TBD app and daemon, which explanations were eliminated
and how, and where the remaining cost sits in code. Two specs act on it —
`docs/specs/2026-08-25-terminal-metal-renderer-design.md` and
`docs/specs/2026-08-25-appstate-observable-migration-design.md` — and this
document is the shared source of their numbers.

All measurements are from `/usr/bin/sample` against the running app and daemon on
one heavily loaded developer machine (12 cores, 48 GB, load average around 197,
swap near capacity, roughly 40 concurrent agent sessions). Machine state matters
for absolute latency and is controlled for below.

## Method: windows must be validated

**Sampling windows that depend on a human performing an action must be checked
for containing that action.** Four early windows in this investigation silently
captured no scrolling — the prompt to scroll was missed — and produced a
confident, wrong conclusion that survived into a committed spec before a
validated re-run reversed it.

The check used here scores each window for scroll-event frames (`scrollWheel`,
`gridPosition`) and for `TerminalView.draw` volume well above the quiet baseline,
and discards windows that fail. Take several short windows rather than one long
one, so a mistimed window announces itself instead of being averaged in. Of three
windows taken this way, one failed — and it failed self-consistently, showing both
no scroll frames and correspondingly lower draw cost.

Two further traps, both hit during this investigation:

- **A session running tooling is not a quiet baseline.** Commands streaming output
  into the terminal drive redraws and inflate the very counters under comparison.
  The "idle" baseline here contains that contamination and is a soft floor rather
  than a true floor.
- **`sample` call-graph counts are inclusive of children.** Summing a symbol
  together with its own callees double-counts the subtree. `TerminalView.draw`
  summed with `TerminalView.drawTerminalContents` inflated the draw path by
  roughly 2x and made it look dominant. Compare top-level subtree totals.

`sample` also could not sustain its nominal rate on this machine — achieved
capture ranged from 89.9% down to 12.5% of nominal across windows. Within-file
percentages are sound; cross-file "samples as milliseconds" arithmetic is not.

## What was eliminated, and how

A control experiment isolates the cause to TBD's frontend:

- Standalone emulator, plain shell — smooth.
- Standalone emulator, same agent TUI, **same tmux session**, same machine — smooth.
- TBD terminal, same TUI — laggy.

Only the frontend differs. That eliminates machine load, tmux, and the hosted
agent's output volume in one step, each of which had been a leading hypothesis at
some point during the investigation.

The daemon is separately eliminated: tmux control mode was disabled
(`control_mode_enabled = 0`), so terminal I/O runs app to local PTY with no
daemon participation — `OutgoingInputRoute.decide` returns `.localPTY` when
control mode is not attached. Daemon sampling during the same windows showed its
main thread fully idle and its worker activity peaking in the window that
captured *no* scrolling, i.e. uncorrelated.

## Measured cost, validated windows

Percentages are of all main-thread samples. Two validated scroll windows, against
the quiet baseline.

**Only the four top-level entries below are additive.** Everything indented under
one is already counted inside its parent, so summing a parent together with its
children double-counts the subtree — the same trap described above, in the same
numbers. The nesting here is the guard against it.

- **SwiftUI view-graph flush** (`GraphHost.flushTransactions`) — 25.1% and 18.1%,
  against 3.7% quiet. The largest single consumer during scroll.
  - of which `RepoSectionView.body` — 3.7% and 3.0%, against 0.7%.
  - of which `WorktreeRowView.body` — 1.2% and 1.7%, against 0.4%.
  - `TabBarItem` and `PanePlaceholder` re-evaluate alongside them; the remainder
    is other view bodies plus the attribute-graph machinery itself.
- **Terminal draw** (`TerminalView.draw`) — 20.7% and 11.6%, against 4.0% quiet.
  - of which `buildAttributedString` — 12.8% and 7.5%, against 2.2%.
- **Blink lifecycle scan** — 1.4% and 1.0% during scroll, but **6.1% of the quiet
  baseline's main thread**. Note this sits *outside* the draw subtree: it hangs
  off the display-queue dispatch, not off `draw`, so it is additive to the two
  entries above rather than part of either.
- **Terminal feed and parse** — around 2.7%.

Main thread 45% to 64% busy across the scroll windows against 18.7% quiet, with
the app near 47% of a core.

**Typing was never measured under a validated window.** The single typing sample
was unvalidated and captured at 12.5% of nominal. It showed the main thread 16.4%
busy — *below* the quiet baseline — which was initially read as evidence that
typing lag is not app-side. That inference is unsound: utilization does not
measure latency, and a mostly-idle main thread can still echo late if its work is
bursty and sits synchronously between keystroke and echo. The control experiment
above contradicts the original reading directly.

## Where the cost sits in code

Paths under `Sources/SwiftTerm/` refer to the pinned dependency revision
`16c52867763121b121f3b29a4d439052e7e76034`.

- **Per-row attributed-string rebuild.** `drawTerminalContents` calls
  `buildAttributedString(row:line:cols:)` fresh for every row intersecting the
  dirty rect on every draw (`Apple/AppleTerminalView.swift`). No row-level cache
  of the built segments exists.
- **Shaped-line cache misses ordinary text.** The `CTLine` cache is value-keyed
  but capped at `ctLineCacheMaxLength = 8`, so any segment longer than eight
  characters re-shapes every frame.
- **Full-viewport invalidation while scrolled back.** `updateDisplay` computes a
  sub-rect from the update range in the common case, but falls back to the entire
  view bounds when `displayBuffer.yDisp != displayBuffer.yBase` — that is,
  whenever the user is scrolled back, which is exactly the scrolling workload.
- **Unconditional full-grid blink scan.** `visibleBlinkRows()` scans every visible
  cell for a blink attribute; the `!blinkRows.isEmpty` term of its caller's guard
  is evaluated only *after* that scan completes, so the overwhelmingly common
  no-blink case pays the full O(rows x cols) cost. `updateTextBlinkLifecycle()` is
  called unconditionally from every `updateDisplay()`.
- **The frame limiter is disabled for 150 ms after each keystroke.**
  `interactiveInputDisplayWindowNs` is 150 ms; within that window `feedFinish`
  takes `displayImmediately()` instead of `queuePendingDisplay()`, bypassing the
  16.67 ms coalescing. Typing while an agent streams therefore forces a
  synchronous display update per output chunk — each one carrying the full-grid
  blink scan and, if scrolled back, a full-viewport redraw.
- **Wheel events are amplified in TBD's own code.**
  `Sources/TBDApp/Terminal/TerminalPanelView.swift` intercepts every wheel event in
  a local `NSEvent` monitor and emits `max(1, Int(abs(deltaY)))` SGR mouse reports,
  with no momentum-phase filter and no fractional-delta accumulator. A sub-line
  delta still sends a full report, and a trackpad flick's momentum tail delivers
  events at 60-120 Hz. Each report makes the hosted TUI repaint, and that output
  returns through the PTY as a redraw — so scrolling manufactures the output flood
  the draw path then pays for. The pinned SwiftTerm revision already contains a
  better handler (pixel-delta accumulation against real cell height, remainder
  banking, a `scrollSensitivity` knob) which never runs because the monitor
  consumes the event first.
- **A GPU renderer exists and is never enabled.**
  `Sources/SwiftTerm/Apple/Metal/` holds a full Metal renderer behind a public
  `setUseMetal(_:)`. TBD contains no reference to it, so every measurement above
  is of the CoreGraphics fallback.

## Upstream state, as of 2026-08-25

The dependency is actively maintained — roughly 395 commits over 52 weeks, 87% of
the last 30 pull requests merged with a median around 1.3 days. Several
outstanding pull requests profile a multi-pane agent-TUI workload closely
resembling TBD's, and are unmerged:

- **Content-keyed shaped-line cache** — reports draw samples falling from 778 to
  68, a 91% reduction, on an agent-TUI workload. Blocked on adding a per-line
  version stamp, which the terminal buffer lacks today.
- **Metal row cache surviving scroll** — the Metal renderer keys its row cache on
  absolute row number and screen-relative coordinates, both invalidated by every
  scroll; reports 10.35 ms to 0.60 ms per frame.
- **Scrolled-back over-invalidation** — dirty-range computation conflates the
  display and base line offsets.
- **Bounding Apple wheel reports** — a downstream fork's approach: one report per
  classic wheel notch, and a 100 reports/second token bucket with a six-event
  immediate burst for precise trackpad deltas.

A separately reported case shows six streaming agent TUIs with Metal **enabled**
still consuming 75-82% of a core, with cost relocating to CoreText glyph metrics.
That report is CJK-heavy, so an ASCII agent TUI should hit the glyph atlas
considerably better, but it is a live possibility rather than a settled one.

## Open questions

- **Typing has no validated measurement.** The mechanism above is read from code,
  not observed. What would settle it: the validated-window protocol applied to
  typing, analyzed for synchronous work between input and echo rather than for
  total utilization.
- **Which property drives the SwiftUI flush** is unidentified. Writer-frame counts
  were comparable between scrolling and quiet windows, so the rise in flush share
  has no isolated write behind it. Because the flush runs as a run-loop observer,
  its frequency scales with run-loop turns — meaning a fix to wheel amplification
  would reduce it without touching observation at all, and the two must not be
  measured together.
- **Whether the difficulty is architectural.** Another project's committed
  migration spec faults this dependency specifically for rendering issues in the
  bytes-fed-without-a-child-process mode that TBD operates in. If that reading is
  right, renderer tuning will not close the gap. Enabling the GPU renderer is the
  cheap measurement that discriminates.

## Perceived lag is intermittent, and is not explained by app CPU — 2026-08-26

The measurements above describe cost. They do not explain the symptom that
prompted the investigation, and a second day of measurement separated the two.

**The condition cycles.** Perceived lag alternates with periods that feel fine,
on a timescale of minutes. That alone rules out any explanation that is constant
— a view graph competing for the main thread is always competing. It also
explains why single-window measurements disagreed with each other: each was a
lottery ticket on which state it happened to sample.

**During a reported laggy period the app was not compute-bound.** Its main thread
was 81% idle and it used 26% of a core — *less* than several windows in which
nothing felt wrong. Terminal draw was 3.6% and view-graph flush 5.4%, both well
below their scroll-time figures.

**A 20-second sample took 73 seconds of wall clock to complete.** A system
profiling tool could not get its own work scheduled on time, which is a
machine-level signal rather than an application one.

**The machine is nonetheless fast where it matters for echo.** A bare pty round
trip — write to an open descriptor, child echoes, read back, with no process
spawns inside the loop — measures 0.1 ms at p50 and 7.7 ms at worst, even at
load average ~70 with swap near capacity. Keystroke echo is not limited by the
operating system, the pty layer, or scheduling beneath it.

**Process spawns, by contrast, are expensive here**: a single `tmux` client spawn
measures 114 ms at p50. Any probe that spawns a process per iteration measures
spawn cost and nothing else. An earlier round-trip probe reported 627 ms at p50
purely from this effect and was discarded.

### What this reframes

Average idle percentage says nothing about queueing delay. A main thread that is
81% idle can still run long bursts, and every chunk of terminal output is
dispatched onto that thread by `TerminalPanelView.dataReceived` — with no check
for whether the terminal is even visible. The distribution of main-thread block
durations, not the mean, is what would explain the symptom, and no measurement
here captures it.

External probing is exhausted: accessibility queries against the app are refused
for want of assistive access, and no external tool can observe dispatch-queue
latency. Answering it requires signpost instrumentation inside the render path.

### Eliminated, with the evidence

- **Machine pty and scheduling beneath it** — 0.1 ms round trip under load.
- **Compilation** — a laggy period was captured with zero compiler processes.
  Note the instrument that established this was initially blind to test
  execution and was corrected; the corrected form counts test helpers too.
- **Sidebar body evaluation as the dominant cause** — collapsing every repo
  section, which removes the largest measured view-graph consumer, did not
  change the symptom.
- **A large population of invisible terminals feeding the main thread** — the
  keep-alive cap is eight, but only three terminals were attached, so the effect
  is real in code and small in practice at present.

### Still open

- **The distribution of main-thread block durations**, which is the mechanism
  that would connect an idle-on-average main thread to a laggy-feeling terminal.
- **Whether the compositor is implicated.** It was the top system process through
  most of the laggy period, with 84 hours of accumulated CPU over 18 days of
  uptime. A view hierarchy that presents more work per frame would degrade first
  under that pressure — which would explain why a simpler emulator on the same
  backend stays smooth — but nothing here demonstrates it.

## The stall's cause: SwiftUI's view-graph flush — 2026-08-26

Signpost instrumentation measured a wait that every earlier method was blind to,
and a subsequent investigation (issue #735) identified its cause and confirmed a
fix. What follows records both.

**Terminal output waited far longer than it should to reach the renderer.**
Intervals around the main-thread hop in `TerminalPanelView.dataReceived` measured
a median under two milliseconds and a maximum of 1,096 ms across three windows.
The median is why averages and CPU percentages never revealed it: what matters is
when work lands, not how much of it there is.

**Rendering was never the bottleneck.** Parse costs a tenth of a millisecond and
a display pass single-digit milliseconds. The per-row attributed-string rebuild,
the eight-character shaped-line cache, and the full-grid blink scan are real
inefficiencies, and none of them is what stalls terminal output.

**The cause is SwiftUI's own runloop observer, `Update.end`, flushing the view
graph.** It was the only class of main-thread work that ever ran longer than
about 35 ms without returning to the runloop: 105 and 118 runs over 50 ms across
two windows, p90 179-205 ms, maximum 366 ms, against a maximum of 89 ms for
everything else combined. The flush is bimodal — trivial or enormous, with a
median of 2-3 ms against that p90.

The mechanism is not a correlation and needs no statistical correction. During
stalls, 87-92% of main-thread CPU sat inside a runloop-observer callout while CPU
servicing the main dispatch queue fell from 25-28% to 0.2-5.1%. A block on the
main queue cannot run while the thread is inside a callout, so a long callout
*is* an undrained queue — one event described from two sides.

**Per-property observation tracking fixed it.** After the change, the worst wait
for terminal output fell from **325 ms to 58 ms** and p99 from **258 ms to
5.3 ms**, measured with the same instrument at matched process uptime.

### A prediction that was wrong, and why the correction matters

The expectation was that per-property tracking would cut attribute-graph
propagation hardest and leave the `ForEach` view-list rebuild largely intact,
since that rebuild runs whenever list data changes regardless of tracking
granularity. The opposite happened, in absolute CPU inside expensive flushes:
the view-list rebuild fell 31-fold (6,190 ms to 201 ms), against 7.4-fold for
attribute-graph propagation and 2.8-fold for body evaluation, and `Worktree`
copy-and-destroy left the top entry points entirely.

The rebuild was itself being *triggered* by object-wide invalidation: any write
invalidated the observing views, forcing the whole nested list to be
reconstructed, with the value copies happening inside that reconstruction.

### Suspects eliminated along the way

The poll cycle was named as the cause on one 30-second window and refuted on a
larger one: enrichment against chance was **1.02x** once the poll's 43.7% duty
cycle was accounted for. `displayPass` showed 3.99x enrichment on twelve
observations and was likewise noise. Process age was tested rather than assumed —
the post-fix side measured at 6 and 59 minutes of uptime agreed almost exactly.

### Method worth reusing

**Define windows by the symptom, never by a suspect.** A window here was a period
during which terminal bytes were demonstrably sitting undelivered on the main
queue. Nothing about any candidate entered that definition, which is what allowed
the analysis to rule the poll cycle out rather than assume it in.

**Put every instrument in one trace so they share a clock** — a sampling
profiler, the signposts, and the platform's own hang detector correlated exactly
rather than aligned after the fact.

**Attribute by which runloop callout the work hangs off, not by what it
contains.** Stack composition inside stall windows was near-identical to
composition outside them, so what code runs did not discriminate at all. The
trigger did.

Three further instrument traps, each of which produced a wrong intermediate
reading: trace exports may reference-compress backtrace frames, yielding a stack
that reads as legitimately truncated but is not; a 21-second pilot window
contradicted the 150-second windows outright, because short windows catch
mistimed captures rather than supporting conclusions; and counting matching
processes by line count over-reports wildly when command lines are multi-line.

### A cheaper instrument already exists

`HangWatchdog` writes stacks to `~/Library/Logs/TBD/hang-stacks/` above a
threshold tunable by `TBD_HANG_THRESHOLD_MS`, and had independently captured the
same path. It is cheaper to read than to record a trace. Note that directory held
110,512 files — a durable resource with no named reconciler.

## What this does NOT cover

**Every window in this work was taken during ordinary operation with agents
streaming and no user interaction.** The intervals measure terminal output
travelling *towards* the screen. They do not measure keystroke-to-echo, and they
do not measure scrolling.

**Typing has still never been measured under a validated window**, and neither
has scrolling. The good numbers above must not be read as covering either.

Two named mechanisms target exactly those cases and are untouched by the fix:
wheel-event amplification, where every wheel event emits
`max(1, Int(abs(deltaY)))` mouse reports with no momentum-phase filter and no
fractional accumulator; and the 150 ms window after each keystroke during which
`interactiveInputDisplayWindowNs` disables the frame limiter so every output
chunk forces a synchronous redraw. If typing or scrolling still feel bad, those
are the better suspects.

Any window intending to cover them must be checked for containing the action —
the trap that put a wrong conclusion into a committed spec earlier in this
investigation.

## Residual

Long flushes have not vanished — 50 callouts over 50 ms, up to 200 ms, in a
59-minute window — they simply far less often have terminal output waiting behind
them. Expensive flushes are now 54.5% body evaluation, led by `WorktreeRowView`,
`TabBarItem`, and `PanePlaceholder`, with 35.4% attribute-graph propagation and
only 6.7% view-list rebuild.
