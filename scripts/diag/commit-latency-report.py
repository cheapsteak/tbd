#!/usr/bin/env python3
"""Report the distribution of the app-side commit latency of terminal frames.

WHAT THE METRIC IS
------------------
`TerminalCommitLatencyProbe` (Sources/TBDApp/Terminal) stamps `t0` at the first
terminal view's `viewWillDraw` in a display cycle, marks the `CATransaction`
AppKit is building around that cycle, registers a completion block on it, and
stamps `t1` when CoreAnimation runs that block. `commitms = t1 - t0`.

WHAT IT IS NOT -- AND THIS IS NOT A QUIBBLE
-------------------------------------------
`commitms` is APP-SIDE ONLY. It does not cross into the render server, and it
is nowhere near time-to-glass.

Measured with a real on-screen window and real committed layer changes, the
completion block runs 12-99 MICROSECONDS after `CATransaction.commit()`
returns, on the same runloop turn. Nothing round-trips to WindowServer in 20us.
Apple's contract for `setCompletionBlock` says the block runs "as soon as all
animations subsequent to this transaction group have completed", and with no
animations "will be invoked immediately" -- the render server is not mentioned
because it is not involved.

So a small `commitms` licenses NO conclusion about the compositor. It says the
app hands the frame over quickly, which is where the evidence already pointed.
Do not read it as "the render server is fine". The render-server leg remains
uninstrumented: no public API exposes it for a CoreGraphics-drawn NSView
(CAMetalDrawable.addPresentedHandler would, but TBD does not use Metal).

THE ANIMATION DISTORTION, AND WHY `sync` EXISTS
-----------------------------------------------
Because the block waits for ANIMATIONS rather than for a commit, any animation
inside a marked transaction redefines `commitms`. Measured: a finite 0.6s
animation deferred the block by 675ms -- a sample that reports an animation
duration and lands in p90/p99 looking exactly like a compositor stall. An
infinite animation meant the block never fired at all, and the cycle surfaces
as a drop. TBD's terminal has both: SwiftTerm's caret blink repeats forever,
and the overlay scroller fades over 0.25s -- during scrolling, which is the lag
repro.

`sync` separates them. `sync=1` means the completion block ran in the same
runloop turn as the draw: no animation wait, the number means what it says.
`sync=0` means it arrived later -- an animation wait, a commit spanning turns,
or both, indistinguishable from inside the process. This script reports the two
populations separately and never pools them. Read `sync=1` as the measurement
and `sync=0` as a count of cycles you cannot use.

WHY THIS LEG
------------
The terminal-lag investigation ruled out everything upstream with numbers: TBD
reached client parity with other emulators on the same tmux window (PR #750),
the main thread measured 83% idle during a confirmed lag episode, the SwiftTerm
IO threads were idle, and tmux sat at 0.1-0.4% CPU. `sample` followed the trail
to `CA::Transaction::commit` and lost it at the process boundary while
WindowServer ran at 57-66% CPU. The live hypothesis is that TBD presents a deep
SwiftUI-hosted layer tree where iTerm2 presents one flat layer, and that a
loaded compositor degrades the expensive tree.

This script puts a per-frame number on `CA::Transaction::commit` itself -- the
last thing `sample` could see. It stops there. Confirming or refuting the
compositing hypothesis needs a WindowServer-side instrument that does not
exist here.

WHY THE SPLIT BY draws-per-cycle
--------------------------------
Several terminal views can draw in one transaction (TBD keeps terminals for
unselected worktrees alive and fed). A cycle with several drawing views is
doing more app-side work AND presenting more dirty layers, so mixing the two
populations hides which one moves. `draws=1` is the shape a single focused
terminal produces; `draws>1` is the fleet-of-panels shape.

WHY vis MATTERS
---------------
`vis=0` means no view in that cycle was genuinely on screen (a non-empty
`visibleRect` inside a visible, unoccluded window). Off-screen cycles are work
the user never sees; they belong in a separate bucket, not in the headline
percentiles. Drop lines carry `vis` too, because drops cluster on animated
frames rather than falling randomly -- knowing whether the lost ones were on
screen is what makes the bias characterizable rather than merely flagged.

DROPPED CYCLES
--------------
`CATransaction.setCompletionBlock` has no getter and replaces any incumbent
block. When AppKit or SwiftUI sets its own block on a transaction after the
probe set one, the probe's block never fires and that cycle is lost. An
animation still running in the transaction produces the same observable, and
the two causes cannot be told apart from inside the process -- so a high drop
rate may mean "our block was replaced" OR "animations were running", not
necessarily a biased sample. The probe emits one `commitdrop draws=<n> vis=<0|1>`
line per lost cycle -- one line each, not a
running total, so a windowed read of the log counts the drops in its own window
instead of inheriting a process-lifetime counter. A high drop rate means the
percentiles describe a biased sample, so it is reported alongside them.

USAGE
-----
Turn the diagnostic on, relaunch the app, reproduce a lag episode, then:

    defaults write TBDApp enableCommitLatencyDiagnostic -bool true
    # relaunch TBDApp, reproduce, then:
    log show --last 5m --info \
      --predicate 'subsystem == "com.tbd.app" AND category == "commitlatency"' \
      | scripts/diag/commit-latency-report.py
    defaults write TBDApp enableCommitLatencyDiagnostic -bool false

Optionally correlate with machine load. The log lines carry no load figure --
reading `getloadavg` once per frame would be its own overhead -- so sample it
alongside in a second shell and join on time:

    while :; do
      printf '%s %s\n' "$(date +%s)" "$(sysctl -n vm.loadavg | awk '{print $2}')"
      sleep 5
    done > /tmp/load.log

    ... | scripts/diag/commit-latency-report.py --load-log /tmp/load.log
"""

