import Foundation

/// Canonical content for the `tbd` skill. Single source of truth used by two
/// daemon writers at startup:
/// - `SkillFileWriter` → `~/Library/Application Support/TBD/skill/SKILL.md`
///   (env-var fallback referenced by `TBD_PROMPT_CONTEXT` for non–Claude-Code
///   harnesses)
/// - `PluginDirWriter` → `~/Library/Application Support/TBD/plugin/skills/tbd/SKILL.md`
///   (loaded into TBD-spawned Claude sessions via `--plugin-dir`, where the
///   skill registers as `tbd:tbd`)
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

Always run `tbd <subcommand> --help` for current flags — flag detail is not duplicated here. Top-level commands: `tbd worktree`, `tbd terminal`, `tbd link`, `tbd notify`, `tbd channels`.

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

### Coordinate via channels

Channels let you share context with another TBD-managed session — useful when
the user asks you to "post that question for the other agent" or asks the other
agent to "go read what session A said in #foo".

```bash
# Post a message
tbd channels post help "anyone seen the launchctl crash?"

# Output includes a copy-pasteable read command:
#   Posted to #help (seq 42)
#   → tbd channels read help --seq 42
# The user often pastes the second line into another session's prompt.

# Read a specific message
tbd channels read help --seq 42

# Read recent activity (default last 20)
tbd channels read help

# Pull only what's new since the seq you last saw
tbd channels read help --since 40

# Discover channels
tbd channels list

# Watch a channel live (background bash + BashOutput)
# Note: long-lived `tail --follow` shells are not yet empirically validated
# against Claude Code's BashOutput buffer / reaping behavior. Prefer short
# windows (start the tail when you need it, kill it when done) over
# multi-hour background shells until the integration is characterized.
tbd channels tail help --follow

# Clean up a channel that has served its purpose
tbd channels archive help
```

**Notes:**
- Channel names are case-folded; `#API-questions` and `#api-questions` are the
  same channel. Free-form Unicode is allowed (emoji, non-Latin scripts).
- The body is plain UTF-8 text up to 64 KB. Markdown is fine if the reader
  cares; the daemon does not interpret it.
- Reads do not require the daemon — the CLI opens the file directly. Posts
  and archives go through the daemon.
- You can also `Read("~/tbd/channels/<name>.jsonl", offset=N)` directly, but
  note `offset` is line-numbered and may diverge from `seq` after a torn-line
  recovery. Prefer the CLI commands above.

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
- `TBD_PROMPT_CONTEXT` — short context hint confirming you're inside a TBD-managed session. The full `tbd` skill is loaded by your harness (Claude Code spawns it via `--plugin-dir`); other harnesses may fall back to reading `~/Library/Application Support/TBD/skill/SKILL.md`.
- `TBD_PROMPT_INSTRUCTIONS` — per-repo custom instructions (if configured).

## Outside a TBD terminal

If `TBD_WORKTREE_ID` isn't set, run `tbd worktree list` to find an ID, or `tbd worktree create` to make one. The CLI works from any shell on the same machine as the TBD daemon.
"""

}
