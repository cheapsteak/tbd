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
