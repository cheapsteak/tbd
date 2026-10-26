# Moving a session to the pty holder, on request

## Summary

A person can move a session from the tmux transport to the pty holder in place:
same row, same tab, same label and pin, same Claude session id and transcript.
The session's program is parked and respawned on the holder; nothing is
extracted from a running tmux server. Nothing moves without a gesture.

This is the mechanism by which the tmux transport's remaining sessions leave it,
so the tmux path can be deleted without stranding a session somebody still
wants. A second, much smaller piece completes that guarantee: once the tmux path
is gone, a row still recorded as `tmux` refuses its wake with a reason naming
this migration, so a session nobody got around to moving produces a clear
message rather than a broken tab.

## Why a gesture rather than a behaviour

The transport a session runs on is recorded per row at spawn and kept for life.
Flipping the default changes what new sessions get; it moves nothing that
already exists. Sessions therefore outlive the default that created them, and
the last tmux-backed ones would outlive the tmux code itself.

Moving a session costs something real: its program is killed and started again.
An agent session reappears through `claude --resume` with its conversation
intact, which is close to invisible; a shell loses whatever was running in it.
A cost that depends on what the session is doing is a cost its owner should
choose to pay, at a moment they pick. So the migration is an action, surfaced
per session and as a fleet-wide run, and the daemon never initiates it.

## What it is not

**It does not extract a live pty from a tmux server.** The transport design
rejects live migration, and that stands: a pty whose master is held by a tmux
server cannot be handed to a holder without the server's cooperation, and
nothing in tmux offers it. Migration is park, rewrite, wake.

**It does not seed the new session with the old screen.** An agent redraws its
own alternate screen on resume, and a shell's scrollback is not worth a
mechanism. The migrated session starts clean.

## The mechanic

One session is the unit, and it is a composition of operations that already
exist. The in-place profile swap — park, re-home, wake, one tab, same row, same
session id — is the same shape with a different column rewritten
([spec](2026-09-22-holder-in-place-profile-swap-design.md)).

- **A running session** is parked, its `transport` rewritten, and woken. The
  wake is the ordinary one: everything above the wake path's single transport
  branch is already transport-independent — profile, environment, settings
  overlay, trust seed, transcript sync, and the `claude --resume` argv — so the
  migrated session resumes through the same code any other wake uses.
- **A parked session** is only rewritten. Nothing is running, so there is
  nothing to park and nothing to respawn; its next ordinary wake lands on the
  holder.
- **A running session with nothing to resume** — a shell — takes a fourth verb
  instead of those three. There is no conversation for a park to preserve, so
  its program is stopped, a fresh login shell is started on the holder in the
  same working directory, and the move is recorded in one guarded write. See
  "What migrates, and what is skipped" for the mechanic and "Failure, and why
  nothing rolls back" for the two states a failure leaves.

### The rewrite is a compare-and-set, not a lock

The write is the sibling of `TerminalStore.setParkedProfileID`: it changes the
row only while the complete launch state the caller observed is still current,
so a wake or a replacement that wins the race rejects the write atomically
rather than leaving the row naming a transport the live process is not on. The
guard is the mechanism that makes the migration safe against a concurrent wake;
no new claim or lock is introduced.

### The park honours every live rail

The migration parks under the ordinary manual-park policy, so the rails that
read the session's state still apply: a turn in flight, a permission prompt,
and a transcript tail that is mid-write. This is deliberate and is the opposite
of the profile swap's policy, which stops honouring them because switching
accounts should interrupt regardless.

The difference is in when each action is wanted. A swap is wanted at the moment
it is asked for. A migration is not: the session moves just as well once its
turn ends, so interrupting the turn, eating a raised permission hand or cutting
a transcript mid-write — which can leave a session the wake cannot resume —
buys nothing. A rail that refuses the park is protecting the session, and its
refusal becomes a *skipped* line carrying that rail's own reason. A person runs
the migration again once the turn has ended or the prompt is answered. No new
eligibility policy is added.

