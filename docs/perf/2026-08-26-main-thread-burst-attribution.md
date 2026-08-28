# What occupies TBD's main thread while terminal output waits — 2026-08-26

This is an evidence record, not a design. It answers the question left open by
[`2026-08-25-terminal-render-cost-investigation.md`](2026-08-25-terminal-render-cost-investigation.md):
*something* runs on the main thread in bursts long enough to stall terminal I/O
by hundreds of milliseconds, and nothing had named it.

It names it: **SwiftUI's own runloop observer, `Update.end`, flushing the view
graph.** That callout is the only class of main-thread work in TBD that ever
runs longer than about 35 ms without returning to the runloop, and terminal
output — dispatched to the main queue by `TerminalPanelView.dataReceived` —
cannot be delivered until it does.

Both windows below are from pid 89137, `/Applications/TBD.app`, built from
branch `tbd/diag-render-signposts` (commit `00c8ac35`). No restart occurred
during or between them; the pid was verified stable rather than inferred.

## Method: state what the instrument counts, and check it matches the claim

This is the first rule, not a footnote. **Every wrong answer across this
investigation came from an instrument measuring a superset or a subset of the
claim being made — not once from bad reasoning over correct data.** A grep
counted every observable rather than the one named. A compiler-process counter
was blind to test processes. A round-trip probe measured process spawns. A
profile summed a symbol with its own child and double-counted the subtree. A
`pgrep -f` matched the investigator's own command lines. A line count over
multi-line command text reported 457 processes where there were six. An XML
export returned ref-compressed stack frames that read exactly like truncated
ones.

So: before reporting any number, say what the instrument actually counts, and
check that it matches the claim. Treat *"the instrument cannot see what I am
claiming"* as the first suspicion, not the last.

The rest of this section applies that rule to each instrument used here.


Three instruments were recorded into **one** `xctrace` trace, so they share a
single timeline and correlation between them is exact rather than clock-matched:

- **`potential-hangs`** — Instruments' own main-thread unresponsiveness
  intervals (threshold 100 ms), derived from system responsiveness events. It
  knows nothing about TBD's code, so selecting windows with it presupposes no
  culprit. It is used here only as a cross-check; the primary window definition
  is the next one.
- **`time-profile`** — a 1 ms sampling profiler. Each row is one sample of one
  thread with a full symbolicated backtrace. **Every sample is counted once,
  into exactly one bucket.** A parent is therefore never summed with its own
  child — the double-counting that inflated the draw path roughly 2x in the
  earlier `sample`-based rounds is structurally impossible in this form.
- **`os-signpost-interval`** — the temporary `mainThreadHop` / `feed` /
  `displayPass` intervals from `00c8ac35`.

**Windows are defined by the symptom, not by a suspect.** A *stall window* is a
period during which at least one `mainThreadHop` interval was open — that is, a
chunk of terminal bytes was demonstrably sitting on the main queue undelivered.
Merged, kept when ≥ 50 ms. Nothing about the poll cycle, the renderer, or
SwiftUI enters that definition.

Recording is `xcrun xctrace record --instrument 'Time Profiler' --instrument
'os_signpost' --instrument 'Hangs' --attach <pid> --time-limit 150s`. Analysis
scripts are single-purpose and were checked against each other; the frame-ref
trap below cost one wrong intermediate reading.

### Two instrument traps hit while building this

- **`xctrace export` ref-compresses backtrace frames.** A row's stack is a
  mixture of `<frame id=…>` and `<frame ref=…>`; resolving only the
  `<backtrace>` element and not each frame yields a stack with one named frame
  and *N* unknowns, which reads exactly like a legitimately truncated stack and
  is not. The first attribution pass reported "100% no TBDApp frame on stack"
  purely from this.
- **A 21-second pilot window disagreed with the 150-second ones**, showing zero
  hop stalls beginning inside hang windows against 24 expected. It was a
  small-sample artifact: at 150 s the same measurement gives 94.6% overlap.
  Short windows are for catching mistimed captures, not for concluding.

## The finding

Two independent 150-second windows, `w2` and `w3`:

- Stall windows (terminal bytes undelivered ≥ 50 ms): **10 totalling 2,016 ms**
  in w2; **30 totalling 5,611 ms** in w3.
- Inside them the main thread is **97–98% on-CPU** — against 21% (w2) and 27%
  (w3) outside. The stall is a busy burst, not a block or a wait.
- Of that in-stall CPU, **92.3% (w2) and 86.9% (w3) sits inside a runloop
  observer callout**.
- Over the same windows, CPU spent **servicing the main dispatch queue falls to
  0.2% (w2) and 5.1% (w3), against 24.6% and 27.9% outside.**

That last contrast is the mechanism rather than a correlation. A block on the
main queue cannot run while the thread is inside a runloop callout, so a long
callout *is* an undrained queue. The duty-cycle correction that killed the
poll-cycle hypothesis does not apply here, because this is not a co-occurrence
claim: it is the same event described from two sides.