from __future__ import annotations

import argparse
import bisect
import math
import re
import sys
from dataclasses import dataclass
from datetime import datetime

# `log show` prefixes each line with e.g. "2026-08-29 10:11:12.345678-0400".
TIMESTAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4})")
COMMIT_RE = re.compile(
    r"\bcommit draws=(\d+) paints=(\d+) drawms=([\d.]+) commitms=([\d.]+)"
    r" vis=([01]) sync=([01])\b"
)
# One line per lost cycle, so drops are counted within the window being read
# rather than inherited from a process-lifetime counter.
DROP_RE = re.compile(r"\bcommitdrop draws=(\d+) vis=([01])\b")

# Load bands, as (label, upper bound exclusive). The last band is open-ended.
LOAD_BANDS = [("load<2", 2.0), ("load 2-8", 8.0), ("load 8-32", 32.0), ("load>=32", None)]


@dataclass(slots=True)
class Sample:
    """One display cycle in which at least one terminal view drew."""

    epoch: float | None
    draws: int
    paints: int
    drawms: float
    commitms: float
    visible: bool
    synchronous: bool


def parse_epoch(line: str) -> float | None:
    match = TIMESTAMP_RE.match(line)
    if not match:
        return None
    try:
        return datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    except ValueError:
        return None


def parse(stream) -> tuple[list[Sample], int, int]:
    samples: list[Sample] = []
    drops = 0
    drops_onscreen = 0
    for line in stream:
        commit = COMMIT_RE.search(line)
        if commit:
            samples.append(
                Sample(
                    epoch=parse_epoch(line),
                    draws=int(commit.group(1)),
                    paints=int(commit.group(2)),
                    drawms=float(commit.group(3)),
                    commitms=float(commit.group(4)),
                    visible=commit.group(5) == "1",
                    synchronous=commit.group(6) == "1",
                )
            )
            continue
        drop = DROP_RE.search(line)
        if drop:
            drops += 1
            if drop.group(2) == "1":
                drops_onscreen += 1
    return samples, drops, drops_onscreen


def load_series(path: str) -> list[tuple[float, float]]:
    series: list[tuple[float, float]] = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                series.append((float(parts[0]), float(parts[1])))
            except ValueError:
                continue
    series.sort()
    return series


def load_at(series: list[tuple[float, float]], epoch: float | None) -> float | None:
    """Nearest load sample at or before `epoch`, within 30s."""
    if not series or epoch is None:
        return None
    index = bisect.bisect_right(series, (epoch, float("inf"))) - 1
    if index < 0:
        return None
    when, value = series[index]
    return value if epoch - when <= 30 else None


def band_for(load: float | None) -> str:
    if load is None:
        return "load unknown"
    for label, upper in LOAD_BANDS:
        if upper is None or load < upper:
            return label
    return LOAD_BANDS[-1][0]


def percentile(values: list[float], fraction: float) -> float:
    """Nearest-rank percentile, rank = ceil(p*n), clamped. `values` must be sorted.

    `ceil`, not `round(p*n + 0.5)`: Python rounds half to even, so that form
    overshoots — at n=100 it puts p99 on rank 100, reporting the maximum. This
    matches InputLatencyRecorder.percentile in the daemon.
    """
    if not values:
        return float("nan")
    rank = max(1, min(len(values), math.ceil(fraction * len(values))))
    return values[rank - 1]


