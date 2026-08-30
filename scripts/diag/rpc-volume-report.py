#!/usr/bin/env python3
"""How much does the daemon push at the app, and what does decoding it cost?

    rpc-volume-report.py [--last 30m] [--top 12]

A `sample` of TBDApp during a confirmed terminal-lag episode (load 154, swap
97% full) found 1,265 samples inside `JSONDecoder` internals against only 81
blocked in `read`/`recv`/`poll`/`cond_wait`, spread across six
`user-initiated-qos.cooperative` threads. Those threads were not waiting on the
socket -- they were burning CPU decoding JSON. The work is off the main thread
(72 `JSONDecoder` mentions on main against 1,717 overall), so it does not block
drawing directly; the question is whether it is a load worth caring about at
all. On a 12-core box already at load 150 six CPU-burning threads compete with
the render path, and on a swap-thrashing machine the allocation churn of a
decode is page faults.

Nothing logged payload sizes, so that question had no answer. `RPCVolumeProbe`
(default off, `defaults write TBDApp enableRPCVolumeDiagnostic -bool true`)
supplies one, and this reads it back.

The headline number is DECODE SHARE: total decode milliseconds divided by the
wall time they were spread over. It is a thread-seconds ratio, not a duty
cycle -- decoding runs on several threads at once, so a share above 1.0 is not
a bug, it means more than one core-second of decode per wall second. Below
about 0.05 the sample's `JSONDecoder` frames are a sampling artifact of threads
that decode in short bursts and the lag is somewhere else. Around 1.0 or above,
JSON decoding is a standing multi-core load and the fix is upstream of the
decoder: send less, send it less often, or stop re-sending state that did not
change.

The two rankings at the bottom are the actionable part, and they are usually
NOT the same ranking. A message type can dominate bytes without dominating
decode time (a big flat blob, cheap per byte) or dominate decode time without
dominating bytes (a small deeply-nested payload, or one arriving thousands of
times a second). Bytes-heavy points at the daemon's payload shape; decode-heavy
points at frequency and nesting. Fixing the wrong one moves nothing.

`kind` separates the two receive paths because they have different fixes.
`response` is a reply to a call the app chose to make: the fix is to call less
often, or to ask for less. `delta` is pushed subscription traffic the app
cannot decline: the fix has to happen in the daemon's broadcast. `(ack)` is the
subscription handshake and should appear once per connection -- more than that
means the subscription is reconnecting.

`kind=mixed type=(other)` is the probe's own rollup of everything outside the
top eight by bytes and the top eight by decode time within a single window. It
exists so the per-type rows still sum to the window totals; a large `(other)`
share means the traffic is spread thin across many types rather than
concentrated in a few, which is itself the answer.
"""
import argparse
import re
import subprocess
import sys
from collections import defaultdict

# Every probe line is a flat key=value bag; one regex reads both shapes.
PAIR = re.compile(r"(\w+)=([^\s]+)")
LINE = re.compile(r"\brpc kind=")


def parse(line):
    if not LINE.search(line):
        return None
    body = line[LINE.search(line).start():]
    return dict(PAIR.findall(body))


