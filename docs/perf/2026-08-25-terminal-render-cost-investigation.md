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

**Per-property observation tracking fixed it**, by roughly fivefold on stall
load. Five windows, same instrument, same window definition, matched uptimes:

| window | uptime | stalled | hop p99 | hop max | callouts >50ms |
|---|---|---|---|---|---|
| before | 50 min | 1.33% | 187.9 ms | 227.7 ms | 105 |
| before | 60 min | 3.71% | 257.9 ms | 325.2 ms | 118 |
| after | 6 min | 0.26% | 16.3 ms | 139.1 ms | 10 |
| after | 59 min | 0.26% | 5.3 ms | 58.4 ms | 50 |
| after | 76 min | 0.83% | 148.5 ms | 162.4 ms | 77 |

Stated honestly: stall load fell from 1.33-3.71% to 0.26-0.83%, and the worst
wait from 228-325 ms to 58-162 ms.

**The post-fix side is variable and one window does not characterise it** — p99
was 5.3 ms in one after-window and 148.5 ms in another. Quoting the best
after-window against the worst before-window yields a fourteenfold improvement
and is not defensible; the direction is solid and replicated across three
post-fix windows, the magnitude is roughly fivefold.

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

## Typing and scrolling, measured — 2026-08-26

The earlier sections measured terminal output travelling toward the screen during
ordinary operation, and stated that typing and scrolling had never been measured
under a validated window. Three windows on one build now close that gap: a quiet
baseline with no interaction, a window of continuous typing, and a window of
continuous scrolling.

| window | chunks/s | hop p50 | hop p99 | display passes | gap p90 | gap max | poll p50 |
|---|---|---|---|---|---|---|---|
| quiet | 21.8 | 0.08 ms | 59.4 ms | none | — | — | 255 ms |
| typing | 79.5 | 6.91 ms | 113.0 ms | 19.3/s | 101.4 ms | 846.5 ms | 525 ms |
| scrolling | 634.6 | 2.49 ms | 19.8 ms | 46.7/s | 31.4 ms | 265.8 ms | 1055 ms |

**Typing and scrolling fail differently, and the difference matters for which fix
helps which symptom.**

### Scrolling manufactures its own load

Scrolling produces **634 chunks per second** — twenty-nine times the quiet rate
and eight times the typing rate — while each chunk is trivially small (`feed`
median 0.03 ms). This is wheel-event amplification measured rather than inferred:
every wheel event emits `max(1, Int(abs(deltaY)))` mouse reports, each report
makes the hosted application repaint, and each repaint returns as output.

The render loop copes comparatively well under it: display passes run at 46.7 per
second with a p90 gap of 31 ms. The problem is not that the work is slow, it is
that most of the work should never have been generated.

### Typing starves the render loop

Typing produces a much lower chunk rate but a materially worse experience for the
renderer: display passes fall to **19.3 per second** against a 60 per second
budget, with a p90 gap of **101 ms**, a worst gap of **846 ms**, and 63 gaps over
100 ms in a 32-second window.

**Each pass is cheap — a median of 6.2 ms.** The render loop is starved rather
than slow: frames are inexpensive to draw and simply do not get to run. The
median wait for output to reach the renderer rises from 0.08 ms quiet to 6.9 ms
typing, so this is not a tail effect — nearly every chunk waits.

### A mechanism this refutes

The 150 ms post-keystroke window, during which `interactiveInputDisplayWindowNs`
disables the frame limiter so every chunk forces a synchronous redraw, was the
leading suspect for typing lag. If it were driving the symptom, 2,545 chunks
would have produced something approaching 2,545 display passes. They produced
617. Coalescing is working, and the frame limiter is not being defeated.

### The poll cycle degrades under both, as a symptom

`rpc.pollCycle` rises from 255 ms quiet to 525 ms typing to **1,055 ms**
scrolling. Read together with the enrichment result that already cleared it as a
cause, this is the poll being starved by main-thread congestion rather than
producing it. A poll cycle exceeding a second is nonetheless worth attention on
its own terms.

### Caveats

The scrolling window's signpost data spans 16 seconds of a 32-second capture; at
634 events per second the logging stream may have dropped records, so that chunk
rate is a floor and its distributions are approximate.

