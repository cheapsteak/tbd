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
