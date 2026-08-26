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
