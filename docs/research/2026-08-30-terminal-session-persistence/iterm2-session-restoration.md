# How iTerm2 makes terminal sessions survive an app restart

**Status:** Research only. No design, no spec, no implementation.

**Source read:** 2026-08-30, against the iTerm2 source tree at commit
`1dc93ca3`. Every claim about iTerm2 cites `file:line` in that tree, so a reader
can check it without re-deriving. Paths are relative to the root of the iTerm2
checkout.

**TBD code read:** the same day, against this worktree. Claims about TBD cite
`file:line` here.

**Not recoverable from this checkout:** the checkout's git history begins at a
squash (`b3dd6d2b`, "Organize source code into directories", 2026-04-21;
1309 commits total), so commit rationale from the 2015-2020 era — when both the
per-session server and the multi-server were written — is not available. Where
that matters the section says so and falls back to what the code itself states.

## The decision-critical answer

**Once a session is running, the iTerm2 app reads and writes the pty master
directly, through a file descriptor it received over `SCM_RIGHTS`. No session
I/O relays through the server process.** The server is involved at launch and at
attach, and never again for as long as the app stays alive.

The chain, end to end:

- The server calls `forkpty()` and keeps the master fd in its child table
  (`sources/Tasks/iTermFileDescriptorMultiServer.c:201` and `:234`, stored at
  `:143`).
- It hands that master to the app in the `sendmsg()` control message of the
  launch response (`:289-299`) and again, for every surviving child, in each
  `ReportChild` message during the attach handshake (`:415-424`). Both go through
  `iTermFileDescriptorServerWriteLengthAndBufferAndFileDescriptor`, which builds
  a `SOL_SOCKET`/`SCM_RIGHTS` cmsg
  (`sources/Tasks/iTermFileDescriptorServerShared.c:229-252`).
- The app pulls the fd out of the received cmsg
  (`sources/Tasks/iTermFileDescriptorMultiClient.m:1240-1246`), the protocol
  parser routes it to `launch.fd` or `reportChild.fd`
  (`sources/Tasks/iTermMultiServerProtocol.c:437` and `:444`), and the child
  object takes ownership: `_fd = report->fd`
  (`sources/Tasks/iTermFileDescriptorMultiClientChild.m:52`).
- That fd is what `PTYTask.fd` resolves to, via the job manager
  (`sources/Tasks/PTYTask.m:158-161`,
  `sources/Tasks/iTermMultiServerJobManager.m:227-230`).
- A dedicated app thread runs its own `select()` over every task's fd
  (`sources/Tasks/TaskNotifier.m:290-342`) and calls `processRead`
  (`:145`), which does `read(self.fd, …)`
  (`sources/Tasks/PTYTask.m:428`). Output goes out through
  `write(self.fd, …)` (`sources/Tasks/PTYTask.m:468`). Window resizes are an
  `ioctl` on the same fd (`sources/Tasks/PTYTask.m:942`).

The server's own event loop selects on exactly three descriptors — a SIGCHLD
self-pipe, the listening socket, and the client's request pipe
(`sources/Tasks/iTermFileDescriptorMultiServer.c:743-747`). The pty master is
not among them. A grep for `masterFd` across the whole server shows it is
stored, sent, and closed, and never read from or written to.

