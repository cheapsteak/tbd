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