No rail guards an unsent draft in the composer. The session mod is the park's
only guard for one, and a manual park, this one included, goes ahead whatever
the mod knows
([`2026-10-24-mod-only-park-guard-design.md`](2026-10-24-mod-only-park-guard-design.md),
"Which parks go ahead"). A session whose mod has confirmed the save gets its
draft back when the wake resumes it on the holder; for any other session an
unsent draft may be lost.

## What migrates, and what is skipped

- **Idle sessions migrate, and a busy one is skipped and named** so a person
  can retry or move it one at a time. How busy-ness is known differs by what
  the tab holds, and both halves are load-bearing. For an **agent** it is the
  activity state TBD already tracks, written from the hook-bridged RPC. A
  **shell** fires no hooks, so nothing ever writes its activity state and the
  row reads "unknown" for its whole life — the activity rails can never fire
  for one, and a promise resting on them alone would be empty. Its busy-ness
  comes from the **process table** instead: the migration asks whether the
  pane's foreground process is the pane's own shell, and a different pid is
  something the person started. An unreadable pid proceeds, exactly as it does
  for a wake — a pane tmux cannot answer for is not evidence that a process is
  there. This matters most for a fleet-wide run, which is how a person drains
  tmux and where they did not pick the tab.
- **Shells migrate plainly** — a fresh program in the same working directory.
  A running session with no conversation to resume cannot be parked at all: a
  park exists to carry a conversation across a respawn, and this row names
  none. So its program is stopped and a fresh login shell starts on the holder
  in the worktree's own directory, recorded in one guarded write that moves the
  transport, blanks the tmux coordinates, records the holder's processes and
  clears the dead process's session and activity facts together. The
  replacement carries a freshly minted incarnation, so a hook from it is
  attributable to it rather than to what was killed. **A command line typed
  into that shell and not yet run is discarded.** A shell never reaches a park
  — nothing it could preserve exists — and the process-table rail that decides
  whether its move goes ahead sees a half-typed line as an idle shell, because
  it is one. A fleet run therefore discards whatever is sitting unsent at every
  idle shell prompt. That is the cost of moving a shell, and it is why nothing
  moves without a gesture.
- **Agents migrate through `--resume`** on the session id the row records, the
  same argv a wake builds.
- **Four rows that name no conversation are skipped rather than moved,
  each with its own reason.** "No conversation to resume" is what sends a row
  down the shell move, and for these four the move available would start a
  bare login shell where something else belongs — so each is turned away where
  eligibility is decided, and each reason says what the person can do instead.
  - **A Codex tab.** Moving it properly needs Codex's own launch preparation —
    the executable resolver, the home ensurer and the merged environment
    overrides — which lives on the RPC router rather than on this path. A bare
    shell in its place would discard the Codex session silently. Close the tab
    and open a new one.
  - **A Claude tab whose session has not begun.** An agent that is still
    starting up, or whose session hook never fired, names no conversation
    either, and that happens in the field. Without a reason of its own it
    would have a live agent killed and replaced by a bare login shell in a tab
    still reading Claude. Close the tab and open a new one, which starts on the
    holder.
  - **A pre-session hook tab.** It is a shell with no conversation, so it would
    otherwise be eligible — and a fleet run during a worktree creation would
    kill the hook mid-run, which the creation flow reports as a hook failure
    with the hook's work lost. The skip is unconditional: the tab is transient,
    so skipping it costs nothing even once its hook has finished, and the row
    alone cannot say whether the creation flow is still waiting on it.
  - **A `setup` hook tab**, for a case no rail can see. A setup hook that
    *failed* has `exec $SHELL`'d, so a tab somebody deliberately kept open to
    read the failure holds an idle shell: the process-table rail finds nothing
    running, the row looks eligible, and the move kills its window with no
    Closed Terminals capture — destroying exactly the output the tab exists to
    show. The skip is unconditional for the same reason the pre-session one is,
    and it costs less: the tab is TBD-created and closing it is what one does
    with it. `finishAutoCloseSetup` is a live observer of it too whenever
    `auto_close_setup_enabled` is on, which the row alone cannot see either.
