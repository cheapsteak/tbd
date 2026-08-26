# The paint-scheduling floor is real, and one frame of it is removable — 2026-08-26

Tests the hypothesis in issue #741: that `queuePendingDisplay` in the pinned
SwiftTerm revision is a fixed 16.67 ms delay rather than a rate limit, and that
the delay — paid even by the first chunk after an idle period, when there is
nothing to coalesce with — is what puts a floor under keystroke-to-paint latency.

**Confirmed, for the path it governs.** Turning the fixed delay into a rate limit
cut the median paint latency for a typed character from **23.3 ms to 5.1 ms**, a
78% reduction, with burst coalescing measurably unchanged. The size of the drop
is one display frame, which is what the mechanism predicts.

**With one large qualification that changes who benefits.** The pinned revision
already bypasses that timer for characters typed into the view, through a fast
path #741 does not mention. So the frame this change removes is one that *agent
output and injected input* pay, and that a genuinely typed key already avoids.
See "What this does not show" below.

## Result

Median, 90th percentile and maximum of key-to-paint latency, in milliseconds,
over 120 keystrokes per run. Every run listed here passed all four validity
guards; the runs that did not are listed at the end rather than dropped silently.

| build | machine load | p50 | p90 | p99 | max | over 100 ms |
|---|---|---|---|---|---|---|
| unpatched | 26.0 | 23.8 | 25.5 | 28.2 | 53.2 | 0.0% |
| unpatched | 25.5 | 23.2 | 25.1 | 38.9 | 54.3 | 0.0% |
| unpatched | ~30 | 23.4 | 25.2 | 26.5 | 86.5 | 0.0% |
| unpatched | 10.7 | 22.4 | 23.7 | 25.2 | 66.2 | 0.0% |
| unpatched | 9.9 | 23.3 | 24.7 | 25.8 | 48.8 | 0.0% |
| patched | ~48 | 5.2 | 7.1 | 58.4 | 60.8 | 0.0% |
| patched | 11.1 | 5.0 | 6.3 | 42.3 | 45.4 | 0.0% |
| patched | 11.5 | 5.2 | 6.7 | 8.0 | 50.7 | 0.0% |

The two conditions do not overlap anywhere. Within a condition the p50 spread is
1.4 ms unpatched and 0.2 ms patched, against an effect of 18.2 ms — so variance
does not swamp it. The measurement is also insensitive to machine load across the
range sampled, which is what a timer-bound quantity should look like.

The order was A, then B, then A again: the unpatched runs at load 10.7 and 9.9
were taken *after* the patched ones, by reverting the patch and rebuilding, so the
comparison does not rest on the two sides having been measured under whatever
machine state happened to prevail an hour apart. That mattered — see the burst
result below, where the naive before/after ordering produced an effect that the
A/B/A showed to be load, not the patch.

### The size of the drop is the mechanism's own prediction

The unpatched median is 23.3 ms: the 16.67 ms timer, plus about 6.6 ms for AppKit
to run a display cycle after `setNeedsDisplay`. Removing the timer leaves the 6.6
ms, and the patched median is 5.1 ms. A change that merely perturbed scheduling
would not land on the frame interval this exactly.

## The change

`queuePendingDisplay` keeps its `pendingDisplay` gate — one scheduled draw at a
time, which is what collapses a burst — and gains a timestamp of the last display
pass. A draw that is already due is posted for the next main-queue turn; one that
would land sooner than a frame after the previous draw waits out the remainder of
the interval. The `terminal.synchronizedOutputActive` early return is untouched.

The full diff is committed alongside this document as
[`2026-08-26-queue-pending-display-rate-limit.patch`](2026-08-26-queue-pending-display-rate-limit.patch):
46 lines in `Apple/AppleTerminalView.swift` and 6 each in the Mac and iOS views,
which declare the stamp and its lock next to the `lastUserInputUptimeNs` the
revision already carries.

## Burst coalescing is unchanged

The throttle exists to stop a saturated output path drawing once per pty chunk,
so the change had to be shown not to have broken that. Load is `yes` piped through
`head` — line append while scrolling, this renderer's documented worst case.

