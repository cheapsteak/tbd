# TBD Actions as an Installable Skill

**Date:** 2026-05-03
**Status:** Design

## Problem

TBD currently teaches Claude sessions about its CLI by injecting `--append-system-prompt` at spawn time. The prompt body is `builtInTBDContext` in `Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift:14-53`. This mechanism has five known weaknesses:

1. **Resumes silently lose it.** `SystemPromptBuilder.build()` returns nil when `isResume=true` (`SystemPromptBuilder.swift:80`), so `claude --resume <uuid>` never re-injects. Sessions originally created before a TBD feature shipped stay permanently context-less for that feature.
2. **Compaction can summarize it away** on long sessions.
3. **Shell-type terminals never get it** — only sessions TBD spawns directly via `claude --append-system-prompt` benefit. Manual `claude` invocations in shell tabs are blind.
4. **Updating the prompt requires a daemon rebuild.** The prompt is a Swift constant baked into the binary, not a file the model can read fresh.
5. **It is Claude-Code-only.** Future codex / gemini support would need separate spawn paths and prompt-injection plumbing.

## Goals

- Make TBD's CLI knowledge available to agent harnesses as a discoverable, on-demand **skill**, so it survives resume and compaction and reaches every kind of terminal.
- Keep the canonical content **hot-updatable** — editing one place in the daemon source updates the body without daemon-internal coupling that requires rebuilding consumers.
- Provide a **failsafe** path so the model can read the content even if no skill is registered with the harness.
- **Ship V1 for Claude Code** while leaving codex / gemini as a clean future extension.
- Match the install UX shape of PR #90 (CLI symlink installer): status-aware menu item, explicit user click, no silent writes to the user's harness config.

## Non-Goals

- Auto-installing into `~/.claude/skills/` without user action.
- Codex / Gemini install targets in V1 (designed for, not shipped).
- Auto-update on TBD upgrade (user clicks Update; no background overwrite).
- User-customization markers / generated-block delimiters in the skill file (Q4 option C). Out of scope until a real user complains.
- Project-scoped skills. TBD is a system-level tool; user-global is the only sensible scope.

## Design

### One canonical source of truth

A new Swift file `Sources/TBDShared/TBDSkillContent.swift` holds:

- `body: String` — the full skill markdown including YAML frontmatter.
- `bodyHash() -> String` — SHA256 of `body`, hex-encoded. Used for "is the installed copy current?" checks.

This replaces the role of `builtInTBDContext` as the canonical reference text. `builtInTBDContext` itself stays as a property of `SystemPromptBuilder` but is rewritten to a one-line pointer (see "Slim legacy injection" below).

### Three places the content lands

1. **Fallback file — always written.** Path: `~/Library/Application Support/TBD/skill/SKILL.md`. Daemon writes this on every startup, unconditionally. Resolved via `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`. Failures (permissions, disk full) are logged via `os.Logger` (subsystem `com.tbd.daemon`, category `skill`) but do not crash the daemon — the slim injection still works. This file is the failsafe the legacy injection points to.
2. **Harness skill — written on user click.** Path: `~/.claude/skills/tbd/SKILL.md`. Written only when the user clicks "Install" or "Update" in the menu (or runs `tbd skill install`). Parent directory `~/.claude/skills/tbd/` is created if missing. `~/.claude/` itself is NOT created — its absence means Claude Code is not installed and the menu item is disabled with a tooltip.
3. **Slim legacy injection** — see next section.

### Slim legacy injection

`SystemPromptBuilder.builtInTBDContext` is replaced with a short pointer (~3 lines):

```
You are running inside a TBD-managed worktree (a macOS worktree + terminal manager).
A `tbd` skill should be available — invoke it for worktree/terminal actions.
If unavailable, read its content directly from /Users/<user>/Library/Application Support/TBD/skill/SKILL.md.
```

The fallback path is resolved at injection build time to its concrete absolute form (e.g., `/Users/chang/Library/Application Support/TBD/skill/SKILL.md`) using `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`. The `<user>` shown above is illustrative; the real injected string contains the resolved path. Resume sessions still skip injection (`build()` continues to return nil when `isResume=true`) — same behavior as today. The slim pointer is only added on fresh sessions.

