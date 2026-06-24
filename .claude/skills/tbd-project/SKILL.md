---
name: tbd-project
description: TBD project knowledge — architecture, components, and conventions. Use when working on the TBD codebase, adding features, fixing bugs, or understanding how the system works. Triggers on questions about the daemon, CLI, SwiftUI app, tmux integration, worktree lifecycle, session instrumentation, or RPC protocol.
---

<!-- skill-synced-through: 7c9ba0f (2026-05-21) -->
<!-- Next maintainer: run `git log 7c9ba0f..HEAD -- Sources/` to find drift since this sync. -->

# TBD Project Guide

TBD is a macOS native app for managing git worktrees and terminals in multi-agent Claude Code workflows. Three components: a daemon (`tbdd`), a CLI (`tbd`), and a SwiftUI app (`TBDApp`).

## Architecture

The daemon owns all state. The CLI and app are both clients that talk to the daemon via a Unix socket.

```
┌─────────┐     ┌──────────┐     ┌─────────┐
│ TBDApp  │────▶│  tbdd    │◀────│  tbd    │
│ SwiftUI │ RPC │  daemon  │ RPC │  CLI    │
└─────────┘     └──────────┘     └─────────┘
                     │
              ┌──────┼──────┐
              ▼      ▼      ▼
           SQLite   tmux    git
```

For detailed architecture, component descriptions, and file locations: consult `references/architecture.md`

For a map of key files and what they do: consult `references/file-map.md`

## Key Conventions

### Config directory is `~/tbd`, not `~/.tbd`

Every daemon-managed path lives under `~/tbd/` (no dot): `~/tbd/state.db`, `~/tbd/sock`, `~/tbd/tbdd.pid`, `~/tbd/port`, `~/tbd/repos/`, `~/tbd/runtime/`, `~/tbd/worktrees/`. `TBDConstants.configDir` honors `TBD_HOME` (and `TBD_SOCKET_PATH` for the socket alone) so tests never collide with the live daemon — see CLAUDE.md.

### SPM Package Structure

Five targets in one package — `TBDShared` (library), `TBDDaemonLib` (library), `TBDDaemon` (executable, just main.swift), `TBDCLI` (executable), `TBDApp` (executable). Tests import `TBDDaemonLib`, not `TBDDaemon`.

The `TBDDaemon` and `TBDDaemonLib` targets share `Sources/TBDDaemon/` — `TBDDaemonLib` excludes `main.swift`, `TBDDaemon` only includes `main.swift` and excludes all subdirectories.

### RPC Protocol

JSON over Unix socket. `RPCRequest` has `method: String` and `params: String` (raw JSON). `RPCResponse` has `success: Bool`, `result: String?` (raw JSON), `error: String?`. Each param/result struct is independently Codable. The router decodes params based on the method string.

### Tmux Integration

Uses **grouped sessions** — NOT control mode. Each terminal panel creates a grouped session (`tmux new-session -t main -s view-<uuid>`) and attaches via a native PTY. SwiftTerm connects directly. For rationale and details: consult `references/architecture.md` or `docs/tmux-integration.md`.

### Git Operations

All git commands use `Process.arguments` arrays — never shell string interpolation (prevents command injection). GitManager methods are async, using `terminationHandler` with `CheckedContinuation`.

### Worktree Hooks

Lifecycle hooks (`setup`, `archive`, `preMerge`, `postMerge`) resolve in priority order (first match wins): app per-repo config → `.worktree-hooks/` → `conductor.json` (deprecated) → `.dmux-hooks/` (deprecated) → global default (`~/tbd/hooks/default/`). `.worktree-hooks/` is the supported in-repo location; the conductor/dmux entries only survive for backward compatibility and log a migration hint. See `docs/worktree-hooks.md`.

> Do not confuse these with **Claude session hooks** — see "Session Instrumentation" below.

### Testing

Tests use Swift Testing framework (`import Testing`, `@Test`, `#expect`), not XCTest. Import `TBDDaemonLib` for daemon tests. Database tests use in-memory `DatabaseQueue`. Tests must isolate from `~/tbd` and `UserDefaults` (see CLAUDE.md).

### Adding New RPC Methods

