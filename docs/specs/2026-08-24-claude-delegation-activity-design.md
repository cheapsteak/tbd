# Claude Delegation Activity Design

## Purpose

A Claude session that delegates to a background subagent presents as idle while
its subagent works. The parent's turn genuinely ends at delegation, so the
`Stop` hook fires and sets `activityState = .idle`, and the sidebar's thinking
indicator goes dark for as long as the delegated work runs. Field measurement
on a live session recorded twelve minutes between the end of the turn that
dispatched a background agent and the notification that woke the parent.

This design adds a display-only rail that keeps the indicator lit across that
gap. It reads a count Claude Code already publishes, samples it only at turn
boundaries, and never touches the persisted activity fact.

## Goals

- Keep the sidebar working indicator lit while a Claude session waits on
  background subagents.
- Derive the claim from a machine-readable fact, never from rendered terminal
  text.
- Add no per-poll cost proportional to fleet size.
- Degrade to current behavior whenever evidence is missing or unreadable.
- Leave Codex and shell activity semantics untouched.

## Non-goals

- Changing what `activityState` means, or what it gates.
- Blocking hibernation for a delegating session.
- Reporting the internal progress of a subagent.
- Distinguishing foreground from background delegation in the UI.
- Counting subagents for any consumer other than the indicator.

## Product semantics

A Claude terminal presents the working indicator when either rail says so:

1. The hook rail reports `activityState == .working`, as today.
2. The delegation rail reports outstanding background agents.

An explicit interrupt or a waiting-for-user state defeats both. The two rails
compose by disjunction because each speaks about a different interval: the hook
rail is authoritative during a turn, and the delegation rail speaks only after
one ends.

The indicator renders identically in both cases. A viewer learns that the
worktree is making progress, which is what the indicator has always claimed;
it has never distinguished which layer of the session is busy.

### Why this is a bug fix rather than a gated feature

The rail restores the indicator's intended meaning instead of adding a
capability. It performs no autonomous action, destroys no state, and replaces
no load-bearing path. It cannot affect hibernation, because it never writes the
field `HibernationGate` consults. Every failure mode resolves to the behavior
that ships today. It therefore carries no feature flag, on the same reasoning
that shipped the Codex activity reconciliation unflagged.

## Relationship to the supervision session state

This rail feeds the sidebar indicator and nothing else. It does not change
`SessionStateResolver`, which composes the separate `SessionStateValue` that
`session.states` and the fleet supervision readouts consume. A delegating
session continues to resolve `.idle` there, carrying its source and observed-at
so a consumer can see that `idle` means "the hook rail last reported a turn
ending, at this time".

The two answers differ because they are answers to different questions, and the
separation is deliberate. The indicator asks whether the worktree is making
progress, and a bounded, display-only, fail-toward-idle claim serves that well.
Supervision asks whether a session needs a human, and it may act on the answer;
it therefore holds a higher bar for what counts as evidence and prefers
reporting ambiguity to guessing. Extending the delegation fact into the
supervision model would be a separate design with a different risk profile,
because that model's consumers are not confined to a spinner.

## Authoritative signal

Claude Code writes a `system` record with `subtype: "turn_duration"` at the end
of every turn. When background agents remain live, that record carries
`pendingBackgroundAgentCount` with their number; when none remain, it omits the
field entirely. The distinction between a present count and an absent field is
therefore the whole signal, and no other record needs reading.

The field is a **level**, not an **edge**, and the design rests on that
difference. A level restates current truth on every emission, so sampling only
the newest value is correct regardless of how many earlier values went unread.
An edge — a start and stop event pair counted into an accumulator — must be
delivered exactly once or the count drifts, and a missed decrement latches the
indicator on forever. Level sampling makes that failure structurally impossible.

Two measurements establish that Claude Code, not TBD, maintains the level.
Across a corpus of real sessions, agents reached four terminal states —
completed, failed, killed, and stopped — and every one of them notified the
parent, which ran a turn, which restated the count. Launches whose notification
never appeared in the transcript were rarer than one in five hundred. In the one
such case where the session kept running afterward, all nineteen subsequent
`turn_duration` records reported the field absent. The count is maintained
independently of whether any observer sees the notification.

### Rejected signals

