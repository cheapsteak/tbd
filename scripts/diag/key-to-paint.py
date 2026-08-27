#!/usr/bin/env python3
"""Measure keystroke-anchored key-to-paint latency in a TBD terminal.

    key-to-paint.py --worktree <id> --label <name> [--keys 120] [--input tmux|typed]

Anchors every measurement on ONE keystroke. A shell emits several chunks per
typed character, so a bare "chunk to next display pass" counts mid-burst
fragments waiting on the *next* character's draw and reads high; that metric was
discarded once and is not re-derived here. The pane instead runs `cat` and no
newline is ever sent, so the only output is the tty line-discipline echo: one
byte in, one byte out, one pty chunk per keystroke. The script checks that 1:1
holds and refuses to report if it does not.

Two numbers, from one capture:

  key2paint   the keystroke's own pty chunk arriving at TBD (mainThreadHop
              begin) -> the next displayPass begin. This is the leg
              `queuePendingDisplay` governs. Both endpoints are TBD's own
              signposts, so it carries none of the harness's overhead.
  +spawn      the same paint, measured from before `tmux send-keys` is launched.
              A loose upper bound: on a loaded machine most of it is this
              script's own process spawn, which a user never pays.

`key2paint` is a LOWER BOUND on what a user perceives, at both ends and by
design:

  - with `--input tmux` it omits TBD's own view keydown handling, because keys are
    injected at the tmux layer and never reach the view. `--input typed` closes
    that gap: System Events posts a real key event, so `TerminalView.keyDown` runs,
    `send(data:)` fires and `recordUserInput()` opens SwiftTerm's 150 ms
    immediate-display window. THE TWO MODES MEASURE DIFFERENT CODE PATHS -- that
    is the point of having both, not an inconsistency.
  - it omits the tmux/pty transport leg, separately measured at 0.1 ms p50 on
    this machine, so the omission is small.
  - it ends at the START of the AppKit display pass, before the CoreAnimation
    commit and the window-server composite.

None of those legs is touched by a change to display scheduling, so a
before/after comparison is unaffected by leaving them out.

Gaps between keys are randomised, from a fixed seed so both sides of a
comparison get the identical cadence: a fixed cadence can alias against a
fixed-interval frame timer and manufacture a bimodal result.
"""
import argparse, json, os, random, re, subprocess, sys, time
from collections import defaultdict

SCRATCH = os.environ.get("TMPDIR", "/tmp")


def seconds_of_day(unix_ts):
    """Local seconds-of-day, matching how `log` renders its timestamps."""
    lt = time.localtime(unix_ts)
    return lt.tm_hour * 3600 + lt.tm_min * 60 + lt.tm_sec + (unix_ts - int(unix_ts))


def parse_capture(path):
    """{name: [(begin_seconds_of_day, message), ...]} for signpost begins, sorted."""
    begins = defaultdict(list)
    for line in open(path, errors="replace"):
        line = line.strip().rstrip(",")
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("signpostType") != "begin":
            continue
        name = event.get("signpostName")
        stamp = re.search(r"(\d{2}):(\d{2}):(\d{2})\.(\d+)", event.get("timestamp", ""))
        if not name or not stamp:
            continue
        frac = (stamp.group(4) + "000000000")[:9]
        begins[name].append((int(stamp.group(1)) * 3600 + int(stamp.group(2)) * 60
                             + int(stamp.group(3)) + int(frac) / 1e9,
                             event.get("eventMessage", "")))
    for v in begins.values():
        v.sort()
    return begins


def parse_intervals(path):
    """{name: [(start, end, begin_message)]} -- durations, not just begins."""
    open_iv, out = {}, defaultdict(list)
    for line in open(path, errors="replace"):
        line = line.strip().rstrip(",")
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        name, sid = event.get("signpostName"), event.get("signpostID")
        stamp = re.search(r"(\d{2}):(\d{2}):(\d{2})\.(\d+)", event.get("timestamp", ""))
        if not name or not stamp or sid is None:
            continue
        frac = (stamp.group(4) + "000000000")[:9]
        t = (int(stamp.group(1)) * 3600 + int(stamp.group(2)) * 60
             + int(stamp.group(3)) + int(frac) / 1e9)
        key = (sid, name)
        if event.get("signpostType") == "begin":
            open_iv[key] = (t, event.get("eventMessage", ""))
        elif event.get("signpostType") == "end" and key in open_iv:
            s, msg = open_iv.pop(key)
            out[name].append((s, t, msg))
    for v in out.values():
        v.sort()
    return out


