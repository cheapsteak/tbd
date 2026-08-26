#!/usr/bin/env python3
"""Check that high-rate terminal output is still coalesced into few display passes.

    burst-coalescing.py --worktree <id> --label <name> [--seconds 15]

The throttle in `queuePendingDisplay` exists to stop a saturated output path from
drawing once per pty chunk. Any change to it has to be shown NOT to have broken
that, so this measures the ratio that matters:

    displayPass rate / mainThreadHop rate   (draws per arriving chunk)

Well below 1 means chunks are being collapsed into shared draws. Approaching 1
means every chunk now draws -- coalescing is gone, which is worse than the
scheduling delay it was traded for. A 60 Hz cap also puts a hard ceiling of
roughly 60 draws/s on the display pass rate however fast chunks arrive.

The load is `yes`-style line append while scrolling: the documented
worst case for this renderer (parse plus damage tracking saturates the main
thread), and the exact path the throttle protects.
"""
import argparse, json, os, re, subprocess, sys, time
from collections import defaultdict



def parse(path):
    ivals, open_iv = defaultdict(list), {}
    for line in open(path, errors="replace"):
        line = line.strip().rstrip(",")
        if not line.startswith("{"):
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        name, sid = e.get("signpostName"), e.get("signpostID")
        m = re.search(r"(\d{2}):(\d{2}):(\d{2})\.(\d+)", e.get("timestamp", ""))
        if not name or not m or sid is None:
            continue
        frac = (m.group(4) + "000000000")[:9]
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(frac) / 1e9
        key = (sid, name)
        if e.get("signpostType") == "begin":
            open_iv[key] = t
        elif e.get("signpostType") == "end" and key in open_iv:
            ivals[name].append((open_iv.pop(key), t))
    for v in ivals.values():
        v.sort()
    return ivals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--seconds", type=float, default=15.0)
    ap.add_argument("--out", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "tbd-k2p"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    sock = os.path.basename(os.environ["TMUX"].split(",")[0]) if os.environ.get("TMUX") else ""
    if not sock:
        sys.exit("must run inside a TBD terminal ($TMUX unset)")

    out = subprocess.run(["tbd", "terminal", "create", args.worktree, "--type", "shell", "--json"],
                         capture_output=True, text=True, check=True).stdout
    term = json.loads(out)["id"]
    pane = ""
    for line in subprocess.run(["tbd", "terminal", "list", args.worktree],
                               capture_output=True, text=True, check=True).stdout.splitlines():
        f = line.split()
        if f and f[0] == term:
            pane = f[2]
    print(f"==> terminal={term} pane={pane}")
    subprocess.run(["tbd", "terminal", "focus", "--terminal", term, "--activate"],
                   capture_output=True, check=True)

    # Wait for the shell to be ready on a machine interface, not a fixed sleep and
    # not screen text: tmux reports the pane's foreground command. Under load a
    # fixed sleep types the load command before the prompt exists, which loses it
    # entirely and yields a capture of an idle terminal that looks normal.
    for _ in range(60):
        cur = subprocess.run(["tmux", "-L", sock, "display", "-p", "-t", pane,
                              "#{pane_current_command}"],
                             capture_output=True, text=True).stdout.strip()
        if cur in ("zsh", "bash", "sh", "fish"):
            break
        time.sleep(1)
    else:
        sys.exit("shell never became ready in the pane")
    time.sleep(5)

    capture = os.path.join(args.out, f"{args.label}.ndjson")
    log = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--signpost",
                            "--predicate", 'subsystem == "com.tbd.app"'],
                           stdout=open(capture, "w"), stderr=subprocess.DEVNULL)
    time.sleep(2)

    # Idle control: nothing has been started yet, so a display pass here belongs
    # to some OTHER visible terminal and would inflate the draw counts below.
    idle_t0 = time.time()
    time.sleep(4)
    idle_span = (idle_t0, time.time())
    load = os.getloadavg()
    # Line append while scrolling, the renderer's documented worst case. Bounded
    # by a line count rather than `timeout`, which is GNU coreutils and is not on
    # a stock macOS -- a missing binary makes the shell print one error line and
    # the run measures an idle terminal while looking entirely normal.
    subprocess.run(["tmux", "-L", sock, "send-keys", "-t", pane, "-l",
                    "yes 'the quick brown fox jumps over the lazy dog 0123456789' "
                    f"| head -n {int(args.seconds) * 40000}"],
                   capture_output=True)
    subprocess.run(["tmux", "-L", sock, "send-keys", "-t", pane, "Enter"], capture_output=True)
    t_start = time.time()
    time.sleep(args.seconds + 2)
    log.terminate(); log.wait()
    subprocess.run(["tbd", "terminal", "close", "--terminal", term], capture_output=True)

    iv = parse(capture)
    def sod(u):
        lt = time.localtime(u)
        return lt.tm_hour*3600 + lt.tm_min*60 + lt.tm_sec + (u - int(u))
    ilo, ihi = sod(idle_span[0]), sod(idle_span[1])
    idle_passes = sum(1 for s, _ in iv.get("displayPass", []) if ilo <= s < ihi)
    hops, passes, feeds = iv.get("mainThreadHop", []), iv.get("displayPass", []), iv.get("feed", [])
    if not hops or not passes:
        print(f"\n*** VOID: hops={len(hops)} passes={len(passes)} -- nothing to measure.")
        return 1
    # Densest contiguous `seconds`-wide window of chunk arrivals: the load period.
    t0 = hops[0][0]
    per_sec = defaultdict(int)
    for s, _ in hops:
        per_sec[int(s - t0)] += 1
    span = int(args.seconds)
    last = max(per_sec)
    best = max(range(0, max(1, last - span + 1)), key=lambda b: sum(per_sec.get(s, 0) for s in range(b, b + span)))
    lo, hi = t0 + best, t0 + best + span

    def window(name):
        return [(s, e) for s, e in iv.get(name, []) if lo <= s < hi]
    h, p, f = window("mainThreadHop"), window("displayPass"), window("feed")
    if len(h) / span < 50:
        print(f"\n*** VOID: only {len(h)/span:.1f} chunk arrivals/s -- the load never ran "
              f"(a missing binary or an unready shell looks exactly like this).")
        print("*** Do not report these numbers.")
        return 1
    if idle_passes > 8:
        print(f"\n*** VOID: idle control saw {idle_passes} display passes before the load started "
              f"-- another visible terminal is drawing and inflates every count here.")
        return 1
    print(f"\n=== {args.label} | load {load[0]:.2f} {load[1]:.2f} {load[2]:.2f} | window {span}s ===")
    print(f"  idle control (4s, before the load): {idle_passes} displayPass -- no other view drawing")
    print(f"  chunk arrivals (mainThreadHop) = {len(h)/span:6.1f}/s   n={len(h)}")
    print(f"  display passes                 = {len(p)/span:6.1f}/s   n={len(p)}")
    print(f"  draws per arriving chunk       = {len(p)/max(1,len(h)):6.3f}"
          f"   ({'COALESCING PRESERVED' if len(p)/max(1,len(h)) < 0.6 else 'WARNING: approaching one draw per chunk'})")
    print(f"  feed work per wall-second      = {sum(e-s for s,e in f)/span:6.2f} s/s")
    print(f"  displayPass p50                = {sorted((e-s)*1000 for s,e in p)[len(p)//2]:6.2f} ms")
    print(f"\n  capture: {capture}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
