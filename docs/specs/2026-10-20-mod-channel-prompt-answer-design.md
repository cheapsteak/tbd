# The session-mod channel, and answering prompts through it

TBD can answer Claude Code's permission dialogs and `AskUserQuestion` from
cards in the transcript pane. Today it does so through settings hooks: every
tool call in a flag-on session runs a `tbd prompt note` process, and every open
dialog holds a `tbd prompt wait` process for up to a day, matched to its tool
call by a hash of the tool input.

This design replaces that path with a feature of the
[session mod](2026-10-19-tbd-session-mod-design.md), `prompt-answer`, which
runs inside the Claude process and so needs neither the processes nor the hash.
To carry answers to the mod, it adds the piece the session mod deferred to its
first consumer: a **channel** from the daemon to the mod. The channel is built
for every later mod feature too; message delivery into sessions through
`$.prompt.submit` is the next one and gets its own spec.

The replacement is wholesale and adds no flag: `transcript_prompt_answer_enabled`
keeps gating the feature, and the old hooks, CLI commands and RPCs are deleted.
The terminal stays able to answer every dialog, as it does today.

Related: [answering prompts from the transcript](2026-10-09-transcript-prompt-answer-design.md)
(the cards, the store, and the remote path this design keeps),
[session mod](2026-10-19-tbd-session-mod-design.md),
[named-reconciler doctrine](2026-08-15-named-reconciler-doctrine-design.md).

## Facts this design rests on

Measured live on Claude Code 2.1.303 with `scripts/claude-stub.py` and probe
mods passed with `--plugin-dir`. Re-measure on a new Claude Code minor before
relying on them.

- **A mod cannot accept connections.** It can make HTTP requests
  (`$.http.fetch`, which accepts `socketPath` for any absolute Unix socket
  path), start processes, read files, run timers, and receive Claude Code's
  inbox-socket messages through `session.receive`.
- **`$.http.fetch` aborts any response at 30 seconds**, over TCP and Unix
  sockets alike, with no option to raise it. A reply the server writes as the
  request aborts is lost to the mod.
- **A hook has 10 seconds of its own time.** The clock stops while `next(e)` or
  a `$` call is in flight, but not during `$.clock` waits. A hook that awaits a
  plain promise, even one a timer-driven poll resolves, is skipped at about
  10 seconds and its late answer ignored. A hook awaiting its own
  `$.http.fetch` is not.
- **Timers and requests run while the session is idle.** `$.clock.every` fired
  218 times in 217 idle seconds; polls held 29 seconds completed.
- **`classic.PermissionRequest` races the visible dialog.** The dialog stays
  usable while the hook waits. A hook answer closes the dialog and the tool runs
  once. A terminal No or Escape aborts `next.signal` at once. A terminal Yes
  does not abort it; the hook's later answer is ignored and does not leak to the
  next dialog.
- **After a terminal No or Escape, every `$` call the hook makes fails.**
  Claude Code aborts the hook's dispatch, and each later `$` call from that
  hook, a `$.http.fetch` included, fails with "The operation was aborted"
  before it reaches the socket. The same holds when an `AskUserQuestion`
  dialog is Escaped. Work the module roots in a `$.clock.after` timer is not
  tied to any hook's dispatch: the poll loop, started that way, kept polling
  through 106 idle seconds. The design relies on that for the terminal's
  **closed** report, which the module sends from a timer of its own (see
  "Mod to daemon: reports").
- **The permission payload has no tool call id,** but `tool.call`'s `e.input`
  equals its `tool_input` exactly, so a mod pairs the two in-process. Parallel
  calls with different inputs paired correctly; calls with identical inputs are
  interchangeable.
- **Permission answers:** `deny` with a message gives the model exactly that
  text and the turn goes on; `allow` with `updatedPermissions` scoped to the
  session works when the suggestion is a rule and writes nothing to disk.
- **`AskUserQuestion` can be answered from `tool.call`:** the hook calls
  `next(e)`, which opens the dialog; returning
  `{ result: { questions, answers } }` before it settles closes the dialog and
  records the answer. While `next(e)` is pending the hook's clock is stopped,
  so it may await a plain promise.
