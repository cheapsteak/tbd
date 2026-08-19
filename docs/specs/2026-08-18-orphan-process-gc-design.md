# Orphaned-process GC: a reconciler for processes that outlive their worktree

## Problem

A process started inside a TBD terminal can outlive every structure TBD uses to
find it. When the pane dies, such a process is reparented to launchd, keeps its
memory, and nothing ever reclaims it. Observed instances have run for **days**
against **seconds** of CPU — parked, not working — in worktrees that had since
been archived.

Two measured examples, both `ppid=1`, both with a cwd inside a worktree whose
row read `status=archived`:

- `process-compose up -f <worktree>/process-compose.yaml` — 11 days 18 hours
  elapsed, 4 minutes 41 seconds of CPU, holding a live subtree of its own
  (`prefect server start`, a gateway supervisor, a prefect `serve(...)`).
- A `pnpm storybook --ci` tree — 10 days elapsed, 4.7 seconds of CPU, never
  having bound a listening socket, so it had not finished starting up.

A single-point census of one developer machine found roughly half a dozen such
processes alive at once, so this is a steady-state population rather than a
one-off.

## Why they escape

The escape is a property of job control, not of any exotic daemonizing. Under
an interactive shell **every job runs in its own process group**, distinct from
the pane process's group. Measured against a pane at pid 52269 (pgid 52269), its
four children carried pgids 53668, 53703, 53735 and 53820 — none of them the
pane's.

So `killpg(pane_pid, …)` reaches the shell and nothing else. What actually kills
a normal foreground job is the **kernel**, which sends SIGHUP to the controlling
terminal's foreground process group when the pty hangs up. Anything outside that
foreground group is signalled by nobody.

Running `tmux kill-window` — the primitive every TBD teardown path calls — against
a pane with one child of each kind gives:

- **Foreground job** – dies. The kernel hangs up the tty and signals the
  foreground process group.
- **Plain background job (`&`)** – dies. zsh sends SIGHUP to its own jobs as it
  exits.
- **`& disown`** – **survives**, reparented to `ppid=1`.
- **`nohup … &`** – **survives**, reparented to `ppid=1`.

Anything that calls `setsid` or double-forks escapes the same way. `disown` and
`nohup` matter most in practice because they are what a person or an agent
reaches for when they want a server to keep running while they do something
else in the same terminal.

## Why nothing reclaims them

`AgentReaper` is the only process-shaped reconciler TBD has, and it cannot see
these, three times over:

- **It walks one generation.** `ProcessSignaller.children(ofServerPID:)` runs
  `ps -axo pid=,ppid=` and keeps pids whose `ppid` equals the tmux server's pid.
  A process started inside a pane is a grandchild at best, and once orphaned its
  parent is launchd.
- **Its per-teardown escalation is already too late.**
  `AgentReaper.escalateAfterHangup(panePID)` returns immediately, because the
  pane pid is dead — which is precisely why its children orphaned.
- **Its ownership gate excludes them deliberately.** `isTBDOwned` requires
  `argv[0]`'s basename to be `claude` or `codex`, or the command line to carry a
  TBD spawn marker. `pnpm`, `node` and `process-compose` fail that gate by
  design; the code comment says the gate exists to avoid "reaping a non-agent
  process a user detached inside a TBD shell pane (e.g. `nohup make`,
  `node script.js`)".

That third point is why this is a design change rather than a bug fix. TBD
already holds a written position that detached non-agent processes are not
teardown's business. This spec revises that position for one specific case — the
worktree they were rooted in is gone — and leaves it standing everywhere else.

`OrphanGC` covers worktree rows, scratchpads, interrupted archives and profile
directories; none of those is a process. The doctrine in CLAUDE.md requires every
durable external resource to name a reconciler, and an escaped descendant process
currently has none.

## Scope

**In scope:** processes whose cwd resolves inside a TBD-managed worktree,
`.deleting/` entry, or scratchpad, and whose owning worktree no longer exists.

**Out of scope, tracked as issue #678:** leaked tmux servers and their
`tmux -CC attach` control-mode clients. A tmux server `chdir`s to `/` when it
daemonizes — measured directly against a live TBD server, which reported
`cwd=/` — so a cwd-keyed rule structurally cannot see one. That class needs a
matcher keyed on server identity instead, and it carries a second half about
test-suite cleanup that does not belong here.

**Out of scope, deliberately deferred to its own spec:** making teardown itself
reap. Eleven of TBD's fifteen teardown call sites use a bare `tmux.killWindow`
with no reaping at all, including `terminal.delete`, `worktree.forget`,
`scratch.delete`, `scratch.archive` and desk close. Only explicit archive and
three branches of `reconcile` go through `killWindowAndReap`. Closing a terminal
will therefore still strand a detached dev server until the next sweep.

