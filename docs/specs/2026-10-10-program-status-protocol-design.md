# Program Status Protocol (OSC 7501) for holder sessions

Status: design, default-off behind `program_status_enabled`.

## Summary

Claude Code (from v2.1.295) reports its own state to the terminal over a
private OSC sequence, the Program Status Protocol, OSC 7501, once the terminal
says it supports it. On the pty-holder transport TBD's SwiftTerm *is* the
terminal, so TBD can opt in, receive those reports, and use them as the
authoritative state of a Claude session — replacing hook inference for the
states hooks get wrong, and covering background subagents that hooks cannot
see at all.

The tmux transport is out of scope. tmux is the terminal there, does not
answer the probe, and drops the sequence; tmux is being deprecated, and this
design only promises not to break it.

## The protocol as Claude Code implements it

Everything here was read from the shipped Claude Code bundle (v2.1.295). No
published specification was found; the behaviors below are what the client
does, and the parser must tolerate drift from them.

**Probe.** At startup, alongside its XTVERSION and DA1 queries, Claude Code
writes `ESC ] 7501 ; ? BEL`. It enables the protocol only if the terminal
answers with an OSC 7501 whose data starts with `?`; a DA1 reply with no 7501
reply settles it off for the life of the process. It is forced off by
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE` and for background workers
(`CLAUDE_CODE_SESSION_KIND=bg`). There is no env var that forces it on, and
the sequence is never wrapped in tmux/screen DCS passthrough.

**Reports.** `ESC ] 7501 ; key=value:key=value… BEL` (`ESC \` instead of BEL
when Claude Code believes the terminal is kitty). Keys:

- **`state`** – `working`, `blocked`, `done`, `idle`, `error`, or `clear`.
- **`app`** – always `claude-code`.
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

## Goals

- Show permission and question blocks the moment they happen, and clear them
  the moment they resolve.
- Distinguish a finished turn (`done`) from a never-started or stopped one
  (`idle`), and show failed turns (`error`) and lapsed sign-ins (`needsAuth`)
  as their own states.
- Keep a session whose main turn ended visibly working while its background
  tasks run, and visibly blocked when one of them waits on the user.
- Show the reported `title`, `msg` and `progress` on hover.

## Non-goals

- The tmux transport, in either attach mode.
- A ticker or history of messages. Only the latest values are kept; a ticker
  can be designed separately once the soak shows how often `msg` changes.
- Persisting any of this across a daemon restart.
- Acting on reports. They drive display and resolution only; nothing kills,
  wakes or sends input because of one.
- Agents other than Claude Code.

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

When `program_status_enabled` resolves true, whichever reader owns the holder
pty answers a `?` query with `ESC ] 7501 ; ? BEL`:

- **App attached** – `TBDTerminalView`'s OSC observer (`observeOscEvents`,
  the same non-preempting hook OSC 777 uses) sees code 7501 and writes the
  reply through the terminal's normal send path, which lands on the holder's
  write fd.
- **App detached** – the daemon's headless `HolderEmulator` observes the same
  code and replies through `ReplyForwardingDelegate`, the path it already uses
  for DA1 and friends.

Both readers must answer identically, because Claude Code asks once at
startup: a probe answered only by the app would make the feature depend on
whether the app happened to be attached when Claude launched.

While a snapshot replays, OSC observation is already suspended, so a 7501 in
replayed history is never answered or ingested.

When the flag resolves false, neither reader answers, Claude Code never
enables the protocol, and behavior is identical to a build without this
feature. Turning the flag on affects only Claude processes started afterwards.

### Delivering reports to the daemon

`ProgramStatusStore`, a daemon actor, owns all report state.

- **Detached** – `HolderReader` hands reports to the store in-process.
- **Attached** – the app sends the raw OSC data to a new RPC,
  `terminal.programStatusReport`, with `{terminalID, incarnationID,
  payload, observedAt}`. Forwarding the raw payload keeps a single parser on
  the path that decides anything.

A report that arrives during a reader hand-off can be lost. The store keeps
the last state it accepted, and Claude Code's next change corrects it.

### Trust

The store accepts a report only when all of these hold; otherwise it drops
it with a debug log:

- the flag resolves true;
- the terminal is a live holder session whose recorded agent is Claude;
- the report's incarnation matches the terminal's current incarnation, so a
  late report from a previous process cannot overwrite its successor;
- `app=claude-code`.

A program running inside a genuine Claude session — a `cat` of a file that
contains the sequence — can still forge a report. That residual risk is
accepted: reports drive display only.

### Liveness

Claude Code sends `clear` when it exits cleanly, but a SIGKILLed process sends
nothing. The store therefore drops a terminal's entries — main and tasks —
when the holder session's child exits, when the terminal is hibernated or
parked, when its incarnation changes, and when the flag is turned off.

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

### Precedence

From the first accepted main-entry report for an incarnation, that terminal
is **OSC-authoritative**: its resolved state comes from the store. Hooks keep
writing `activityState` exactly as they do now; resolution simply does not
consult it while the terminal is OSC-authoritative. Authority ends with a
main-entry `clear`, an incarnation change, or a liveness drop.

States TBD owns outrank OSC: `.parked` and `.gone` win, and so does
`.rateLimited`.

Nothing new is written to `state.db`. Holder sessions survive a daemon
restart but the store does not, so after a restart those sessions show their
hook-derived state until Claude Code's next change re-establishes authority.

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
   with a count of working task entries.
4. Otherwise → the main entry's `.done` or `.idle`.

Rule 3 closes the gap that
[`2026-08-24-claude-delegation-activity-design.md`](2026-08-24-claude-delegation-activity-design.md)
works around: the parent's `Stop` no longer makes a session with running
subagents look idle. On OSC-authoritative terminals that spec's turn-boundary
rail is not consulted.

### UI

For OSC-authoritative terminals only, with the flag on:

- **Worktree row** – `.done` shows a quiet "finished" badge distinct from
  idle; `.error` and `.needsAuth` get badges of their own; a working session
  with running task entries shows a small background count. The existing
  working, idle and awaiting-input badges are unchanged.
- **Tooltip** – hovering the worktree row lists, per OSC-authoritative
  terminal in the worktree, the main entry's state, `title`, `msg` and
  `progress`, then one line per task entry with its title, state and `msg`.

The daemon pushes a `ProgramStatusSnapshot` per terminal to the app with its
existing state updates. `title` and `msg` live only in daemon and app memory
and are never written to `state.db`, since they can carry content from the
user's work.

Terminals that are not OSC-authoritative look exactly as they do today.

## Flag

`program_status_enabled` is a `config` column added with no SQL default, so
NULL means nobody chose. The shipped default lives in
`Config.programStatusEnabledDefault = false` and is applied in
`ConfigRecord.toModel()`. A Settings toggle sets it.

The flag gates every piece: answering the probe in both readers, accepting
reports, resolution, and UI. Off means neither reader answers, so Claude Code
never emits anything.

- **Soak** – enable the toggle on a development machine running holder
  sessions, and compare the sidebar against what the sessions are visibly
  doing, especially permission prompts and sessions with background agents.
- **Graduation** – flip the default constant. Users who never touched the
  toggle follow it; explicit opt-outs are preserved. Delete the flag once the
  default has held.

## Reconciler

The feature creates no durable external resource. The store is daemon
memory, and the probe reply is a write to an existing pty. Nothing can
orphan.

## Testing

- **Parser** – every key; base64 decode and the byte caps on a UTF-8
  boundary; malformed and empty payloads; unknown `state` and `kind`; the
  probe form; missing `state`.
- **Probe reply** – answered with the flag on and silent with it off, in both
  the app observer and the daemon emulator; silent during snapshot replay.
- **Store** – trust checks (flag, agent, incarnation, `app`); task add,
  `clear:id`, and the 32-entry cap; the liveness drops.
- **Resolution** – each roll-up rule in order; OSC precedence over hook state;
  fall-back after a main `clear`; `.parked`, `.gone` and `.rateLimited`
  outranking OSC.
- **Flag column** – a pre-migration row reads NULL rather than `0`; NULL
  follows the default constant; an explicit `false` survives a change to it.
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
  latest-wins would flicker. Claude Code computes its state from its own
  internals, so once it reports, it is the better source.
- **Using OSC only to fill gaps hooks leave.** Keeps two sources racing on the
  states both can express, for no gain in accuracy.
