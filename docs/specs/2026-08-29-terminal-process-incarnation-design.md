# Terminal Process Incarnation Design

## Purpose

A terminal row outlives the process running in its tmux pane. TBD may replace
that process when a terminal is recreated, a model profile changes, or a
session hibernates and wakes. Process hooks can arrive after the originating
process has exited, and tmux coordinates and agent session IDs can both be
reused. Neither value alone proves that a hook belongs to the process the row
currently represents.

TBD assigns each managed terminal process a durable incarnation token. The
token travels in the process environment and returns through process-bound
hook RPCs. The daemon validates it in the same database transaction that
applies the hook. This design defines that shared lifecycle for Claude, Codex,
and replacement shells.

## Goals

- Reject SessionStart, activity, SessionEnd delegation changes, and delayed
  session recapture from replaced processes.
- Make replacement safe when tmux coordinates or agent session IDs are reused.
- Represent the prepare interval of a two-step hibernation replacement without
  claiming either the outgoing or future process owns the row.
- Accept hooks from a newly launched wake process while the parked marker
  remains until tmux confirms launch.
- Recover safely after a crash or failed replacement.
- Preserve compatibility for terminals launched before incarnation tokens.

## Non-goals

- Changing activity interpretation for any terminal kind.
- Changing when terminals hibernate, wake, or recreate.
- Making notification hooks or arbitrary agent protocols incarnation-aware.
- Ordering client delta delivery for an observation that committed before a
  later replacement.
- Making tmux process replacement transactional with the database.
- Introducing a general event-sourcing or process-leasing framework.

## Durable state

Each terminal row has two optional UUIDs:

- **Current incarnation** — `sessionIncarnationID` names the process that owns
  the row. TBD exports it as `TBD_TERMINAL_INCARNATION_ID` when launching that
  process.
- **Pending incarnation** — `pendingSessionIncarnationID` names a replacement
  being prepared but not yet confirmed. It is normally `NULL`.

Both fields are optional for database and JSON compatibility. A row with both
fields `NULL` is a legacy row. A non-null pending token is a durable replacement
phase, not the identity of a running process.

The terminal replacement snapshots used for compare-and-swap operations carry
both tokens. Any competing replacement, rollback, or wake therefore makes a
stale operation fail rather than overwrite the winner.

## Core invariants

- A process-bound SessionStart, activity event, or session recapture is accepted
  only when the pending token is `NULL` and its expected optional token exactly
  equals the current optional token.
- Exact optional equality preserves legacy behavior: a missing token matches
  only a legacy row whose current token is also `NULL`.
- Once a row has a managed current token, a missing or different token is
  stale.
- While a pending token exists, no process-bound SessionStart, activity event,
  or session recapture is accepted. The current token is retained only as
  rollback identity, and the pending token does not belong to a launched
  process yet.
- App-originated user interrupts are actions against the selected terminal, not
  process hooks. They bypass process identity validation and remain accepted.
- Token validation and the resulting terminal mutation happen in one database
  writer transaction.
- An accepted working hook cancels its scheduled resume in that same writer
  transaction, so a replacement cannot interleave and lose its own later
  schedule.
- Deferred Claude delegation marks, claims, and SessionEnd clears carry their
  process token. Sampling and process-derived clearing discard mismatched
  tokens, while an app-originated user interrupt still clears the selected
  terminal across incarnations.
- Every one-step process reset clears any pending token as it installs its new
  current token.

## One-step replacement

Most replacement paths can establish their complete launch intent before they
start a new process. Recreated Claude, Codex, and shell windows, profile swaps,
and wake preparation atomically:

1. Compare the caller's replacement snapshot with the durable row.
2. Set any new tmux coordinates and process-owned session fields.
3. Mint and store a new current token.
4. Clear the pending token and process-local activity, prompt, ordering, and
   transcript-boundary facts as appropriate for that path.
5. Commit before launching the process with the returned token.

A hook can race the launch, but it cannot arrive before the durable identity it
must report exists. A delayed outgoing hook reports the former token and loses
the atomic comparison.

## Two-step hibernation replacement

