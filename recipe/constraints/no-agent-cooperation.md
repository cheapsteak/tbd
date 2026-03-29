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
