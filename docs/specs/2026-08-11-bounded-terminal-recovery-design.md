# Bounded terminal recovery — design

Status: **implemented**.

## Problem

TBD keeps a durable terminal record while presenting that terminal through a tmux
window. If the recorded window disappears, the app should recreate it and attach a new
viewer. That repair must be narrowly targeted: most failures while building a viewer
session do not prove that the underlying window is gone.

The previous preparation API collapsed every subprocess failure into one absent value.
The terminal coordinator interpreted that value as a dead window and requested daemon
recreation. Its attempt counter lived in the coordinator, but recreation changed the
tmux window ID and therefore the SwiftUI view identity. Each reconstructed coordinator
started with a fresh counter. Field diagnostics measured 121 recreation requests in 31
seconds from this loop.

The root cause was a destructive action based on ambiguous evidence, amplified by a
budget whose lifetime was shorter than the identity being protected. Recovery needs a
typed failure boundary, affirmative evidence of absence, and an attempt budget owned by
terminal UUID rather than a view instance.

## Goals

- Distinguish successful preparation, a confirmed missing tmux window, and every other
  preparation failure.
- Recreate automatically only when tmux positively reports that the requested window
  ID is absent from the reachable server.
- Allow at most two automatic attempts per terminal UUID until attachment is confirmed.
- Preserve the budget across tmux window replacement and SwiftUI coordinator
  reconstruction.
- Keep a user-triggered retry available after automatic attempts are exhausted.
- Prevent delayed recreation and snapshot responses from reviving a terminal after an
  authoritative deletion.
- Log stable preparation and recovery facts with both terminal and worktree UUIDs.

## Non-goals

- Do not change the app's `PATH` contract, executable resolution policy, or tmux search
  locations. Preparation continues to invoke `/usr/bin/env tmux`; the returned viewer
  command remains `tmux`, and the terminal panel resolves that command through the
  existing `findExecutable` path.
- Do not change terminal/tab convergence, the database schema, persisted models, tmux
  server ownership, or app-daemon RPC methods.
- Do not add a feature flag, background timer, arbitrary delay, or test-only production
  dependency.
- Do not infer terminal state from rendered screen text or human error phrases.

## Typed preparation outcomes

`TmuxBridge.prepareSession` returns
`Result<TmuxPreparedSession, TmuxPreparationFailure>`. A prepared session carries the
viewer executable name and arguments. A failure is one of:

- `windowMissing(failedStage:)` — affirmative evidence says the requested tmux window
  ID is absent.
- `commandFailed(stage:output:)` — preparation failed, but the underlying terminal is
  left unchanged.

The preparation stage is also typed: view-session creation, window linking, window
selection, exited-output preservation, exited-marker suppression, or selection
verification. This makes the coordinator's decision exhaustive and gives diagnostics a
stable category independent of subprocess prose.

Failure to create the isolated view session is always `commandFailed`, because no
window-specific operation has yet established anything about the requested window. A
failure after view-session creation runs a server-wide machine-readable inventory:

```text
tmux -L <server> list-windows -a -F '#{window_id}'
```

Classification follows the command result and exact window identities:

- A successful inventory containing the requested ID means the window exists. The
  original preparation failure remains `commandFailed`.
- A successful inventory omitting the requested ID is positive absence evidence and
  becomes `windowMissing`.
- A failed inventory is ambiguous and remains `commandFailed`.
- A successful targeted selection query with an unexpected ID is anomalous, not proof
  of absence. The server-wide inventory must still omit the expected ID before recovery
  is allowed.

Temporary view sessions are cleaned up best-effort after post-creation failures. Only
the typed `windowMissing` branch reaches automatic recreation. Generic command failure
shows stable guidance that the terminal was left unchanged and that the user can inspect
diagnostics or close the tab.

## Persistent bounded recovery

`AppState`, which is main-actor isolated and lives longer than terminal coordinators,
owns `TerminalRecoveryBudget`. The value stores counts by terminal UUID. Its named
maximum is two: an initial repair and one retry, enough to tolerate one failed repair
while bounding repeated autonomous mutation.

The budget is app-lifetime state, not database state. It deliberately survives tmux
window-ID changes and coordinator replacement without introducing a schema migration.
Automatic and manual claims have separate result types, so an automatic claim always
carries a concrete attempt number and a manual claim cannot accidentally enter the
automatic decision path.

An automatic request checks and acts in this order:

1. Coalesce an existing in-flight request without consuming another attempt.
2. Reject a terminal UUID that is no longer present locally.
3. Claim attempt one or two, or report exhaustion.
4. Mark the UUID in flight and dispatch the existing recreation RPC.
5. Adopt the returned snapshot only by replacing the same live terminal row.
6. Clear the in-flight marker on every completion path.

RPC failure and successful recreation both retain the consumed attempt. A recreation
response proves only that a new window was requested; it does not prove a viewer can use
that window. Late responses cannot append a row, and authoritative deletion tombstones
guard the replacement path against stale adoption.

## Attachment-positive reset

The budget resets only on a stronger production signal that the viewer is attached:

- In control mode, the live attach path directly reports viewer start.
- In grouped-session mode, `LocalProcess.startProcess` and `process.running` alone are
  insufficient. After PTY output arrives, the coordinator queries tmux with
  `list-clients -F '#{client_session}'` and requires the exact isolated view-session
  name returned by `TmuxBridge.sessionName(for:)`.

