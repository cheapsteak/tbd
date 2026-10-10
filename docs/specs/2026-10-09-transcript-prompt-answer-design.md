# Answering prompts from the transcript

## Summary

A person can drive a Claude Code session from the transcript pane with the
composer, for local sessions and for remote provider sessions alike. That
works until the agent opens a dialog: an `AskUserQuestion` picker or a tool
permission prompt. Then the person has to switch to the terminal, or for a
remote session attach to it, to answer. The composer can't help, because the
daemon refuses to send text while a prompt is on screen.

This design makes those dialogs answerable from the transcript. A pending
prompt renders as an interactive card in the transcript:
- **Question card.** Options as radio buttons or checkboxes, a free-text
  "Other" field per question, and Submit.
- **Permission card.** The tool and its input, plus Allow, "Yes, and don't
  ask again this session", and Deny with an optional reason.

The answer reaches Claude Code as a structured answer, exactly as if it had
been picked in the terminal dialog. The terminal dialog stays live the whole
time, and whichever side answers first wins.

Scope:
- Claude Code sessions on local worktrees, on both terminal transports.
- Remote provider sessions whose provider declares the new `answer`
  capability.
- Out of scope: Codex, and auto mode's classifier denials, which are not
  dialogs.

## Facts this design rests on

These were measured against Claude Code 2.1.296. The measurements ran the real
interactive TUI against the loopback fake model (`scripts/claude-stub.py`), so
they cost no tokens.

- **A `PermissionRequest` hook can answer a dialog while the terminal dialog
  stays usable.** The hook fires for `AskUserQuestion` and for ordinary tool
  permission dialogs. While it blocks, the dialog stays fully visible and
  usable.
  - **The hook answers first:** the dialog closes and the hook's decision
    applies.
  - **The terminal answers first:** the hook's later output is silently
    ignored, even if a second dialog is open by then.
  - Pressing Yes in the terminal leaves the hook running. Pressing No or
    Escape sends it SIGTERM.
- **A `PreToolUse` hook that blocks hides the dialog** until it returns. So it
  can't race the terminal and is not used.
- **The `PermissionRequest` payload has no `tool_use_id`.** It carries
  `session_id`, `transcript_path`, `cwd`, `prompt_id`, `permission_mode`,
  `tool_name`, `tool_input`, and sometimes `permission_suggestions`.
  `PreToolUse` fires about 55 ms earlier with the `tool_use_id`, so the two
  are paired by session.
- **These decision outputs work:**
  - **Question:** `{"behavior":"allow","updatedInput":{"questions":[…original…],"answers":{"<question text>":"<value>"}}}`
    - A multi-select value is one string joined with `", "`. An array reaches
      the model, but the TUI doesn't display it.
    - Free text is accepted as a value, and the model is told to read it
      carefully.
    - An unanswered question is silently dropped.
    - `allow` without `updatedInput` is ignored, and the dialog stays.
  - **Permission:** `{"behavior":"allow"}`. `updatedPermissions` applies
    "don't ask again" entries. With destination `session`, nothing is written
    to disk.
  - **Deny:** `{"behavior":"deny","message":"…"}`. The model receives the
    message as an error tool result, and the turn continues.
    `"interrupt": true` throws the message away and stops the turn.
- **Printing nothing and exiting 0 hands control back to the terminal
  dialog.** This is the fallback for every error and timeout.
- **Claude Code's "don't ask again" suggestions are not always permission
  rules.** For a plain Bash `touch` in default mode, Claude Code suggested
  "add this directory" and "switch the session to acceptEdits".
- **The transcript already holds the tool call while its dialog is open.** The
  assistant text and the `tool_use` reach the JSONL about 70 ms after
  `PreToolUse`. Only the `tool_result` waits for the answer.
  - This holds for `AskUserQuestion` too. The 2026-07-31 dismissal research
    saw the `tool_use` held back until the dialog resolved, so older versions
    may differ.
  - When one assistant message holds two tool calls that both need
    permission, both `tool_use` lines are on disk at once. The second dialog
    opens only after the first is answered.
- **In auto mode, ordinary calls never show a dialog.** Calls the classifier
  blocks fire `PermissionDenied`, not a dialog. Permission cards therefore
  appear mostly in default mode. Question cards appear in every mode.

## One idea: the pending prompt

