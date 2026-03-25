# TBD File Map

Key source files and what they do.

## Package
- `Package.swift` — SPM manifest. Targets: TBDShared, TBDDaemonLib, TBDDaemon, TBDCLI, TBDApp

## Sources/TBDShared/
- `Constants.swift` — paths (~/.tbd/), version string, socket path
- `Models.swift` — Repo, Worktree (with hasConflicts bool), Terminal, TBDNotification, NotificationType, WorktreeStatus (.active/.archived/.main/.creating), PRStatus, PRMergeableState
- `RPCProtocol.swift` — RPCRequest/Response, all param/result structs, RPCMethod constants
- `NameGenerator.swift` — YYYYMMDD-adjective-animal name generation
- `Adjectives.swift` — ~1,179 curated adjectives (from unique-names-generator)
- `Animals.swift` — ~353 curated animals
- `GitVersion.swift` — auto-generated commit hash/message (from scripts/generate-version.sh)

## Sources/TBDDaemon/ (TBDDaemonLib target)

### Database/
- `Database.swift` — TBDDatabase class, GRDB setup, WAL mode, migrations (v1: schema, v2: gitStatus column, v3: hasConflicts bool replacing gitStatus)
- `RepoStore.swift` — Repo CRUD
- `WorktreeStore.swift` — Worktree CRUD (archive, revive, rename, findByPath, updateHasConflicts, updateTmuxServer)
- `TerminalStore.swift` — Terminal CRUD (list supports optional worktreeID filter for batch fetching)
- `NotificationStore.swift` — Notification CRUD, unread, highestSeverity

### Git/
- `GitManager.swift` — all git operations (fetch, worktree add/remove/list, conflict check, headSHA, isMergeBaseAncestor)

### Hooks/
- `HookResolver.swift` — hook priority chain resolution + async execution

### SSH/
- `SSHAgentResolver.swift` — finds live SSH agent socket, maintains ~/.ssh/tbd-agent.sock symlink

### Tmux/
- `TmuxManager.swift` — tmux server lifecycle, window CRUD, dryRun mode for tests

### Lifecycle/
- `WorktreeLifecycle.swift` — base struct, error enum, init (coordinates db/git/tmux/hooks/subscriptions)
- `WorktreeLifecycle+Create.swift` — two-phase async creation (beginCreate inserts DB row with .creating, completeCreate does git+tmux setup)
- `WorktreeLifecycle+Archive.swift` — two-phase archive (beginArchive updates DB + kills tmux, completeArchive runs hook + git worktree remove in background) and revive (recreate worktree from archived branch)
- `WorktreeLifecycle+Reconcile.swift` — reconcile DB against git worktree list on startup, git status refresh

### PR/
- `PRStatusManager.swift` — polls GitHub PR status for worktrees (open/merged/closed, mergeable state), caches results

### Server/
- `RPCRouter.swift` — maps RPC method names to handler functions (dispatch switch)
- `RPCRouter+RepoHandlers.swift` — repo.add, repo.remove, repo.list handlers
- `RPCRouter+WorktreeHandlers.swift` — worktree.create, worktree.list, worktree.archive, worktree.revive, worktree.rename handlers
- `RPCRouter+TerminalHandlers.swift` — terminal.create, terminal.list, terminal.send, terminal.delete, notify, notifications.list, notifications.markRead, cleanup, daemon.status, resolve.path, pr.refresh handlers
- `SocketServer.swift` — Unix domain socket server (NIO)
- `HTTPServer.swift` — HTTP server on localhost (NIO + NIOHTTP1)
- `StateSubscription.swift` — StateDelta events (worktreeConflictsChanged, etc.) + StateSubscriptionManager for streaming deltas to clients

### Root files
- `main.swift` — daemon entry point (signal handlers, start/stop)
- `Daemon.swift` — top-level orchestrator (init all subsystems incl. PRStatusManager, startup/shutdown, background git fetch every 60s)
- `PIDFile.swift` — PID file management + stale detection

## Sources/TBDCLI/
- `TBD.swift` — @main entry, registers all subcommands
- `SocketClient.swift` — POSIX socket client for daemon RPC
- `PathResolver.swift` — resolves $PWD to repo/worktree ID
- `Utilities.swift` — printJSON, resolvePath helpers
- `Commands/RepoCommands.swift` — tbd repo add/remove/list
- `Commands/WorktreeCommands.swift` — tbd worktree create/list/archive/revive/rename
- `Commands/TerminalCommands.swift` — tbd terminal create/list/send
- `Commands/NotifyCommand.swift` — tbd notify (auto-resolves worktree from PWD)
- `Commands/DaemonCommands.swift` — tbd daemon status
- `Commands/SetupHooksCommand.swift` — tbd setup-hooks --global/--repo
- `Commands/CleanupCommand.swift` — tbd cleanup