- **`classic.*` hooks may not run where an organization manages Claude Code.**
  The plugin validator says so for user-installed plugins, and under
  `allowManagedHooksOnly` a user-tier plugin loads no hooks at all. Not
  measurable without managed settings.
- **macOS does not let one process read another's environment**, so a secret
  passed in a spawn's environment is not readable through `ps` or `/proc`-style
  inspection.
- **TBD spawns every Claude session with `--dangerously-skip-permissions`.**
  Permission dialogs appear only after the person leaves bypass mode, so
  questions are the common case.

## The channel

One channel per daemon, shared by every mod feature. The mod always initiates;
the daemon answers.

### Listener

The daemon opens a second Unix socket, `~/tbd/mod.sock` (derived from
`TBDConstants`, so it follows `TBD_HOME`), mode 0600, speaking HTTP/1.1. It
serves only the mod routes below. The existing `~/tbd/sock` is unchanged: it
speaks line-delimited JSON, which `$.http.fetch` cannot. The daemon unlinks a
stale `mod.sock` before binding and unlinks it at shutdown, like `sock`.

### Addressing and trust

A mod identifies itself by the terminal ID and the incarnation it was spawned
under, both already in its environment (`TBD_TERMINAL_ID`,
`TBD_TERMINAL_INCARNATION_ID`). The Claude session ID is not an address: two
terminals can share one, and `/clear` changes it.

Only TBD may deliver into a session. At spawn, a session with any mod feature
on gets `TBD_MOD_TOKEN`: an HMAC-SHA256 of its incarnation under a daemon key
kept in `~/tbd/runtime/mod-key` (mode 0600, 32 random bytes, created on first
use), plus `TBD_MOD_SOCKET`, the listener's path. Every request carries the
token in an `Authorization: Bearer` header and names its terminal and
incarnation; the daemon recomputes the token from the incarnation and refuses
the request unless it matches and the terminal's row holds that incarnation.
An incarnation is minted per spawn, so binding the token to it binds it to one
process in one terminal. Because the token is derived, it survives a daemon
restart with no database change. A process outside the session, running as
the same user, cannot learn a session's token without deliberately reading the
key file, which is the same trust boundary that protects `state.db`. The
session's own descendants do inherit `TBD_MOD_TOKEN` with the rest of its
environment: a command the Bash tool runs, an MCP server. Such a process:

- **can** forge **closed** or **receipt**, which dismisses or hides a card, or
  take a decision meant for one of the session's dialogs, so the answer never
  reaches it: denial of service;
- **can** open cards for tool use ids that have no dialog;
- **cannot** change what an open card shows: the first payload wins, and a
  repeat **opened** whose tool name, input or suggestions differ is refused
  with a 409 and leaves the card as first reported;
- **cannot** answer a dialog, because answers come only from the app through
  `prompt.answer`, and the terminal can still answer every dialog.

A request for a terminal whose row holds a different incarnation is refused,
so a process that outlived its row cannot receive what its successor should.

### Daemon to mod: the poll

The mod keeps one `GET /v1/poll?after=<seq>` open whenever it runs. The daemon
holds it until it has an item for that terminal or 25 seconds pass, then
replies with zero or more items. The mod opens the next poll at once.

- **Sequence and resend.** Items carry a sequence number that increases per
  terminal. A poll's `after=` confirms every item up to it. An item sent but not
  confirmed is sent again on the next poll; the mod drops an item whose number
  it has seen. A reply lost to the 30-second abort is therefore resent, and each
  item takes effect at most once.
- **Holding.** When no poll is open, the daemon keeps a terminal's items in
  memory for up to 60 seconds. An item still unconfirmed then is dropped and its
  sender told `notConnected`. Nothing is written to disk; a daemon restart drops
  held items and their senders are told.
- **Backoff.** A poll that fails (daemon down, socket missing, token refused)
  is retried after 1, 2, 5, then every 10 seconds. Failures log at debug level
  only, so they put nothing in the transcript.