def tbd_activity():
    """(isActive, hasKeyWindow) from TBD's own lifecycle heartbeat, or None.

    A machine interface, not screen text: TBDApp logs `active=` and `keyWindow=`
    every 5 seconds. Both must be true for the whole run — a display pass only
    happens while the view is on screen, and a driven keystroke can only be
    delivered to a key window. Checking first turns a 40-second capture that
    yields an empty table into a one-second abort with a reason.
    """
    out = subprocess.run(
        ["/usr/bin/log", "show", "--last", "20s", "--level", "info", "--predicate",
         'subsystem == "com.tbd.app" AND category == "lifecycle"'],
        capture_output=True, text=True).stdout
    last = [ln for ln in out.splitlines() if "heartbeat" in ln]
    if not last:
        return None
    m = re.search(r"active=(\w+) keyWindow=(\w+)", last[-1])
    if not m:
        return None
    return (m.group(1) == "true", m.group(2) == "true")


def first_at_or_after(sorted_times, t, horizon):
    for x in sorted_times:
        if x >= t:
            return x if x - t <= horizon else None
    return None


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))]


def summarize(label, values, unit_note=""):
    if not values:
        print(f"  {label:11s} none")
        return
    over = sum(1 for v in values if v > 100) / len(values) * 100
    print(f"  {label:11s} n={len(values):4d}  p50={pct(values,.5):7.1f}  p90={pct(values,.9):7.1f}  "
          f"p99={pct(values,.99):7.1f}  max={max(values):7.1f} ms   >100ms={over:5.1f}%{unit_note}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--keys", type=int, default=120)
    ap.add_argument("--min-gap", type=float, default=0.12)
    ap.add_argument("--max-gap", type=float, default=0.26)
    ap.add_argument("--out", default=os.path.join(SCRATCH, "tbd-k2p"))
    ap.add_argument("--terminal", default="", help="reuse an existing terminal id")
    ap.add_argument("--seed", type=int, default=741)
    ap.add_argument("--settle", type=float, default=6.0)
    ap.add_argument("--input", choices=("tmux", "typed", "driven"), default="tmux",
                    help="tmux: inject at the tmux layer (never touches the view). "
                         "typed: post a real key event via System Events (needs an "
                         "Accessibility grant osascript does not have on this machine). "
                         "driven: have TypedInputDriver inside the app call "
                         "TerminalView.send(txt:) on the first responder -- the same "
                         "call keyDown ends in, so recordUserInput() fires.")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    random.seed(args.seed)  # identical key cadence on every run, before and after

    sock = ""
    if os.environ.get("TMUX"):
        sock = os.path.basename(os.environ["TMUX"].split(",")[0])
    if not sock:
        sys.exit("must run inside a TBD terminal ($TMUX unset) to find the tmux socket")

    term = args.terminal
    created = False
    if not term:
        out = subprocess.run(["tbd", "terminal", "create", args.worktree, "--type", "shell",
                              "--json", "--cmd", "cat"],
                             capture_output=True, text=True, check=True).stdout
        term = json.loads(out)["id"]
        created = True
    listing = subprocess.run(["tbd", "terminal", "list", args.worktree],
                             capture_output=True, text=True, check=True).stdout
    pane = ""
    for line in listing.splitlines():
        f = line.split()
        if f and f[0] == term:
            pane = f[2]
    if not pane:
        sys.exit(f"could not find pane for terminal {term}")
    print(f"==> terminal={term} pane={pane} socket={sock} (created={created})")

    subprocess.run(["tbd", "terminal", "focus", "--terminal", term, "--activate"],
                   capture_output=True, check=True)

    # Wait for `cat` to actually own the pane, on a machine interface rather than
    # a fixed sleep or screen text. Under load a fixed sleep types into a pane
    # whose process has not started, the keys are swallowed, and the run reports
    # a plausible-looking latency computed from somebody else's chunks.
    for _ in range(90):
        cur = subprocess.run(["tmux", "-L", sock, "display", "-p", "-t", pane,
                              "#{pane_current_command}"],
                             capture_output=True, text=True).stdout.strip()
        if cur == "cat":
            break
        time.sleep(1)
    else:
        sys.exit("`cat` never took over the pane -- aborting rather than measuring nothing")
    time.sleep(args.settle)

    act = tbd_activity()
    if act is not None and not (act[0] and act[1]):
        print(f"*** ABORT: TBD reports active={act[0]} keyWindow={act[1]} after being focused.")
        print("*** Nothing can be measured -- an off-screen view emits no display pass, and a")
        print("*** driven keystroke needs a key window. Something is taking focus back; retry")
        print("*** when TBD can hold the foreground for the length of a run.")
        if created:
            subprocess.run(["tbd", "terminal", "close", "--terminal", term], capture_output=True)
        return 2

    capture = os.path.join(args.out, f"{args.label}.ndjson")
    # Signposts are read back from the persisted store with `log show`, not taken
    # live with `log stream`. The live stream silently stopped delivering this
    # subsystem partway through this investigation -- an unfiltered `log stream
    # --signpost` produced 5.2 MB in five seconds with not one com.tbd.app line
    # in it, while `log show` returned thousands of com.tbd.app signposts over
    # the same minutes. A capture that comes back empty is indistinguishable from
    # a terminal that never drew, so the failure mode was a run that looked
    # merely void. `log show` also cannot drop events under volume or lose a
    # buffered tail when the stream is killed.
    #
    # A `log stream` IS still started, but only as an ENABLER and its output is
    # discarded. Signpost emission is gated on a live listener: emission stopped
    # dead the moment no stream was running, so a capture taken purely with
    # `log show` reads back an empty window from an app that was working fine.
    # That failure is indistinguishable from a terminal that never drew, which is
    # exactly the shape of instrument error this investigation keeps producing.
    enabler = subprocess.Popen(
        ["/usr/bin/log", "stream", "--signpost", "--predicate", 'subsystem == "com.tbd.app"'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t_capture_start = time.time()
    time.sleep(2.0)

    # Idle control: nothing is typed, so a busy displayPass count here means some
    # OTHER visible terminal is drawing and would contaminate every measurement.
    idle_start = seconds_of_day(time.time())
    time.sleep(4.0)
    idle_end = seconds_of_day(time.time())

    load = os.getloadavg()
    print(f"==> load average at start: {load[0]:.2f} {load[1]:.2f} {load[2]:.2f}")
    print(f"==> sending {args.keys} keys")
    # A synthetic keystroke goes to whatever is frontmost, so it could land in
    # another agent's composer. The frontmost check is fused into the same
    # osascript call as the keystroke rather than done separately, so nothing can
    # steal focus in between, and the run aborts rather than typing blind.
    TYPE_SCRIPT = '''tell application "System Events"
        if (name of first application process whose frontmost is true) is not "TBDApp" then
            error "TBD is not frontmost"
        end if
        keystroke "%s"
    end tell'''

    if args.input == "driven":
        # Re-focus right before triggering. The pre-roll above (settle, signpost
        # enabler, idle control) is long enough that TBD has usually lost the
        # foreground again by now, and the driver can only deliver to a key window.
        subprocess.run(["tbd", "terminal", "focus", "--terminal", term, "--activate"],
                       capture_output=True)
        time.sleep(1.0)
        trigger = os.path.expanduser("~/tbd/runtime/typed-drive.json")
        os.makedirs(os.path.dirname(trigger), exist_ok=True)
        with open(trigger, "w") as f:
            json.dump({"count": args.keys, "minGap": args.min_gap,
                       "maxGap": args.max_gap, "seed": args.seed,
                       "terminalID": term}, f)
        expected = args.keys * (args.min_gap + args.max_gap) / 2
        print(f"==> triggered in-app driver for {args.keys} keys (~{expected:.0f}s)")
        time.sleep(expected + 6)
        launches, spawn_costs = [], [0.0]
    else:
        launches, spawn_costs = [], []
    for i in range(0 if args.input == "driven" else args.keys):
        ch = "abcdefghijklmnopqrstuvwxyz"[i % 26]
        t0 = time.time()
        if args.input == "typed":
            r = subprocess.run(["osascript", "-e", TYPE_SCRIPT % ch],
                               capture_output=True, text=True)
            if r.returncode != 0:
                print(f"\n*** ABORTED at key {i}: {r.stderr.strip()}")
                print("*** No further keys sent. Bring the measurement tab to the front and re-run.")
                return 1
        else:
            subprocess.run(["tmux", "-L", sock, "send-keys", "-t", pane, "-l", ch],
                           capture_output=True)
        t1 = time.time()
        launches.append(seconds_of_day(t0))
        spawn_costs.append((t1 - t0) * 1000)
        time.sleep(random.uniform(args.min_gap, args.max_gap))

    load_end = os.getloadavg()
    time.sleep(1.5)
    t_capture_end = time.time() + 1.0
    time.sleep(1.5)
    enabler.terminate()
    enabler.wait()
    fmt = "%Y-%m-%d %H:%M:%S"
    subprocess.run(
        ["/usr/bin/log", "show", "--style", "ndjson", "--signpost",
         "--start", time.strftime(fmt, time.localtime(t_capture_start - 1)),
         "--end", time.strftime(fmt, time.localtime(t_capture_end + 1)),
         "--predicate", 'subsystem == "com.tbd.app"'],
        stdout=open(capture, "w"), stderr=subprocess.DEVNULL)
    if created:
        subprocess.run(["tbd", "terminal", "close", "--terminal", term],
                       capture_output=True)

    begins = parse_capture(capture)
    passes = [t_ for t_, _ in begins.get("displayPass", [])]
    all_hops = begins.get("mainThreadHop", [])
    # TBD feeds terminals that are not on screen, so their chunks appear in this
    # process-wide capture while producing no display pass at all (verified: a
    # 10 s idle capture showed 90 chunk arrivals and zero display passes). Those
    # chunks cannot serve a keystroke's paint, but they do break a naive
    # "next chunk after the key" match. The pane under test runs `cat` with no
    # newline ever sent, so its echo is always exactly one byte -- which
    # identifies it without any view identity in the signpost.
    hops = [t_ for t_, msg in all_hops if msg == "bytes=1"]
    foreign = [t_ for t_, msg in all_hops if msg != "bytes=1"]
    idle_passes = sum(1 for p in passes if idle_start <= p < idle_end)
    idle_foreign = sum(1 for f in foreign if idle_start <= f < idle_end)

    print(f"\n=== {args.label} ===")
    print(f"  load: start {load[0]:.2f} {load[1]:.2f} {load[2]:.2f} | "
          f"end {load_end[0]:.2f} {load_end[1]:.2f} {load_end[2]:.2f}")
    print(f"  displayPass begins: {len(passes)}   echo chunks (1 byte): {len(hops)}   "
          f"off-screen chunks (other sizes): {len(foreign)}")
    print(f"  idle control (4.0s, no keys sent): {idle_passes} displayPass, {idle_foreign} off-screen chunks "
          f"({'quiet -- no other view is DRAWING' if idle_passes <= 8 else 'BUSY -- another view is drawing, results contaminated'})")
    if len(passes) < 20:
        print("\n*** VOID: fewer than 20 displayPass begins -- the tab was not drawing.")
        print("*** Do not report these numbers.")
        return 1

    # Pair each keystroke with its own echo chunk. The search starts at the
    # instant `tmux send-keys` was LAUNCHED, which is necessarily before the byte
    # reaches the pty, so the first arrival at or after it is this keystroke's.
    # (Anchoring on when send-keys RETURNED does not work: the echo reaches TBD
    # while the tmux client is still tearing down, so the search would skip to
    # the *next* keystroke's chunk and report an inter-key gap as latency.)
    if args.input == "driven":
        # No per-key send timestamp exists -- the keystrokes originate inside the
        # app. The echo chunks ARE the keystrokes, one byte each, so they anchor
        # directly and the transport leg is not in the number at all.
        k2p, spawn_k2p, dropped = [], [], 0
        for h in hops:
            paint = first_at_or_after(passes, h, 2.0)
            if paint is None:
                dropped += 1
                continue
            k2p.append((paint - h) * 1000)
        launches = hops or [0.0]
        spawn_k2p = list(k2p)
    else:
        k2p, spawn_k2p, dropped = [], [], 0
    for t_launch in (launches if args.input != "driven" else []):
        hop = first_at_or_after(hops, t_launch, 2.0)
        if hop is None:
            dropped += 1
            continue
        paint = first_at_or_after(passes, hop, 2.0)
        if paint is None:
            dropped += 1
            continue
        k2p.append((paint - hop) * 1000)
        spawn_k2p.append((paint - t_launch) * 1000)

    run_lo, run_hi = launches[0], launches[-1] + 1.0
    hops_in_run = sum(1 for h in hops if run_lo <= h < run_hi)
    ratio = hops_in_run / len(launches)
    passes_in_run = sum(1 for x in passes if run_lo <= x < run_hi)
    draw_cover = passes_in_run / len(launches)
    # A ceiling as well as a floor. Fewer draws than keys means the tab left the
    # screen; MORE means some other view is also drawing, and then "the next
    # display pass after my chunk" can be that other view's draw rather than the
    # one showing this keystroke -- which UNDERSTATES latency, the direction a
    # result is most likely to be believed.
    ok = 0.9 <= ratio <= 1.15 and 0.95 <= draw_cover <= 1.35
    print(f"  keys sent={len(launches)} matched={len(k2p)} dropped={dropped}")
    print(f"  echo chunks per keystroke = {ratio:.2f}  "
          f"({'1:1 -- each key is anchored on its own echo' if 0.9 <= ratio <= 1.15 else 'NOT 1:1 -- keys were lost, do not report'})")
    print(f"  display passes per keystroke = {draw_cover:.2f}  "
          f"({'every key got a draw, and only this view drew' if 0.95 <= draw_cover <= 1.35 else ('FEWER DRAWS THAN KEYS -- the tab went off screen mid-run, do not report' if draw_cover < 0.95 else 'MORE DRAWS THAN KEYS -- another view is drawing too, latency would be understated, do not report')})")
    print(f"  harness `tmux send-keys` spawn cost (excluded from key2paint): "
          f"p50={pct(spawn_costs,.5):.1f} p90={pct(spawn_costs,.9):.1f} ms")
    print()
    summarize("key2paint", k2p)
    summarize("+spawn", spawn_k2p, "  <- upper bound: harness spawn cost left in")

    # `feed` wraps TerminalView.feed(byteArray:), which runs on the main thread and
    # calls feedFinish() -> queuePendingDisplay() or displayImmediately(). On the
    # typed path displayImmediately() takes its Thread.isMainThread branch and
    # updates the display SYNCHRONOUSLY, so that whole update lands INSIDE this
    # interval. On the tmux path the update is deferred and does not. Comparing the
    # two therefore separates "the fast path does too much" from "the throttle waits
    # too long" directly, on the same binary and the same machine state.
    ivs = parse_intervals(capture)
    echo_feeds = [(e - s) * 1000 for s, e, msg in ivs.get("feed", [])
                  if msg == "bytes=1" and run_lo <= s < run_hi]
    print()
    summarize("feed(1B)", echo_feeds, "  <- per-keystroke work on the main thread")
    if not ok or idle_passes > 8:
        print("\n*** VOID: the guards above did not pass. Do not report these numbers.")
        return 1
    print(f"\n  capture: {capture}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