def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024 or unit == "GB":
            return f"{n:,.1f} {unit}" if unit != "B" else f"{n:,.0f} B"
        n /= 1024.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--last", default="30m")
    ap.add_argument("--top", type=int, default=12,
                    help="how many message types to list in each ranking")
    args = ap.parse_args()

    out = subprocess.run(
        ["/usr/bin/log", "show", "--last", args.last, "--info", "--style", "compact",
         "--predicate", 'subsystem == "com.tbd.app" AND category == "rpcvolume"'],
        capture_output=True, text=True).stdout

    windows = []
    types = defaultdict(lambda: {"n": 0, "bytes": 0, "decodems": 0.0, "maxms": 0.0})

    for ln in out.splitlines():
        kv = parse(ln)
        if not kv:
            continue
        if kv.get("kind") == "window":
            windows.append(kv)
            continue
        key = (kv.get("kind", "?"), kv.get("type", "?"))
        t = types[key]
        t["n"] += int(kv.get("n", 0))
        t["bytes"] += int(kv.get("bytes", 0))
        t["decodems"] += float(kv.get("decodems", 0.0))
        t["maxms"] = max(t["maxms"], float(kv.get("maxms", 0.0)))

    if not windows:
        print(f"No rpcvolume lines in the last {args.last}.")
        print("The probe is default-OFF. To enable it for a measurement session:")
        print("  defaults write TBDApp enableRPCVolumeDiagnostic -bool true")
        print("  # then relaunch TBDApp -- the flag is read once per process")
        return 1

    secs = sum(float(w.get("secs", 0.0)) for w in windows)
    msgs = sum(int(w.get("msgs", 0)) for w in windows)
    total_bytes = sum(int(w.get("bytes", 0)) for w in windows)
    decode_ms = sum(float(w.get("decodems", 0.0)) for w in windows)
    max_ms = max(float(w.get("maxms", 0.0)) for w in windows)
    # Windows close lazily, on the next message after they expire. A quiet
    # stretch is therefore ONE long window, not a gap -- so summing the
    # windows' own spans is the honest denominator, not the clock elapsed.
    if secs <= 0:
        print("Windows carry no elapsed time; nothing to divide by.")
        return 1

    print(f"over {secs:.0f}s of measured traffic ({len(windows)} windows)")
    print(f"  received     = {human_bytes(total_bytes)} in {msgs:,} messages")
    print(f"  message rate = {msgs / secs:10.1f}/s")
    print(f"  byte rate    = {total_bytes / secs / 1e6:10.3f} MB/s")
    print(f"  mean message = {human_bytes(total_bytes / msgs) if msgs else 'n/a'}")

    share = decode_ms / (secs * 1000.0)
    print(f"\ndecode cost:")
    print(f"  total        = {decode_ms / 1000:10.1f} thread-seconds")
    print(f"  share        = {share:10.3f} x wall time  "
          f"({share * 100:.1f}% of one core)")
    print(f"  slowest one  = {max_ms:10.1f} ms")

    # Percentiles come from the windows, which already reduced them; averaging
    # per-window p50s is a stand-in for a true global p50 and is labelled so.
    p50s = sorted(float(w.get("p50ms", 0.0)) for w in windows)
    p90s = sorted(float(w.get("p90ms", 0.0)) for w in windows)
    if p50s:
        print(f"  per-window p50 median = {p50s[len(p50s) // 2]:.3f} ms, "
              f"p90 median = {p90s[len(p90s) // 2]:.3f} ms")

    def table(title, keyfn, fmt):
        print(f"\n{title}")
        ranked = sorted(types.items(), key=lambda kv: keyfn(kv[1]), reverse=True)
        for (kind, name), t in ranked[:args.top]:
            print(f"  {fmt(t):>22}  {t['n']:>9,} msgs  {kind:<8} {name}")

    table("by BYTES -- what the daemon is sending too much of:",
          lambda t: t["bytes"],
          lambda t: f"{human_bytes(t['bytes'])} "
                    f"({100 * t['bytes'] / total_bytes:4.1f}%)")

    table("by DECODE TIME -- what is actually costing CPU:",
          lambda t: t["decodems"],
          lambda t: f"{t['decodems'] / 1000:8.1f}s "
                    f"({100 * t['decodems'] / decode_ms:4.1f}%)" if decode_ms else "n/a")

    print()
    by_bytes = sorted(types, key=lambda k: types[k]["bytes"], reverse=True)
    by_time = sorted(types, key=lambda k: types[k]["decodems"], reverse=True)
    if by_bytes[:3] != by_time[:3]:
        print("  -> the two rankings disagree. The bytes leader is a payload-shape")
        print(f"     problem ({by_bytes[0][1]}); the decode leader is a frequency or")
        print(f"     nesting problem ({by_time[0][1]}). They need different fixes.")
    else:
        print(f"  -> both rankings agree on {by_time[0][1]}: fix that one first.")

    if share < 0.05:
        print(f"  -> decode share {share:.3f} is negligible. The `sample` frames were")
        print("     an artifact of short bursts; look elsewhere for the lag.")
    elif share >= 0.5:
        print(f"  -> decode share {share:.3f} is a standing multi-core load. The fix is")
        print("     upstream of the decoder, in what the daemon chooses to send.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
