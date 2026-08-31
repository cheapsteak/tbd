# Migrating terminal sessions off tmux onto per-session pty holders

**Status:** Approved design. Not yet implemented.

**Companion evidence:** the measurement and research records under
[`docs/research/2026-08-30-terminal-session-persistence/`](../research/2026-08-30-terminal-session-persistence/)
— field measurements of the tmux path, a full source read of iTerm2's session
restoration, and a prior-art survey of every shipping system found in this
space. This spec restates the decision-critical numbers so it stands alone, and
defers to those records for methodology and file:line citations.

## Summary

TBD today keeps agent sessions alive across daemon and app restarts by running
them under tmux. This design replaces tmux with a **per-session holder
process**: a minimal supervisor that `forkpty()`s the job, holds the pty
master, and hands the master over `SCM_RIGHTS` to whoever should be reading —
the app while a viewer is attached, the daemon otherwise. The attached path
becomes a raw pty read in the app with no other process involved, which is the
arrangement iTerm2 has shipped for years; the daemon's always-on presence
covers the detached-output window iTerm2 structurally cannot.

The justification is **scaling headroom, not current latency**. At quiet load
tmux costs 1.1 ms p50 per keystroke and is imperceptible; this design does not
claim to fix any latency a user feels today. What the measurements show is that
a raw pty is *flat* under load (never exceeded 5 ms at any load including 117)
while tmux degrades superlinearly (p90 of 9.3 → 12.7 → 139 ms as load rises),
because a tmux keystroke costs two extra process wakeups whose latency is
scheduling delay. tmux is therefore the component that breaks first as the
fleet grows. The design point is roughly twice the present fleet: **~150
concurrent sessions at sustained load ≥ 100** on one machine.

## The measured basis

Three findings from the companion records shape everything below.

- **The cost of tmux is process wakeups, and they track load.** A raw pty's
  echo happens in the kernel line discipline inside `write()`, with no process
  wakeup at all, which is why it is indifferent to load. A tmux keystroke is
  two server wakeups (read the key, read the echo) plus the reader's own; the
  server's actual work is ~40 µs, and the rest is waiting to be scheduled.
  The tmux *client* is not in the steady-state path — it hands its stdin to
  the server over `SCM_RIGHTS` at attach — so there is no client relay to
  delete; the only saving available is the server wakeups and the redundant
  VT parse.
- **TBD's live path is already the good arrangement, minus tmux.** The app
  spawns a `tmux attach` client per viewer and SwiftTerm reads that client's
  pty natively; the control-mode fanout is gated off by default. There is no
  intermediary left to remove first.
- **Holding a pty master elsewhere is proven, and draining is the hard half.**
  Passing a master over `SCM_RIGHTS` to another process which then does direct
  I/O works on Darwin, and the shell sees no SIGHUP when the passing process
  dies. But a supervisor that merely parks the fd wedges its child once the
  kernel tty buffer fills — observed directly — so exactly one process must be
  reading at all times that output flows, and the transfer of that role needs
  an acknowledged edge.

Additionally, tmux imposes a throughput cost this design removes: every byte a
program prints is parsed twice — once by the tmux server into its grid, then
re-rendered as a fresh escape stream that SwiftTerm parses again — with tmux's
output flow control in between. On the new attached path the bytes are read
once and parsed once, by the app. For the dominant workload (a full-screen
agent TUI repainting continuously) this is a straight bandwidth win in addition
to the latency-flatness win.

## Design overview

Three roles, three processes:

- **The holder** — one tiny process per session. It `forkpty()`s the job, owns
  the pty master for the session's whole life, and **never reads it**. It
  survives daemon restarts, app restarts, and crashes of both. Holder death
  is session death — by policy as well as by mechanism, see "Holder death"
  below — so it is kept small enough to essentially never change.
- **The daemon** — the arbiter of who reads, and the **default reader**. While
  no viewer is attached it drains the master into a headless terminal
  emulator, so unattended agents never stall and reattachment has a screen to
  show. Because the holder owns the master, the daemon is freely restartable:
  a daemon restart no longer touches any live terminal.
- **The app (viewer)** — while attached, reads and writes the master directly
  through a dup received over the existing FD sidecar. Keystroke echo is
  kernel → app: 0.1 ms, flat under load, identical in mechanism to iTerm2's
  attached path.

The single-reader invariant, in one sentence: **the daemon reads exactly the
sessions that no live, connected app has claimed — and when it cannot yet
know, it errs toward reading nothing**, because not-reading costs recoverable
backpressure while double-reading is silent corruption (each `read()` steals
bytes the other reader never sees).

## The holder

### Contract

- **Spawn.** The daemon spawns the holder with fork + `setsid()` + exec.
  `setsid` detaches it from any process group that could signal it (the
  iTerm2 lesson: without it, a Ctrl-C aimed at the parent kills the
  supervisor and strands every session). The holder then `forkpty()`s the
  job, making it both the master's owner and the child's parent; it reaps the
  child via SIGCHLD. When the daemon exits, the holder orphans to launchd and
  carries on. SIGHUP and SIGPIPE are ignored.
