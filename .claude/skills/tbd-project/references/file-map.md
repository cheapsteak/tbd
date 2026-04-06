# TBD File Map

Key source files and what they do.

## Package
- `Package.swift` — SPM manifest. Targets: TBDShared, TBDDaemonLib, TBDDaemon, TBDCLI, TBDApp

## Sources/TBDShared/
- `Constants.swift` — paths (~/.tbd/), version string, socket path, conductor constants
- `ConductorModels.swift` — Conductor struct, ConductorPermission enum, ConductorSuggestion
- `Models.swift` — Repo (with renamePrompt, customInstructions), Worktree (with hasConflicts, sortOrder), Terminal (with pinnedAt, claudeSessionID, suspendedAt, suspendedSnapshot), Note, TBDNotification, NotificationType, WorktreeStatus (.active/.archived/.main/.creating/.conductor), PRMergeableState, PRStatus
- `RPCProtocol.swift` — RPCRequest/Response, all param/result structs (incl. TerminalCreateType enum, TerminalCreateParams with `type`/`prompt`, TerminalSendParams with `submit`, TerminalConversationParams/Result, ConversationMessage), RPCMethod constants
- `StateDelta.swift` — StateDelta enum (worktreeCreated/Archived/Revived/Renamed, notificationReceived, repoAdded/Removed, terminalCreated/Removed, worktreeConflictsChanged, terminalPinChanged, worktreeReordered) + delta payload structs
- `RepoConstants.swift` — default rename prompt template for worktrees
- `NameGenerator.swift` — YYYYMMDD-adjective-animal name generation
- `Adjectives.swift` — ~1,179 curated adjectives (from unique-names-generator)
- `Animals.swift` — ~353 curated animals
- `EmojiData.swift` — emoji dataset for Slack-style autocomplete in worktree names

## Sources/TBDDaemon/ (TBDDaemonLib target)

### Conductor/
- `ConductorStore.swift` — GRDB store for conductor table (CRUD, updateTerminalID, updateWorktreeID)
- `ConductorManager.swift` — Conductor lifecycle: setup (directory + synthetic worktree + DB + CLAUDE.md), start (tmux window), stop, teardown. Name validation, interact conflict check, template generation.

### Database/
- `Database.swift` — TBDDatabase class, GRDB setup, WAL mode, migrations (v1 through v9+). Exposes stores: repos, worktrees, terminals, notifications, notes, conductors
- `RepoStore.swift` — Repo CRUD
- `WorktreeStore.swift` — Worktree CRUD (archive, revive, rename, findByPath, updateHasConflicts, updateTmuxServer, reorder)
- `TerminalStore.swift` — Terminal CRUD (list supports optional worktreeID filter for batch fetching)
- `NotificationStore.swift` — Notification CRUD, unread, highestSeverity
- `NoteStore.swift` — Note CRUD (create, get, update, delete, list by worktreeID)

### Git/
- `GitManager.swift` — all git operations (fetch, worktree add/remove/list, conflict check, headSHA, isMergeBaseAncestor)

### Hooks/
- `HookResolver.swift` — hook priority chain resolution + async execution

### SSH/
- `SSHAgentResolver.swift` — finds live SSH agent socket, maintains ~/.ssh/tbd-agent.sock symlink

### Tmux/
- `TmuxManager.swift` — tmux server lifecycle, window CRUD, `sendKeys` (literal text with -l), `sendKey` (tmux key name like "Enter" without -l), `sendKeyCommand` (static command builder), `sendCommand` (text + Enter), `windowExists` check, `capturePaneOutput`, `capturePaneWithAnsi`, `paneCurrentCommand`, `panePID`, dryRun mode for tests
- `ClaudeStateDetector.swift` — detects Claude CLI idle state from pane output (status bar + prompt indicators, excludes busy state), captures session ID from PID-based session files

