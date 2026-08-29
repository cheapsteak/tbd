# Commit-latency diagnostic: app draw → render-server commit

## The gap this closes

The terminal-lag investigation has settled everything upstream of the process
boundary with numbers. They were measured during that investigation against a
running fleet and are recorded here because they are the reason this instrument
exists; the raw sample output is not in this tree, so treat the figures as the
investigation's findings rather than as something a reader can re-derive from
the repository:

- **TBD's client was slower than other emulators on the identical tmux window.**
  PR #750 fixed it; TBD now measures at parity with an attached iTerm2 or
  Ghostty on the same window.
- **Residual lag is still worse in TBD than in iTerm2 at the same machine
  load.** That is the live problem, and it is ours.
- **The main thread is not the bottleneck.** `sample` during a
  user-confirmed lag episode (load 154) put the main thread 83% idle — 46,475
  of 55,761 samples in `mach_msg` — with terminal drawing ~4.6% of its busy
  time.
- **The SwiftTerm IO threads are idle** (`_pthread_cond_wait`, `poll`): #750's
  off-main parse works as designed.
- **tmux is not involved** (0.1–0.4% CPU, and an external client attached to
  the same window is smooth).

What `sample` could see ended at `CA::Transaction::commit` and
`UC::DriverCore::continueProcessing`, and then the trail left the process.
`WindowServer` was measured at 57–66% CPU during episodes. The standing
hypothesis is **compositing**: TBD presents a deep SwiftUI-hosted layer tree
with many panels where iTerm2 presents one flat layer, and under a loaded
compositor an expensive tree degrades where a cheap one does not.

Nothing has ever instrumented the leg between the app finishing a draw and the
frame being committed. This diagnostic does.

## What it measures, and what it does not

`CATransaction.setCompletionBlock` fires after the **render server** has
committed the transaction currently in flight. Stamping a timestamp when a
terminal view begins drawing and again when that block fires yields exactly the
missing leg.

**This is not time-to-glass.** Nothing after the render-server commit is
covered: not `WindowServer` compositing the layer tree, not the display's
scanout. Every figure the instrument produces is a **lower bound** on what a
user perceives. Measuring the second half needs a WindowServer-side instrument
we do not have and this design does not attempt.

## Design

`TerminalCommitLatencyProbe` (`Sources/TBDApp/Terminal/`) is a `@MainActor`
object owned by a lazily-resolved static.

**The two ends are stamped from two different seams, because the obvious one is
closed.** SwiftTerm's `TerminalView.draw(_:)` is `public`, not `open`, so a
subclass outside that module cannot override it and bracket the draw. What is
reachable:

- **`viewWillDraw()`** — the start. `open` on `NSView` and `open override` on
  `TerminalView`. AppKit sends it to each view it is about to draw, on the main
  thread, inside the display cycle's transaction, which is what makes the
  completion-block registration land on the right transaction.
- **`TerminalView.onFramePresented`** — the end of the app's drawing. TBD's
  SwiftTerm fork provides it as a diagnostics hook and calls it at the end of
  `draw` on the main thread on the Core Graphics path. TBD does not use the
  Metal renderer, so that path is the live one; TBD uses the hook nowhere else,
  so the probe takes sole ownership of its single slot while the diagnostic is
  on, and only the production `shared` accessor installs it.

AppKit sends `viewWillDraw` to a whole subtree before drawing any of it, so the
two hooks cannot be paired per view. `drawms` is therefore the **span** — first
terminal view about to draw → last terminal draw returned — not a sum of
per-view draw bodies. The span is the more useful of the two anyway: it includes
whatever AppKit does between the terminal draws. `commitms` is unaffected; it
was always measured from the first draw of the cycle.

**Per-transaction, not per-view.** Several terminal views can draw in one
display cycle and they all land in the same `CATransaction`. The probe stamps
`t0` at the *first* terminal draw of a transaction, folds later draws in the
same transaction into that cycle, and logs exactly one line when the completion
block fires. Registering a block per view would overwrite the previous one and
measure nonsense.

**Transaction identity comes from the transaction, not from a stopwatch.** This
is the load-bearing decision. `CATransaction.setValue(_:forKey:)` is a
per-transaction store *with a getter* — unlike `setCompletionBlock` — so the
probe stamps its cycle id there and reads it back on the next draw: the same
mark means the same transaction, no mark means a new one.