- **Lifetime.** The holder exits when its child exits — but only after
  reporting the child's exit status to the daemon, or timing out trying
  (bounded, injected clock). Exit status is data the session lifecycle wants,
  and the holder is the only process guaranteed to observe it. If the report
  never lands (daemon down through the whole timeout), the session record's
  status becomes exited, status unknown — implementations must not fabricate
  one. On the way out the holder unlinks its socket.
- **Rendezvous and identity.** One Unix socket per holder, at a
  `TBDConstants`-derived path under the TBD home directory (honoring
  `TBD_HOME`), named by the session UUID. Session identity is the UUID TBD
  already persists — stronger than iTerm2's *(socket number, child pid)*
  pairing. Socket paths observe `sun_path`-length discipline: the sessions
  directory stays shallow, and the length is checked before every `bind` and
  `connect`. The socket is bound with owner-only permissions. One client at a
  time, enforced holder-side: a second connection is accepted and immediately
  rejected with a sentinel protocol version.
- **Creation is serialized by an advisory lock.** A socket file alone cannot
  distinguish a live holder from the corpse of a SIGKILLed one, and `bind`
  refuses a path that already exists — so "unlink the stale socket, then bind"
  is a race two spawners can both win, leaving one holder bound to a path the
  other has already unlinked and a session nobody can reach. Beside each
  socket sits a zero-byte lock file on the same UUID. A spawner takes an
  exclusive `flock` on it before unlinking or binding anything; the descriptor
  carrying the lock is passed across exec to the holder (`FD_CLOEXEC`
  cleared) and the daemon closes its own copy, so the holder alone holds it
  for its whole life. A spawner that cannot take the lock has learned that a
  live holder owns that UUID **without connecting to it**, and backs off
  instead of clearing the path — which is what makes the stale-daemon hazard
  named under Reconciliation safe rather than merely detectable. The kernel
  drops the lock when the holder dies, so nothing can leak but an empty file,
  swept with the socket by `OrphanGC`.

  Two rules keep that safe against holder versions. **A socket with no
  sibling lock is unowned-but-unproven, never unowned**: the spawner must
  handshake the existing socket before clearing it, and a rejected or
  timed-out handshake means leave it alone. Absence of a lock is not evidence
  of absence of a holder. And **the rendezvous layout is frozen at v1** —
  socket name, lock name, lock semantics — deliberately outside the
  protocol's version negotiation, because it has to be interpretable *before*
  a connection exists, which is exactly when no version has been exchanged.
  A future holder needing a different rendezvous gets a different directory,
  not a different convention in the same one.
- **Protocol.** Minimal and versioned from day one. Verbs: report the child
  (pid, tty name, launch parameters, alive/exited status) and hand over a
  master dup; report exit status; forget the child (close the master and stop
  reporting, so a killed session cannot be resurrected — iTerm2's preemptive
  wait). The version field is load-bearing: long-lived sessions keep running
  old holder binaries, so the daemon must interoperate with every holder
  version that has ever shipped. This is the standing argument for keeping
  the holder near-featureless forever.
- **Environment and launch parameters.** The session's environment (including
  `envOverrides`) is applied at spawn by the daemon and passed through the
  holder to the child, replacing today's tmux `-e` delivery. The holder
  retains the launch request and replays it on demand, so a re-adopting
  daemon can reconstruct what is running without trusting the database.
- **Binary.** A new small SPM executable target. No copying the binary out of
  the build tree: a running holder's executable image survives rebuilds and
  build-directory reclamation (iTerm2 copies its server binary only because
  its auto-updater deletes the bundle out from under running servers, a
  hazard TBD does not have). The consequence — old sessions run old holders —
  is handled by the protocol versioning above.

### Why per-session

The holder is the process whose crash kills its sessions' ptys, so blast
radius dominates the granularity choice. A per-session holder's bug costs one
session; its lifecycle is self-reclaiming in the common case (exit on child
exit); its socket needs no child multiplexing; and upgrading the holder
binary — the hardest problem in this space, which Superset solves with a
successor-spawn fd-inheritance dance — is sidestepped entirely, because new
sessions simply get the new binary while old ones keep the old. At the design
point this is ~150 processes, which is trivial on macOS. The daemon's fd
budget is likewise a non-issue: it already raises `RLIMIT_NOFILE` at startup
(`raiseFileDescriptorLimit` in `Sources/TBDDaemon/Daemon.swift`) far beyond
150 master dups plus 150 holder sockets.

### Holder death

The daemon holds a master dup, so a holder crash does not by itself kill the
child: the kernel's fd refcount keeps the pty alive — the same mechanism
Superset exploits on purpose for daemon upgrades. The policy is that it kills
the session anyway, promptly and deliberately. The daemon watches its
connection to each holder; when a holder dies while its child lives, the
daemon kills the child's **process group** — the child is the session leader
of the pty's own session, courtesy of `forkpty`, so the group is the natural
closure of the job rather than one pid — verifying process identity
(executable and start time) before signalling, then closes its dups and marks
the session exited with a distinct reason (holder lost) rather than a generic
exit.

