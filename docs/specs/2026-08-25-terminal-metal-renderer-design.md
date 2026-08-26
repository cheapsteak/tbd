# Enabling SwiftTerm's Metal renderer for embedded terminals

TBD embeds SwiftTerm to draw its terminals. SwiftTerm ships two draw paths — a
CoreGraphics one and a Metal one behind a public `setUseMetal(_:)` — and TBD had
never called the second, so every terminal-render measurement TBD had ever taken
was of the CoreGraphics path while a GPU path sat unused in the same binary.

This design adds a default-off flag that selects between them, so the two can be
compared from Settings on a real workload. It ships as an experiment with a
recorded result, not as a performance fix.

## Why the draw path was suspected

Embedded terminals scrolled and typed noticeably slower than a standalone
terminal emulator on the same machine. A control experiment isolates that to
TBD's frontend rather than to the machine, the daemon, tmux, or the hosted
agent's output volume:

- A standalone emulator running a **plain shell** — smooth.
- The same emulator running the **same agent TUI**, attached to the **same tmux
  session** on the **same loaded machine** — smooth.
- A TBD terminal running that TUI — laggy.

Only the frontend differs across those three, so the frontend is the variable
that matters. The daemon is separately excluded: with tmux control mode off,
terminal I/O runs app to local PTY with no daemon participation, and daemon
sampling during the same windows showed its main thread idle and its worker
activity peaking in the window that captured no scrolling at all.

Sampling the app across windows scored for containing actual scrolling put real
cost in the CoreGraphics draw path. Percentages below are of main-thread samples,
in two validated scroll windows against a quiet baseline:

- **Terminal draw** — 20.7% and 11.6%, against 4.0% quiet.
- **The per-row attributed-string rebuild inside it** — 12.8% and 7.5%, against
  2.2%. That code rebuilds an attributed string for every row intersecting the
  dirty rect on every draw, with no row-level cache of the built segments.
- **The shaped-line cache alongside it** — value-keyed but capped at
  eight-character segments, so ordinary text re-shapes every frame.
- **Terminal feed and parse** — around 2.7%.

Those are real inefficiencies in code that runs on every frame, and a GPU
renderer covering exactly that stage existed and was unreachable. Enabling it
behind a flag is an afternoon's work and reversible, so it was worth measuring
rather than arguing about.

## What the flag can and cannot reach

Two facts bound the prize, and both were established by measurement rather than
by reading code. They belong here because they decide how a flat result should be
read.

**The genuinely expensive path is upstream of drawing.** Deterministic
benchmarking finds that the one costly workload — high-rate line-append while
scrolling — spends its cost in `feed`, that is in parse and damage tracking,
which sits *upstream* of the draw stage a GPU renderer replaces. A GPU renderer
substitutes how a frame is drawn; it does not touch what produced the frame.

**Drawing was already cheap in absolute terms.** A display pass costs single-digit
milliseconds (median around 6 ms) and a parse a tenth of a millisecond. Under
typing, display passes fall to 19.3 per second against a 60 per second budget,
with a p90 gap of 101 ms and a worst gap of 846 ms — the render loop is *starved*,
not slow. Making a cheap pass cheaper does not fix a pass that never gets to run.

Neither fact makes the experiment worthless: the draw path is genuinely
inefficient and the flag is cheap. Both mean the expected prize is small, and
that a null result should be read as confirming the cost lies elsewhere rather
than as a failure of the GPU path.

## How this sits on SwiftTerm 2.0

TBD pins a SwiftTerm 2.0 fork revision (`62d0be6d4c9641a4b27f311c55e1489b024271c3`).
That revision moves parsing onto the PTY IO thread, puts `Terminal` access behind
a public ticket lock, and replaces the fixed 16.67 ms paint floor with a
display-link frame scheduler. Three consequences for this flag:

- **The call survives the version unchanged.** `setUseMetal(_:)` is still the
  entry point at the pinned revision; nothing about the 2.0 concurrency model
  renames or retires it.
- **Upstream's `usesMetalLayerSurface` is a different thing.** It is a separate,
  additional surface-selection toggle, not a rename of `setUseMetal(_:)`, and
  this flag does not set it.
- **Both branches run the new scheduler and the lock.** Turning the flag off does
  not restore a pre-2.0 terminal; it selects the CoreGraphics backend underneath
  the same frame scheduling and the same locking. So this flag bounds
  **rendering-backend** risk only. It cannot be used to A/B frame scheduling, and
  a scheduling problem will look identical on both sides of it.

Where measurements in this document were taken against the pre-2.0 CoreGraphics
path, that is stated. They are evidence about how that path behaves and they
stand; they are not claims about the current pin.

## What ships

A `UserDefaults` flag, `useMetalTerminalRenderer`, defaulting to **off**, with a
toggle in Settings under Terminal. When set, the terminal view requests
`setUseMetal(true)` after construction.

`UserDefaults` rather than a `config` column because the behavior is entirely
app-side rendering with no daemon participation — the same placement as the
existing `enableTranscript` flag. It is read through the three-state form:

```swift
defaults.object(forKey: useMetalTerminalRendererKey) as? Bool ?? Self.useMetalTerminalRendererDefault
```

so "nobody has chosen" stays distinguishable from an explicit `false`. Graduation
is then a one-line change to the default constant: it reaches everyone who never
touched the toggle while preserving every deliberate opt-out.

`setUseMetal(_:)` throws — on hardware without Metal support, or when the pipeline
cannot be built. On a throw the view stays on CoreGraphics, the failure is logged
once per terminal view at `.error`, and no retry is attempted. Degrading to the
path that shipped for years is always correct here; crashing, or logging per
frame, is not.

**Activation is confirmed positively, not by absence of an error.** Because
`setUseMetal(_:)` degrades silently by design, a missing error line is not
evidence that Metal engaged. A `.notice` line is emitted per terminal view on
success. `.notice` rather than `.info` because `.info` lives in a memory ring
buffer that becomes unreadable within minutes of the launch that wrote it, and
the question "was the GPU path actually on?" has to be answerable the next
morning. One line per view is rare enough to afford that.

**The request is deferred until the view has a window.** Enabling Metal on a view
that is not yet attached leaves the renderer bound to no window, and attachment
then rebinds — building a second Metal view, renderer, glyph atlas and pipeline
set and discarding the first, synchronously on the main thread. Renderer
construction runs a runtime compile of the shader source with no library cache,
so opening a worktree with six tabs would pay twelve of those, half of them thrown
away milliseconds later. That is exactly the cost the flag exists to measure, so
paying it twice would contaminate the comparison.

## Hazards

**The shader resource must actually reach the app bundle.** SwiftTerm resolves
its shader source relative to the main bundle. The app is assembled into a bundle
at build time, and staging only TBD's own resource bundle leaves the shader
source out — `setUseMetal(true)` then throws for a missing shader and the terminal
silently stays on CoreGraphics. The failure mode is the worst possible one for an
experiment: an A/B that compares two identical CoreGraphics terminals and reports
"no difference". The bundling step stages every dependency resource bundle, and
the per-view `.notice` line above is what proves the path is live.

**Pane snapshots read the view backing store.** The screenshot path captures by
re-running the view's draw down the subview tree. A Metal-backed view renders into
a layer that path does not see, so snapshots come back blank — and a blank image
is a *silent* regression, because it still renders as an image and nothing
downstream reports it. Snapshots feed the sidebar context menu and pane
placeholders.

`setUseMetal(_:)` is togglable in both directions at runtime, so the capture drops
to CoreGraphics for its duration and restores Metal afterwards. The whole round
trip happens inside one main-thread turn, so the compositor never commits the
intermediate hierarchy and the swap is not visible; a synchronous frame is forced
on the way back so the rebuilt Metal view is not blank until the next runloop
turn. Re-enabling rebuilds the renderer and glyph atlas, which is acceptable only
because captures are user-gestured and occasional rather than per-frame.

**Terminal views are reparented across windows.** The keep-alive pager retains up
to eight terminal views and moves them between windows, which is precisely the
Metal-layer device-and-drawable rebinding case SwiftTerm's own comments call out.
The soak must demonstrate that handling holds under TBD's pager specifically.

**Eight simultaneous GPU contexts is a new resource class.** Today the retained
views cost only their backing stores. The soak watches for GPU memory growth
across worktree switches, not only for correctness.

## Field result

The flag has been dogfooded with Metal confirmed active — 15 per-view activations
observed with zero fallbacks to CoreGraphics. The by-feel A/B verdict is **no
noticeable improvement**.

Two verified mechanisms explain that, and both are findings in their own right.

