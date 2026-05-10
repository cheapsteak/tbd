# TBD Plugin: Spawn-Scoped `tbd` Skill via `--plugin-dir`

**Date:** 2026-05-09
**Status:** Design approved, awaiting implementation plan

## Problem

The `tbd` skill (CLI driver: `tbd worktree create`, `tbd terminal send`, etc.) only makes sense inside Claude sessions that TBD spawned. Today it reaches the agent through two indirect mechanisms:

1. A `--append-system-prompt` hint pointing at `~/Library/Application Support/TBD/skill/SKILL.md`.
2. A "Install TBD Skill" menu action that copies the file to `~/.claude/skills/tbd/SKILL.md` — which makes it global to every Claude session on the machine, including non-TBD ones.

Mechanism (1) works but lacks the `Skill("tbd")` slash UX and progressive-disclosure loading. Mechanism (2) breaks isolation: every `claude` session on the machine sees the skill, even when it has nothing to do with TBD.

## Goal

Make the `tbd` skill available *only* in TBD-spawned Claude sessions, via Claude Code's native skill mechanism, with zero writes to `~/.claude/`.

## Approach

Use Claude Code's `--plugin-dir <path>` flag, which loads a plugin directory for one invocation only. The daemon writes a TBD-owned plugin to a fixed Application Support path; the spawn pipeline appends `--plugin-dir` alongside the existing `--settings` flag.

Non-TBD `claude` sessions never receive the flag, so they never load the plugin — strict spawn-scoping by construction.

The existing `claude-overlay.json` (SessionStart + Stop hooks via `--settings`) is **not** touched. We may migrate those into the plugin later; out of scope here to keep the diff small and avoid disturbing working notification/transcript-routing behavior.

## Layout on disk

```
~/Library/Application Support/TBD/
  skill/SKILL.md          ← unchanged (env-var fallback, kept for non-TBD harnesses)
  plugin/                 ← NEW
    .claude-plugin/
      plugin.json         ← Claude Code requires the manifest under .claude-plugin/
    skills/tbd/SKILL.md
```

Both `skill/SKILL.md` and `plugin/skills/tbd/SKILL.md` are written from the same source: `TBDSkillContent.body` in `Sources/TBDShared/`. Single source of truth; two on-disk copies during the transition.

`plugin.json`:

```json
{
  "name": "tbd",
  "version": "<TBDConstants.version>",
  "description": "TBD worktree + terminal driver"
}
```

The version field tracks `TBDConstants.version` (currently `"0.1.0"`), so every TBD release auto-bumps the plugin version and Claude Code's plugin cache invalidates cleanly.

## Code changes

### 1. New writer: `PluginDirWriter` (Sources/TBDDaemon/Lifecycle/)

Sibling of the existing `SkillFileWriter`. Writes:
- `<root>/TBD/plugin/plugin.json`
- `<root>/TBD/plugin/skills/tbd/SKILL.md`

Idempotent atomic writes. Creates parent directories. Logs success/failure via `os.Logger` under `subsystem: "com.tbd.daemon", category: "skill"` (or new `"plugin"`). Failures non-fatal — the spawn pipeline gates on directory existence and silently skips `--plugin-dir` if absent, mirroring the existing `--settings` overlay gating.

Called once at daemon startup, alongside `SkillFileWriter.writeFallback()` and `ClaudeHookOverlay.writeOverlay()`.

### 2. Spawn builder: `ClaudeSpawnCommandBuilder.build`

Add parameter `pluginDirPath: String?` (default nil) mirroring the existing `settingsOverlayPath` shape. Emit `--plugin-dir <escaped>` when:
- `pluginDirPath` is non-nil
- `fileExists(pluginDirPath)` returns true (uses the same injected `fileExists` closure as the settings overlay check)

Flag goes after `--settings` on both the `--resume` and `--session-id` branches. The `cmd` and `shellFallback` branches do not get the flag (non-claude commands).

### 3. Caller wiring