The gaps the holding window covers: the milliseconds between two polls; a
session's first seconds before the mod loads; a mod reload; reconnection after
the Mac wakes; a daemon restart. A session that will never connect — exited,
crashed, or spawned without the mod — is known before a send through
`SessionModLiveness` and is not waited for.

### Mod to daemon: reports

Reports are short `POST` requests on the same socket: a dialog opened, a dialog
closed and by whom, and receipts for items the mod acted on. A hook waits for
the daemon's reply to a receipt before it returns, so none is dropped with the
hook; the wait is one local round trip, and a `$` call in flight stops the
hook's clock. A receipt is sent only on paths the terminal has not aborted. A
**closed** report is sent from the module's outbox instead: a
`$.clock.after(0, …)` timer the module schedules, so a terminal No or Escape,
which aborts the hook and every `$` call it makes afterwards, cannot cancel
it. The outbox retries a failed attempt (no reply, or a 5xx) after 1, 2, 5 and
5 seconds, five attempts in all, and drops the report once an attempt reaches
the daemon or the attempts run out. Failed reports are logged at debug level
and otherwise ignored. A dialog's own wait (below) is also a request on this
socket.

### Liveness

A poll received in the last 30 seconds marks the terminal's mod connected. The
channel exposes this per terminal, and `SessionModLiveness` takes it as a
further signal beside `alive.json` once a feature needs it — message delivery
is the first. `alive.json` stays. The disconnect sweep below does not read
it: an open prompt's liveness is its own wait requests, since a dialog's hook
repeats its wait for as long as the dialog is open, whatever the poll loop is
doing.

### Orphans

The channel creates no durable resource that can be orphaned. Held items and
open-prompt records live in daemon memory; `mod.sock` is unlinked at start and
stop; `mod-key` is one fixed file. The mod starts no process.

### Clock

The 25-second hold, the 60-second window, the 30-second liveness test and the
disconnect sweep below take the injected clock (`any Clock<Duration>`), per the
repo rule.

## Answering prompts

### The feature

`SessionModFeature.promptAnswer` (`prompt-answer`) is enabled when
`transcript_prompt_answer_enabled` is on. No new flag or column: the existing
flag gates both the spawn-time feature list and the daemon routes, as it gates
the RPCs today.

### Permission dialogs

1. The mod's `tool.call` hook records each in-flight call's id and input, and
   removes it when `next(e)` settles.
2. The `classic.PermissionRequest` hook finds its call by exact input match
   (and `agent_id`, which separates subagents), then posts **opened** with the
   tool call id, tool name, input and permission suggestions.
3. It waits on its own request, `GET /v1/prompts/<id>/answer`, held up to
   25 seconds and repeated while the dialog is open. Holding its own request
   keeps the hook's clock stopped. A failed wait (the daemon restarting) is
   retried after a 1-second pause, posting **opened** again first; the pause
   is the hook's own time, so after five failures in a row, or once the
   hook's remaining budget falls below 2 seconds, the dialog is left to the
   terminal. A hook that ran short of budget leaves its card up, and the mod
   sends **closed** from its outbox when the tool call ends.
4. On an answer it returns the decision and posts a **receipt**:
   - `allow` returns `{ behavior: 'allow' }`;
   - `allowAlways` returns `allow` with the suggested rule as
     `updatedPermissions`, destination forced to `session`;
   - `deny` returns `{ behavior: 'deny', message }`, the message defaulting to
     "The user declined this from TBD." It never sets `interrupt`.
5. When the terminal answers first:
   - No or Escape aborts `next.signal`; the hook catches the aborted request,
     queues **closed** with `by: terminal`, and returns. The module's outbox
     timer sends it, since the aborted hook's own `$` calls would fail.
   - Yes is seen when the tool finishes and `tool.call`'s `next(e)` settles;
     the mod then sends **closed** with `by: terminal` from its outbox.

Until the tool finishes, a card answered Yes in the terminal stays up. A click
on it is harmless: the hook's late answer is ignored and the card reports
"already answered" once the close arrives. Whether the mod can see the tool
start sooner is an open probe; adopting such a signal later changes only when
**closed** is posted.

