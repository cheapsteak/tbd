# TBD

A macOS native app for managing git worktrees and terminals, designed for multi-agent Claude Code workflows.

TBD gives you a unified interface to spin up isolated worktrees, run Claude Code sessions in embedded terminals, and orchestrate parallel development across branches — all from a single SwiftUI app.

## Architecture

Three components communicate over a Unix socket using a JSON RPC protocol:

- **`tbdd`** — Daemon that owns all state (SQLite via GRDB, tmux, git)
- **`tbd`** — CLI client for scripting and shell integration
- **`TBDApp`** — SwiftUI app with embedded terminal views (SwiftTerm)

## Requirements

- macOS 15+
- Swift 6.0+ / Xcode 16+
- [tmux](https://github.com/tmux/tmux) installed (`brew install tmux`)

## Build & Run

```bash
# Build everything
swift build

# Run the daemon
.build/debug/tbdd

# Use the CLI
.build/debug/tbd --help

# Run the app (or open in Xcode)
open TBDApp.xcodeproj  # if applicable, or:
swift build --product TBDApp && .build/debug/TBDApp
```

A convenience script rebuilds and restarts the daemon + app:

```bash
scripts/restart.sh          # full rebuild + restart
scripts/restart.sh --app    # restart app only
scripts/restart.sh --quick  # skip build
```

## Test

```bash
swift test
```

## Migrating from Conductor

Adopt your existing [Conductor](https://conductor.build) worktrees into TBD in place — no files moved, branches untouched, Conductor keeps working alongside. By default, only active (`ready`) Conductor workspaces are adopted, and any repos they reference are auto-registered in TBD.

```sh
./scripts/import-conductor.sh --dry-run    # preview
./scripts/import-conductor.sh              # run
```

Flags:
- `--all` — also adopt archived Conductor workspaces.
- `--repo <name>` — limit to one Conductor repo (e.g. `--repo longeye-app`).
- `--dry-run` — print the plan, don't write anything.

Idempotent — safe to re-run as you create new Conductor worktrees.

Existing Claude session transcripts and `conductor.json` hooks are picked up automatically — nothing extra to migrate.

## Migrating from Claude Code Desktop

Adopt your existing Claude Code Desktop worktrees into TBD in place. Pass any path inside the repo (the main checkout or any worktree); the script resolves to the main repo root and adopts every worktree under `.claude/worktrees/`. Repos not yet in TBD are auto-registered.

```sh
./scripts/import-claude-code-desktop.sh --repo ~/projects/acme-app --dry-run
./scripts/import-claude-code-desktop.sh --repo ~/projects/acme-app
```

## License

Private / All rights reserved.
