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