### Lifecycle/
- `WorktreeLifecycle.swift` — base struct, error enum, init (coordinates db/git/tmux/hooks/subscriptions)
- `WorktreeLifecycle+Create.swift` — two-phase async creation (beginCreate inserts DB row with .creating, completeCreate does git+tmux setup)
- `WorktreeLifecycle+Archive.swift` — two-phase archive (beginArchive updates DB + kills tmux, completeArchive runs hook + git worktree remove in background) and revive (recreate worktree from archived branch)
- `WorktreeLifecycle+Reconcile.swift` — reconcile DB against git worktree list on startup, git status refresh
- `SystemPromptBuilder.swift` — builds `--append-system-prompt` for Claude sessions. `promptLayers()` returns env-var-name -> value pairs (TBD_PROMPT_CONTEXT, TBD_PROMPT_INSTRUCTIONS, TBD_PROMPT_RENAME) used both as terminal env vars and as input to the combined prompt. `build()` combines layers into `--append-system-prompt`. `buildForConductor()` for conductor sessions. Skips rename prompt for main worktree.
- `SuspendResumeCoordinator.swift` — auto-suspend idle Claude sessions on worktree deselection, manual suspend/resume, snapshot capture via ClaudeStateDetector

### PR/
- `PRStatusManager.swift` — polls GitHub PR status for worktrees (open/merged/closed, mergeable state), caches results

### Server/
- `RPCRouter.swift` — maps RPC method names to handler functions (dispatch switch), owns all subsystem references
- `RPCRouter+RepoHandlers.swift` — repo.add, repo.remove, repo.list, repo.updateInstructions handlers
- `RPCRouter+WorktreeHandlers.swift` — worktree.create, worktree.list, worktree.archive, worktree.revive, worktree.rename, worktree.reorder handlers
- `RPCRouter+TerminalHandlers.swift` — terminal.create, terminal.list, terminal.send, terminal.delete, terminal.setPin, terminal.output, terminal.conversation, terminal.recreateWindow, notify, notifications.list, notifications.markRead, cleanup, daemon.status, resolve.path, pr.list, pr.refresh handlers
- `RPCRouter+ConductorHandlers.swift` — conductor.setup, conductor.start, conductor.stop, conductor.teardown, conductor.list, conductor.status, conductor.suggest, conductor.clearSuggestion handlers
- `RPCRouter+SelectionHandlers.swift` — worktree.selectionChanged handler (triggers suspend/resume)
- `RPCRouter+ManualSuspendHandlers.swift` — terminal.suspend, terminal.resume, worktree.suspend, worktree.resume handlers
- `RPCRouter+SubscriptionHandler.swift` — state.subscribe registration/removal for streaming deltas
- `RPCRouter+NoteHandlers.swift` — note.create, note.get, note.update, note.delete, note.list handlers
- `SocketServer.swift` — Unix domain socket server (NIO)
- `HTTPServer.swift` — HTTP server on localhost (NIO + NIOHTTP1)
- `StateSubscription.swift` — StateDelta events + StateSubscriptionManager for streaming deltas to clients

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
- `Commands/TerminalCommands.swift` — tbd terminal create/list/send/output/conversation. Create supports `--type claude|shell`, `--cmd`, `--prompt`. Send supports `--submit` (presses Enter after text). TerminalCreateType conforms to ExpressibleByArgument for CLI flag parsing.
- `Commands/ConductorCommands.swift` — tbd conductor setup/start/stop/teardown/list/status
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
- `AppState+Notes.swift` — note actions (create, update, delete) + tab management for note panes
- `ArchivedWorktreesView.swift` — list of archived worktrees with revive/delete actions
- `DaemonClient.swift` — actor, POSIX socket RPC client for app
- `ContentView.swift` — NavigationSplitView, toolbar (incl. PR link button), empty/disconnected states
- `RepoDetailView.swift` — tabbed repo detail view (archived worktrees, instructions)
- `RepoInstructionsView.swift` — per-repo custom instructions editor (rename prompt + custom instructions)
- `TabBar.swift` — generic horizontal tab bar (supports terminal, webview, codeViewer, note tabs)
- `FileViewer/FileViewerPanel.swift` — git status file viewer (staged/unstaged changes), clicks open code viewer tab
- `Sidebar/SidebarView.swift` — repo list with filter, add repo button
- `Sidebar/RepoSectionView.swift` — collapsible repo section with + button, shows active + creating worktrees
- `Sidebar/WorktreeRowView.swift` — worktree item with badge, PR status icon, inline rename, selection handling
- `Sidebar/SidebarContextMenu.swift` — right-click menu (rename, archive, etc.)
- `Sidebar/EmojiPickerView.swift` — Slack-style emoji autocomplete popup for worktree names
- `Sidebar/FloatingPanel.swift` — NSPanel wrapper for positioning popups near sidebar rows
- `Sidebar/InlineTextField.swift` — inline text field for renaming worktrees in sidebar
- `Panes/CodeViewerPaneView.swift` — syntax-highlighted code viewer (Highlightr) with file sidebar
- `Panes/NotePaneView.swift` — freeform text editor pane for notes
- `Panes/PanePlaceholder.swift` — empty state placeholder for panes
- `Panes/WebviewPaneView.swift` — WKWebView pane with shared cookie store
- `Conductor/ConductorHotkeyMonitor.swift` — local key event monitor for conductor toggle hotkey (Opt+.)
- `Conductor/ConductorOverlayView.swift` — Guake-style conductor overlay for terminal panels
- `Conductor/ConductorSuggestionBar.swift` — suggestion bar showing conductor navigation hints
- `Terminal/TmuxBridge.swift` — grouped session management for terminal panels
- `Terminal/TBDTerminalView.swift` — SwiftTerm subclass with natural text editing (Cmd+Arrow, Opt+Delete)
- `Terminal/TerminalPanelView.swift` — NSViewRepresentable wrapping TBDTerminalView + LocalProcess
- `Terminal/TerminalContainerView.swift` — tab bar + layout for single/multi worktree view
- `Terminal/PaneContent.swift` — PaneContent enum (.terminal/.webview/.codeViewer/.note) + Tab model
- `Terminal/SplitLayoutView.swift` — recursive split renderer with draggable dividers
- `Terminal/LayoutNode.swift` — recursive layout tree using .pane(PaneContent), Codable with backward compat
- `Terminal/PinnedTerminalDock.swift` — vertical dock showing pinned terminals from other worktrees with draggable dividers
- `Services/MacNotificationManager.swift` — UNUserNotificationCenter wrapper for macOS native notifications
- `Services/NotificationSoundPlayer.swift` — plays notification sounds (configurable via AppStorage)
- `Settings/SettingsView.swift` — preferences (notifications, claude flags, per-repo)
- `Helpers/StatusBarView.swift` — bottom status bar (version string)
- `Helpers/KeyboardShortcuts.swift` — Cmd-N, Cmd-D, Cmd-1..9, etc.
- `Helpers/ExpandingRow.swift` — auto-expanding row helper for sidebar
- `Helpers/ExpandingTextField.swift` — text field that expands to fit content

