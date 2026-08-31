#!/usr/bin/env python3
"""Is tmux lag caused by the machine, or by how many panes share one tmux server?

    tmux-server-contention.py --busy-socket /tmp/tmux-$(id -u)/<name> [--samples 40] [--interval 0.4]

WHY THIS EXISTS

Typing through tmux is laggy in TBD's panel AND in an external emulator attached
to the same server, while the same emulator with no tmux in the path is fast.
That rules out both renderers and leaves the tmux layer. But "the tmux layer" has
two very different faults inside it, and they call for opposite responses:

  MACHINE   The box is oversubscribed (load 40+, fseventsd and kernel_task eating
            cores). Every process waits in the run queue on every wakeup. tmux
            feels worse than a raw pty only because it adds process hops, each
            paying that wait. No TBD change fixes this.

  SERVER    A tmux server is ONE single-threaded event loop, and TBD gives a whole
            repo one server -- currently 60 and 78 panes on two of them. Every
            pane's output is parsed by that one thread, so a keystroke is queued
            behind however much output the other 77 panes just produced. This is
            head-of-line blocking, TBD creates it by sharding per repo, and TBD
            can fix it by sharding finer.

METHOD CAVEAT

Every sample here shells out to `tmux send-keys`, so each measurement pays a
fork+exec of a tmux client on top of whatever tmux itself does. The sibling
script, tmux-vs-rawpty-idle.py, measured that fork+exec cost in isolation --
5.1 ms p50 / 58.9 ms p90 on this machine -- and deliberately avoids it by
driving a real attached client instead of spawning one per keystroke. The
absolute numbers this script reports are dominated by fork+exec, not tmux,
and are NOT comparable to the pty-driven numbers from that sibling script.

Both arms pay the identical fork+exec tax, so a LARGE difference between BUSY
and SOLO still shows through it -- that is what makes this script usable at
all. But the noise that tax adds is tens of milliseconds wide, so this script
cannot rule out a difference of a few milliseconds between a busy and a solo
server; it can only see a difference large enough to clear that floor. A null
result here means "no difference at this resolution," not "no difference."
Reach for tmux-vs-rawpty-idle.py's fork-avoiding method when the question is
whether a small difference exists.

THE DISCRIMINATOR

Run the identical round-trip against two servers, alternating BUSY and SOLO
`interval / 2` apart (200 ms by default) so both arms of a pair see the same
few hundred milliseconds of system load, differing only in how many panes
the server thread is juggling:

  arm BUSY  a scratch pane on the live shared server (dozens of panes)
  arm SOLO  a scratch pane on a private server this script mints (one pane)

  both arms slow, and close together  -> MACHINE. Sharding buys nothing.
  BUSY slow, SOLO fast                -> SERVER. Pane count per server is the
                                         cause and sharding is the fix.

Each sample yields two timestamps, which split the path further:

  echo1  the pty line discipline echoes the token in the KERNEL before any
         process reads it: tmux server -> pty master -> back. Starving a
         userspace process cannot delay this, so echo1 is the tmux server's own
         responsiveness.
  echo2  `cat` then reads the line and writes it back -- echo1's path plus one
         process wakeup, so (echo2 - echo1) is scheduling latency.

MEASUREMENT HYGIENE. Keystrokes go only to panes this script created. It never
sends to a live agent session, and the captures hold only its own tokens -- no
agent output is recorded. Load average rides along on every sample because it
has dominated every other effect in this investigation.

RECLAMATION. Both scratch sessions are durable external resources no sweep
covers, so this script owns their whole life and kills them on every exit path,
including Ctrl-C.
"""
import argparse, os, shutil, subprocess, sys, time

SCRATCH = os.environ.get("TMPDIR", "/tmp").rstrip("/")
STAMPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_rtt_stamp.py")
SOLO_LABEL = "tbd-contention-solo"
SESSION = "tbd-contention"


def resolve_tmux():
    """Find the tmux binary: TMUX_BIN env var, then PATH, then the common
    Homebrew-on-Apple-Silicon path as a last resort. A hardcoded absolute path
    breaks on Intel Macs, MacPorts, and Linux, so this is the only place that
    guesses -- everything else uses the result.
    """
    for candidate in (os.environ.get("TMUX_BIN"), shutil.which("tmux"),
                       "/opt/homebrew/bin/tmux"):
        if candidate and os.path.exists(candidate):
            return candidate
    print("no tmux binary found: set TMUX_BIN or install tmux on PATH", file=sys.stderr)
    sys.exit(1)


TMUX_BIN = resolve_tmux()