Two honest limits on that kill, neither new to this design. Identity
verification narrows the pid-reuse window but does not close it: nothing makes
"check identity" and "signal" atomic on Darwin, and the residual race is the
same one every pid-based reclaimer in TBD already runs. And a descendant that
deliberately leaves the group — `setsid`, a double fork, `nohup`, `disown` —
is outside the closure and survives, exactly as it survives a tmux pane kill
today. Reclaiming deliberate escapees is a standing fleet-wide problem that
belongs to `AgentReaper`, not to the transport; this design neither worsens
it nor claims to solve it.

The alternative — carrying the session on the daemon's own dup, marked
degraded — was rejected: it preserves in-flight work only until the next
daemon restart kills the session anyway, at the price of a permanent extra
session state and an ownership story with an exception in it. Holder crashes
are expected to be vanishingly rare precisely because the holder is small and
frozen; predictability is worth more than softening a rare event.

Recovery follows the transcript. For a Claude session the conversation up to
the last persisted turn survives on disk regardless, and a respawn with
`claude --resume <session-id>` continues it (any revive affordance must pass
`--fork-session`; a bare `--resume` reuses the session UUID). The in-flight
turn and unsubmitted composer input are lost — the same ladder as any process
death today, and no worse than a tmux server crash is now, with blast radius
one session rather than a repo's worth. Because the daemon knows why the
session died, the distinct exit reason enables a natural follow-on, out of
scope for this design: a UI affordance that revives the session in place.

## Reader arbitration

Each session has exactly one reader at any moment: the app, the daemon, or —
transiently and safely — nobody. All transitions are arbitrated by the daemon,
which is also the fallback reader, so the acknowledged edge ("you read now, I
have stopped") is an in-process state transition plus one acked fd-vend, not a
distributed protocol.

- **Attach.** The app requests a session over the existing RPC. The daemon
  **quiesces** before it snapshots anything: it lets any in-flight `read()`
  finish and feeds every byte it already holds into its emulator, so no byte
  is stranded in a buffer the app will never see. Only then does it render its
  headless emulator's screen and retained scrollback into an escape-sequence
  **snapshot preamble** and send the preamble plus the master dup over the FD
  sidecar. The app feeds the preamble into SwiftTerm first, then goes live on
  the fd, then jiggles (see below). Reattach therefore paints the last-known
  screen instantly, as tmux does today. Ownership transfers on the app's
  acknowledgement, not on the send. A failed vend or a lost ack does **not**
  license an unconditional resume, because a lost ack and a lost app are
  indistinguishable on the wire and the app may already be live on its dup —
  resuming there would be the double read this whole design exists to prevent.
  So the daemon applies the same liveness gate as App death below: app
  confirmed gone, resume reading and the session is detached again; app alive
  or not yet determined, stay off the fd and await reconnect and re-claim. The
  invariant is "at most one reader", so the failure direction is always toward
  reading nothing until liveness says otherwise — accepting a recoverable
  stall over an unrecoverable corruption.
- **Detach.** The mirror image, carrying the same ordering discipline in the
  opposite direction: the app stops reading and closes its dup, and **only
  then** tells the daemon. The detach notice carries a **snapshot preamble of
  the app's own**, produced by the same serializer attach uses in the other
  direction; the daemon resets its emulator, replays that preamble, and only
  then resumes reading. This is what makes the handback symmetric, and it is
  load-bearing rather than tidy: the jiggle heals only programs that repaint
  on SIGWINCH, so without the handback a detach from a plain shell would leave
  the daemon's store frozen at the last attach until new output happened to
  arrive. One snapshot per detach is not the streaming handback rejected below
  — it is O(1) per reader change, not per byte. The
  close-before-notify order is what preserves the single-reader invariant — a
  notify-first detach would put the daemon on the fd while the app's last
  `read()` is still outstanding, which is the double-reader corruption in
  miniature. An app that dies mid-detach needs no special handling: the fd
  closes with the process and the app-death path below covers it.
- **App death.** A sidecar disconnect alone is not death: the sidecar has a
  designed reconnect path, so a socket-level drop can leave the app alive,
  holding its dups, still reading — and seizing then is exactly the
  double-reader corruption this design exists to avoid. On disconnect the
  daemon first checks whether the app process is alive, using the same
  identity-verified check the holder-death kill uses — recorded pid plus
  executable and start time — so a reused pid cannot make a dead app look
  alive and stall the fleet. Gone: every session
  it held reverts to daemon-read, with a jiggle, no cooperation from the dead
  process needed. Alive: the daemon stays off the fds and treats the drop
  like the startup grace window — await reconnect and re-claim, seize only on
  confirmed process death.
- **Daemon death.** Attached sessions are untouched — the app keeps its fds
  and keeps painting through the entire daemon outage. Detached sessions have
  no reader: their writers block on the kernel tty buffer, which is
  backpressure, not loss, and drains when the daemon returns.
- **Daemon startup (re-adoption).** The new daemon connects to every holder
  and adopts a master dup, but **reads nothing yet**. Every app-liveness
  question below is the identity-verified check described under App death,
  never a bare `kill(pid, 0)`. If no app process is alive, it becomes reader
  of everything immediately. If an app process is alive, it waits for that app's sidecar handshake, which carries the list of
  sessions the app holds fds for; claimed sessions stay app-owned and
  everything else begins draining. The wait is bounded by a grace window on
  an injected clock; on expiry the daemon re-checks app liveness — app gone,
  drain everything; app alive but silent, stay off the fds, log loudly, and
  raise a user-visible notification. A claim arriving after draining began is
  handled as an ordinary attach. The database records attach state as an
  observability hint only; it is never the arbiter, because a persisted row
  cannot answer a liveness question.

The alive-but-silent arm is an acknowledged limitation: while an app process
exists but never (re)connects, no detached session drains — a fleet-wide
stall of unattended work, visible as the notification above plus writers
blocked on full tty buffers. The alternative — draining sessions a database
hint says were detached — trades a visible, recoverable stall for a chance of
silent corruption, and is rejected; backpressure loses nothing, and the stall
ends the moment the app reconnects or its process dies.

This arbitration was checked against the restart script's actual sequencing
(daemon bounces first, then the app): during a full development restart,
attached sessions keep painting through the daemon swap and go dark only for
the app's own bounce; detached sessions get a few seconds of harmless
backpressure. The daemon-only restart path — a live app throughout — is the
scenario the claim handshake exists for, and ordinary development restarts
exercise it continuously.

### Input is not arbitrated, but it is serialized

Reading the master is exclusive; writing is not. The daemon keeps its master
dup for the session's whole life and injects input (`tbd terminal send`,
queued prompts, supervision nudges) by writing to it. This retires a real bug
class: today a daemon keystroke is addressed to a tmux pane coordinate
resolved at send time and can hit the wrong session after pane reuse; a write
to an fd bound to the session at spawn cannot miss.

