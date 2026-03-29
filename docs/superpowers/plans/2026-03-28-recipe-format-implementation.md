# Recipe Format Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construct the `recipe/` directory for TBD by mining existing design specs and git history, then add mechanical checks and review gating.

**Architecture:** Pure markdown files in `recipe/`, one bash script for mechanical validation, one CODEOWNERS file. No code changes to the Swift project. All content is distilled from the 9 existing design specs in `docs/superpowers/specs/` and the git history.

**Tech Stack:** Markdown, Bash, GitHub CODEOWNERS

**Spec:** `docs/superpowers/specs/2026-03-28-recipe-format-design.md`

---

### Task 1: Create recipe.md (The Dish)

**Files:**
- Create: `recipe/recipe.md`

- [ ] **Step 1: Create the recipe directory and root file**

```markdown
---
format: recipe/v1
last-audit: 2026-03-28
---

# TBD

A macOS native worktree and terminal manager for multi-agent Claude Code workflows.

## Why it exists

Managing multiple AI coding agents on the same repo requires juggling git worktrees, terminal sessions, and status monitoring — creating worktrees, spawning terminals, checking PR status, resuming context after a crash. TBD makes this invisible. Agents get isolated workspaces with their own branches and terminals. Humans get a single window to see what every agent is doing.

## Jobs

- [Set up a multi-agent coding session](jobs/setup-session.md)
- [Monitor agent progress without context-switching](jobs/monitor-agents.md)
- [Resume work across sessions without losing state](jobs/resume-sessions.md)
- [Review and integrate agent work](jobs/review-integrate.md)

## Constraints

- [Daemon owns all state](constraints/daemon-owns-state.md) — Invariant
- [Crash resilience](constraints/crash-resilience.md) — Invariant
- [No agent cooperation required](constraints/no-agent-cooperation.md) — Strong
- [Agents are first-class users](constraints/agents-first-class.md) — Strong

## Key Techniques

- [Grouped tmux sessions](techniques/grouped-tmux.md) (Make)
- [One tmux server per repo](techniques/tmux-per-repo.md) (Make)
- [Daemon-UI-CLI split](techniques/daemon-ui-cli.md) (Make)
- [SQLite with WAL mode](techniques/sqlite-wal.md) (Buy: GRDB)
- [Terminal emulation behind a protocol](techniques/terminal-protocol.md) (Wrap: SwiftTerm)
- [Unix domain socket + HTTP RPC](techniques/unix-socket-rpc.md) (Make)
- [YYYYMMDD-adjective-animal naming](techniques/adjective-animal-naming.md) (Make)
- [Stable SSH agent symlink](techniques/ssh-agent-symlink.md) (Make)
```

- [ ] **Step 2: Create directory structure**

Run: `mkdir -p recipe/constraints recipe/jobs recipe/techniques`

- [ ] **Step 3: Commit**

```bash
git add recipe/recipe.md
git commit -m "feat: add recipe.md — the dish-level recipe for TBD"
```

---

### Task 2: Create constraint files

**Files:**
- Create: `recipe/constraints/daemon-owns-state.md`
- Create: `recipe/constraints/crash-resilience.md`
- Create: `recipe/constraints/no-agent-cooperation.md`
- Create: `recipe/constraints/agents-first-class.md`

- [ ] **Step 1: Create daemon-owns-state.md**

Mine from: `docs/superpowers/specs/2026-03-21-tbd-design.md` lines 9-11 (Core Philosophy), lines 29-47 (Components — daemon owns state), lines 424 (Architecture decision).

```markdown
# Daemon owns all state

**Weight: Invariant**

The UI is a stateless client. All persistent state lives in the daemon process (`tbdd`). If the app crashes, no user-visible data is lost — agents keep working in their tmux sessions, the database retains all worktree metadata, and terminals continue running. If the daemon crashes, it recovers from the SQLite database on restart and reconnects to surviving tmux servers.

## Why this matters

- Agents work in terminals independent of the UI — they don't know or care whether the app is open
- The UI can be restarted, crashed, or closed without interrupting any agent's work
- The CLI tool (`tbd`) works without the app running, talking directly to the daemon
- Multiple UIs could theoretically connect to the same daemon

## What this constrains

- The app process must never be the source of truth for anything persistent — it only owns window layout (split positions, tab order) in UserDefaults
- All state mutations go through the daemon's RPC interface (Unix socket or HTTP)
- The database schema is the daemon's responsibility, not the app's
- State reconciliation on launch: the daemon reconciles its ledger against `git worktree list` — git is authoritative for what exists on disk, the ledger adds metadata
```