Wherever `settingsOverlayPath` is currently threaded through (`Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift` and any other callers of `ClaudeSpawnCommandBuilder.build`), also pass the plugin directory path. The path is a constant derived from the same Application Support root used by `SkillFileWriter`:

```
<applicationSupportRoot>/TBD/plugin
```

Expose this as a static constant on `PluginDirWriter` (mirrors `ClaudeHookOverlay.overlayPath`).

### 4. System prompt cleanup

`Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift:18-29` currently says:

> A `tbd` skill should be available — invoke it for worktree/terminal actions. If unavailable, read its content directly from `<fallback path>`.

With `--plugin-dir` always supplied for TBD spawns, the "if unavailable" fallback line becomes noise. Tighten to:

> You are running inside a TBD-managed worktree (a macOS worktree + terminal manager). A `tbd` skill is available — invoke it for worktree/terminal actions.

The fallback file path is no longer mentioned in the system prompt, but the file itself stays on disk for non-TBD harnesses (Codex, Copilot CLI) that don't use Claude Code's plugin loader.

### 5. Remove "Install TBD Skill" menu

Files to remove or trim:
- `Sources/TBDApp/MenuBar/SkillMenu.swift` — entire file (verify no other call sites)
- `Sources/TBDApp/AppState+Skill.swift` — `installSkill()` method
- `Sources/TBDApp/DaemonClient.swift:531` — `installSkill(harness:)` method
- Daemon-side `installSkill` RPC handler (locate via grep on `RPCRouter`)
- Any `MenuBar` wiring that adds the skill submenu to the menu bar
- Related types in `RPCProtocol.swift` (e.g., `SkillInstallResultRPC`, `Harness` enum if unused elsewhere)

Removing the menu also removes the only path that writes to `~/.claude/skills/tbd/`. If a user previously installed via the menu, the file at `~/.claude/skills/tbd/SKILL.md` will remain stale on disk — out of scope to clean up automatically. Document in the migration note.

### 6. Tests

New cases in `Tests/TBDDaemonTests/Claude/ClaudeSpawnCommandBuilderTests.swift`:
- Plugin dir present + fresh session → command contains `--plugin-dir <path>`
- Plugin dir present + resume → command contains `--plugin-dir <path>`
- Plugin dir nil → no flag
- Plugin dir non-nil but `fileExists` returns false → no flag
- Plugin dir + settings overlay both present → both flags emitted, in stable order

New test target or file `Tests/TBDDaemonTests/Lifecycle/PluginDirWriterTests.swift`:
- Writes `plugin.json` with current `TBDConstants.version` and expected fields
- Writes `skills/tbd/SKILL.md` with body byte-equal to `TBDSkillContent.body`
- Idempotent (second call doesn't error or duplicate)
- Creates parent directories if absent

## Out of scope

- Migrating SessionStart/Stop hooks from `claude-overlay.json` into the plugin manifest. Possible future simplification; not done here to keep the diff small and avoid disturbing working notification/transcript-routing.
- Cleaning up stale `~/.claude/skills/tbd/` files left by the deprecated menu action.
- Multi-harness plugin packaging (Codex, Copilot CLI). Those harnesses continue to use the standalone `~/Library/Application Support/TBD/skill/SKILL.md` fallback.

## Verification

After implementation, manual smoke:

1. `scripts/restart.sh` — verify plugin dir written at `~/Library/Application Support/TBD/plugin/`.
2. Open a worktree in TBD → in the spawned Claude session, confirm `Skill("tbd")` is listed in the available skills system reminder.
3. Run `claude` from a plain terminal (no TBD) → confirm the `tbd` skill is **not** listed.
4. `--resume` an existing TBD session → confirm `--plugin-dir` is present in the spawn command (`ps aux | grep claude`).

## Open questions

None. All scoping decisions resolved during brainstorming:
- Plugin = skill only (hooks stay in overlay)
- Version tracks `TBDConstants.version`
- "Install TBD Skill" menu removed
