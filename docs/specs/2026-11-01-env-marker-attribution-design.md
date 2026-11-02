# Env markers as attribution evidence: the orphan-process sweep and hook callers

## Summary

Every process a TBD terminal starts inherits `TBD_WORKTREE_ID` and
`TBD_TERMINAL_ID`, and on macOS another process of the same user can usually
read them. This design uses that fact in two places, under one theory:
**the environment records where a process came from, not who owns it now.**

- **The orphan-process sweep** reads the markers of every escaped process it
  considers. A marker naming a live worktree, or no marker at all, vetoes a kill
  the cwd rule would have made. A marker naming an archived worktree admits a
  process the cwd rule missed. Guards keep that second route away from
  user-wide daemons.
- **Hook bridges** stop taking the markers on trust. Before an event
  changes a terminal's state, the daemon checks that the calling process really
  descends from that terminal's job, and refuses the event only on positive
  proof that it does not.

The sweep half ships under the existing `gc_orphan_processes_enabled` flag. The
hook half ships unflagged, as a bug fix.

## What the environment shows

Measured on one macOS 27 machine (SIP enabled) on 2026-10-30, with the
read-only probe in `docs/research/2026-10-30-herdr/procenv_probe.py`:

- **`sysctl(CTL_KERN, KERN_PROCARGS2, pid)`**, the call `ps eww` makes, returns
  another process's environment as it stood at exec. A later `setenv` inside
  that process does not show.
- **Readable:** most processes of the same user, including `claude` (despite
  its hardened-runtime signing), `node`, `pnpm`, and binaries under `~`,
  `/opt/homebrew` and `/nix/store`. A TBD-spawned `claude` exposed both markers.
- **Hidden:** every Apple platform binary tested (`/bin/zsh`, `/bin/sleep`,
  `/usr/bin/perl`, anything under `/System`) returns its argv but zero
  environment entries. So do Dia, Chrome and Postgres.app.
- **Other users:** the call fails with `EINVAL`.
- **Escapees:** a process that left with `setsid` and a double fork was found
  by its marker alone.

TBD sets the markers only on a terminal's job, so they reach what that job
starts and nothing else. The daemon, a holder and a per-repo tmux server were
probed directly and carry neither marker. The `tmux -CC attach` clients and the
model proxy are spawned by the daemon, whose environment holds no marker, so
they carry none either.

