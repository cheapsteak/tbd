#!/usr/bin/env python3
"""Summarize com.tbd.app render-latency signposts from an `log stream --signpost` ndjson capture.

Usage: signpost-report.py <capture.ndjson> <label> [--window START END]

Reads the three intervals emitted by the temporary RenderLatencySignposts
instrumentation (see the accompanying research doc for how to build it):

  mainThreadHop  main-thread QUEUEING DELAY for a pty chunk -- not work done.
  feed           the nested TerminalView.feed() call: parse + damage tracking.
                 Synchronous and nested, so this is the trustworthy cost signal.
  displayPass    UPPER BOUND on one AppKit display pass. It ends on the next
                 main-queue turn, so a backed-up main queue inflates it. Do not
                 read a large displayPass as "drawing was slow".

Also reports `feed work per wall-second`: total feed time divided by window span.
Above ~1.0 the main thread is saturated by parsing alone, before any drawing.

By default the densest contiguous 25s sub-window is chosen, so idle head/tail
around the load period does not dilute the rates. Pass --window to override.
"""
import json, re, sys
from collections import defaultdict


def load(path):
    """Match begin/end signpost pairs by (signpostID, name). Returns {name: [(start, end)]}."""
    open_intervals, intervals = {}, defaultdict(list)
    for line in open(path, errors="replace"):
        line = line.strip().rstrip(",")
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        sid = event.get("signpostID")
        name = event.get("signpostName") or event.get("eventMessage", "").split(":")[0]
        stamp = re.search(r"(\d{2}):(\d{2}):(\d{2})\.(\d+)", event.get("timestamp", ""))
        if not stamp or sid is None:
            continue
        frac = (stamp.group(4) + "000000000")[:9]
        t = (int(stamp.group(1)) * 3600 + int(stamp.group(2)) * 60
             + int(stamp.group(3)) + int(frac) / 1e9)
        key = (sid, name)
        kind = event.get("signpostType", "")
        if kind == "begin":
            open_intervals[key] = t
        elif kind == "end" and key in open_intervals:
            intervals[name].append((open_intervals.pop(key), t))
    return intervals


def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))]


def densest_window(hops, t0, span):
    per_second = defaultdict(int)
    for start, _ in hops:
        per_second[int(start - t0)] += 1
    last = max(per_second) if per_second else 0
    best = (0, -1)
    for begin in range(0, max(1, last - span + 1)):
        count = sum(per_second.get(s, 0) for s in range(begin, begin + span))
        if count > best[1]:
            best = (begin, count)
    return best[0], per_second, last


def main():
    args = sys.argv[1:]
    window = None
    if "--window" in args:
        i = args.index("--window")
        window = (float(args[i + 1]), float(args[i + 2]))
        del args[i:i + 3]
    path, label = args[0], args[1]

    intervals = load(path)
    hops = sorted(intervals.get("mainThreadHop", []))
    if not hops:
        print(f"{label}: no mainThreadHop intervals -- capture is void")
        return 1
    t0 = min(h[0] for h in hops)

    if window:
        start, end = window
        per_second, last = None, None
    else:
        span = 25
        start, per_second, last = densest_window(hops, t0, span)
        end = start + span
        print("per-second mainThreadHop counts:")
        print("  " + " ".join(str(per_second.get(s, 0)) for s in range(last + 1)))

    lo, hi = t0 + start, t0 + end
    # Effective span: `log stream` starts mid-flight and the load may end before the
    # nominal window does, so rates must divide by the span actually covered by data,
    # not by the nominal window width. Intervals whose begin predates t0 (their
    # matching begin was never captured) are excluded by the `lo <= s` bound below.
    covered = [(s_, e_) for v in intervals.values() for s_, e_ in v if lo <= s_ < hi]
    width = (max(e_ for _, e_ in covered) - min(s_ for s_, _ in covered)) if covered else (end - start)
    if width <= 0:
        width = end - start
    print(f"\n=== {label} | window t=[{start:.0f},{end:.0f}) covered span={width:.1f}s ===")
    for name in ("mainThreadHop", "feed", "displayPass", "rpc.pollCycle"):
        durations = [(e - s) * 1000 for s, e in intervals.get(name, []) if lo <= s < hi]
        if not durations:
            print(f"  {name:14s} none")
            continue
        print(f"  {name:14s} n={len(durations):5d} rate={len(durations)/width:6.1f}/s  "
              f"p50={pct(durations,.5):7.2f}  p90={pct(durations,.9):7.2f}  "
              f"p99={pct(durations,.99):8.2f}  max={max(durations):8.2f} ms")

    passes = sorted(p for p in intervals.get("displayPass", []) if lo <= p[0] < hi)
    if len(passes) > 1:
        gaps = [(passes[i + 1][0] - passes[i][1]) * 1000 for i in range(len(passes) - 1)]
        print(f"  gaps between passes  p50={pct(gaps,.5):7.1f}  p90={pct(gaps,.9):7.1f}  "
              f"max={max(gaps):8.1f} ms   ({sum(1 for g in gaps if g > 100)} over 100ms)")

    feed_work = sum(e - s for s, e in intervals.get("feed", []) if lo <= s < hi) / width
    pass_work = sum(e - s for s, e in intervals.get("displayPass", []) if lo <= s < hi) / width
    print(f"\n  feed work per wall-second        = {feed_work:.2f} s/s"
          f"   ({'SATURATED' if feed_work > 0.9 else 'headroom'})")
    print(f"  displayPass(upper bound) per s   = {pass_work:.2f} s/s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
