# Automatic version updates — design

TBD is built from source and installed by `scripts/restart.sh`. Nothing tells
an operator that the running daemon is behind `main`, and the only way to move
forward is a restart that has, in the field, parked most of a live fleet. This
spec adds three things: a **build identity** every binary can report, an
**update check** that compares the running daemon with the latest commit on
`main`, and an **update path** that builds the new version out of place and
hands the fleet over to it without losing a session. The autonomous half
ships behind a default-off setting.

## 1. What is wrong today

- **No binary knows what it is.** `TBDConstants.version` is the literal
  `"0.1.0"` and has never changed. `daemon.status` reports it, `tbd --version`
  prints it, nothing compares it to anything. The only identity that exists is
  the daemon's executable *path*, which `DaemonBuildSkew` compares against the
  app's expectation to show a banner. A daemon thirteen commits behind `main`
  is indistinguishable from one at `main`.
- **No source of "latest".** The repo has no tags and no release workflow.
  Latest means the head of `main` on the upstream remote.
- **Restart is the only update, and it is not fleet-safe.** `restart.sh` sends
  the daemon `SIGTERM`, waits 0.5 s, deletes the pid and socket files, and
  starts the new daemon from the worktree's `.build`. The new daemon's
  startup reconcile probes every tmux window with a 15 s ceiling and treats a
  timeout the same as an absent window: it parks the Claude rows under it
  with `reason: .recovery` and **deletes** non-Claude rows and their tabs. On
  a machine still digesting the build, a probe that is merely slow parks the
  fleet. Field measurement: a 2026-09-02 restart parked 49 of 56 lane
  sessions in one pass, all with the same `hibernatedAt`. The un-park repair
  (`HibernationCoordinator.reconcileOnStartup`) runs *before* the parking
  pass, so it cannot fix the parks the same boot creates.
- **The launch environment is fragile.** The daemon inherits whatever
  environment launched the app. When LaunchServices relaunches the app at
  login it ignores the bundle's `LSEnvironment.PATH`; the daemon then runs
  with `/usr/bin:/bin:/usr/sbin:/sbin` and every git operation that needs a
  Homebrew tool fails (measured 2026-09-04: `git worktree add` in a git-lfs
  repo). That fix is a separate bug-fix PR, but the update path must never
  depend on the launcher's environment either.

## 2. Goals and non-goals

Goals:

- Every TBD binary reports the commit it was built from, and the daemon's
  `status` carries it.
- `tbd version` shows CLI, daemon, and latest-known commits and says plainly
  whether an update is available. The app shows a one-line notice.
- `tbd update` moves the whole installation (daemon, app, CLI) to the latest
  `main` with one command, building out of place and handing over without
  parking live sessions. Where a session is nonetheless parked, the update
  repairs it, paced.
- An `auto` mode runs that same path unattended, default off, with a durable
  log of what it did.
- The pieces that encode policy — how often to check, how many sessions to
  wake at once — live where an operator can edit them without a rebuild.

Non-goals:

- A release channel, tags, or signed downloadable builds. Latest is a commit.
- Zero-downtime RPC. During the handover the socket is briefly absent, as it
  is during any restart today; CLI calls in that window fail and retry as
  they do now.
- Rolling back. The previous build directory is kept on disk so an operator
  can restart from it by hand; no automated rollback.
- Changing how the pty holder transport survives restarts. It already does.

## 3. Placement

Per `docs/theory-placement.md`, compiled behavior is limited to facts,
mechanisms, and invariants:

- **Facts (compiled):** build identity; latest commit on `main` as last
  observed; when it was observed; whether the running daemon is behind.
- **Mechanisms (compiled):** the successor-first handover; reconcile probes
  that distinguish *absent* from *unknown*; a post-reconcile un-park pass;
  compare-and-delete of the pid file.
- **Theories (authored, in `scripts/update.sh`):** the check interval's
  default, the wake concurrency and stagger, whether the app is restarted,
  which build configuration to install. All are constants at the top of the
  script or flags on it.
- **The one policy the daemon holds is the setting itself** — `off`,
  `check`, or `auto` — because the timer that runs the check has to live in
  a long-lived process, and the daemon is the only one TBD owns.

## 4. Build identity

A `BuildIdentity` value in `TBDShared`:

- `commit` (full SHA), `shortCommit`, `branch` (may be `HEAD` for a detached
  build), `builtAt` (ISO-8601), `sourceWorktree` (absolute path), `dirty`
  (Bool), `origin` (how it was learned: `.stamp`, `.worktreeHead`).
- Learned at process start, once, from **a JSON sidecar next to the
  executable**: `TBDBuildIdentity.json` in the same directory as the resolved
  binary, or in `Contents/` of the app bundle. The sidecar is written by the
  build wrapper before the compiler runs (see §7), so its contents describe
  the tree the binary came from. A build that bypassed the wrapper has no
  sidecar; the loader then falls back to `git rev-parse HEAD` of the worktree
  derived from the executable path (the parent of `.build`), marked
  `.worktreeHead` so a consumer can tell it might be stale, and finally to
  `nil`.
- `daemon.status` gains an optional `buildIdentity` field. `tbd --version`
  prints `0.1.0 (<shortCommit>)` when known. The CLI installed into
  `~/.local/bin` is a hard link and has no sidecar; it reports the fallback
  or nothing, which is acceptable — the daemon's identity is the one that
  matters.

Why a sidecar and not a generated Swift file: a generated source file makes
every commit a rebuild of `TBDShared` and everything above it; a sidecar
changes nothing in the compile graph. Why not `Bundle.module` resources: the
daemon and CLI run from places where the resource bundle is not next to them,
and `Bundle.module` traps when the bundle is missing.

## 5. Update check

A daemon actor `UpdateChecker` (new file under `Sources/TBDDaemon/Update/`,
injected clock per the repo rule):

- Runs only when `update_mode` is `check` or `auto`. Reads the setting on
  each tick so `tbd config set` takes effect without a restart.
- A tick runs `git ls-remote <url> refs/heads/main` where `<url>` is the
  `upstream` remote of the daemon's source worktree, else `origin`, else
  the setting is unusable and the checker logs once and idles. `ls-remote`
  moves no objects and writes nothing to any worktree.
- Result is held in memory as `UpdateStatus { latestCommit, observedAt,
  relation }` with `relation` one of `upToDate`, `behind`, `unknown`.
  `behind` is "latest differs from ours and ours is not ahead of it";
  ahead-ness is decided by `git merge-base --is-ancestor` in the source
  worktree when the latest commit is present locally, otherwise the relation
  is `behind` with `behindBy == nil`. When the update clone (§7) exists and
  has fetched, `behindBy` is `rev-list --count` there.
- Exposed as an optional `update` field on `daemon.status`, and by
  `tbd version` (which prints the cached status, or runs one check
  synchronously with `--check`).
- Interval: the daemon uses a constant (one hour) unless the environment
  variable `TBD_UPDATE_CHECK_INTERVAL` overrides it; the script's `--auto`
  path does not depend on the interval.
- In `auto` mode, when the relation is `behind` and the latest commit is
  not one the checker has already attempted, it launches
  `<sourceWorktree>/scripts/update.sh --auto` detached (own session, stdout
  and stderr to `~/tbd/updates/update.log`) and records the attempted commit.
  A failed attempt is not retried until `main` moves; a manual `tbd update`
  always runs. Nothing else in the daemon acts on an update.

## 6. The setting

A config column `update_mode`, added by a timestamped SQL migration
(`Sources/TBDDaemon/Database/Migrations/<stamp>_config_update_mode.sql`;
the numbered Swift block is frozen). The column is `TEXT` with **no
`DEFAULT` clause**, in the house tri-state style: a pre-migration row reads
`NULL` ("never chose") and resolves through the single constant
`Config.updateModeDefault`, which is `.off`. Graduation later edits that one
constant and nothing else, and a deliberate opt-in stays distinguishable from
the backfilled value.

The value decodes to `enum UpdateMode: String, Codable, Sendable { off,
check, auto }` in `TBDShared`. The GRDB `ConfigRecord` field is `String?`,
resolved in `toModel()` with an injected default so tests drive both values;
an unrecognised string resolves to the default and is logged once. The shared
`Config` model, the record, and the migration change in one commit.

