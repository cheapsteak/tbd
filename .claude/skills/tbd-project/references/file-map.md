# TBD File Map

Key source files and what they do.

## Package
- `Package.swift` — SPM manifest. Targets: TBDShared, TBDDaemonLib, TBDDaemon, TBDCLI, TBDApp

## Sources/TBDShared/
- `Constants.swift` — paths (~/.tbd/), version string, socket path
- `Models.swift` — Repo, Worktree, Terminal, TBDNotification, NotificationType
- `RPCProtocol.swift` — RPCRequest/Response, all param/result structs, RPCMethod constants

## Sources/TBDDaemon/ (TBDDaemonLib target)

### Database/
- `Database.swift` — TBDDatabase class, GRDB setup, WAL mode, migrations
- `RepoStore.swift` — Repo CRUD
- `WorktreeStore.swift` — Worktree CRUD (archive, revive, rename, findByPath)
- `TerminalStore.swift` — Terminal CRUD
- `NotificationStore.swift` — Notification CRUD, unread, highestSeverity

### Git/
- `GitManager.swift` — all git operations (fetch, worktree add/remove/list, rebase, merge, conflict check)

### Hooks/
- `HookResolver.swift` — hook priority chain resolution + async execution

### Tmux/
- `TmuxManager.swift` — tmux server lifecycle, window CRUD, dryRun mode for tests

### Names/
- `NameGenerator.swift` — YYYYMMDD-adjective-animal name generation
- `Adjectives.swift` — ~1,179 curated adjectives (from unique-names-generator)
- `Animals.swift` — ~353 curated animals

### Lifecycle/
- `WorktreeLifecycle.swift` — orchestrates create/archive/revive/merge/reconcile

### Server/
- `RPCRouter.swift` — maps RPC method names to handler functions
- `SocketServer.swift` — Unix domain socket server (NIO)
- `HTTPServer.swift` — HTTP server on localhost (NIO + NIOHTTP1)
- `StateSubscription.swift` — streaming state deltas to connected clients

### Root files
- `main.swift` — daemon entry point (signal handlers, start/stop)
- `Daemon.swift` — top-level orchestrator (init all subsystems, startup/shutdown)
- `PIDFile.swift` — PID file management + stale detection

## Sources/TBDCLI/
- `TBD.swift` — @main entry, registers all subcommands
- `SocketClient.swift` — POSIX socket client for daemon RPC
- `PathResolver.swift` — resolves $PWD to repo/worktree ID
- `Utilities.swift` — printJSON, resolvePath helpers
- `Commands/RepoCommands.swift` — tbd repo add/remove/list
- `Commands/WorktreeCommands.swift` — tbd worktree create/list/archive/revive/rename/merge
- `Commands/TerminalCommands.swift` — tbd terminal create/list/send
- `Commands/NotifyCommand.swift` — tbd notify (auto-resolves worktree from PWD)
- `Commands/DaemonCommands.swift` — tbd daemon status
- `Commands/SetupHooksCommand.swift` — tbd setup-hooks --global/--repo
- `Commands/CleanupCommand.swift` — tbd cleanup

## Sources/TBDApp/
- `TBDApp.swift` — @main App, AppDelegate for dock visibility
- `AppState.swift` — @MainActor ObservableObject, all published state, daemon polling
- `DaemonClient.swift` — actor, POSIX socket RPC client for app
- `ContentView.swift` — NavigationSplitView, toolbar, empty/disconnected states
- `Sidebar/SidebarView.swift` — repo list with filter, add repo button
- `Sidebar/RepoSectionView.swift` — collapsible repo section with + button
- `Sidebar/WorktreeRowView.swift` — worktree item with badge, selection handling
- `Sidebar/SidebarContextMenu.swift` — right-click menu (rename, merge, archive, etc.)
- `Terminal/TmuxBridge.swift` — grouped session management for terminal panels
- `Terminal/TerminalPanelView.swift` — NSViewRepresentable wrapping SwiftTerm + LocalProcess
- `Terminal/TerminalContainerView.swift` — tab bar + layout for single/multi worktree view
- `Terminal/TerminalTabBar.swift` — horizontal tab bar
- `Terminal/SplitLayoutView.swift` — recursive split renderer with draggable dividers
- `Terminal/LayoutNode.swift` — recursive layout tree (Codable)
- `Settings/SettingsView.swift` — preferences (notifications, claude flags, per-repo)
- `Helpers/StatusBarView.swift` — bottom status bar
- `Helpers/KeyboardShortcuts.swift` — Cmd-N, Cmd-D, Cmd-1..9, etc.

## Scripts
- `scripts/restart.sh` — rebuild + restart daemon + app (~2s)

## Docs
- `docs/tmux-integration.md` — tmux learnings, grouped sessions vs control mode
- `docs/superpowers/specs/2026-03-21-tbd-design.md` — original design spec
- `docs/superpowers/plans/` — implementation plans (Phase 1 + Phase 2)