- **The row keeps its identity**: id, label, pin, profile and history entries
  all survive every path, and on the park → rewrite → wake path the Claude
  session id and transcript path do too, because there only the transport
  column (and the tmux coordinates that go with it) changes. The shell move
  writes more, since the process it records is a new one — but it keeps the
  label deliberately, and not for display: startup recovery and the app's
  primary-terminal detection both FIND a tab by its label, so a hook tab
  renamed `shell` by this gesture would be found by nothing. The `kind`
  follows the program and becomes `shell`, which is what is now running
  there.
- **The tmux coordinates are blanked.** A row that no longer lives in tmux must
  not carry a window or pane id: a stale pane coordinate is what let daemon
  keystrokes reach a different session than the one addressed, and holder rows
  record empty coordinates for exactly this reason.

No database migration is needed. The `transport` column exists and already
carries both values; this feature writes a value the schema has always allowed.

## Failure, and why nothing rolls back

Each session's migration is claim-free but ordered: park, rewrite, wake.

- **The holder cannot be started** — the helper is missing or unspawnable. The
  migration refuses before touching the row, which is left exactly as it was,
  running or parked, on tmux. The refusal names the reason.
- **A rail refuses the park.** The session is skipped and reported, unchanged.
- **The rewrite is rejected** because a wake or replacement won the race. The
  session is skipped and reported; the row is consistent by construction.
- **The wake fails after the rewrite.** The row is left parked and recorded as
  holder-backed, which the ordinary wake path already handles: its next wake
  spawns a holder and resumes the session. The worst case is a session that
  comes back on the holder later rather than now.

  This is **its own reported outcome**, not a refusal, and the distinction is
  load-bearing in both directions. A refusal says the session is where it was,
  so reporting this one as a refusal would tell a person a session "can't be
  moved" that is already on the holder, and would leave the run's migrated
  count short of what it did. And the rewritten row is **published** for this
  outcome exactly as for a clean one: the row is holder-backed with its tmux
  coordinates blanked, so a client that never heard about it keeps attaching to
  a window the migration has killed, and spends a recovery attempt on a
  `terminal.recreateWindow` the daemon refuses for a holder row. What a person
  reads is what happened and what it costs — it is on the holder, and it starts
  there when the tab is focused or when it is next woken.

A shell's move is the one that stops a program before it writes anything, so it
is worth saying which states it can leave behind. There are two, and no third.

- **The spawn failed.** The row is untouched: still `tmux`, still awake, naming
  a window that is now dead. That is the ordinary window-died state the app's
  recovery banner already owns, and `terminal.recreateWindow` can still repair
  it precisely because the row was not rewritten.
- **The write lost its compare-and-set.** The holder that was started is
  abandoned — a holder and a job no row names would be reclaimable by nothing —
  and the row is in the same state as above. The race this loses is a
  window-died recovery recreating the row's window in the gap, which rotates
  the row's incarnation; the person keeps the fresh tmux window the recovery
  gave them.

Killing before the write is the opposite of the parked path's order, and it is
safe for a different reason: the write is a compare-and-set, so a recovery that
notices the dead window first makes this write a no-op. Both outcomes are
consistent, and nothing can leave a row naming a transport its live process is
not on. Everything that can turn the move away is settled *before* the kill —
no holder can be started, a worktree that gives no local directory, a pane that
cannot be proven to be this terminal's, a pane running something other than its
own shell — and each leaves the session the program it has.