That ordering is deliberate. Neither measured orphan would have been caught by
teardown-time logic — both had already escaped before the teardown that should
have caught them — so the sweep is both the lower-risk feature and the one that
reclaims more. Teardown-time killing also reverses the `isTBDOwned` position at
the moment of a user gesture, which deserves its own examination.

## Identification

Cwd comes from the `lsof -d cwd -Fn` pass `OrphanGC` already runs once per
sweep. That pass prints a `p<pid>` header followed by an `n<path>` line per
process, and `parseLiveCWDs` currently keeps only the paths. Retaining the pid
alongside the path yields a pid-to-cwd map for every process on the machine at
no additional cost — no new subprocess, no per-pid syscall, and the established
"lsof unavailable means skip the entire sweep" direction already guards it.
That failure direction matters more here than anywhere else in the sweep: a
missing cwd map must never be read as "this process is not in a worktree".

A second `ps -axww -o pid=,ppid=,pgid=,uid=,etime=,command=` snapshot supplies
the process graph, the ownership and age fields, and the argv the reap record
names — none of which lsof carries. It is the same `/bin/ps` invocation shape
`ProcessSignaller` already uses.

`lsof` reports fully resolved paths (`/private/var/...` rather than
`/var/...`), so both sides of every comparison resolve symlinks first — the same
care `WorktreeLifecycle+Archive.swift` already takes when matching a worktree
path against `git worktree list` output.

A process is a candidate for reclamation when **all** of these hold:

- `ppid == 1`. It has been reparented to launchd, i.e. it really did escape.
  A process still held by a live parent is that parent's business.
- Its resolved cwd lies inside a TBD-managed root: a worktree pool directory,
  a `<pool>/.deleting/` entry, an adopted worktree's own directory, or a
  scratchpad directory.
- The worktree owning that path is archived or absent from the database.
- It is at least as old as the cwd reading it was matched against.

A cwd inside a **live** worktree is never a candidate, whatever the process is.
That is what keeps the rule narrow: a deliberately detached dev server is
reclaimed only after the worktree it belonged to has been archived, which is
already the gesture that says the work is over. A row that is present and not
archived counts as live whether or not its directory still exists on disk: that
combination is a broken worktree, and a broken worktree is a reconcile problem,
not a licence to kill.

### Owned roots and shared roots

The "absent from the database" arm makes an unrecognized child of a root
reclaimable, and that is only sound where every child of the root is TBD's by
construction. Two kinds of root therefore behave differently:

- **Owned** — each repo's worktree pool (canonical and legacy) and the
  scratch-worktree pool. Everything under one of these was put there by TBD, so
  a child naming no row is a leftover this sweep owns, and `.deleting/<uuid>`
  entries land here.
- **Shared** — the Claude scratchpad base, and every adopted worktree's own
  directory. Claude Code creates one directory in the scratchpad base per
  project it has ever been run in, and TBD manages almost none of them: a
  census of one developer machine found 86 entries, of which 9 named no
  worktree at all — plain checkouts, a home directory, and loose files. A cwd
  under a shared root is classified only by an explicit live or dead entry —
  derived from a worktree row via `ScratchpadCollector`'s slug for a
  scratchpad, and from the row's own path for an adopted worktree; an
  unrecognized child is never a candidate.

`ScratchpadCollector.reconcile` already draws exactly this line for a merely
destructive operation — "Unrelated directories in the base are untouched" — and
this phase kills processes, so it draws the line no further out.

`adoptWorktree` inserts a worktree row at a path the user chose, so an adopted
worktree lies under no pool at all. Without an entry of its own it would fail
the root test above and stay `.outside` forever, reproducing this phase's whole
subject for that class of worktree — so the row's own path is admitted, as a
shared root. Not as a pool, and not its parent directory: the location is the
user's, its neighbours are unrelated checkouts and loose files, and admitting
the neighbourhood as owned would put every one of them in the "absent from the
database" arm and make a stranger's live session reclaimable. A shared root
classifies exactly the adopted worktree and nothing beside it. Since no pool
contains the path, the reap record takes its repo from the row's own `repoID`
rather than from the pool-to-repo map.

`reclaimDeletionQueue` widens its own pool set from adopted rows for a related
reason, and can take the whole parent directory: an entry sitting in
`.deleting/<uuid>` is there because TBD renamed it there, so draining it needs
no provenance gate. Killing a process does.

### Two readings, joined by pid

The cwd map and the `ps` snapshot are read at different moments in one sweep and
joined by pid alone, and macOS reissues pids. A pid that named an orphan when
lsof ran can name an unrelated new process by the time `ps` runs, and that
process would inherit the dead one's cwd. So a candidate must be at least as old
as the gap between the two readings; anything younger is a possible reuse and is
skipped. A process whose age could not be parsed fails this gate too, which is
what makes "an unparseable start time keeps the process" true on both grace arms
rather than only the one that has no archive instant.