**Origin is not ownership.** A census that day found ten escaped (`ppid == 1`)
processes carrying `TBD_WORKTREE_ID`. One was a three-day-old
`nix … print-dev-env` naming an archived worktree: real garbage. Three others
were `dirmngr`, `claude daemon run` and `claude --bg-pty-host`, user-wide
daemons tagged with whichever worktree or terminal happened to start them. A
rule that killed on the marker alone would kill those daemons when that
worktree was archived. The same shape appears in herdr's open issues
(herdrdev/herdr#2012, #4649, #4814): Codex's shared app-server and Claude
Code's background host keep the first pane's environment for days.

## Problem

### The sweep kills processes it does not own

`OrphanProcessCollector` reclaims a `ppid == 1` process whose cwd lies under a
worktree that is positively dead
(`docs/specs/2026-08-18-orphan-process-gc-design.md`). A cwd also records only
where a process started, and the sweep has acted on that wrongly:

- **Holders of live sessions.** Holders once inherited the daemon's cwd.
  Archiving the worktree the daemon was started from had the sweep kill every
  holder that daemon spawned, ending live sessions in other worktrees (fixed for
  holders by PR #956, which starts holders in `/`).
- **The per-repo tmux server, still exposed.** On the measured machine the
  daemon's cwd and the repo's tmux server's cwd (tmux 3.6a, `ppid == 1`) were
  both one worktree's directory. That server serves every worktree of the repo.
  Archive that one worktree, and a later sweep kills the server and every pane
  under it. No exclusion covers TBD's own tmux servers.

### The sweep misses processes it should reclaim

The cwd rule cannot see a process whose cwd left the worktree: one that changed
directory, one that daemonized to `/`, or one started with its cwd elsewhere
(a dev server run with `--cwd`). The `nix` process above is the measured case.
The sweep was enabled on that machine and had not reclaimed it after three
days, which points to a cwd outside the worktree.

On the same machine the cwd sweep reclaimed 42 process trees between
2026-10-06 and 2026-10-29. They included the 6 live holders above, 7 tmux
servers leaked by test suites, 3 Codex `app-server-broker.mjs` processes, and
at least 5 Apple binaries whose environment is hidden (`log stream`, `tail -f`,
`caffeinate`, `zsh -c` twice). Any design here must keep reclaiming that last
group, which no marker can reach.

### Hook events trust an inherited identity

Each hook TBD installs, for Claude Code through its `--settings` overlay and for
Codex through its plugin, runs a `tbd` subcommand. The subcommand reads `TBD_TERMINAL_ID` (or `TBD_WORKTREE_ID`) from its own
environment and sends an RPC naming that terminal or worktree. Today the daemon
checks only that the row exists and that the hook's reported cwd resolves to
the row's worktree (`hookCWDBelongsToTerminal`). The incarnation check
(`TBD_TERMINAL_INCARNATION_ID`) does not help here, because it is inherited the
same way.

So a process outside a tab's process tree that still carries the tab's markers
drives that tab whenever it works in the same worktree. Candidates are a
session hosted by Claude Code's background daemon, Codex's shared app-server,
and an agent `nohup`'d from an earlier job in the same tab. TBD has no direct
evidence yet that such events arrive; herdr's issues are the evidence that the
shape exists. What one wrong event does to the tab it names:

- **`session-event` (SessionStart)** rebinds the tab's Claude session ID and
  transcript path. The transcript pane shows another conversation, and a later
  park, wake or restart resumes the wrong session. It lasts until the tab's own
  next SessionStart, which can be hours away.
- **`pr bind --from-hook`** binds a PR to the worktree in `TBD_WORKTREE_ID`. A
  wrong bind ties the PR to the wrong worktree, and if auto-archive-on-merge is
  on there, the merge archives it.
- **`session-end`** clears the tab's pending AskUserQuestion dialogs, and on a
  tmux row can mark a running Claude as exited.
- **`ask-user-question`** shows a question as pending on the wrong tab, or
  clears the right tab's question.
- **`hooks stop-failure`** posts a usage-limit or API-error notification on the
  wrong tab. With auto-resume on, it also schedules a resume that later types
  "continue" into that tab.
- **`hooks session-title`** claims the tab's title for the other session, so the
  tab's own session can miss it, and marks the tab's worktree active for the
  PR schedule.

## Part 1: env evidence in the orphan-process sweep

### Reading the markers

A new reader calls `KERN_PROCARGS2` for one pid and keeps exactly two values,
`TBD_WORKTREE_ID` and `TBD_TERMINAL_ID`. Nothing else from the environment is
retained or logged; environments hold secrets. It answers one of three ways:

- **markers** – the environment is readable and holds at least one marker;
- **no markers** – the environment is readable and holds neither;
- **hidden** – zero entries, or the call failed. A process started under
  `env -i` also reads as hidden, which only returns it to today's cwd rule.

The reader runs after the sweep's `ps` snapshot, so a pid can be reissued in
between. After each read it takes the pid's start time from the kernel and
compares it with the start instant the snapshot recorded, using the same
two-second tolerance as the signal-time re-check. A mismatch makes the answer
**hidden**.

### Deciding on one escaped root

A root is a process the sweep already considers: `ppid == 1`, our uid, outside
the protected set. Each root is judged by these rules, in order:

1. **Its cwd lies in a live worktree, or could not be read: keep.** This is
   today's rule, and it binds both routes. An unreadable cwd keeps because the
   env route cannot then rule out a live worktree. A cwd of `/` is readable and
   lies in no worktree. Because both routes read the cwd, the age gate that
   guards that join — a root at least as old as the cwd reading — applies on
   both.
2. **A marker names something live: keep.** `TBD_WORKTREE_ID` names a worktree
   row that is not archived, or `TBD_TERMINAL_ID` names a terminal row that
   exists. Archiving a worktree deletes its terminal rows, so an existing
   terminal row always belongs to a live worktree. When markers disagree, live
   wins.
3. **The environment is readable and holds no marker: keep.** No TBD terminal
   started this process, so it is not this sweep's to kill. This covers every
   process TBD spawns from the daemon — tmux servers, `-CC attach` clients,
   holders, the model proxy — whatever their cwd.
4. **A marker names an archived worktree: the env route admits it,** once
   `gcGraceSeconds` has passed since that row's `archivedAt`.
5. **A marker names no row, or does not parse: the environment is neutral.**
   The absence of a row attests nothing either way, and neutrality keeps the
   `.deleting/<uuid>` attestation working for worktrees whose rows are gone.
6. **The environment is hidden: neutral.**

When the environment is neutral, or when rule 4 did not apply, the cwd route
decides exactly as it does today. A root is a candidate when either route
admits it. The reap record names the archived worktree's path for an env-only
admission and the cwd's dead root otherwise.

Rule 3 changes what the sweep reclaims. With the sweep on, a process started
outside any TBD terminal — from another terminal app, or by an editor's task
runner — is no longer reclaimed, even when its cwd lies in an archived
worktree. Three groups that look like it stay covered. Holders whose session
row is gone are reclaimed by the row-less holder phase. Tmux servers leaked by
a test run inside a TBD terminal inherit the test runner's markers, because
`TmuxManager` spawns tmux with the caller's environment. Apple binaries read as
hidden, not as "no markers".

### Guards on the tree

The sweep plans a candidate's whole descendant tree before signalling it. Two
guards apply to that tree.

- **The tree guard.** The reader runs on every process in the planned tree. If
  any of them carries a marker naming something live, the whole tree is kept. A
  process born in a worktree that was later archived may now host work for a
  live one, and killing the host would kill that work. Most real daemons pass
  their own environment to their children, so this guard rarely fires; it
  exists because it costs one read per tree member and errs only toward keeping.
- **The daemon keep-list.** A process whose command line matches the keep-list
  joins the protected set beside `isTBDBinary`. So the list applies on both
  routes and to every tree member, and the descendant walk stops beneath a
  match, as it does at a foreign uid.

### The keep-list

Which daemons are user-wide differs from one toolset to the next, and the
answer depends on other tools' argv, which changes with their releases. That
makes the list a theory in the sense of `docs/theory-placement.md`, so it ships
as an editable default rather than as compiled law:

- **Format.** One pattern per line. A pattern matches when it is a substring of
  the process's `ps -ww` command line. Blank lines and lines starting with `#`
  are ignored. Substring matching over-matches, and over-matching keeps.
- **Shipped defaults**, in `TBDShared`: `claude daemon run`, `--bg-pty-host`,
  `gpg-agent`, `dirmngr`, `keyboxd` and `codex app-server`. They cover the
  daemons seen carrying markers they merely inherited — GnuPG's `dirmngr`, with
  its siblings, and Claude Code's background host — and Codex's app-server,
  from herdr's reports. Killing GnuPG's daemons costs a passphrase prompt;
  killing Claude Code's background host or Codex's app-server ends work that
  may belong to live worktrees.
- **Where it lives.** While `~/tbd/gc-keep-processes` (a `TBDConstants` path
  helper, so it follows `TBD_HOME`) does not exist, the shipped defaults apply
  and improve with each release. `tbd gc keep-list customize` writes the
  defaults to that file once. From then on the file is the whole list, and TBD
  never rewrites it. An empty file is a valid list with no patterns.
- **A file that exists but cannot be read skips the orphan-process phase,**
  recorded as `KEEP keep-list-unreadable`. The sweep never guesses which list
  the user meant.
- **Surfaces.** `tbd gc keep-list` prints the path, whether the file or the
  shipped defaults are in effect, and the patterns. Settings → Cleanup shows
  the tilde-abbreviated path with a copy-path button and a Customize button.
  The app writes the file directly, without an RPC, as `RepoHooksSettingsView`
  does for hooks.

### No time-stamped token

herdr-core stamps its token with a monotonic time so a scan can skip every
process older than the token, which both saves reads and defeats pid reuse.
TBD needs neither. The sweep reads environments only for escaped roots
outside live worktrees and for the trees it plans. On the measured machine that
was 485 of 1,177 processes, and reading all 485 took about 20 ms from Python,
once an hour. Pid reuse is already handled twice: by the start-time check after
each read, and by the re-check before each signal volley. `TBD_TERMINAL_INCARNATION_ID`
stays a plain UUID.

### Forged markers

`HolderDescentIndex` never consults an environment variable for tab identity,
because any process can set one, and a forged marker there would hand one tab's
identity to another process. That rule stands. Attribution of an escaped
process for GC asks a different question. A process can set markers only for
itself and its children. Forging an archived worktree's ID gets the forger's
own tree killed; forging a live worktree's ID keeps it alive. In both cases the
only party affected is the forger, and no identity changes hands.

### What env cannot reach

- **Leaked tmux servers and `-CC attach` clients (issue #678).** They carry no
  markers, so rule 3 keeps them. That class still needs a matcher keyed on
  server identity.
- **A hidden root whose cwd also left the worktree.** For example,
  `nohup zsh -c 'cd /tmp && node server.js' &`: the root is `/bin/zsh` with
  cwd `/tmp`, and only its `node` child shows the archived worktree. Such a
  root is kept. herdr-core accepts the same gap in its own sweep: "A process
  that both leaves the session and drops its environment escapes."

### Record

`processDescription` gains the routes that admitted the root:
`pid=<pid> tree=<n> via=<cwd|env|cwd+env> <argv>`. The dry-run plan line
carries the same `via=`, so a soak can compare what each route catches. No
column changes.

### Flag

Everything in Part 1 runs under the existing `gc_orphan_processes_enabled`, on
top of `gcEnabled`. That flag is still default-off and soaking, so the new
kills stay behind a default-off switch. A machine that already enabled the
sweep receives the env route with no second opt-in; that is accepted, because
the veto half removes the false-kill shape the soak has shown, and the same
flag decides both. `tbd gc sweep --dry-run` lists what the sweep would reclaim,
by route, even while the flag is off. Graduation is unchanged: flip
`Config.gcOrphanProcessesEnabledDefault` once reap records across a soak show
only real garbage on both routes. No migration is needed.

## Part 2: checking hook callers by descent

### Which calls

Every RPC that only a hook sends is checked:

- `terminal.sessionEvent` (`session-event`, from Claude Code and Codex)
- `terminal.sessionEnded` (`session-end`)
- `terminal.sessionTitle` (`hooks session-title`)
- `terminal.askUserQuestionPending` and `terminal.askUserQuestionCleared`
- `claude.rateLimitDetected` and `claude.transientApiErrorDetected`
  (`hooks stop-failure`)
- `pr.attach` with `source == hook` (`pr bind --from-hook`)

Three paths stay out. `tbd notify` is also run by hand with an explicit
`--terminal`, so the daemon cannot tell an inherited target from a chosen one.
That includes the `tbd notify --type error` a `stop-failure` hook falls back to
when the daemon does not handle the failure.
`terminal.askUserQuestionSatisfied` comes from the app. The session mod
authenticates with its own token on its own socket. The hidden debug command
`tbd fake-rate-limit` now has to run from inside the tab it targets.

### The guard

One guard sits beside `hookCWDBelongsToTerminal` and runs before it. The router
hands the checked handlers their `RPCConnectionContext`, as it already does for
`terminal.send`. The context's `peerPID` comes from the kernel (`LOCAL_PEERPID`)
and cannot be forged. The `tbd` CLI blocks on the daemon's reply, so the peer
is alive, and its pid stable, for the whole check.

The guard gives one of three answers:

- **Inside: accept.** The caller's ancestry contains the row's job.
- **Proven foreign: refuse.** All of these hold:
  - the peer pid is known;
  - the row can anchor a walk by `HolderDescentIndex.liveJob`'s rules — holder
    transport, not parked, holder alive, job is the holder's child, job start
    within `HolderChildIdentity.startWindow` of the row's anchor;
  - one `KERN_PROC_ALL` read yields a complete ancestry for the peer that
    reaches launchd without passing through the job.
- **Can't tell: accept, and log the reason.** Everything else: no peer pid, a
  failed table read, an ancestry broken by a process that exited mid-walk, a
  tmux row, a parked row, a job outside the start window, or two rows naming
  one job.

For `pr.attach`, the caller is inside when it descends from the job of any row
in the named worktree. It is proven foreign only when the worktree has at
least one row that is not parked, every such row can anchor a walk, and the
complete ancestry passes through none of their jobs. A worktree with no
unparked row is "can't tell", for the same reason a parked row is.

A parked row is deliberately "can't tell". A wake starts a new job before the
row records its pid, so the new session's SessionStart can arrive while the row
still looks parked. Refusing it would leave the tab on its old session — the
costliest mistake this guard could make.

### On refusal

The handler replies as it does when the named row does not exist, because
hooks are fire-and-forget and an error would surface inside the agent's
session. For most calls that reply is OK; `transientApiErrorDetected` answers
"not handled"; `pr.attach`, which names no row, replies OK. It changes
nothing. It logs at `.info` the method, the terminal or worktree ID,
the peer pid, the caller's executable basename and the reason, all `.public`.
It never logs argv or the hook's cwd; checkout paths routinely carry employer
and client names.

### Why no flag

This restores a theory TBD already holds — a hook speaks for the tab it runs
in — rather than revising one, so it ships as a bug fix. What bounds the risk
is that the guard refuses only on proof: every case where the daemon cannot
see the whole picture accepts, as today.

### Cost

Measured from Python on the same machine, walking one process's ancestry took
about 3 µs for five hops, and reading the whole process table took about
0.12 ms. Each hook
already starts a `tbd` process, which took about 8 ms. Hooks fire a few times
per turn, not per tool call: the overlay matches PreToolUse and PostToolUse
only to AskUserQuestion, and PostToolUse also to Bash for `pr bind`.

## Testing

Process-level tests inject the signaller, the `ps` snapshot, the process table
and the environment reader, following `OrphanProcessCollectorTests`; none
spawns a real process to be killed.

**Part 1:**

- **Both flag branches.** With the flag off, neither route touches a matching
  root. With it on, each route reclaims its own case.
- **The reader.** Markers, no markers, zero entries and a failed call each give
  the right answer; only the two keys survive parsing; a pid whose start time
  moved reads as hidden. One live test reads the test process's own
  environment through the real `sysctl` path.
- **Each root rule**, including:
  - TBD's tmux-server shape — readable, no markers, cwd in an archived
    worktree — is kept;
  - a terminal-ID marker naming an existing row keeps a root whose cwd is in an
    archived worktree;
  - an unknown worktree ID with cwd in a `.deleting/<uuid>` entry is
    reclaimed, and with cwd elsewhere is kept;
  - a hidden root with cwd in an archived worktree is reclaimed by the cwd
    route, as today;
  - a root whose cwd could not be read is kept, even when its marker names an
    archived worktree.
- **The env route.** A root with cwd `/` whose marker names an archived
  worktree is reclaimed once the grace has passed, and not before.
- **The tree guard.** One tree member naming a live worktree keeps the whole
  tree.
- **The keep-list.** A shipped pattern protects a `--bg-pty-host` root on both
  routes and stops the walk at a matching tree member; a user file replaces the
  defaults; `customize` writes once and never overwrites; an unreadable file
  skips the phase.
- **The accepted gap.** A hidden root with cwd elsewhere and a marked child is
  kept.
- **The record.** Reap records and plan lines carry the right `via=`.

**Part 2:**

- **The guard alone**, over an injected table and rows: inside at depth 0 and
  deeper; proven foreign; each can't-tell reason; two rows naming one job.
- **Each checked method.** A proven-foreign caller changes no state and gets
  the handler's no-row reply; an inside caller behaves as today. `pr.attach` is
  checked only for `source == hook`.

## Rejected alternatives

**Require both cwd and env (strict AND).** It removes every false kill a
marker can veto, and it stops reclaiming every process whose environment is
hidden. Five of the measured reclaimed trees were Apple binaries — `log
stream`, `tail -f`, `caffeinate`, `zsh -c` — and no marker can ever be read
from them.

**Use env only to veto.** It removes the false kills and catches none of the
misses, so the `nix` shape stays alive forever.

**Kill on a marker alone.** The marker records origin. User-wide daemons —
GnuPG's, Claude Code's background host, Codex's app-server — carry the marker of
whichever worktree started them, so an unguarded marker rule kills them when
that worktree is archived. The env route exists only with the vetoes, the tree
guard and the keep-list around it.

**Treat a closed tab as death.** `TBD_TERMINAL_ID` naming a terminal row that
no longer exists, in a live worktree, would reclaim a `nohup`'d server left by
a closed tab. The worktree is still in use, and a deliberately detached server
there is the developer's business until they archive the worktree.

**Infer a hidden root from its children's markers.** This is herdr-core's
descendant closure turned upward. A single-instance GUI app opened from a TBD
tab (`code .`) can be a hidden-env root whose children carry that tab's
markers; when the worktree is archived, the inference kills the whole app,
including windows for other projects. The tree guard does not help, because
those children inherit the app's own markers.

**A time-stamped token.** It speeds up scans of the whole process table and
defeats pid reuse. The sweep reads only escaped roots, about 20 ms of reads
per hourly sweep on the measured machine, and pid reuse is already checked at
read time and at signal time.

**Compile the daemon list.** Fewer surfaces, but the list encodes facts about
other tools' argv that change with their releases, and toolsets differ. A
theory shipped as compiled law changes only by rebuild.

**No daemon guard.** herdr-core's theory is that everything a terminal started
dies with it, like a Windows job object, and it accepts killing `gpg-agent`.
For TBD that would also end Claude Code background sessions that may belong to
live worktrees.

**A separate flag for the env route.** It would let the new kills soak apart
from the veto. The veto and the route are one change to one sweep, which is
itself still default-off and soaking; one flag keeps one thing to evaluate.

**Fail closed in the hook guard.** Envelope suppression fails closed because it
grants an elevated action. A hook event is an input, and refusing a real
SessionStart leaves the tab on the wrong session. So only proof refuses.

**Check only session binding, or only log.** Checking only `session-event` and
`session-end` leaves wrong PR binds possible, and those stick and can drive
auto-archive. Logging without refusing records the problem and fixes none of
it.

## Reconciler doctrine

No new kind of durable resource. Part 1 changes what an existing reconciler —
`OrphanGC`'s orphan-process phase — may reclaim, in both directions. The
keep-list is one user-authored file at a fixed path. Part 2 creates nothing.

## Related documents

- `docs/specs/2026-08-18-orphan-process-gc-design.md` — the cwd rule this
  extends.
- `docs/research/2026-10-30-herdr/README.md` and `identity.md` — the env-read
  measurements, the census, and herdr-core's `HC_SCOPE` sweep.
- `docs/theory-placement.md` — why the keep-list is an editable default.
