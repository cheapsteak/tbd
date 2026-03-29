# Review and integrate agent work

When agents have completed work on their branches, I need to see diffs, review PRs, spot merge conflicts, and understand what changed — all within the same app, without switching to a browser or running git commands manually.

## Constraints

- Must detect merge conflicts before they become a problem
- PR review should be possible without leaving TBD
- File changes should be viewable with syntax highlighting
- [No agent cooperation required](../constraints/no-agent-cooperation.md)

## Techniques used

- [Daemon-UI-CLI split](../techniques/daemon-ui-cli.md)
- [Terminal emulation behind a protocol](../techniques/terminal-protocol.md)

## Success looks like

- Conflict icons appear on worktree rows when a branch would conflict with main
- Clicking a PR status icon opens the GitHub PR in an embedded webview tab
- Cmd+clicking a file path in a terminal opens a syntax-highlighted code viewer alongside the terminal
- The file viewer shows changes since the branch's merge-base with main

## Traps

- Don't try to detect squash merges done outside TBD (e.g., via GitHub PR merge button) — only track merges TBD performs itself
- Don't build a full code review tool — embedded webview to GitHub is sufficient for PR review
- File path detection from terminal text is a heuristic — accept that it won't always work and fail silently