Rationale for keeping resume-skip behavior: the slim pointer's value comes from being injected when no other context exists. On resume, the user's prior session text is the load-bearing context, and the skill is registered (or the file is on disk) for the model to find on its own.

### Skill body content

Frontmatter — this is the description the harness matches against to decide skill relevance:

```yaml
---
name: tbd
description: Drive TBD (a macOS worktree + terminal manager). Use when the user asks to create a worktree, spawn a Claude or shell session in another tab, send input to a terminal, read terminal output, link to a worktree, or send a UI notification — or whenever running inside a TBD-managed terminal (TBD_WORKTREE_ID env var is set).
---
```

Body, ~50–70 lines, workflow-oriented (not a flag dump):

1. **What TBD is** — one paragraph. macOS app, manages git worktrees + terminal tabs (claude/shell), `TBD_WORKTREE_ID` set inside.
2. **Discovering current commands** — explicit instruction to run `tbd <cmd> --help` for current flags. Versioning-drift mitigation: the body documents shape and intent; `--help` is authoritative for flag specifics.
3. **Common workflows** (5 tasks, each one example block):
   - Spawn a new Claude tab in the current worktree (heredoc + briefing)
   - Create a new worktree with an initial task
   - Send input to an existing terminal / read its output
   - Notify the TBD UI (with the four valid types)
   - Get a deep link to a worktree
4. **Briefing requirements when spawning sessions** — preserved verbatim from today's injection: spawned sessions start with zero context, include goal/ruled-out/paths/judgment-context, use `--prompt-file -` heredoc.
5. **Env vars set in TBD-managed terminals** — `TBD_WORKTREE_ID`, `TBD_PROMPT_CONTEXT`, `TBD_PROMPT_INSTRUCTIONS`. Brief.
6. **Outside a TBD terminal** — short note: if `TBD_WORKTREE_ID` isn't set, use `tbd worktree list` to find an ID, or `tbd worktree create` from anywhere on the same machine.

What's NOT in the body:
- Per-flag enumeration (delegated to `--help`)
- Architecture details (daemon, RPC, tmux internals — irrelevant to driving the CLI)
- Notes about deep links / LaunchServices internals

### Menu UX (mirrors PR #90 pattern)

Three menu states, re-evaluated on app activation by polling `skillStatus` RPC:

| Daemon hash vs file | File exists? | Menu item label | Action on click |
|---|---|---|---|
| n/a | no | **Install TBD Skill…** | Write file, show "Installed at `~/.claude/skills/tbd/SKILL.md`" dialog |
| match | yes | **TBD Skill: Installed ✓** | Disabled / informational; clicking shows path |
| mismatch | yes | **Update TBD Skill…** | Confirm dialog ("This will overwrite ~/.claude/skills/tbd/SKILL.md"), then write |

If `~/.claude/` does not exist: menu item is disabled with tooltip "Claude Code not detected".

Update detection uses content-hash compare (Q4 option A). User edits to the installed file will show as "Update available"; clicking Update overwrites them. Acceptable for V1 — design intent is that user customization happens in their own skills, not by patching ours.

### CLI parity

`Sources/TBDCLI/Commands/` gains `skill` subcommand:

- `tbd skill install` — installs or updates `~/.claude/skills/tbd/SKILL.md`. Prints absolute path on stdout on success, status on stderr.
- `tbd skill status` — prints status (`not-installed` / `installed` / `outdated`) and the path. Exit code 0 for installed-and-current; non-zero otherwise so it composes in shell scripts.

Same logic as the menu, scriptable, useful for headless / no-app users.

### RPC surface

Additions to `Sources/TBDShared/RPCProtocol.swift`:

```swift
case skillStatus      // -> { harnessPath, exists, hashMatch, daemonHash, fileHash? }
case skillInstall     // -> { harnessPath, action: "installed" | "updated" | "noop" }
```

