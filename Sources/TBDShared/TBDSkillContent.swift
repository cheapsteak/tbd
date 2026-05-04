import Foundation
import CryptoKit

/// Canonical content for the `tbd` skill. Single source of truth — written to
/// the fallback file at daemon startup, written to `~/.claude/skills/tbd/SKILL.md`
/// when the user clicks "Install" in the app menu, and referenced (by absolute
/// path) from the slim system-prompt pointer that fresh Claude sessions get.
public enum TBDSkillContent {

    public static let body: String = """
---
name: tbd
description: Drive TBD (a macOS worktree + terminal manager). Use when the user asks to create a worktree, spawn a Claude or shell session in another tab, send input to a terminal, read terminal output, link to a worktree, or send a UI notification — or whenever running inside a TBD-managed terminal (TBD_WORKTREE_ID env var is set).
---

# TBD

TBD is a macOS app that manages git worktrees and terminal tabs (Claude Code or shell). Sessions running inside a TBD-managed terminal have `TBD_WORKTREE_ID` set in env.

## When to use this skill

- The user asks to spawn an agent, create a new worktree, send a message to another terminal, or notify the UI.
- You're running inside TBD (`TBD_WORKTREE_ID` is set) and need to coordinate with the user's other tabs.

## Discovering current commands

Always run `tbd <subcommand> --help` for current flags — flag detail is not duplicated here. Top-level commands: `tbd worktree`, `tbd terminal`, `tbd link`, `tbd notify`.

## Common workflows

### Spawn a new Claude tab in the current worktree

New sessions you spawn start with NO conversation history. Brief them like a colleague who just walked into the room.

```bash
tbd terminal create "$TBD_WORKTREE_ID" --type claude --prompt-file - <<'EOF'
Goal, what you've ruled out, file paths/lines, enough surrounding context
that the new session can make judgment calls rather than follow narrow steps.
EOF
```

### Create a new worktree with an initial task

```bash
tbd worktree create --prompt-file - <<'EOF'
briefing here
EOF
```

### Send input to an existing terminal / read its output

```bash
tbd terminal send --terminal <id> --text "..." [--submit]
tbd terminal output <id> [--lines N]
```

### Notify the TBD UI

```bash
tbd notify --type {response_complete|error|task_complete|attention_needed} --message "..."
```

### Get a deep link to a worktree

```bash
tbd link [<worktree>]   # no arg = current
```

## Briefing requirements when spawning sessions

Always include:
- What you're trying to accomplish.
- What you've already tried or ruled out.
- Relevant file paths with line numbers.
- Enough context for the new session to make judgment calls, not just follow narrow steps.

Use `--prompt-file -` with a heredoc to avoid shell escaping issues.

## Env vars set in TBD-managed terminals

- `TBD_WORKTREE_ID` — current worktree UUID.
- `TBD_PROMPT_CONTEXT` — short pointer that names this skill and the absolute path to its fallback file (~/Library/Application Support/TBD/skill/SKILL.md). The skill body itself is not in env — read it from that path or via your harness's skill mechanism.
- `TBD_PROMPT_INSTRUCTIONS` — per-repo custom instructions (if configured).

## Outside a TBD terminal

If `TBD_WORKTREE_ID` isn't set, run `tbd worktree list` to find an ID, or `tbd worktree create` to make one. The CLI works from any shell on the same machine as the TBD daemon.
"""

    /// SHA256 of `body`, hex-encoded (lowercase, 64 chars). Used to detect
    /// whether an installed skill file matches the running daemon's content.
    public static func bodyHash() -> String {
        let data = Data(body.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
