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