- **`SubagentStart` / `SubagentStop` hooks.** Claude Code's documented and
  supported interface, and instant rather than deferred. Rejected because the
  pair is edge-triggered and therefore carries the drift failure described
  above, because it fires for foreground subagents that can never change the
  display, and because whether `SubagentStop` fires for a background agent
  completing after its parent's turn has ended remained unverified. The
  transcript lifecycle was verified end to end instead.
- **`TaskCreated` / `TaskCompleted` hooks.** These exist, but they fire on the
  `TaskCreate` tool — the task-list feature — and say nothing about subagents.
- **An unresolved `Agent` tool-use.** A background launch writes its
  `tool_result` immediately, carrying `status: "async_launched"`, so the
  transcript shows a completed tool call while the work runs out of band.
  `SessionStateResolver` documents this trap already.

### Accepted risk

Claude Code documents its transcript format as internal and subject to change
on any release. The field has been present continuously across roughly
thirty-five releases, and TBD already depends on this format in
`TranscriptParser` and throughout the Codex reconciler, so the exposure is
known rather than new. A release that removes the field produces no claim,
which is exactly today's behavior.

## Components and data flow

### Delegation tracker

`ClaudeDelegationTracker`, a daemon actor under `Sources/TBDDaemon/Claude/`,
owns two pieces of transient state: the set of terminals awaiting a sample, and
the last sampled count for each. Nothing persists. Its state is keyed by
terminal and discarded when a terminal's transcript path changes, so a count
read from a cleared or compacted session can never speak for its successor.

The tracker mirrors `CodexTranscriptActivityTracker`'s role but needs far less
machinery. The Codex tracker reduces an event stream and therefore may not miss
a record, which is why it carries shared byte budgets, round-robin quanta and
generation watermarks. A level sampler may skip everything except the newest
value, so it needs none of them.

### Marking a terminal for sampling

`handleTerminalActivityEvent` already receives every Claude turn boundary. When
a Claude terminal reports `idle`, the handler marks it for sampling.

**The mark is set unconditionally, before the handler's unchanged-state early
return.** That guard returns without acting when the reported state matches the
stored one, and consecutive `idle` reports with no intervening `working` are
reachable: a background agent's completion notification wakes the parent, which
runs a turn and ends it. Marking after the guard would drop that second
boundary and latch the previous count. Marking before it costs a set insertion
and removes the dependency on whether an injected notification submits as a
user prompt.

### Sampling

The next `terminal.list` satisfies outstanding marks. For each marked terminal
the tracker stats the transcript path, reads at most the final 64 KiB, discards
the partial leading record through its first newline, and scans backward for the
newest `turn_duration`. A present `pendingBackgroundAgentCount` greater than
zero becomes a claim; an absent field, an absent record, or an unreadable file
produces none. The mark then clears.

Sampling deliberately does not happen inside the activity handler, and the
reason is an ordering fact that a reasonable implementation would otherwise get
wrong. Claude Code runs the `Stop` hooks first, writes its hook summary once
they return, and writes `turn_duration` about two milliseconds later. A read
performed while the hook is executing therefore observes the *previous* turn's
record — precisely the difference between a count of zero and a count of one in
the case this design exists to catch. Deferring to the next poll clears the gap
by three orders of magnitude.

### Publication and composition

A claim sets `presentationActivityState = .working` on the wire. That field is
response-derived and never persisted, so this design adds no database column and
no migration.

`WorktreeRowView.isForegroundWorking` gains a Claude branch. **The two agent
kinds compose their rails differently, and inverting them is the likely bug.**
For Codex the presentation rail *replaces* the raw one: a Codex terminal shows
working only when the transcript agrees. For Claude the presentation rail is
*disjunctive* with the raw one: either rail alone suffices, because the hook
rail stays correct during a turn and the delegation rail speaks only after one
ends.

### Clearing a stale claim

Every ordinary ending restates the level, so no timeout constant appears
anywhere in this design. What counts as a stalled agent is a theory on which
reasonable projects differ, and compiling one would be the most expensive place
to hold it. Two endings do not restate the level, and each gets a fact rather
than a theory:

- **Interrupt.** An interrupted turn frequently writes no `turn_duration` at
  all, so the newest record keeps reporting the pre-interrupt count. TBD's own
  `.terminalInterrupt` fact defeats the rail, matching the precedence the Codex
  presentation path already follows.
- **Session end.** A session that exits while agents remain live leaves a final
  record reporting them, and no later turn corrects it. A `SessionEnd` entry in
  the Claude hook overlay clears the claim. It follows the file's established
  discipline — silent failure, never wedging the agent — and carries an explicit
  short timeout, because Claude Code runs `SessionEnd` callbacks inside a
  1.5-second shutdown budget.

A crash that delivers no `SessionEnd` leaves a claim standing. The residual is
bounded by the reconcilers and by hibernation, and it is cosmetic by
construction, because the rail cannot reach anything but the indicator. This
design accepts that case rather than introducing a timeout to cover it.

## Cost

The rail adds no term proportional to fleet size. A session that has not just
ended a turn is neither stat'd nor read.

Measured on a development fleet of roughly a hundred worktrees: stating every
Claude transcript path costs about 0.2 ms, and a 64 KiB tail read with its parse
costs about 0.5 ms. Because only marked terminals are sampled, steady-state work
is one read per turn end rather than either figure per poll.

Transcripts are large — a median around 2 MB and a maximum around 40 MB in that
corpus — which is why the design stats first, reads a bounded tail, and never
reads a whole file.

## Failure modes

Every failure produces no claim, and no claim means the indicator behaves
exactly as it does today. The rail can therefore fail toward false idle but
never toward false thinking, which is the safety direction the Codex
reconciliation established.

- A Claude Code release without the field yields no claim.
- A tail containing no `turn_duration` yields no claim. This arises when much
  has been appended since the last turn ended — a long turn in progress — where
  the hook rail already reports working, so the delegation rail is not needed.
  Measurement puts the newest record a median of about 1.3 KB from end of file,
  within a 64 KiB tail for roughly 98% of transcripts.
- A missing, empty, or unreadable transcript path yields no claim. Inability to
  look is not evidence of work.
- A truncated leading record in the tail is discarded through its newline.
- A transcript path change discards the tracker's state for that terminal.
- Removing a terminal prunes its tracker state on the existing retention path.

## Durable resources

This design creates none. Tracker state lives in memory and is pruned with the
terminals it describes. No git ref, tmux object, spawned process, or file
outlives the request that created it, so no reconciler needs extending.

## Testing

Two tests must fail against the current code for the right reason, because each
guards a trap that a plausible implementation walks into and that a weaker test
would pass regardless:

- A transcript whose newest `turn_duration` belongs to the previous turn must
  not publish that count. This fails if sampling moves into the activity
  handler.
- Two consecutive `idle` events with no intervening `working` must both mark.
  This fails if the mark moves below the unchanged-state guard.

Fixtures use real captured transcript bytes rather than hand-written JSON.
Synthetic fixtures have twice measured a fallback path in this repository while
appearing to exercise the real one. The captured set covers a present count, an
absent field, a tail with no record, a truncated leading record, and an
oversized record.

Remaining coverage:

- The composition asymmetry, including a Codex regression guard, since that path
  ships unflagged today.
- Interrupt and waiting-for-user each defeating the rail.
- A transcript path change discarding a stale count.
- An absent field reproducing current behavior exactly.
- The hook overlay's exact-equality entry set, extended with the `SessionEnd`
  entry, asserting its silent-failure suffix and its timeout.

## Files

New:

- `Sources/TBDDaemon/Claude/ClaudeDelegationTracker.swift`
- `Tests/TBDDaemonTests/ClaudeDelegationTrackerTests.swift`

Modified:

- `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` — mark before the
  early return; satisfy marks during `terminal.list`.
- `Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift` — `SessionEnd` entry and its
  timeout constant.
- `Sources/TBDApp/Sidebar/WorktreeRowView.swift` — the Claude branch.
- `Tests/TBDDaemonTests/ClaudeHookOverlayTests.swift` — the entry-set assertion.

This design requires no migration, no configuration column, no feature flag, and
no injected clock. Each is absent for a stated reason: the presentation field is
never persisted, the behavior is a bug fix, and the existing `terminal.list`
poll supplies the deferral rather than a new timer.