| build | machine load | chunks/s | draws/s | draws per chunk | feed work per wall-second |
|---|---|---|---|---|---|
| unpatched | 91.4 | 97.9 | 1.5 | 0.015 | 0.84 |
| unpatched | 139.3 | 103.4 | 1.0 | 0.010 | 0.91 |
| unpatched | 10.7 | 91.7 | 0.5 | 0.005 | 0.98 |
| patched | 7.2 | 81.3 | 0.4 | 0.005 | 0.85 |
| patched | 7.4 | 79.9 | 0.6 | 0.008 | 0.86 |

Draws per arriving chunk stays at 0.005–0.008 patched against 0.005 unpatched at
matched load. The failure mode to look for — display passes climbing toward the
chunk rate — is absent by two orders of magnitude.

**The load-matched row is the one that matters, and it is why the A/B/A was worth
the extra rebuild.** Comparing the first two unpatched rows against the patched
rows suggests the patch cut the draw rate from 1.0–1.5/s to 0.4–0.6/s, which would
read as the view being starved worse. It does not survive matching: the unpatched
build at load 10.7 draws 0.5/s, the same as patched. The apparent effect was
entirely the difference between machine load 91–139 and load 7.

`displayPass` duration is not reported here because under saturation it measures
main-queue backlog rather than draw cost — the interval ends on the next
main-queue turn. It read 12–15 ms at load 91–139 and 1.7–1.9 s at load 7–11, on
*both* builds. That is the instrument, not the renderer.

## What this does not show

**A character typed into the view already bypasses this timer, and did before the
patch.** Read from the pinned revision, not measured. `TerminalView.send(data:)`
calls `recordUserInput()`, and for 150 ms afterwards `feedFinish()` routes to
`displayImmediately()` instead of `queuePendingDisplay()`. The echo of a typed
character comes back in well under a millisecond, so that window is open for
essentially every real keystroke, however fast or slow the typist. TBD feeds on
the main thread (`TerminalPanelView.Coordinator.dataReceived(slice:)` dispatches
to main before calling `feed`), so `displayImmediately()` takes its
`Thread.isMainThread` branch and updates the display synchronously.

`tbd terminal send` reaches a pane through `tmux send-keys`
(`TmuxManager.swift`), which never touches the view, so injected keys take the
throttled path. **The measurements above, on both sides, are of a path a
genuinely typed key does not take.** The patch is still worth what it measures —
that path carries all agent output, and every keystroke sent by TBD's own
automation — but it is not a fix for interactive typing latency, because
interactive typing was already taking the fast route.

The two numbers agreeing is itself the consistency check: the patched throttled
path lands at 5.1 ms, which is where the existing user-input fast path should
already be, since both end in a synchronous `updateDisplay` followed by one
AppKit display cycle.

This could not be measured directly. macOS refuses synthetic keystrokes without
an Accessibility grant, which this environment does not have, so there is no way
to drive `send(data:)` from a script. Confirming it needs either that grant or a
human typing into a terminal while signposts are captured.

**Three legs of perceived latency are excluded** and the figures are a lower bound
in all three directions: TBD's own view keydown handling (the same gap #741
carries, for the same reason), the tmux and pty transport leg, separately measured
at 0.1 ms p50, and everything after `viewWillDraw` — the CoreAnimation commit and
the window-server composite. None of the three is touched by a change to display
scheduling, so the before/after difference is unaffected by leaving them out.

**The over-100 ms tail in #741 was not reproduced on either build.** Every clean
run here, patched or not, had 0.0% of keystrokes over 100 ms. Each time a tail did
appear it came from the measurement tab leaving the screen mid-run, which the
guards caught: in one voided run every one of the 34 slow keystrokes was
contiguous, from t=21.1 s to the end of the run. A scheduling defect scatters; a
window going away does not.