1. Add method constant to `RPCMethod` in `Sources/TBDShared/RPCProtocol.swift`
2. Add param/result structs in the same file
3. Add handler in the appropriate `Sources/TBDDaemon/Server/RPCRouter+*Handlers.swift` extension
4. Add client method in `Sources/TBDApp/DaemonClient.swift`
5. Add CLI command in `Sources/TBDCLI/Commands/` (if user-facing)
6. Broadcast a `StateDelta` if the method mutates state

### Worktree Names & Location

Auto-generated as `YYYYMMDD-adjective-animal` from curated word lists (sourced from unique-names-generator). Branch: `tbd/<name>`. New worktrees are created under `~/tbd/worktrees/<repo-slot>/<name>/`. Worktrees created before the canonical-location switch still live at `<repo>/.tbd/worktrees/<name>/` and are read from both prefixes for backward compatibility.

## Session Instrumentation

TBD instruments every `claude` (and `codex`) session it spawns so the app can observe and drive them. Three mechanisms, all set up at daemon startup (`Daemon.start()`):

- **TBD plugin** — `PluginDirWriter` writes a Claude Code plugin to `~/Library/Application Support/TBD/plugin/` (`.claude-plugin/plugin.json` + `skills/tbd/SKILL.md`). The bundled skill body is `TBDSkillContent.body` (single source of truth, also dropped to a failsafe path by `SkillFileWriter`). `ClaudeSpawnCommandBuilder` appends `--plugin-dir <path>` to every spawned `claude`, so the `tbd` skill is available *only* in TBD-spawned sessions, never globally.

- **Settings overlay** — `ClaudeHookOverlay` writes `~/tbd/runtime/claude-overlay.json` and the spawn builder appends `--settings <path>`. Claude merges array settings (the `hooks` dict) with the user's `~/.claude/settings.json` rather than replacing it, so TBD ships hooks without touching user config. The overlay registers: `SessionStart` (`tbd session-event` → relays new session id + transcript path to the daemon, fixing the post-`/clear`/`/compact` transcript freeze), `Stop` (two entries — `tbd notify` for response-complete notifications, and `tbd hooks stop-rename-check` to prompt renaming a still-default worktree), and `PreToolUse`/`PostToolUse` matched on `AskUserQuestion` (bridge the question into the transcript pane before the JSONL flush).

- **Codex sessions** — `CodexHomeManager` gives Codex a per-repo isolated `CODEX_HOME` with its own hooks + bundled `tbd` skill, so Codex is instrumented equivalently without polluting `~/.codex/`.

The overlay and plugin are regenerated on every daemon startup; both writes are idempotent and non-fatal on failure (the session just loses instrumentation, it still runs).

Spawned Claude/Codex sessions also receive free-form `KEY=VALUE` env overrides merged across three scopes (`global < repo < profile`), with the Claude builder's auth/routing env layered last so it can't be clobbered. See `docs/env-overrides.md`.

## Common Tasks

### Restart for testing
```bash
scripts/restart.sh          # rebuild + restart (~2s) — always use the worktree-relative path
scripts/restart.sh --app    # app only (NOT for daemon/shared changes)
scripts/restart.sh --quick  # skip build
```

### Debug terminal rendering
Check `/tmp/tbd-bridge.log` for tmux bridge diagnostics.

### Diagnostics
Use `os.Logger` with the `com.tbd.app` / `com.tbd.daemon` subsystems — no `print()` in `Sources/` (SwiftLint-enforced; `TBDCLI` excepted). Stream a feature area: `log stream --level debug --predicate 'subsystem BEGINSWITH "com.tbd"'`. Full guide: `docs/diagnostics-strategy.md`.

### Debug SwiftUI layout / positioning
Add colored borders at each layer of the modifier chain to visualize what occupies what space:
```swift
.border(Color.red, width: 1)   // inner content
.padding(.vertical, 2)
.border(Color.green, width: 1) // after padding
.background(...)
.border(Color.blue, width: 1)  // outermost
```
Useful for diagnosing misalignment with NSPanel overlays — SwiftUI's `List` adds its own row insets and cell spacing outside the view hierarchy. Walk up the AppKit view hierarchy (`superview` chain) to find the `NSTableRowView` if you need the actual cell bounds.
