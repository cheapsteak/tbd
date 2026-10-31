# OSC 7501 as the only source of agent state

Status: design. Ships as a stack of three pull requests; no flag.

## Summary

Claude Code and Codex both report their own state to the terminal over the
Program Status Protocol, OSC 7501. On the pty-holder transport TBD is that
terminal, so it can read the agent's state directly instead of inferring it
from hooks. This design makes those reports the only source of an agent
session's activity state:

- TBD reads Codex's reports as well as Claude Code's.
- `ProgramStatusStore` becomes the only writer of the `activityState` and
  wait-reason columns, so every consumer of those columns — hibernation,
  queued prompts, the delivery verifier, rate-limit resume, PR poll pacing,
  the tab bar — reads agent-reported state without changing.
- The hook commands that wrote state, the transcript-based activity trackers,
  and the resolver rules that ranked hook signals against each other are
  deleted.
- `program_status_enabled` is retired. OSC 7501 is always on.

Sessions that cannot report — any agent on the tmux transport, Claude Code
before 2.1.295, Codex before 0.163.0 — still run. Their state is `unknown`,
the sidebar says why, and the idle sweep leaves them alone.

The protocol, the parser, the store's trust and liveness rules, and the
roll-up of task entries are specified in
[`2026-10-10-program-status-protocol-design.md`](2026-10-10-program-status-protocol-design.md).
This document covers what changes around them.

## Who can report

- **Claude Code 2.1.295 and later** – probes with `ESC ] 7501 ; ? BEL` at
  startup and reports only if the terminal answers before its DA1 reply.
  Reports carry `app=claude-code`, a main entry, and up to 32 task entries
  with `title`, `msg` and `progress`. Claude Code writes its main entry as
  soon as the probe settles, so a capable session reports within moments of
  starting.
- **Codex 0.163.0 and later** – sends without probing whenever its output is a
  terminal (except VTE older than 0.54). Reports are
  `state=<idle|working|blocked|done|error>:app=codex`, with `:kind=` when
  blocked, terminated by ST, and `state=clear` with no `app`. Codex sends no
  task entries, `title`, `msg` or `progress`. It computes its status on every
  draw but writes it only when it changes (its own cache suppresses repeats),
  and the cache starts empty, so its first draw reports `idle`. Codex 0.163.0
  sends `working`, `idle` and `blocked` without `kind`; 0.164.0 added `done`,
  `error` and `kind`. TBD accepts both forms.
- **The tmux transport** – tmux is the terminal there. It does not answer the
  probe and drops the sequence, so no agent on tmux reports.

## Goals

- One source of agent state, written by one component, read unchanged by
  every existing consumer.
- Codex sessions keep a working, idle and blocked badge, and gain done and
  error.
- A session that cannot report is visibly a session without status, never a
  session that looks idle.
- No auto-park of a session whose state TBD does not know.

## Non-goals

- Refusing to launch old agents or tmux sessions.
- Giving consumers richer facts than `working`, `idle` and `waiting_for_user`.
  The column vocabulary is unchanged; richer facts can be added to it one at a
  time when a consumer needs them.