## Tests
- `Tests/TBDSharedTests/ModelsTests.swift` — model encoding/decoding tests
- `Tests/TBDSharedTests/EmojiDataTests.swift` — emoji data tests
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
- `Tests/TBDDaemonTests/WorktreeStoreTests.swift` — worktree store tests
- `Tests/TBDDaemonTests/ConductorStoreTests.swift` — conductor DB store tests
- `Tests/TBDDaemonTests/ConductorManagerTests.swift` — conductor lifecycle tests
- `Tests/TBDDaemonTests/ClaudeStateDetectorTests.swift` — Claude idle detection + session ID parsing tests
- `Tests/TBDDaemonTests/StateSubscriptionTests.swift` — state subscription broadcast tests
- `Tests/TBDDaemonTests/SuspendResumeCoordinatorTests.swift` — suspend/resume coordinator tests
- `Tests/TBDDaemonTests/SystemPromptBuilderTests.swift` — system prompt builder tests
- `Tests/TBDAppTests/LayoutNodeTests.swift` — layout node tree tests
- `Tests/TBDAppTests/PaneContentTests.swift` — pane content encoding/decoding tests
- `Tests/TBDAppTests/PlaceholderTests.swift` — placeholder
- `Tests/TBDDaemonTests/PlaceholderTests.swift` — placeholder

## Scripts
- `scripts/restart.sh` — rebuild + restart daemon + app (<1s when no code changes)

## Docs
- `docs/tmux-integration.md` — tmux learnings, grouped sessions vs control mode
- `docs/superpowers/specs/` — design specs (TBD design, SSH agent, git status, PR status, multiformat panes, tmux input, worktree pinning, terminal enhancements, terminal pane pinning, recipe format, auto-suspend, manual suspend, conductor, conductor UI, idle notifications, per-repo instructions)
- `docs/superpowers/plans/` — implementation plans (Phase 1 + Phase 2, SSH agent, git status, simplify god objects, PR status, multiformat panes, lucide icons, tmux input, terminal enhancements, terminal pane pinning, worktree pinning, recipe format, auto-suspend, manual suspend, conductor, conductor UI, idle notifications, per-repo instructions)