**What this implies for TBD.** The precedent holds: a supervisor process that
merely *holds* pty masters costs zero extra process wakeups on the interactive
path. Persistence and raw-pty latency are not in tension. The supervisor pays
only at launch, at attach, and at child death. Two caveats sit at the end of
this document, in [Implications for TBD](#implications-for-tbd) — the biggest
being that a holder-only supervisor cannot buffer output while the app is gone,
because it never reads the pty.

## Process model

### What owns the pty

One server process per *socket number*, holding many children. The current
design ("multi-server") is a small standalone binary named
`iTermServer-<bundle version>` (`sources/Tasks/iTermServerDeleter.swift:10-18`),
enabled by default (`sources/Settings/iTermAdvancedSettingsModel.m:884`, still
filed under the experimental section) and selected in preference to the older
per-session server whenever it is available (`sources/Tasks/PTYTask.m:87-93`).

The server keeps an array of `iTermMultiServerChild`, each holding the launch
request, the child pid, the pty master fd, and the tty name
(`sources/Tasks/iTermFileDescriptorMultiServer.c:70-77`). It calls `forkpty()`
itself, so it is both the pty master owner and the child's parent, and it reaps
children with `waitpid` off a SIGCHLD self-pipe (`:87-88`, `:444-481`).

Normally there is one server. The app tries socket number 1 and increments on
failure, giving up after five failures (`sources/Tasks/iTermMultiServerConnection.m:116-141`).

### How it is spawned

A single `fork()` from the app, then `setsid()`, then `iTermExec`
(`sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:262`, `:289`). Five file
descriptors are handed over positionally
(`sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:253-259`), and the server
reads them by index (`sources/Tasks/iTermFileDescriptorMultiServer.c:37-48`):
the listening socket, an already-accepted connection to write on, a dead man's
pipe, a pipe to read requests from, and an advisory lock fd.

Three deliberate choices in that sequence are worth naming:

- **It is not daemonized.** A `iTermFileDescriptorMultiServerDaemonize` function
  exists (`sources/Tasks/iTermFileDescriptorMultiServer.c:1032-1050`) but is
  compiled out by `const int daemonize = 0`
  (`:1063`). The comment at
  `sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:279-288` explains why:
  tools walk the shell's parent chain up to the app, so the server must remain
  the app's child. When the app exits, the server is reparented to launchd like
  any orphan; nothing in the source arranges that, it is just Unix.
- **`setsid()` is what detaches it.** Same comment: without it, an app launched
  from a terminal shares that terminal's foreground process group, so a `^C` to
  the app also kills the server, and the sessions become un-reattachable. The
  comment also notes `setsid` is async-signal-safe, which matters between fork
  and exec.
- **SIGHUP is ignored** — "We get this when iTerm2 crashes. Ignore it."
  (`sources/Tasks/iTermFileDescriptorMultiServer.c:945-951`). SIGPIPE too, so a
  `sendmsg()` into a dead app does not kill the server (`:1070`).

Because the server is an ordinary child, the app has to reap it. It installs a
`DISPATCH_SOURCE_TYPE_PROC` / `DISPATCH_PROC_EXIT` source that `waitpid`s and
logs the exit status, on the grounds that a server death takes down every
session on that connection and this is the only place that learns why
(`sources/Tasks/iTermFileDescriptorMultiClient.m:932-958`).

### The server the multi-server replaced

The older design ("mono-server") is still in the tree and still used whenever
the multi-server is unavailable. It is a different shape in three ways:

- **One server process per session, not per app.** The app re-execs *its own
  binary* as `iTerm2 --server <program> <args>` (`sources/Tasks/PTYTask.m:272-287`),
  which `main` dispatches into `iterm2_server`
  (`sources/AppKit/main.m:39-41`, `sources/Tasks/legacy_server.c:217-262`). Each
  such server carries the whole app binary's image and supervises exactly one
  child (`sources/Tasks/iTermFileDescriptorServer.c:18`).
- **Its rendezvous lives in a shared world-writable directory.**
  `/var/tmp/iTerm2.socket.<pid>` (`sources/Tasks/iTermFileDescriptorSocketPath.c:69-72`),
  chosen deliberately over `/tmp` and `$TMPDIR` because those get swept; the
  long comment at `:34-63` records the reasoning. The consequence is a security
  problem the multi-server does not have — see
  [Failure modes](#failure-modes-and-hard-won-details).
- **It survives GUI logout on purpose.** Before forking, it moves itself from
  the per-session Aqua Mach bootstrap namespace up to the per-user one
  (`sources/Tasks/legacy_server.c:189-215`, an extensively commented fix for
  what the comment calls issue 4147). The multi-server does the opposite: it
  polls its bootstrap port and quits cleanly when it goes dead, precisely
  because a logout leaves it "unusable"
  (`sources/Tasks/iTermFileDescriptorMultiServer.c:989-1004`).

**Why the change happened** is not recoverable from this checkout's history.
The only statement of purpose in the tree is the advanced setting's own
description — "A new implementation of session restoration that combines daemon
processes" (`sources/Settings/iTermAdvancedSettingsModel.m:884`) — and the
structural differences above: one process instead of one per session, a
purpose-built standalone binary instead of a re-exec of the whole app, and a private
per-user directory instead of a shared one. One further difference is stated in
a code comment: killing modes differ because "Monoserver needs to ensure the
server dies even when the child is persistent, but multiserver can survive its
children" (`sources/Tasks/iTermMultiServerJobManager.m:557-559`).

The lifetime rule follows from that: a multi-server exits when it has no
reportable children *and* no client
(`sources/Tasks/iTermFileDescriptorMultiServer.c:864-868`), unlinking its socket
on the way out (`:1052-1060`).

## Rendezvous and reattachment

### Where the socket lives

`~/Library/Application Support/iTerm2/iterm2-daemon-<N>.socket`
(`sources/Tasks/iTermMultiServerConnection.m:257-286`). If that path will not
fit in `sockaddr_un.sun_path`, it falls back to `~/.iterm2/<N>.socket`
(`:288-315`). The fit test is explicit — `strlen(path) + 1 < sizeof(addr.sun_path)`
(`:249-255`) — and it is load-bearing enough that the entire multi-server
implementation declares itself unavailable when even a synthetic
`pathForNumber:1000` would not fit (`:154-156`), falling the whole app back to
the mono-server.

The socket is bound under `umask(S_IRWXG | S_IRWXO)` so only the owning user can
connect (`sources/Tasks/iTermFileDescriptorServerShared.c:347`), and any
existing file at the path is `unlink()`ed immediately before `bind()` (`:353`) —
which is the whole of the stale-socket reclamation story.

### Proving which server owns which session

Each session's saved arrangement carries a restoration identifier: a dictionary
of `{Type: "multiserver", Version: 1, Socket: <N>, "Child PID": <pid>}`
(`sources/Tasks/iTermMultiServerJobManager.m:21-28`, built at `:293-303`,
parsed back at `:66-89`). Identity is therefore *(socket number, child pid)* and
nothing more.

Pid reuse is not a hazard here, because the pid is only an index into the
server's own child table, never a lookup into the OS process table
(`sources/Tasks/iTermFileDescriptorMultiServer.c:548-555`). A child that has
exited is still in the table, marked `terminated`, and is reported as such — so
the app learns "your process is gone" rather than attaching to a stranger
(`sources/Tasks/iTermMultiServerJobManager.m:466-486`).

### The attach handshake

Connecting is a three-step dance
(`sources/Tasks/iTermFileDescriptorMultiClient.m:178-234`):

1. `connect()` to the socket, non-blocking "so connect can fail fast if another
   iTerm2 is connected to this server"
   (`sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:64-68`).
2. Read the server's first message, whose control data carries the *write end of
   a fresh pipe*; the client uses that for writes and keeps the socket for reads
   (`sources/Tasks/iTermFileDescriptorMultiServer.c:782-818`). The client code
   carries a bare `TODO: why? Unix domain sockets are bidirectional`
   (`sources/Tasks/iTermFileDescriptorMultiClient.m:199`). Nothing in the tree
   explains it.
3. Send a handshake naming the maximum protocol version; the server replies with
   its version, its pid, and a child count, then streams one `ReportChild`
   message per surviving child — each carrying that child's pty master fd
   (`sources/Tasks/iTermFileDescriptorMultiServer.c:505-544`,
   `sources/Tasks/iTermFileDescriptorMultiClient.m:370-426`).

If the connection fails, the client launches a new server and handshakes with
that instead (`sources/Tasks/iTermFileDescriptorMultiClient.m:147-173`).

### How restoration is sequenced around it

The app deliberately does not block window restoration on the server. The order
is: bring up an *empty* window first, then walk the saved arrangement as plain
dictionaries and kick off one asynchronous "partial attach" per leaf session,
then build the real sessions only once those resolve. A session is created
already knowing whether it will adopt a surviving process or launch a fresh one;
there is no state where a session exists but is waiting for an attachment.

The wait is bounded by `timeoutForDaemonAttachment`, default 10 seconds
(`sources/Settings/iTermAdvancedSettingsModel.m:665`). Whichever fires first —
all attaches complete, or the timer — restoration proceeds with whatever
arrived. iTerm2's own write-up of this flow, including the file-by-file map of
the restoration path and the reasoning behind the split, is in the tree at
`docs/session-restoration-and-process-reattachment.md`; it attributes the design
to a wedged-daemon hazard ("if the daemon is not feeling well, it can take
forever") and it matches the code read here.

The synchronous attach still exists but is a `dispatch_group_wait(…,
DISPATCH_TIME_FOREVER)` around the same async path
(`sources/Tasks/iTermMultiServerJobManager.m:373-386`), and is not on the launch
path.

## What is preserved, and what is lost

**Preserved by the server:** the live process, its pty, its controlling
terminal, its tty name, and a copy of its launch request — path, argv, envp,
working directory, UTF-8 flag — which it replays on every reattach
(`sources/Tasks/iTermFileDescriptorMultiServer.c:111-148`, replayed at
`:383-399`, reconstituted app-side at
`sources/Tasks/iTermFileDescriptorMultiClientChild.m:20-58`).

**Not preserved by the server: any screen content at all.** Scrollback, the
current screen, the selection, and the window layout live entirely in the app's
own SQLite database at
`~/Library/Application Support/iTerm2/SavedState/restorable-state.sqlite`
(`sources/StateRestoration/iTermRestorableStateController.m:107-122`). Session
contents are encoded from the live screen into the arrangement under a
`Contents` key (`sources/PTYSession/PTYSession.m:6978-6985`) and read back on
restore (`:2297-2300`).

That database is written when the app resigns active
(`sources/AppKit/iTermApplicationDelegate.m:1272`) and synchronously at
termination (`sources/StateRestoration/iTermRestorableStateController.m:217-230`).
The consequence is a **skew that is structural, not a bug**: after a crash the
*process* is current and the *scrollback* is as of the last time the app lost
focus. The two do not agree, and nothing reconciles them.

**Output produced while the app is dead appears to be lost.** The server never
reads the pty master — it only stores, sends, and closes it. So once the
kernel's tty buffer fills, the child blocks in `write()`, and nothing anywhere
retains those bytes. This is an inference from the absence of any read of
`masterFd` in the server, not from an experiment; it is the single most
consequential difference from tmux, so treat it as high-confidence but
unmeasured.

**Nothing survives a reboot.** There is no launchd job for the server, and its
own daemonize path is compiled out. The socket files persist as ordinary files
in Application Support and are reclaimed lazily by the `unlink()` before the
next `bind()`.

**Nothing survives a GUI logout either,** in the current design: the server
polls its Mach bootstrap port and quits when it goes dead
(`sources/Tasks/iTermFileDescriptorMultiServer.c:989-1004`). The mono-server
went to considerable trouble to survive exactly that
(`sources/Tasks/legacy_server.c:189-215`); the multi-server gave the property up.

## Orphan reclamation

A surviving child that no restored session claims is an *orphan*. iTerm2 has
three mechanisms, all in `sources/Tasks/iTermOrphanServerAdopter.m` except the
last.

- **Self-termination** – a server with no reportable children and no connected
  client exits and unlinks its socket
  (`sources/Tasks/iTermFileDescriptorMultiServer.c:864-868`, `:1052-1060`). This
  is the common case and it needs no external sweeper.
- **Late partial attachments** – results that arrive after the 10 s restore
  timeout are handed to `adoptPartialAttachments:`
  (`sources/Tasks/iTermOrphanServerAdopter.m:246-256`) and opened as fresh
  sessions rather than retrofitted into the window that was meant to hold them.
- **A filesystem sweep at launch** – at construction the adopter asynchronously
  scans for mono-server sockets by name prefix in `/var/tmp` (`:41-55`) and for
  multi-server sockets by the glob `iterm2-daemon-*.socket` in Application
  Support (`:57-84`). After restoration completes it connects to each and adopts
  the connection's `unattachedChildren` — by construction, exactly the children
  no restored session claimed (`:216-239`). Adopted sessions get a default
  profile, a non-activating new tab, and a banner; they recover the process but
  not the arrangement's visual state.
- **A reclaimer for the copied binaries** – the server executable is copied out
  of the app bundle into Application Support, because the auto-updater would
  otherwise delete it out from under a running server
  (`sources/Tasks/iTermFileDescriptorMultiClient.m:829`, copy at `:831-908`).
  That makes the copies a durable resource in their own right, and
  `iTermServerDeleter` is their reclaimer: it deletes every `iTermServer-*` in
  those folders that is neither the current version nor the executable of a
  running process (`sources/Tasks/iTermServerDeleter.swift:43-76`).

Two gaps are worth naming. **The sweep is launch-only** — there is no periodic
reconciler, so a server whose app never comes back keeps running until the next
launch or until logout kills it. And **stale socket files are never actively
removed**; a `SIGKILL`ed server leaves its socket behind until something binds
that exact path again.

## Failure modes and hard-won details

Things in this code that read as scar tissue, each of which would have to be
rediscovered by anyone building the same thing:

- **The fd rides on a one-byte `sendmsg`.** `sendmsg` has been observed failing
  with `EMSGSIZE` at buffer sizes the man page says are fine — the theory in the
  comment is that the control block counts against the limit — and an *empty*
  message fails the same way. So the payload cap for the fd-carrying message is
  set to exactly one byte, and the rest of the message goes out with a plain
  `write()` afterwards
  (`sources/Tasks/iTermFileDescriptorServerShared.c:184-217`). There is a second
  guard immediately after: on a short `sendmsg`, send the remainder with
  `write()` and never re-send the fd, "or it will create multiple file
  descriptors in the recipient" (`:256-261`).
- **Reads must be serialized by construction.** Messages are length-prefixed
  with a 1 MiB cap, and the comment states that exactly one method may call the
  low-level read after the handshake, "otherwise, reads could get intermingled"
  (`sources/Tasks/iTermFileDescriptorMultiClient.m:1126-1127`). Partial reads
  are accumulated in a builder that separately carries the received fd
  (`:1210-1274`).
- **The mono-server's rendezvous directory forces a peer check.** Because
  `/var/tmp` is world-writable with a predictable socket name, a local attacker
  of any uid can pre-create the socket and hand back an attacker-controlled pty
  master. The defense is `getpeereid()` on the established connection, and the
  comment is explicit that the `lstat()` before it is *only* a cheap early
  reject, "inherently TOCTOU with the `connect()` that follows, so do not rely on
  it" (`sources/Tasks/iTermFileDescriptorClient.c:100-130`, the real check at
  `:160-185`). The multi-server client does no such check
  (`sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:37-98`) — it does not need
  one, because its socket lives in a per-user directory.
- **Two apps racing for one server.** Creation is serialized by an advisory
  lock: the app opens `<socket>.lock` with `O_CREAT|O_TRUNC|O_EXLOCK|O_NONBLOCK`
  before binding (`sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:102-118`,
  `sources/Tasks/iTermFileDescriptorServerShared.c:371-384`) and passes the lock
  fd into the server, which holds it for its whole life. A loser of that race
  moves on to the next socket number. *Connecting* to a server that already has
  a client is handled differently: the server accepts and immediately rejects,
  replying with a sentinel "rejected" protocol version and closing
  (`sources/Tasks/iTermFileDescriptorMultiServer.c:701-740`); the client reads
  the version mismatch and treats the attach as failed
  (`sources/Tasks/iTermFileDescriptorMultiClient.m:351-354`). **One client at a
  time, enforced at the server.**
- **`SIGHUP` is not enough on user-initiated close.** Closing a session sends
  `SIGKILL`, not `SIGHUP`, because "we must ensure servers get killed on
  user-initiated quit. If we just HUP the shell then the server won't notice
  until it becomes attached as an orphan on the next launch"
  (`sources/PTYSession/PTYSession.m:3712-3716`). Separately, tearing down a
  `PTYTask` `killpg`s the process group, with a `TODO` admitting nobody
  remembers why `killpg` is used there and nowhere else
  (`sources/Tasks/PTYTask.m:100-106`).
- **Preemptive wait is how a killed session stops being adoptable.** The app can
  ask the server to forget a child before it dies; the server closes the master
  fd and stops reporting the child, so a later reattach cannot resurrect it
  (`sources/Tasks/iTermFileDescriptorMultiServer.c:569-575`, requested at
  `sources/Tasks/iTermMultiServerJobManager.m:563-570`).
- **The restore timeout has an asymmetry.** After the 10 s timeout the
  partial-attachment dictionary is non-nil but missing the slow session, so that
  session launches a *fresh* process while its old one is separately adopted
  into an orphan window. The user ends up with two sessions where they expected
  one, and the adopted one has no scrollback.
- **`sun_path` shapes the whole feature.** Beyond the fallback path and the
  wholesale `+available` check described above, the connect path re-checks the
  length before every `strcpy` into `sun_path`
  (`sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:47-50`), and the mono
  client `assert(0); exit(1)`s rather than overflow
  (`sources/Tasks/iTermFileDescriptorClient.c:142-145`).
- **A leaked descriptor, apparently.** The app creates a dead man's pipe before
  forking the server, passes the write end in as fd 2, and closes the write end
  in both fork branches — but never closes the read end and never selects on it
  (`sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:242`, `:256`, `:270`,
  `:306`). The server's own header comment for that slot says "Do nothing with
  it" (`sources/Tasks/iTermFileDescriptorMultiServer.c:45`). So the mechanism
  looks vestigial in the multi-server — the mono-server does use its dead man's
  pipe, during the handshake read
  (`sources/Tasks/iTermMonoServerJobManager.m:192-196`) — and one descriptor
  appears to leak per daemon launch. This is from reading, not from measurement,
  and an indirect close may have escaped the grep.
- **Liveness checks are lazy.** The bootstrap-port death check only runs when
  `select()` returns (`sources/Tasks/iTermFileDescriptorMultiServer.c:751`), so a
  fully idle server can outlive its session's namespace until something pokes it.
- **A fork/spawn toggle exists for TCC reasons.** `ITERM_FDMS_USE_SPAWN` selects
  `posix_spawn` over `fork` for launching children
  (`sources/Tasks/iTermFileDescriptorMultiServer.c:1027`, `:223-252`), set from a
  "disclaim children" advanced setting
  (`sources/Tasks/iTermFileDescriptorMultiClient+MRR.m:245-250`).

## What iTerm2 does not get that tmux does

Being fair to tmux here matters, because TBD ships a feature that depends on
several of these.

- **No multiplexing and no second viewer.** Exactly one client connection per
  server, enforced by rejecting the second
  (`sources/Tasks/iTermFileDescriptorMultiServer.c:701-740`). Two windows cannot
  show one session; there are no read-only observers.
- **No attach from another terminal emulator, ever.** The wire protocol is a
  private binary format over a Unix socket, and the payload is a pty master file
  descriptor. Only a local process of the same uid can consume it, and only one
  at a time. There is no equivalent of `tmux attach`.
- **No remote or ssh attach.** A Unix socket and a file descriptor cannot cross
  a machine boundary. TBD's external-tmux-attach feature has no analogue in this
  design and could not be built on it.
- **No buffering while detached.** tmux keeps reading the pty and keeps
  `history-limit` lines regardless of whether a client is attached. A
  holder-only server reads nothing, so a detached session's output stops at the
  tty buffer and the writer blocks.
- **No scrollback ownership.** tmux owns the history; here the app owns it, and
  it is only as fresh as the last save.
- **No survival of logout.** tmux survives; this server quits itself.
- **iTerm2 uses tmux anyway, for exactly these cases.** It ships a separate tmux
  control-mode integration with its own job manager
  (`sources/tmux/iTermTmuxJobManager.m`, wired at
  `sources/Tasks/PTYTask.m:315-321` through a read-only fd). The two mechanisms
  coexist; the fd-passing server is not presented as a replacement for tmux.

## How this compares with what TBD already has

TBD already passes file descriptors from daemon to app over a Unix socket with
`SCM_RIGHTS`. The mechanism is in place; what differs is *which* descriptor
crosses and what sits behind it.

- **The channel.** `FDVendingServer` binds a Unix socket, accepts one client at
  a time, and vends descriptors inside length-prefixed frames
  (`Sources/TBDDaemon/Server/FDVendingServer.swift:143-193` for the listener,
  `:255-274` for `send(fd:header:)`). The app side connects, receives, and
  demultiplexes frames on a dedicated thread
  (`Sources/TBDApp/Terminal/FDSidecarClient.swift:48`, `:192-281`). Like
  iTerm2's, it is a one-client channel, and both ends carry careful commentary
  about fd-number recycling and connection-epoch races.
- **The descriptor.** TBD vends **the read end of a per-pane pipe**, allocated by
  the tmux control-mode fanout — not a pty master
  (`Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift:264-266`,
  vended at `Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift:82-96`).
  It is read-only and one-directional.
- **The input path.** Because the vended fd carries no write side, keystrokes go
  the other way as framed `.input` and `.paste` messages over the same socket
  (`Sources/TBDApp/Terminal/FDSidecarClient.swift:117`, `:161`), decoded on the
  daemon's receive thread and routed to the tmux server.

So today, in the steady state, TBD's keystroke path is app → daemon → tmux
server → pty, and its paint path is pty → tmux server → daemon → pipe → app.
The daemon is a process wakeup in both directions, layered on top of tmux's own.
iTerm2's steady-state hop count after attach is zero in both directions.

The gap TBD would have to close is therefore not the fd-passing plumbing — that
exists and is battle-hardened here — but what the vended descriptor *is*, and
which process owns the pty behind it.

## Implications for TBD

Deliberately short, and clearly separated from the research above. This document
is a record, not a proposal.

- **The core hypothesis is confirmed by precedent.** A supervisor that only
  holds pty masters and hands them over by `SCM_RIGHTS` gives restart survival
  at zero steady-state process wakeups. iTerm2 has shipped this for years, on by
  default.
- **The cost is that the app owns the byte stream.** Whoever holds the fd must
  run the `select`/`read` loop and the terminal emulator. TBD already does both,
  on the far side of a pipe.
- **Three tmux properties do not come along:** external attach (which TBD ships
  today), output buffering while the app is gone, and survival of logout. The
  second is the one most likely to be underestimated — a holder-only supervisor
  cannot read the pty without reintroducing exactly the wakeups it was built to
  avoid, so "detached output is lost, and the writer blocks" is intrinsic to the
  design rather than an implementation gap.
- **Content and process persist on different clocks.** iTerm2's scrollback is as
  fresh as the last resign-active save while its processes are current. Any
  design of this shape inherits that skew and has to decide what it means.
- **The durable resources needing a named reclaimer** are the supervisor
  process, the rendezvous socket file, the lock file, and — if the binary is
  copied anywhere — the copies. iTerm2's answers are: self-exit when childless,
  lazy `unlink()` before `bind()`, a launch-time filesystem sweep, and
  `iTermServerDeleter`. Note that it has *no* periodic reconciler, which under
  TBD's own doctrine would be a gap rather than a precedent to copy.
- **Identity binding is weaker there than TBD's would be.** iTerm2 matches a
  restored session to a surviving child by *(socket number, child pid)* carried
  in a saved arrangement. TBD already has stable worktree and pane identifiers
  in its database, which is a stronger basis for the same handshake.

## What could not be verified

- **Why the per-session server was replaced by the multi-server.** The
  originating commits predate this checkout's squashed history. Everything in
  [The server the multi-server replaced](#the-server-the-multi-server-replaced)
  is read off the two implementations as they stand today, plus the advanced
  setting's one-line description.
- **That output produced while the app is dead is genuinely lost.** Inferred
  from the server never reading the pty master. Not observed.
- **That the dead man's pipe's read end leaks in the multi-server path.** No
  close was found by grep across the client, the MRR category, and the header;
  an indirect close would falsify this.
- **Runtime behavior of any kind.** Nothing here was executed, traced, or
  measured. Every claim is a source reading.
