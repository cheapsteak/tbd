# Program Status Protocol (OSC 7501) for holder sessions

Status: design. On for every pty-holder session; there is no flag.

## Summary

Claude Code (from v2.1.295) and Codex (from 0.164.0) report their own state
to the terminal over a private OSC sequence, the Program Status Protocol,
OSC 7501 — Claude Code once the terminal says it supports it, Codex without
asking. On the pty-holder transport TBD's SwiftTerm *is* the terminal, so TBD
can opt in, receive those reports, and use them as the authoritative state of
an agent session — replacing hook inference for the states hooks get wrong,
and covering Claude Code's background subagents that hooks cannot see at all.

Each agent stamps its reports with its own `app` value, `claude-code` or
`codex`, and TBD accepts a report only from a terminal whose recorded agent
is the one that value names.

The tmux transport is out of scope. tmux is the terminal there, does not
answer the probe, and drops the sequence; tmux is being deprecated, and this
design only promises not to break it.

## The protocol as the agents implement it

Claude Code's behavior was read from its shipped bundle (v2.1.295), and
Codex's from its source (0.164.0). No published specification was found; the
behaviors below are what the clients do, and the parser must tolerate drift
from them.

**Probe.** At startup, alongside its XTVERSION and DA1 queries, Claude Code
writes `ESC ] 7501 ; ? BEL`. It enables the protocol only if the terminal
answers with an OSC 7501 whose data starts with `?`; a DA1 reply with no 7501
reply settles it off for the life of the process. It is forced off by
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE` and for background workers
(`CLAUDE_CODE_SESSION_KIND=bg`). There is no env var that forces it on, and
the sequence is never wrapped in tmux/screen DCS passthrough.

**Reports.** Claude Code writes `ESC ] 7501 ; key=value:key=value… BEL`
(`ESC \` instead of BEL when it believes the terminal is kitty). Keys:

- **`state`** – `working`, `blocked`, `done`, `idle`, `error`, or `clear`.
- **`app`** – `claude-code` on every state report; absent on both forms of
  `clear`.
- **`id`** – present on per-task entries (background tasks and subagents),
  absent on the session's main entry. Sanitized by the sender to
  `[A-Za-z0-9_.+-]`, at most 32 characters.
- **`kind`** – only with `blocked`: `permission`, `question`, or `auth`, or
  absent.
- **`progress`** – integer 0–100, only with `working` or `blocked`. It is the
  completed fraction of the session's todo list.
- **`title`** – base64 of UTF-8 text, at most 192 bytes before encoding.
- **`msg`** – base64 of UTF-8 text, at most 2048 bytes before encoding.

The sender writes only entries that changed since its last write, sends
`state=clear:id=X` when a task entry goes away, keeps at most 32 task entries,
and sends a bare `state=clear` on exit and when restoring terminal modes.

**What each state means to Claude Code.**

- `working` – a turn is running, or the session is idle with a queued prompt.
  `msg` is the current task summary.
- `blocked` – the session waits on the user. A permission prompt, sandbox
  request, worker request or goal proposal sends `kind=permission`; an
  input-needed prompt sends `kind=question`; an open dialog sends no kind.
  An authentication failure (`authentication_failed`,
  `oauth_org_not_allowed`, `cloud_credential_error`) sends `kind=auth` until
  the user signs in again.
- `done` – the last turn completed. `msg` is the post-turn summary.
- `idle` – no turn has run, or the user stopped one.
- `error` – the last turn failed for a non-auth reason. `msg` is the failure.
- Task entries are `working`, or `blocked` when paused or waiting on input.

**Codex.** Codex sends no probe and needs no answer: it reports whenever its
output is a terminal, unless that terminal is VTE older than 0.54. A report is
`ESC ] 7501 ; state=<idle|working|blocked|done|error>:app=codex ESC \`, with
`:kind=<permission|question|auth>` added when blocked, and its clear is
`ESC ] 7501 ; state=clear ESC \`, with no `app`. Codex sends no `id`,
`title`, `msg` or `progress`, so a Codex terminal has a main entry and never a
task entry. It refreshes its status on every draw and its cache starts empty,
so its first draw reports `idle`. Codex 0.163.0 sends `working`, `idle` and
`blocked` without `kind`; TBD accepts that form, which lacks only the richer
states.

## Goals

- Show permission and question blocks the moment they happen, and clear them
  the moment they resolve.
- Tell a finished turn (`done`) apart from a never-started or stopped one
  (`idle`), and show failed turns (`error`) and lapsed sign-ins (`needsAuth`)
  as their own states.
- Keep a session whose main turn ended visibly working while its background
  tasks run, and visibly blocked when one of them waits on the user.
- Show the reported `title`, `msg` and `progress` when hovering a status
  badge.

## Non-goals

- The tmux transport, in either attach mode.
- A ticker or history of messages. Only the latest values are kept; a ticker
  can be designed separately once field use shows how often `msg` changes.
- Persisting any of this across a daemon restart.
- Acting on reports. They drive display and resolution only; nothing kills,
  wakes or sends input because of one.

## Design

### Placement

Parsing a pty byte stream and remembering the latest report are facts and
mechanism, and compile: they are per-byte work inside the emulators that no
user-land surface can reach. The precedence and roll-up rules below are a
theory about what TBD shows. They are compiled because they are the
resolution of an existing compiled state model, but they are gated, isolated
in one resolver function, and covered rule by rule so they stay cheap to
change.

### Parsing

A pure parser in `TBDShared` turns the OSC data after `7501;` into a
`ProgramStatusReport`:

- `state` – a `ProgramStatusState` enum with an `unrecognized(String)` case.
- `id`, `kind` (`ProgramStatusBlockKind`, also with `unrecognized`),
  `progress` (clamped to 0–100), `title`, `msg`.
- `title` and `msg` are base64-decoded and truncated to 192 and 2048 bytes on
  a UTF-8 boundary; an undecodable value is dropped, not the whole report.
- `?` alone parses as the probe, not a report.
- A payload with no `state` key is rejected. Unknown keys are ignored.

The terminator (BEL or ST) is SwiftTerm's concern; the parser sees only the
data.

### Answering the probe

Whichever reader owns a holder session's pty answers a `?` query with
`ESC ] 7501 ; ? BEL`. A tmux panel never answers.

The reply must be written synchronously, while SwiftTerm parses the probe.
Claude Code writes the probe before its DA1 query and treats DA1's reply as
the end of the probe batch: a 7501 reply that arrives after the DA1 reply
settles the protocol off. SwiftTerm answers DA1 synchronously during parsing,
so the probe reply comes from a synchronous OSC handler
(`registerOscHandler` for code 7501, which has no built-in handler to
preempt), never from the asynchronous `observeOscEvents` stream.

- **App attached** – `TBDTerminalView` registers the handler and writes the
  reply through the terminal's normal send path, which lands on the holder's
  write fd.
- **App detached** – the daemon's headless `HolderEmulator` registers the
  same handler and replies through `ReplyForwardingDelegate`, the path it
  already uses for DA1 and friends.

Both readers must answer identically, because Claude Code asks once at
startup: a probe answered only by the app would make the feature depend on
whether the app happened to be attached when Claude launched. Both therefore
answer for any holder session, whatever its agent; ingestion, not the probe,
filters by agent.

Codex needs no answer. It sends without probing, so its reports reach
whichever reader owns the pty whether or not that reader ever answered
anything.

A snapshot replay must never answer a probe or ingest a report. Reports are
read from `observeOscEvents`, which is already suspended during replay; the
probe handler checks the same replay state and stays silent while it is up.

### Delivering reports to the daemon

`ProgramStatusStore`, a daemon actor, owns all report state.

- **Detached** – `HolderReader` hands reports to the store in-process.
- **Attached** – the app sends the raw OSC data to a new RPC,
  `terminal.programStatusReport`, with `{terminalID, incarnationID,
  payload, observedAt}`. Forwarding the raw payload keeps a single parser on
  the path that decides anything.

A report that arrives during a reader hand-off can be lost. The store keeps
the last state it accepted, and the agent's next change corrects it.

### Trust

The store accepts a report only when all of these hold; otherwise it drops
it with a debug log:

- the terminal is a live holder session whose recorded agent reports:
  Claude or Codex. A row written before kinds were recorded is Codex when its
  label says so and Claude otherwise; a shell reports nothing;
- the report's incarnation matches the terminal's current incarnation, so a
  late report from a previous process cannot overwrite its successor;
- the report's `app` is the terminal's own agent's — `app=claude-code` on a
  Claude terminal, `app=codex` on a Codex one — except on a `clear`, which
  both agents write without `app`. An `app` TBD does not know is refused
  before the terminal is looked up, and a known `app` on the other agent's
  terminal, on a `clear` as on any other report, after it.

A program running inside a genuine agent session — a `cat` of a file that
contains the sequence — can still forge a report. That residual risk is
accepted: reports drive display only.

### Liveness

An agent sends `clear` when it exits cleanly, but a SIGKILLed process sends
nothing. The store therefore drops a terminal's entries — main and tasks —
when the holder session's child exits, when the terminal is hibernated or
parked, and when its incarnation changes.

A child exit or a park is an unconditional end, so its drop also records a
per-terminal watermark: a report observed at or before it is refused, and so
is a report whose validation was suspended on the terminal lookup while the
drop ran. Otherwise a backlog already in flight — the
daemon's inbox, or the app's forwarder — would land after the drop and hold an
entry nothing ever clears. A wake drops only entries whose incarnation differs
from the terminal's current one, because by the time it runs the replacement
session is live and what it has already reported is its current state.

### State model

`SessionStateValue` gains three cases. Its wire form is tagged and readers
decode an unknown tag as `.unknown(why:)`, so the additions are compatible:

- `.done` (`done`) – the last turn completed.
- `.error` (`error`) – the last turn failed. It carries no text; the message
  lives in the store.
- `.needsAuth` (`needs_auth`) – the user must sign in again.

`AwaitingInputReason` gains a way to carry a program-status block kind
(`permission`, `question`, or none) alongside the hook-derived reasons.

The main entry maps as follows:

- `working` → `.working`
- `blocked` with `kind` `permission`, `question` or none → `.awaitingInput`
  carrying that kind
- `blocked kind=auth` → `.needsAuth`
- `error` → `.error`
- `done` → `.done`
- `idle` → `.idle`
- `clear` → the terminal stops being OSC-authoritative
- a state this build does not recognize → the main entry takes part in no
  roll-up rule: an unrecognized state says nothing TBD can display. Its task
  entries still decide the state through rules 2 and 3 below; when none does,
  the terminal is not OSC-authoritative and the hook rail speaks, because the
  hook-derived state is a better reading than an opaque unknown

### Precedence

A terminal is **OSC-authoritative** while the store holds a main entry for
its current incarnation that either carries a state this build recognizes or
stands over task entries that decide the state (a blocked or working task).
Its resolved state then comes from the store; task entries with no main entry
above them do not make a terminal authoritative. Hooks keep
writing `activityState` exactly as they do now; resolution simply does not
consult it while the terminal is OSC-authoritative. Authority ends with a
main-entry `clear`, an incarnation change, or a liveness drop.

States TBD owns outrank OSC: `.parked` and `.gone` win, and so does
`.rateLimited`.

Nothing new is written to `state.db`. Holder sessions survive a daemon
restart but the store does not, so after a restart those sessions show their
hook-derived state until the agent's next report re-establishes authority.

### Rolling up task entries

The store keeps up to 32 task entries per terminal, each
`{state, kind, title, msg, progress}`, removed by `clear:id=X`. The
displayed state of an OSC-authoritative terminal is the first rule that
matches:

1. The main entry resolves to `.needsAuth`, `.awaitingInput` or `.error` →
   the main entry's state.
2. Any task entry is `blocked` → `.awaitingInput`, labelled with that task's
   title.
3. The main entry is `working`, or any task entry is `working` → `.working`,
   with a count of working task entries carried in the resolution (the row
   does not draw it).
4. Otherwise → the main entry's `.done` or `.idle`.

Rule 3 closes the gap that
[`2026-08-24-claude-delegation-activity-design.md`](2026-08-24-claude-delegation-activity-design.md)
works around: the parent's `Stop` no longer makes a session with running
subagents look idle. On OSC-authoritative terminals that spec's turn-boundary
rail is not consulted.

### UI

For OSC-authoritative terminals only:

- **Worktree row** – `.error` and `.needsAuth` get badges of their own.
  The existing working, idle and awaiting-input badges are unchanged. A
  running task entry keeps the row on the working badge even after the main
  entry stops working (rule 3); the row draws no count of running tasks,
  since a number beside the working dots crowds them and the tooltip
  already lists every task entry with its state.
- **Done shows as idle** – `.done` has no badge. Claude Code reports `done`
  after every turn and keeps it until the next one, so a badge for it would
  sit on nearly every waiting session. The row already marks the case that
  matters: a bold worktree name means a turn finished with a response the
  user has not read, and it clears when the user selects the worktree.
  Like an idle row, a row whose only OSC-authoritative terminal is done has
  no badge and so no tooltip. `.done` stays a distinct resolved state: it
  appears in the tooltip when another terminal's badge carries one, and it
  is there for any later consumer.
- **Tooltip** – hovering the row's status badge lists, per OSC-authoritative
  terminal in the worktree, the main entry's state, `title`, `msg` and
  `progress`, then one line per task entry with its title, state and `msg`.
  Each terminal goes by its label, or by its agent's name, "Claude" or
  "Codex", when it has none. A Codex terminal sends a main entry and nothing
  else, so its block is the one line naming its state.

The daemon pushes a `ProgramStatusSnapshot` per terminal to the app with its
existing state updates. `title` and `msg` live only in daemon and app memory
and are never written to `state.db`, since they can carry content from the
user's work.

Terminals that are not OSC-authoritative look exactly as they do today.

## Flag

None. Both readers answer the probe on every holder session, and the store
accepts every report that passes "Trust"; no setting turns the protocol off.
See [`2026-10-30-osc-only-agent-status-design.md`](2026-10-30-osc-only-agent-status-design.md),
"Flag".

## Reconciler

The feature creates no durable external resource. The store is daemon
memory, and the probe reply is a write to an existing pty. Nothing can
orphan.

## Testing

- **Parser** – every key; base64 decode and the byte caps on a UTF-8
  boundary; malformed and empty payloads; unknown `state` and `kind`; the
  probe form; missing `state`.
- **Probe reply** – answered on a holder session by both the app observer and
  the daemon emulator; silent on a tmux panel and during snapshot replay.
- **Store** – trust checks (agent, incarnation, `app`); task add,
  `clear:id`, and the 32-entry cap; the liveness drops.
- **Resolution** – each roll-up rule in order; OSC precedence over hook state;
  fall-back after a main `clear`; `.parked`, `.gone` and `.rateLimited`
  outranking OSC.
- **`SessionStateValue`** – the three new tags round-trip, and a decoder that
  lacks them reads `.unknown`.

## Rejected alternatives

- **The daemon tees every byte.** Giving the daemon the stream even while the
  app is attached would leave one parser in one process, but it reopens the
  holder's single-reader arbitration, a load-bearing transport decision, for
  a status signal.
- **App-only parsing.** The app is absent exactly when a blocked session most
  needs to be visible, and the facts would never reach anything outside the
  UI.
- **Latest-wins reconciliation with hooks.** Reports arrive in-band and hooks
  arrive over CLI→RPC, so ordering between them is not reliable, and
  latest-wins would flicker. An agent computes its state from its own
  internals, so once it reports, it is the better source.
- **Using OSC only to fill gaps hooks leave.** Keeps two sources racing on the
  states both can express, for no gain in accuracy.
