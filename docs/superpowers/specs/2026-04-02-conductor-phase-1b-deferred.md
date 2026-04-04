# Conductor Phase 1b: Event-Driven Routing (Deferred)

Extracted from the [Conductor Pattern Design](2026-04-02-conductor-pattern-design.md). This is a potential future enhancement, not a planned phase.

## Why Deferred

- **Event-driven notifications burn tokens.** The conductor is a Claude session — every `[TERMINAL WAITING]` notification costs ~3-5k tokens to process (message parsing, state.json read, decision logic, response or escalation). With 5+ active terminals, this adds up fast.
- **Heartbeats cost tokens even when nothing changed.** Each heartbeat cycle costs ~1-2k tokens for the conductor to read and respond to, regardless of whether any terminal state actually changed.
- **Agent Deck's conductor works without event-driven push.** It uses timer-based polling (launchd heartbeat) and that's sufficient. The polling model is proven in production.
- **Phase 1a with manual polling + `terminal.conversation` delivers the core value.** The conductor can read agent output, auto-respond to waiting terminals, and escalate — all without the daemon pushing notifications.
- **Phase 1b is not required for Phase 2 (app UI).** The sidebar only needs the conductor DB, lifecycle, and terminal state from Phase 1a. Event-driven routing is orthogonal to the UI layer.
- **Can revisit if a lightweight heartbeat proves worthwhile.** A launchd timer that only fires when terminals are in `waiting` state would avoid the always-on token cost. This is worth exploring if manual polling feels too slow in practice.

## What This Would Add

### TerminalStateTracker

Extracted from `SuspendResumeCoordinator`. Owns all terminal state detection logic, independent of what consumers do with the information.

**Inputs:**
- `response_complete` notifications (already broadcast as StateDelta from the notify RPC)
- `ClaudeStateDetector.isIdle()` polling (tmux capture-pane heuristic)
- Terminal process status (is Claude process running in the pane?)

**State model per terminal:**

| State | Meaning | Detection |
|-------|---------|-----------|
| `running` | Claude is actively processing | `ClaudeStateDetector.busyIndicators` present in pane |
| `waiting` | Claude finished, needs input | `response_complete` hook fired AND `isIdle()` confirms prompt visible |
| `idle` | Shell prompt, no Claude running | `paneCurrentCommand` is not a Claude process |
| `unknown` | Can't determine | tmux capture-pane failed, window dead, or detection error |

The `unknown` state is produced when `capturePaneOutput` or `paneCurrentCommand` throws. `ClaudeStateDetector.isIdle()` currently swallows errors and returns `false` (appearing as `running`). The tracker must distinguish "confirmed busy" from "can't tell" by catching errors explicitly.

**API:**
```swift
public actor TerminalStateTracker {
    /// Current state of a terminal
    func state(terminalID: UUID) async -> TerminalState
    
    /// All terminals in a given state
    func terminals(in state: TerminalState) async -> [TerminalStateEntry]
    
    /// Called when response_complete notification arrives
    func responseCompleted(terminalID: UUID, worktreeID: UUID)
    
    /// Clear idle tracking for a worktree (called by SuspendResumeCoordinator
    /// on suspend/resume to prevent immediate re-eligibility)
    func clearIdleFlag(worktreeID: UUID)
    
    /// Subscribe to state transitions
    func onTransition(_ handler: @Sendable (TerminalStateTransition) -> Void)
}

public struct TerminalStateEntry: Sendable {
    let terminalID: UUID
    let worktreeID: UUID
    let repoID: UUID
    let state: TerminalState
    let since: Date              // when it entered this state
    let terminalLabel: String?   // e.g. "claude", "setup"
    let lastAssistantMessage: String?  // last assistant message from Claude session JSONL
}

public struct TerminalStateTransition: Sendable {
    let terminalID: UUID
    let worktreeID: UUID
    let repoID: UUID
    let worktreeName: String
    let branchName: String
    let terminalLabel: String?
    let from: TerminalState
    let to: TerminalState
    let timestamp: Date
}
```

**Polling cadence:** Running terminals are polled more frequently than idle ones (e.g., ~10s vs ~60s). Exact intervals are implementation details — the invariant is that the tracker detects running->waiting transitions within a reasonable window. Event-driven via `response_complete` hook provides near-instant detection for the common case; polling is the safety net.

**Relationship to SuspendResumeCoordinator:** The coordinator becomes a consumer of `TerminalStateTracker` instead of managing its own `worktreeIdleFromHook` set. It subscribes to transitions and triggers suspend/resume logic when appropriate. The coordinator-specific 30-second re-eligibility delay after resume stays in the coordinator, not the tracker. The tracker exposes `clearIdleFlag(worktreeID:)` so the coordinator can reset idle tracking on suspend/resume (preserving the existing `worktreeIdleFromHook.remove()` semantics at SuspendResumeCoordinator.swift lines 158, 300).

### ConductorRouter

Routes terminal state transitions to the appropriate conductor(s) based on scope configuration.

**Responsibilities:**
- Loads conductor configs from the `conductor` DB table
- On each `TerminalStateTransition`, determines which conductors should be notified
- Manages interaction locks (one conductor at a time per worktree)
- Formats and delivers messages to conductor terminals
- Detects conductor terminal death and releases interaction locks

**Routing rules:**
1. When a terminal transitions to `waiting`: notify all conductors whose scope includes that terminal's repo (filtered by worktree and terminal_label if configured)
2. When a conductor wants to send a message to a terminal: the `terminal.send` RPC handler verifies the target terminal is currently in `waiting` state before dispatching `sendKeys`. This is a server-side invariant — if the terminal transitioned to `running` between the conductor's decision and the send, the RPC returns an error.

### Server-Side Send Guard