- Changing hooks that report something other than state (see "Hooks that
  stay").
- Persisting `title` or `msg`. They can quote the user's work and stay in
  daemon and app memory only.

## Design

### Trust

The store accepts a report from a live holder session when the terminal's
recorded agent and the report's `app` agree:

- a `.claude` terminal and `app=claude-code`;
- a `.codex` terminal and `app=codex`;
- either agent, and a `clear` with no `app`.

A report from a shell terminal, a tmux-backed terminal, or a mismatched pair is
dropped with a debug log. The incarnation check and the per-terminal watermark
are unchanged. There is no flag check.

### The store writes the activity columns

When the rolled-up state of a terminal — its main entry together with its task
entries, by the roll-up rules of the protocol spec — maps to a column value
different from the one the row holds, the store writes `activityState`,
`activityStateSource = .programStatus`, `activityStateObservedAt` (the report's
observed-at), and the wait-reason columns, through `TerminalStore`. A column
value is the activity state, the wait reason and the source together, so a
block that changes kind — a permission prompt followed by a question —
rewrites the reason although the state stays `.waitingForUser`, and a child
exit over a session that never reported rewrites the source although the state
stays `.unknown`. When all three are unchanged, the store writes only the
ordering stamp.

The mapping:

- `working`, or any working task entry → `.working`
- `blocked` with `kind` `permission`, `question` or none, or any blocked task
  entry → `.waitingForUser`, with a wait reason carrying the block kind and no
  message text
- `done`, `idle`, `error`, and `blocked kind=auth` → `.idle`
- a main-entry `clear`, a child exit, or an incarnation change → `.unknown`,
  with the wait reason cleared; a child exit's is stamped
  `activityStateSource = .processLiveness`, the fact it comes from

A park keeps writing `.idle` through `TerminalStore.setHibernated`; it is not
a second state source, because a parked session runs no agent to report. No
un-park leaves that `.idle` standing. A wake resets the column to `.unknown`
for the incarnation it mints, and an un-park that launches nothing resets it
the same way: `SessionStart` lifting an exit stamp, a park rolled back over a
child that would not end or could not be verified, startup finding a parked
agent still running, and a wake that adopts a holder already running. Each of
those leaves an agent running under a value written for a parked row, and on
tmux no report would ever replace it, so the idle sweep or merge-park could
park a turn in flight. The exit stamp's reset is stamped at the `SessionStart`
that lifts it; the others keep the park's stamp, so a report the agent made
after the park still lands over the reset.

The `done`, `error` and `needsAuth` distinctions stay in the store's snapshot,
where the resolver reads them for display. In the column they are `.idle`, as
they are today: a finished, failed or signed-out session is one the idle sweep
may park.

The store pushes the same `terminalActivityUpdated` and
`terminalAwaitingInputChanged` deltas the hook handlers pushed, so the app's
tab bar and sidebar read the same fields as before; an activity delta goes out
when the state or the source changed. The app applies an activity delta under
its ordering stamp, on every row. A newer delta whose state or source differs
from the cached row's is applied whole, source and observed-at included, and
so is a `terminal.list` row; a newer one repeating both only advances the
cached stamp. A delta older than the cached row's is dropped, because the
store has two ingest paths, the daemon's own reader and the reports the app
forwards, whose broadcasts can arrive out of commit order. A park's `.idle`
and a wake's or un-park's reset to `.unknown` reach the app on the park's or
wake's own `terminalHibernationChanged` delta, which carries the activity
columns read back from the row; the app applies them under the same ordering
stamp. A rolled-back park broadcast no park delta, so its reset goes out as an
activity delta.

### Attention banner

When the rolled-up state enters `blocked` from any other state, the store
creates an `.attentionNeeded` notification, which fires the macOS banner and
bolds the worktree name. Staying blocked raises nothing further. The message
is fixed text chosen by agent and kind, because a notification is a stored
row and `msg` must not reach `state.db`:

- `permission` → "Claude needs your permission" / "Codex needs your permission"
- `question` → "Claude has a question" / "Codex has a question"
- no kind, or a blocked task entry → "Claude needs your input" /
  "Codex needs your input"

`blocked kind=auth` raises no attention banner; Claude Code's `StopFailure`
hook already reports the sign-in failure as an error notification.

The `PreToolUse:AskUserQuestion` hook raises its own banner, with the
question's text, only on a session whose current incarnation is not reporting
— the store holds no report from it, and the row's activity column holds no
state other than `.unknown` that the store wrote (`activityStateSource =
.programStatus`): any tmux session, a holder session whose agent cannot
report, and one whose agent ended its reporting with a bare `clear`, after
which an agent relaunched by hand in that shell may not report at all. A
reporting session reports the question as `blocked kind=question` and the
store's banner is the one, so a question is announced once. The column is what
answers after a daemon restart, which empties the store; it speaks for the
current incarnation only, because every write that mints an incarnation — a
wake, a respawn, a park — rewrites the source.

### PR poll pacing

Every accepted report stamps the worktree activity ledger the PR poll schedule
reads, as each remaining hook event does. The ledger's recording method carries
an agent-event name, since agent reports are its main caller.

### Answering the probe

The app's `TBDTerminalView` and the daemon's `HolderEmulator` answer the probe
on every holder session. Nothing configures whether they answer: there is no
capability the daemon sends the app and no config RPC. Each `TBDTerminalView`
keeps a per-view switch set only from its panel's transport — on for holder,
off for tmux — so a tmux panel never answers, and a snapshot replay still
answers nothing and ingests nothing.

### Resolution

`SessionStateResolver` keeps its order. Only the rung under the snapshot
changes, and it gets simpler:

1. `.gone`
2. `.parked`
3. `.rateLimited`
4. the store's snapshot for the current incarnation, when it is
   OSC-authoritative — this is where `.done`, `.error` and `.needsAuth`
   come from
5. the `activityState` column and wait reason, which only the store and a
   park write — this is what speaks after a daemon restart, before the agent's
   next report
6. `.unknown(why:)`, whose `why` names the cause: the tmux transport, or no
   report from this incarnation

The rules that existed to rank hook signals are deleted: the observed-at
comparison between the wait reason and the activity state, the transcript
fingerprint and growth check, and the delegation rail. The store writes state
and reason together, from one report, so they cannot disagree.

### Hibernation

`HibernationGate.blockingRail` treats `.unknown` as blocking, with a decision
of its own, so neither the idle sweep nor merge-park parks a session whose
state TBD does not know. `.idle` still parks. A manual "Hibernate now" keeps
its existing checks and is unaffected.

### Sessions that cannot report

The sidebar row draws a small "no status" mark for a session that has not
reported since it started: a Claude or Codex terminal whose `activityState` is
`.unknown`, that is neither parked nor gone, once the app has seen its current
incarnation in that state for 15 seconds. A `.unknown` that came after the
agent reported draws no mark, because the tooltip below would misexplain it:
one the agent's own bare `clear` wrote (`.programStatus`) — Claude Code
restoring terminal modes around an external editor, or a clean Codex exit —
and one a child exit wrote (`.processLiveness`), whose process is gone. The
upgrade reset, which records no source, and a wake's, respawn's or un-park's
reset (`.derived`) do draw it. The grace period keeps a starting session from
flashing the mark before its first report. The app keeps the first-seen time
in memory per incarnation; a new incarnation restarts it. The wait uses an
injected clock.

The mark's tooltip names the cause from the terminal's transport:

- tmux – "The tmux transport doesn't carry agent status. Status needs the
  pty-holder transport."
- holder – "This session isn't reporting status. Status needs Claude Code
  2.1.295 or later, or Codex 0.163.0 or later. A session started before this
  version of TBD reports after it is relaunched."

The mark clears on the first accepted report. Shell terminals never show it.
It is new UI beside the existing badges and needs no flag.

Every other consumer of the column sees the same `.unknown`. The delivery
verifier reports a send to such a session as undetermined rather than
confirmed, and the PR poll schedule sees no activity from it.

Three checks that refuse while a session is mid-turn or waiting on the user
have nothing to act on for such a session, and there are no rails on
`.unknown`: the composer's gated send never refuses, because nothing records
a prompt on screen; `tbd terminal close` without `--force` closes it; and a
manual "Hibernate now" parks it. So a composer send can land on an open
dialog, and a close or a manual park can end a running turn. That is the
accepted cost of a session that cannot report; the idle sweep and merge-park
still leave it alone.

### Continue in Claude

Continue in Claude replaces a Codex process with Claude, and runs only on the
tmux transport, where a Codex row stays `.unknown`. Its preflight therefore
requires no persisted `idle`. Its idle check is a bounded re-read of the Codex
rollout through `CodexTranscriptActivityTracker`, which must report the last
turn closed. The tracker serves that check and the action's pending recovery,
and nothing else: it does not feed `terminal.list` or the sidebar.

### Upgrading

A session started before this design never had its probe answered (Claude
Code), or had its reports dropped (Codex), and its column holds a value a hook
wrote. No hook will write it again, so a `working` would stand forever and
block every auto-park. A `.sql` migration therefore sets `activityState` to
`unknown`, and clears its source, its observed-at stamps and the wait-reason
columns (`awaitingInputReason`, `awaitingInputObservedAt`), on every terminal
row that is neither parked nor suspended (`hibernatedAt IS NULL AND
suspendedAt IS NULL`) and whose `activityStateSource` — the JSON encoding of a
`FactSource` — is not `programStatus`. Rows the store wrote, and parked or
suspended rows, keep their value. The reset sessions show the no-status mark
until they are relaunched or woken.

### Hooks that stay

These hooks report something other than state and are unchanged, except that
each loses its `tbd terminal-activity` call:

- **Claude** – `SessionStart` (`tbd session-event`: session ID and transcript
  path), `Stop` (response-complete notification, rename check), `StopFailure`
  (error notification, rate-limit detection), `PreToolUse` and `PostToolUse`
  for `AskUserQuestion` (question rendering), `PostToolUse:Bash` (PR binding),
  `SessionEnd` (the exited stamp).
- **Codex** – `SessionStart` (`tbd session-event`) and `Stop` (rename check,
  response-complete notification).

`UserPromptSubmit` on Claude has one job, the session title, which it gets
from the `tbd hooks session-title` command. The turn-end transcript sync runs
inside the `tbd notify` call the `Stop` and `StopFailure` hooks already make.
A `StopFailure` whose hard usage limit or transient error the daemon takes
over prints no message and makes no such call; the RPC `tbd hooks
stop-failure` makes instead runs the sync.

### What is removed

- **Hook entries** – Claude's `Notification` entry; Codex's
  `UserPromptSubmit` and `PermissionRequest` entries; every
  `tbd terminal-activity` call in both overlays; the Codex `Stop` hook's
  active-goal `sqlite3` check, which existed only to choose between idle and
  working.
- **CLI** – `tbd terminal-activity` and `tbd hooks notification`. An overlay
  that still calls them fails silently through `|| true`, and the daemon
  rewrites both overlays at startup.
- **RPC** – `terminal.activityEvent` and `terminal.notificationEvent`, their
  params, and the activity write in the session-event handler.
- **App** – the interrupt write the app sent through `terminal.activityEvent`
  when the user stopped a turn. The agent reports `idle` itself.
- **Inference** – `ClaudeDelegationTracker`, `ClaudeDelegationSample`, the
  delegation-claim clear in `SessionEnd`, `CodexTranscriptActivityTracker`'s
  sidebar wiring (see "Continue in Claude"), `AwaitingInputSupersession`, and
  `AwaitingInputClass`'s notification-type classification. A type that keeps a
  reader outside this list stays for that reader.
- **The flag** – see "Flag".

## Placement

Reading the pty stream and writing the columns compile: they are per-event work
inside the emulators, and the columns are the record every compiled consumer
gates on. The no-status mark is display and lives in the app as a pure
function of the terminal's kind, transport, activity state and first-seen
time.

## Flag

None, and no kill switch. The design removes the hook writers the protocol
replaces, so a switch that turned the protocol off would leave every agent
session with no source of state at all — worse than either source alone. The
column that gated it, `program_status_enabled`, is retired under the "Retiring a
column" checklist in `Sources/TBDDaemon/Database/CLAUDE.md`: the record
property, the `Config` field and `programStatusEnabledDefault`, the config RPC
and its params, the Settings toggle, the app's capability plumbing, and every
gate check go in one commit that lists the column in `RetiredColumns.all` and
bumps `SchemaEpoch.current`.

## Reconciler

Nothing new outlives a request. The store is daemon memory, the probe reply is
a write to an existing pty, and the upgrade reset is a one-time data change.

## Delivery

Three stacked pull requests, each safe to merge alone:

1. **Retire the flag.** OSC 7501 is always on for Claude Code on holder
   sessions. In this pull request the hooks still write the columns, and the
   resolver's snapshot rung governs the sidebar and `session.states` for
   OSC-authoritative terminals. This spec lands here.
2. **Accept Codex reports.** The trust rule above, and a tooltip that handles a
   terminal with no task entries. Hooks still write the columns.
3. **OSC becomes the only state source.** The column writer, the attention
   banner, the ledger stamp, the hibernation rule, the no-status mark, the
   upgrade migration, and every removal. Both overlays change here, in the
   same pull request as the writer that replaces them, so no build ships with
   neither.

## Testing

Each branch of each new conditional gets a test.

- **Trust** – a Claude terminal with `claude-code` and a Codex terminal with
  `codex` are accepted; each mismatched pair, a shell terminal, and a tmux
  terminal are refused; a `clear` with no `app` is accepted from either agent.
- **Codex wire form** – the parser accepts Codex's exact bytes,
  `ESC ] 7501 ; state=blocked:app=codex:kind=permission ESC \`, and the 0.163.0
  form without `kind`.
- **Column writer** – every mapping line; no write when the state, reason and
  source are unchanged; a child exit over a never-reported `.unknown` rewrites
  and announces the source; a working or blocked task entry under an idle main
  entry; `clear`, child exit and incarnation change write `.unknown`; a park
  still writes `.idle`; lifting an exit stamp resets it to `.unknown` at the
  lift, and an un-park that launches nothing resets it at the park's stamp, so
  a backlogged report still lands.
- **Banner** – raised on entering `blocked` and not again while blocked; the
  fixed text per agent and kind; no banner for `kind=auth`; no `msg` text in
  the notification row.
- **Ledger** – an accepted report stamps it; a refused one does not.
- **Probe** – answered on holder sessions in both readers with no gate; never
  on tmux; silent during snapshot replay.
- **Hibernation** – `.unknown` blocks the idle sweep and merge-park; `.idle`
  parks; manual park is unaffected; a session whose exit stamp `SessionStart`
  lifted, or that startup un-parked over a live agent, is not auto-parked.
- **Resolution** – the snapshot rung over the column; the column after the
  store is emptied (a daemon restart); `.unknown(why:)` naming tmux and naming
  no report.
- **No-status mark** – absent before 15 seconds and present after; tooltip text
  by transport; cleared by a report; restarted by a new incarnation; never on a
  shell terminal; absent for a `.unknown` the agent's `clear` or a child exit
  wrote, and present for the upgrade and wake resets; hidden when a child exit
  lands on a row that never reported, and armed when a wake's reset lands on a
  row the agent's `clear` wrote.
- **Upgrade migration** – a hook-written live row becomes `unknown` with no
  wait reason; a store-written row, a parked row and a suspended row keep
  their values.
- **Continue in Claude** – proceeds from a tmux Codex row at `.unknown` when
  the rollout re-read reports the turn closed; refuses when it does not.
- **Overlays** – neither overlay contains `terminal-activity`; Claude's has no
  `Notification` entry and calls `tbd hooks session-title` from
  `UserPromptSubmit`; Codex's has only `SessionStart` and `Stop`.
- **Retired column** – listed in `RetiredColumns.all` with the bumped epoch.

Before the third pull request merges, run Claude Code and Codex 0.164.0 or
later on holder sessions and watch each badge move through working, blocked
and idle; then run a tmux session and confirm the no-status mark.

## Rejected alternatives

- **Consumers read the store, and the column is retired.** One copy of the fact
  instead of two, and consumers could see `done`, `error` and the block kind.
  But the store is memory and agents report only on change, so after a daemon
  restart every idle session would read `unknown` until its next turn — and,
  with `unknown` blocking auto-park, would never park. Persisting the snapshot
  to fix that rebuilds the column. It would also turn the pure functions over a
  terminal row that six consumers use into actor calls, for richer facts no
  consumer asks for.
- **Hooks as a fallback for sessions that cannot report.** Keeps two writers of
  one column with no reliable order between them — the race the protocol spec
  already rejected — and keeps every rule that existed to referee it.
- **Refusing to launch old agents or tmux sessions.** A session without status
  is still useful, and TBD does not know Claude Code's version without running
  it. A visible mark costs nothing and tells the user what to change.
- **Reading state off the rendered screen.** Forbidden by the repository's
  rule against TUI screen-scraping, and unnecessary now that both agents
  report through a machine interface.