Two kill outcomes are not failures and must not be reported as any. A kill that
tmux refuses while the window is still there, or while tmux cannot say, is a
program still running, so the move refuses rather than starting a second one
beside it: two live programs for one row is the one state this path must never
produce, and "we do not know" is a refusal here as at every other site in this
family. But a kill that fails because the window is *already gone* has nothing
left to stop — the pane-ownership guard passes such a row deliberately, since a
positively absent server holds no stranger's pane — so the move carries on to
the replacement shell. Only tmux's own positive "no such window" counts.

Nothing unwinds an earlier success. A fleet-wide run migrates sessions
sequentially — so a machine with a large fleet is not asked for many
simultaneous respawns — continues past a failure, and reports the outcome of
each: migrated, skipped with a reason, or refused with a reason. Earlier
successes are finished sessions, not steps in a transaction, and rolling them
back would mean moving working sessions off the transport they now run on.

## Surfaces

One RPC method, exposed three ways: a per-session action in the app's row
context menu, the CLI equivalent, and a fleet-wide run. The run's report is its
product — a person needs to know what did not move and why, not merely that
something did.

**The fleet run is composed from the per-session move on both surfaces**, and
each surface has its own reason for that. The daemon's `--all` loops its own
single-session move, so the actuation record and the publication of each
rewritten row land at that session's own moment rather than after the whole
loop: a run's worth of stale transports is a run's worth of panes attached to
windows the migration has already killed. The app does not call `--all` at all —
it iterates the non-holder rows it holds and sends one single-session call each.
A sequential park-and-respawn of a hundred sessions outruns the app's RPC
receive deadline, and when it does the call throws while the daemon keeps
migrating: the person is told the daemon is unresponsive, every veil drops at
once, and the report this run exists to produce is lost. One call per row has no
deadline to outrun, and it gives every row the same veil and the same wait for
adoption the single gesture already has.

The actions are unflagged. A gesture that does nothing until somebody asks for
it needs no switch, which is why "Hibernate now" has never had one.

## The backstop

Deleting the tmux path removes the code a `tmux` row's wake would take. From
that point a row still recorded as `tmux` refuses its wake with a reason naming
this migration, instead of failing obscurely inside a path that no longer
exists. This is a refusal and nothing more: no migration logic, no flag, a
handful of lines. It is what keeps "a session never silently breaks" true
without a daemon-initiated migration.

## Out of scope

- **Prompting on app launch.** Asking a person to run the migration when they
  open the app is wanted, and is not this design. It acts without a gesture, so
  it ships behind a default-off flag of its own when it is built.
- **Automatic or wake-time migration.** A session is never moved by the daemon's
  own decision. The backstop refusal covers the row nobody moved.
- **Moving a session back to tmux.** There is no reverse gesture, and none is
  planned: the whole point of this one is to drain the transport that is being
  deleted, so a way back would be a way to re-enter a state the next release
  removes. A session that must run on tmux is closed and opened again with the
  transport flag off.

## Reconcilers

This introduces no new kind of durable resource. The holder session a migration
creates is created through the same spawn path every other holder session uses,
and is therefore already covered: `HolderRegistry` adoption, the `AgentReaper`
holder leg, the `OrphanGC` rendezvous arms, and the reconcile pass.

It does retire one resource of its own. A tmux park keeps the window and
respawns it to a bare login shell, which is what makes a parked tab wakeable in
place — so once the rewrite lands, that window belongs to nobody: the row no
longer names it, and one dangling window and shell per migrated session is a
fleet run's worth of residue. The migration therefore kills the window as the
last step of the rewrite, and the reconcile pass's untracked-window sweep is the
backstop rather than the mechanism. It kills a window only after the rewrite has
landed, and only through the pane-ownership guard every other teardown by
DB-recorded coordinate goes through: the kill proceeds on all four of that
guard's permitting answers — the pane answers with this terminal's id, the pane
carries no identity to read, tmux positively reports the pane *absent* on a
server it can reach, or the whole tmux server is positively gone — and it
refuses when the pane names a different terminal or when the consultation could
not be run at all. The absent-pane arm is not a technicality: the shell move's
already-gone-window case depends on it, since that is the state a row whose
window died before anybody reached for this gesture arrives in. So a coordinate
tmux has recycled onto a stranger's pane costs that stranger nothing, while a pane
that answers *without* an identity is still retired — the ordinary state of one
whose stamp and start command are both unreadable, and not evidence of anybody
else. A consultation that failed outright is "we do not know" rather than
"gone", so it refuses; that is the stance all seven sites take.

