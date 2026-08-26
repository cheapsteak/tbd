#!/usr/bin/env python3
"""Pair render-latency signpost begin/end rows and report the latency distribution.

Feed it the ndjson produced by:

    log stream --style ndjson --signpost \
        --predicate 'subsystem == "com.tbd.app" AND category == "renderlatency"' \
        > /tmp/renderlatency.ndjson

Usage: render-latency-report.py /tmp/renderlatency.ndjson
"""
import json
import sys
from collections import defaultdict

# Apple Silicon mach timebase: 125/3 ns per tick. Verified on this machine via
# mach_timebase_info(); override if you run this on Intel (numer=denom=1).
NS_PER_TICK = 125 / 3


def main(path: str) -> None:
    open_intervals: dict[tuple, int] = {}
    durations: dict[str, list[float]] = defaultdict(list)
    begins: dict[str, list[int]] = defaultdict(list)
    unmatched = 0

    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("eventType") != "signpostEvent":
                continue
            name = row["signpostName"]
            key = (name, row["signpostID"], row["processID"])
            kind = row["signpostType"]
            if kind == "begin":
                open_intervals[key] = row["machTimestamp"]
                begins[name].append(row["machTimestamp"])
            elif kind == "end":
                start = open_intervals.pop(key, None)
                if start is None:
                    unmatched += 1
                    continue
                durations[name].append((row["machTimestamp"] - start) * NS_PER_TICK / 1e6)

    for name in sorted(durations):
        report(f"{name} duration (ms)", sorted(durations[name]))

    gaps = sorted(
        (b - a) * NS_PER_TICK / 1e6
        for a, b in zip(sorted(begins["displayPass"]), sorted(begins["displayPass"])[1:])
    )
    if gaps:
        report("displayPass inter-frame gap (ms)", gaps)

    if unmatched or open_intervals:
        print(f"\n(unmatched: {unmatched} end-without-begin, {len(open_intervals)} begin-without-end)")


def report(label: str, values: list[float]) -> None:
    def pct(p: float) -> float:
        return values[min(len(values) - 1, int(len(values) * p))]

    print(
        f"{label}: n={len(values)} "
        f"p50={pct(0.50):.2f} p90={pct(0.90):.2f} p99={pct(0.99):.2f} max={values[-1]:.2f}"
    )


if __name__ == "__main__":
    main(sys.argv[1])
