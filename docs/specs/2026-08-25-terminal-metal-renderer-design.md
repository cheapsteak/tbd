# Enabling SwiftTerm's Metal renderer for embedded terminals

## Why

Embedded terminals in TBD scroll and type noticeably slower than a standalone
terminal emulator on the same machine. A control experiment isolates the cause to
TBD's rendering rather than to the machine, the daemon, tmux, or the hosted
agent's output volume:

- A standalone emulator running a **plain shell** — smooth.
- The same emulator running the **same agent TUI**, attached to the **same tmux
  session** on the **same loaded machine** — smooth.
- A TBD terminal running that TUI — laggy.

Only the frontend differs across those three, so the frontend is the variable
that matters.

Profiling TBD across sampling windows verified to contain actual scrolling puts
the cost in SwiftTerm's **CoreGraphics** draw path: `drawTerminalContents` at
20.7% and 11.6% of main-thread samples in the two validated windows against 4.0%
in a quiet baseline, of which `buildAttributedString` — which rebuilds an
`NSAttributedString` for every visible row on every redraw — is 12.8% and 7.5%.
The shaped-line cache alongside it is capped at 8-character segments, so ordinary
text re-shapes every frame.

SwiftTerm already ships a Metal renderer covering exactly that path
(`Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift`, `Shaders.metal`,
and a public `setUseMetal(_:)`), and TBD has never called it. Every measurement
above is therefore of a fallback path, taken while a GPU path sat unused in the
same binary.

This design enables that renderer behind a default-off flag and measures it.

### What later measurement says about this experiment's premise

Deterministic benchmarking after this spec was written found that the one
genuinely expensive path — high-rate line-append while scrolling — spends its
cost in `feed`, that is parse and damage tracking, which is **upstream of
`drawTerminalContents`**. A GPU renderer replaces the draw stage and would not
address it.

The same work found that an agent cannot saturate the renderer at all (~30-40
screen updates per second regardless of renderer, with a tenfold token-rate
increase *lowering* the chunk rate), and that perceived typing lag is a
paint-scheduling floor of 40-55 ms on a main thread that is ~99% idle, rather
than a cost problem.

This does not make the experiment worthless — the draw path is genuinely
inefficient, and the flag is cheap and reversible. It does mean the expected
prize is smaller than the spec assumed, and that a null result should be read as
confirming the cost lies elsewhere rather than as a failure of the GPU path. See
`docs/perf/2026-08-25-terminal-render-cost-investigation.md` and
`2026-08-26-claude-code-render-benchmark.md`.

### Two ways a null result is expected, stated before measuring

Recording these in advance so that a flat result is diagnosed rather than
argued about afterwards.

- **A flat scroll result most likely means the Metal row cache, not Metal.**
  Upstream reports the Metal renderer keys its row cache on absolute row number
  and screen-relative coordinates, both of which every scroll invalidates, so it
  rebuilds every visible row per frame while scrolled (reported fix: 10.35 ms to
  0.60 ms per frame). That patch is not in the pinned revision. A scroll result
  showing no improvement is evidence for applying it, not evidence against Metal.
- **A flat result under sustained streaming may mean the bottleneck moved.**
  Upstream also reports six streaming agent TUIs with Metal enabled still
  consuming 75-82% of a core, with cost relocating to CoreText glyph metrics
  rather than disappearing. That report is CJK-heavy and an ASCII agent TUI should
  hit the glyph atlas far better, but the possibility is real and the remedy is a
  different, smaller upstream fix.

Neither outcome retires the experiment; each names its own next step.

## What ships

A `UserDefaults` flag, `useMetalTerminalRenderer`, defaulting to **off**. When
set, `TerminalPanelView.makeNSView` calls `try tv.setUseMetal(true)` on the
terminal view it has just constructed.

`UserDefaults` rather than a `config` column because the behavior is entirely
app-side rendering with no daemon participation — the same placement as the
existing `enableTranscript` flag. Read through the three-state form:

```swift
defaults.object(forKey: useMetalTerminalRendererKey) as? Bool ?? useMetalTerminalRendererDefault
```

so "nobody has chosen" stays distinguishable from an explicit `false`, and
graduation is a one-line change to the default constant that reaches everyone who
never touched the toggle while preserving every deliberate opt-out.

`setUseMetal(_:)` throws — on hardware without Metal support, or if the pipeline
cannot be built. On a throw the view stays on CoreGraphics, the failure is logged
once at `.error`, and no retry is attempted. Degrading to current behavior is
always correct here; crashing or logging per frame is not.

## Hazards