- [ ] **Step 2: Create crash-resilience.md**

Mine from: `docs/superpowers/specs/2026-03-21-tbd-design.md` lines 119-121 (Session Persistence), lines 393-399 (Crash recovery).

```markdown
# Crash resilience

**Weight: Invariant**

No user-visible data loss when any component crashes. The system is designed so that the failure of any single component (app, daemon, or tmux server) does not cascade into data loss or require manual recovery.

## Why this matters

- AI agents run for extended periods — losing their terminal state mid-task is expensive
- Users expect a native app to survive crashes gracefully
- The daemon may be kept alive by launchd across system restarts

## What this constrains

- Tmux servers are independent processes — they survive both app and daemon crashes
- The daemon uses PID file checking on startup to detect stale state and clean up
- The daemon reconciles its database against git worktree list on every startup
- The app reattaches to existing tmux sessions on relaunch — scrollback is preserved by tmux
- SQLite WAL mode ensures the database survives process crashes without corruption
```

- [ ] **Step 3: Create no-agent-cooperation.md**

Mine from: `docs/superpowers/specs/2026-03-21-tbd-design.md` lines 9-11 (agents don't need to know about TBD), `docs/superpowers/specs/2026-03-23-worktree-pr-status-design.md` (status is inferred from git artifacts, not agent reporting).

```markdown
# No agent cooperation required

**Weight: Strong**

TBD observes agents through their git artifacts (branches, commits, PRs) and terminal output — it never requires agents to know about TBD, install plugins, or report their status. Agents are unmodified Claude Code sessions.

## Why this matters

- Agents should work the same way inside and outside TBD
- Requiring agent-side integration creates a fragile dependency — agent updates could break TBD
- Users can adopt TBD without changing their agent configuration

## What this constrains

- Status monitoring must infer state from git (branches, merge status, PRs), not from agent APIs
- The notification hook (`tbd notify`) is opt-in and self-filtering — it's a no-op outside TBD-managed worktrees
- Terminal output parsing for status is a trap — use git artifacts as the signal
```

- [ ] **Step 4: Create agents-first-class.md**

Mine from: `docs/superpowers/specs/2026-03-21-tbd-design.md` lines 9-11 (Core Philosophy: "Everything the app can do must be accessible to coding agents").

```markdown
# Agents are first-class users

**Weight: Strong**

Everything the app can do must also be accessible to coding agents via the CLI or RPC interface. The UI is one client of the daemon — not a privileged one.

## Why this matters

- The primary workflow involves AI agents creating worktrees, spawning terminals, and managing their own workspace
- If a feature only works through the GUI, agents can't use it, which defeats the purpose of the tool
- The CLI must be the full-powered interface, not a subset

## What this constrains

- Every new feature needs both a UI surface and a CLI/RPC method
- The daemon's RPC protocol is the canonical API — the app and CLI are both clients
- All commands support `--json` output for machine-readable consumption
- `tbd worktree create` blocks until the directory exists and terminals are spawned, so scripts can rely on the output
```

- [ ] **Step 5: Commit**

```bash
git add recipe/constraints/
git commit -m "feat: add recipe constraints — daemon-owns-state, crash-resilience, no-agent-cooperation, agents-first-class"
```

---

### Task 3: Create job files

**Files:**
- Create: `recipe/jobs/setup-session.md`
- Create: `recipe/jobs/monitor-agents.md`
- Create: `recipe/jobs/resume-sessions.md`
- Create: `recipe/jobs/review-integrate.md`

- [ ] **Step 1: Create setup-session.md**

Mine from: `docs/superpowers/specs/2026-03-21-tbd-design.md` lines 163-177 (Worktree Creation flow), lines 204-237 (Hook System).

```markdown
# Set up a multi-agent coding session

When starting work on a codebase with multiple AI agents, I need each agent to get its own isolated workspace — a git worktree with a fresh branch, a terminal running Claude Code, and a setup hook that prepares the environment — without manually running git commands, tmux sessions, or configuration scripts.

## Constraints

- Creating a worktree must be a single action (click or CLI command)
- Each worktree gets an isolated git branch based on the latest remote default branch
- Setup hooks from existing tools (Conductor, dmux) must be auto-detected and honored
- The CLI must block until the workspace is ready so scripts can depend on the output
- [Daemon owns all state](../constraints/daemon-owns-state.md)
- [Agents are first-class users](../constraints/agents-first-class.md)

## Techniques used

- [Daemon-UI-CLI split](../techniques/daemon-ui-cli.md)
- [One tmux server per repo](../techniques/tmux-per-repo.md)
- [YYYYMMDD-adjective-animal naming](../techniques/adjective-animal-naming.md)

## Success looks like

- Clicking "+" on a repo in the sidebar creates a worktree, spawns two terminals (Claude Code + setup hook), and selects it — all in under 5 seconds
- Running `tbd worktree create --repo .` from any terminal does the same thing and returns the path
- The setup hook runs visibly in its own terminal so users can see its output
- Multiple agents can be set up in rapid succession without conflicts

## Traps

- Don't require network for worktree creation — fall back to local `origin/main` if fetch fails
- Don't chain hooks — first match wins, or you'll double-execute when dmux hooks call conductor scripts internally
- Don't block on the setup hook — let Claude Code start immediately in terminal 1 while the hook runs in terminal 2
```

- [ ] **Step 2: Create monitor-agents.md**

Mine from: `docs/superpowers/specs/2026-03-23-worktree-git-status-design.md` (git status indicators), `docs/superpowers/specs/2026-03-23-worktree-pr-status-design.md` (PR status), `docs/superpowers/specs/2026-03-27-terminal-enhancements-design.md` (OSC 777 notifications).

```markdown
# Monitor agent progress without context-switching

When managing multiple coding agents on the same repo, I need to see what each is doing, whether they're blocked, and what PRs they've opened — without leaving my current context or switching windows.

## Constraints

- Agents work independently; can't require them to report in
- Status must be fresh (< 60s for git, ~30s for PRs) without manual refresh
- Must work even if the UI crashes mid-session
- [Daemon owns all state](../constraints/daemon-owns-state.md)
- [No agent cooperation required](../constraints/no-agent-cooperation.md)

## Techniques used

- [Grouped tmux sessions](../techniques/grouped-tmux.md)
- [Daemon-UI-CLI split](../techniques/daemon-ui-cli.md)

## Success looks like

- Glancing at the sidebar tells me which agents are active, which have PRs open, and whether any branches have conflicts with main
- PR status icons update automatically — green means mergeable, orange means open, purple means merged
- Git status icons show when a branch is behind main or has merge conflicts
- Pinning 2-3 worktrees gives me a persistent split view across sessions
- Terminal notifications (OSC 777) from agents surface as TBD notification badges

## Traps

- Don't poll GitHub too aggressively — rate limits will cut you off. One bulk GraphQL query for all PRs is better than per-worktree REST calls.
- Don't try to infer agent status from terminal output parsing — use git artifacts (branches, PRs) as the signal
- Don't compute git status on a timer — make it event-driven (after fetch, after merge, on startup)
```

- [ ] **Step 3: Create resume-sessions.md**

Mine from: `docs/superpowers/specs/2026-03-26-worktree-pinning-design.md` (persistent selection), `docs/superpowers/specs/2026-03-27-terminal-pane-pinning-design.md` (terminal dock), `docs/superpowers/specs/2026-03-21-tbd-design.md` lines 119-121 (session persistence), lines 148-161 (split layout model).

```markdown
# Resume work across sessions without losing state

When I close the app and reopen it — or it crashes — I need to pick up exactly where I left off: the same worktrees visible, the same terminals running, the same split layout, with no manual reconstruction.

## Constraints

- Tmux sessions must survive app crashes and restarts
- Pinned worktrees must persist across sessions
- Terminal panes pinned to the dock must persist
- Split layout (pane positions, ratios) must be restored
- [Crash resilience](../constraints/crash-resilience.md)
- [Daemon owns all state](../constraints/daemon-owns-state.md)

## Techniques used

- [Grouped tmux sessions](../techniques/grouped-tmux.md)
- [One tmux server per repo](../techniques/tmux-per-repo.md)
- [SQLite with WAL mode](../techniques/sqlite-wal.md)
- [Stable SSH agent symlink](../techniques/ssh-agent-symlink.md)

## Success looks like

- Closing and reopening the app restores the same worktrees in the sidebar, the same terminals with their output, and the same split layout
- Pinned worktrees are automatically selected on launch
- Pinned terminal panes appear in the dock
- SSH signing works in old terminals after a system restart (no stale agent socket)

## Traps

- Don't store session state in the app process — it dies with the UI
- Don't use tmux control mode for the connection model — use grouped sessions so each panel gets independent current-window and size
- The SSH agent socket path goes stale after WindowServer crashes — use a stable symlink that's refreshed periodically
```

- [ ] **Step 4: Create review-integrate.md**

Mine from: `docs/superpowers/specs/2026-03-23-worktree-git-status-design.md` (conflict detection, merge status), `docs/superpowers/specs/2026-03-24-multiformat-panes-design.md` (webview for PRs, code viewer for diffs).

```markdown
# Review and integrate agent work

When agents have completed work on their branches, I need to see diffs, review PRs, spot merge conflicts, and understand what changed — all within the same app, without switching to a browser or running git commands manually.

## Constraints

- Must detect merge conflicts before they become a problem
- PR review should be possible without leaving TBD
- File changes should be viewable with syntax highlighting
- [No agent cooperation required](../constraints/no-agent-cooperation.md)

## Techniques used

- [Daemon-UI-CLI split](../techniques/daemon-ui-cli.md)
- [Terminal emulation behind a protocol](../techniques/terminal-protocol.md)

## Success looks like

- Conflict icons appear on worktree rows when a branch would conflict with main
- Clicking a PR status icon opens the GitHub PR in an embedded webview tab
- Cmd+clicking a file path in a terminal opens a syntax-highlighted code viewer alongside the terminal
- The file viewer shows changes since the branch's merge-base with main

## Traps

- Don't try to detect squash merges done outside TBD (e.g., via GitHub PR merge button) — only track merges TBD performs itself
- Don't build a full code review tool — embedded webview to GitHub is sufficient for PR review
- File path detection from terminal text is a heuristic — accept that it won't always work and fail silently
```

- [ ] **Step 5: Commit**

```bash
git add recipe/jobs/
git commit -m "feat: add recipe jobs — setup-session, monitor-agents, resume-sessions, review-integrate"
```

---

### Task 4: Create technique files

**Files:**
- Create: `recipe/techniques/grouped-tmux.md`
- Create: `recipe/techniques/tmux-per-repo.md`
- Create: `recipe/techniques/daemon-ui-cli.md`
- Create: `recipe/techniques/sqlite-wal.md`
- Create: `recipe/techniques/terminal-protocol.md`
- Create: `recipe/techniques/unix-socket-rpc.md`
- Create: `recipe/techniques/adjective-animal-naming.md`
- Create: `recipe/techniques/ssh-agent-symlink.md`

- [ ] **Step 1: Create grouped-tmux.md**

Mine from: `docs/superpowers/specs/2026-03-21-tbd-design.md` lines 101-147 (Tmux Architecture), `docs/superpowers/specs/2026-03-26-tmux-input-passthrough-design.md`.

```markdown
# Grouped tmux sessions for independent panel views

## Posture: Make

This is a tmux configuration pattern, not a library dependency. The technique is a handful of tmux commands. No library models this specific multi-panel use case.

## The problem

Multiple UI panels need independent views of the same set of terminal sessions — different current windows, different sizes, different scroll positions. A single tmux connection forces all panels to share state.

## The technique

Use tmux grouped sessions. Each repo gets one tmux server (via `-L` socket name). Each UI panel attaches its own session grouped to a shared server. Panels can navigate independently — switching windows in one panel doesn't affect another.

Each terminal is a tmux window with exactly one pane. No tmux pane splits are used — all spatial layout is managed by the host UI (SwiftUI). This keeps the tmux topology flat and predictable.

Key configuration applied to each server:
- `set -g mouse on` — enables mouse click passthrough for agent team pane switching
- `set -g status off` — TBD owns the tab bar, not tmux
- `set -g xterm-keys on` — passes through extended key sequences (Shift+Arrow)
- `set -g extended-keys-format kitty` — enables Kitty keyboard protocol for Shift+Enter and modifier combos

## Why not alternatives

- **Tmux control mode (`-CC`):** Single controller, shared state, size conflicts between panels. iTerm2 uses this but dedicates ~3000 lines to working around its constraints.
- **Multiple independent servers:** Can't share sessions across panels. Each panel would need its own copy of every terminal.
- **No tmux (direct PTY):** Loses session persistence across app crashes. Tmux's independent process model is the key to crash resilience.

## Where this applies

Any multi-panel terminal UI that needs independent navigation of shared sessions with crash-resilient persistence.
```

- [ ] **Step 2: Create tmux-per-repo.md**

```markdown
# One tmux server per repo

## Posture: Make

A naming convention and process isolation pattern. No dependencies.

## The problem

Multiple repos managed in one app need terminal isolation. A crash or misconfiguration in one repo's terminal sessions shouldn't affect another repo.

## The technique

Each repo gets its own tmux server, named `tbd-<hash>` where hash is derived from the repo's stable identifier. Selected via `tmux -L tbd-<hash>`. Each server has one session named `main`. Windows within the session correspond to individual terminal panels.

## Why not alternatives

- **Single shared server:** A crash takes down all repos. Window name collisions. No isolation.
- **Per-worktree servers:** Too many servers. Harder to share sessions between panels viewing the same repo.

## Where this applies

Any tool managing terminals across multiple independent projects in a single UI.
```

- [ ] **Step 3: Create daemon-ui-cli.md**

Mine from: `docs/superpowers/specs/2026-03-21-tbd-design.md` lines 29-47 (Components), line 424 (Architecture decision).

```markdown
# Daemon-UI-CLI three-process split

## Posture: Make

Architectural pattern. Three SPM targets in one Swift package.

## The problem

A macOS app that manages long-running terminal sessions needs to survive its own UI crashes. It also needs to be scriptable by AI agents that work in terminals, not GUIs.

## The technique

Split into three processes:
- **Daemon (`tbdd`):** Long-running headless process that owns all state (database, tmux servers, git operations, hooks). Communicates via Unix socket and HTTP.
- **App (`TBD.app`):** SwiftUI client that subscribes to the daemon's state stream. Owns only window layout. Stateless — can be killed and restarted without data loss.
- **CLI (`tbd`):** Stateless tool that sends a command to the daemon socket, prints the response, exits. Auto-resolves repo and worktree from `$PWD`.

The daemon is the brain. The app and CLI are views.

## Why not alternatives

- **Monolithic app:** UI crash kills everything. Agents can't interact when app is closed.
- **App + CLI (no daemon):** State lives in the app process. CLI can't work when app is closed. App crash loses state.
- **Electron/web approach:** Heavy runtime, poor macOS integration, no native terminal performance.

## Where this applies

Any developer tool that needs to survive crashes and be accessible to both humans (GUI) and machines (CLI/API).
```

- [ ] **Step 4: Create sqlite-wal.md**

```markdown
# SQLite with WAL mode for persistent state

## Posture: Buy (currently GRDB)

Embedded SQLite via a Swift ORM. Don't hand-roll SQL query builders or migration systems. The migration framework and Codable integration aren't worth reimplementing.

## The problem

The daemon needs persistent state (worktree metadata, display names, notification history, pin timestamps) that survives crashes and supports concurrent readers (the daemon writes while the database is being read for state broadcasts).

## The technique

SQLite database at `~/.tbd/state.db` in WAL (Write-Ahead Logging) mode. Only the daemon writes — CLI and UI go through the daemon's RPC, so there are no concurrent writer conflicts. GRDB provides the Swift ORM layer with Codable record types and a sequential migration system (`DatabaseMigrator` with named migrations: v1, v2, v3...).

Key rule: never modify an existing migration. Always add a new one. New columns must have `.defaults(to:)` values, and the corresponding Codable model must make new fields optional or provide defaults.

## Why not alternatives

- **UserDefaults / plist:** No relational queries, no migrations, doesn't scale to the worktree/terminal/notification model.
- **Core Data:** Heavy, complex, designed for app processes not daemons, poor CLI ergonomics.
- **Raw SQLite (no ORM):** Works but GRDB's Codable integration and migration system save significant boilerplate.

## Where this applies

Any Swift daemon or CLI tool needing structured persistent storage with crash safety and migration support.
```

- [ ] **Step 5: Create terminal-protocol.md**

```markdown
# Terminal emulation behind a swappable protocol

## Posture: Wrap (currently SwiftTerm)

We need terminal rendering but must isolate the app from API changes. The terminal adapter layer exists so the underlying library can be swapped.

## The problem

Terminal emulation is complex and the library landscape shifts. Committing to one library's API throughout the codebase creates expensive lock-in if a better option emerges (e.g., Ghostty's renderer).

## The technique

Abstract the terminal emulator behind a protocol (`TerminalRenderer`). The app talks to the protocol; the concrete implementation wraps SwiftTerm. The bridge between tmux control mode output and the terminal emulator is the highest-complexity component — the protocol should be designed with this bridging in mind.

## Why not alternatives

- **Direct SwiftTerm integration (no protocol):** Tightly couples the entire app to one library. Expensive to swap.
- **Building a custom terminal emulator:** Years of work. SwiftTerm and Ghostty exist for a reason.

## Where this applies

Any app embedding a terminal emulator where the library choice may change.
```

- [ ] **Step 6: Create unix-socket-rpc.md**

```markdown
# Unix domain socket + HTTP RPC

## Posture: Make

Standard Unix IPC pattern. SwiftNIO provides the transport layer.

## The problem

The daemon, app, and CLI need to communicate. The protocol must be fast (for real-time state streaming), secure (user-scoped), and debuggable (for development).

## The technique

Dual transport: Unix domain socket at `~/.tbd/sock` (primary, user-scoped permissions) and HTTP on localhost (port stored in `~/.tbd/port`, for debugging with curl). Both use the same JSON-RPC style protocol with newline-delimited messages.

The `state.subscribe` method returns a persistent streaming connection that pushes state deltas as they occur — the app uses this for reactive UI updates.

## Why not alternatives

- **HTTP only:** No Unix socket means no user-scoped permissions out of the box. Localhost HTTP is fine for debugging but shouldn't be the primary transport.
- **gRPC:** Heavy dependency for a single-machine IPC use case. JSON-RPC is simpler and curl-debuggable.
- **XPC:** macOS-only, requires entitlements, harder to debug, no good Swift async story.

## Where this applies

Any daemon + client architecture on a single machine where both performance and debuggability matter.
```

- [ ] **Step 7: Create adjective-animal-naming.md**

```markdown
# YYYYMMDD-adjective-animal naming for worktrees

## Posture: Make

A naming convention. ~20 lines of code with word lists.

## The problem

Worktrees need unique, human-friendly names that don't collide and are easy to type in a terminal. Branch names derived from ticket numbers or descriptions are either cryptic or conflict-prone.

## The technique

Auto-generate names as `YYYYMMDD-adjective-animal` (e.g., `20260321-fuzzy-penguin`). The date prefix groups worktrees chronologically. The adjective-animal suffix is drawn from large randomized word pools, making collisions vanishingly unlikely. The git branch is `tbd/<name>`.

Users can rename the display name in the sidebar without changing the branch or directory name.

## Why not alternatives

- **Sequential numbers:** `worktree-1`, `worktree-2` — no semantic meaning, confusing across repos.
- **Ticket-based names:** Requires ticket system integration, names are ugly in terminals.
- **UUID-based:** Impossible to type or remember.

## Where this applies

Any system that auto-generates human-facing identifiers where uniqueness and typability both matter.
```

- [ ] **Step 8: Create ssh-agent-symlink.md**

Mine from: `docs/superpowers/specs/2026-03-23-ssh-agent-resolver-design.md`.

```markdown
# Stable SSH agent symlink

## Posture: Make

A background task and symlink management. ~100 lines of code.

## The problem

The daemon inherits `SSH_AUTH_SOCK` from its launch environment. When macOS's WindowServer crashes or restarts, launchd creates a new SSH agent at a new socket path. The daemon (and its tmux sessions) retain the old, stale path. Git commit signing breaks in all TBD-managed terminals.

## The technique

Maintain a stable symlink (`~/.ssh/tbd-agent.sock`) that always points to the live SSH agent socket. Set `SSH_AUTH_SOCK` to this symlink path in all tmux sessions. A background task probes every 60 seconds: fast-path checks if the current symlink is reachable via `connect(2)`, slow-path probes launchd socket candidates if not. Symlink updates are atomic via `rename(2)`.

The symlink indirection is the key insight: existing shells don't need to be restarted when the agent socket moves — the symlink resolves at connect time.

## Why not alternatives

- **Restart terminals on SSH agent change:** Destructive, loses agent context.
- **Set env per-command:** Complex, fragile, doesn't work for all git operations.
- **Rely on user to restart:** Happens several times per week on macOS. Not acceptable.

## Where this applies

Any long-running process on macOS that needs SSH agent access across WindowServer restarts.
```

- [ ] **Step 9: Commit**

```bash
git add recipe/techniques/
git commit -m "feat: add recipe techniques — grouped-tmux, tmux-per-repo, daemon-ui-cli, sqlite-wal, terminal-protocol, unix-socket-rpc, adjective-animal-naming, ssh-agent-symlink"
```

---

### Task 5: Create evolution.md from git history

**Files:**
- Create: `recipe/evolution.md`

- [ ] **Step 1: Create evolution.md**

Mine from git log — identify reasoning shifts visible in the commit history and PR titles.

```markdown
# Evolution

Reasoning shifts in TBD's recipe, distilled from git history. Newest first.

# 2026-03-27 | Terminal pane pinning adds a dock model
Originally, pinned terminals were just part of the worktree's own layout. Users actually want to reference a terminal from one worktree while working in another. Terminal pinning creates a persistent dock alongside the main content, filtered to hide terminals whose home worktree is already visible.

# 2026-03-26 | Worktree pinning replaces tab-based workflow
Originally, switching between agents meant clicking sidebar items like tabs. Users actually want 2-3 agents visible simultaneously. Pinning with persistent split view replaces the single-select tab model. Selection order is preserved for split layout.

# 2026-03-26 | Kitty keyboard protocol for modifier key passthrough
The original xterm-keys approach handled Shift+Arrow but not Shift+Enter. Claude Code needs Shift+Enter for multi-line input. Enabling Kitty keyboard protocol in tmux (`extended-keys-format kitty`) solved the full modifier key space in one configuration change.

# 2026-03-26 | Mouse clicks forwarded to tmux for agent team pane switching
Claude Code's agent teams feature spawns tmux split panes. Users couldn't switch between panes because SwiftTerm intercepted all clicks for text selection. Click-vs-drag detection now forwards simple clicks to tmux while preserving drag-select for text.

# 2026-03-24 | Multi-format panes generalize beyond terminals
The layout system originally assumed every leaf was a terminal. Adding webview (for GitHub PRs) and code viewer (for file diffs) required generalizing to a PaneContent enum. The terminal tab system became a generic tab system with mixed pane types.

# 2026-03-23 | PR status is a monitoring job, not a review job
Initially grouped PR display under "reviewing agent work." Realized users check PR status for monitoring (is the agent still working?) not reviewing (is the code good?). PR status polling was moved to background bulk GraphQL queries, not on-demand per-worktree lookups.

# 2026-03-23 | Git status is event-driven, not periodic
The original design polled git status on a timer. Changed to event-driven triggers: after fetch, after merge, on startup. Avoids unnecessary git operations and makes status appear faster when it matters.

# 2026-03-23 | Stable symlink solves SSH agent socket rotation
SSH agent sockets go stale several times per week on macOS. The initial approach was to update tmux env vars periodically, but existing shells would still have the old path. A stable symlink that resolves at connect time means existing sessions self-heal without restart.

# 2026-03-21 | Grouped tmux sessions over control mode
The original design used tmux control mode (-CC) for the app-to-tmux connection. Control mode forces a single controller with shared window state and size. Grouped sessions give each panel independent current-window and size. iTerm2 uses control mode and dedicates ~3000 lines to working around its constraints.
```

- [ ] **Step 2: Commit**

```bash
git add recipe/evolution.md
git commit -m "feat: add recipe evolution.md — reasoning history distilled from git log"
```

---

### Task 6: Create mechanical check script

**Files:**
- Create: `scripts/recipe-check.sh`

- [ ] **Step 1: Create the validation script**

```bash
#!/usr/bin/env bash
# recipe-check.sh — mechanical checks for recipe/ directory integrity
# Validates internal links and detects orphaned files.
# Exit 0 = all checks pass, Exit 1 = issues found.

set -euo pipefail

RECIPE_DIR="$(git rev-parse --show-toplevel)/recipe"
ERRORS=0

if [ ! -d "$RECIPE_DIR" ]; then
    echo "ERROR: recipe/ directory not found"
    exit 1
fi

echo "=== Recipe Mechanical Checks ==="
echo ""

# --- Check 1: Broken internal links ---
echo "Checking internal links..."

while IFS= read -r file; do
    dir="$(dirname "$file")"
    # Extract markdown links: [text](relative/path.md)
    grep -oE '\[([^]]+)\]\(([^)]+\.md)\)' "$file" | while IFS= read -r match; do
        target="$(echo "$match" | sed 's/.*](\(.*\))/\1/')"
        # Skip external URLs
        if [[ "$target" == http* ]]; then
            continue
        fi
        resolved="$(cd "$dir" && realpath -q "$target" 2>/dev/null || echo "")"
        if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
            echo "  BROKEN LINK: $file -> $target"
            ERRORS=$((ERRORS + 1))
        fi
    done
done < <(find "$RECIPE_DIR" -name '*.md' -type f)

# --- Check 2: Orphaned techniques (referenced by zero jobs) ---
echo "Checking for orphaned techniques..."

if [ -d "$RECIPE_DIR/techniques" ]; then
    for technique in "$RECIPE_DIR/techniques"/*.md; do
        [ -f "$technique" ] || continue
        basename="$(basename "$technique")"
        # Search for references in jobs/ and recipe.md
        refs=$(grep -rl "techniques/$basename" "$RECIPE_DIR/jobs/" "$RECIPE_DIR/recipe.md" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$refs" -eq 0 ]; then
            echo "  ORPHAN TECHNIQUE: techniques/$basename (referenced by 0 jobs)"
            ERRORS=$((ERRORS + 1))
        fi
    done
fi

# --- Check 3: Orphaned constraints (referenced by zero jobs) ---
echo "Checking for orphaned constraints..."

if [ -d "$RECIPE_DIR/constraints" ]; then
    for constraint in "$RECIPE_DIR/constraints"/*.md; do
        [ -f "$constraint" ] || continue
        basename="$(basename "$constraint")"
        refs=$(grep -rl "constraints/$basename" "$RECIPE_DIR/jobs/" "$RECIPE_DIR/recipe.md" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$refs" -eq 0 ]; then
            echo "  ORPHAN CONSTRAINT: constraints/$basename (referenced by 0 jobs)"
            ERRORS=$((ERRORS + 1))
        fi
    done
fi

# --- Check 4: Audit staleness ---
echo "Checking audit freshness..."

last_audit=$(grep -m1 'last-audit:' "$RECIPE_DIR/recipe.md" 2>/dev/null | sed 's/.*last-audit: *//' | tr -d ' ')
if [ -n "$last_audit" ]; then
    audit_epoch=$(date -j -f "%Y-%m-%d" "$last_audit" "+%s" 2>/dev/null || echo "0")
    now_epoch=$(date "+%s")
    days_ago=$(( (now_epoch - audit_epoch) / 86400 ))
    if [ "$days_ago" -gt 14 ]; then
        echo "  STALE AUDIT: last audit was $days_ago days ago ($last_audit)"
        ERRORS=$((ERRORS + 1))
    else
        echo "  Audit is fresh ($days_ago days ago)"
    fi
else
    echo "  WARNING: No last-audit timestamp found in recipe.md"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "FAILED: $ERRORS issue(s) found"
    exit 1
else
    echo "PASSED: All checks clean"
    exit 0
fi
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/recipe-check.sh`

- [ ] **Step 3: Run the check to verify it passes**

Run: `scripts/recipe-check.sh`

Expected: PASSED (all links resolve, no orphans, audit is fresh)

- [ ] **Step 4: Commit**

```bash
git add scripts/recipe-check.sh
git commit -m "feat: add recipe mechanical checks — link validation, orphan detection, audit staleness"
```

---

### Task 7: Add CODEOWNERS for review gating

**Files:**
- Create: `CODEOWNERS`

- [ ] **Step 1: Create CODEOWNERS file**

```
# Recipe files require review from someone who understands architectural intent.
# Recipes have more leverage than code — they guide all future generation.
/recipe/ @chang
```

- [ ] **Step 2: Commit**

```bash
git add CODEOWNERS
git commit -m "feat: add CODEOWNERS — recipe changes require architectural review"
```

---

### Task 8: Final validation

- [ ] **Step 1: Run the mechanical check script**

Run: `scripts/recipe-check.sh`

Expected: `PASSED: All checks clean`

- [ ] **Step 2: Verify the complete directory structure**

Run: `find recipe/ -type f | sort`

Expected output:
```
recipe/constraints/agents-first-class.md
recipe/constraints/crash-resilience.md
recipe/constraints/daemon-owns-state.md
recipe/constraints/no-agent-cooperation.md
recipe/evolution.md
recipe/jobs/monitor-agents.md
recipe/jobs/resume-sessions.md
recipe/jobs/review-integrate.md
recipe/jobs/setup-session.md
recipe/recipe.md
recipe/techniques/adjective-animal-naming.md
recipe/techniques/daemon-ui-cli.md
recipe/techniques/grouped-tmux.md
recipe/techniques/sqlite-wal.md
recipe/techniques/ssh-agent-symlink.md
recipe/techniques/terminal-protocol.md
recipe/techniques/tmux-per-repo.md
recipe/techniques/unix-socket-rpc.md
```

- [ ] **Step 3: Verify recipe.md links match actual files**

Spot-check: every link in `recipe/recipe.md` should resolve to an actual file in the recipe directory.

- [ ] **Step 4: Read through recipe.md as a first-time reader**

Quick sanity check: does the top-level recipe tell a coherent story? Do the job names make sense? Do the constraint weights feel right?