**The running-shell move's stop is one of those sites too, and the sharpest of
them.** Every other kill reclaims a window somebody has finished with; this one
ends a running program, so a recycled coordinate would take a stranger's live
session rather than an idle leftover. It asks the same question through the same
guard, and a refusal writes nothing at all.

**An exit-stamped row is skipped rather than moved while its pane is in use.**
`.exited` parks a row whose pane's shell is still alive and usable, which is the
whole point of that stamp: the pane is the one the person was sitting in when
the agent left, and they may have started something in it since. Moving the row
would blank its coordinates and retire that window, taking their process with
it. So the migration asks the process table the same question a wake asks before
its own `respawn-window -k` — is the pane's foreground pid its own shell? — and
reports the wake's own reason as a *skip* when it is not: the person stops what
is running in the pane and runs the migration again, which is what a skip means
and a refusal does not. An unreadable pid proceeds, exactly as it does for the
wake: a pane tmux cannot answer for is not evidence that a process is there.

## Testing

- An idle agent session migrates: the transport flips, the id, Claude session id
  and transcript path are unchanged, and the tmux coordinates are blanked. The
  session resumes through the ordinary wake — everything above that path's
  single transport branch is already transport-independent, the `claude --resume`
  argv included — so what is asserted is that the wake was called and
  that the row kept the session id it will resume on, not that this path builds
  an argv of its own. It builds none.
- A parked session migrates with nothing spawned at all — asserted on a
  spawn-counting double, because "no respawn" is the whole difference between
  the two paths.
- A busy session is skipped and named, and its row is untouched.
- A migrated session's tmux window is retired, on the parked path and the
  running one, while a rewrite that was refused leaves the window alone. A row
  that names no tmux window asks tmux to kill nothing and still moves.
- The retire's pane-ownership guard is enumerated beside the other six
  teardown-by-coordinate sites: it refuses both a pane naming a different
  terminal and a consultation that could not be run, writing nothing to the row
  in either case, and proceeds for a pane that answers with the row's own id. A
  whole migration of a row whose coordinate has been recycled still moves the
  session and still leaves that window alive.
- An exit-stamped session with something running in its pane is skipped with
  the wake's own pane-busy refusal and keeps its window and coordinates, while
  an exit-stamped session whose pane is idle migrates.
- A running shell moves: the transport flips, the tmux coordinates are blanked,
  the holder's processes and its child's start time are recorded, the row keeps
  its id, label and pin, its window is stopped exactly once, and neither the
  park nor the wake is called at all. The launch carries the worktree's path as
  its working directory, the login shell as its program, and the incarnation
  the row ends up naming. A running Claude session still parks and wakes, which
  is the regression this branch most needs guarded.
- The shell move's busy rail, all three legs: a pane whose foreground process
  is something else is skipped and named with nothing killed, spawned or
  written, while a pane holding only its own idle shell moves, and so does one
  whose pid tmux could not read.
- Each state a failed shell move can land in: a spawn that fails leaves the row
  on `tmux` with its coordinates intact, a spawn the registry declines because
  the session already has a holder says another move won rather than repeating
  the spawn failure's recovery advice, and a write that loses its
  compare-and-set abandons the holder and reports the race skip. A worktree
  that gives no local directory refuses before anything is touched. Its kill
  joins the pane-ownership enumeration, refusing both a stranger's pane and an
  unanswerable consultation while writing nothing.