A pending prompt is a dialog that is open and waiting for an answer. It has:
- an `id`
- a `kind`, either `question` or `permission`
- the `tool_use_id` when known
- the questions (for kind `question`)
- the tool name, tool input and "don't ask again" suggestions (for kind
  `permission`)

It resolves exactly once: by an answer from TBD, by an answer in the terminal,
or by the session moving on. A second answer to the same id is refused as
already resolved. That refusal is the whole of "first answer wins". Local
sessions and remote sessions feed the same app-side model. The app answers
both through one shape of answer, and only the delivery differs.

The answer payload, for both paths:
- **Question:** `{kind: "question", answers: {"<question text>": "<value>"}}`.
  There must be one entry per question. A value is an option label, labels
  joined with `", "`, or the free text typed into "Other".
- **Permission:** `{kind: "permission", decision: "allow" | "allow_always" | "deny", message?}`.
  `message` applies only to `deny`. `allow_always` applies every suggestion
  Claude Code offered, with the destination forced to `session`, so it lasts
  for this session only and writes nothing to disk. It is offered only when
  suggestions exist.

## Local delivery

### Hooks

`ClaudeHookOverlay` adds these hooks, and only when the flag is on. The
existing `AskUserQuestion` pre and post hooks stay as they are.
- **`PreToolUse`, no matcher: `tbd prompt note`.** It records
  `{terminal, session, tool_use_id, tool_name, input hash}` with the daemon
  and returns at once. It never prints a decision.
- **`PostToolUse` and `PostToolUseFailure`, no matcher: `tbd prompt note`.**
  These tell the daemon that a tool call finished, which resolves any prompt
  still open for its `tool_use_id`. They carry the input hash too, so they
  also resolve the session's open prompt when it has no `tool_use_id` and
  shows the same tool and input. This is how the daemon learns that the
  terminal won with Yes, because that answer leaves the waiting hook running.
  - For `AskUserQuestion` the hash covers `questions` alone, on the notes and
    the register alike. The post's input carries the merged `answers` as
    well, so a whole-input hash would never match.
  - These signals come after the tool finishes, not when you answer. So after
    a Yes in the terminal, the card still looks pending while the tool runs.
  - An answer sent from the card in that window reaches a hook whose output
    Claude Code ignores. The card holds "Answered" until the tool result
    lands, and the result shows what actually happened.
- **`PermissionRequest`, no matcher: `tbd prompt wait`.** Its hook `timeout`
  is 86400 seconds.
  1. It reads the payload and calls `prompt.register`. The daemon pairs it
     with a `prompt note` from the same session and tool name, which supplies
     the `tool_use_id`.
     - It matches the tool input's hash first, so two calls to the same tool
       in one message pair correctly.
     - If the hash doesn't match, it falls back to the latest note.
     - A note that arrives up to 5 seconds after its register still pairs.
     - An unpaired prompt gets a fresh UUID id instead.
     - The reply names the `tool_use_id` the prompt was paired with. A
       restarted daemon has lost its notes, so the hook sends its id and that
       `tool_use_id` back when it registers again, and the prompt keeps both.
       A prompt that was never paired stays unpaired, and its card stays on
       the fallback row described under "Placement".
  2. While the flag is off, `prompt.register` answers `disabled`, and the
     hook exits silently. Sessions that started while the flag was on still
     carry the hooks until they restart.
  3. It then holds `prompt.await(id)`, a long-poll RPC on the daemon socket.
     - Like `state.subscribe`, the call bypasses the RPC concurrency limiter,
       so many waiting sessions can't block the daemon.
     - The HTTP transport refuses it, because HTTP can't see a closed
       connection.
     - If the connection drops while the daemon restarts, the hook reconnects
       and registers again.
  4. **An answer arrives:** it prints the decision JSON wrapped as
     `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":…}}`,
     acknowledges delivery to the daemon, and exits 0. A deny without a
     message carries the text "The user declined this from TBD.".
  5. **The prompt resolved elsewhere, or anything failed:** it prints nothing
     and exits 0, and the terminal stays in charge.

  When the daemon is unreachable, the command exits silently at once. So a
  session behaves exactly as it does today whenever TBD can't answer.

### Daemon: `PendingPromptStore`

`PendingPromptStore` is an actor that generalises today's
`PendingQuestionStore`. It lives in memory and holds pending prompts keyed by
id, each with its waiting `prompt.await` continuation.