The worktree rows have their own staleness problem and the phase reads them
itself for the same reason: the archived list and the live list have to agree
with each other, and a row archived between them belongs to neither. It would
then reach the "absent from the database" arm and be graced from process start
rather than from `archivedAt` — the weaker gate, on the exact row whose grace was
just supposed to begin. Both reads happen together, inside the phase, and a
failure on either skips it.

## Exclusions

These are the safety core, and the first is not hypothetical.

- **The daemon and the app.** `TBDDaemon` runs at `ppid=1` with its cwd inside a
  TBD-managed tree — measured at `ppid=1, cwd=/Users/<user>/projects/tbd`, and
  when `scripts/restart.sh` is run from a worktree the daemon's cwd is that
  worktree. Archiving it would otherwise have the sweep SIGKILL the live daemon
  that is running the sweep. `TBDDaemon`, `TBDApp`, `getpid()` and its ancestors
  are never signalled.

  `getpid()` and its ancestors cover the running daemon; the binary-name check
  is what covers `TBDApp` and any sibling worktree's daemon, neither of which is
  in this process's ancestry. It matches the basename of any path component in
  the command line, not just of the first token: `ps` prints argv space-joined
  and unquoted, so a home directory with a space in it would otherwise split
  argv[0] and leave the app unrecognized. Over-matching is the keep-favoring
  direction and is accepted.
- **pid <= 1**, already refused inside `ProcessSignaller`.
- **Processes not owned by our uid.**
- **Anything whose cwd could not be read.** Absence of evidence is not evidence
  of an orphan; an unreadable cwd means skip, never reclaim.

## Reclamation

`ProcessSignaller.terminate` group-kills only when the pid is its own group
leader, and that is not dependable here. The `process-compose` orphan was a
leader (`pid == pgid == 70473`), so a group kill would have reached its prefect
children; `just backend local` was not (`pid=1450, pgid=1448`, its leader already
dead), so the same call would have signalled one process and left its children
running.

The collector therefore computes the **descendant closure** of each orphan root
from the `ps` snapshot it already holds, and signals the whole subtree leaf-first:
SIGTERM, poll for liveness, SIGKILL anything still alive at the end of the grace
window. Leaf-first so no descendant is still unsignalled at the moment its
ancestor is asked to shut down. It is an ordering rather than a barrier — the
volley does not wait between generations — so a process that forks during its own
SIGTERM handling can still leave a child behind; that residue is an orphan of its
own by the next sweep.

Every signal goes to exactly one pid. `ProcessSignaller.terminate` escalates to
a group kill whenever the pid is its own group leader, and a process group is a
superset of the *group*, not of the closure: it can contain a pid this sweep
deliberately protected, and on a reused pid `getpgid` resolves to a stranger's
group outright. The exclusion list is only a guarantee if nothing widens the
target after it has been applied.

This is the capability `ProcessSignaller.children(ofServerPID:)` lacks by
construction, and it is why the collector computes the closure itself rather than
calling that helper in a loop.

## Grace

Reclamation waits out `gcGraceSeconds` (3600 today), measured from `archivedAt`
where a worktree row survives, and from process start time where it does not.
Reusing the existing knob keeps one dial rather than two, and an hour is far
below the multi-day lifetimes every observed orphan reached.

The grace comparison uses the date seam (`Date` is data). The SIGTERM-to-SIGKILL
poll takes an injected `Clock` (`Duration` is behavior), matching
`AgentReaper`'s `graceAttempts` / `pollInterval` parameters.

## Flag mechanics

The column is `gc_orphan_processes_enabled`, added by migration **with no SQL
default**, so "nobody has chosen" stays a third state distinct from an explicit
`false`. The shipped default lives in exactly one place,
`Config.gcOrphanProcessesEnabledDefault = false`, and `ConfigRecord.toModel()`
resolves the column as `?? Config.gcOrphanProcessesEnabledDefault` — never
`?? false`, which would make the constant unreachable in any real install.

This follows `gc_profile_dirs_enabled`, the most recent flag to use the
tri-state pattern, and avoids the `auto_hibernate_enabled` defect: passing
`defaults:` makes `ADD COLUMN ... DEFAULT` backfill every existing row, after
which flipping the default needs a forcing `UPDATE` migration and a deliberate
opt-in becomes indistinguishable from a backfilled value.

The flag gates the collector **on top of** `gcEnabled`, the same way
`gcProfileDirsEnabled` does, so the GC master switch still turns everything off.

Migration, GRDB record and Codable model land in one commit, with the model
field optional so existing rows and JSON still decode.