## Sources/TBDApp/
- `TBDApp.swift` — @main App, AppDelegate for dock visibility + programmatic icon
- `AppIcon.swift` — programmatic icon generation (purple gradient, branch lines, "TBD" text, optional worktree ribbon)
- `AppState.swift` — @MainActor ObservableObject, published state (repos, worktrees, terminals, tabs, layouts, prStatuses, activeTabIndices, pendingWorktreeIDs), daemon polling, connection management
- `AppState+Repos.swift` — repo actions (add, remove, refresh)
- `AppState+Worktrees.swift` — worktree actions (create with optimistic placeholder, archive, revive, rename, refresh)
- `AppState+Terminals.swift` — terminal actions (create, createForSplit, delete, refresh, send)
- `AppState+Notifications.swift` — notification refresh and alert helpers
- `DaemonClient.swift` — actor, POSIX socket RPC client for app
- `ContentView.swift` — NavigationSplitView, toolbar (incl. PR link button), empty/disconnected states
- `TabBar.swift` — generic horizontal tab bar (supports terminal, webview, codeViewer tabs)
- `FileViewer/FileViewerPanel.swift` — git status file viewer (staged/unstaged changes), clicks open code viewer tab
- `Sidebar/SidebarView.swift` — repo list with filter, add repo button
- `Sidebar/RepoSectionView.swift` — collapsible repo section with + button, shows active + creating worktrees
- `Sidebar/WorktreeRowView.swift` — worktree item with badge, PR status icon, inline rename, selection handling
- `Sidebar/SidebarContextMenu.swift` — right-click menu (rename, archive, etc.)
- `Panes/CodeViewerPaneView.swift` — syntax-highlighted code viewer (Highlightr) with file sidebar
- `Panes/PanePlaceholder.swift` — empty state placeholder for panes
- `Panes/WebviewPaneView.swift` — WKWebView pane with shared cookie store
- `Terminal/TmuxBridge.swift` — grouped session management for terminal panels
- `Terminal/TBDTerminalView.swift` — SwiftTerm subclass with natural text editing (Cmd+Arrow, Opt+Delete)
- `Terminal/TerminalPanelView.swift` — NSViewRepresentable wrapping TBDTerminalView + LocalProcess
- `Terminal/TerminalContainerView.swift` — tab bar + layout for single/multi worktree view
- `Terminal/PaneContent.swift` — PaneContent enum (.terminal/.webview/.codeViewer) + Tab model
- `Terminal/SplitLayoutView.swift` — recursive split renderer with draggable dividers
- `Terminal/LayoutNode.swift` — recursive layout tree using .pane(PaneContent), Codable with backward compat
- `Settings/SettingsView.swift` — preferences (notifications, claude flags, per-repo)
- `Helpers/StatusBarView.swift` — bottom status bar
- `Helpers/KeyboardShortcuts.swift` — Cmd-N, Cmd-D, Cmd-1..9, etc.

## Tests
- `Tests/TBDSharedTests/ModelsTests.swift` — model encoding/decoding tests
- `Tests/TBDDaemonTests/DatabaseTests.swift` — GRDB store tests
- `Tests/TBDDaemonTests/GitManagerTests.swift` — git operation tests
- `Tests/TBDDaemonTests/GitStatusTests.swift` — git status refresh tests
- `Tests/TBDDaemonTests/HookResolverTests.swift` — hook resolution tests
- `Tests/TBDDaemonTests/NameGeneratorTests.swift` — name generation tests
- `Tests/TBDDaemonTests/PRStatusManagerTests.swift` — PR status manager tests
- `Tests/TBDDaemonTests/RPCRouterTests.swift` — RPC routing tests
- `Tests/TBDDaemonTests/SSHAgentResolverTests.swift` — SSH agent resolution tests
- `Tests/TBDDaemonTests/TmuxManagerTests.swift` — tmux manager tests
- `Tests/TBDDaemonTests/WorktreeLifecycleTests.swift` — lifecycle orchestration tests
- `Tests/TBDAppTests/LayoutNodeTests.swift` — layout node tree tests
- `Tests/TBDAppTests/PaneContentTests.swift` — pane content encoding/decoding tests
- `Tests/TBDAppTests/PlaceholderTests.swift` — placeholder
- `Tests/TBDDaemonTests/PlaceholderTests.swift` — placeholder

## Scripts
- `scripts/restart.sh` — rebuild + restart daemon + app (~2s)
- `scripts/generate-version.sh` — writes GitVersion.swift with current commit hash

## Docs
- `docs/tmux-integration.md` — tmux learnings, grouped sessions vs control mode
- `docs/superpowers/specs/2026-03-21-tbd-design.md` — original design spec
- `docs/superpowers/specs/2026-03-23-ssh-agent-resolver-design.md` — SSH agent resolver design
- `docs/superpowers/specs/2026-03-23-worktree-git-status-design.md` — git status tracking design
- `docs/superpowers/specs/2026-03-23-worktree-pr-status-design.md` — PR status tracking design
- `docs/superpowers/specs/2026-03-24-multiformat-panes-design.md` — multiformat panes design
- `docs/superpowers/plans/` — implementation plans (Phase 1 + Phase 2, SSH agent, git status, simplify god objects, PR status, multiformat panes, lucide icons)
