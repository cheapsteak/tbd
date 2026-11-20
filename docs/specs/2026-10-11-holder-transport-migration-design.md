# Moving a session to the pty holder, on request

## Summary

A person can move a session from the tmux transport to the pty holder in place:
same row, same tab, same label and pin, same Claude session id and transcript.
Nothing is extracted from a tmux server, and nothing moves without a gesture.

TBD starts sessions only on the pty holder and no longer drives tmux at all: it
cannot show, send to, park or end a tmux session. A row recorded as `tmux` is
therefore in one of three states, and the migration treats each differently:

- **Parked.** The row is only rewritten; its next wake starts it on the holder.
- **Live, with its tmux server gone.** The session ended with the server. A
  session with a conversation is parked with its identity kept, rewritten and
  woken on the holder; a shell gets a fresh login shell there.
- **Live, with its tmux server possibly still running.** A server an earlier
  build started can outlive `tbd update` until the Mac restarts. TBD cannot
  reach that session, so it refuses to move it and says how to end the server.
  "A live row whose tmux server outlived the update" below is the rule.

A row nobody moved never breaks obscurely: its wake refuses with a reason naming
this migration, and a live row whose server still runs shows a notice in place
of its terminal.

## Why a gesture rather than a behaviour

The transport a session runs on is recorded per row at spawn and kept for life.
Opening every new session on the holder changes what new sessions get; it moves
nothing that already exists. Sessions therefore outlive the code path that
created them, and the last tmux-backed rows outlive the tmux code itself.

Moving a session starts a program: an agent comes back through
`claude --resume` with its conversation intact, and a shell starts fresh. Whether
to start it now is its owner's choice, at a moment they pick, so the migration
is an action, surfaced per session and as a fleet-wide run, and the daemon never
initiates it. Reconcile parks a live row whose tmux server is gone, which keeps
the session resumable, but it never rewrites a transport.

## What it is not

**It does not extract a live pty from a tmux server.** The transport design
rejects live migration, and that stands: a pty whose master is held by a tmux
server cannot be handed to a holder without the server's cooperation, and
nothing in tmux offers it.

**It does not seed the new session with the old screen.** An agent redraws its
own alternate screen on resume, and a shell's scrollback is not worth a
mechanism. The migrated session starts clean.

**It does not end a tmux server.** TBD sends tmux nothing. A session still
running in tmux ends when its owner ends the server or restarts the Mac.

## The mechanic

One session is the unit, and it is a composition of operations that already
exist. The in-place profile swap — park, re-home, wake, one tab, same row, same
session id — is the same shape with a different column rewritten
([spec](2026-09-22-holder-in-place-profile-swap-design.md)).

- **A parked session** is only rewritten. Nothing is running, so there is
  nothing to stop and nothing to respawn; its next ordinary wake lands on the
  holder.
- **A live session whose tmux server is gone, with a conversation to resume** —
  Claude, or Codex with a recorded thread — is parked with its identity kept,
  rewritten, and woken. The park is the one reconcile makes for the same row
  (`.recovery`). The wake is the ordinary one: everything above the wake path's
  single transport branch is transport-independent — profile, environment,
  settings overlay, trust seed, transcript sync, and the `claude --resume` argv
  — so the migrated session resumes through the same code any other wake uses.
- **A live session whose tmux server is gone, with nothing to resume** — a shell
  — gets a fresh login shell on the holder in the worktree's own directory,
  recorded in one guarded write. There is no conversation for a park to keep.
- **A live session whose tmux server may still be running** is refused with
  `tmux -L <server> kill-server` and the advice that goes with it.

The probe comes first for a live row, before anything else is decided about it:
nothing about a session still running in tmux can change until tmux has
stopped. The holder-unspawnable refusal comes before any park, so a refusal
never leaves a parked row behind.

### The writes are compare-and-sets, not a lock

The rewrite is the sibling of `TerminalStore.setParkedProfileID`: it changes the
row only while the complete launch state the caller observed is still current,
so a wake or a replacement that wins the race rejects the write atomically
rather than leaving the row naming a transport its process is not on. The park
of a live row is a compare-and-set against the row as the migration read it, in
the same way. No new claim or lock is introduced.

### The park stops nothing

