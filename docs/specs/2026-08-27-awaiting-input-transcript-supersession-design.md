# Taking the raised hand down: transcript supersession for awaiting-input

A Claude session that stops on a permission prompt shows a raised hand in the
sidebar. Nothing reliably takes that hand down. This document records why the
existing mechanism cannot, and adds a second superseder that TBD evaluates for
itself rather than waiting to be told.

## The rail as it stands

A terminal's `awaitingInputReason` column carries a structured reason — the
verbatim `notification_type`, the message, and the class TBD files it under.
`Terminal.hasPromptOnScreen` is true when that class is `.promptOnScreen`, and
that is what puts the amber `hand.raised.fill` in the sidebar's suffix slot and
bolds the row's name.

Exactly one thing writes the reason: Claude Code's `Notification` hook, bridged
through `tbd hooks notification` into `handleTerminalNotificationEvent`. Exactly
one thing retracts it: **a later activity observation.** `setActivityState` nils
the reason columns unconditionally — it is the superseding rail — and the
same-value path calls `clearAwaitingInputReasonIfNotNewer` so a repeated state
still supersedes a not-newer wait. Activity observations arrive from a small set
of hooks the TBD overlay registers: `UserPromptSubmit` reports working, `Stop`
and `StopFailure` report idle, `SessionStart` re-establishes identity, and the
`AskUserQuestion` pre/post pair brackets a question.

That design is sound and stays. It is also incomplete in a way no tuning fixes.

## Why the hand stays up

**Claude Code has no permission-decision hook.** The event vocabulary carries
`PermissionRequest`, which fires on the ask path *before* the human decides, and
`PermissionDenied`, whose own help text reads "After auto mode classifier denies
a tool call" — auto-mode denials, not human ones. A user's approval or refusal
fires nothing. The `Notification` hook is raise-only by construction: it reports
that a prompt was raised, never that it went away.

So after a human approves a permission, the next activity observation is the
`Stop` at the end of the turn, which can be many minutes away. The row shows a
raised hand at a session that is working.

A refusal is no better. Rejecting a tool call is not an error; it resolves to a
tool result telling the model the user does not want to proceed, so neither
`PostToolUse` nor `PostToolUseFailure` fires. The hand waits for `Stop` there
too, though in practice a refusal is usually followed closely by one.

And when a session's hook rail stops reaching the daemon at all, nothing
retracts the reason ever. This is not hypothetical. A terminal observed in the
live fleet held a `permission_prompt` reason recorded at 15:05 on one day while
its session transcript was still being written at 15:59 on the next — a raised
hand standing for twenty-five hours over a session that was demonstrably making
progress, with no activity observation reaching the daemon in that window.

## The signal TBD already has

**A session sitting on a permission prompt stops writing to its own transcript.**
The assistant message carrying the tool call is flushed before the prompt is
raised; from then until a human answers, the parent session's turn contributes
nothing further to the JSONL. A terminal in the live fleet made the positive
case: a `permission_prompt` reason recorded at 14:51 against a transcript whose
last write was 14:45, six minutes of a pending prompt with a frozen file. That
terminal was later answered, its activity rail fired, and the reason retracted
normally.

**But the file is not the session's alone, and this is the whole difficulty.**
A parallel `Task` subagent appends **sidechain** records to the same JSONL while
the prompt is still on screen — as does a backgrounded task's completion record,
and a queued user message. So the file growing is not proof the prompt was
answered. Claude issues a `Task` and a `Bash` in one turn, the `Bash` raises a
permission prompt, the subagent appends two seconds later: a mechanism that read
growth as an answer would drop the hand at the exact moment a human is being
waited on, and the row would show a working session indefinitely. That is the
failure that costs a night, and it is the reason `SessionStateResolver` refuses
the growth-as-answer inference outright.

What discriminates the two cases is not *whether* the file grew but *who* wrote.
The parent session's records are the ones the prompt gates; a nested agent's are
not. A record appended since the prompt that does not carry `isSidechain` is the
parent writing again, and the parent cannot write while blocked. That is the
signal, and it is a machine field on a machine record — the same field
`TranscriptParser` and `ClaudeDelegationSample` already partition on, never a
reading of prose.