def tmux(sock, *args, check=True):
    r = subprocess.run([TMUX_BIN, "-S", sock, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"tmux {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def pane_count(sock):
    r = subprocess.run([TMUX_BIN, "-S", sock, "list-panes", "-a"],
                       capture_output=True, text=True)
    return len(r.stdout.splitlines()) if r.returncode == 0 else 0


def arm_up(sock, tag):
    """Mint a scratch pane running `cat` and tee its output through the stamper.

    `cat` needs no rc file, so nothing in the user's shell config can perturb the
    timing or leak surprise output into the capture.
    """
    cap = f"{SCRATCH}/contention-{tag}.txt"
    open(cap, "w").close()
    subprocess.run([TMUX_BIN, "-S", sock, "kill-session", "-t", f"={SESSION}"],
                   capture_output=True)
    tmux(sock, "new-session", "-d", "-s", SESSION, "-c", "/tmp", "cat")
    pane = tmux(sock, "list-panes", "-t", f"={SESSION}", "-F", "#{pane_id}")
    tmux(sock, "pipe-pane", "-o", "-t", pane, f"/usr/bin/python3 {STAMPER} {cap}")
    return pane, cap


def arm_down(sock):
    subprocess.run([TMUX_BIN, "-S", sock, "kill-session", "-t", f"={SESSION}"],
                   capture_output=True)


def pct(xs, p):
    if not xs:
        return float("nan")
    s = sorted(xs)
    return s[min(len(s) - 1, int(len(s) * p / 100))]


def parse(cap, sends):
    """Recover echo1/echo2 for each token from the stamped capture."""
    hits = {}
    for ln in open(cap, errors="replace"):
        ts, _, payload = ln.partition(" ")
        try:
            t = float(ts)
        except ValueError:
            continue
        for tok in sends:
            if tok in payload:
                hits.setdefault(tok, []).append(t)
    e1, e2 = [], []
    for tok, t0 in sends.items():
        h = sorted(x for x in hits.get(tok, []) if x >= t0)
        if not h:
            continue
        e1.append((h[0] - t0) * 1000)
        if len(h) > 1:
            e2.append((h[1] - h[0]) * 1000)
    return e1, e2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--busy-socket", required=True,
                    help="path to the live tmux server socket to test, e.g. "
                         f"/tmp/tmux-{os.getuid()}/<name>. TBD names its "
                         "per-repo socket from a worktree-derived hash, so "
                         "there's no portable default -- list "
                         f"/tmp/tmux-{os.getuid()}/ or check `tmux -L "
                         "<name> list-sessions` to find the one you want.")
    ap.add_argument("--samples", type=int, default=40)
    ap.add_argument("--interval", type=float, default=0.4)
    a = ap.parse_args()

    if not os.path.exists(a.busy_socket):
        print(f"no such tmux socket: {a.busy_socket}")
        return 1

    solo_sock = f"{SCRATCH}/{SOLO_LABEL}"
    busy_panes = pane_count(a.busy_socket)
    print(f"BUSY {a.busy_socket}  panes={busy_panes}")
    print(f"SOLO {solo_sock}  panes=1 (minted here)")
    print(f"{a.samples} interleaved samples, {a.interval}s apart\n")

    # Every scratch session gets torn down on every exit path, including a
    # failure partway through setup. Record intent to tear down a socket
    # *before* arming it, not after arm_up returns -- arm_down/kill-server
    # against a socket that never got a session is a harmless no-op, but
    # skipping cleanup because arm_up raised partway through is how the busy
    # scratch session used to leak onto the live shared server.
    armed_socks = []
    busy_sends, solo_sends, loads = {}, {}, []
    # Bound before the try so an interrupt during setup lands in the handler
    # below with defined names. Ctrl-C is caught, not propagated, so without
    # this the "report what landed" path would raise NameError instead.
    busy_cap = solo_cap = None

    try:
        armed_socks.append(a.busy_socket)
        busy_pane, busy_cap = arm_up(a.busy_socket, "busy")
        armed_socks.append(solo_sock)
        solo_pane, solo_cap = arm_up(solo_sock, "solo")

        for i in range(1, a.samples + 1):
            loads.append(os.getloadavg()[0])
            for sends, sock, pane, pfx in (
                (busy_sends, a.busy_socket, busy_pane, "B"),
                (solo_sends, solo_sock, solo_pane, "S"),
            ):
                tok = f"CT{pfx}{i:05d}"
                t0 = time.time()
                subprocess.run([TMUX_BIN, "-S", sock, "send-keys", "-t", pane, tok, "Enter"],
                               capture_output=True)
                sends[tok] = t0
                time.sleep(a.interval / 2)
            if i % 10 == 0:
                print(f"  {i}/{a.samples}  load={loads[-1]:.1f}")
        time.sleep(1.0)  # let the last echoes land in the captures
    except KeyboardInterrupt:
        print("\ninterrupted; reporting what landed")
    finally:
        for sock in armed_socks:
            arm_down(sock)
        if solo_sock in armed_socks:
            subprocess.run([TMUX_BIN, "-S", solo_sock, "kill-server"], capture_output=True)

    if busy_cap is None or solo_cap is None or not loads:
        print("\ninterrupted before sampling began; nothing to report")
        return

    print(f"\nload during run: min={min(loads):.1f} max={max(loads):.1f}\n")
    print(f"{'arm':6} {'n':>4} {'echo1 p50':>10} {'p90':>8} {'max':>9}   "
          f"{'echo2-1 p50':>12} {'p90':>8} {'max':>9}")
    res = {}
    for name, cap, sends in (("BUSY", busy_cap, busy_sends), ("SOLO", solo_cap, solo_sends)):
        e1, e2 = parse(cap, sends)
        res[name] = (e1, e2)
        print(f"{name:6} {len(e1):>4} {pct(e1,50):>9.1f}m {pct(e1,90):>7.1f}m "
              f"{pct(e1,100):>8.1f}m   {pct(e2,50):>11.1f}m {pct(e2,90):>7.1f}m "
              f"{pct(e2,100):>8.1f}m")

    b1, s1 = res["BUSY"][0], res["SOLO"][0]
    if b1 and s1:
        ratio = pct(b1, 50) / max(pct(s1, 50), 0.001)
        print(f"\nBUSY/SOLO echo1 p50 ratio: {ratio:.1f}x")
        if ratio >= 2.0:
            print("  -> SERVER. Pane count per tmux server is the cause;")
            print("     sharding servers finer than one-per-repo is the fix.")
        elif pct(s1, 50) > 25:
            print("  -> MACHINE. A one-pane server is slow too; the box is")
            print("     oversubscribed and sharding buys little.")
        else:
            print("  -> Both arms healthy right now. Re-run during a stall.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