The independent form of the claim is the distribution of **uninterrupted
callout runs** — consecutive samples carrying the same callout marker, which
splits (never merges) if the thread goes off-CPU, so these are lower bounds:

```
                                          n     p50    p90    p99    max   >50ms
w2  runloop observer (SwiftUI flush)     259     2.0  205.0  256.0  295.0    105
    main-dispatch-queue block           3095     2.0    3.0    6.0   11.0      0
    source0 (NSEvent / perform)          499     0.0   19.0   30.0   35.0      0
    source1 (mach port)                  154     0.0   19.0   26.0   34.0      0
    runloop timer                         31     0.0    0.0    0.0    0.0      0

w3  runloop observer (SwiftUI flush)     529     3.0  179.0  219.0  366.0    118
    main-dispatch-queue block           4152     2.0    4.0   10.0   89.0      1
    source0 (NSEvent / perform)         1209     4.0   11.0   21.0   33.0      0
    source1 (mach port)                  506     3.0   11.0   26.0   61.0      1
    runloop timer                         49     0.0    0.0    1.0    3.0      0
```

**No other class of main-thread work in either window exceeds 89 ms, and only
once.** The observer callout exceeds 50 ms 105 and 118 times — roughly 0.75 per
second — and reaches 295 ms and 366 ms. It is bimodal: p50 is 2–3 ms, p90 is
179–205 ms. A flush is either trivial or enormous, with very little between.

The observer is identified by the frames immediately inside the callout:
`NSRunLoop.flushObservers()` → **`static Update.end()`** — SwiftUI's update
flush, not CoreAnimation's commit. CoreAnimation's
`CA::Transaction::flush_as_runloop_observer` appears separately and is small
(2,878 ms total in w3, 448 ms of it in stalls).

Across the whole trace the flush costs **18.1 s of 151 s (w2) and 19.1 s of
151 s (w3)** — about 12% of wall clock on one thread.

## Where the time goes inside an expensive flush

Comparing the 105 / 118 flushes ≥ 50 ms against the 139 / 345 flushes < 10 ms as
a control. Buckets are disjoint; the metadata line is cross-cutting and is
deliberately *not* additive with them.

Both windows agree within a couple of points:

- **Attribute-graph propagation and comparison, with no body or view-list above
  it** — 40.7% / 40.3%.
- **View-list rebuild** (`ForEach`/`ViewList.applyNodes`,
  `_ViewList_TemporarySublistTransform`, `SubgraphList`) — 33.3% / 31.5%.
- **`View.body` evaluation** — 21.8% / 23.8%.
- Display list and layout — under 1%.
- *(cross-cutting)* Swift **generic-metadata lookup** at the leaf
  (`MetadataCacheKey::operator==`, `getGenericMetadata`, `getCache`,
  mangled-name instantiation) — 10.8% / 11.4%.

The TBD entry points reached inside an expensive flush, with their share of
flush CPU and their enrichment against the cheap-flush control:

- `WorktreeRowView.body` — 6.7% / 7.5% (12.3x, 2.5x)
- `TabBarItem.body` — 4.1% / 4.6% (present only in fat flushes; 45x in w3)
- `PanePlaceholder.body` — 2.2% / 2.4% (fat-only; 23.7x in w3)
- `initializeWithCopy for Worktree` — 2.6% / 2.2%, plus `destroy for Worktree`
  1.5% / 1.3%: **about 4% of flush CPU is spent copying and releasing
  `Worktree` values**, in `ForEach`'s ID generation and view-list transforms.
- `RepoSectionView.body` — 1.1% / 1.2%; `TerminalPanelView.body` — 1.0% / 1.1%;
  `WorktreeSubtreeView`, `SingleWorktreeView`, `RemoteSessionRowView`,
  `TerminalPanelRepresentable.updateNSView` each under 1%.
- Roughly 72% carries no TBDApp frame at all — SwiftUI and AttributeGraph
  internals between the flush and the next body.

The independent `HangWatchdog` stacks already on disk for this pid corroborate
the same path from a different instrument: a 1,032 ms hang captured
`ForEachState` → `ForEach.IDGenerator.makeID` → value-witness work on
`Worktree` and `PRObservation`, and a 1,246 ms hang captured
`NSHostingView.layout` → `ViewGraph.updateOutputs` → `EnvironmentObject`
`StoreBox.update`.

## A second, smaller burst source

`HoverMenuModel.closeNow()`, invoked from a `NotificationCenter` observer
outside any runloop callout, produced 7 runs of 52–538 ms totalling 2.2 s in
w2 (`HoverMenuModel.init(openDelay:closeGrace:notificationCenter:)` →
`closeNow()` → `setOpen(_:)`). It is an order of magnitude smaller than the
flush and is recorded here so it is not rediscovered as a surprise.

## What this reorders

- **Rendering stays exonerated**, and more firmly. `feed` is 0.11 ms at p50 and
  a display pass 5–9 ms; neither ever appears as a long uninterrupted run.