An elapsed-time boundary cannot do this job, and its failure is not a rounding
error. AppKit's cadence is ~16.67ms, so any window wide enough to tolerate a
slow commit is also wide enough to swallow the entire next cycle. Draws from
the following transaction would be counted into a frame that had already been
committed, that transaction would get no completion block of its own, and the
frame would vanish from the output — counted neither as a sample nor as a
drop. The bias would grow precisely with the latency the instrument exists to
characterize, and the `draws=1` versus `draws>1` split would partition on
"draws within the window" rather than "draws in one transaction". A diagnostic
that degrades in the presence of the phenomenon it measures is worse than none.

**`setCompletionBlock` has no getter and replaces any incumbent block.** There
is no way to read what is already set and chain to it. Two consequences are
accepted, and are the reason this cannot ship on: a block someone else set
earlier in the cycle is discarded by us, and a block someone else sets later
discards ours. The second case is why a cycle can go unreported.

**A lost cycle is reported, promptly and exactly.** When a draw arrives in a
different transaction while a cycle is still open, that cycle's completion
block demonstrably never fired, so it is emitted as `commitdrop draws=<n>` —
one line per lost cycle, carrying the draws that went with it. One line rather
than a running total, so a reader working over a `log show` window counts the
drops inside its window instead of inheriting a process-lifetime counter. Each
cycle also carries an id, so a completion block from an abandoned cycle
arriving late cannot close the current one. The reader reports the drop rate
and warns at 20% or above, because a high rate means the percentiles describe a
biased sample. The one loss that goes uncounted is a final open cycle at the
end of a session with no draw after it.

**A draw that paints nothing is distinguishable.** SwiftTerm's `draw` has early
returns before its frame-presented hook, so a view can be asked to draw and
paint nothing; `drawms` is then 0.000 for a reason that has nothing to do with
paint speed. The line carries `paints=<n>` alongside `draws=<n>` so the two
cases are separable, and the reader excludes unpainted cycles from the paint
percentiles rather than dragging them toward zero.

**Clock.** `ProcessInfo.processInfo.systemUptime`, injected as a closure.
`Duration` is behaviour, `Date` is data, and this is behaviour — so monotonic
uptime, never a wall-clock difference. No `Clock<Duration>` is involved because
nothing here sleeps, debounces, polls, or times out.

**Visibility.** TBD keeps terminals for unselected worktrees alive and fed
inside a visible window, so `window.occlusionState` alone admits views AppKit
correctly never draws — it reports the *window*. The probe additionally
requires a non-empty `visibleRect`, which is what excludes a view clipped
entirely out of its pager or scroll container. `vis=1` on a line means at least
one of that cycle's drawing views was genuinely on screen; the reader reports
off-screen cycles as their own bucket rather than folding them into the
headline percentiles.

## Output

One `.info` line per instrumented display cycle, subsystem `com.tbd.app`,
category `commitlatency`:

```
commit draws=<n> paints=<n> drawms=<f> commitms=<f> vis=<0|1>
```

- `draws` — terminal views that drew in this transaction
- `paints` — how many of those reached the end of `draw`
- `drawms` — first terminal view about to draw → last terminal draw returned
  (the app-side paint span)
- `commitms` — first draw's start → render server committed
- `vis` — 1 if at least one of those views was genuinely on screen

`.info` rather than `.debug` because of how the two are retained.
[`docs/diagnostics-strategy.md`](../diagnostics-strategy.md) assigns per-event
traces to `.debug`, which this is, and this deviates deliberately: `.debug`
lives in an in-memory ring buffer that `log show` does not return for past
events unless someone raised the subsystem's persistence with `sudo log config`
*before* the episode. The whole workflow here is "reproduce, then ask the system
for the recent past", which only `.info` and above satisfy without that
prior step. The cost is real and worth knowing when reading a capture: `.info`
is retained briefly rather than persisted, and at roughly a line per frame a
long session can lose its earlier minutes, biasing a capture toward its end.
Take short captures. The key=value shape matches the other diagnostics'
convention. `scripts/diag/commit-latency-report.py` reports p50/p90/p99/max for
`commitms`, split by `draws=1` versus `draws>1` and by on-screen versus not,
plus an optional split by machine load when a sidecar load log is supplied.
Load is not in the log line because reading it once per frame would be its own
overhead; the reader joins on the `log show` timestamp instead.