## The rule

When `handleTerminalNotificationEvent` records a reason whose class is
`.promptOnScreen`, it stats the session JSONL and stores the file's path,
modification time and size inside the `AwaitingInputReason` value.

When a reader later loads that terminal, it stats the file again and compares.
The comparison asks whether the file changed since the prompt was raised, not
whether the file is newer than some timestamp. That distinction is the point.
Claude Code raises the `permission_prompt` notification from a debounced,
cancellable timer, so the delay between the transcript write and the reason's
observed-at stamp is set by someone else's internals and can change without
notice. A fingerprint captured at raise time depends on none of it, and is
immune to clock skew between the writer of the file and the writer of the row.

What a difference means:

- **Nothing changed** — the hand stays up. This is the steady state, and it
  costs one `stat`: no open, no read, no parse.
- **The path changed** — the session was retargeted by a `/clear`, a compaction
  or a resume. Retract: a fingerprint cannot describe a file it was not taken
  from, and the reason it described belongs to a session that no longer exists.
  The activity rail reaches the same conclusion by its own route when
  `SessionStart` lands.
- **The size shrank** — the file was truncated or rotated. The stored offset no
  longer names a position in this file, so nothing can be compared against it.
  Retract.
- **The file grew** — and only here does the check cost more than a `stat`. The
  region appended since the stored size is read and its records examined. A
  single non-sidechain record means the parent session itself wrote, so the
  prompt was answered: retract. Sidechain-only means a nested agent wrote while
  the human is still blocked: **the hand stays up**, and the stored fingerprint
  is refreshed to what was just observed, so the next pass is a `stat` again and
  the same bytes are never re-read.
- **The file cannot be read** — nothing changes, and it is retried on the next
  pass. Inability to look is never evidence.

Retraction clears the reason columns and broadcasts
`.terminalAwaitingInputChanged` with a nil reason, exactly as the activity rail
does when it supersedes a reason.

**The cost, stated honestly.** One `stat` per raised hand per pass in the steady
state — in a 153-terminal fleet, two rows held a standing prompt. When a file is
growing, a bounded read of only the region appended since the previous pass, and
the refresh means that region is what arrived in one interval rather than the
whole file. The delta read is capped at 64 KiB, the same order of tail window the
daemon's other transcript readers use; when the appended region exceeds the cap,
only its tail is examined, which can miss a parent record buried in the
unexamined part and therefore fails toward leaving the hand raised.

`AwaitingInputReason` is stored as JSON in a text column and decodes through
`decodeIfPresent`, so the fingerprint field needs no migration and rows written
before it shipped decode it as absent.

## Where the check runs

Three readers consult `awaitingInputReason`, and they reach terminal rows by
different routes. **Two of them reconcile**, through one shared helper:

- **`terminal.list`** — the app's poll, every two seconds while the app is
  connected. This is the path that heals a row for the sidebar.
- **`SupervisionReadoutBuilder`** — loads rows one at a time for a readout, and
  can run with no app attached, which is exactly the case `terminal.list` cannot
  cover.

**The third reader does not reconcile.** `handleSessionStates`, backing the
`session.states` RPC, reads the same column through `SessionStateFactGatherer`
and resolves it with `SessionStateResolver`. It performs no supersession, and
this is sound rather than an oversight:

- It never wrote the row, and it is not the rail that owns retraction. A
  read-only reporter that also mutated the record it reports would give the same
  column two writers on two schedules.
- A stale row it reads is transient. `terminal.list` heals it on its own polling
  cadence, so `session.states` sees the corrected value on a later cycle without
  doing anything itself.
- Most importantly, the resolver does not report a stale prompt confidently. It
  independently compares the transcript's append stamp against the reason's
  observed-at, and when the transcript has moved it degrades the answer to
  `.unknown(why:)` naming both possibilities, rather than asserting
  `.awaitingInput`. Its refusal is coarser than the supersession's — it does not
  distinguish a sidechain writer from the parent — and it is deliberately
  coarser, because a resolver that guessed wrong would report `.working` for a
  session blocked on a human. The two mechanisms agree on direction and differ
  only in how much they are willing to conclude.