It also introduces one, which the design must answer rather than inherit.
Today every injection funnels through the single tmux server process, so
tmux serializes daemon input against user keystrokes for free. Here the app
and the daemon hold separate fds to the same master, and a `write()` to a tty
is not atomic — so a daemon injection landing mid-keystroke can shear. The
sharp case is bracketed paste: user bytes arriving between `ESC[200~` and
`ESC[201~` are swallowed into the pasted text, and a torn marker leaves the
TUI's paste state desynchronized. Rare, and recoverable by retyping, but it
is a regression against today and it is not acceptable to leave implicit.

Three rules close it, in increasing order of how often they apply.

- **Every injection is one message.** The daemon completes partial writes in
  a loop while holding that session's write lock, so a payload is never
  interleaved with another *daemon* write. A bracketed paste is one message
  including both markers — the framing is never split across a decision.
- **While a viewer is attached, the daemon injects through the app**, over
  the sidecar frames that already carry input for the control-mode path. The
  app is then the session's only writer as well as its only reader, and the
  concurrency simply does not exist. This is the mirror of how reads already
  work: pull from whichever store is live rather than reaching past it.
- **The app is not allowed to become a single point of failure for
  injection.** If it does not acknowledge within a bounded deadline on an
  injected clock, the daemon writes directly.

That last fallback is deliberately fail-*open*, where the read side's
safety rail fails closed, and the asymmetry is the point: an unanswered read
can be resolved by refusing to act on a stale screen, but an unanswered
injection that is simply dropped leaves an agent waiting forever for a prompt
that never arrives.

Its cost is **two** failure modes, not one, and the second is the easier to
overlook. A missing ack does not mean the injection was not delivered — the
app may have written it and had the ack lost or merely delayed, which App Nap
has been measured doing to this app's work for ~90 s. So the fallback can
deliver an injection **twice**, and for a queued prompt acting twice may be
worse than a sheared keystroke. This is the at-least-once versus at-most-once
fork, chosen knowingly in favour of at-least-once: a duplicated prompt is
visible and recoverable, while a silently dropped one strands an agent
indefinitely with nothing to see. **Do not "fix" the duplicate by acking
before writing** — that trades a visible duplicate for exactly the invisible
loss this design rejected, and it will look like a cleanup.

Rule 2 also makes a real deferral policy possible, where the daemon could
never have one. Once the app is the sole writer it is the only process that
sees both streams, so the serialization point is a single in-process queue —
and that queue knows its own bracketed-paste state exactly. A daemon-originated
frame is therefore held while a user paste is open and never lands between its
markers, which is the strongest form of the guarantee rule 1 approximates.
That belongs to the attach work, not here.

Resize follows the reader: whichever process currently reads the master owns
`TIOCSWINSZ` — the app drives it from the view while attached, the daemon
holds the last-known size while detached.

## Detached output and the headless emulator

While no viewer is attached, the daemon drains each session's master into a
headless instance of SwiftTerm's core `Terminal` — the same parser the viewer
uses, so the detached picture and the attached picture can never disagree on
interpretation, and every escape-sequence fix benefits both. This repo's own
history is the argument against a purpose-built minimal parser: the
`ANSIEscape` component missed `CSI <>=`, `ESC 7/8`, and charset switching,
and a `hasPrefix` broke title parsing — the escape-sequence long tail is
precisely what bites.

The emulator keeps a bounded in-memory scrollback (on the order of 10k lines;
a plain constant, not a flag) and is **not persisted to disk**. The constant
is a memory decision as much as a history one: at the design point there are
~150 emulators resident, and a naive per-cell buffer representation across
150 sessions can reach into gigabytes, so the limit must be sized against
SwiftTerm's measured per-line cost at implementation time — and the limit, or
the representation, gives way first if field memory pressure says so.

