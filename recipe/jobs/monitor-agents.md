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