Grouped confirmation is scoped to the viewer process generation. A failed first query
receives one immediate retry so an idle attached client is not dependent on another
output chunk. Process termination or restart invalidates a late successful query. Error
bytes from a failed `tmux attach`, dispatch of the process start, and process existence
without a matching tmux client do not reset the budget.

Confirmed attachment resets only the named terminal's count. Authoritative terminal
deletion and explicit adoption of a genuinely new terminal UUID also clear stale
history. Merely receiving a recreation response or an unordered terminal snapshot does
not.

## Manual retry and user guidance

Automatic failure and exhaustion reveal an inline `Retry` affordance. That action calls
the manual recreation operation, which is independent of the automatic budget. It does
not consume a third automatic attempt and still requires confirmed viewer attachment
before the automatic budget resets.

The stable automatic guidance is:

- Failure — “Automatic terminal recovery failed. Retry manually or close the tab.”
- Exhaustion — “The terminal window is still unavailable after two automatic recovery
  attempts. Retry manually or close the tab.”

The affordance and text describe actions the user can actually take; a generic
preparation failure does not offer destructive recreation because absence is unproven.

## Deletion and unordered snapshots

Deletion signals and list snapshots carry different authority and must not share a
state transition.

Direct terminal deletion and a daemon `terminalRemoved` delta are authoritative. They
remove the terminal representation, reconcile its worktree's tabs, and record a
recent-deletion tombstone. Worktree archival is authoritative too, but removes the whole
worktree terminal bucket and records removal for each terminal rather than reconciling
those tabs. If recreation is already in flight, its RPC cannot be unsent, so the UUID
remains claimed until completion and budget cleanup is deferred. Delayed creation,
recreation, and refresh responses cannot resurrect the deleted row.

Terminal-list responses may complete out of order. A UUID omitted by one snapshot is
therefore observational only: absence creates no tombstone, changes no recovery count,
and changes no authoritative deletion state. A later snapshot can self-heal the local
row immediately. In particular, a stale empty snapshot cannot reopen an exhausted
automatic budget.

Recent-deletion tombstones are bounded data, not an app-lifetime set. Their TTL is
derived from the daemon client's receive deadline plus a fixed 30-second scheduling and
settlement margin. With the current 300-second receive deadline, the TTL is 330 seconds.
The margin covers timeout or response completion followed by main-actor callback
ordering, without retaining every deleted UUID for the lifetime of the app. Tombstones
use a date seam and are pruned on state access or mutation, so no timer or sleep is
required.

## Diagnostics

Preparation and recovery logs include:

- Terminal UUID and worktree UUID.
- Typed preparation stage and failure category.
- Automatic attempt number or exhaustion.
- Confirmed attachment and budget reset.

The coordinator captures the diagnostic context before awaiting automatic recovery, so
a concurrent removal cannot degrade the worktree identity in the completion log.
Subprocess output is debug-level and explicitly private. Logs do not include the full
`PATH`, rendered terminal contents, agent input, or secrets.

## Rejected alternatives

- **Treat any failed preparation or probe as a missing window** — transient server,
  process, and configuration failures are ambiguous and cannot justify recreation.
- **Parse tmux error prose or terminal output** — rendered and human-facing text is not
  a stable machine interface. Exit status and formatted identity inventories are.
- **Keep retries in the coordinator** — coordinator identity changes during the repair,
  which reopens an unbounded loop.
- **Reset on recreation dispatch, process spawn, or first output** — each can occur when
  attachment ultimately fails. The matching live tmux client is the stronger signal.
- **Treat snapshot omission as deletion** — concurrent list responses are unordered and
  would suppress healthy terminals or reopen consumed attempts.
- **Retain permanent deletion tombstones** — an app-lifetime set grows without bound.
  A transport-deadline-derived TTL covers stale responses with bounded memory.
- **Persist attempts or add timers** — app-lifetime ownership is sufficient to survive
  view reconstruction, and access-time date pruning avoids a new behavioral clock.
- **Change executable resolution in this fix** — recovery classification must remain
  independent of the existing launch and `PATH` policy.

## Verification and rollout

Focused tests cover every classification branch, command construction, independent
UUID budgets, automatic/manual claim types, in-flight coalescing, failure and exhaustion
guidance, grouped and control-mode attachment resets, process-generation invalidation,
authoritative deletion races, tombstone expiry, and unordered snapshot self-healing.

Release verification requires:

- `scripts/test.sh` for the focused suites and the full repository suite.
- `scripts/swift-safe build`.
- `swiftlint --strict` when SwiftLint is available.
- `git diff --check` and a scope audit confirming no PATH policy, migration, flag,
  timer, screen scraper, or new RPC was introduced.

Manual recovery verification should observe typed logs and tmux machine commands rather
than pane contents: remove a known window, confirm at most two automatic recreations,
confirm manual retry remains available, then establish a real viewer attachment and
verify the next missing-window event starts at attempt one.

The change requires no data migration or compatibility shim and does not alter the
app-daemon wire contract. Rollout therefore follows the ordinary app release path. A
revert restores the prior app-only preparation and recovery behavior without changing
persisted terminal records.