Surfaces: `tbd config get` prints it; `tbd config set update-mode
<off|check|auto>` writes it through a `config.setUpdateMode` RPC that writes
the column on every call; the app's Settings shows a three-way picker fed
from `daemon.capabilities` (which gains `updateMode`) and writes through the
same RPC. The checker reads the setting on each tick, so no `*Live` twin is
needed: a change takes effect at the next tick without a restart.

Default-off satisfies the "large or risky behavior" rule: with the default,
the daemon runs no timer and spawns nothing. `check` is a read-only network
call. `auto` is the only branch that acts.

## 7. The update path (`scripts/update.sh`, `tbd update`)

`tbd update` is a thin CLI command: it asks the daemon for its source
worktree, execs `<sourceWorktree>/scripts/update.sh` with the user's
arguments, and inherits the user's environment. The script is the procedure:

1. **Locate or create the update clone** at `~/tbd/updates/src`
   (`TBDConstants.updatesDir`, honors `TBD_HOME`). A dedicated clone, not a
   worktree of the operator's checkout: it must not appear in anyone's
   `git worktree list`, must not be reaped by `reclaim-build.sh` (which
   scans TBD worktrees and `.claude/worktrees`, never `~/tbd/updates`), and
   must be safe to `checkout --detach` at any time. Its `origin` is the
   upstream URL resolved as in §5.
2. **Fetch and check out** `origin/main` detached. If the fetched
   `scripts/update.sh` differs from the running copy, re-exec the fetched one
   with the same arguments (guarded by an environment marker so it happens
   once). This is how the procedure itself updates.
3. **Stamp** `TBDBuildIdentity.json` into `.build/<config>/` (commit, branch,
   time, worktree, dirty) and **build** `TBDDaemon`, `TBDApp`, and `tbd`
   with `scripts/swift-safe build -c release --product …`, the same module
   cache flags as `restart.sh`. A failed build stops here; the running
   installation is untouched.
4. **Assemble, sign, and install** the app bundle to `/Applications/TBD.app`
   exactly as `restart.sh` does today. That code moves out of `restart.sh`
   into `scripts/restart-bundle-lib.sh` so the two scripts share it; the
   sidecar is copied into `Contents/`, next to `SourceWorktreePath.txt`,
   which now points at the update clone.
5. **Hand over** (§8): start the new daemon with
   `TBD_HANDOVER_FROM_PID=<old pid>` and wait until `tbd daemon status`
   reports the new executable path and build identity, bounded at 120 s.
6. **Restart the app** — kill the exact installed executable path, `open`
   the bundle with `--env PATH=$PATH` as `restart.sh` does. `--no-app` skips
   this. The app is a viewer; nothing in it holds a session.
