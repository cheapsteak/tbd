# TBD

A macOS native app for managing git worktrees and terminals, designed for multi-agent Claude Code workflows.

TBD gives you a unified interface to spin up isolated worktrees, run Claude Code sessions in embedded terminals, and orchestrate parallel development across branches — all from a single SwiftUI app.



https://github.com/user-attachments/assets/85881cde-dbac-47a9-a65c-45c684c92460




## Architecture

Three components communicate over a Unix socket using a JSON RPC protocol:

- **`tbdd`** — Daemon that owns all state (SQLite via GRDB, tmux, git)
- **`tbd`** — CLI client for scripting and shell integration
- **`TBDApp`** — SwiftUI app with embedded terminal views (SwiftTerm)

## Requirements

- macOS 15+
- Swift 6.0+ / Xcode 16+
- [tmux](https://github.com/tmux/tmux) installed (`brew install tmux`)
- [SwiftLint](https://github.com/realm/SwiftLint) installed (`brew install swiftlint`) — required for the pre-push git hook

## Build & Run

```bash
# Build everything
scripts/swift-safe build

# Run the daemon
.build/debug/tbdd

# Use the CLI
.build/debug/tbd --help

# Run the app (or open in Xcode)
open TBDApp.xcodeproj  # if applicable, or:
scripts/swift-safe build --product TBDApp && .build/debug/TBDApp
```

A convenience script rebuilds and restarts the daemon + app:

```bash
scripts/restart.sh          # full rebuild + restart
scripts/restart.sh --app    # restart app only
scripts/restart.sh --quick  # skip build
```

## Updating

`tbd update` moves the whole installation to the head of `main`. It builds in a
dedicated clone under `~/tbd/updates/`, then hands the running daemon over to
its successor rather than killing it, so tmux sessions survive and anything the
new daemon's startup reconcile parks anyway is woken a few at a time.

```bash
tbd version                       # what is running, and whether main has moved
tbd update                        # build the latest main and hand over
tbd config set update-mode check  # be told when main moves; act by hand
```

The daemon can also watch for updates itself, and in `auto` mode run them
unattended. Both are off by default. See [`docs/updating.md`](docs/updating.md)
for the modes, the log at `~/tbd/updates/update.log`, and how to get back to a
previous build.

## Test

```bash
scripts/test.sh
```

A thin wrapper around `swift test` — it forwards every argument, and fences the
run behind a scratch config dir so tests cannot write into your real `~/tbd` or
`~/.claude`.

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

Adopt your existing Claude Code Desktop worktrees into TBD in place. Pass any path inside the repo (the main checkout or any worktree); the script resolves to the main repo root and adopts every worktree under `.claude/worktrees/`. Repos not yet in TBD are auto-registered. Directories named `agent-*` (scratch worktrees from one-shot agent runs) are skipped by default — pass `--include-agents` to adopt them too.

```sh
./scripts/import-claude-code-desktop.sh --repo ~/projects/acme-app --dry-run
./scripts/import-claude-code-desktop.sh --repo ~/projects/acme-app
```

## License

[MIT](LICENSE) © 2026 Chang Wang