A prompt resolves on the first of these:
- **`prompt.answer` from the app.** The store hands the payload to the
  waiting hook, and the RPC returns once the hook acknowledges it. If no
  acknowledgement arrives within 5 seconds, the RPC answers
  `already_resolved`. The acknowledgement (`prompt.ack`) bypasses the RPC
  concurrency limiter, so a burst of slow RPCs can't delay it past that
  window and turn a delivered answer into "answered elsewhere".
  - If no hook is attached at that moment, for example while a daemon restart
    is still reconnecting it, the RPC returns a retryable error. The card
    offers Retry.
- **`PostToolUse` or `PostToolUseFailure` for its `tool_use_id`**, or, for
  an unpaired prompt, for the same tool and input hash. The terminal won. The existing `AskUserQuestion` post hook also covers
  questions.
- **A new `prompt.register` in the same session.** A session has one open
  dialog at a time, so the old one is over.
- **The hook's connection closing.** No or Escape in the terminal killed it.
- **The terminal or session ending.**
- **An hour with no hook attached.** This is a safety sweep, not the normal
  path.

Each change emits a per-terminal `pendingPrompts` delta, which carries
everything the cards render. The daemon stops sending the old
`pendingQuestions` delta. The case stays decodable so an app paired with an
older daemon still works.

The phrase "pending prompt" already names the queued first message of a new
worktree (`worktree.pending_prompt`, `PendingPromptCoordinator`). The two are
unrelated, and the new types say so in their doc comments.

No new durable resource is created:
- Claude Code owns the waiting hook process and ends it.
- The store is in memory, and its records clear themselves.

So the named-reconciler question is answered by "no orphan can outlive the
daemon or the session".

### The awaiting-input gate

The composer's `gateOnAwaitingInput` refusal stays unchanged. A typed message
still can't land in an open dialog. The card is the way to answer the dialog.
While a prompt is pending, the composer shows a one-line hint, "Claude is
waiting on a prompt above", that scrolls to the card.

## Remote delivery

### Contract additions

These additions go in `docs/remote-provider-contract.md`. They are additive
within the current major version and need no bump.
- **Session field `pending_prompt`, optional:**
  `{id, kind, tool_use_id?, questions?, tool_name?, tool_input?, tool_input_truncated?, suggestions?}`.
  - `questions` uses the existing `pending_question` item shape.
  - `tool_use_id` is present when the provider could pair the dialog with its
    tool call, and omitted otherwise. It is never null.
  - Long strings in `tool_input` may be cut for display. A cut string ends
    with `… (+N chars)`, and the provider sets `tool_input_truncated`. The
    provider may bound the whole object. As a last resort it may leave out
    `tool_input` and set `tool_input_truncated`, and the prompt stays
    answerable. Question text is never cut.
  - The `pending_question` rule extends to it. `agent_state` is
    `waiting_input` for exactly as long as a pending prompt is present. Both
    come only from machine interfaces, never from terminal text.
  - No capability gates the field. A provider that emits `pending_prompt` for
    a question also emits the matching `pending_question` with the same id, so
    callers that only know `pending_question` keep working.
- **Capability and verb `answer`:** `answer <session_id> <prompt_id>`, with
  the answer payload above on stdin. On success it exits 0 and prints `{}`.
  Exit 0 means the decision reached the agent's dialog. If the terminal
  answered in the same instant, Claude Code may still ignore it, and nothing
  can detect that. Errors exit 1:
  - `already_resolved`: the prompt is no longer pending.
  - `invalid_params`: a kind mismatch, a missing answer, or `allow_always`
    without suggestions.
  - `not_found`: the session is unknown.
- **Capability rule:** a provider that declares `answer` must also declare
  `events`, so a prompt reaches the caller in seconds rather than on the
  60-second `list` poll.
- **Rewrite** the paragraph that says there is no dedicated answer verb, so it
  describes `answer`.

The first provider implements all of this, along with `events`, in its own
repository. Its box hooks use the same `PermissionRequest` mechanism
described above.

### Daemon

- **`RemotePendingPrompt`.** The daemon decodes this type leniently, as it
  already does `RemotePendingQuestion`. A provider that sends only
  `pending_question` is projected to a prompt of kind `question`. It renders,
  but it is answerable only when the provider declares `answer`.