The `terminal.send` RPC handler (RPCRouter+TerminalHandlers.swift) gains a state check:

```
terminal.send received (from conductor)
  -> Look up terminal in TerminalStateTracker
  -> If state != .waiting: return error "terminal is not waiting for input (current state: running)"
  -> If interaction lock held by another conductor: return error "locked by conductor X"
  -> Acquire interaction lock, send keys, return success
```

No permission check — any conductor can interact. The guard enforces two invariants: the terminal must be waiting, and no other conductor can be mid-interaction with the same worktree. This prevents the stale-notification race: even if a conductor acts on an outdated `[TERMINAL WAITING]` notification, the send is rejected server-side if the terminal has already transitioned.

### Heartbeat Delivery

The daemon runs a single heartbeat timer in `Daemon.swift` (alongside existing periodic timers). The timer fires at the minimum interval across all active conductors and tracks per-conductor cadence — each conductor receives heartbeats at its own configured interval.

```
[HEARTBEAT] 5 terminals across 2 repos.
  waiting (3m): fix-auth @ my-app [claude] — "Should I also update the test fixtures?" (from session JSONL)
  waiting (12m): add-export @ my-app [claude] — "Which CSV library should I use?" (from session JSONL)
  running: refactor-db @ api-server [claude]
  running: add-metrics @ api-server [claude]
  idle (1h): setup-ci @ my-app [setup]
```

### Full CLAUDE.md Template

Replaces the Phase 1a template. Adds sections for `[TERMINAL WAITING]`, `[HEARTBEAT]`, `tbd terminal state`, structured response formats, and quick commands. Key additions over Phase 1a:

```markdown
## How You Receive Information

The TBD daemon sends you two types of messages automatically:

1. **[TERMINAL WAITING]** — Real-time notification when a terminal needs input.
   Includes terminal ID, repo, worktree, branch, duration, and last assistant message from session JSONL.
   Decide: auto-respond or escalate.

2. **[HEARTBEAT]** — Periodic summary of all terminal states.
   Review for stuck agents, long waits, or patterns needing attention.
   Reply with a [STATUS] report (see Response Formats below).

## Additional CLI Commands (Phase 1b)

| Command | Description |
|---------|-------------|
| `tbd terminal state --json` | List all terminal states with running/waiting/idle/unknown |

## Response Formats

### Heartbeat Response
[STATUS] All clear.

or:

[STATUS] Auto-responded to 1 terminal. 1 needs your attention.

AUTO: fix-auth — told it to proceed with updating test fixtures
NEED: add-export — asking about CSV library preference

### Quick Commands

Self-invokable procedures for common tasks:

| Command | What to Do |
|---------|------------|
| "check status" | Run `tbd terminal state --json`, summarize |
| "check <worktree>" | Find terminal, run `tbd terminal conversation <id>`, summarize |
| "list sessions" | Run `tbd terminal state --json`, format as table |

## Unknown/Error States

If a terminal shows `unknown` state for more than 2 consecutive heartbeats,
escalate to the user. The terminal may be dead or its tmux window may need
recreation.

## Idle Terminals

Terminals in `idle` state have no Claude process running (just a shell prompt).
Do not send messages to idle terminals. Note them in status reports but take
no action unless the user asks.
```

### Additional RPC Methods

| Method | Params | Result | Description |
|--------|--------|--------|-------------|
| `terminal.state` | terminalID | TerminalStateEntry | Get current terminal state |
| `terminal.states` | repoID? | TerminalStateEntry[] | Get all terminal states, optionally filtered by repo |

### Additional CLI Commands

```bash
tbd terminal state [--repo <id>] [--json]     # list terminal states
```

## Data Flows

### Terminal transitions to "waiting" (event-driven)

```
Claude finishes response
  -> PostToolUse hook fires `tbd notify --type response_complete`
  -> Daemon receives notification via RPC
  -> TerminalStateTracker.responseCompleted() called
  -> ClaudeStateDetector.isIdle() confirms (debounced)
  -> TerminalStateTracker emits transition(running -> waiting)
  -> ConductorRouter receives transition
  -> Router checks scope: which conductors cover this repo/worktree/label?
  -> Router formats [TERMINAL WAITING] message with context
  -> Router sends to each scoped conductor via TmuxManager.sendKeys()
  -> SuspendResumeCoordinator also receives transition (if enabled)
```

### Heartbeat

```
Daemon heartbeat timer fires (every N minutes, in Daemon.swift)
  -> TerminalStateTracker.terminals(in:) queried for all states
  -> Filtered by conductor scope (repos, worktrees, terminal labels)
  -> Formatted as [HEARTBEAT] message
  -> Sent to conductor terminal
```

## Testing (Phase 1b-specific)

- **TerminalStateTracker tests:** Mock TmuxManager in dryRun mode + mockable `ClaudeStateDetector` interface. Verify state transitions fire correctly, test response_complete -> waiting transition, test capture-pane failure -> unknown state, test clearIdleFlag semantics
- **ConductorRouter tests:** Verify scope filtering (repo match, wildcard, worktree patterns, terminal labels), verify interaction lock acquire/release/expiry, verify lock conflict between two conductors, verify message formatting, verify conductor death releases locks
- **Server-side send guard tests:** Verify terminal.send rejects when terminal is running, verify it succeeds when waiting, verify lock conflict returns error
- **SuspendResumeCoordinator regression tests:** Existing tests still pass after TerminalStateTracker extraction

## Migration Notes

- **SuspendResumeCoordinator refactor:** Extract idle detection into `TerminalStateTracker`. Coordinator subscribes to tracker transitions. `clearIdleFlag()` replaces direct `worktreeIdleFromHook.remove()` calls. The coordinator-specific 30-second re-eligibility delay after resume stays in the coordinator (not the tracker). Public API unchanged.
