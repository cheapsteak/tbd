#!/usr/bin/env python3
"""Report main-thread queueing delay for REAL typed keystrokes.

    key-queue-report.py [--last 30m] [--bucket 60]

Reads the `keyqueue` lines the temporary key-latency monitor emits (see
`TypedInputDriver.installKeyLatencyMonitor`). Each line is one keystroke a human
actually typed: the gap between the window server stamping the event and TBD's
main thread getting to it.

Nothing here is synthetic, so it needs no Accessibility grant, and unlike every
other keystroke figure in this investigation it is of the path a typed key really
takes -- `keyDown`, and therefore `send(data:)` and `recordUserInput()`.

The per-bucket view is the point. Key-to-paint has only ever been measured as a
total, in which a paint-scheduling floor and a synchronous per-chunk cost look
identical. They are separable here: if the cost is `displayImmediately()` doing a
full synchronous `updateDisplay` per chunk, queueing delay climbs while an agent
streams and falls when it stops. A fixed floor stays flat.

Only keystrokes whose first responder is a terminal view are counted by default;
typing into a text field is a different code path and does not reach send(data:).
"""
import argparse, re, subprocess, sys
from collections import defaultdict

LINE = re.compile(r"(\d{2}):(\d{2}):(\d{2})\.(\d+).*keyqueue ms=([0-9.]+)(?: chunks1s=(\d+))? responder=(\S+)")


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * q))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--last", default="30m")
    ap.add_argument("--bucket", type=int, default=60, help="seconds per reported bucket")
    ap.add_argument("--all-responders", action="store_true",
                    help="include keystrokes that did not go to a terminal view")
    args = ap.parse_args()

    out = subprocess.run(
        ["/usr/bin/log", "show", "--last", args.last, "--info", "--style", "compact",
         "--predicate", 'subsystem == "com.tbd.app" AND category == "keylatency"'],
        capture_output=True, text=True).stdout

    rows = []
    skipped = 0
    for line in out.splitlines():
        m = LINE.search(line)
        if not m:
            continue
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        ms = float(m.group(5))
        chunks = int(m.group(6)) if m.group(6) else None
        responder = m.group(7)
        if not args.all_responders and "TerminalView" not in responder:
            skipped += 1
            continue
        rows.append((t, ms, responder, chunks))

    if not rows:
        print(f"No keyqueue samples in the last {args.last}.")
        print("Either nobody typed into a TBD terminal in that window, or the build")
        print("running does not carry the monitor. Check:")
        print("  strings /Applications/TBD.app/Contents/MacOS/TBDApp | grep -c keyqueue")
        if skipped:
            print(f"({skipped} samples were dropped as non-terminal responders; "
                  f"re-run with --all-responders to see them.)")
        return 1

    vals = [r[1] for r in rows]
    print(f"real typed keystrokes: n={len(vals)}   window={args.last}"
          + (f"   ({skipped} non-terminal keystrokes excluded)" if skipped else ""))
    print(f"  main-thread queueing delay   p50={pct(vals,.5):7.2f}  p90={pct(vals,.9):7.2f}  "
          f"p99={pct(vals,.99):7.2f}  max={max(vals):8.2f} ms   "
          f">100ms={sum(1 for v in vals if v > 100)/len(vals)*100:.1f}%")

    responders = defaultdict(int)
    for _, _, r, _c in rows:
        responders[r] += 1
    print("  responders: " + ", ".join(f"{k}={v}" for k, v in
                                       sorted(responders.items(), key=lambda x: -x[1])[:4]))

    # Chunk rate is the variable in the hypothesis, so bucket by it directly.
    # A p50 that climbs with output rate is the "displayImmediately() does a full
    # synchronous updateDisplay per chunk" signature; a flat one across rates
    # means the cost is not per-chunk work, whatever else it may be.
    rated = [r for r in rows if r[3] is not None]
    if rated:
        edges = [(0, 0), (1, 5), (6, 20), (21, 50), (51, 200), (201, 10 ** 9)]
        print("\n  by terminal output rate at the moment the key was typed:")
        print("    chunks/s      n     p50      p90      max")
        for lo, hi in edges:
            v = [r[1] for r in rated if lo <= r[3] <= hi]
            if not v:
                continue
            label = f"{lo}" if lo == hi else (f"{lo}-{hi}" if hi < 10 ** 9 else f"{lo}+")
            print(f"    {label:>9s}  {len(v):5d}  {pct(v,.5):7.2f}  {pct(v,.9):7.2f}  {max(v):7.2f} ms")
        idle = [r[1] for r in rated if r[3] == 0]
        busy = [r[1] for r in rated if r[3] >= 21]
        if len(idle) >= 20 and len(busy) >= 20:
            print(f"\n    idle p50={pct(idle,.5):.2f} ms vs busy(>=21 chunks/s) p50={pct(busy,.5):.2f} ms"
                  f"  -> {'RISES with output rate: per-chunk work' if pct(busy,.5) > pct(idle,.5) * 1.5 else 'FLAT across output rate: not per-chunk work'}")
        else:
            print(f"\n    (need >=20 samples in both the idle and busy bands to call it; "
                  f"have idle={len(idle)} busy={len(busy)})")
    else:
        print("\n  (no chunks1s labels -- samples predate the output-rate instrument)")

    buckets = defaultdict(list)
    t0 = rows[0][0]
    for t, ms, _, _c in rows:
        buckets[(t - t0) // args.bucket].append(ms)
    print(f"\n  per-{args.bucket}s buckets:")
    for b in sorted(buckets):
        v = buckets[b]
        print(f"    t+{b*args.bucket:5d}s  n={len(v):4d}  p50={pct(v,.5):7.2f}  "
              f"p90={pct(v,.9):7.2f}  max={max(v):8.2f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