- The kill's two failure answers are told apart: an already-gone window moves
  the session anyway, while a window still alive — or one tmux cannot classify —
  refuses with nothing started.
- Each row that names no conversation and must not become a shell is skipped
  with its own reason, after the already-holder answer and before the activity
  rails, with nothing killed, spawned or written: a Codex tab by kind and by
  label, a Claude tab with no session yet (while the same tab *with* a session
  stays eligible, so the skip is about the conversation and not the kind), and
  a hook tab of either kind including an idle one — while a plain `shell` tab
  with no conversation still moves, which is what keeps the hook skips about
  the label rather than about shells. A row with no `kind` at all reads as a
  shell and still moves.
- A wake that fails after the rewrite is reported as its own outcome rather
  than as a refusal, for each shape of wake answer, and the row it names really
  is holder-backed. Its rewritten row is published like a clean migration's,
  carrying the new transport and the blanked coordinates.
- A fleet run publishes each row before it starts the next one, observed from
  inside the second row's own move, and writes one actuation row per session,
  each naming that session: the moved one dispatched, a busy one refused as
  not-eligible with the rail's reason, and one that moved without resuming as a
  transport failure.
- The app's fleet run sends one single-session call per non-holder row and none
  for a holder row, veils the awake rows and not the parked ones, and keeps the
  report of the rows already moved when a later call throws.
- A session already on the holder is answered `.alreadyHolder` with nothing
  touched, for an agent tab and for a shell.
- A session whose transcript is mid-write is skipped with the rail's reason,
  proving the migration park honours the rails rather than overriding them.
- An unspawnable holder refuses and leaves the row exactly as it was, in both
  the running and parked variants, and a daemon with no holder registry at all
  refuses the same way — the registry is where the launch's inherited
  environment comes from, so a move without one could compose no launch even if
  it could spawn.
- A rejected compare-and-set is reported as skipped, with the row consistent.
- A fleet-wide run containing one refusal still migrates the rest and reports
  the one.
- The backstop refuses a `tmux` row's wake with its stated reason, and that
  reason names the session, because the command it hands a stranded person is
  the whole product of the refusal.
- Any wait introduced by the migration takes an injected clock.

## Rejected alternatives

- **Migrating at wake time.** A parked tmux row could be rewritten as it wakes,
  which would need no gesture at all. It was rejected because it moves a session
  at a moment nobody chose and cannot ask: a person waking a session wants it
  back, not relocated. The backstop refusal gives the same protection against a
  forgotten row for a fraction of the behaviour.
- **Rewriting at park time.** Parking a tmux session could record it as
  holder-backed so every wake is already a holder wake. It decides earlier than
  necessary, churns rows that may never be woken again, and park must succeed —
  so it has no way to refuse, which is the thing a migration most needs.
- **A proactive sweep.** A boot or reconcile pass could migrate every parked
  tmux row. Nothing needs that convergence: an unwoken parked row costs nothing,
  and the delete requires that no wake take the tmux branch, not that the fleet
  be drained. A sweep would act on rows nobody asked about, with no person
  waiting for its answer, and would duplicate the decision in a second place.
- **Extracting the live pty.** Rejected by the transport design and unchanged
  here; tmux offers no way to surrender a pty master.
- **Seeding the migrated session with the parked screen.** The snapshot-preamble
  machinery could put the old screen above the new prompt. An agent redraws its
  alternate screen on resume, so it would show through for a moment and then be
  replaced, and a shell's scrollback does not justify the mechanism.
- **A dedicated park-eligibility policy.** The migration could stop honouring
  the live rails, as the profile swap does. A swap is wanted at the moment it is
  asked for, and a migration is not: a session refused by a rail moves just as
  well once its turn ends or its prompt is answered, while one parked mid-turn
  has that turn cut off and one parked mid-write may not resume at all. The
  manual-park policy already refuses those, so no policy is added.