def report_group(label: str, samples: list[Sample]) -> None:
    if not samples:
        print(f"  {label:<16} (no samples)")
        return
    commit = sorted(s.commitms for s in samples)
    # `drawms` spans the first draw to the last paint, so it only describes
    # paint cost when every draw in the cycle actually painted. Any shortfall
    # (SwiftTerm's `draw` has early returns before its frame-presented hook)
    # truncates the span for a reason unrelated to paint speed.
    draw = sorted(s.drawms for s in samples if s.paints == s.draws)
    unpainted = len(samples) - len(draw)
    paint = (
        f"   (drawms p50={percentile(draw, 0.50):.2f} max={draw[-1]:.2f})"
        if draw
        else "   (no painted cycles)"
    )
    if unpainted:
        paint += f" [{unpainted} incompletely painted]"
    print(
        f"  {label:<16} n={len(commit):<7}"
        f" p50={percentile(commit, 0.50):8.2f}"
        f" p90={percentile(commit, 0.90):8.2f}"
        f" p99={percentile(commit, 0.99):8.2f}"
        f" max={commit[-1]:8.2f}"
        f"{paint}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="p50/p90/p99/max of app-draw -> render-server-commit latency.",
        epilog="All figures are milliseconds, and are a LOWER BOUND on time-to-glass.",
    )
    parser.add_argument(
        "logfile",
        nargs="?",
        help="`log show` output to read; defaults to stdin.",
    )
    parser.add_argument(
        "--load-log",
        help="Sidecar file of '<epoch> <load1>' lines, to split figures by machine load.",
    )
    parser.add_argument(
        "--include-offscreen",
        action="store_true",
        help="Fold vis=0 cycles into the headline figures instead of reporting them apart.",
    )
    args = parser.parse_args()

    stream = open(args.logfile, encoding="utf-8") if args.logfile else sys.stdin
    try:
        samples, drops, drops_onscreen = parse(stream)
    finally:
        if args.logfile:
            stream.close()

    if not samples:
        print("No `commit draws=...` lines found.", file=sys.stderr)
        print(
            "Is `defaults write TBDApp enableCommitLatencyDiagnostic -bool true` set,"
            " and did the app relaunch after? `log show` also needs --info.",
            file=sys.stderr,
        )
        return 1

    offscreen = [s for s in samples if not s.visible]
    onscreen = samples if args.include_offscreen else [s for s in samples if s.visible]
    # Never pool these two. See the docstring: a sync=0 sample may be reporting
    # an animation's duration rather than a commit's cost.
    deferred = [s for s in onscreen if not s.synchronous]
    clean = [s for s in onscreen if s.synchronous]

    total = len(samples) + drops
    drop_pct = (100.0 * drops / total) if total else 0.0

    print("app-side commit latency of terminal frames, milliseconds")
    print("NOT time-to-glass, and NOT a render-server round trip: the CATransaction")
    print("completion block runs on the same runloop turn, ~12-99us after commit.")
    print()
    print(f"cycles reported: {len(samples)}   never completed: {drops}"
          f" ({drop_pct:.1f}%, {drops_onscreen} of them on screen)")
    if drop_pct >= 20:
        print("  WARNING: a fifth or more of cycles never completed. That is either our")
        print("  completion block being replaced, or animations still running in those")
        print("  transactions -- indistinguishable from here. Treat the rest as partial.")
    print(f"on screen: {len(samples) - len(offscreen)}   off screen: {len(offscreen)}")
    print(f"of the on-screen cycles: {len(clean)} sync=1 (usable), "
          f"{len(deferred)} sync=0 (animation wait or multi-turn commit)")
    print()

    scope = "" if args.include_offscreen else ", on screen"
    print(f"by draws-per-cycle (sync=1 only{scope}) -- THE measurement")
    report_group("all", clean)
    report_group("draws=1", [s for s in clean if s.draws == 1])
    report_group("draws>1", [s for s in clean if s.draws > 1])
    print()

    if deferred:
        print("sync=0 cycles -- NOT comparable; commitms here may be an animation's")
        print("duration rather than a commit's cost. Shown to be accounted for, not read.")
        report_group("deferred", deferred)
        print()

    if not args.include_offscreen and offscreen:
        print("off-screen cycles (work the user never sees)")
        report_group("vis=0", offscreen)
        print()

    if args.load_log:
        series = load_series(args.load_log)
        print("by machine load (1-minute average, nearest sample within 30s; sync=1 only)")
        banded: dict[str, list[Sample]] = {}
        for sample in clean:
            banded.setdefault(band_for(load_at(series, sample.epoch)), []).append(sample)
        for label, _ in LOAD_BANDS:
            if label in banded:
                report_group(label, banded[label])
        if "load unknown" in banded:
            report_group("load unknown", banded["load unknown"])
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
