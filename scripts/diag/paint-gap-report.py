#!/usr/bin/env python3
"""Report terminal paint cadence, and join it against keystroke queueing delay.

    paint-gap-report.py [--last 30m]

Answers the question a keystroke-latency number cannot: when a character appears
late, is it because the app was slow to accept the key, or because nothing
painted? During a reported lag episode those gave opposite readings -- keystrokes
reached the main thread in 0.85 ms while the median gap between paints was 101 ms
and 94% of the window sat in gaps over 100 ms.

Both inputs are `info` log lines, not signposts, and that is load-bearing.
Signposts for this subsystem live in a ring buffer of roughly 900 events and are
never persisted: `log show --last 5m` and `--last 120m` both return ~900, while
info lines over the same spans scale 378 -> 5893. A signpost capture read back an
hour later is empty, from an app that was working fine.

The join is the discriminator between two explanations of starved paints:

  - keystrokes INSIDE a long paint gap are ALSO slow  -> the main thread was
    contended during the gap, and moving painting off it would help.
  - keystrokes inside a gap are just as fast as outside -> the main thread was
    free and the gate is below the app (CoreAnimation commit or window-server
    compositing), which no app-side renderer change escapes.
"""
import argparse, bisect, re, subprocess, sys

PAINT = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d+).*paint term=(\S+)(?: chunks1s=(\d+))?")
KEY = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d+).*keyqueue ms=([0-9.]+)(?: chunks1s=(\d+))? responder=(\S+)")


def secs(m):
    return (int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
            + int((m.group(4) + "000000")[:6]) / 1e6)


def show(last, category):
    return subprocess.run(
        ["/usr/bin/log", "show", "--last", last, "--info", "--style", "compact",
         "--predicate", f'subsystem == "com.tbd.app" AND category == "{category}"'],
        capture_output=True, text=True).stdout


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * q))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--last", default="30m")
    ap.add_argument("--term", default="", help="only paints of this terminal id prefix")
    args = ap.parse_args()

    paints = []
    for ln in show(args.last, "paintcadence").splitlines():
        m = PAINT.search(ln)
        if not m:
            continue
        if args.term and not m.group(5).startswith(args.term):
            continue
        paints.append((secs(m), int(m.group(6)) if m.group(6) else None))
    paints.sort()

    keys = []
    for ln in show(args.last, "keylatency").splitlines():
        m = KEY.search(ln)
        if m and "TerminalView" in m.group(7):
            keys.append((secs(m), float(m.group(5))))
    keys.sort()

    if len(paints) < 2:
        print(f"Only {len(paints)} paint lines in the last {args.last}. Either nothing drew,")
        print("or the running build predates the paintcadence instrument. Check:")
        print("  strings /Applications/TBD.app/Contents/MacOS/TBDApp | grep -c paintcadence")
        return 1

    span = paints[-1][0] - paints[0][0]
    # A gap is only starvation if there was something to draw. An idle terminal
    # legitimately goes seconds without painting; counting those as lag is the
    # error the #740 doc already retracted once. `chunks1s` rides on every paint,
    # so a gap counts only when output was flowing at BOTH ends of it.
    labelled = any(c is not None for _, c in paints)
    gaps = []
    for i in range(len(paints) - 1):
        (t0, c0), (t1, c1) = paints[i], paints[i + 1]
        d = (t1 - t0) * 1000
        if d >= 60000:
            continue
        busy = (c0 is not None and c1 is not None and c0 > 0 and c1 > 0)
        gaps.append((t0, t1, d, busy))
    idle_gaps = [g for g in gaps if not g[3]]
    if labelled:
        gaps = [g for g in gaps if g[3]]
    if not gaps:
        print(f"paints={len(paints)} over {span:.0f}s, but no gap had output flowing at both ends.")
        print("Nothing was being drawn, so there is no starvation to measure here.")
        return 0
    d = [g[2] for g in gaps]
    print(f"paints={len(paints)} over {span:.0f}s = {len(paints)/span:.2f}/s     keystrokes={len(keys)}")
    if labelled:
        print(f"  gaps considered: {len(gaps)} with output flowing at both ends "
              f"({len(idle_gaps)} idle gaps excluded -- an idle terminal not painting is correct)")
    else:
        print("  WARNING: paint lines carry no chunks1s label (older build) -- idle gaps are NOT excluded")
    print(f"  inter-paint gap   p50={pct(d,.5):7.1f}  p75={pct(d,.75):7.1f}  "
          f"p90={pct(d,.9):7.1f}  p99={pct(d,.99):7.1f}  max={max(d):8.0f} ms")
    for thr in (33, 100, 250, 1000):
        n = sum(1 for x in d if x > thr)
        tot = sum(x for x in d if x > thr) / 1000
        print(f"    gaps > {thr:5d} ms: {n:5d} ({100*n/len(d):5.1f}%)  "
              f"{tot:7.1f}s = {100*tot/span:5.1f}% of the window")

    big = [g for g in gaps if g[2] > 100]
    if not big or not keys:
        print("\n  (no long gaps, or no keystrokes, in this window -- nothing to join)")
        return 0
    starts = [g[0] for g in big]

    def gap_at(t):
        i = bisect.bisect_right(starts, t) - 1
        if i < 0:
            return None
        s, e, dur = big[i][0], big[i][1], big[i][2]
        return dur if s <= t < e else None

    inside = [ms for t, ms in keys if gap_at(t) is not None]
    outside = [ms for t, ms in keys if gap_at(t) is None]
    cover = sum(g[2] for g in big) / 1000 / span
    print(f"\n  JOIN -- keystroke queueing delay inside vs outside a >100ms paint gap")
    print(f"    gaps >100ms cover {cover*100:.0f}% of the window")
    for name, v in (("inside", inside), ("outside", outside)):
        if v:
            print(f"    {name:8s} n={len(v):5d}  p50={pct(v,.5):7.2f}  p90={pct(v,.9):7.2f}  max={max(v):8.2f} ms")
        else:
            print(f"    {name:8s} none")
    if len(inside) >= 20 and len(outside) >= 20:
        ratio50 = pct(inside, .5) / max(1e-9, pct(outside, .5))
        ratio90 = pct(inside, .9) / max(1e-9, pct(outside, .9))
        print()
        if ratio50 > 2 or ratio90 > 2:
            print("    -> CONTENDED: keys landing inside a gap wait longer. The main thread was")
            print("       busy during the gaps, so moving painting off it should help.")
        else:
            print("    -> NOT CONTENDED: keys inside a gap are as fast as outside. The main thread")
            print("       was free while nothing painted, so the gate is below the app --")
            print("       CoreAnimation commit or window-server compositing. An app-side renderer")
            print("       thread would not escape it.")
    else:
        print(f"\n    (need >=20 both sides to call it; inside={len(inside)} outside={len(outside)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