The live-row park runs only once the server is positively gone, and with it
every process the server ran. It therefore judges no live rail — there is no
turn in flight to interrupt and no transcript being written — and its reason is
`.recovery`, the reason reconcile records for a session nothing can reach. The
row's recorded activity is not consulted either: it describes a session that
ended with its server, so a "working" state there is stale and would refuse a
move that interrupts nothing.

## A live row whose tmux server outlived the update

TBD has started sessions only on the pty holder since 2026-11-14. A tmux server
started before then keeps running across `tbd update` — tmux has no reason to
exit when its client goes — until it is ended or the Mac restarts. Its rows read
live, and nothing in TBD can reach their sessions.

**The probe.** For each live tmux row the daemon reads two signals, and runs
no tmux binary for either. The server is gone only when both say so.

- **The socket.** The daemon tries a plain `AF_UNIX` `connect()` to each place
  it can find the row's tmux socket, `<directory>/tmux-<uid>/<server>`, and
  closes each socket at once. tmux takes the directory from `TMUX_TMPDIR`,
  reads the value as one path, and resolves it with `realpath(3)`. When the
  resolve fails (a missing directory, or a `~/` path, which tmux does not
  expand there) tmux falls back to `/tmp`, which resolves to `/private/tmp`,
  without a word. So the candidates are this
  daemon's `TMUX_TMPDIR`, resolved against its working directory, when it
  resolves, and always `/private/tmp`. This signal says gone only when every
  candidate is positively absent: `ENOENT` (nothing bound) or `ECONNREFUSED`
  (bound, nothing accepting). Any other answer from any candidate — success
  included, and a path too long to try — means the server may be running. The
  errno rules are `HolderRegistry.exitProbeOutcome(for:)`'s, the one place
  every socket probe in the daemon reads them.
- **The process table.** A tmux server keeps the command line of the client
  that started it, `tmux -u -L <server> …`. This signal says gone only when the
  process table was read and no live tmux process of this user names the
  server with `-L` in its argv (from `KERN_PROCARGS2`). The argv is read as
  tmux's `getopt` reads it, so `-L <server>`, `-L<server>` and a cluster such
  as `-uL <server>` all count.
  - **Which processes are tmux** – a process is tmux when its kernel command
    name (`p_comm`, from the same `sysctl(KERN_PROC_ALL)` read that lists the
    table) or the last component of its executable path (`proc_pidpath`) is
    `tmux`, or is the name of the binary saved in `tmux-executable-path` under
    the TBD home, which can be any name; the probe reads that file itself, and
    a saved link counts under both its own name and the name it resolves to.
    A missing, unreadable or blank file adds no name. The kernel cuts a
    command name to 16 bytes (`MAXCOMLEN`), so the saved name is cut the same
    way before it is compared, and the two are compared as bytes: a cut can
    split a character, and the kernel keeps the split bytes as they are. The
    command name is what matters when a package manager upgrades tmux: it
    deletes the old version's binary, a server started from it keeps running,
    and `proc_pidpath` fails for that server from then on, while its command
    name stays `tmux`. The path covers a binary started through a link of
    another name.
  - **Whose** – "this user" is the daemon's `getuid()`, compared with each
    process's real user id (`p_ruid`, from the same table read). tmux keeps
    each user's sockets under `tmux-<uid>`, so another user's tmux cannot be a
    server this user's rows name, and nothing more is asked of it; the kernel
    would refuse its argv to a daemon that is not root, and an unreadable argv
    would otherwise keep every server running for as long as that user's tmux
    runs.
  - **What counts as running** – one of this user's tmux processes whose argv
    cannot be read counts as running for every server, and so does a process
    table that cannot be read.

The socket cannot settle it alone, because its candidates are only as good as
the environment and working directory they come from, and those are this
daemon's, not necessarily the ones of the daemon that started the server.
Daemons start from different places: `tbd update` with the shell's
environment, `scripts/restart.sh` with the worktree as its working directory,
and the app's fallback launch with the LaunchServices environment, usually
without `TMUX_TMPDIR`, from `/`. A server started under a `TMUX_TMPDIR` the
current daemon does not have listens where no candidate looks, and only its
command line still names it. The command line covers one more case the socket
cannot: Darwin answers `ECONNREFUSED` at once when a listener's accept backlog
is full, the same answer a stale socket gives, and the server's process still
names it then. The process table is read only when every socket is absent,
because a socket that answers settles it (`LeftoverTmuxServerProbe`).