- **Carry the field through every copy.** Every hand-built
  `RemoteSessionPayload` copy carries the field, including
  `withoutTranscriptHint` and `withFreshestAgentAxis`. A copy that leaves it
  out silently drops it from the mirror. The field changes only when a prompt
  opens or closes, so mirroring it doesn't rebroadcast on every poll.
- **Except a stale snapshot.** `projectedForStaleSnapshot` drops it, as it
  already drops `pending_question`. A stale snapshot can't claim that a
  dialog is still open.
- **New RPC `remote.answer`.** It follows `handleRemoteSendMessage`:
  1. It checks the remote gates and the new flag.
  2. It checks the declared `answer` capability. If the capability is
     missing, it returns the standard missing-capability refusal.
  3. It runs inside the per-session `RemoteSendMessageSerializer`, so an
     answer never overlaps a typed message.
  4. It refuses a stale snapshot, and a prompt id that no longer matches
     `pending_prompt.id` ("already resolved"). It skips the `waiting_input`
     send refusal.
  5. It records the actuation under a new `.remoteAnswer` surface.
  6. It invokes the verb with a 30-second timeout. A timeout or signal is an
     unknown outcome and is never retried automatically, as with
     `sendMessage`.
  7. The verb's own error codes (`already_resolved`, `invalid_params`,
     `not_found`) describe this one answer, not the provider, so they don't
     count against provider health. Losing the race to the terminal must not
     mark the provider unhealthy and every session's snapshot stale.

  After a success, the app calls `requestRemoteTranscriptSync`, as the
  composer does after a send, so the tool result appears promptly.
- **The `sendMessage` refusal text changes.** While a prompt is open, it
  points at the card when the provider declares `answer`, and at the terminal
  otherwise.
- **Attention text.** `RemoteAgentAttention` reads `pending_prompt`:
  - a permission reads "Blocked on permission: <tool> <short input>"
  - a question keeps today's text

  The raised hand still follows `waiting_input`, and `events` makes it arrive
  within seconds.

## The cards

### Placement in the transcript

The transcript has two independent sources: the JSONL for rows and the
pending-prompt state for cards. A merger joins them on `tool_use_id` before
`TranscriptPresentation.build()` runs, so the table always receives one
consistent list. The merger serves both the local pane and the remote pane,
and the remote pane gains this merge step.

`AskUserQuestionMerger` stays beside it, with a different job. It drops a
pending question once the `tool_use` reaches the file. The new merger keeps a
pending prompt attached to that row until the prompt resolves.

- **The transcript already holds the tool call** (the normal case). That row
  becomes the card in place, and the file decides its position.
- **The transcript doesn't hold it yet.** A remote cache can lag behind
  `events`, and an older Claude Code holds the write back. The card is
  appended at the end under the same `tool_use_id`. The agent is blocked, so
  nothing legitimately follows it. Rows that arrive later from an earlier
  point in the turn appear above it. When the real tool call lands, it
  replaces the card in place under the same id.
- **No `tool_use_id`, a question.** The last `AskUserQuestion` call in the
  transcript that has no result yet becomes the card in place. A provider
  that sends only `pending_question` never names the tool call, and its row
  is already on disk, so an appended copy would draw the question twice.
- **No `tool_use_id`, a question whose dialog has closed** while its card is
  held, with no open `AskUserQuestion` row left. Its row has its result by
  now, so the newest answered `AskUserQuestion` row is taken as its row: no
  card is drawn, and the prompt counts as settled, which releases the hold.
  Appending a card here would draw the answered question twice until the hold
  timed out.
- **No `tool_use_id` otherwise**, or an open question with no open
  `AskUserQuestion` row. The card is appended under the id `prompt-<id>`. It
  retires on a timeout once the prompt resolves, because nothing can replace
  it in place.
- **Activity groups.** A pending card is always a standalone row. A tool call
  that would normally fold into a collapsed activity group is lifted out of
  the group while its prompt is pending, and folds back once it resolves. With
  two tool calls on disk, only the one whose dialog is open is lifted out. The
  group's id is keyed on the window-start members, not on the lifted row.
- **Ids.** Card ids never start with `line-` or `tail-`, which the table's
  prepend anchoring treats as unstable.
- **Caches.** An appended card never enters `sessionTranscripts` and is never
  recorded as a window start.

### Question card

This is the existing `AskUserQuestionCard`, made interactive while its prompt
is pending:
- Each question shows its header and text, then its options with
  descriptions. Single-select options are radio buttons, and multi-select
  options are checkboxes.