**Pane snapshots read the view backing store.** `TBDTerminalView.captureScreenshot()`
captures through `bitmapImageRepForCachingDisplay` + `cacheDisplay`. A
Metal-backed view renders into a `CAMetalLayer`, which that path does not see, so
snapshots come back blank or stale. The capture feeds `AppState.snapshotProviders`,
which the sidebar context menu and pane placeholders consume.

`setUseMetal(_:)` is togglable in both directions at runtime, so the cheapest
candidate fix is to drop to CoreGraphics for the duration of a capture and
restore afterwards. That may flicker, and it is a candidate rather than a
decision: the implementation verifies it and may instead read back the Metal
drawable. Whatever the mechanism, a test asserts a non-blank snapshot with the
flag on — a snapshot regression is silent, because a blank image still renders as
an image.

**Terminal views are reparented across windows.** The keep-alive pager retains up
to eight terminal `NSView`s and moves them between windows, which is precisely
the `CAMetalLayer` device-and-drawable rebinding case SwiftTerm's own comments
call out. SwiftTerm carries handling for it; the soak must demonstrate that
handling holds under TBD's pager specifically, including GPU memory with eight
layers retained simultaneously.

**Eight simultaneous GPU contexts is a new resource class.** Today the retained
views cost only their backing stores. The soak watches for GPU memory growth
across worktree switches, not just for correctness.

## Acceptance

**Graduation requires closing the gap to a standalone emulator under realistic
load.** The bar is that a TBD terminal hosting an agent TUI feels comparable to a
standalone emulator hosting the same TUI, attached to the same tmux session, on
the same machine — the control described in "Why". The repository owner is the
judge of comparable.

**The comparison must be made on a loaded machine, not a quiet one.** A browser
open, agents running, memory under pressure: the conditions the app is actually
used in. This is not incidental strictness. Field observation established that
TBD's terminal is usable when the machine is quiet and degrades badly when it is
not, while a standalone emulator stays smooth through both — so a gate applied to
a quiet machine can pass while the defect that motivated this work is entirely
intact. Closing a browser and freeing roughly 3 GB was measured to halve system
load, stop paging, and produce a large subjective improvement, while leaving TBD's
own CPU unchanged. A gate that can be satisfied by that kind of ambient relief is
measuring the machine, not the change.

The failure mode this guards against is specific: the surplus work TBD performs
per keystroke and per frame is invisible when everything has headroom, and
decisive when it does not. The client with the least headroom degrades first.

Feel is the bar rather than a threshold on the profile because the profile can
improve while the terminal still feels slow: the upstream streaming report above
is exactly that case, with cost relocating rather than disappearing. The profile
is what keeps the judgment honest, not what settles it.

**The profile corroborates.** Re-run the validated-window protocol and show the
draw subtree collapsing from its recorded baseline of 20.7% and 11.6% of
main-thread samples. Every window on both sides must be scored for an actual
scroll or keystroke signature, with failing windows discarded rather than
averaged in; take several short windows rather than one long one, so a mistimed
window announces itself instead of becoming a finding. The quiet baseline must be
genuinely quiet — a session in which tooling is running commands streams output
into the terminal and drives redraws, inflating the very counters under
comparison. Compare subtree totals, never summed symbol occurrences: counts in a
`sample` call graph are inclusive of children.

**Tests cover both branches of the flag.** With the flag off, no `setUseMetal`
call is made and the CoreGraphics path is unchanged. With it on, Metal is
requested and a captured snapshot is non-blank. The three states of the default
are distinguishable: an unset key reads the shipped default, and an explicit
`false` survives a change to that constant.

## Rejected alternatives

**Replacing the terminal engine.** Migrating to a different engine is a live
option with three distinct shapes, real precedent, and documented hazards —
enough that it is recorded separately in
`docs/perf/2026-08-25-terminal-engine-options.md` rather than summarized here.

It is not rejected; it is sequenced behind this experiment. The reason is that
this experiment discriminates between the two readings that decide it. If
enabling the GPU renderer closes the gap, the difficulty was a rendering defect
in a fallback path, and an engine migration would be solving an already-solved
problem at a cost measured in months. If it does not, the competing reading —
that the difficulty is architectural, in how TBD drives the engine rather than in
how the engine draws — gains real support, and a migration spike becomes
justified by evidence rather than by analogy.

An afternoon's work settles which of those is true, so it goes first.

**Cherry-picking the row-cache fix before measuring.** Applying the upstream
Metal row-cache patch first would avoid a possibly misleading flat scroll result.
Rejected as sequencing: it costs the fork setup before any evidence justifies it
and mixes two changes into one measurement. The expected-null-result section
above captures the interpretation instead, at no cost.

**Shipping without a flag.** Rejected: replacing a rendering path is exactly the
category the repository requires to ship default-off and soak. The flag is also
what makes the A/B measurable at all, since it can be toggled live.