A candidate explanation for #741's 10–29% figure, not established here: this
harness also records a `+spawn` upper bound with its own `tmux send-keys` process
spawn left in, and that reads 0.8% to 39% over 100 ms depending on machine load —
the same range. If #741's keys were injected the same way, part of its tail may be
the injection harness rather than TBD. Its measurements were taken at load 63–119,
where spawn cost here reached a p50 of 57 ms.

## Method

`scripts/diag/key-to-paint.py` and `scripts/diag/burst-coalescing.py`, added with
this document. #740 committed the key-to-paint *result* but no tool, so the
harness is new.

The pane runs `cat` and no newline is ever sent, so the only output is the tty
line-discipline echo: one byte in, one byte out, exactly one pty chunk per
keystroke. That is what makes the measurement keystroke-anchored rather than the
inflated "chunk to next display pass" metric already discarded once — a shell
emits roughly 8.75 chunks per typed character, most of them mid-burst fragments
waiting on the next character's draw.

Latency is measured from the arrival of that keystroke's own chunk
(`mainThreadHop` begin) to the next `displayPass` begin. Both endpoints are TBD's
own signposts, so the number carries none of the harness's overhead — which
matters, because `tmux send-keys` process spawn cost ranged from 5 ms to 57 ms
across this machine's load and would otherwise have swamped an 18 ms effect.

Gaps between keystrokes are randomised from a fixed seed, so both sides get an
identical cadence and neither aliases against a fixed-interval frame timer.

### Four guards, and what each one caught

Every one of these fired on real runs during this investigation. They are the
reason the reported numbers are the ones they are.

- **Idle control.** Four seconds of capture with nothing typed. A display pass
  here belongs to some other visible terminal. Caught five runs.
- **Echo chunks per keystroke must be 1:1.** Caught runs where keys were lost
  entirely — under load the pane's `cat` had not started and every keystroke went
  nowhere, while the run still produced a full-looking latency table computed from
  another terminal's chunks. One voided run had 683 foreign chunks and zero echoes.
- **Display passes per keystroke must be at least 0.95.** Catches the measurement
  tab going off screen mid-run, which produces a plausible median and a wild tail.
- **Chunk rate floor, on the burst harness.** `timeout` is GNU coreutils and is
  not on a stock macOS. The first burst run measured an idle terminal and reported
  `COALESCING PRESERVED` with total confidence.

Two further instrument errors were found and fixed before any number was trusted:

- **Anchoring on when `tmux send-keys` returns is too late.** The echo reaches TBD
  while the tmux client is still tearing down, so each keystroke was matched to the
  *next* keystroke's chunk and the harness reported an inter-key gap of 278 ms as
  latency. Anchoring the search at launch time, which is necessarily before the
  byte exists, fixes it.
- **TBD feeds terminals that are not on screen.** A 10-second idle capture showed
  90 chunk arrivals and zero display passes. Those chunks cannot serve any
  keystroke's paint but they do break a naive "next chunk after the key" match.
  Isolating the pane under test by its one-byte echo removes them, and because
  they never draw, they never contaminate the display-pass side at all.

### Runs voided by the guards

Recorded so the reported set is not mistaken for the set that was taken.
Unpatched: one run with 37 idle display passes and 2.57 chunks per keystroke; one
with zero echo chunks and 39 idle passes. Patched: two runs where the tab left the
screen (88 and 94 of 120 keys drawn, and one with a contiguous slow block from
t=21.1 s); two with zero echo chunks; one with 24 idle passes; one with 5.40
chunks per keystroke. Burst: two runs where the load never started.

## Carrying this

`queuePendingDisplay` is in the pinned dependency, not in TBD. The revision is
pinned by SHA in `Package.swift` (`16c5286`), so there is no build-time patch
hook: carrying this means either an upstream change, or a fork pinned in place of
the upstream URL, or a checked-in patch applied to the checkout by a build step.
None of those exists today, and adding one is a larger decision than this
measurement settles — particularly given that the change does not touch
interactive typing, which is what #741 set out to improve.

The measurement itself needs none of that: `swift package edit SwiftTerm` gives an
editable checkout, the patch applies to it, and `swift package unedit SwiftTerm`
restores the pin. That is how these numbers were taken.