- An "Other" row has a one-line text field, and typing into it selects it.
- Several questions stack in one card. Submit is enabled only when every
  question has an answer.
- The row's height is computed once, from the questions and options, which
  are all known up front. Nothing inside the card grows. A long description is
  cut to two lines with a tooltip. This keeps the table's static-height
  constraint.

### Permission card

`PermissionPromptCard` is new:
- A title line names the tool. Below it is a preview of fixed height:
  - **Bash:** the command, up to six lines.
  - **Write and Edit:** the path and the first lines of the content or edit.
  - **Other tools:** compact input JSON.
- "Show all" opens a popover with the full input, and says when the provider
  cut it.
- Buttons:
  - **Allow.**
  - **"Yes, and don't ask again this session".** It is shown only when
    suggestions exist, and lists what they do, such as "adds directory X" or
    "switches to acceptEdits".
  - **"Deny…".** It reveals a one-line "Tell Claude why (optional)" field
    with a confirm button, inside the card's fixed height.

### States

Both cards share these states:
- **Waiting:** the controls are live.
- **Sending:** the controls are disabled and a spinner shows.
- **Answered:** the card shows the chosen answer and stays until the tool
  result lands in the transcript, then renders as today's answered row. This
  covers the gap between the prompt clearing and the file catching up, about
  170 ms locally and a few seconds remotely. A bounded timeout retires it if
  the result never comes.
- **Answered elsewhere:** the daemon or provider said `already_resolved`. A
  short note shows, and the card goes read-only.
- **Error:** the message and a Retry button.
- **Unknown outcome** (remote timeout): "May not have arrived" and Retry. A
  retry that did arrive the first time returns "answered elsewhere".

The card stays read-only, exactly as today, in these cases:
- the flag is off
- the remote provider doesn't declare `answer` (the card shows "Attach to
  answer")
- the row has no live pending prompt behind it

## Flag

`transcript_prompt_answer_enabled` is a new `config` column, added by a `.sql`
migration with no SQL default, so NULL means "never chose". Its default lives
in `Config.transcriptPromptAnswerDefault = false`. The flag is reported
through `DaemonCapabilitiesResult` and toggled in Settings under
Experimental, after the transcript-streaming toggle.

The flag gates two things:
- **Off:** the overlay leaves out both new hooks, `prompt.answer` and
  `remote.answer` refuse, and the transcript renders exactly as it would with
  no pending prompt: no card, no appended row, no row lifted out of its
  activity group.
- **On:** everything above.

Hook changes reach a session on its next start, as with every overlay change.

The flag exists because the feature sends input to sessions. The soak runs
with the flag on. Graduation flips the default constant, and a later change
deletes the flag.

## Testing

Each branch of the flag gets a test, following the repo rule.

- **Merger (pure):**
  - in-place on an existing row
  - appended when absent
  - the appended card replaced by a same-id row with no rebuild, checked
    through `TranscriptStreamPlan`
  - lifting a row out of its activity group and back without changing the
    group id
  - the `prompt-<id>` fallback, and an unpaired question carding the open
    `AskUserQuestion` row instead
  - a held unpaired question settling on the answered row rather than
    appending a duplicate, while an open one still appends
  - never a window start
- **Store:** each way a prompt resolves; a second answer refused; delivery
  acknowledged or timed out; `disabled` while the flag is off; the pairing
  of `PermissionRequest` with `PreToolUse`, including concurrent sessions and
  an unpaired prompt.
- **Decision encoding:** the question, multi-select, free-text, allow,
  `allow_always` and deny outputs, asserted against the exact shapes above.
- **`tbd prompt wait`:**
  - silent exit when the daemon is down
  - silent exit when the prompt resolves elsewhere
  - a printed decision when answered
- **`remote.answer`:**
  - capability refusal
  - flag refusal
  - stale-snapshot refusal
  - stale-prompt refusal
  - serialization with `sendMessage`
  - `already_resolved` mapping
  - unknown outcome on timeout

  All of these run against a fake provider.
- **Payload copies:** `pending_prompt` survives `withoutTranscriptHint` and
  `withFreshestAgentAxis`, and `projectedForStaleSnapshot` drops it.
- **Live check, zero tokens:** the real Claude Code TUI against the fake model
  with TBD's overlay. Answer a question and a permission from the card, win
  and lose the race from the terminal, and check what the model received.
