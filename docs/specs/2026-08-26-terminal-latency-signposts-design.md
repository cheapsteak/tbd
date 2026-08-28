# Permanent signposts on the terminal output path

## Why

TBD had no way to see how long terminal output waits before it reaches the
screen. That gap cost this project several wrong conclusions: main-thread
*utilisation* was measured repeatedly and found low, and low utilisation was
read as "the app is not the problem" — but utilisation cannot see queueing
delay, and a main thread that is idle 80% of the time can still stall terminal
I/O for a third of a second at a stretch.

Temporary instrumentation closed that gap and immediately produced the answer
(`docs/perf/2026-08-26-main-thread-burst-attribution.md`): output was waiting up
to 325 ms behind a single SwiftUI view-graph flush. It also measured the fix —
after per-property observation tracking (#724), the same instrument shows the
worst wait falling to 58 ms and the 99th percentile to 5.3 ms.

That instrument is currently a commit marked *do not merge*. Deleting it means
the next person to investigate this area starts from zero again, which is
precisely the loop `docs/diagnostics-strategy.md` exists to break:

> Every interesting event in TBD should already be logged. The default log
> stream should still be quiet enough to read.

This spec makes the two load-bearing intervals permanent.

## What ships

Two `os_signpost` intervals on subsystem `com.tbd.app`, category
`perf-terminal`, emitted for every chunk of terminal output:

- **`mainThreadHop`** — begins on the pty reader thread immediately before the
  `DispatchQueue.main.async` in `TerminalPanelRepresentable.Coordinator.dataReceived(slice:)`,
  ends inside that block. The duration *is* the main-thread queueing delay for
  terminal output. Carries the chunk's byte count.
- **`feed`** — the nested `TerminalView.feed(byteArray:)` call, separating parse
  cost from queueing delay.

Every chunk is instrumented rather than sampled. The tail is the entire point:
the median hop is 0.05 ms in every window measured, and the finding lives at the
99th percentile.

`mainThreadHop` is also what defines an analysis *window*. A period during which
at least one interval is open is a period when terminal bytes were demonstrably
sitting undelivered — a window definition derived from the symptom rather than
from a suspect. That property is what let the attribution work rule out the poll
cycle rather than assume it, and it is the reason this interval in particular is
worth keeping.

## Rejected: an interval around the display pass

A third interval wrapping one AppKit display pass is deliberately excluded.

`TerminalView.draw(_:)` is `public`, not `open`, so it cannot be overridden from
this module. The only reachable seam is `viewWillDraw()`, and closing an interval
opened there requires posting an extra block to the main queue on every display
pass — roughly nine per second in steady state.

That block lands on **the very queue whose delay `mainThreadHop` exists to
measure**. A permanent instrument that adds traffic to its own subject is not
acceptable at any cost, and this one buys little: a display pass is 5–9 ms
against stalls of hundreds of milliseconds, and display-pass timing has never
been the quantity in question.

The measurement is also treacherous at the sample sizes available. Display-pass
duration showed a 3.99x enrichment against stalls on twelve observations — a
sample size that had already produced one retracted conclusion in the same
investigation, and which a larger window reduced to noise.

Inter-frame timing remains available from Instruments' own Core Animation
instruments when it is wanted, without TBD paying for it continuously.

## No feature flag

`docs/diagnostics-strategy.md` settles this. Signposts are silent unless a
recording tool is attached, which makes them the same class of always-on,
zero-default-cost diagnostic as a `.debug` log line. `TranscriptSignposts`
(categories `perf-transcript`, `perf-rpc`) is the existing precedent and carries
no flag.

CLAUDE.md requires a default-off flag for behaviour that acts autonomously,
destroys state, or replaces a load-bearing path. Emitting a signpost does none
of those. Adding a flag would contradict the diagnostics principle directly —
"never delete a log line to reduce noise" applies with equal force to never
making one conditional on a toggle nobody will remember to set.

## Placement

`TerminalSignposts` lives in `Sources/TBDApp/Diagnostics/`, beside
`TranscriptSignposts`, and follows its convention of documenting the region names
in a doc comment on the enum. The category `perf-terminal` matches the existing
`perf-transcript` and `perf-rpc`, so the three read as one family and a capture
predicate can select any of them by prefix.

Region names are load-bearing: the analysis scripts match on them verbatim. They
are documented in the enum and asserted by a test, so a rename cannot silently
break the tooling.

## Analysis tooling

`scripts/diag/render-latency-report.py` pairs intervals from `log stream` ndjson
and prints percentiles. It is the quick check: no Xcode required, useful for
answering "is output waiting at all right now?".

`scripts/diag/main-thread-attribution.py` is the full instrument, for answering
"waiting behind *what*?". It records Instruments' hang detector, a 1 ms
sampling profiler and the signposts into **one** `xctrace` trace, so all three
share a timeline and correlation is exact rather than clock-matched. They then
attribute main-thread CPU inside symptom-defined windows by which runloop
callout it hangs off.

Two traps are documented with them, because both cost real time to rediscover:

- `xctrace export` ref-compresses backtrace frames (`<frame ref="…"/>`).
  Resolving only the `<backtrace>` element yields a stack with one named frame
  and *N* unknowns, which reads exactly like a legitimately truncated stack and
  is not.
- Raw co-occurrence is not evidence when the suspect occupies a large fraction
  of the timeline. Compute the suspect's duty cycle and test enrichment against
  chance. That single check is what refuted the poll-cycle hypothesis, which had
  looked like a 6x effect on a small sample and turned out to be 1.02x.

## Cost

Two `beginInterval`/`endInterval` pairs per chunk of terminal output. When no
recording tool is attached, `os_signpost` emission is a predicted-not-taken
branch on a global flag. No allocation, no dispatch, no lock. Nothing is added
to the main queue, which is the property that distinguishes this from the
excluded a display-pass interval.

## Testing

There is no conditional, so the both-branches rule does not apply. One test
asserts the emitted region names and category are unchanged, since the analysis
scripts match on them verbatim and a silent rename would break tooling without
breaking a build.

## What this deliberately does not measure

Both intervals cover terminal output travelling **towards** the screen. Neither
measures keystroke-to-echo, and neither measures scrolling.

This matters because typing and scrolling have their own suspected mechanisms —
wheel-event amplification (#719) and the 150 ms post-keystroke window during
which the frame limiter is disabled — and both are untouched by anything
measured here. Typing has still never been measured under a validated window.

A future window that intends to cover typing or scrolling must be **checked for
containing that action**, not assumed to. Four windows earlier in this
investigation silently captured no scrolling and produced a confident, wrong
conclusion that reached a committed spec before a validated re-run reversed it.
