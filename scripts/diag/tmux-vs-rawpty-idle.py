#!/usr/bin/env python3
"""Why is a tmux-attached terminal laggy when a raw one on the same box is not?

    tmux-vs-rawpty-idle.py [--reps 4] [--gaps 0.1,1,5,20]

WHY THIS EXISTS

The user's own A/B is the sharpest evidence in this investigation: iTerm2 with no
tmux in the path is fast, iTerm2 attached to tmux is laggy, and TBD's panel is
laggy in the same way at the same moment. Two unrelated renderers degrading
together exonerates rendering and points at tmux -- but the obvious tmux stories
have already been measured and refuted:

  pane count per server   a private one-pane server was exactly as slow as a
                          60-pane one (34.1 vs 36.5 ms p50), so head-of-line
                          blocking across panes is not it, and sharding servers
                          finer would buy nothing.
  process scheduling      a woken process responded in 0.4 ms p50 at load 60, so
                          the run queue is not starving anyone.

What those runs could not see is that they sampled every 0.4 s, which keeps every
process in the path continuously hot. Real typing follows a pause -- reading
output, thinking -- and this box is memory-exhausted (12.6 of 14.3 GB swap in
use, 75 agent processes, fseventsd at 3.5 GB). Under that pressure an idle
process's pages are compressed or evicted, and the next keystroke pays the fault
to bring them back.

That predicts a difference the earlier probes were blind to, and it is exactly
the difference the user reports:

  raw pty   one process in the path (the shell), and the emulator is a hot
            foreground app. Little to reclaim, so latency is flat in idle time.
  tmux      adds a client AND a server, both background processes, both
            reclaimable. Latency should grow with how long you were idle.

THE MEASUREMENT

Both arms are driven identically: write a token into a pty we own, then time
until the token becomes visible coming back out of that same pty. That is
keystroke-to-visible latency short of the GPU, and it is the quantity the user
is actually complaining about.

  RAW   our pty -> cat -> our pty
  TMUX  our pty -> tmux client -> socket -> tmux server -> pane pty -> cat
        -> server -> client -> our pty

The tmux arm attaches a real client through a real pty rather than shelling out
to `tmux send-keys`, because spawning a client per keystroke would measure
fork+exec -- 5.1 ms p50 and 58.9 ms p90 on this box -- instead of tmux. Real
typing forks nothing.

Each gap is slept before the sample, and the arms are interleaved so both see the
same system load. Load rides along because it has dominated every other effect
here.

  both flat across gaps        -> idle reclaim is not the mechanism; look
                                  downstream at delivery to clients.
  TMUX grows with gap, RAW flat -> memory pressure evicting the tmux processes.
                                  The fix is pressure, not tmux.
  both grow                    -> machine-wide reclaim; tmux only amplifies it
                                  by having more processes to fault back in.

RECLAMATION. The scratch session and both pty children are durable external
resources no sweep covers, so this script kills them on every exit path
including Ctrl-C. Tokens go only to panes it created; no agent session is
touched and no agent output is recorded.
"""
import argparse, os, pty, select, signal, struct, subprocess, sys, termios, time, fcntl

SESSION = "tbd-idlecost"
TMUX = "/opt/homebrew/bin/tmux"


def set_winsize(fd, rows=50, cols=200):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def spawn_pty(argv):
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execv(argv[0], argv)
        finally:
            os._exit(127)
    set_winsize(fd)
    return pid, fd


def drain(fd, quiet_for=0.25, limit=3.0):
    """Read until the fd has been silent for `quiet_for`, so a sample starts clean."""
    end = time.time() + limit
    last = time.time()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                if not os.read(fd, 65536):
                    return
            except OSError:
                return
            last = time.time()
        elif time.time() - last >= quiet_for:
            return


