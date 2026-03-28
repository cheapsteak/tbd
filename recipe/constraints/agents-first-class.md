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
