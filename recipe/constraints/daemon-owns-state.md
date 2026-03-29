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