## Gating

Default OFF behind the UserDefaults key `enableCommitLatencyDiagnostic`
(`AppState.enableCommitLatencyDiagnosticKey`, default
`enableCommitLatencyDiagnosticDefault = false`). App-only behaviour, so a
UserDefaults key is the right seam — precedent `enableTranscript`.

**This departs from the diagnostics doctrine, and the departure is the point.**
[`docs/diagnostics-strategy.md`](../diagnostics-strategy.md) says a diagnostic
should need "no env var, no defaults key, no debug build … the activation
mechanism is the OS, not the app", and sibling instruments in this same
investigation ship with no flag at all. That rule is about *verbosity*: where
the only thing a flag would control is whether a line is emitted, os_log's
level filter already does the job better. This instrument is not only verbosity.
Turning it on **changes behaviour**: it stamps a value on, and claims the single
completion-block slot of, a `CATransaction` the whole app shares, discarding
whatever block was there. No subscriber-side level filter can express that, so
the activation mechanism has to be in the app. Per-frame `.info` logging being
too heavy to ship on is the lesser half of the argument.

`nil` is the whole gate: with the flag off the static resolves to no probe,
`viewWillDraw()`'s `guard let` returns straight after `super.viewWillDraw()`,
and the frame-presented hook is never installed — nothing timed, nothing
logged, no transaction marked, no completion block registered. Both branches are
covered by `TerminalCommitLatencyProbeTests`, driven through a per-test
`UserDefaults(suiteName:)` because `UserDefaults.standard` on this unbundled
executable is the developer's live `TBDApp.plist`.

There is deliberately no Settings toggle. This is an instrument turned on for a
measurement session and off again, not a preference:

```
defaults write TBDApp enableCommitLatencyDiagnostic -bool true    # then relaunch
defaults write TBDApp enableCommitLatencyDiagnostic -bool false
```

The gate is resolved once, on the first terminal draw, so flipping the key
takes effect at the next launch — which a measurement session begins with
anyway.

## The assumption that would make it lie

`Package.swift` carries a standing warning from the #750 SwiftTerm bump: a
frame loop that does not run on the main thread may never call
`viewWillDraw()`, and TBD's terminal diagnostics hook it. It does not bite
today — SwiftTerm takes its render-loop path only when the Metal layer surface
is enabled, TBD enables it nowhere in `Sources/`, and `frameTick` therefore
falls through to `setNeedsDisplay` and an ordinary AppKit display pass. It is
written down because the failure is silent and reads as good news: **an
instrument that logs nothing looks exactly like a machine with no lag.** If a
capture comes back empty, check that assumption before concluding anything
about latency.

## Lifetime

Temporary. It exists to answer one question: how much of the residual lag lives
between the app's draw and the render server's commit. Once that is answered —
either the leg is fat, and the compositing hypothesis becomes a fix, or it is
thin, and attention moves past the render server — the probe, its flag, its
tests, and its reader come out. It is deliberately cheap to delete: one new
file, one `viewWillDraw()` override, one key on `AppState`, one script.

## Rejected alternatives

- **`TerminalView.onFramePresented` alone.** It is process-wide with no view
  identity, so on its own it cannot report draws-per-cycle or visibility — the
  two dimensions the compositing hypothesis actually turns on. It is used here
  only for the end of the paint span, where identity does not matter.
- **A `Duration`-based clock seam.** The repo requires an injected
  `Clock<Duration>` for anything that sleeps, debounces, polls, or times out.
  This does none of those; it reads a monotonic instant twice. Adding a clock
  would be ceremony that measures nothing.
- **`CADisplayLink` frame callbacks.** They report when a frame was scheduled,
  not when the render server accepted it, which is the boundary in question.
- **Sampling load per frame into the log line.** `getloadavg` per frame is
  measurable overhead inside the very path being measured. A sidecar load log
  joined on timestamp costs the measurement nothing.
- **A Settings toggle.** A per-frame `.info` logger that also mutates a shared
  `CATransaction` should not be one click away from a user who is not running a
  measurement.