7. **Repair parks.** List terminals; every row parked with
   `hibernateReason == recovery` and `hibernatedAt` after the handover began
   is a candidate. The daemon's own post-reconcile pass (§8) has already
   un-parked those whose pane still runs Claude; what remains are sessions
   whose process is genuinely gone. The script wakes them with
   `tbd terminal wake`, `WAKE_CONCURRENCY` at a time (default 3, the
   app's `wakeAllBatchSize`), `WAKE_STAGGER_SECONDS` apart (default 2),
   because N simultaneous `claude --resume` respawns have taken the machine
   down before (#284, #367). `--no-wake` skips this; `--wake-only` runs only
   this step against a daemon that is already new.
8. **Log** every step with a timestamp to `~/tbd/updates/update.log` and
   print a summary: old commit, new commit, commits advanced, sessions
   un-parked by the daemon, sessions woken by the script, sessions it could
   not wake and why.

`--check` prints the same comparison as `tbd version --check` and exits.
`--dry-run` does everything up to the build without installing or handing
over. `--debug` builds the debug configuration. `--auto` is what the daemon
passes: non-interactive, and it refuses to run if another update is in
flight (a lock file under `~/tbd/updates/`).

Everything the script leaves under `~/tbd/updates/` sits outside the three
named reconcilers on purpose, because none of it can accumulate: each entry
is a fixed singleton path that every run reuses or overwrites, never a
per-request resource.

- `src` — one long-lived clone that every update reuses. It appears in no
  `git worktree list` and `scripts/reclaim-build.sh` never scans it. A run
  that dies mid-fetch or mid-build leaves the same clone the next run fetches
  into.
- `update.lock` — one file naming the running update's pid. A lock left by a
  crashed run names a dead pid; the next run takes it over. Acquisition is
  atomic (a noclobber create), so two simultaneous runs cannot both hold it.
- `update.log` — one append-only log.
- `wake` — one scratch directory for the wake step's per-terminal results,
  emptied at the start of every wake and removed at its end. A run killed
  mid-wake leaves it for the next run to empty.
- `previous/TBD.app` — exactly one bundle, the one the last update replaced,
  overwritten by the next update and kept as the no-rebuild route back.

Removing any of them is an operator gesture, and the next update recreates
it. See `docs/updating.md`.

The script is written to the same conventions as `restart.sh` and gets a
`scripts/update.test.sh` covering argument handling, the self-re-exec guard,
the wake-candidate filter, and the batching, against a fake `tbd`.

## 8. Handover

Sequence, with the app running throughout:

1. The successor starts with `TBD_HANDOVER_FROM_PID` set. Its
   single-instance gate finds the pid file naming a live `TBDDaemon`. Today
   that exits. In handover mode, when the live pid equals the variable, the
   successor instead **writes its own pid over the file first**, then sends
   the predecessor `SIGTERM`, then waits for the predecessor's pid to exit —
   polling, bounded at 30 s, then `SIGKILL` and one more wait. Only then
   does it continue its normal start. A predecessor that outlives `SIGKILL`
   aborts the start: the successor writes the predecessor's pid back into the
   file (three attempts, 100 ms apart) and exits, and the result says whether
   the write-back landed. A write-back that never lands is not a two-writer
   hazard — `SIGKILL` cannot be caught, so a pid still present after it is in
   an uninterruptible kernel wait, not serving, and the successor is exiting
   too. The file then names a dead or dying pid, which is the ordinary
   stale-pid case with an existing reconciler: `PIDFile.cleanupIfStale` at
   the top of `Daemon.start()` removes it, and the app's poller starts a fresh
   daemon from the installed bundle. Recovery is delayed, not corrupted.
2. The predecessor's `stop()` runs as today, except it **removes the pid file
   only if the file still names its own pid** (compare-and-delete) and removes
   the port file the same way. Its socket unlinks are unchanged: the
   successor has not bound yet, so there is nothing to protect.
3. The successor binds the sockets and serves.

Why successor-first: the app polls every two seconds and spawns a daemon the
moment the socket is missing *and* the pid file does not name a live daemon.
With the successor's pid in the file from the first instant, every spurious
spawn — the app's, or a stray `restart.sh` — exits at the gate. This closes
the race that a plain kill-then-start opens, and it needs no new RPC.

Why not overlap (successor serving while the predecessor drains): two daemons
would be two writers on `state.db` and two reconcilers with different
opinions. The brief socket gap is the price of a single writer, and it is the
same gap every restart has today.

Reconcile hardening, which applies to every daemon start and is what makes
the handover safe:

- `TmuxManager` gains tri-state probes: `probeServer` and `probeWindow`
  return `alive`, `absent`, or `unknown`. `absent` requires tmux to have
  answered (exit status from a live server saying no such window or server);
  a timeout, a spawn failure, or an unparseable answer is `unknown`. The
  existing `Bool` probes stay for their other callers.
- `reconcileTerminalsWhileLocked` acts only on `absent`. On `unknown` it logs
  the terminal and moves on, leaving the row live. A wedged tmux therefore
  parks nothing; an operator can still park by hand. The delete arm for
  non-Claude rows likewise fires only on `absent`.
- After `performStartupReconciliation`, the daemon runs
  `hibernationCoordinator.reconcileOnStartup()` a second time. The first
  run still precedes reconcile so shared scratch servers are reaped from a
  consistent view; the second run un-parks anything the same boot parked
  whose pane demonstrably still runs Claude. The pass is cheap: it only
  examines parked rows.
- Every other caller that mutates on a negative probe takes the tri-state
  probe too, and treats `unknown` as a refusal to act: `terminal.recreateWindow`
  (which parks and kills on absence) returns a retryable error and touches
  nothing; the activity rail's tmux leg reports `unknown` so a close that
  respects rails fails closed; and the wake path's recreate arm fails the wake
  and leaves the row parked rather than kill a window it could not see.
  Callers that only skip on a negative answer keep the `Bool` probes.

Holder-transport sessions are unaffected: the predecessor's `releaseAll` and
the successor's `adoptAll` already bracket a restart, and the handover
shortens the gap between them rather than lengthening it.

## 9. Surfaces

- `tbd version` — CLI commit, daemon commit and executable path, latest
  known commit and when it was observed, relation, and one line: `Update
  available: <short> → <short> (N commits behind). Run: tbd update`, or
  `Up to date`, or `Unknown — run tbd version --check`.
- `tbd daemon status` — gains `buildIdentity` and `update` in JSON; the
  text form adds `Build:` and `Update:` lines.
- App — a one-line notice in the same place as the daemon-build-skew banner,
  from the same `daemon.status` response, dismissible per commit.
- `tbd config get|set update-mode`.
- `docs/updating.md` — the operator-facing page: what `tbd update` does,
  what happens to running sessions, the modes, the log, and how to restart
  from the previous build by hand.

## 10. Testing

- `BuildIdentity` loader: sidecar present; sidecar absent with a git
  worktree derivable from the path; neither.
- `UpdateStatus` relation: equal commits, local ahead, local behind with and
  without a count, unknown latest.
- `UpdateChecker` with an injected clock: `off` runs nothing; `check`
  ticks and never launches; `auto` launches once per latest commit and not
  again for the same commit; setting changes take effect on the next tick.
- Handover gate: pid file names the handover pid — successor claims the file
  and signals; pid file names a different live daemon — successor exits as
  before; pid file stale — normal path.
- `PIDFile` compare-and-delete: removes when it names our pid; leaves a
  file naming another pid.
- Tri-state probes and reconcile: `unknown` leaves rows live and deletes
  nothing; `absent` parks and deletes as before; the second un-park pass
  clears a park made by the same boot.
- A schema suite under `Tests/TBDDaemonTests/Config/` in the shape of
  `RemoteDeleteFlagTests`: the column reads `NULL` before any gesture,
  migrating only to the identifier before it reproduces the old schema, and
  resolution is asserted against both default values. The migration passes
  `scripts/lint-migrations.py`. Both branches of `update_mode` wherever
  behavior forks.
- `scripts/update.test.sh` as in §7.

## 11. Rollout

- Ships default-off. The first run is manual: `tbd update` from a login
  shell. Its summary reports what it did to running sessions.
- Soak in `check` for the notice, then `auto` for one operator, then
  consider flipping the default to `check` (a forcing `UPDATE` migration,
  because the column default backfills).
- The PATH bug fix is a prerequisite for `auto` on this machine only in the
  sense that a daemon with a bare PATH cannot build; the new daemon carries
  its own PATH fallbacks, and the script runs under the invoking shell.

## 12. Rejected alternatives

- **A `daemon.restart` RPC that execs the new binary in place.** Loses the
  successor-first pid claim, cannot change the environment of the new
  process without a wrapper anyway, and puts the update procedure into
  compiled code where every change to it is a rebuild.
- **Building in the operator's worktree.** The worktree may be on a feature
  branch, dirty, or mid-build; `restart.sh` already refuses to install from
  such a tree. A dedicated clone is always on `main`.
- **Overlapping daemons with a retire handshake.** Shorter socket gap, but
  two `state.db` writers and two reconcilers during the overlap. Not worth
  the gap it saves.
- **Treating a probe timeout as "gone" but retrying later.** A retry does
  not undo a deleted tab. The row must not be touched on ambiguous evidence
  in the first place — the same conclusion as the bounded terminal recovery
  design.
- **A generated Swift source for the commit.** Rebuilds `TBDShared` on every
  commit and every worktree switch.
- **Version numbers.** Nothing produces them; a commit is what an operator
  can look up.

## 13. Decisions taken from the request, and what remains open

The request (relayed 2026-09-04) fixed: opt-in and default-off; out-of-place
build; hand over without killing sessions where the architecture allows,
paced wake otherwise; never lose a session's prompt or state; a clear log;
`tbd version` and an app notice; tests and a doc section. The following were
decided here and should be confirmed by a human before `auto` is enabled
anywhere:

- Latest means the head of `main` on the `upstream` remote, else `origin`.
- The update clone lives at `~/tbd/updates/src` and builds release.
- The check interval defaults to one hour.
- `auto` restarts the app as well as the daemon.
- Wake concurrency 3 and stagger 2 s are script constants, not settings.
