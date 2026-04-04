# Conductor Pattern Design

A meta-agent orchestration layer for TBD. Conductors are persistent Claude Code sessions that monitor and coordinate other Claude terminals across worktrees and repos.

## Problem

When running multiple Claude agents across worktrees, agents frequently block waiting for human input — "Should I proceed?", "Which approach?", "Tests passed, what next?". The user must manually check each terminal, context-switch, and respond. With 5+ active worktrees across multiple repos, this becomes a bottleneck.

## Solution

A **conductor** is a Claude Code session with special instructions that:
1. Receives real-time notifications when any terminal in its scope transitions to "waiting"
2. Reads the agent's last conversation message (via Claude session JSONL) to understand what the agent needs
3. Auto-responds when confident (routine questions, obvious next steps)
4. Escalates to the user when unsure (design decisions, destructive actions, ambiguity)

The TBD daemon serves as the API/medium — the conductor is a consumer of existing daemon capabilities, augmented with a few new ones.

## Design Principles

- **Daemon as API, conductor as consumer.** The conductor uses `tbd` CLI commands. No special privileges.
- **Event-driven with heartbeat fallback.** Real-time notifications on state transitions, periodic summaries as a safety net.
- **Interaction locks as safety mechanism.** Any conductor can respond to waiting terminals. The daemon enforces one-at-a-time interaction per worktree via advisory locks — no permission tiers needed.
- **Decouple detection from action.** Terminal state tracking is independent of both suspend/resume and conductor systems.
- **Flexible scoping.** Conductors choose their repos, worktrees, and terminal labels. Multiple conductors can observe the same worktree. Only one can interact with a given worktree at a time (enforced by interaction locks).
- **Server-side safety.** The daemon enforces invariants (don't send to non-waiting terminals) rather than trusting the conductor's view of state.

## Architecture

### Component Overview

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│  Conductor  │────▶│      tbdd        │◀────│  tbd CLI    │
│  (Claude)   │ RPC │                  │ RPC │             │
└─────────────┘     │  TerminalState   │     └─────────────┘
                    │  Tracker         │
┌─────────────┐     │       │          │     ┌─────────────┐
│  Conductor  │────▶│       ▼          │◀────│  TBDApp     │
│  (Claude)   │ RPC │  ConductorRouter │ RPC │  SwiftUI    │
└─────────────┘     │       │          │     └─────────────┘
                    │       ▼          │
                    │  Notification    │
                    │  Delivery        │
                    └──────────────────┘
```

### New Components

#### 1. TerminalStateTracker (Deferred — Phase 1b)

Extracted from `SuspendResumeCoordinator`. Owns all terminal state detection logic, independent of what consumers do with the information. See `2026-04-02-conductor-phase-1b-deferred.md` for full details. Retained here for architectural context.

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

**Polling cadence:** Running terminals are polled more frequently than idle ones (e.g., ~10s vs ~60s). Exact intervals are implementation details — the invariant is that the tracker detects running→waiting transitions within a reasonable window. Event-driven via `response_complete` hook provides near-instant detection for the common case; polling is the safety net.

**Relationship to SuspendResumeCoordinator:** The coordinator becomes a consumer of `TerminalStateTracker` instead of managing its own `worktreeIdleFromHook` set. It subscribes to transitions and triggers suspend/resume logic when appropriate. The coordinator-specific 30-second re-eligibility delay after resume stays in the coordinator, not the tracker. The tracker exposes `clearIdleFlag(worktreeID:)` so the coordinator can reset idle tracking on suspend/resume (preserving the existing `worktreeIdleFromHook.remove()` semantics at SuspendResumeCoordinator.swift lines 158, 300).

#### 2. Conversation Reader

Reads Claude's structured conversation history for a terminal, providing the conductor with reliable access to what agents said — independent of terminal viewport size.

**How it works:** Each Claude terminal stores a `claudeSessionID` (already captured by `ClaudeStateDetector.captureSessionID()`). Claude writes conversation history to `~/.claude/projects/<project-path>/sessions/<session-id>.jsonl`. The daemon reads this file to extract the last N assistant messages.

**Why not capture-pane:** tmux capture-pane only returns the visible viewport (~24-50 lines). Claude responses routinely exceed one screenful. The JSONL contains the complete, structured conversation.

**API:**
- `terminal.conversation` RPC — returns last N assistant messages for a terminal's Claude session
- Used by ConductorRouter when formatting [TERMINAL WAITING] notifications
- Used by conductor CLI for manual polling
- `terminal.output` remains available as a debug tool for raw terminal state

#### 3. ConductorRouter (Deferred — Phase 1b)

Routes terminal state transitions to the appropriate conductor(s) based on scope configuration. See `2026-04-02-conductor-phase-1b-deferred.md` for full details. Retained here for architectural context.

**Responsibilities:**
- Loads conductor configs from the `conductor` DB table
- On each `TerminalStateTransition`, determines which conductors should be notified
- Manages interaction locks (one conductor at a time per worktree)
- Formats and delivers messages to conductor terminals
- Detects conductor terminal death and releases interaction locks

**Routing rules:**
1. When a terminal transitions to `waiting`: notify all conductors whose scope includes that terminal's repo (filtered by worktree and terminal_label if configured)
2. When a conductor wants to send a message to a terminal: the `terminal.send` RPC handler verifies the target terminal is currently in `waiting` state before dispatching `sendKeys`. This is a server-side invariant — if the terminal transitioned to `running` between the conductor's decision and the send, the RPC returns an error.

#### 4. Conductor Storage

**Database table (new `conductor` table):** Queryable metadata lives in SQLite for consistency with the rest of TBD's data model.

```sql
CREATE TABLE conductor (
    id TEXT PRIMARY KEY,           -- UUID
    name TEXT UNIQUE NOT NULL,     -- human-readable name
    repos TEXT NOT NULL DEFAULT '*', -- JSON array of repo IDs or ["*"]
    worktrees TEXT,                -- JSON array of worktree name patterns, null = all
    terminalLabels TEXT,           -- JSON array of terminal labels to monitor, null = all
    heartbeatIntervalMinutes INTEGER NOT NULL DEFAULT 10,
    terminalID TEXT,               -- FK to terminal table (the conductor's own terminal)
    createdAt TEXT NOT NULL,
    FOREIGN KEY (terminalID) REFERENCES terminal(id) ON DELETE SET NULL
);
```

**Filesystem (for Claude's CWD):** The conductor's CLAUDE.md, state.json, and task-log.md live at `~/.tbd/conductors/<name>/`. This directory is the conductor's CWD so Claude reads CLAUDE.md on startup.

```
~/.tbd/conductors/
├── my-conductor/
│   ├── CLAUDE.md            # Instructions for the conductor Claude session
│   ├── state.json           # Conductor's persistent state (managed by Claude)
│   └── task-log.md          # Action log (managed by Claude)
└── ops-conductor/
    ├── CLAUDE.md
    ├── state.json
    └── task-log.md
```

**Scope fields:**
- `repos`: `["*"]` for all repos, or specific repo IDs
- `worktrees`: `null` for all worktrees, or name patterns like `["fix-*", "feature-*"]`
- `terminalLabels`: `null` for all terminals, or specific labels like `["claude"]` (excludes "setup" terminals)

#### 5. Conductor Terminal Model

The conductor needs a terminal record in the DB (for tmux window tracking, state detection, etc.). Rather than making `worktreeID` nullable (which would require a migration + audit of every query), the conductor gets a **synthetic worktree** record:

```
Worktree {
    id: UUID,
    repoID: <conductors-pseudo-repo-id>,  // synthetic repo inserted by migration
    name: "conductor-<name>",
    path: "~/.tbd/conductors/<name>",
    branch: "conductor",                  // sentinel value (column is NOT NULL)
    status: .conductor,                   // new WorktreeStatus case
    ...
}
```

**Synthetic "conductors" repo:** The DB migration inserts a pseudo-repo with a well-known UUID and path `~/.tbd/conductors`. All conductor worktrees reference this repo. This avoids FK cascade issues — if a real repo is removed, conductor worktrees are unaffected. The pseudo-repo is filtered from `repo.list` results (by checking a `synthetic` bool column or the well-known UUID).

**WorktreeStatus.conductor and StateDelta:** Adding `.conductor` to the `WorktreeStatus` enum must ship in `TBDShared` (used by both daemon and app). The `StateSubscriptionManager` must suppress `worktreeCreated`/`worktreeArchived` deltas for `.conductor`-status worktrees to prevent the app from displaying or failing to decode them before UI support exists.

This new `.conductor` status is filtered out of normal worktree listings (sidebar, `tbd worktree list`) but visible via `tbd conductor list`. The terminal record uses this synthetic worktreeID normally — no NULL handling needed.

The conductor runs in a dedicated tmux server named `tbd-conductor` (shared by all conductors, separate from any repo's server). Each conductor gets its own tmux window in this server. **Known limitation:** one conductor crashing tmux takes down all conductors. Acceptable for Phase 1; per-conductor servers can be added in Phase 2 if users run 3+ conductors.

#### 6. Interaction Locking

Any conductor can send messages to waiting terminals. When a conductor sends a message (via `terminal.send`), the daemon records an **advisory interaction lock** on that worktree. The lock:
- Is recorded in memory (not DB — it's transient)
- Auto-expires after 5 minutes
- Prevents other conductors from sending to the same worktree simultaneously
- Does NOT prevent the user from interacting directly (user always wins)
- Is released when the terminal transitions back to `running` (the agent started processing)
- Is released immediately if the conductor's terminal dies (daemon detects pane gone / process exited via TerminalStateTracker's periodic polling)

```swift
public struct InteractionLock: Sendable {
    let worktreeID: UUID
    let conductorName: String
    let acquiredAt: Date
    let expiresAt: Date
}
```

#### 7. Server-Side Send Guard (Deferred — Phase 1b)

The `terminal.send` RPC handler (RPCRouter+TerminalHandlers.swift) gains a state check. See `2026-04-02-conductor-phase-1b-deferred.md` for full details. Retained here for architectural context.

```
terminal.send received (from conductor)
  → Look up terminal in TerminalStateTracker
  → If state != .waiting: return error "terminal is not waiting for input (current state: running)"
  → If interaction lock held by another conductor: return error "locked by conductor X"
  → Acquire interaction lock, send keys, return success
```

No permission check — any conductor can interact. The guard enforces two invariants: the terminal must be waiting, and no other conductor can be mid-interaction with the same worktree. This prevents the stale-notification race: even if a conductor acts on an outdated `[TERMINAL WAITING]` notification, the send is rejected server-side if the terminal has already transitioned.

### Conductor Lifecycle

#### Setup

```bash
tbd conductor setup my-conductor                                    # defaults: all repos
tbd conductor setup my-conductor --repos repo-id-1,repo-id-2       # specific repos
tbd conductor setup my-conductor --worktrees "fix-*,feature-*"     # worktree name patterns
tbd conductor setup my-conductor --terminal-labels claude           # only monitor claude terminals
tbd conductor setup my-conductor --heartbeat 5                      # 5-minute heartbeat interval
```

Creates the directory structure, generates a default `CLAUDE.md` from a template, inserts a row in the `conductor` table, and creates a synthetic worktree record.

#### Start

```bash
tbd conductor start my-conductor
```

Creates a tmux window in `tbd-conductor` server running `claude --dangerously-skip-permissions` with the conductor's directory as CWD. Registers a terminal in the DB linked to the synthetic worktree.

#### Stop / Teardown

```bash
tbd conductor stop my-conductor     # kills tmux window, keeps config + DB row
tbd conductor teardown my-conductor # stop + remove DB row + remove directory
```

#### List

```bash
tbd conductor list                  # all conductors with status
tbd conductor list --json           # machine-readable
```

### Message Delivery to Conductor

When a terminal transitions to `waiting`, the `ConductorRouter` formats a notification:

```
[TERMINAL WAITING] id: <terminal-uuid>
repo: my-app | worktree: fix-auth (tbd/fix-auth) | terminal: claude
Waiting for 0s. Running for 4m since last input.
Last message:
---
I've updated the authentication middleware to use JWT tokens instead of session cookies.
Should I also update the test fixtures to use the new token format?
---
```

Includes terminal UUID (so conductor can immediately `tbd terminal send <id>`), branch name, terminal label, time waiting, and time running since last input. Last assistant message from the Claude session JSONL.

This is sent to the conductor terminal via `TmuxManager.sendKeys()` (same mechanism as `tbd terminal send`).

### Escalation

When the conductor decides to escalate (rather than auto-respond), it uses a structured format and fires a notification:

```bash
tbd notify --type attention_needed "fix-auth waiting 12m: asking whether to run integration tests against staging or prod"
```

This creates a macOS notification visible to the user. The conductor's CLAUDE.md defines a structured `[ESCALATION]` output format:

```
[ESCALATION] fix-auth @ my-app
Agent is asking: "Should I run integration tests against staging or prod?"
Context: Working on JWT migration, tests need a live database.
```

Phase 2: A bridge (Telegram/Slack) can parse `[ESCALATION]` lines from conductor output and forward them. The daemon-side notification hook exists in Phase 1, giving the bridge something to consume.

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

The conductor replies with a structured format:

```
[STATUS] Auto-responded to 1 terminal. 1 needs your attention.

AUTO: fix-auth — told it to proceed with updating test fixtures
NEED: add-export — asking about CSV library preference, escalating
```

The daemon builds the heartbeat from `TerminalStateTracker` data — no CLI round-trips needed.

### RPC Methods

New methods added to the daemon:

| Method | Params | Result | Description |
|--------|--------|--------|-------------|
| `conductor.setup` | name, repos?, worktrees?, terminalLabels?, heartbeat? | Conductor | Create conductor config + directory + DB row |
| `conductor.start` | name | Terminal | Start conductor session |
| `conductor.stop` | name | void | Stop conductor session |
| `conductor.teardown` | name | void | Stop + remove conductor |
| `conductor.list` | (none) | Conductor[] | List all conductors with status |
| `conductor.status` | name | ConductorStatus | Detailed status of one conductor |
| `terminal.state` | terminalID | TerminalStateEntry | Get current terminal state *(deferred — Phase 1b)* |
| `terminal.states` | repoID? | TerminalStateEntry[] | Get all terminal states, optionally filtered by repo *(deferred — Phase 1b)* |
| `terminal.conversation` | terminalID, messages? | string[] | Last N assistant messages from Claude session JSONL (default 1) |
| `terminal.output` | terminalID, lines? | string | Debug: capture visible terminal viewport (default 50 lines) |

### CLI Commands

```bash
# Conductor management
tbd conductor setup <name> [--repos id,...] [--worktrees pattern,...] [--terminal-labels label,...] [--heartbeat N]
tbd conductor start <name>
tbd conductor stop <name>
tbd conductor teardown <name>
tbd conductor list [--json]
tbd conductor status <name> [--json]

# Terminal state (useful for conductors and debugging)
tbd terminal state [--repo <id>] [--json]     # list terminal states (deferred — Phase 1b)
tbd terminal conversation <id> [--messages N]  # last N assistant messages from session JSONL
tbd terminal output <id> [--lines N]           # debug: capture raw terminal viewport
```

### Conductor CLAUDE.md Template

#### Phase 1a Template (Manual Polling)

```markdown
# Conductor: {NAME}

You are a conductor — a persistent Claude Code session that monitors and
orchestrates other Claude terminals managed by TBD.

## Your Scope
- Repos: {REPO_LIST}
- Worktrees: {WORKTREE_PATTERNS}
- Terminal labels: {TERMINAL_LABELS}

## Startup Checklist

Run this when you first start, after a restart, or after context compaction:
1. Read `./state.json` if it exists (restore context from previous session)
2. Run `tbd worktree list --json` to see active worktrees
3. Run `tbd terminal list --json` to discover terminal IDs
4. Run `tbd conductor status {NAME} --json` to verify your scope
5. Log startup in `./task-log.md`
6. Output: "Conductor {NAME} online. N terminals found across M worktrees."

This output is a self-log confirmation, not a message to anyone.

## How You Work (Manual Polling)

In this version, you do NOT receive automatic notifications. You must actively
poll terminals to check on them. When asked to check status, or periodically:

1. Run `tbd terminal list --json` to get terminal IDs
2. For each terminal of interest, run `tbd terminal conversation <id>` to read the last assistant message
3. Review the message — is the agent waiting for input?
4. If waiting: decide to auto-respond or escalate
5. If running: leave it alone

## Core Rules

1. **Never send to running terminals.** Only respond to terminals that are
   waiting for input (you can tell from the terminal output — look for the ❯ prompt).
2. **When unsure, escalate.** The cost of a false escalation (user gets a notification)
   is much lower than a wrong auto-response (agent goes off track).
3. **Log everything.** Every action goes in `./task-log.md`.
4. **Keep responses SHORT.** Status updates: 1-3 sentences. Use bullet points for lists.
5. **Don't poll in a loop.** Check when asked or when relevant. If no terminals are
   active, say so and wait.

## CLI Commands

| Command | Description |
|---------|-------------|
| `tbd worktree list --json` | List all worktrees with IDs |
| `tbd terminal list --json` | List all terminals with IDs and worktree mapping |
| `tbd terminal conversation <id>` | Read last assistant message from Claude session |
| `tbd terminal conversation <id> --messages N` | Read last N assistant messages |
| `tbd terminal output <id> --lines 50` | Debug: raw terminal viewport (last 50 lines) |
| `tbd terminal send <id> "message"` | Send message to a terminal |
| `tbd conductor list --json` | List all conductors |
| `tbd conductor status {NAME} --json` | Your own scope and config |
| `tbd notify --type attention_needed "message"` | Escalate to user via macOS notification |

Terminal IDs are UUIDs. Use the full ID from `tbd terminal list` output.

## Terminal States

When reading terminal output, look for these indicators:
- **Waiting for input:** ❯ prompt visible, status bar shows "⏵⏵" or "? for shortcuts"
- **Running/busy:** Status bar shows "esc to interrupt" or "to stop agents"
- **Idle (no Claude):** Shell prompt (zsh/bash), no Claude process
- **Unknown:** Can't determine — terminal may be dead or restarting. Escalate if persistent.

## Auto-Response Guidelines

### Safe to Auto-Respond
- "Should I proceed?" / "Should I continue?" → Yes, if the plan looks reasonable
- "Tests passed. What's next?" → Direct to the next logical step
- Compilation/lint errors with obvious fixes → Suggest the fix
- Questions about project conventions → Answer from context

### Always Escalate
- Destructive actions (delete, force-push, drop table)
- Security issues
- Design decisions with multiple valid approaches
- Requests for credentials or API keys
- "I'm stuck and don't know how to proceed"
- Anything you're unsure about

## Handling Send Rejections

If `tbd terminal send` returns an error (e.g., "terminal is not waiting for input"),
the terminal transitioned since you last checked. Do NOT retry immediately. Re-read
the terminal output to see its current state, then decide what to do.

### Escalation
When escalating, notify the user:
```bash
tbd notify --type attention_needed "worktree-name: brief description of what needs attention"
```

## State Management

Maintain `./state.json` for context across context compactions:
```json
{
  "terminals": {
    "terminal-uuid": {
      "worktree": "fix-auth",
      "repo": "my-app",
      "summary": "Migrating auth from sessions to JWT tokens",
      "last_auto_response": "2026-04-02T10:30:00Z",
      "escalated": false
    }
  },
  "last_checked": "2026-04-02T10:30:00Z",
  "auto_responses_today": 5,
  "escalations_today": 2
}
```

Read state.json at the start of each interaction. Update it after taking action.
Keep terminal summaries current based on what you observe in their conversation messages.

## Task Log

Append every action to `./task-log.md`:
```markdown
## 2026-04-02 10:30 - Status Check
- Scanned 5 terminals (2 waiting, 3 running)
- Auto-responded to fix-auth: "Proceed with updating test fixtures"
- Escalated add-export: needs decision on CSV library

## 2026-04-02 10:15 - Terminal Check
- fix-auth asking: "Should I update test fixtures?"
- Auto-responded: "Yes, update the test fixtures to use JWT tokens"
```
```

### App UI (Phase 2, not in this spec)

Future work: conductor section in sidebar, status indicators showing which worktrees are conductor-managed, scope editor in settings. Not designed here — this spec covers the daemon + CLI + CLAUDE.md layer only.

**UI model note:** The conductor is envisioned as a repo-level feature in the sidebar — users start and configure conductors from the repo section, not primarily via CLI. The CLI exists as the backend the app calls. Phase 1 builds the CLI/daemon layer; Phase 2 wraps it in the app UI.

## Data Flow

### Conductor checks terminals (Phase 1a — manual polling)

```
Conductor (Claude) decides to check on terminals
  → Runs: tbd terminal list --json (gets terminal IDs)
  → Runs: tbd terminal conversation <id> (reads last assistant message from session JSONL)
  → Reviews the message — is the agent waiting for input?
  → If waiting: decides to auto-respond or escalate
  → If running: leaves it alone
```

### Conductor auto-responds (Phase 1a)

```
Conductor (Claude) reads terminal conversation, decides to auto-respond
  → Runs: tbd terminal send <terminal-id> "Yes, proceed with updating the tests"
  → Daemon receives terminal.send RPC
  → Message sent to terminal via TmuxManager.sendKeys()
  → Terminal's Claude processes the message (transitions to running)
```

### Conductor escalates (Phase 1a)

```
Conductor (Claude) reads terminal conversation, decides to escalate
  → Runs: tbd notify --type attention_needed "fix-auth: asking whether to delete the old migration files"
  → User receives macOS notification
  → Logs escalation in task-log.md and updates state.json
```

### Event-driven data flows (Deferred — Phase 1b)

See `2026-04-02-conductor-phase-1b-deferred.md` for the event-driven flows: automatic `[TERMINAL WAITING]` notifications, server-side send guard with interaction locks, and daemon-driven heartbeats.

## Phasing

### Phase 1a: Minimal Viable Conductor

The smallest slice that delivers value — a conductor can run and manually poll terminals.

1. **terminal.conversation RPC** — Read last N assistant messages from Claude session JSONL via the terminal's `claudeSessionID`. Primary content-reading mechanism for conductors. **terminal.output RPC** remains as a debug tool (raw terminal viewport via tmux capture-pane).
2. **Conductor DB table + synthetic repo + config directory** — `conductor.setup` / `conductor.teardown` / `conductor.list`. DB migration adds `conductor` table + synthetic "conductors" pseudo-repo + `.conductor` WorktreeStatus. StateDelta suppression for conductor worktrees.
3. **Conductor lifecycle** — `conductor.start` / `conductor.stop` (synthetic worktree, tmux window in `tbd-conductor` server, terminal record)
4. **Phase 1a CLAUDE.md template** — Uses only pre-existing + Phase 1a commands. Startup checklist uses `tbd worktree list --json` + `tbd terminal list --json` (both exist today). Does NOT reference `[TERMINAL WAITING]` or `[HEARTBEAT]` messages (those are deferred — see `2026-04-02-conductor-phase-1b-deferred.md`). Includes manual polling workflow using `tbd terminal conversation`.
5. **CLI commands** — `tbd conductor setup/start/stop/teardown/list/status`, `tbd terminal conversation`, `tbd terminal output` (debug)

At this point, the conductor can run and manually check on terminals via `tbd worktree list`, `tbd terminal list`, and `tbd terminal conversation <id>` (reading session JSONL). `tbd terminal output <id>` is available as a debug tool for raw terminal viewport. It can escalate via `tbd notify --type attention_needed`. No automatic routing yet.

### Phase 1b: Event-Driven Routing (Deferred)

Deferred to a separate document: `2026-04-02-conductor-phase-1b-deferred.md`. 
Event-driven notifications would push terminal state transitions to conductors automatically, 
but the token cost (~3-5k per notification, ~1-2k per heartbeat) may not justify the benefit 
over manual polling. Agent Deck's conductor operates without this and works well. 
Phase 2 (app UI) does not depend on Phase 1b.

### Phase 2: Polish (future)

- App UI: conductor section in sidebar (requires new `StateDelta` case for terminal state transitions)
- Per-conductor tmux servers (blast radius isolation)
- Bridge integration (Telegram/Slack forwarding of escalations via `[ESCALATION]` parsing)
- Conductor metrics/analytics (auto-response success rate, escalation frequency)
- Conductor-to-conductor communication

## Testing Strategy

### Phase 1a Tests

- **Conductor lifecycle tests:** Setup creates correct directory structure + DB row + synthetic worktree, start creates terminal record in tbd-conductor tmux server, teardown cleans up everything
- **CLI integration tests:** Verify `tbd conductor setup/list` produce correct output
- **End-to-end:** Manual test with a real conductor session monitoring a worktree

### Phase 1b Tests (Deferred)

See `2026-04-02-conductor-phase-1b-deferred.md` for TerminalStateTracker, ConductorRouter, server-side send guard, and SuspendResumeCoordinator regression tests.

## Migration

- **DB migration (v9):**
  - New `conductor` table (schema in Conductor Storage section — no permissions column, just scope fields and heartbeat config).
  - Synthetic "conductors" pseudo-repo inserted with well-known UUID.
  - New `.conductor` case for `WorktreeStatus` in `TBDShared/Models.swift`. Must ship in TBDShared so both daemon and app can decode it. The `Worktree.branch` column is NOT NULL, so conductor worktrees use the sentinel value `"conductor"`.
- **StateDelta suppression:** `StateSubscriptionManager` filters out `worktreeCreated`/`worktreeArchived` deltas for `.conductor`-status worktrees. This prevents the app from receiving deltas it can't display yet.
- **SuspendResumeCoordinator refactor (deferred, Phase 1b):** Extract idle detection into `TerminalStateTracker`. See `2026-04-02-conductor-phase-1b-deferred.md` for details.
- New RPC methods are additive (no breaking changes to existing RPCs).
- `WorktreeStatus.conductor` is filtered out of `worktree.list` results by default.

## Risks & Mitigations

### Phase 1a Risks

| Risk | Mitigation |
|------|------------|
| Conductor auto-responds incorrectly | CLAUDE.md template is conservative ("when unsure, escalate"). Cost asymmetry: false escalation < wrong auto-response. |
| Shared tbd-conductor tmux server blast radius | One conductor crashing tmux affects all conductors. Acceptable for Phase 1. Per-conductor servers in Phase 2 if needed. |
| NULL worktreeID for conductor terminals breaks queries | Avoided: synthetic worktree with status `.conductor` instead. Filtered from normal worktree listings. |

### Phase 1b Risks (Deferred)

| Risk | Mitigation |
|------|------------|
| Stale notification race (terminal transitions running->waiting->running before conductor acts) | Server-side send guard: `terminal.send` checks TerminalStateTracker state before dispatching. Rejects sends to non-waiting terminals. |
| Conductor sends conflicting message while user is typing | Interaction lock prevents simultaneous sends. User input always takes priority (conductor can't send to a `running` terminal). |
| tmux capture-pane failure masks terminal state | TerminalStateTracker produces `unknown` state on detection errors instead of silently reporting `running`. Conductors can flag persistent `unknown` states. |
| Conductor crashes with held interaction lock | Daemon detects conductor terminal death via TerminalStateTracker periodic polling. Immediately releases all locks held by dead conductor. |
| TerminalStateTracker polling adds overhead | 10s polling only for `running` terminals. Most detection is event-driven via hooks. Polling is a safety net. |
| Refactoring SuspendResumeCoordinator breaks suspend/resume | Tracker exposes `clearIdleFlag()` preserving existing semantics. 30s resume delay stays in coordinator. Existing tests serve as regression suite. |