**Enabling it for a soak:** call the `config.setGCOrphanProcessesEnabled` RPC,
which writes `gc_orphan_processes_enabled` on the singleton `config` row. It has
an RPC for the same reason its sibling gates do — the one phase whose mistakes
cannot be undone should not also be the one whose only switch is behind a
hand-edit of `state.db`. **Graduation:** once reap records across a soak show it
only ever caught real garbage, flip
`Config.gcOrphanProcessesEnabledDefault` to `true` — a one-line change that
reaches everyone who never touched the toggle while preserving every explicit
opt-out. The flag is deleted a release later.

## Record and restore

A new `ReapKind.orphanProcess` case joins `agentWorktree`, `scratchpad`,
`archivedWorktree` and `profileDir`. `worktreePath` carries the dead worktree the
process was rooted in, and a new optional `processDescription` field carries the
pid and a truncated argv, so a reap record says what was killed and not merely
where it lived. `tbd gc list` prints it: this is the one kind whose reap removed
nothing from disk, so `worktreePath` alone would say only where.

`ReapRecord`'s remaining fields (`branch`, `headSHA`, `snapshotRef`,
`quarantinePath`) are path- and git-shaped and go unused. That is a real cost of
hosting this in `OrphanGC` rather than standing up a new reconciler with its own
record type, and it is accepted: one reconciler with an imperfect record beats a
fourth sweep with its own scheduling, flags and wiring.

`restore(recordID:)` gains an explicit unsupported branch for `.orphanProcess`,
alongside the ones already there for `.scratchpad` and `.profileDir`. A killed
process cannot be restored, and the record exists as an audit trail rather than
an undo.

## Testing

- **Both flag branches.** With the flag off, a matching orphan survives a sweep
  untouched. With it on, the same orphan is reclaimed. Ungated GC behavior — the
  four existing collectors — is unaffected either way.
- **The three config states are distinguishable.** A pre-migration row reads
  NULL rather than `0`; an explicit `false` survives a change to
  `Config.gcOrphanProcessesEnabledDefault`; NULL follows it.
- **Descendant closure.** A three-generation tree is reclaimed whole, including
  a grandchild whose pgid differs from the root's, which is the case a plain
  `killpg` misses.
- **Live worktrees are untouched.** A process whose cwd is inside an active
  worktree is never a candidate, even when its ppid is 1.
- **Grace is honored.** An orphan younger than `gcGraceSeconds` survives; the
  same orphan is reclaimed once the window has passed.
- **Daemon self-exclusion.** With the daemon's own cwd inside the archived
  worktree, the sweep does not signal it.
- **Unreadable cwd is a skip.** A candidate whose cwd cannot be read is never
  reclaimed.
- **A stray scratchpad is a skip.** A directory under the Claude scratchpad base
  that names no worktree TBD knows is never a candidate, while an archived
  worktree's own scratchpad still is.
- **A pid younger than the cwd reading is a skip**, and so is one whose age
  could not be parsed, on both grace arms.

Process-level tests inject the signaller and the `ps` snapshot rather than
spawning real processes, following `AgentReaperTests`, which drives the same
escalation logic at `.milliseconds(1)`.

## Rejected alternatives

**Kill the escaped tree at teardown time instead of sweeping.** Neither observed
orphan would have been caught: both had already escaped before the teardown that
should have caught them. It is also the destructive-at-a-user-gesture path and it
reverses the `isTBDOwned` position. Deferred to its own spec rather than
rejected outright.

**Identify by TBD ancestry fingerprint rather than cwd.** Most precise about
ownership, and it misses exactly the observed cases: `pnpm` and `process-compose`
inherit no TBD marker in their argv, and macOS hides another process's
environment, so an env-var marker cannot be read at all.

**Reclaim any orphan under a TBD worktree whose terminal row is gone, without
requiring the worktree to be dead.** Catches more, and reclaims processes inside
worktrees the developer is actively using — far too easy to surprise someone
holding a deliberately detached server.

**Detect and report only, never kill.** Zero destructive risk and it solves
nothing: `HibernationCoordinator.detectOrphanedClaudeProcesses()` already scans
for `ppid == 1` and its results are, in the code's own words, "logged but not
killed in v1". An orphan surviving 11 days is direct evidence that nobody reads
such a log.

**An exemption mechanism so a user can protect a process.** Not in this version.
The flag is default-off and the worktree must already be archived, so the only
process at risk is one whose work the developer has already declared finished. An
escape hatch is cheap to add later if a soak shows real need, and every version
of it — a pattern file, an argv marker — is surface that has to be right the
first time.

## Reconciler doctrine

This spec answers the doctrine's question for a resource class that previously
had no answer: processes rooted in a worktree, escaped from every pane and
server structure, reclaimed by a named collector inside `OrphanGC`. The two
gaps it does not close are named rather than left implicit — tmux servers and
control-mode clients in issue #678, and teardown-time reaping in a follow-on
spec.