def sample(fd, token, timeout=8.0):
    """Write the token, return ms until it is visible coming back out."""
    buf = bytearray()
    t0 = time.time()
    os.write(fd, token + b"\r")
    while time.time() - t0 < timeout:
        r, _, _ = select.select([fd], [], [], timeout - (time.time() - t0))
        if not r:
            break
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if token in buf:
            return (time.time() - t0) * 1000
    return None


def pct(xs, p):
    if not xs:
        return float("nan")
    s = sorted(xs)
    return s[min(len(s) - 1, int(len(s) * p / 100))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default="/tmp/tmux-501/tbd-4c853a38")
    ap.add_argument("--reps", type=int, default=4)
    ap.add_argument("--gaps", default="0.1,1,5,20")
    a = ap.parse_args()
    gaps = [float(g) for g in a.gaps.split(",")]

    if not os.path.exists(a.socket):
        print(f"no such tmux socket: {a.socket}")
        return 1

    subprocess.run([TMUX, "-S", a.socket, "kill-session", "-t", f"={SESSION}"],
                   capture_output=True)
    subprocess.run([TMUX, "-S", a.socket, "new-session", "-d", "-s", SESSION,
                    "-c", "/tmp", "-x", "200", "-y", "50", "cat"], capture_output=True)

    pids = []
    try:
        raw_pid, raw_fd = spawn_pty(["/bin/cat"])
        pids.append(raw_pid)
        tmux_pid, tmux_fd = spawn_pty([TMUX, "-S", a.socket, "attach", "-t",
                                       f"={SESSION}", "-f", "ignore-size"])
        pids.append(tmux_pid)
        time.sleep(1.5)  # let the tmux client finish its initial full redraw
        drain(raw_fd); drain(tmux_fd)

        results = {("RAW", g): [] for g in gaps}
        results.update({("TMUX", g): [] for g in gaps})
        loads = []
        total = len(gaps) * a.reps
        done = 0
        for rep in range(a.reps):
            for g in gaps:
                for arm, fd in (("RAW", raw_fd), ("TMUX", tmux_fd)):
                    drain(fd, quiet_for=0.15, limit=1.0)
                    time.sleep(g)
                    tok = f"IC{arm[0]}{rep}{int(g*10):04d}".encode()
                    ms = sample(fd, tok)
                    if ms is not None:
                        results[(arm, g)].append(ms)
                loads.append(os.getloadavg()[0])
                done += 1
                print(f"  {done}/{total}  gap={g}s  load={loads[-1]:.0f}", flush=True)
    finally:
        for p in pids:
            try:
                os.kill(p, signal.SIGKILL)
                os.waitpid(p, 0)
            except OSError:
                pass
        subprocess.run([TMUX, "-S", a.socket, "kill-session", "-t", f"={SESSION}"],
                       capture_output=True)

    print(f"\nload during run: min={min(loads):.0f} max={max(loads):.0f}")
    print(f"\n{'idle gap':>9} | {'RAW p50':>9} {'p90':>8} {'max':>9} | "
          f"{'TMUX p50':>9} {'p90':>8} {'max':>9} | {'ratio':>6}")
    print("-" * 78)
    for g in gaps:
        r, t = results[("RAW", g)], results[("TMUX", g)]
        ratio = pct(t, 50) / max(pct(r, 50), 0.001) if r and t else float("nan")
        print(f"{g:>8}s | {pct(r,50):>8.1f}m {pct(r,90):>7.1f}m {pct(r,100):>8.1f}m | "
              f"{pct(t,50):>8.1f}m {pct(t,90):>7.1f}m {pct(t,100):>8.1f}m | {ratio:>5.1f}x")

    short, long = gaps[0], gaps[-1]
    for arm in ("RAW", "TMUX"):
        s, l = results[(arm, short)], results[(arm, long)]
        if s and l:
            print(f"{arm:5} {short}s -> {long}s idle: "
                  f"{pct(s,50):.1f}ms -> {pct(l,50):.1f}ms "
                  f"({pct(l,50)/max(pct(s,50),0.001):.1f}x)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
