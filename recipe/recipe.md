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