The asymmetry is deliberate. Parking a row whose agent still runs lets a later
migration and wake start a second agent on the same session id, beside the one
tmux still holds. Leaving a dead server's row live costs a notice and a click.

**Gone.** The row is parked with its session id kept, reason `.recovery`, and
from there the ordinary path moves it: its wake refuses and names
`tbd terminal migrate`, the migration rewrites it, and a wake opens it on the
holder. A live tmux row with nothing to resume — a shell, a hook tab, an agent
tab whose session never began — is deleted by reconcile, as any unreachable
non-resumable row is. Check Again refuses it plainly: tmux has stopped, and the
tab had no conversation to keep, so close it. A migration still moves a shell,
as a fresh one on the holder.

**Running.** The row stays live. The app shows a notice in place of the
terminal: the session is still running in tmux, which this version of TBD can
no longer show; `tmux -L <server> kill-server` ends it, along with the repo's
other tmux tabs, since one server carries them all; restarting the Mac ends it
too; and Check Again looks again, after which a tab with a conversation is
parked and a tab with none can be closed. Every request that would have to
reach the session — a view, a send, an output read, a wake, a park, a
migration — refuses with the same advice and the `terminalOnTmux` error code
(`LeftoverTmuxSession`). The app derives the notice from the row it already
holds — `transport == .tmux` and not parked — and the server name from the
worktree's `tmuxServer`, so no model field is added.

**Closing.** Closing a tmux row's tab deletes the row and runs no tmux
command, and so do archiving or forgetting its worktree, deleting or archiving
a scratch space, and reconcile's archive of a worktree gone from git. Each is
recorded as dispatched. What else happens depends on whether the row was
parked:

- **Live** – the session keeps running in its server. The daemon logs a notice
  naming the server and `tmux -L <server> kill-server`, and the notice in the
  app says that closing the tab leaves the session running in tmux. A row with
  a session id gets a Closed Terminals entry with no screen, marked with the
  server (`TerminalHistoryEntry.liveOnTmuxServer`): the conversation stays
  resumable from it like any other closed tab's, and the mark makes every
  resume of that session id ask first (below). A row
  with no session id has nothing to resume and no screen to keep, so it gets
  no entry. Its session directory is left for `OrphanGC`.
- **Parked** – the session ended when the row was parked, so its Closed
  Terminals entry carries the screen the park stored, and no mark.

Either entry is written on every one of these paths but two, which remove
every entry the worktree had: forgetting a worktree and deleting a scratch
space. Nothing in TBD names the session after those.

`terminal.delete`'s activity rails apply to holder rows only: closing a tmux
row ends no process, so there is no turn in flight to protect.

**Resuming a session a tmux row carries.** A session a tmux row carries, or a
deleted live tmux row carried, may still be running in that row's server, and
starting it on the pty holder would put a second agent on the same session id.
The open row's tab says its session is still on tmux, but the History pane lists
the same session, and its Resume reaches the session by id, not through the row.
So every start of an existing session looks its id up first, across every
worktree (`TmuxResumeGate`), in two places: the tmux rows whose session may
still run, whose server is their worktree's, and the marked Closed Terminals
entries. A tmux row's session may still run while the row is unparked, and
while a park is in flight (`pendingSessionIncarnationID` set). An earlier
build's tmux hibernate recorded the park and signalled the agent before it
respawned the window, and left the park in flight when the respawn failed, so
the agent may still be running behind such a row. A parked tmux row with no
park in flight is no reason to ask, since its session ended when it was parked.
A session neither names starts without more: one read of each of two indexes,
each holding only the rows it can match, which is all a wake of a parked holder
row pays. For each server they name, the start asks the probe.

- **Running** – the start refuses with `terminalOnTmux` and the same ending
  advice, `tmux -L <server> kill-server` or a restart, then try again. Nothing
  is written: every record, tmux row and mark included, stays as it was, so the
  same request succeeds once the server is gone.
- **Gone** – the start goes ahead on the holder with the session id. The tmux
  row or mark stays, and a later start of the same id asks again; a server that
  is gone stays gone, so the answer does not change.

