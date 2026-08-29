#!/usr/bin/env python3
"""Report the distribution of app-draw -> render-server-commit latency.

WHAT THE METRIC IS
------------------
`TerminalCommitLatencyProbe` (Sources/TBDApp/Terminal) stamps `t0` at the first
terminal view's `viewWillDraw` in a display cycle, registers a `CATransaction`
completion block on the transaction AppKit is building around that cycle, and
stamps `t1` when CoreAnimation fires it. `commitms = t1 - t0` is the leg between
"the app started painting its terminal content" and "the render server has
committed that frame". `drawms` is the app-side paint span within it: `t0` to
the last terminal draw returning.

WHAT IT IS NOT
--------------
It is NOT time-to-glass. Nothing after the render server's commit is covered:
not WindowServer compositing the layer tree, not the display's scanout. Every
number below is therefore a LOWER BOUND on what a user perceives. If you are
tempted to quote a p99 here as "keystroke latency", don't.

WHY THIS LEG
------------
The terminal-lag investigation ruled out everything upstream with numbers: TBD
reached client parity with other emulators on the same tmux window (PR #750),
the main thread measured 83% idle during a confirmed lag episode, the SwiftTerm
IO threads were idle, and tmux sat at 0.1-0.4% CPU. `sample` followed the trail
to `CA::Transaction::commit` and lost it at the process boundary while
WindowServer ran at 57-66% CPU. The live hypothesis is that TBD presents a deep
SwiftUI-hosted layer tree where iTerm2 presents one flat layer, and that a
loaded compositor degrades the expensive tree. This script measures the first
half of that gap; the second half needs a WindowServer-side instrument we do
not have.

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
percentiles.

DROPPED CYCLES
--------------
`CATransaction.setCompletionBlock` has no getter and replaces any incumbent
block. When AppKit or SwiftUI sets its own block on a transaction after the
probe set one, the probe's block never fires and that cycle is abandoned. The
probe emits a running `commitdrop cycles=<n>` counter; this script reports it,
because a high drop rate means the percentiles describe a biased sample.

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
import re
import sys
from dataclasses import dataclass
from datetime import datetime

# `log show` prefixes each line with e.g. "2026-08-29 10:11:12.345678-0400".
TIMESTAMP_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4})")
COMMIT_RE = re.compile(
    r"\bcommit draws=(\d+) drawms=([\d.]+) commitms=([\d.]+) vis=([01])\b"
)
DROP_RE = re.compile(r"\bcommitdrop cycles=(\d+)\b")

# Load bands, as (label, upper bound exclusive). The last band is open-ended.
LOAD_BANDS = [("load<2", 2.0), ("load 2-8", 8.0), ("load 8-32", 32.0), ("load>=32", None)]


@dataclass(slots=True)
class Sample:
    """One display cycle in which at least one terminal view drew."""

    epoch: float | None
    draws: int
    drawms: float
    commitms: float
    visible: bool


def parse_epoch(line: str) -> float | None:
    match = TIMESTAMP_RE.match(line)
    if not match:
        return None
    try:
        return datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    except ValueError:
        return None


def parse(stream) -> tuple[list[Sample], int]:
    samples: list[Sample] = []
    drops = 0
    for line in stream:
        commit = COMMIT_RE.search(line)
        if commit:
            samples.append(
                Sample(
                    epoch=parse_epoch(line),
                    draws=int(commit.group(1)),
                    drawms=float(commit.group(2)),
                    commitms=float(commit.group(3)),
                    visible=commit.group(4) == "1",
                )
            )
            continue
        drop = DROP_RE.search(line)
        if drop:
            # The counter is cumulative, so the largest value seen is the total.
            drops = max(drops, int(drop.group(1)))
    return samples, drops


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
    """Nearest-rank percentile. `values` must be sorted."""
    if not values:
        return float("nan")
    rank = max(1, min(len(values), int(round(fraction * len(values) + 0.5))))
    return values[rank - 1]


def report_group(label: str, samples: list[Sample]) -> None:
    if not samples:
        print(f"  {label:<16} (no samples)")
        return
    commit = sorted(s.commitms for s in samples)
    draw = sorted(s.drawms for s in samples)
    print(
        f"  {label:<16} n={len(commit):<7}"
        f" p50={percentile(commit, 0.50):8.2f}"
        f" p90={percentile(commit, 0.90):8.2f}"
        f" p99={percentile(commit, 0.99):8.2f}"
        f" max={commit[-1]:8.2f}"
        f"   (drawms p50={percentile(draw, 0.50):.2f} max={draw[-1]:.2f})"
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
        samples, drops = parse(stream)
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

    total = len(samples) + drops
    drop_pct = (100.0 * drops / total) if total else 0.0

    print("app-draw -> render-server-commit latency, milliseconds")
    print("NOT time-to-glass: WindowServer composite and scanout are not covered.")
    print()
    print(f"cycles reported: {len(samples)}   dropped (completion block lost): {drops}"
          f" ({drop_pct:.1f}%)")
    if drop_pct > 20:
        print("  WARNING: a fifth or more of cycles were dropped; this sample is biased.")
    print(f"on screen: {len(samples) - len(offscreen)}   off screen: {len(offscreen)}")
    print()

    print("by draws-per-cycle" + ("" if args.include_offscreen else " (on-screen cycles only)"))
    report_group("all", onscreen)
    report_group("draws=1", [s for s in onscreen if s.draws == 1])
    report_group("draws>1", [s for s in onscreen if s.draws > 1])
    print()

    if not args.include_offscreen and offscreen:
        print("off-screen cycles (work the user never sees)")
        report_group("vis=0", offscreen)
        print()

    if args.load_log:
        series = load_series(args.load_log)
        print("by machine load (1-minute average, nearest sample within 30s)")
        banded: dict[str, list[Sample]] = {}
        for sample in onscreen:
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