- **The poll cycle stays exonerated.** Nothing here reinstates it. The poll's
  application of results is one of many writers that can dirty the graph, but
  the cost is in the flush, and the flush is not the poll.
- **`@Observable` migration (#667) is now the directly indicated line of work**,
  not a speculative one: 41% of expensive-flush CPU is attribute-graph
  propagation with no body above it, which is the shape of invalidating far
  more of the graph than changed.
- **Two costs are visible that no migration addresses on its own**: `Worktree`
  being copied and destroyed by value inside `ForEach` identity and view-list
  transforms (~4%), and generic-metadata lookup at ~11%, which is a symptom of
  deeply nested generic view types.

## The fix, measured with the same instrument

Per-property observation tracking (#724) landed while this was being written, so
the same recipe was re-run against it: same window definition, same scripts, same
machine, on an app verified built from `main` + #724 by the source paths baked
into its binary.

**Process age was tested rather than assumed.** Perceived lag had appeared to
worsen with uptime, which would confound any comparison against a freshly
restarted app, so the post-fix side was measured at three ages. It does not
explain the effect: the 6-minute and 59-minute windows agree almost exactly.

```
                          stall%  | hop p99    max  | flush-s  >50ms callouts
w2  before (50min uptime)  1.33%  |   187.9  227.7  |   19.4        105
w3  before (60min uptime)  3.71%  |   257.9  325.2  |   22.2        118
a1  after  ( 6min uptime)  0.26%  |    16.3  139.1  |    3.4         10
a3  after  (59min uptime)  0.26%  |     5.3   58.4  |    6.3         50
a4  after  (76min uptime)  0.83%  |   148.5  162.4  |   11.5         77
```

Stated conservatively, because the post-fix side is variable and a single window
does not characterise it — `a3` reached p99 5.3 ms and `a4` 148.5 ms:

- **Worst observed wait fell from 228–325 ms to 58–162 ms.**
- **Stall load fell from 1.33–3.71% to 0.26–0.83%**, roughly 5x on the means.
- Long callouts have not vanished. `a4` still shows 77 over 50 ms, up to 253 ms.
  They far less often have terminal output waiting behind them, which is why the
  symptom improved more than the flush count did.

### A prediction this record made, and its falsification

An earlier draft of this document predicted that #724 would cut the
attribute-graph slice hardest and leave the `ForEach` view-list rebuild and the
`Worktree` copying largely intact — reasoning that the rebuild runs whenever the
list data changes, which the 2-second poll does regardless of how narrowly
properties are tracked.

That was wrong, and the correction is worth more than the prediction. In absolute
CPU inside expensive flushes:

- **`ForEach` view-list rebuild: 6,190 ms → 201 ms — a 31x cut, the largest.**
- attribute-graph propagation: 7,922 ms → 1,066 ms (7.4x)
- `View.body` evaluation: 4,677 ms → 1,642 ms (2.8x)
- `Worktree` copy and destroy left the top entry points entirely.

So the view-list rebuild was not independent of invalidation — it was *triggered*
by it. Under object-wide notification any `AppState` write invalidated the
observing views, forcing the whole nested `ForEach` list to be reconstructed, and
the `Worktree` copies happened inside that reconstruction. Per-property tracking
stops most of those reconstructions from being requested at all.

The residual has a different shape: body evaluation is now the largest slice
(54.5% in `a3`, 44.8% in `a4`), led by `WorktreeRowView.body`, `TabBarItem.body`
and `PanePlaceholder.body`. That is the next target if anyone pursues the view
graph — but at these latencies it is no longer what a user feels.

## What this does not cover

Every window in this record was taken during ordinary operation with agents
streaming and **no user interaction**. Both intervals measure terminal output
travelling *towards* the screen.

- **Keystroke-to-echo was never measured**, here or anywhere. That gap predates
  this work and survives it.
- **Scrolling was not measured** in any window here either.

Two named mechanisms target exactly those cases and are untouched by anything
measured here: wheel-event amplification (#719), and the 150 ms window after each
keystroke during which `interactiveInputDisplayWindowNs` disables the frame
limiter so every output chunk forces a synchronous redraw. If typing or scrolling
still feel slow, those are better suspects than the view graph.

A window intended to cover typing or scrolling **must be checked for containing
the action**. Four windows earlier in this investigation silently captured no
scrolling and produced a confident, wrong conclusion that reached a committed
spec before a validated re-run reversed it.

## Still open

- **What dirties the graph before each expensive flush.** The flush is bimodal,
  so something distinguishes the 2 ms case from the 200 ms case. This record
  measures the flush, not its trigger.
- **Whether an off-CPU split understates callout length.** Run grouping breaks
  when the thread leaves the CPU, so every duration here is a lower bound.
- **`~/Library/Logs/TBD/hang-stacks/` held 110,512 files** at the time of this
  investigation. That directory is a durable resource with no named reconciler.
  Unrelated to this finding; recorded because it was found here.