A daemon restart starts the emulator empty; the jiggle on re-adoption makes
full-screen programs repaint into the fresh emulator, and the durable record
of an agent's work is its transcript, which persists on disk independently of
any terminal. That heal is scoped honestly: it works for programs that
repaint on SIGWINCH. A plain shell prompt, or output that has scrolled away,
repaints nothing — so after a daemon restart such a *detached* session reads,
and later seeds its viewer, as a blank screen until new output arrives, and a
shell has no transcript to fall back on. tmux preserves screen and history
across daemon restarts unconditionally; this design deliberately does not,
trading that for a daemon that is free to restart under live sessions at all.

Rendering terminal state as bytes is a named deliverable of this design, not
an assumed primitive: both the attach-time snapshot preamble and the app's
pull snapshot need a grid-to-escape-stream serializer (screen plus retained
scrollback, emitted as a stream a fresh emulator ingests). It is exercised on
every attach, so it cannot rot unnoticed the way failure-edge-only code does.

### Two stores, reconciled on demand

While a viewer is attached the daemon reads nothing, so its emulator is
frozen for the duration of that attach — and re-seeded from the app's
handback snapshot on an orderly detach. This design accepts that — the
**two-store model** — rather than having the app stream a copy of everything
it reads back to the daemon:

- The app's SwiftTerm is authoritative while attached; the daemon's emulator
  is authoritative while detached.