**In a fullscreen TUI there is nothing for a row cache to hit.** The primary
workload is an agent TUI running in the alternate screen buffer, and the alt
buffer is constructed with no scrollback at all (`Terminal.swift`: "The alt buffer
should never have scrollback"). So what feels like scrolling is not scrolling: the
TUI rewrites the entire screen each step, every line's generation stamp bumps, and
a per-row render cache misses on every row no matter how it is keyed. Cache design
is irrelevant when the content genuinely is new. What remains of Metal's edge is
glyph rasterization — an atlas hit instead of a text-layout pass — which is real
but the smaller share.

This also reframes an upstream report that the Metal renderer keys its row cache
on absolute row number and screen-relative coordinates, both invalidated by every
scroll, and that fixing it takes a frame from 10.35 ms to 0.60 ms. That patch
would help scrollback scrolling in a shell. It cannot help the fullscreen-TUI
workload, because there the cache has nothing valid to retain.

**TBD amplifies wheel input upstream of any renderer.** TBD's own terminal panel
installs a local wheel-event monitor that emits `max(1, Int(abs(deltaY)))` mouse
reports per event, with no momentum-phase filter and no fractional-delta
accumulator, and it consumes the event — so it is the only thing forwarding wheel
input, and SwiftTerm's own better handler never runs. A sub-line delta still sends
a full report, and a trackpad flick's momentum tail arrives at 60-120 Hz. Each
report makes the hosted TUI repaint and that repaint returns through the PTY as
output. Measured: scrolling produces 634 chunks per second against 21.8 quiet and
79.5 while typing, each chunk trivially small. Scrolling manufactures the output
flood the terminal then pays for, and that amplification sits entirely upstream of
the renderer, so no amount of GPU work can touch it.

A third possibility is on record but not observed here: a separately reported case
shows six streaming agent TUIs with Metal enabled still consuming 75-82% of a core,
with cost relocating to text-layout glyph metrics rather than disappearing. That
report is CJK-heavy and an ASCII agent TUI should hit the glyph atlas far better.

**What the flag is worth, stated plainly.** Its value is that it makes the A/B
available from Settings on a real workload, and that it bounds rendering-backend
risk to one togglable switch. It is not a proven win. It ships default-off, and
**graduation is not recommended on current evidence** — the two mechanisms above
are where the work is, and neither is a rendering-backend problem.

## Acceptance

**Graduation requires closing the gap to a standalone emulator under realistic
load.** The bar is that a TBD terminal hosting an agent TUI feels comparable to a
standalone emulator hosting the same TUI, attached to the same tmux session, on
the same machine — the control described above. The repository owner judges
comparable. On the evidence recorded here that bar is not met, so the flag stays
off.

**The comparison must be made on a loaded machine, not a quiet one.** A browser
open, agents running, memory under pressure: the conditions the app is actually
used in. This is not incidental strictness. Field observation established that
TBD's terminal is usable when the machine is quiet and degrades badly when it is
not, while a standalone emulator stays smooth through both — so a gate applied to
a quiet machine can pass while the defect that motivated the work is entirely
intact. Closing a browser and freeing roughly 3 GB was measured to halve system
load, stop paging, and produce a large subjective improvement while leaving TBD's
own CPU unchanged. A gate that ambient relief can satisfy is measuring the
machine, not the change.

Feel is the bar rather than a threshold on the profile because the profile can
improve while the terminal still feels slow — the relocating-cost report above is
exactly that case. The profile keeps the judgment honest; it does not settle it.

**Profiling protocol, if the profile is used to corroborate.** Score every window
on both sides for an actual scroll or keystroke signature and discard the failures
rather than averaging them in; take several short windows rather than one long
one, so a mistimed window announces itself instead of becoming a finding. Ensure
the quiet baseline is genuinely quiet — a session in which tooling is running
commands streams output into the terminal and drives the very redraws under
comparison. Compare subtree totals, never summed symbol occurrences: call-graph
counts are inclusive of children, and summing a parent with its own callees
inflated the draw path by roughly twofold on a first pass and made it look
dominant.

**Tests cover both branches of the flag.** With the flag off, no `setUseMetal`
call is made and the CoreGraphics path is byte-for-byte what existed before. With
it on, Metal is requested and a captured snapshot is non-blank. The three states
of the default are distinguishable: an unset key reads the shipped default, and an
explicit `false` survives a change to that constant. Two decisions are extracted
into pure functions — the capture-time renderer swap and the wait-for-window
deferral — because a test process resolves shaders against a helper binary rather
than the build directory, so the Metal branch itself cannot be exercised
in-process; deleting either decision then goes red anyway.

## Rejected alternatives

**Replacing the terminal engine.** A migration to a different terminal engine is
not rejected, but it is sequenced behind this experiment, because the experiment
discriminates between the two readings that decide it. If enabling the GPU
renderer closed the gap, the difficulty was a rendering defect in a fallback path
and a migration would be solving a solved problem at a cost measured in months. It
did not close the gap, which supports the competing reading — that the difficulty
is in how TBD drives the engine rather than in how the engine draws — and that
reading is corroborated by both field mechanisms above, one of which is entirely
TBD's own code. A migration also carries a hard constraint: tmux cannot be removed
from TBD, because worktree reconciliation, cross-session agent messaging, the pane
readers, and pane identity for the peer registry all run through tmux commands. An
engine choice that assumes owning the process is unavailable regardless of its
rendering merits.

**Cherry-picking the upstream row-cache fix before measuring.** Applying it first
would have avoided a possibly misleading flat scroll result, at the cost of fork
setup before any evidence justified it and of mixing two changes into one
measurement. Recording the expected readings in advance costs nothing and does the
same job — and in the event the fullscreen-TUI finding shows that patch would not
have changed the verdict anyway.

**Moving painting off the main thread as part of this flag.** Out of scope by
construction: at the pinned revision the frame scheduler and the off-main model
apply to both branches, so this flag cannot deliver or withhold them. Scheduling
work belongs to the dependency pin, not here.

**Shipping without a flag.** Rejected: selecting a rendering backend is exactly
the category that must ship default-off and soak. The flag is also what makes the
A/B possible at all, since it can be toggled live from Settings.