Hibernation is different because TBD first records park intent and then asks
tmux to replace a live agent with an inert shell. The outgoing agent may remain
alive if tmux replacement fails, so changing the current token at prepare time
would prevent startup recovery from recognizing and restoring that still-live
process.

The prepare transaction therefore:

1. Verifies the complete hibernation snapshot.
2. Retains the outgoing process's current token.
3. Mints a pending token.
4. Records the parked marker and cancels scheduled resume.
5. Stores idle activity with database provenance and clears prompt state.

The non-null pending token makes subsequent process-bound hooks inert. This
prevents a delayed or still-exiting agent from restoring working activity after
the row is parked, while retaining its current token for rollback.

TBD then asks tmux to replace the agent with an inert process. Only after tmux
confirms that replacement does the finalize transaction promote the exact
pending token to current, clear pending, and reset process-local ordering and
attention facts. The promoted token is injected into the replacement shell.
Promotion cannot happen earlier: before tmux confirmation the outgoing process
may still be the real pane occupant, and a crash must remain recoverable.

## Wake while parked

The parked marker describes user-visible lifecycle state; it is not an
incarnation gate. It deliberately remains set from wake preparation until tmux
confirms that the new agent launched.

Wake preparation is a one-step process reset. It replaces any abandoned
pending token, installs a fresh current token, clears pending, and commits
before launch. SessionStart and activity from the new process can therefore be
accepted by exact current-token equality even while the row is still marked
parked. Launch confirmation clears only the parked fields and preserves session
and activity facts already accepted from the new process.

Using `isParked` as the hook gate would reject these legitimate wake events.
Inferring the replacement phase from activity provenance or terminal kind would
also conflate observable state with process ownership. The explicit pending
token is the smallest durable state that distinguishes prepare from wake.

## Failure and recovery

- **Failure before prepare commits** — the row and running process are
  unchanged.
- **Failure after prepare while the old agent is still alive** — startup
  reconciliation proves the agent is live and clears the parked and pending
  fields. The retained current token continues to identify that process.
- **Failure after the pane becomes inert but before finalize** — the row remains
  parked with a pending token, so no old hook can mutate it. A later wake
  preparation replaces the pending token with a fresh current token before
  launching an agent.
- **Failure after finalize** — the row holds the token intended for the
  replacement shell, while the hook-silent inert process remains in the pane
  and the row stays parked. Wake follows the normal one-step reset.
- **Failure after wake preparation but before launch confirmation** — the row
  remains parked with the new current token and no pending token. A matching
  early hook is valid; a retry compares the full replacement snapshot and
  rotates the token again if it wins.
- **Startup finds a live replacement agent while parked** — reconciliation
  clears the parked and pending fields without replacing the current token, so
  any already accepted SessionStart or activity remains attached.

The existing hibernation startup reconciler owns these crash states. Existing
worktree and tmux reconciliation owns unmatched windows and panes. This design
creates no new external durable resource.

## Terminal-kind behavior

- **Claude** — SessionStart, activity, and SessionEnd hooks report the process
  token. SessionStart and activity validate it transactionally; deferred
  delegation marks, claims, and clears retain it through their actor hops.
  Activity keeps its existing last-writer and same-value behavior after
  identity acceptance.
- **Codex** — SessionStart and activity hooks use the same process fence before
  Codex-specific ordering, transcript boundary, and presentation reconciliation.
- **Shell** — replacement shells receive tokens so a later transition can
  compare process generations. Shell activity, where present, keeps legacy
  semantics after identity acceptance.

## Compatibility and observability

The pending database column has no SQL default. Existing rows migrate to
`NULL`, and older encoded `Terminal` values decode it as `nil`. The hook RPC
tokens remain optional, allowing mixed-version clients to decode while exact
optional equality prevents an old client from mutating a managed row.

Rejected hook events and session recaptures are idempotent no-ops. They do not
change session, activity, prompt, ordering, or scheduled-resume state and do
not broadcast a terminal activity transition. No new autonomous actuation,
timer, or feature flag is introduced; this fence hardens process replacements
TBD already performs.
