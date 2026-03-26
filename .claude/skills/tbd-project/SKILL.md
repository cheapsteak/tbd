---
name: tbd-project
description: TBD project knowledge — architecture, components, and conventions. Use when working on the TBD codebase, adding features, fixing bugs, or understanding how the system works. Triggers on questions about the daemon, CLI, SwiftUI app, tmux integration, worktree lifecycle, or RPC protocol.
---

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

### SPM Package Structure

Four targets in one package — `TBDShared` (library), `TBDDaemonLib` (library), `TBDDaemon` (executable, just main.swift), `TBDCLI` (executable), `TBDApp` (executable). Tests import `TBDDaemonLib`, not `TBDDaemon`.

The `TBDDaemon` and `TBDDaemonLib` targets share `Sources/TBDDaemon/` — `TBDDaemonLib` excludes `main.swift`, `TBDDaemon` only includes `main.swift` and excludes all subdirectories.

### RPC Protocol

JSON over Unix socket. `RPCRequest` has `method: String` and `params: String` (raw JSON). `RPCResponse` has `success: Bool`, `result: String?` (raw JSON), `error: String?`. Each param/result struct is independently Codable. The router decodes params based on the method string.

### Tmux Integration

Uses **grouped sessions** — NOT control mode. Each terminal panel creates a grouped session (`tmux new-session -t main -s view-<uuid>`) and attaches via a native PTY. SwiftTerm connects directly. For rationale and details: consult `references/architecture.md` or `docs/tmux-integration.md`.

### Git Operations

All git commands use `Process.arguments` arrays — never shell string interpolation (prevents command injection). GitManager methods are async, using `terminationHandler` with `CheckedContinuation`.

### Hooks

Resolution order (first match wins, no chaining): app per-repo config → conductor.json → .dmux-hooks → global default. This avoids double-execution when dmux hooks call conductor scripts internally.

### Testing

Tests use Swift Testing framework (`import Testing`, `@Test`, `#expect`), not XCTest. Import `TBDDaemonLib` for daemon tests. Database tests use in-memory `DatabaseQueue`.

### Adding New RPC Methods

1. Add method constant to `RPCMethod` in `Sources/TBDShared/RPCProtocol.swift`
2. Add param/result structs in the same file
3. Add handler in `Sources/TBDDaemon/Server/RPCRouter.swift`
4. Add client method in `Sources/TBDApp/DaemonClient.swift`
5. Add CLI command in `Sources/TBDCLI/Commands/`
6. Broadcast state delta if mutation

### Worktree Names

Auto-generated as `YYYYMMDD-adjective-animal` from curated word lists (sourced from unique-names-generator). Branch: `tbd/<name>`. Path: `<repo>/.tbd/worktrees/<name>/`.

## Common Tasks

### Restart for testing
```bash
scripts/restart.sh          # rebuild + restart (~2s)
scripts/restart.sh --app    # app only
scripts/restart.sh --quick  # skip build
```

### Debug terminal rendering
Check `/tmp/tbd-bridge.log` for tmux bridge diagnostics.

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