The question is asked where every new row on a session starts,
`WorktreeLifecycle.spawnTerminal`. That covers a revive's relaunch of its
archived tabs, the History pane's resume (`session.resume`, and `terminal.create`
with a session to resume), a Closed Terminals reopen of a Claude entry, and a
fresh-branch revive of a Codex thread. A wake starts a session in an existing
row, so `HibernationCoordinator.wake` asks the same, and a refused wake leaves
the row parked. A profile change applied in place replaces the holder process of
a row that is already running its session and starts no second agent, so it
asks nothing. Neither does a spawn that forks a Claude session
(`spawnTerminal`'s `forksSession`): a profile switch's fork tab, a carryover
into a new worktree and a fresh-branch revive of a Claude conversation start
with `--fork-session`, or the fork tab with a fresh session, so each writes a
new session id and puts no second agent on the one it names. A Codex
carryover resumes the thread itself and asks.

A request that writes before it reaches `spawnTerminal` asks before its first
write as well:

- **A revive in place** – keyed by every archived tab it would relaunch and the
  History pane's preferred session, the whole revive refuses before it records
  the restore plan or re-adds the checkout, and the worktree stays archived. A
  revive that skips the agent tabs relaunches none, so it asks nothing.
- **A fresh-branch revive of a Codex thread** – before the new worktree
  exists.
- **`terminal.create` resuming a session**, which `session.resume` reaches, and
  **a Closed Terminals reopen of a Claude entry** – before the trust seed, the
  transcript sync and the spawn record.

Each of these RPCs answers a refusal with the code and records the act as
refused, `not-eligible`.

The gate is keyed by session id rather than by row or worktree, because the
requests that resume a session reach it from different records: an archived
tab, the History pane's session list, a Closed Terminals entry. The session id
is what they share, and the tmux row or mark that names it may sit in any
worktree. An open tmux row needs no mark: the row names the session, and its
worktree names the server. Archive keeps a live tmux row's tab in the
worktree's archived record like any other tab, because a revive brings every
tab back on the pty holder, and the mark on the tab's entry is what makes that
revive ask. Reconcile's archive of a worktree gone from git records no archived
tabs, and closing a tab records none at all, so the mark lives in the one
record every close writes. A marked entry sits outside the newest-50 cap on a
worktree's Closed Terminals, since pruning it would drop the mark while the
session may still be running.

**When it runs.** Reconcile probes once per server name per pass, wherever it
runs: at daemon startup, on demand (`tbd cleanup`, a repo add), and on a timer —
the hourly orphan maintenance (`Daemon.performOrphanMaintenance`) runs
`reconcileScratchTerminals`, which probes the servers of scratch worktrees'
live tmux rows, and like the rest of that pass it answers to the GC switch.
Check Again is `terminal.recreateWindow`, which probes the row's server and
parks the row once it is gone. A migration probes the row it is asked to move,
and a start of an existing session the servers named by its marks and by the
tmux rows whose session may still run.

**This probe is a transition measure; on 2027-01-15 it is replaced by parking
on sight.** No tmux server started before 2026-11-14 should still be running by
then, so a live tmux row can be parked without asking. The resume gate goes the
same day, for the same reason: no session a tmux row or a mark names can still
be running, so such a session starts like any other.

## What migrates, and what is skipped

- **Agents migrate through `--resume`** on the session id the row records, the
  same argv a wake builds. A Codex tab with a recorded thread migrates the same
  way: the rewrite keeps its thread id and recorded launch options (model,
  disabled features, dedicated home), from which the holder wake prepares
  Codex's resume.
- **Shells migrate plainly** — a fresh program in the same working directory,
  recorded in one guarded write that moves the transport, blanks the tmux
  coordinates, records the holder's processes and clears the dead process's
  session and activity facts together. The replacement carries a freshly minted
  incarnation, so a hook from it is attributable to it. A shell tab whose row
  carries a session id — what `SessionStart` leaves for a Claude started by hand
  inside it — is still a shell, and moves as one.
- **Four rows that name no conversation are skipped rather than moved, each with
  its own reason.** For these the move available would start a bare login shell
  where something else belongs, so each is turned away where eligibility is
  decided, and each reason says what the person can do instead.
  - **A Codex tab with no thread.** There is nothing to resume, and a bare shell
    in its place would discard the tab's purpose silently. Close the tab and
    open a new one, which starts on the holder.
  - **A Claude tab whose session never began.** An agent whose session hook
    never fired names no conversation either. Without a reason of its own it
    would become a bare login shell in a tab still reading Claude.
  - **A pre-session hook tab.** The skip is unconditional: the tab is transient,
    and the row alone cannot say whether the creation flow is still waiting on
    it.
  - **A `setup` hook tab.** It is TBD-created, and closing it is what one does
    with it; a shell in its place would show nothing the tab existed to show.
- **A parked row's activity rails still apply**, through the same eligibility
  decision; a park records the row idle, so in practice a parked row is never
  turned away by them.
- **The row keeps its identity**: id, label, pin, profile and history entries
  all survive every path, and on the park → rewrite → wake path the Claude
  session id and transcript path do too, because there only the transport
  column (and the tmux coordinates that go with it) changes. The shell move
  writes more, since the process it records is a new one, but it keeps the label
  deliberately: startup recovery and the app's primary-terminal detection both
  find a tab by its label. The `kind` follows the program and becomes `shell`.
- **The tmux coordinates are blanked.** A row that no longer lives in tmux must
  not carry a window or pane id, and holder rows record empty coordinates.

No database migration is needed. The `transport` column exists and already
carries both values; this feature writes a value the schema has always allowed.

## Failure, and why nothing rolls back

Each session's migration is claim-free but ordered.

- **The tmux server may still be running.** The migration refuses before
  touching the row and gives the command that ends the server.
- **The worktree cannot be read**, so there is no server to probe. The migration
  refuses and touches nothing.
- **The holder cannot be started** — the helper is missing or unspawnable. The
  migration refuses before any park, and the row is left exactly as it was.
- **A compare-and-set is rejected** because a wake, a replacement or a reconcile
  won the race. The session is skipped and reported; the row is consistent by
  construction. A live row parked just before its rewrite lost stays parked on
  tmux, and the next run moves it as a parked row.
- **The wake fails after the rewrite.** The row is left parked and recorded as
  holder-backed, which the ordinary wake path already handles: its next wake
  spawns a holder and resumes the session. This is **its own reported outcome**,
  not a refusal: a refusal says the session is where it was, and this one is
  already on the holder. The rewritten row is published exactly as for a clean
  move, so a client that never heard about it stops reading the old transport.

The shell move can leave two states behind, and no third:

- **The spawn failed.** The row is untouched: still `tmux` and live, on a server
  that is gone. Reconcile deletes it, as any unreachable shell row, and running
  the migration again before then moves it.
- **The write lost its compare-and-set.** The holder that was started is
  abandoned — a holder and a job no row names would be reclaimable by nothing —
  and the row is as the other writer left it, such as a tab that was closed.

Nothing unwinds an earlier success. A fleet-wide run migrates sessions
sequentially — so a machine with a large fleet is not asked for many
simultaneous respawns — continues past a failure, and reports the outcome of
each: migrated, moved but not resumed, skipped with a reason, or refused with a
reason. Earlier successes are finished sessions, not steps in a transaction.

## Surfaces

One RPC method, exposed three ways: a per-session action in the app's row
context menu, the CLI equivalent, and a fleet-wide run. The run's report is its
product — a person needs to know what did not move and why, not merely that
something did.

**The fleet run is composed from the per-session move on both surfaces**, and
each surface has its own reason for that. The daemon's `--all` loops its own
single-session move, so the actuation record and the publication of each
rewritten row land at that session's own moment rather than after the whole
loop. The app does not call `--all` at all — it iterates the non-holder rows it
holds and sends one single-session call each. A sequential run over a hundred
sessions outruns the app's RPC receive deadline, and when it does the call
throws while the daemon keeps migrating: the person is told the daemon is
unresponsive and the report this run exists to produce is lost. One call per
row has no deadline to outrun.

The actions are unflagged. A gesture that does nothing until somebody asks for
it needs no switch.

## The backstop

TBD has no tmux wake: waking a session means starting its program again, and
TBD starts programs only on the pty holder. So a parked row still recorded as
`tmux` refuses its wake with a reason naming this migration and the row's own
id (`tbd terminal migrate <id>`), and that refusal comes before every other
check a wake makes — a missing session id, a Codex wake asked to deliver a
prompt — so the person is always told the one thing that unblocks the row. The
row stays parked with its session id, so a wake after the migration resumes it
on the holder. Switching a tmux session's account in place would start a
program too, and it refuses the same way.

A wake of a live tmux row refuses with the still-running advice, since TBD can
neither reach the session nor know it has ended without the probe. Check Again
(`terminal.recreateWindow`) is where a live row is looked at again: it parks a
resumable row whose server is gone, refuses a row whose server may still run
with the still-running advice, and refuses a row with nothing to resume — a
shell is told to run the migration, which moves it, and a tab the migration
always skips is told to close the tab and open a new one.

None of this is migration logic: each is a refusal or a park, with no flag.

## Out of scope

- **Prompting on app launch.** Asking a person to run the migration when they
  open the app is wanted, and is not this design. It acts without a gesture, so
  it ships behind a default-off flag of its own when it is built.
- **Automatic or wake-time migration.** A session is never moved by the daemon's
  own decision. The backstop refusal covers the row nobody moved.
- **Moving a session back to tmux.** There is no reverse gesture: TBD opens no
  session on tmux.

## Reconcilers

This introduces no new kind of durable resource. The holder session a migration
creates is created through the same spawn path every other holder session uses,
and is therefore already covered: `HolderRegistry` adoption, `AgentReaper`'s
holder sweep, the `OrphanGC` rendezvous arms, and the reconcile pass.

TBD reclaims no tmux window or server. A leftover server and its windows are its
owner's to end, with `kill-server` or a restart, and the notice says how. The
socket file tmux leaves behind when a server exits is not TBD's either: tmux
never unlinks it, and nothing TBD runs creates one any more.

## Testing

- The probe, against real sockets and no tmux: a listening `AF_UNIX` socket is
  running, a missing path is gone, a socket bound with no listener is gone
  (`ECONNREFUSED`), and any other connect error is running. The candidates are
  a `TMUX_TMPDIR` that resolves, resolved, and always the fallback root; a
  `TMUX_TMPDIR` naming a missing directory is dropped. A listener under the
  fallback root reads as running while `TMUX_TMPDIR` names a missing
  directory, a listener at either candidate reads as running, and a server
  absent from every candidate, with no tmux process, reads as gone. The
  fallback root is injected, so no test asks the real `/private/tmp`.
- The process signal, with an injected process table: every socket absent
  plus a tmux process naming the server is running; one naming another server
  is gone; one whose argv cannot be read is running, for any server; another
  user's, with an argv that cannot be read, is gone; no tmux process is gone;
  a table that cannot be read is running; and a socket that answers is running
  without the table being read. A tmux whose binary was deleted, so its path
  cannot be read, is still found by its command name and keeps the server it
  names running. Another user's process is passed over even when its argv
  names the server. The lister, over a literal table, finds tmux by command
  name, by path, and by the saved binary's name cut to 16 bytes, asks for a
  path only when the command name does not settle it, and asks nothing of
  another user's process; a saved name whose cut splits a character still
  matches the command name the kernel keeps for it; against the real kernel,
  the table gives a started process's command name and real user id. The
  `-L` matcher finds the separate, joined and clustered forms and nothing
  else. The argv reader
  starts argv at the 8-byte boundary the kernel pads the executable path to,
  so an empty `argv[0]` is read in place rather than taken for padding, and it
  stops before the environment; a process started with an empty `argv[0]` under
  paths that need each amount of padding reads back as started.
- Reconcile parks a live resumable tmux row whose server is gone, keeping its
  session id, deletes a live shell row on such a server, leaves a row whose
  server may run live and untouched, never probes a parked row, and asks the
  probe once per server name.
- A migration of a live row whose server may still run refuses with the
  still-running advice and calls nothing else; one whose server is gone parks,
  rewrites and wakes in that order, or moves a shell; an unspawnable holder
  refuses before any park; a lost park or rewrite compare-and-set is a skip.
  One case runs the production operations, so the probe's wiring is covered.
- A parked session migrates with nothing spawned at all — asserted on a
  spawn-counting double, because "no respawn" is the whole difference between
  the two paths.
- A shell moves: the transport flips, the tmux coordinates are blanked, the
  holder's processes and its child's start time are recorded, and the row keeps
  its id, label and pin. Each state a failed shell move can land in is covered:
  a spawn that fails leaves the row on `tmux`, and a write that loses its
  compare-and-set abandons the holder and reports the race skip.
- Each row that names no conversation and must not become a shell is skipped
  with its own reason, while a plain `shell` tab still moves.
- A wake that fails after the rewrite is reported as its own outcome rather than
  as a refusal, and its rewritten row is published.
- A fleet run publishes each row before it starts the next one and writes one
  actuation row per session.
- A session already on the holder is answered `.alreadyHolder` with nothing
  touched.
- The backstop refuses a parked `tmux` row's wake with its stated reason, ahead
  of the resume-plan and Codex-prompt checks, and that reason names the session.
- Check Again on a live tmux row refuses with the still-running advice while the
  server may run and parks the row once it is gone; a send, a wake or a park
  of a live tmux row, and a wake of a parked one, refuse with `terminalOnTmux`,
  and the actuation record calls each wake or park refusal `not-eligible`.
- The app shows the notice for a live tmux row and not for a parked one or a
  holder row, and the notice says that closing the tab leaves the session
  running in tmux.
- Closing a tmux row's tab, archiving its worktree, reconcile's archive and a
  pre-session hook tab's close run no tmux command and delete the row. A live
  row with a session id gets a Closed Terminals entry with no screen, marked
  with the worktree's server; a live row without one gets no entry; a parked
  row's entry carries its stored screen and no mark.
- A marked entry survives the newest-50 prune, a later save of the same entry
  keeps its mark, and the lookup returns each server marked for the given
  session ids, across worktrees.
- Each start of an existing session refuses while a server its mark names may
  run, spawns nothing and leaves every record as it was; goes ahead on the
  holder once the server is gone; and asks no probe for a session that neither
  a mark nor a tmux row names. That holds for a revive in place with and without
  a preferred session, a fresh-branch revive of a Codex thread,
  `session.resume`, a Closed Terminals reopen, `spawnTerminal` itself and a
  wake. The RPCs answer `terminalOnTmux` and record `not-eligible`. A revive
  that skips the agent tabs asks nothing.
- `session.resume` and `terminal.create` resuming a session refuse the same
  way while an unparked tmux row in any worktree carries the session and that
  worktree's server may run, leaving the tmux row as it was, and go ahead once
  the server is gone. A row whose transport is NULL counts as one on tmux, and
  so does a parked tmux row with a park in flight; a parked tmux row with no
  park in flight is not probed.
- A profile switch's fork of a tab on tmux, a Claude carryover into a new
  worktree and a fresh-branch revive of a Claude conversation go ahead while a
  tmux row and a mark name the source session and the probe says its server
  may run.
- Archive keeps a live tmux row's tab in the record. Reconcile's archive of a
  vanished checkout followed by a History pane resume, and `terminal.delete`
  followed by `session.resume`, are refused end to end. The probe is injected,
  so no test runs tmux.

## Rejected alternatives

- **Migrating at wake time.** A parked tmux row could be rewritten as it wakes,
  which would need no gesture at all. It moves a session at a moment nobody
  chose and cannot ask: a person waking a session wants it back, not relocated.
  The backstop refusal gives the same protection for a fraction of the
  behaviour.
- **A proactive sweep.** A boot or reconcile pass could migrate every parked
  tmux row. Nothing needs that convergence: an unwoken parked row costs nothing.
  A sweep would act on rows nobody asked about, with no person waiting for its
  answer.
- **Extracting the live pty.** Rejected by the transport design; tmux offers no
  way to surrender a pty master.
- **Seeding the migrated session with the parked screen.** An agent redraws its
  alternate screen on resume, and a shell's scrollback does not justify the
  mechanism.
- **Parking every live tmux row on sight now.** Two agents could then share one
  session id: the parked row migrates and wakes while tmux still runs the first.
- **Keeping a tmux kill shim.** Ending leftover servers for the person keeps
  tmux in TBD with no end date.
