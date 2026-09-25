# Stable session addressing — design

Status: **proposed**. The open questions at the end need the repository owner's answers
before implementation starts.

A TBD terminal row names a live session through a chain of addresses: the worktree row's
tmux server name, the socket file that name resolves to, and the window and pane ids
recorded on the terminal row. Every link in that chain is re-derived when a process
restarts, and none of them is checked against an identity the row already holds. This
document states the invariant those addresses must satisfy and proposes how TBD's tmux
transport meets it.

Scope: the tmux sockets and pane identities TBD itself creates and addresses. The holder
transport already meets the invariant (see "What already holds"), and is in scope only as
the model to follow.

## How a session is addressed today

- **Server name.** `TmuxManager.serverName(forRepoPath:)` derives `tbd-<8 hex>` from a
  djb2 hash of the repository path. The name is persisted on each worktree row
  (`worktree.tmuxServer`), and reconcile rewrites a stored name only after tmux
  affirmatively reports that the stored server has no live windows for that worktree.
  The name is therefore already an identity of record.
- **Socket file.** Every daemon tmux invocation addresses its server with `-L <name>`
  (`TmuxManager`'s command builders; the control-mode connection in
  `TmuxControlConnection` does the same). The app's `TmuxBridge` does too, from its own
  process. tmux resolves `-L <name>` to `$TMUX_TMPDIR/tmux-<uid>/<name>`, or
  `/tmp/tmux-<uid>/<name>` when `TMUX_TMPDIR` is unset. `runTmux` passes
  `environment: nil`, so each child inherits the daemon's environment wholesale, and the
  directory half of the address comes from however the daemon happened to be launched:
  by `scripts/restart.sh` through `open`, by the app spawning `tbdd`, by a LaunchServices
  login relaunch, or directly from a shell. Nothing in `Sources/` or the launch scripts
  sets or records `TMUX_TMPDIR`. The socket path is re-derived on every call and
  persisted nowhere.
- **Pane coordinate.** Terminal rows record `tmuxWindowID` (`@N`) and `tmuxPaneID`
  (`%N`). tmux numbers both per server, starting again from the beginning whenever a
  server is recreated, and several worktrees of one repository share one server.
- **Pane identity stamp.** Since #595, every spawn and respawn stamps the pane option
  `@tbd_terminal_id` with the terminal row's UUID. Panes spawned by builds before #595
  carry no stamp, and the stamp is deliberately not backfilled.

## Observed failure modes

### 1. Socket-path drift reads a live server as gone

If the daemon's `TMUX_TMPDIR` differs from the one in effect when a server was created,
the same `-L` name resolves to a different socket file. tmux then prints
`error connecting to <path> (No such file or directory)`. Reproduced locally with tmux
3.6a: a server started under a private `TMUX_TMPDIR` answers normally there, while
`tmux -L <same name>` from a shell without it reports exactly that error against
`/private/tmp/tmux-<uid>/<name>`.