The instrumentation remains output-side only. There is no signpost on the
outgoing keystroke, so none of this measures keystroke-to-echo latency directly —
it measures whether output is delayed and whether frames are produced on
schedule. Measuring true echo latency needs a send-side interval.

## Residual

Long flushes have not vanished — 50 and 77 callouts over 50 ms in the two later
post-fix windows — they simply far less often have terminal output waiting behind
them.

The composition shift replicates across both post-fix windows independently: the
view-list rebuild fell from 31.5% of expensive-flush CPU before the change to
6.7% and 12.8% after, and body evaluation is now the largest slice in both, led
by `WorktreeRowView`, `TabBarItem`, and `PanePlaceholder`.

## Key-to-paint latency, and what it refutes — 2026-08-26

A deterministic benchmark — the real agent TUI driven by a scripted local
endpoint, so token rate is a parameter rather than a variable — measured the leg
that matters to a user: the time from a keystroke to the next display pass that
could show it. Harness and full method: `2026-08-26-claude-code-render-benchmark.md`.

| condition | keys | p50 | p90 | max | over 100 ms |
|---|---|---|---|---|---|
| bare shell, typing only | 84 | 53.8 ms | 156.8 ms | 303.8 ms | 28.6% |
| bare shell, typing only | 76 | 45.7 ms | 102.3 ms | 257.6 ms | 10.5% |
| typing while streaming | 84 | 40.8 ms | 119.3 ms | 270.0 ms | 13.1% |
| typing while streaming | 72 | 41.6 ms | 100.8 ms | 188.8 ms | 11.1% |

**The lag is a paint-scheduling floor, not a cost problem.** Median 40-55 ms with
a tail past 300 ms and one keystroke in ten or more taking over 100 ms to appear —
while the main thread is ~99% idle in every condition, parse work is 0.00-0.02
seconds per wall-second, and each display pass costs 10-15 ms. Nothing is
CPU-bound. TBD is not busy; it is not painting promptly.

### Three earlier readings this overturns

**Streaming does not make typing worse — it slightly improves it.** The streaming
pair ran at machine load 95-119 against the typing-only pair's 78-103 and still
came out faster. More output means more frequently scheduled draws, so a
keystroke waits less for the next one. The expectation that heavy agent output
would be the worst case for typing was wrong, and backwards.

**An agent cannot saturate TBD.** Claude Code emits ~30-40 screen updates per
second regardless of renderer, and raising its token rate tenfold *lowered* the
observed chunk rate. Renderer choice — fullscreen or classic — is immaterial to
throughput. The hypothesis that fullscreen full-viewport repaints constitute a
maximum-cost path does not survive: the producer is the limit, not the renderer.

**Gaps between display passes are not lag when input is bursty.** During a pause
between typing bursts there is nothing to draw, so a long gap is correct
behaviour. The earlier reading of 846 ms gaps as render-loop starvation over-read
that metric; keystroke-anchored latency is the sound measure and supersedes it.

### The one genuinely expensive path, and why it changes the fix

High-rate line-append while scrolling — reachable with a build log or `cat`, not
with an agent — costs 6.15 ms per chunk and 0.96 seconds of parse work per
wall-second. That is saturation, and it starves the view to roughly one display
pass per second.

**That cost sits in `feed` — parse and damage tracking — which is upstream of
`drawTerminalContents`.** So optimising the per-row `NSAttributedString` rebuild
would target the wrong stage for the one path where cost genuinely dominates.

### Caveats

**The input leg is excluded and the figures are a lower bound.** macOS refused
synthetic keystrokes without Accessibility permission, so keys were injected at
the tmux layer; TBD's own view keydown handling is not in these numbers. True
perceived latency is this plus that leg.

**Machine load was 63-119 throughout**, with the window server alone at 65-73%.
Within-pair comparisons are sound; comparison against baselines taken under
unknown load is not.

**A discarded metric, recorded so it is not re-derived.** "Time from chunk to next
display pass" gave a plausible 133-146 ms median but is inflated and partly
circular: a shell emits roughly 8.75 chunks per typed character while only about
one draw occurs, so most chunks are mid-burst fragments waiting on the next
character's draw.

### Where this points

At *when* TBD schedules a paint, rather than at parse or draw cost. A ~40 ms floor
on an otherwise idle main thread suggests a coalescing or timer policy rather than
contention — so the next question is what marks the terminal view as needing
display, and how that is throttled.
