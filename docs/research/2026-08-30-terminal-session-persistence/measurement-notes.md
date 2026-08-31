# Measured behaviour of the current tmux path

Companion to the two research records in this directory. Everything here was
measured on a loaded development machine (48 GB, ~75 concurrent agent
processes) with the probes in `scripts/diag/`, and is included because the
design question turns on *where* the latency comes from, not merely that it
exists.

## Keystroke-to-visible, raw pty against tmux

Both arms are driven identically: write a token into a pty the probe owns, then
time until it becomes visible coming back out of that same pty. The tmux arm
attaches a real client through a real pty rather than shelling out per
keystroke, because spawning a client per key would measure `fork`+`exec` — 5.1 ms
p50 and 58.9 ms p90 on this machine — instead of tmux.

- **load 20-37** — raw 0.1 ms p50 / 0.3 p90 / 0.4 max; tmux 1.1 ms p50 / 9.3 p90 / 11.6 max
- **load 62-77** — raw 0.1 ms p50 / 0.9 p90 / 5.0 max; tmux 3.3 ms p50 / 12.7 p90 / 18.2 max
- **load 72-117** — raw 0.2 ms p50, 5.0 ms max; tmux 139 ms p90 (n=4, directional only)

Two readings matter more than the absolute numbers. **A raw pty never exceeded
5 ms at any load**, including 117 — it is flat. **tmux's p90 runs 9.3 -> 12.7 ->
139 ms** across the same range. tmux is not a constant tax that load makes
visible; it degrades superlinearly against a baseline that does not degrade.

At 1.1 ms p50 on a quiet machine tmux is imperceptible, so the interactive lag
reported on this machine is a load phenomenon. The scaling difference is the
durable finding.

## The probe's tmux arm is TBD's live path

Worth stating so these numbers are not discounted as a synthetic analogue. TBD's
default terminal path is the one described in `docs/tmux-integration.md`: the app
spawns a `tmux attach` client per viewer against a private single-window session,
and SwiftTerm reads that client's pty natively rather than parsing a protocol.
Confirmed on a running system — the `tmux -u -L <server> attach` processes are
children of the app, not the daemon.

The control-mode path in `Sources/TBDDaemon/Tmux/ControlMode/`, which routes
`%output` through `PaneFanout` into per-pane pipes vended over the FD sidecar,
is gated behind `control_mode_enabled`. That flag defaults false
(`ConfigStore.swift`, `control_mode_enabled ?? false`) and reads `0` in the live
database.

So the daemon is not a wakeup in the default rendering path, and the probe --
which attaches a client through a pty it owns and reads the pty directly -- is
measuring the same arrangement the product ships. The saving available from
removing tmux is therefore the two server wakeups and the redundant VT parse
below, and nothing else; there is no intermediary left to delete first.

## The tmux client is not in the keystroke path

An earlier reading of these numbers attributed them to four process hops — app,
tmux client, tmux server, pane pty. That attribution is wrong, and the error is
worth recording because it would have justified deleting a component that costs
nothing.

`tmux attach` dups its stdin/stdout to the server over `SCM_RIGHTS` during
`client_send_identify`; the server stores them as `c->fd`, registers libevent
watches on that fd directly, and reads keystrokes off it in `tty_read_callback`.
GNU screen does the same by way of `SendAttachMsg`. The client process is a
setup and teardown participant, not a relay.

Measured directly: 2000 keystrokes driven through an attached client's pty,
sampling both processes' CPU time either side.

- **tmux client — 0 ms** of CPU
- **tmux server — 80 ms** of CPU, about 40 us per keystroke

So the corrected account of a tmux keystroke is roughly **two server wakeups**
(one to read the key off the client fd, one to read the echo back off the pane
pty) plus the reader's own wakeup, against a raw pty's **one**. A wakeup costs
about 0.4 ms p50 here, and 3 x 0.4 ms lands on the 1.1 ms measured at low load.

The server's actual *work* is 40 us. The latency is almost entirely waiting to be
scheduled, which is why it tracks system load so closely and why a raw pty —
whose echo happens in the kernel line discipline inside `write()`, with no
process wakeup at all — is indifferent to it.

## What this implies for a replacement

The saving available is the two server wakeups and the redundant VT parse, not
the removal of a client process. Any design in which the persistent process
*reads* the pty while a viewer is attached reintroduces exactly the cost being
removed, so an attached viewer must read the pty master itself.

That constraint collides with the detached-output problem described in the two
companion records, though the window is narrower than it first appears and is
worth stating precisely.

A supervisor that never reads the pty cannot buffer output produced while
*nothing at all* is reading, and the writer blocks once the kernel tty buffer
fills. That window is not "no human is watching" — it is "no reader process
exists". In iTerm2 the two collapse together because the app is the only reader
it has: `TaskNotifier` runs a single `select()` loop over every registered task,
and `wantsRead` consults only `paused` (set solely for an undoable termination)
and the job manager's `ioAllowed`. Focus and visibility never enter it, so a
background tab drains exactly like a foreground one, and the stall can only
happen when the app itself is gone.

TBD's shape differs in a way that helps rather than hurts. iTerm2 has no
always-on component, so when its app dies nothing can drain and blocking is
unavoidable. TBD has a daemon that outlives the app, so it can cover exactly the
window iTerm2 cannot. What it does not automatically cover is its own restart,
which is the case a minimal holder process — separate from both daemon and app,
the shape of iTerm2's server — would exist to handle.

So the design needs three roles rather than two: a holder that survives
everything, a drainer of last resort for whenever no viewer is attached, and the
attached viewer reading the master directly. The handoff between the last two,
with an acknowledged edge so exactly one reader owns the fd at a time, is the
hard part of any such design rather than an implementation detail.

Note also that blocking is backpressure, not loss — a writer stalled on a full
buffer resumes when a reader returns. The failure modes across prior art differ
in kind: dtach and abduco read and discard while detached (loss, no stall),
iTerm2 never reads (stall, no loss), and tmux and its modern equivalents read
into a headless VT (neither, at the cost of a process in the path).

## Reproducing

- `scripts/diag/tmux-vs-rawpty-idle.py` — the raw-pty/tmux comparison above.
- `scripts/diag/tmux-server-contention.py` — interleaves a busy server against a
  private one-pane server. Measured 34.1 ms against 36.5 ms p50, which is why
  pane count per server, and therefore sharding servers more finely, is not a
  lever here.