### Questions

`AskUserQuestion` is answered from `tool.call`, not from
`classic.PermissionRequest`, so it keeps working where an organization manages
Claude Code.

1. The hook calls `p = next(e)`, which opens the dialog, and posts **opened**
   with the tool call id and questions.
2. It races `p` against its own answer request. If TBD answers first, it
   returns `{ result: { questions, answers } }` and posts a **receipt**. Every
   question needs an answer; multi-select answers are joined with ", ".
   Because `p` keeps the hook's clock stopped, a failed wait is retried with
   the poll's backoff (1, 2, 5, then every 10 seconds), posting **opened**
   again before each retry, until `p` settles; a card that outlives a daemon
   restart can therefore still be answered. Once `p` is open, any failure on
   TBD's side returns `p`'s own result, never a second `next(e)`.
3. If `p` settles first, the terminal answered; the mod queues **closed** with
   `by: terminal` and returns `p`'s result. The module's outbox timer sends
   it: an Escape aborts the hook, and with it the hook's own `$` calls.

The existing `AskUserQuestion` pre and post hooks that render a question early
in the pane are separate and stay.

### Daemon: the store

`PendingPromptStore` keeps its rules; its inputs change.

- **Opened** registers a prompt keyed by (terminal, tool call id). Parallel
  tool calls can open several dialogs, which Claude Code shows one at a time
  ("1 of 2"); each gets its own prompt, and the pane shows the oldest open one,
  the one the terminal shows. Two terminals sharing a session ID stay apart
  because the address is the terminal.
- **`prompt.answer`** is unchanged: only the app may call it, and the first
  answer wins. The answer goes to the dialog's waiting request, or is held for
  the next one within the 60-second window. A wait that arrives after the
  decision was handed to an earlier one gets the same decision again: that
  covers a reply lost when its connection dropped, and Claude Code applies
  only the first decision it receives.
- **Receipt** resolves the prompt as delivered. **Closed** resolves it as
  answered in the terminal, so an answer racing it reports `alreadyResolved`.
  An answer sent with no receipt within 5 seconds reports `unknown`, as today.
- **Re-post after restart.** The mod keeps its open dialogs in memory and
  posts each again as **opened** after any reconnect, so the cards return
  after a daemon restart. The store treats a repeat as the same prompt. The
  re-post is the body first sent, so its payload is the same; a repeat whose
  payload differs is refused with a 409, which the mod treats as final.
- **Clearing.** The store records, per prompt, when a wait request last
  attached to it or left it, starting from its **opened** (a repeat
  **opened** restarts the measure). Every 15 seconds a disconnect sweep clears
  each prompt that has no wait attached and whose last such moment is more
  than 60 seconds old, whatever the terminal's poll is doing: a mod that still
  polls but has stopped waiting on a dialog loses that card, and a mod whose
  poll loop is down while its dialog waits still work keeps its cards. A
  terminal's open prompts are also cleared when its session ends and when the
  terminal is removed.
- **Session ID.** **Opened** may carry the Claude session ID; the store keeps
  it for the log only, since prompts are keyed by terminal.
- **Snapshot.** A new `state.subscribe` subscriber receives the open prompts
  with its initial state. Today it waits for the next change.
- **Flag off.** New prompts are refused; prompts already open still resolve.

### Removed

- The four overlay hooks: `tbd prompt note` on PreToolUse, PostToolUse and
  PostToolUseFailure, and `tbd prompt wait` on PermissionRequest.
- `tbd prompt note` and `tbd prompt wait` (`PromptCommand.swift`).
- `PromptInputHash` and the note-pairing it serves.
- The `prompt.note`, `prompt.register`, `prompt.await` and `prompt.ack` RPCs.

`prompt.note` also stamped the PR poll schedule's activity ledger
(`WorktreeActivityLedger`) on each tool call. Flag-on sessions lose that feed
and match flag-off sessions, whose stamps come from the other hooks.

### Unchanged