Daemon-side handlers in a new `Sources/TBDDaemon/Server/RPCRouter+SkillHandlers.swift` (parallel to PR #90's terminal handler additions). Pure delegation to `SkillInstaller` in TBDShared.

### Components

| File | Purpose |
|---|---|
| `Sources/TBDShared/TBDSkillContent.swift` (new) | Canonical body string + hash function |
| `Sources/TBDShared/SkillInstaller.swift` (new) | Pure logic: status check, install, update. Takes a `Harness` enum (`.claudeCode` only in V1) |
| `Sources/TBDShared/RPCProtocol.swift` | Add `skillStatus` and `skillInstall` cases |
| `Sources/TBDDaemon/Lifecycle/SystemPromptBuilder.swift` | `builtInTBDContext` becomes the slim pointer; resolves fallback path absolutely |
| `Sources/TBDDaemon/Lifecycle/SkillFileWriter.swift` (new) | Writes fallback file at daemon boot, idempotent |
| `Sources/TBDDaemon/Server/RPCRouter+SkillHandlers.swift` (new) | RPC handlers for `skillStatus` / `skillInstall` |
| `Sources/TBDApp/SkillInstallerCoordinator.swift` (new) | Menu state + click handlers; polls daemon on app activation |
| `Sources/TBDApp/AppState.swift` | Wire in coordinator (parallel to PR #90's CLI installer wiring) |
| `Sources/TBDCLI/Commands/Skill.swift` (new) | `tbd skill install` / `tbd skill status` subcommands |

### Data flow

```
Daemon boot
  └─ SkillFileWriter.writeFallback() → ~/Library/Application Support/TBD/skill/SKILL.md

App launch / activation
  └─ SkillInstallerCoordinator.refresh()
       └─ RPC skillStatus → { harnessPath, exists, hashMatch, daemonHash }
            └─ Menu renders "Install…" / "Installed ✓" / "Update…"

User clicks Install/Update
  └─ RPC skillInstall
       └─ SkillInstaller.install(harness: .claudeCode)
            └─ Writes ~/.claude/skills/tbd/SKILL.md
       └─ Coordinator re-renders menu
```

### Future-proofing

`SkillInstaller` accepts a `Harness` enum:

```swift
enum Harness {
    case claudeCode
    // future: .codex, .gemini
}
```

Each case maps to:
- A target install path (e.g., `~/.claude/skills/tbd/SKILL.md` for `.claudeCode`)
- A detector for whether the harness is installed (e.g., `~/.claude/` exists)
- (If needed) a content adapter that transforms the canonical body into harness-specific format

V1 ships with one case. Adding codex / gemini later is mechanical: new enum case, new path resolver, new adapter if format differs. RPC signature stays stable; menu grows a submenu when more than one harness is detected.

## Testing

- `Tests/TBDSharedTests/SkillInstallerTests.swift` (new): pure-logic tests parallel to `CLIInstallerTests`. Cover status detection (not installed / installed-current / installed-outdated), install transitions, update transitions, missing parent dir creation, refusal when `~/.claude/` is absent.
- `Tests/TBDSharedTests/TBDSkillContentTests.swift` (new): hash is stable across calls; body parses as valid YAML frontmatter (cheap regex check); body contains the expected workflow section headings.
- `Tests/TBDDaemonTests/SystemPromptBuilderTests.swift` (extend or add): verifies the slim pointer is what's emitted now, fallback path is absolute, `build()` still returns nil on resume.
- Per CLAUDE.md branching-conditional rule: tests for both "skill installed" and "skill not installed" branches of menu state evaluation.

## Open Questions

1. **Menu placement** — TBD app menu, dedicated "Tools" submenu, or alongside the existing "Install Command-Line Tool…"? PR #90's pattern would suggest the latter. Defer to implementation; trivial to move.
2. **Generated-by header in the skill file** — should the body include a `<!-- generated by TBD vX.Y.Z -->` comment? Adds forensic value but complicates hash semantics if not excluded from the hash. Lean: skip for V1.
3. **`tbd skill install` exit codes / output** — confirmed shape: stdout = absolute path on success; stderr = human-readable status; exit 0 only for installed-and-current on `status`. Check this matches existing CLI conventions in TBDCLI before implementation.
