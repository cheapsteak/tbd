# One latency number for both terminal transports

## Why

The pty-holder transport was justified on latency. Its design
([`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md))
argues that a tmux keystroke costs process wakeups whose latency tracks
machine load, while a raw pty costs none, and its Rollout section makes
graduation depend on a paired measurement: p90 keystroke echo at load no more
than 2× p90 at idle, and no more than 5 ms. That section also says the run
"must exercise a real holder-backed session, not the raw-pty arm standing in
for one", because the raw arm is the design's central claim and a gate that
assumes the claim measures nothing.

Nothing in TBD can take that measurement. The probes committed with the
transport spec (`scripts/diag/tmux-vs-rawpty-idle.py`,
`scripts/diag/tmux-server-contention.py`) drive a pty the script owns; they
never pass through TBD's app, its reader threads, or its emulator. The
instrument that did cover TBD's own output path (PR #739) measured a
main-thread hop that no longer exists, since output now feeds synchronously on
the IO thread, and it only ever covered the tmux arm, because a holder-backed
panel has no `LocalProcess`.

This design ships the instrument the transport spec asks for: a number taken
inside TBD, on both transports, by one mechanism, so the two arms are
comparable by construction.

## What ships

Everything lives in `TBDApp`, is off by default, and is enabled by one
`UserDefaults` key for a measurement session:

```
defaults write TBDApp enableTerminalLatencyDiagnostic -bool true
```

Off, the whole instrument is one nil-check per chunk of terminal output.

### The seam: one entry point both transports feed through

Both transports already hand every chunk to the same object.
`TerminalViewHolder` is the lock-guarded box the IO-thread feed path reaches
the view through, and each arm calls `withView { $0.feed(byteArray:) }` on it:
the tmux arm from `Coordinator.dataReceived(slice:)`, the holder arm from the
`HolderStreamReader` callback in `startHolderClient`. The seam is that object.
`TerminalViewHolder` gains a `feed(_:)` method that stamps the chunk, feeds the
view, and stamps again; both call sites change from `withView { $0.feed(...) }`
to `feed(...)`. Nothing about the feed changes: same thread, same lock, same
view reference, same drop-on-teardown behaviour.

The alternative was two instruments at the two call sites. It touches no
shared code, but the arms can drift, and the spec would have to *argue* that
they measure the same thing. With one seam the argument is unnecessary: a
timestamp taken on entry to `TerminalViewHolder.feed` means "the bytes reached
the app's feed seam" on both arms, and the same line of code takes it.

The control-mode attach path (`registerReader` in `startControlModeClient`,
which feeds on the main queue) is not tapped. It is off by default, it feeds
through a different object, and it leaves with tmux.

### The passive tap: bytes-waiting-for-a-draw, defined by the symptom

`TerminalLatencyTap` is one small lock-guarded object per panel, held by the
`TerminalViewHolder` and by the panel's `TBDTerminalView`. It records two
things:

- **On every chunk**, from the IO thread: the time the chunk reached the seam
  and how long the view's `feed` took to return. Timestamps go into a bounded
  ring; the parse duration is kept as a running maximum.
- **On every draw of that panel's view**, from `TBDTerminalView.viewWillDraw()`
  on the main thread: the tap takes everything in the ring and emits one line.

The line reports the *oldest* chunk's wait. That is the symptom: bytes that
were parsed into the emulator and sat there undrawn. A window defined this way
presupposes no culprit, which is what let #739's investigation rule the poll
cycle *out* rather than assume it in, and it is the one idea from that design
this one keeps. Per-chunk emission is deliberately not done: the worst
measured chunk rate is 634/s during scrolling, and one line per draw (at most
the display rate) carries the tail exactly, because the oldest chunk in a
frame *is* that frame's worst wait.

A draw with no new chunks (a caret blink) emits nothing. A panel that is fed
but never drawn, which TBD does for unselected worktrees, fills its ring; the
ring is capped at 512 entries and the overflow is counted, so an off-screen
panel costs a bounded amount of memory and its eventual draw reports how much
it dropped. Visibility is recorded with the same
`TerminalCommitLatencyProbe.isOnScreen` check the commit probe uses, so a
reader can separate on-screen draws from the rest.

The draw endpoint is the *start* of the view's draw. It is per-view, so it
names which panel drew, which SwiftTerm's static `onFramePresented` hook cannot
(and that hook has one slot, already owned by the commit-latency probe). What
follows the start of a draw is covered by the commit probe, and it is
milliseconds; the quantity in question here has always been the wait before
it. Under the Metal renderer flag `viewWillDraw` is not on the frame path, so
the tap emits no draw lines there; the flag is off by default and its A/B came
back flat.

### The echo probe: the number that can settle the question

The passive tap cannot compare the transports. Its timestamps start when
bytes reach the app, and everything between the pty and that point, which is
precisely where tmux sits, is invisible to it on both arms. A comparison needs
a loop the app closes itself: write a token through the panel's real keystroke
path, watch the seam for its echo, and stamp both ends in the same process.

`TerminalEchoProbe` does exactly one thing per request: it writes one token
into one terminal through `Coordinator.send(source:data:)`, the delegate entry
a keystroke reaches after SwiftTerm's input hop, so the write pays whatever a
keystroke pays on that transport (a `DispatchIO` write to the attach client's
pty on tmux; a synchronous `write(2)` to the session's pty on the holder). The
token is short lowercase ASCII with a sequence number, followed by a carriage
return so each token starts a fresh line and never wraps mid-token. The tap
on that panel watches subsequent chunks for the token, matching across chunk
boundaries with a tail buffer, and on the first occurrence emits one line with
the elapsed time. The first occurrence is the line discipline's echo (or, on
tmux, the server's rendering of it); `cat`'s own copy of the line arrives
later and is ignored because the token is no longer pending.

The probe is deliberately stateless beyond one pending token per panel. It
has no count, no gap, no arms, and no timer. A request that arrives while a
token is still pending replaces it and reports the old one as lost. Pacing,
sample size, the idle and load arms, and their interleaving are the run's
policy, and they live in the driver script, where changing them is an edit
rather than a rebuild (`docs/theory-placement.md`). The app compiles the one
thing user-land cannot do: originate a write on the keystroke path and
observe the echo at the seam, in one process, on one clock.

**A request is a file.** The driver writes
`~/tbd/runtime/terminal-latency-probe.json` naming a terminal id and a
sequence number; the app watches the runtime directory with a dispatch source
while the diagnostic is on, reads the file, deletes it, and writes the token.
The precedent is the runtime directory's other app-read file,
`claude-overlay.json`, and the unmerged typed-input driver on
`tbd/741-paint-scheduling-floor`, which used the same shape. A daemon RPC that
forwarded a probe event to the app was considered and rejected: three times
the plumbing, and it would put the daemon's RPC latency on the path *before*
the app stamps the start, which is harmless but pointless.

**The probe writes input into a session, so it refuses anything that is not
a scratch shell.** The app refuses a request naming a terminal whose row is
not a plain shell, and logs the refusal; agents (Claude, Codex) can never be
typed into by this path. The driver goes further: it creates the `cat`
sessions it measures, verifies each one's transport from the daemon before
the first sample, only ever names those ids, and closes them on every exit
path including interrupt.

### How the number gets out

Signposts are a ring buffer and their emission is gated on a live listener;
both facts have already cost measurement runs here. Every line this
instrument produces is an `.info` log line on subsystem `com.tbd.app`,
category `terminallatency`, in `key=value` form, read back with `log show`
after the run:

```
draw transport=holder terminal=<uuid> chunks=<n> oldestms=<f> newestms=<f> parsemaxms=<f> dropped=<n> vis=<0|1>
echo transport=tmux terminal=<uuid> seq=<n> ms=<f>
echolost transport=tmux terminal=<uuid> seq=<n>
echorefused terminal=<uuid> reason=<word>
```

The format is pinned by a test because the scripts match it verbatim.

### Two scripts

- `scripts/diag/terminal-latency-probe.py` drives a paired run. Given the two
  scratch terminal ids (or a worktree to create them in), it interleaves
  samples across the arms so both see the same machine, records the load
  average alongside every sample, and reads the lines back with `log show`
  when the run ends. It refuses to report an arm whose echo count does not
  match its request count, and it refuses to pool samples taken under
  different load bands.
- `scripts/diag/terminal-latency-report.py` turns a `log show` capture into
  the table: per transport, echo n/p50/p90/p99/max and the flatness ratio
  against the idle band; per transport, the oldest-wait distribution over
  on-screen draws, the parse maximum, and drops. Fixture-driven self-test,
  run from the CI script-harness step like the other Python checks.

### The headline

**p90 echo latency per transport, paired idle against load, from one
interleaved run**, with the 2× flatness ratio and the 5 ms bound the
transport spec names. The passive oldest-wait distribution is the
decomposition beneath it: identical in mechanism on both arms, so if the two
arms' draw waits agree and their echoes differ, the difference is upstream of
the app, which is the transport. If the draw waits *disagree*, the arms are
not being measured the same way and the echo comparison is suspect; the
report prints both so that check is always visible.

## What this instrument cannot show

- **The wait before the app's read.** Bytes queue in the kernel before the
  reader thread wakes, and that queue is a different object on each arm (the
  attach client's pty on tmux, the session's master on the holder). The
  passive tap cannot see it; the echo probe spans it. Only the echo number
  compares transports.
- **Pixels.** The draw endpoint is the start of a draw. The commit probe
  covers the app-side commit; nothing covers the compositor.
- **An agent's response.** `cat` echo is the line discipline or tmux
  answering, not a TUI repainting. That is the point: the transport's cost is
  isolated from the program's. It says nothing about how fast Claude Code
  redraws.
- **A fair comparison without a fair run.** The two arms need deliberate
  setup: `Config.ptyHolderDefault` is `false`, so a holder session exists only
  if the flag was on when it was spawned. The driver interleaves arms and
  records load per sample because on this machine a load swing from 7 to 139
  once faked a threefold effect that vanished under matched load; measurements
  must be ordered A/B/A and never pooled across load bands. The script
  enforces what it can and prints the rest.
- **Anything under the Metal renderer**, or on the control-mode attach path.
- **The detached daemon drain.** When no viewer is attached the daemon's
  `HolderReader` drains the pty into its own emulator, and that consumer has
  its own latency. It is out of scope: nobody types into a detached session,
  the transport spec's flatness bound "does not speak to it at all", and its
  consumers (`terminal.output`, the hibernation pending-input rail) tolerate
  seconds. Its drain loop has the same read→feed shape if a number is ever
  wanted there, and it would need its own category and script support rather
  than a third arm in this one.

## Gating

Default off, one `UserDefaults` key, `enableTerminalLatencyDiagnostic`, with
the default in one place (`AppState.terminalLatencyDiagnosticDefault`),
following `enableCommitLatencyDiagnostic`. Off, no tap is created, the seam
does one nil-check, the view does one nil-check, and no directory is watched.
It is a measurement tool with no graduation plan, like the commit probe: the
per-draw `.info` line is acceptable during a run and not as a fleet-wide
default, and the echo probe writes into sessions, which must never be armed
by default. Both branches of the gate are tested.

## Clocks

Both endpoints of every number are read from monotonic uptime
(`ProcessInfo.processInfo.systemUptime`) behind an injected
`now: () -> Double`, as the commit probe does: these are behaviour, never
persisted, never compared to a `Date`. The instrument has no delays, timers,
or timeouts of its own, so it takes no `Clock`; the echo probe's replacement
rule (a new request retires the pending token) is what bounds a lost echo,
and the driver script owns the pacing.

## Testing

- The gate, both branches, through a per-test `UserDefaults(suiteName:)`.
- The tap with a hand-cranked clock: one chunk then a draw yields one line
  whose oldest wait is the difference; three chunks then a draw report the
  first as oldest and the last as newest; a draw with no chunks emits nothing;
  513 chunks then a draw report 512 and one dropped; the parse maximum is the
  maximum.
- The echo matcher: a token in one chunk; a token split across two chunks; a
  second copy after the match is ignored; a new request retires the pending
  token as lost; a request for a non-shell terminal is refused with the
  reason.
- The seam: `TerminalViewHolder.feed` with no tap feeds the view exactly as
  `withView` did, and with the view cleared records nothing.
- The line format, pinned.
- Each test fails with its change reverted; the report script's self-test
  runs in CI.

## Run recipe

1. Enable the key, relaunch the app (`scripts/restart.sh`), confirm which
   worktree's daemon is running.
2. Create one `cat` shell terminal with the pty-holder flag off and one with
   it on, in a scratch worktree, and confirm their transports from
   `tbd terminal list --json`. The driver can do this itself.
3. Run the driver at idle; run it again under load, or let it run across a
   load change and bucket. Nothing heavy may run on the machine during the
   idle arm, and no build may run during either.
4. Read the report. Graduation is a judgement over the four conditions the
   transport spec lists (workload, sample size, absolute bound, flatness
   bound); this instrument supplies the numbers, not the verdict.

## Rejected alternatives

- **Two instruments, one per call site.** No shared-code change, but the arms
  can drift, and the design would rest on an argument that they agree rather
  than on the same line of code.
- **Signposts.** #739 shipped them; they cost nothing when nobody listens,
  which is also why the numbers vanish when nobody listens.
- **Per-chunk lines.** The worst chunk rate measured is 634/s; one line per
  draw loses no information about the wait, because the oldest chunk in a
  frame is that frame's stall.
- **`onFramePresented` as the draw endpoint.** A single process-wide slot,
  already taken, with no view identity.
- **A daemon RPC as the probe trigger.** Three times the plumbing to deliver
  a two-field request.
- **Pacing inside the app.** Count, gap, and arms are run policy; a script
  changes them by editing a file, and the app keeps one fact (one echo, one
  timestamp) and no timer.
- **Driving through `tbd terminal send`.** On tmux it goes through
  `tmux send-keys` and never touches the app, so the arms would start from
  different places.
- **A third arm for the daemon's drain.** Out of scope, above.