The cards, `PromptAnswerController`, the pending-prompt merge, the
`terminalPendingPromptsChanged` delta, the remote path through the provider
contract (`pending_prompt`, `answer`), and the flag's gating of
`remote.answer`. Remote sessions are not affected: a provider session runs
behind its contract, and `claude --cloud` runs no local process for a mod.

## Switchover

A session started before the new build keeps the hooks and feature list it was
spawned with until it restarts. It gets no answer cards: its dialogs are
answered in the terminal, as with the flag off, and its questions still render
read-only through the early-render hooks. If its old `tbd prompt wait` hook
still runs, the command no longer exists, the hook fails, and Claude Code shows
the dialog in the terminal as it would without the hook. A restart gives the
session the mod feature.

## Failure handling

- **The mod cannot reach the daemon.** The hook passes the event on and the
  dialog stays in the terminal, exactly as without the mod.
- **TBD and the terminal answer at once.** Claude Code takes the first. The
  mod posts **closed** in place of a receipt and the card reports already
  answered.
- **The answer arrives but the receipt is lost.** The card reports unknown.
- **A mod reload during an open dialog.** The old hook stops and the dialog
  falls back to the terminal. The reloaded mod does not know the dialog, so it
  neither re-posts it nor waits on it, and the disconnect sweep clears its
  prompt about 60 seconds after its last wait ended, even though the reloaded
  mod polls again.
- **An organization manages Claude Code.** Permission dialogs fall back to the
  terminal; questions still work.

## Testing

- **Daemon (Swift Testing, injected clock):**
  - the listener: token accepted, wrong token refused, stale incarnation
    refused; poll held and timed out; sequence, confirm and resend; 60-second
    holding and `notConnected` expiry;
  - the store: opened, answered, receipt and closed; first answer wins;
    `unknown` without a receipt; re-post after restart; clearing on session end,
    terminal removal and a prompt with no wait for 60 seconds while its
    terminal still polls, sparing one with a wait attached; the subscribe
    snapshot;
  - both flag branches: on, `prompt-answer` is in the spawn's feature list and
    the routes accept new prompts; off, it is absent and new prompts are refused
    while open ones resolve.
- **Mod (`claude plugin test`, handlers exported as named functions):** pairing
  by exact input and `agent_id`; the allow, allow-always and deny decisions;
  the abort path and an Escaped question sending **closed** from the outbox's
  timer while the hook's own `$` calls fail; the question race in both
  directions; re-post after reconnect; backoff; the outbox's retries and its
  give-up; a question's waits retried across a daemon restart until its
  dialog settles; receipts awaited before the hook returns.
- **Live, before merge:** a zero-token run with `claude-stub` against a fake
  daemon that answers a question and a permission dialog, and checks the
  terminal can still answer each. Manual, not CI.

## Rejected alternatives

- **A mod-started helper process holding a stream to `~/tbd/sock`.** Push is
  immediate, but it adds a process per session that survives a SIGKILL of
  Claude with no parent, needing its own watchdog and a reconciler; it depends
  on a `tbd` binary path that can be stale; and a waiting permission hook would
  still have to hold a `$` call.
- **Claude Code's inbox socket, with signed messages.** Delivery takes 1–5 ms
  and needs no open request, but `session.receive` carries no sender identity,
  so every message needs a signature and replay protection; replies need a
  second mechanism; and the inbox depends on a Claude Code feature a setting or
  an organization can turn off.
- **A file inbox read on a timer.** Simple and durable, but any same-user
  process can write it, latency equals the interval, and a waiting permission
  hook cannot wait on a file within the 10-second rule.
- **Answering questions through `classic.PermissionRequest`.** One code path
  for both dialog kinds, but questions would stop working wherever an
  organization manages Claude Code.
- **A durable queue for undelivered items.** Survives a daemon restart, but a
  message could land long after its context changed, and the queue would be a
  new durable resource needing a sweep. Senders are told instead.
- **Keeping the hook path for sessions started before the switch.** Two answer
  paths would live side by side until every old session restarted; terminal
  answering covers those sessions in the meantime.