- When the daemon needs an attached session's screen (supervision, `tbd
  terminal read`), it **pulls a snapshot from the app** over the existing
  RPC; the app serializes its live terminal state on request. A machine read
  therefore reaches whichever store is live, instead of a store that stopped
  being updated at attach. That is a routing guarantee, not a freshness
  guarantee: when the pull cannot be answered, the consumer's declared policy
  below decides, and one of the two policies deliberately returns a stale
  answer.
- The handback is the orderly path only. An app that dies attached hands back
  nothing, so the daemon reverts to an emulator frozen at that attach and
  heals it with the jiggle alone — which repairs programs that repaint on
  SIGWINCH and nothing else. Same scoping as the daemon-restart case above,
  and for the same reason.
- Pulls are bounded (timeout on an injected clock), and every consumer
  declares a failure policy, because the app can legitimately go quiet (App
  Nap has coalesced this app's work for ~90 s in the field, and app-wedged
  correlates with exactly the moments supervision most wants a screen).
  Safety-critical consumers fail closed: the hibernation input-veto check
  treats no-answer as unsafe and refuses to hibernate, never risking typed
  input. Best-effort consumers fall back to the daemon's frozen-at-attach
  emulator, labeled stale, rather than blocking on an unresponsive app.
- Terminal scrollback history has a hole across each attached period (minus
  whatever the kernel buffer held at the edges). This is the accepted cost,
  and it is cheap here specifically: the artifact users actually mine history
  from is the transcript, and the dominant workload is a full-screen TUI that
  manages its own display anyway.

The alternative — the app forwarding every chunk it reads to the daemon so
one unbroken history exists — was rejected because it re-imposes roughly the
tmux parse-everything CPU bill on the loaded machine this design targets
(relocated off the paint path, but standing), to buy a property (gapless
terminal scrollback) that transcripts already provide where it matters. See
Rejected alternatives.

### The jiggle

Whenever the reader changes — attach, detach, app death, daemon re-adoption —
the incoming reader briefly wiggles the tty size (grow one column, restore)
to force a SIGWINCH, so full-screen programs repaint into the reader's
emulator. This is iTerm2's `WinSizeController` "jiggle", wired here to every
handoff edge rather than only orphan adoption (in iTerm2 the plain reattach
path gets no jiggle, and its resize ioctl is guarded by only-if-changed, so
the common same-geometry reattach heals nothing — a gap, not a choice; see
the companion iTerm2 record). The jiggle heals screen *state*; it cannot
recover missing history and does nothing for scrolled-away output, which is
why it complements rather than replaces the daemon's emulator.

## Feature parity

Everything TBD does through tmux today, and its replacement:

- **Session persistence across app and daemon restarts** — the holder; strictly
  better than today, since attached sessions now also survive daemon restarts
  without interruption.
- **Reattach shows the last screen** — snapshot preamble from the daemon's
  emulator, plus jiggle; scoped by the emulator's lifetime — after a daemon
  restart, a detached session that does not repaint on SIGWINCH (a plain
  shell, scrolled-away output) seeds blank until new output arrives.
- **Input injection** (`tbd terminal send`, queued prompts) — daemon writes to
  its master dup.
- **Machine reads** (`tbd terminal read`, the interactive-login driver, the
  hibernation pending-input rail, the embedded supervision babysitter) — the
  daemon renders its own emulator when it is the reader and pulls a snapshot
  from the app when a viewer is attached. This replaces `capture-pane` with a
  first-party interface, which the no-TUI-scraping rule already pushes
  toward; the three sanctioned scrapers migrate onto it as part of this work.
- **Hibernation and revive** — hibernate instructs the holder to terminate its
  child (the holder reports status and exits); revive spawns a fresh holder.
  The input-veto and queued-prompt flags keep their semantics, now gating
  daemon writes to the master instead of tmux `send-keys`.
- **Scrollback** — bounded emulator history while detached, SwiftTerm's own
  history while attached, transcripts as the durable record. tmux's 50k-line
  retention is not matched and deliberately so.

### Out of scope, structurally

- **External attach from another terminal emulator** is not carried forward.
  It existed only as a diagnostic and is being unshipped independently of
  this design.
- **Remote or ssh attach** cannot exist in this design: the interface is a
  file descriptor, and a file descriptor cannot cross a machine boundary.
  Every system in the survey that dropped a mux server also dropped this, on
  purpose. If remote viewing is ever wanted it is a separate streaming
  feature, not a holder feature. Sessions on remote hosts keep whatever
  transport they have today; this migration is local-machine only.
- **Survival of reboot or GUI logout** — not provided, exactly as today.

## Reconciliation

Per the named-reconciler doctrine, the new durable resources are the holder
processes, their socket and lock files, and (transitively) the agent processes
under them. Orphans can arise because holder creation is non-transactional against
the process table — the same argument as every other resource here.

- **`WorktreeLifecycle+Reconcile`** swaps its ground truth from tmux windows
  and servers to the **holder inventory**: enumerate holder sockets under the
  sessions directory, connect, and handshake (yielding holder pid, child pid,
  child status, and launch parameters). A session row with no live holder is
  marked exited through the existing handling — and specifically as **status
  unknown**, never a fabricated `0`. This is the durable landing place for the
  case the holder's Lifetime contract describes: a daemon that was down through
  the holder's whole report timeout comes back to a vanished holder and an
  unreported status, and the sweep must record the absence rather than invent
  a value. A **rejected** connection is
  the opposite of a dead holder — the holder is alive and owned by another
  daemon (a stale daemon from a different checkout is a known hazard on a
  development machine) — and must never feed the exited path. **A rejected
  connection is terminal for this sweep in both directions**: not exited, and
  not killed either — a holder that will not talk to us is left alone and
  logged, never reclaimed on the theory that it has no row.

  **A completed handshake is proof of liveness, not of ownership**, and only
  ownership licenses a kill. Two installations can share a holders directory —
  the default `TBD_HOME` is shared by every checkout on a machine — so
  "reachable and absent from *my* database" is exactly the shape a foreign but
  perfectly healthy session presents. The holder therefore carries an **owner
  token**, given at spawn and returned by every handshake: a UUID minted once
  per installation and persisted in the `config` row. It identifies the
  installation rather than the process, so it survives daemon restarts — a
  token that did not would strand a daemon from reclaiming the holders it
  spawned a moment earlier, which is the common case, not the exotic one. The
  sweep kills only a holder whose token matches its own; a mismatch is left
  alone and logged, exactly like a rejection. Only a holder that handshakes,
  proves the same owner, and still has no session row is a half-finished
  deletion, and that is the case where the daemon kills the child and the
  holder.

  **Row-lessness is only meaningful once creation can no longer be in flight.**
  Reconcile runs on demand from RPC handlers, not only at startup, so it can
  land in the window between a holder becoming connectable and its session row
  committing — and killing there would destroy a session that was merely being
  born. Two things close that window, and both are required. Creation **commits
  the session row before the holder becomes discoverable**: the row is written
  in a creating state first, and only then is the holder spawned, so a
  discoverable holder always has a row unless something failed. And the sweep
  is **keep-biased for young holders** — a holder whose socket is newer than a
  grace window is left alone regardless of row state, the same guard `OrphanGC`
  already applies to the same race shape. Ordering alone would be enough if
  nothing ever crashed between the two steps; the grace window is what makes
  the guarantee hold when something does.
  **Kill, not adopt** — iTerm2 adopts unclaimed survivors into new tabs
  because its live processes are the only copy of anything; TBD's transcripts
  persist independently, so adoption would buy a mystery-session UI and
  little else, and it cuts against the database-is-intent model the other
  reconcilers already follow.
- **`OrphanGC`** (hourly, gated on `gcEnabled` as today) gains two sweeps:
  unlink socket files (and their sibling lock files) with no listening
  process behind them, and re-run the holder-versus-database check between
  startup reconciles. The socket sweep is mandatory, not hygienic: a
  SIGKILLed holder cannot unlink its own socket, and the tmux precedent on
  this machine was ~7,100 dead socket files, because tmux unlinks lazily on
  rebind and nothing ever rebound. The lock file leaks only as an empty
  file — the kernel released its lock when the holder died — so it is swept
  for tidiness on the same pass rather than needing its own reclaimer.
- **`AgentReaper`** gains a holder-transport leg. Its existing sweep
  enumerates children of tmux server pids and structurally cannot see a
  child re-parented to launchd, so for holder-transport sessions it sweeps by
  each session's **recorded child pid** (captured at spawn and refreshed at
  adoption), verifying process identity (executable and start time) before
  killing, and reaps children whose session row is exited or absent. This is
  the backstop for holder deaths the daemon was down for; the prompt path is
  the daemon's own holder-connection watch ("Holder death" above).

## Rollout

This wholesale-replaces a load-bearing path, so it ships behind a default-off
flag with a soak and a stated graduation plan.

- **Flag.** `pty_holder_enabled`, a `config` column added by a `.sql`
  migration with **no SQL `DEFAULT` clause**, so unset stays a third state.
  The shipped default is `false`, resolved the way every other nullable gate
  in `ConfigRecord.toModel(...)` resolves one: a `ptyHolderDefault: Bool =
  Config.ptyHolderDefault` parameter on `toModel`, and `pty_holder_enabled ??
  ptyHolderDefault` in the body. The injected parameter is not decoration —
  it is what lets a test change the effective default and prove NULL follows
  it while an explicit `0` does not. Tests cover all three states: a
  pre-migration row reads NULL rather than `0`, NULL follows the injected
  default, and an explicit `0` survives a change to it.
- **Granularity: spawn time only.** A session records its transport (`tmux`
  or `holder`) in its database row at creation and keeps it for life; the app
  attaches by whichever transport the row names. Flipping the flag never
  migrates a running session — the fleet converges as sessions naturally end
  and respawn. Live migration (extracting a pty from a running tmux server)
  is rejected; see below.

  The flag therefore gates **spawning, not servicing**: the flag is consulted
  only when a session is created, and both transports' machinery (attach
  paths, the daemon's arbitration and drain, each reconciler's ground-truth
  sweep) runs whenever any session row of that transport exists, regardless
  of the flag's current value. Toggling in either direction strands nothing:
  off → on leaves every running tmux session on tmux and routes only new
  spawns to holders; on → off leaves every running holder session on its
  holder and routes new spawns back to tmux.
- **Coexistence cost, stated honestly.** Both paths live until graduation:
  two reconciliation ground truths, a doubled test surface, and — counted
  accurately — a **third** attach path in the app, not a second. The app
  already carries two: the older one forks a `tmux attach` client per viewer
  and lets SwiftTerm read that client's pty, and the control-mode one feeds
  SwiftTerm bytes the daemon relays over the FD sidecar. The holder path joins
  them. That the count is three is an argument for graduating and deleting
  promptly, not against the design — and the control-mode path's fd-in,
  `feed(byteArray:)`-out shape is the closest existing seam to what the holder
  transport needs, so the third path is cheaper than the second was. Each
  gated branch gets tests for flag-on and flag-off behavior.
- **Soak.** Enable on a development machine running a real fleet at real
  load. Ordinary development restarts exercise the re-adoption path
  continuously — the hardest code in the design gets adversarial testing for
  free. Graduation gates on field evidence: no double-reader violations, the
  reconcilers holding (no growth in unclaimed holders or socket litter), and
  latency flatness re-confirmed under load by re-running the keystroke-echo
  measurement whose methodology the companion research record documents.
  That harness is a **deliverable of this work, not an existing tool to lean
  on**: `scripts/diag/` today holds only a commit-latency report and an
  RPC-volume report, neither of which measures keystroke echo. A design
  justified by a latency curve has to ship the committed probe that can
  re-draw that curve on demand, or graduation is a judgement call rather than
  a measurement.

  **"No double-reader violations" is only evidence if something can see one.**
  A double read is silent by construction — each `read()` takes bytes the other
  reader never sees — so an absence of reports is not an absence of the fault,
  and gating the design's central safety property on unaided observation would
  be the weakest step in the argument. Two positive detectors carry that bar
  instead. An always-on **reader-count assertion**: the daemon holds explicit
  per-session reader state, and every transition into reading asserts the count
  was zero, incrementing a violation counter and logging loudly rather than
  trusting the arbitration to be correct. And a soak-time **continuity
  canary**: a known sequence written periodically to a session, whose reader
  checks it arrives unbroken — a gap is byte theft, positively observed rather
  than inferred. Graduation reads those two numbers.
- **Graduation.** Flip `Config.ptyHolderDefault` to `true` — a one-line
  change that reaches everyone who never chose while preserving every
  explicit opt-out. Removing the tmux path entirely is separate, later work,
  undertaken once no `tmux`-transport session rows remain in the wild.

New delays introduced by this design — the re-adoption grace window, the
holder's exit-report timeout, any handoff ack timeout — take an injected
clock (`clock: any Clock<Duration> = ContinuousClock()`), per the repo rule.

## Relationship to the build-isolation work

Issue #720 (isolating development builds from the production daemon, tmux
server, and database) interacts with this design in both directions: it
reduces how often the production daemon restarts, shrinking one window the
holder covers, while the holder makes daemon restarts nearly free for live
sessions, shrinking the pain that motivates it. The two are deliberately
**independent, with no ordering dependency**: whichever lands first makes the
other somewhat less urgent, nothing in either design assumes the other, and
re-scoping #720 is that issue's own decision, not this spec's.

## Learnings from iTerm2

iTerm2 is the shipping precedent for the core of this design, and its source
is a catalogue of paid-for lessons. **Implementers and reviewers of this work
should read the companion record
[`iterm2-session-restoration.md`](../research/2026-08-30-terminal-session-persistence/iterm2-session-restoration.md)
and consult the iTerm2 source before re-deriving any of the following**, each
of which is carried into this design:

- **The fd rides on a one-byte `sendmsg`.** `sendmsg` with an `SCM_RIGHTS`
  control block has been observed failing with `EMSGSIZE` at payload sizes
  the man page permits, and an empty payload fails too; iTerm2 caps the
  fd-carrying message at exactly one byte and sends the rest with a plain
  `write()` — and never re-sends the fd on a short write, or the recipient
  materializes duplicate descriptors. TBD's existing FD sidecar already
  navigates fd-number recycling; the holder protocol adopts the one-byte
  convention as well.
- **Reads on the fd channel must be serialized by construction** — exactly
  one method may read after the handshake, or interleaved partial reads
  corrupt the stream.
- **Creation races are settled by an advisory lock file** held for the
  server's whole life — adopted verbatim, and specified under "Creation is
  serialized by an advisory lock" above. Connecting to a *busy* server is a
  separate problem with a separate answer: accept-then-reject with a sentinel
  version.
- **SIGHUP is not enough on user-initiated close.** A supervised child can
  ignore SIGHUP, leaving the supervisor alive to be adopted later; closing a
  session must make the holder forget the child (close the master, stop
  reporting) and then kill, which is why the protocol carries a forget verb.
- **`sun_path` shapes the feature.** Check the socket path length before
  every bind and connect; keep the rendezvous directory shallow.
- **`setsid()` in the supervisor is load-bearing**, and SIGHUP/SIGPIPE must
  be ignored, or a crash of the spawning process (or a `sendmsg` into a dead
  peer) takes the supervisor with it.
- **The jiggle exists and works** — and iTerm2 wires it only to orphan
  adoption, leaving its common reattach path unhealed behind an
  only-if-changed resize guard. This design wires it to every reader
  handoff.
- **Content and process persist on different clocks** unless something keeps
  the detached picture current. iTerm2 saves screen contents only on losing
  focus and at clean quit, so a crash restores a screen as stale as the last
  click away, with no banner admitting it. The daemon's always-on drain is
  this design's answer; the residual skew (the attached-period scrollback
  hole) is accepted and documented above.

## Rejected alternatives

- **Keeping tmux and sharding servers more finely.** Measured: a busy server
  against a private one-pane server differed by 34.1 vs 36.5 ms p50 under
  load — pane count per server is not the lever; the wakeups are.
- **The daemon holds the masters itself (no holder).** A daemon restart is
  precisely one of the windows persistence exists to cover, and on a
  development machine the daemon restarts constantly. The holder exists to
  make the daemon boring to restart.
- **Per-repo or global holders.** A global holder is a single crash away from
  SIGHUPing the entire fleet and is the one process that can never be
  restarted for an upgrade (the successor-spawn fd-inheritance dance is the
  known workaround, and it is surgery). Per-repo shrinks but keeps both
  problems and adds child-table multiplexing to the protocol. Per-session
  makes blast radius one session and upgrade a non-event.
- **The holder drains its own pty (headless emulator in the holder).** Every
  minimal-supervisor precedent (shpool, zmx, the Zed proposal) puts the
  emulator in the persistent process — but each of those has no other
  persistent process. TBD has an always-on daemon, so putting the emulator
  there keeps the holder near-featureless and makes the crashiest, most
  frequently updated code freely restartable and upgradable. The residual
  window — daemon and app both dead — blocks writers without losing data and
  is bounded by daemon supervision.
- **The app streams attached-period output to the daemon for one unbroken
  history.** Rejected as a standing per-byte tax (roughly tmux's parse bill,
  relocated) on exactly the loaded machine this design targets, purchasing
  gapless terminal scrollback that transcripts already provide where it
  matters. The two-store model with pull-on-demand keeps machine reads
  current at zero steady-state cost.
- **State handback at detach** (the app serializes its full terminal state to
  the daemon when it detaches). Its worst case sits on the worst edge: an
  app crash is a detach with no handback, leaving both a permanent history
  gap and a stale emulator resuming mid-stream, and it requires a full
  SwiftTerm state export/import surface exercised only at failure time.
- **A purpose-built minimal VT parser.** The `ANSIEscape` scar tissue is the
  refutation: the escape-sequence long tail is where the bugs live, and a
  second interpretation of the stream can disagree with the viewer's.
  Likewise **a third-party headless VT** (e.g. libghostty-vt): well-tested,
  but a new dependency and a second interpretation; SwiftTerm headless gives
  one parser for both pictures.
- **Persisting the daemon's emulator to disk.** Buys a cold-restorable
  picture across daemon crashes at the cost of a write cadence, a file
  format, and a new durable resource needing a reclaimer — for a screen the
  jiggle heals and a history the transcript already holds.
- **Live-migrating running sessions between transports at flag flip.**
  Extracting a live pty from a tmux server is ptrace-grade surgery with no
  payoff; sessions converge to the new transport as they naturally recycle.
- **Adopting unclaimed holders into the UI** (iTerm2's orphan adoption).
  TBD's database records intent and its transcripts survive independently; a
  row-less holder is a half-finished deletion, not a treasure, and adoption
  UI is real complexity.
- **Predictive local echo (the mosh approach) instead of removing tmux.**
  Prediction speculates only about the echo of the user's own printable
  keystrokes; it does nothing for program output, scrolling, or a
  full-screen TUI repainting — which is most of what a fleet of streaming
  agents shows. It is a complement to a fast path, not a substitute.
