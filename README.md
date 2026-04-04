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

## License

Private / All rights reserved.