`TmuxPresenceClassifier.indicatesAbsentServer` (from #804) treats that `ENOENT` spelling
as affirmative absence, alongside `no server running on`. In
`reconcileTerminalsWhileLocked`, a server probe of `.absent` makes every window probe
`.absent` without asking. Every non-parked tmux row in the worktree then goes down the
park-or-delete path: resumable Claude rows are parked, and every other row is deleted
along with its tab. The server was alive all along; the daemon looked in the wrong
directory.

The same misreading surfaced first at pane level. #731, opened on 2026-08-26, records the
field symptom: `tbd terminal send` refused to type into a healthy pane, reporting that it
"no longer exists" on its server. At the same moment, `tmux -L <server> list-panes`
listed the pane as live, and a direct `send-keys` reached it. #731 (merged 2026-09-23)
split `PaneSendTarget.missing` into `.absent` and `.unreachable`, deciding between them
with a positive server-wide inventory probe rather than tmux's error prose. That closes
the pane-level half. The server-level half, `probeServer` and `probeWindow` in the
reconcile sweep, still reads the `ENOENT` message as absence on current `main`.

Pinning the tmux executable does not help. #909 seeds a saved tmux path at install so
that a login relaunch can still find tmux. It pins the binary, not the socket directory.

### 2. Pane-id reuse after a server restart

On 2026-09-22, after a laptop reboot, two terminal rows on the same repository's server
both recorded window `@2` and pane `%2`, and neither was parked. The pane's
`@tbd_terminal_id` answered with only one of the two terminal ids. `tbd terminal output`
on the stale row showed the live session's screen, and closing the stale tab would have
run `kill-window` against the live session.

The reboot killed every tmux server. The recreated server numbered its windows from the
beginning, and a freshly spawned session took a coordinate that a pre-reboot row still
recorded. The coordinate is numeric and per server, so this is plain reuse, unrelated to
either terminal's identity.

The record does not establish which startup path let the stale row through. One route
fits all of the facts: a parked stale row was un-parked by
`HibernationCoordinator.reconcileOnStartup`, which on that build checked only that the
window existed and was running `claude`, never the stamp. That is an inference, not an
observation. On current `main`:

- **Live-row reconcile** (`reconcileTerminalsWhileLocked`, since #704) reads the pane's
  stamp. When the stamp names a different terminal, it treats the row like a gone
  window and parks or deletes it.
- **Startup un-park** (`reconcileOnStartup`, since #901, merged 2026-09-23) refuses to
  clear a parked row when the stamp names a different terminal. It also refuses when the
  pane reads `.absent` or `.unreachable`.
- **Kill paths** have no stamp check on `main`. #902 (open, CI green) adds
  `TmuxManager.paneOwnership(terminalID:server:paneID:)`, which answers `.owned`,
  `.ownedByAnother` or `.unverifiable`, and lets only `.owned` proceed to `kill-window`
  at every site that tears down a window by recorded coordinate. It is rebased over
  #731, so `.unreachable` maps to `.unverifiable`.
- **Unstamped panes** are trusted everywhere, for backward compatibility.

### 3. Restarts re-derive state instead of re-registering it

A daemon restart has repeatedly rebuilt its picture of the fleet from probes instead of
confirming the identities its rows already held:

- **2026-07-08** – a restart left 33 terminal rows sharing one `suspendedAt`, equal to
  the minute the daemon started. The rows were bulk-marked by an earlier suspend path,
  which has since been removed; the sessions themselves stayed alive in tmux.
- **2026-09-02** – a restart parked 49 of 56 live sessions in one reconcile pass,
  because tmux probes timed out on a loaded machine and read as absence. The
  `TmuxPresence` tri-state, which came with #804, fixed that reading.

Each fix closed one reading. The shape underneath is the same in all three failure
modes. After a restart, the daemon asks "what is at the address I would compute now?"
when it should ask "is the session I recorded still at the address I recorded?"

## The invariant

1. **One address for life.** A TBD session — a terminal row — is reachable at one stable
   address from creation to deletion. The address is recorded when the resource is
   created and is not recomputed from ambient state afterwards.
2. **Restarts re-register.** A daemon, app or machine restart re-registers the identity
   the row already holds. It confirms the recorded address and identity, or concludes
   that they are gone. It never mints a new address, and never guesses one from the
   current environment.
3. **Absence needs an affirmative answer at the correct address.** A session is gone
   only when the recorded address positively answers "not here", or the recorded
   identity is positively no longer the one there. A failed lookup at an address that
   might be wrong is ignorance, and ignorance parks nothing, deletes nothing and kills
   nothing.

The third clause restates, for addresses,
[`2026-08-11-bounded-terminal-recovery-design.md`](2026-08-11-bounded-terminal-recovery-design.md)'s
rule that only affirmative evidence of absence licenses a destructive transition.

## What already holds

- **The holder transport.** A holder session's rendezvous socket is
  `TBDConstants.holdersDir()/<session uuid>.sock` (`HolderRendezvous`). The path is
  derived from `TBD_HOME` through `TBDConstants`, never from ambient tmux state, and is
  validated at derivation time against Darwin's 104-byte `sun_path`. Reconcile judges a
  holder row against its own rendezvous and recorded process identity, and `OrphanGC`
  reclaims leftover rendezvous files behind `gcHolderRendezvousEnabled`. That is the
  invariant as built. The tmux transport should converge on the same shape.
- **The server name.** It is persisted per worktree row and changes only on affirmative
  evidence.
- **Pane identity.** The stamp exists (#595) and is consulted by live-row reconcile
  (#704) and startup un-park (#901). With #902 it will also be consulted on every kill
  path.
- **Pane-level reachability.** `.absent` and `.unreachable` are distinct (#731).

What does not hold: the socket half of the address is ambient, and server absence is
still concluded from a failed lookup that may have used the wrong directory.

## Design options

### (a) Pin `TMUX_TMPDIR` for every TBD tmux invocation

Every tmux child TBD spawns — daemon one-shots, the control-mode connection, the app's
`TmuxBridge` — gets `TMUX_TMPDIR` set to a new `TBDConstants.tmuxDir()` (for example
`~/tbd/tmux`), which honors `TBD_HOME`. Servers keep their `-L` names.

- **For:** small change; one environment entry at three spawn sites; names and argv
  shapes unchanged; tmux's own `tmux-<uid>` subdirectory keeps its permission check.
- **Against:** the address is still recomputed on every call, now from `TBD_HOME`
  instead of `TMUX_TMPDIR`. A process with a different `TBD_HOME` drifts in exactly the
  same way. It still records nothing a restart can re-register against, so an `ENOENT`
  is still not evidence that the server is gone.
- **Against:** the moment the pin ships, every existing server in `/tmp/tmux-<uid>/`
  becomes unreachable by name. Without separate adoption machinery the next reconcile
  would read them all as absent, the very failure this document exists to remove.
- **Against:** `runTmux` currently passes `environment: nil`, and passing an
  environment replaces the child's wholesale. The pin therefore means building a full
  child environment at each site, which interacts with `SpawnBaseEnvironment`'s
  existing rules.

### (b) Address servers by a recorded absolute socket path with `-S`

When TBD creates a server, it chooses an absolute socket path under a directory derived
from `TBDConstants`, such as `~/tbd/tmux/<server name>`. It persists that path, and
every later invocation for that server uses `-S <path>`.

- **For:** the address is data, not derivation. It survives any change in launch
  environment, `TBD_HOME` or tmux version, and a restart re-registers it by reading it
  back.
- **For:** an answer at the recorded path is an answer about the right server. On a
  path inside a TBD-owned directory, `ENOENT` means the file TBD created is gone, and
  `ECONNREFUSED` means nothing is listening there. Both become affirmative.
- **For:** it follows the holder precedent, including `sun_path` validation at
  derivation time. A default path such as `/Users/<user>/tbd/tmux/tbd-1a2b3c4d` is
  roughly 45 bytes, well inside the budget. A deep `TBD_HOME` can overflow it, and
  tmux then fails with `File name too long` (reproduced locally), so the check has to
  happen before tmux is asked.
- **For:** adoption is natural. An existing server's current socket path is simply
  recorded as its path of record.
- **Against:** a schema change, and every command builder, the control-mode connection
  and the app bridge must take an address value instead of a name string. That is a
  wide mechanical diff across load-bearing paths.
- **Against:** operators and user-land scripts that type `tmux -L tbd-…` stop reaching
  new servers. The recorded path has to be exposed (see "User-land surface").

### (c) Keep `-L`, record the socket path at creation, verify it against the server process

Keep `-L` for addressing, but record each server's socket path and pid when it is
created, and check the recorded path against the live server process before trusting a
negative answer.

- **The process title does not carry the path on Darwin.** Checked locally with tmux
  3.6a: the server's `ps` command line is the argv of the client that spawned it, for
  example `tmux -L probe-x new-session -d -s main …`. It names the server but not its
  directory. The bound path is visible only through `lsof -U -p <server pid>`, or by
  asking the server `display -p '#{socket_path}'`, which needs a connection that works.
- **For:** no change to the argv of any existing call.
- **Against:** it records the right fact and then keeps addressing by the wrong one. A
  mismatch is detected, not prevented, and every negative answer costs an extra process
  inspection. `lsof` is slow and its output format is not a stable interface.
- **Partly useful:** as a one-time adoption probe (see "Migration"), inspecting the
  recorded server process is a targeted, per-server test. That is different in kind
  from the rejected global `ps` veto.

### (d) Make the pane stamp the identity of record everywhere

`@tbd_terminal_id` becomes the identity every path consults before it trusts a recorded
coordinate, whether it is reading, sending, un-parking or killing.

- **Done:** stamping at spawn (#595); the live-row reconcile check (#704); the startup
  un-park check (#901).
- **In flight:** kill-path ownership through `paneOwnership` (#902), which leaves two
  gaps it records itself. `HibernationCoordinator.wake`'s old-window kill still relies
  on a database-level duplicate-claim check. Several guarded sites check and then kill
  without holding the server resource lock.
- **Remaining gap:** unstamped panes are trusted everywhere. That is safe against reuse
  only because every server incarnation created since #595 stamps every pane. Nothing
  records which incarnation a row belongs to, so the safety is an accident of timing,
  not a checked property.
- **Complement, not substitute:** (d) protects the pane half of the address and says
  nothing about which socket was asked. It is required under any server-level option.

## Recommendation

Adopt **(b) together with (d)**, and record one more fact per server: the **server
incarnation**, meaning its pid and process start time. The pair is the same identity
check `AgentReaper`'s holder leg already makes before signalling a process.

### Components

- **`TBDConstants.tmuxSocketsDir(environment:)`** – `~/tbd/tmux`, honoring `TBD_HOME`,
  created with mode `0700`. It sits directly under the config directory, for the same
  `sun_path` reason as `holdersDir`.
- **A `TmuxRendezvous`-style helper** – composes `<dir>/<server name>`, validates it
  against the 104-byte limit at derivation time, and throws a typed error rather than
  letting `bind` or `connect` fail later.
- **A typed `TmuxServerAddress`** – either `.socket(path)` for recorded servers or
  `.legacyName(name)` for servers not yet adopted. Every command builder, `runTmux`
  caller, the control-mode connection and the app bridge take this value instead of a
  bare name string. `-L` survives only inside the legacy case.
- **A recorded server identity** – socket path, server pid and server start time,
  written when TBD creates a server (read back with `display -p '#{pid}'`) and when
  adoption confirms an existing one.

### The absence rule

For a recorded server, the server is affirmatively gone when either of these holds:

- the recorded socket path answers `ECONNREFUSED`, or `ENOENT` on a path inside
  `tmuxSocketsDir`; or
- the recorded pid is not running, or is running with a different start time.

Any other failure is `.unknown`. A server that answers with a different pid or start
time is a new incarnation. Every terminal row recorded against the old incarnation is
then affirmatively stale, whatever its pane coordinate or stamp says, so pane-id reuse
across a server restart is detected structurally rather than by stamp comparison alone.

For a legacy server, reached by `-L`, `ENOENT` stops being evidence. Only
`no server running on` (`ECONNREFUSED`) remains affirmative, together with the targeted
process check described under "Migration". Everything else is `.unknown`, and the row is
left alone.

### Pane identity

Keep #704, #901 and #902's stamp checks. Add the incarnation check ahead of them. A row
whose recorded incarnation matches the live server is judged by its stamp exactly as
today. A row whose incarnation does not match is stale without consulting the pane at
all. An unstamped pane is then trusted only when the row's recorded incarnation matches,
which turns the current timing accident into a checked property.

### Migration: adopting existing servers without killing them

Existing servers live at whatever path the daemon's environment gave them, usually
`/tmp/tmux-<uid>/<name>`. Adoption records where each one is. It never moves one.

1. **Adoption pass.** Runs once per server name found on local worktree rows that have
   no recorded address. It runs at startup and again on demand, holding the server
   resource lock. It asks, in order:
   - `-L <name>` under the daemon's current environment;
   - `-S /tmp/tmux-<uid>/<name>`, the path an unset `TMUX_TMPDIR` produces, which is
     the common drift pair.

   The first candidate that answers is asked for `#{socket_path}` and `#{pid}`. Its
   answer is recorded as the server's address and incarnation.
2. **Adopted in place for life.** An adopted legacy server keeps its `/tmp` path until
   it exits, usually at the next reboot. No session is killed, moved or respawned.
3. **New servers at the new path.** With the flag on, servers TBD creates go under
   `tmuxSocketsDir` and are recorded at creation. Once every legacy server has exited,
   the fleet is fully on recorded paths.
4. **Unresolved legacy names.** A name that no candidate reaches stays unadopted and is
   judged by the legacy absence rule. To keep genuinely dead servers reclaimable, the
   pass applies one targeted check. On Darwin a TBD-spawned server's process title
   carries `-L <name>` (verified above), so the absence of any process owned by this
   uid whose argv names `-L <name>` counts as affirmative evidence that the server is
   gone. This check is scoped to one server name. The rejected global `ps` veto could
   not be.

### Storage

The recorded identity belongs to a server, and several worktree rows share one server.
The proposal is a new `tmux_server` table keyed by server name, with `socket_path`,
`server_pid` and `server_started_at` columns and a `recorded_at` timestamp. Worktree
rows keep `tmuxServer` as the key. A missing row means unadopted. Per the migration
rules this ships as one `.sql` migration plus the GRDB record and the Codable model in
the same commit, with every new field optional. Open question 2 covers the alternative
of per-worktree columns.

### Flag

This replaces a load-bearing path, the addressing of every tmux call, so it ships behind
a default-off flag: `config.stable_tmux_addressing_enabled`. The column is added with no
SQL `DEFAULT`, so NULL stays "never chosen", and the shipped default lives only in
`ConfigRecord.toModel()`'s `?? Config.stableTmuxAddressingDefault`.

- **Off:** today's `-L` addressing and new servers under the ambient directory, except
  that the legacy absence rule applies whether or not the flag is on, if open
  question 4 is answered that way.
- **On:** adoption pass, `-S` addressing for recorded servers, new servers under
  `tmuxSocketsDir`, and the incarnation check.
- **Soak:** enable it on development machines through Settings or the config RPC, and
  watch the adoption log lines and reconcile's park and delete counts across reboots and
  daemon restarts.
- **Graduation:** flip the default constant. Delete the legacy case once no installation
  can still carry an unadopted server, which is after any reboot on a flag-on build.

Tests cover both branches, and the three flag states: a pre-migration row reads NULL
rather than `0`, and an explicit `false` survives a change to the default constant.

### Named reconciler for socket files

tmux never unlinks its socket when a server exits, and `tmuxSocketsDir` is a new kind of
durable resource that TBD creates. Following
[`2026-08-15-named-reconciler-doctrine-design.md`](2026-08-15-named-reconciler-doctrine-design.md),
**`OrphanGC`** gains a tmux-socket leg, gated additionally by its own default-off
sub-flag in the manner of `gcHolderRendezvousEnabled`. The leg reclaims a socket file in
`tmuxSocketsDir` whose connect answers `ECONNREFUSED` and whose server identity row is
absent or names a dead incarnation. It keeps young files and anything whose probe does
not answer. The same leg deletes `tmux_server` rows that no worktree row references.
Legacy files in `/tmp/tmux-<uid>/` are outside it: that directory is shared with the
user's own tmux and is not TBD's to sweep. TBD simply stops adding to it.

### User-land surface

Following "Compile only what user-land cannot do well", the daemon exposes the fact and
leaves tooling to user land. The recorded socket path joins the worktree's JSON output
in the CLI, so an operator or a user-land script can run `tmux -S "$(…)" list-panes`.
Addressing itself stays compiled, because it is on the per-call path of every tmux
operation in the fleet.

## Open questions for the repository owner

1. **Which addressing mechanism?**
   - (a) Pin `TMUX_TMPDIR` to a TBD-owned directory and keep `-L`.
   - (b) Record an absolute socket path per server and address it with `-S`.
   - (c) Keep `-L`, record the path, and verify it against the server process.
   - Recommendation: (b). Only (b) makes the address data a restart can re-register
     against, rather than a computation that can drift again.
2. **Where does the server identity live?**
   - A new `tmux_server` table keyed by server name.
   - New nullable columns on the worktree row, beside `tmuxServer`.
   - Recommendation: the table. The identity belongs to the server, and per-row copies
     can disagree across the several worktrees that share one server.
3. **How are existing servers migrated?**
   - Adopt in place: record each one's current path and let it live out its life there.
   - Symlink the new path to the legacy socket, so that `-S <new path>` reaches the old
     server.
   - Move sessions: park resumable sessions and respawn them on new servers.
   - Recommendation: adopt in place. It kills nothing and needs no filesystem trick
     whose behavior across tmux versions would have to be verified.
4. **Should the server-level `ENOENT` reading be withdrawn now, ahead of the flag?**
   - Withdraw it now as a standalone bug fix, with the targeted per-name process check
     as the affirmative replacement.
   - Leave it until the flagged path lands.
   - Recommendation: withdraw it now. It restores the existing affirmative-absence
     theory, the same way #731 did at pane level, and does not need the new design.
5. **What happens when the derived socket path exceeds `sun_path`?**
   - Refuse at derivation with a typed error, as `HolderRendezvous` does.
   - Fall back to `-L` under the ambient directory for that server.
   - Fall back to a short hashed path under `/tmp`.
   - Recommendation: refuse. A fallback silently reintroduces ambient addressing for
     exactly the installations least likely to notice.
6. **One flag or two?**
   - One `stable_tmux_addressing_enabled` for addressing plus adoption, with the socket
     GC leg under its own sub-flag.
   - A separate flag for adoption, so recording can soak before addressing changes.
   - Recommendation: one flag plus the GC sub-flag. Adoption only records and is inert
     until addressing reads it, so a separate soak buys little.

## Rejected alternatives

- **A global `ps` check for "any tmux process" as a veto on absence.** It cannot target
  a per-repository server: any unrelated tmux server, including the user's own, would
  veto every absence verdict. Genuinely dead TBD servers would never be reclaimed, and
  their rows would stay live-looking indefinitely. The recommendation's process check
  differs because it is keyed to one recorded pid and start time, or, for legacy names,
  to one `-L <name>` argv.
- **Reading tmux's error prose more finely.** An `ENOENT` at the wrong directory and an
  `ENOENT` at the right directory whose server is gone print the same text. No parsing
  can tell which directory was right; only a recorded address can.
- **Setting `TMUX_TMPDIR` in the launch scripts or `LSEnvironment`.** It covers only
  some launch paths. The app spawning `tbdd`, a shell launch and a login relaunch each
  arrive with a different environment, and
  [`2026-09-22-tmux-fallback-install-seeding-design.md`](2026-09-22-tmux-fallback-install-seeding-design.md)
  already records that a login relaunch ignores `LSEnvironment.PATH`.
- **Recreating every server at the new location on upgrade.** It kills every live
  session in order to move it, and violates the invariant it is meant to establish.
- **Continuous stamp polling of every row.** It costs one tmux call per row per tick
  across the fleet, and it still answers only the pane half. The incarnation check gets
  the same protection from one query per server.

## Verification contract

- **Classifier.** Unit tests for the legacy absence rule: `ENOENT` over `-L` is
  `.unknown`; `ECONNREFUSED` is `.absent`; status 127 and timeouts stay `.unknown`.
- **Real tmux under the test fence.** `scripts/test.sh` already fences `TMUX_TMPDIR`.
  Tests put `-S` paths under `TBD_TEST_SCRATCH_ROOT` so they fit `sun_path`, then cover:
  - a server created under one `TMUX_TMPDIR` and probed from another stays live through
    reconcile;
  - adoption records the path and incarnation;
  - a killed and recreated server is detected as a new incarnation, and its old rows
    are judged stale.
- **Pane reuse.** A fixture reproduces two rows on `@2`/`%2` across a server
  recreation. The stale row is parked or deleted, and no kill reaches the live pane.
- **`sun_path`.** Derivation throws for an over-long `TBD_HOME`.
- **Flag.** Both branches, plus the three-state column checks listed under "Flag".
- **Socket GC leg.** It keeps a live socket, a young socket and an unanswered probe, and
  reclaims a refused socket whose identity row is dead.