So the precision the supersession buys is available on the paths that write, and
the path that only reads stays honest about what it does not know.

There is no sweep and no timer. The check runs only for terminals holding a
standing `.promptOnScreen` reason, and both reconciling call sites already
perform far heavier transcript I/O on the same pass:
`CodexTranscriptActivityTracker` reads Codex transcripts on every
`terminal.list`, `ClaudeDelegationTracker` opens and reads a byte-limited tail of
the JSONL for every terminal that just ended a turn, and the readout builder
samples session counters from the transcript per agent. A background sweep would
perform the same stats on a worse schedule and add a timer to own, name, and
test.

## Edges

Every edge fails toward leaving the hand up. A hand that lingers is the bug this
document fixes; a hand that drops while a human is still being asked for
something is worse, because it hides the one row that needs attention.

- **The file cannot be read, or has no path** — no retraction. TBD's delegation
  rail already states the principle this borrows: inability to look is never
  evidence. Here it is never evidence that a prompt was answered.
- **The appended region cannot be parsed** — a partial line at the tail, a
  record shape this build does not model. It is not a non-sidechain parent
  record until it is read as one, so it does not retract.
- **No fingerprint stored** — the row predates this mechanism. Adopt the current
  stat and store it, so the row self-heals on the transcript's next write. This
  needs no clock comparison and no horizon constant, and it leaves a genuinely
  pending prompt raised.
- **Concurrency** — the stat and the delta read happen outside the database, so
  the clear re-reads the stored fingerprint inside the write transaction and
  clears only if it still matches what was compared. This mirrors
  `clearAwaitingInputReasonIfNotNewer`, whose comment explains why: the row a
  handler read before an unbounded stretch of async work may already be stale,
  and `handleTerminalNotificationEvent` runs concurrently on its own connection.
  The fingerprint refresh on a sidechain-only append takes the same conditional
  form, so a reason recorded while the delta was being read is not overwritten
  by a measurement of the file as it stood before it.

## Seams and testing

The stat is reached through an injected closure so tests drive fingerprints
without a filesystem, and the delta read is driven from written temp files whose
contents the test controls. No clock seam is required: nothing here sleeps,
debounces, or polls, and a file's modification time is data rather than behavior
— the distinction `CLAUDE.md` draws between the `Duration` and `Date` seams.

Tests cover: the fingerprint is captured when a `.promptOnScreen` reason is
recorded and not for other classes; an unchanged file does not retract; a
changed `transcriptPath` retracts; a shrunken file retracts; an appended region
carrying a non-sidechain record retracts; an appended region carrying only
sidechain records does **not** retract and refreshes the stored fingerprint; a
second pass after such a refresh reads no bytes; an unreadable file does not
retract; an absent fingerprint is adopted rather than acted on; a stale expected
fingerprint makes the conditional clear a no-op; and the broadcast carries a nil
reason.

## The classifier's vocabulary

`AwaitingInputClass` files a verbatim `notification_type` under a class, and
states that it lists Claude Code's types exhaustively so that adding one is a
visible edit rather than a silent reclassification. That claim has drifted:
Claude Code emits more types than the published documentation lists, and two of
them raise a prompt a human must answer.

- **`worker_permission_prompt`** and **`elicitation_url_dialog`** join
  `.promptOnScreen`. Today they fall through to `.unrecognized` and raise no
  hand at all.
- **`computer_use_enter`**, **`computer_use_exit`**, **`push_notification`**,
  **`quota_auto_resume_fired`**, **`quota_auto_resume_stale`** and
  **`quota_auto_resume_disabled`** join `.informational`, restoring the
  exhaustiveness the type claims. None of these changes behavior; they make the
  next drift a visible edit again.

The default case stays as it is. A type this build has never heard of remains
`.unrecognized`: no prefix matching, no case folding, no guessing that something
sounds like a prompt.

## No feature flag

`CLAUDE.md` requires a default-off flag for behavior that acts autonomously or
can destroy state, and exempts bug fixes. This is a bug fix — a raised hand that
never comes down is the system failing its own existing theory, not a revision
of it — and the four properties that make the exemption apply here are worth
naming, because the feature does write to a persisted column and "it deletes no
state" would be the wrong reason to reach the right conclusion:

- **The write is narrow.** One column pair on one row, to nil, and only for rows
  already holding a `.promptOnScreen` reason. Nothing else in the record is
  touched, and no row without a standing prompt is read past its reason field.
- **The write is idempotent and conditional.** It clears only when the stored
  fingerprint still matches what was compared, so a repeated pass over an
  already-cleared row does nothing, and a concurrent raise is not clobbered.
- **Every failure direction is the status quo.** An unreadable file, an
  unparseable append, an over-cap region, a mismatched expectation: each leaves
  the hand raised, which is the behavior shipping today.
- **It rides an existing read path.** No timer, no sweep, no background actor,
  no new schedule to reason about — the work happens on passes that already load
  these rows and already read these transcripts.

A flag here would mean a config column and a migration to gate a correction, and
would leave the defect standing for everyone who never found the toggle.

## Rejected alternatives

- **Retracting on any transcript change.** The simplest rule — the file moved,
  therefore the prompt is gone — and it is wrong in the direction that matters.
  A parallel `Task` subagent appends sidechain records to the same JSONL while
  the prompt is still on screen, as do a backgrounded task's completion record
  and a queued user message. The hand would drop seconds after a permission
  prompt in any turn that also delegated, and the row would then show a working
  session for as long as the human took to notice by other means. Reading who
  wrote the appended records costs a bounded read only while the file is
  growing, and buys the one distinction the raw growth signal cannot make.
- **A `PostToolUse` hook as the take-down signal.** A tool that ran is proof its
  permission prompt was answered, and the hook fires within milliseconds. It was
  rejected on coverage rather than cost: it says nothing about a refusal, which
  fires no tool-completion hook at all, and it cannot help a session whose hook
  rail has stopped reaching the daemon — the twenty-five-hour case above. Adding
  it alongside the transcript check would buy roughly two seconds of latency in
  exchange for a second rail that can disagree with the first, a hook-overlay
  entry, and a `tbd` process spawn per tool call across the whole fleet.
- **Scoping a hook to the permission prompt itself.** There is nothing to scope
  to. A permission prompt is a gate on another tool's call, not a tool; for
  `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest` and
  `PermissionDenied` the matcher key is the tool name, and no synthetic name
  represents the prompt. `AskUserQuestion` is the misleading precedent: it is a
  real tool with a real name, which is why the overlay can matcher-scope it.
- **Comparing the transcript's modification time against the reason's
  observed-at stamp.** Simpler, and it would repair existing rows the moment it
  shipped. It depends on Claude Code flushing the assistant message before its
  debounce timer fires — true in every sample taken, but an assumption about
  another program's internals whose failure mode is dropping every hand
  instantly. Adding a margin in seconds does not remove the dependency; it
  encodes a guess about it, and costs that latency on every prompt.
- **Deriving the state at read time without writing.** Leaving the column stale
  and having `hasPromptOnScreen` disbelieve it would avoid writes and
  broadcasts, but it leaves a value in the record that nothing believes — the
  outcome the existing supersession comments argue against — and the app cannot
  stat a daemon-side path on behalf of a remote lane.
- **A background sweep.** The doctrine that every durable external resource
  needs a named reconciler covers resources that outlive the request that made
  them. A stale column read by pull-based readers is not one: the readers that
  own the retraction can correct it on the pass that consults it, for the cost
  of a stat.

## Out of scope

Two findings surfaced alongside this work and are deliberately not addressed
here.

The first is why a session's hook rail goes silent while its transcript keeps
advancing. This design makes such a row render correctly; it does not explain
it, and the explanation likely lies in hook routing or CLI staleness rather than
in the awaiting-input rail.

The second is the raise signal. `PermissionRequest` fires immediately on the ask
path, carries the `tool_name` being gated, and cannot be switched off, while the
`Notification` hook TBD reads today is debounced, carries no tool name, and is
disabled outright by the `CLAUDE_CODE_DISABLE_PERMISSION_PROMPT_NOTIFY_HOOKS`
environment variable. Moving the raise onto `PermissionRequest` is a clear
improvement and an independent one: it changes when and how well the hand goes
up, and nothing in this document depends on which hook raised it.
