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

**Graduation requires closing the gap to a standalone emulator.** The bar is that
a TBD terminal hosting an agent TUI feels comparable to a standalone emulator
hosting the same TUI, attached to the same tmux session, on the same machine —
the control described in "Why". The repository owner is the judge of comparable.

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

**Replacing SwiftTerm with libghostty.** Ghostty's embedder API is the natural
candidate — its own macOS app is Swift over that C API, and it is MIT licensed —
but as of 2026-08-10 the project explicitly disclaims it for external use.
`include/ghostty.h` describes itself as an internal API "tailored to the needs of
the macOS app and not designed for external use", directing external embedders to
`libghostty-vt` instead; the commit that landed that wording removed an earlier
"(yet)". `libghostty-vt` is a VT state machine only — no renderer, no font
handling, no pty — which is the half TBD does not need, since parsing is under 3%
of the main thread and rendering is the measured cost.

Three further blockers stand independently of API status. Serious embedders fork
Ghostty and build it themselves, taking on a pinned Zig toolchain and a rebase
burden against an API with no tagged version. The mode TBD would require — a
surface fed bytes with no child process, matching the tmux bridge and replay
paths — exists but is not upstream, and no shipped consumer activates it.
And Ghostty deliberately disables BiDi, forcing
`kCTTypesetterOptionForcedEmbeddingLevel = 0`, where SwiftTerm's Metal path
supports it: a migration would be a functional regression for right-to-left text.
Estimated effort is three to five months against roughly 6,600 lines of TBD
terminal code.

The strongest argument on the other side, recorded because it is genuinely
unresolved: another project's committed migration spec faults SwiftTerm
specifically for "sizing and rendering issues when used without a process (the
`feed()` path vs `LocalProcessTerminalView`)" — which is exactly the mode TBD
operates in. If that is right, TBD's difficulty is architectural rather than a
caching defect, and no amount of renderer tuning resolves it. This design does
not settle that question; it makes the cheap measurement first.

Two triggers to revisit: an announced but unreleased pure-Swift Metal renderer
with `libghostty-vt` bindings, which would remove the Zig toolchain, the fork,
and the disclaimed-API objection at once; or this experiment plus the shaped-line
cache failing to close the gap to a standalone emulator, which would make the
architectural reading the better explanation.

**Cherry-picking the row-cache fix before measuring.** Applying the upstream
Metal row-cache patch first would avoid a possibly misleading flat scroll result.
Rejected as sequencing: it costs the fork setup before any evidence justifies it
and mixes two changes into one measurement. The expected-null-result section
above captures the interpretation instead, at no cost.

**Shipping without a flag.** Rejected: replacing a rendering path is exactly the
category the repository requires to ship default-off and soak. The flag is also
what makes the A/B measurable at all, since it can be toggled live.
