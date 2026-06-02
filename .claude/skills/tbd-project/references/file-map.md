# TBD File Map

Key source files and what they do. Not exhaustive — see the directory listing for the rest.

## Package
- `Package.swift` — SPM manifest. Targets: TBDShared, TBDAppIcon, IconBaker, TBDDaemonLib, TBDDaemon, TBDCLI, TBDApp

## Sources/TBDShared/
- `Constants.swift` — paths under `~/tbd/` (configDir, socket, db, pid, port, repos), version; honors `TBD_HOME`/`TBD_SOCKET_PATH`
- `Models.swift` — Repo, Worktree, Terminal, TerminalKind, Note, TBDNotification, ModelProfile, CredentialKind, Config, PRStatus, SessionSummary + transcript message types, TabState, WorktreeStatus, RepoStatus
- `RPCProtocol.swift` — RPCRequest/Response, all param/result structs, `RPCMethod` constants, `TerminalCreateType`
- `StateDelta.swift` — `StateDelta` enum + delta payload structs (worktree/repo/terminal/tab/modelProfile/session deltas)
- `TBDSkillContent.swift` — canonical `tbd` skill body, single source of truth for the plugin + failsafe writers
- `CLIInstaller.swift` — logic for symlinking `tbd` into `~/.local/bin`
- `SettingsJSONWriter.swift` — safe atomic edits to Claude `settings.json` (legacy hook removal)
- `DeepLinks.swift` — `tbd://` URL parsing/building
- `NameGenerator.swift` / `Adjectives.swift` / `Animals.swift` — `YYYYMMDD-adjective-animal` names
- `RepoConstants.swift` — default rename-prompt template
- `EmojiData.swift` — emoji dataset for worktree-name autocomplete
- `ClaudeEnvRegistry.swift` — registry of user-configurable spawn-time Claude env settings (`ClaudeEnvValue`: bool/int/string, frozen JSON format; `ClaudeEnvRegistry.all` is the single source of truth)

## Sources/TBDAppIcon/ & Sources/IconBaker/
- `TBDAppIcon/AppIcon.swift` — programmatic AppKit/CoreGraphics/CoreText icon drawing; per-worktree ribbon variant at runtime, shared by TBDApp and IconBaker
- `IconBaker/main.swift` — one-shot executable: renders the default (no-ribbon) icon and writes a multi-rep `.icns` file; run after changing AppIcon.swift and commit the result

## Sources/TBDDaemon/ (TBDDaemonLib target)

### Root
- `main.swift` — daemon entry point (signal handlers, SIGUSR1 self-relaunch)
- `Daemon.swift` — top-level orchestrator: initializes subsystems, writes session-instrumentation files, starts servers, reconciles, runs background tasks
- `PIDFile.swift` — PID file management + stale detection

### Claude/
- `ClaudeSpawnCommandBuilder.swift` — pure builder for the `claude` spawn command; appends `--plugin-dir`/`--settings`, returns auth/routing `sensitiveEnv`
- `ClaudeProfileConfigDirManager.swift` — isolates a model profile's Claude config dir under `~/tbd/profiles/<id>/claude/`
- `ClaudeSessionScanner.swift` — locates Claude JSONL session files for a worktree cwd
- `TranscriptParser.swift` — parses Claude JSONL (incl. subagent transcripts) into transcript items
- `UserMessageClassifier.swift` — distinguishes real user messages from system-injected lines
- `ClaudeUsageFetcher.swift` / `ClaudeUsagePoller.swift` / `PollerClock.swift` — Claude OAuth usage polling

### Codex/
- `CodexHomeManager.swift` — per-repo isolated `CODEX_HOME` with TBD hooks + bundled skill

### Hooks/
- `ClaudeHookOverlay.swift` — generates `~/tbd/runtime/claude-overlay.json` (SessionStart/Stop/AskUserQuestion hooks)
- `HookResolver.swift` — worktree lifecycle hook resolution (`.worktree-hooks/` etc.) + async execution
- `LegacyHookScanner.swift` — detects legacy globally-installed `tbd` hook entries in user/repo settings.json

### Lifecycle/
- `WorktreeLifecycle.swift` (+`Create`/`Archive`/`Reconcile`/`Adopt`) — worktree create/archive/revive/adopt/reconcile orchestration
- `ParentResolver.swift` — resolves a new worktree's parent (lineage)
- `WorktreeLayout.swift` — canonical (`~/tbd/worktrees/`) + legacy path resolution, name sanitization
- `SystemPromptBuilder.swift` — builds `TBD_PROMPT_*` layers + `--append-system-prompt`
- `SuspendResumeCoordinator.swift` — auto/manual suspend-resume of idle Claude sessions
- `PluginDirWriter.swift` — writes the TBD Claude Code plugin to Application Support
- `SkillFileWriter.swift` — writes the failsafe copy of the skill body
- `ArchivedWorktreeBackfill.swift` — repairs archived worktree rows with missing branches
- `RepoHealthValidator.swift` — flips repos with stale paths to `.missing`

### Database/
- `Database.swift` — `TBDDatabase`, GRDB setup, WAL, migrations v1–v25
- `MigrationHelpers.swift` — shared migration utilities
- `RepoStore` / `WorktreeStore` / `TerminalStore` / `NotificationStore` / `NoteStore` / `TabStore` — GRDB CRUD stores
- `ConfigStore.swift` / `TBDMetaStore.swift` — global config + key/value meta
- `ModelProfileRecord.swift` / `ModelProfileUsageRecord.swift` — model profile GRDB records

### ModelProfile/
- `ModelProfileResolver.swift` — picks a profile per spawn (terminal → repo → global default)
- `ModelProfileHealthProbe.swift` — validates a profile's credentials

### Server/
- `RPCRouter.swift` — method dispatch, owns subsystem references
- `RPCRouter+*Handlers.swift` — Repo, Worktree, Terminal, Tab, Session, Note, ModelProfile, AskUserQuestion, ManualSuspend, Selection, Subscription, LegacyHook, Relocate, Appearance (terminal COLORFGBG), ClaudePreferences (spawn-time env overrides) handlers
- `SocketServer.swift` / `HTTPServer.swift` — NIO Unix-socket + HTTP RPC servers
- `StateSubscription.swift` — `StateDelta` broadcasting to subscribed clients
- `RepoSerializer.swift` — repo serialization for RPC results

### Git/ Tmux/ SSH/ Keychain/ AskUserQuestion/
- `Git/GitManager.swift` — all git operations
- `Tmux/TmuxManager.swift` — tmux server/window lifecycle, sendKeys/capture; `Tmux/ClaudeStateDetector.swift` — idle detection + session-id capture
- `SSH/SSHAgentResolver.swift` — `~/.ssh/tbd-agent.sock` symlink maintenance
- `Keychain/ModelProfileKeychain.swift` — stores apiKey profile secrets (0600 token files)
- `AskUserQuestion/PendingQuestionStore.swift` — in-memory store bridging AskUserQuestion hook payloads
- `PR/PRStatusManager.swift` — GitHub PR status polling

## Sources/TBDCLI/
- `TBD.swift` — `@main`, registers subcommands
- `SocketClient.swift` / `PathResolver.swift` / `Utilities.swift` — POSIX RPC client, `$PWD`→repo/worktree resolution, helpers
- `Commands/` — `RepoCommands`, `WorktreeCommands` (+`WorktreePosition`), `TerminalCommands`, `NotifyCommand`, `HooksCommand`, `SetupHooksCommand` (deprecated), `SessionEventCommand`, `AskUserQuestionEventCommand`, `StopRenameCheckCommand`, `LinkCommand`, `CleanupCommand`, `DaemonCommands`, `DoctorCommand` (`tbd doctor` — diagnose/repair CLI install), `TerminalActivityEventCommand` (agent hook → terminal-activity bridge)

## Sources/TBDApp/
- `TBDApp.swift` — `@main` App + AppDelegate
- `AppState.swift` + `AppState+*.swift` — observable state split (Repos/Worktrees/Terminals/Tabs/Notes/Notifications/Navigation/History/ModelProfiles/ArchiveTombstones/TerminalFocus)
- `AutoTabLabelResolver.swift` — derives display labels for terminal tabs automatically
- `PRStatusPresentation.swift` — color/label helpers for PR status display
- `DaemonClient.swift` — actor, POSIX RPC client; `DeepLinkHandler.swift` — `tbd://` routing
- `ContentView.swift` / `RepoDetailView.swift` / `RepoInstructionsView.swift` / `TabBar.swift` / `ArchivedWorktreesView.swift`
- `CLIInstallerCoordinator.swift` / `LegacyHooksCoordinator.swift` — launch-time install + legacy-hook migration prompts
- `Sidebar/` — repo sections, nested worktree rows/subtrees, context menu, emoji picker, inline rename, `BranchPickerView` (option-click `+` to create worktree from an existing branch)
- `Terminal/` — TmuxBridge, TBDTerminalView, panels, split layout, LayoutNode, PaneContent, pinned dock, appearance/color schemes, WorktreePager; custom/importable terminal themes: `ThemeStore`, `UserTerminalTheme`, `AlacrittyImporter` (TOML), `ThemeDirectoryWatcher`, `TmuxConfigStyleDetector`
- `Panes/` — code viewer, note, webview, history, `LiveTranscriptPaneView`, `Transcript/` (per-tool cards with body/header split files, chat bubbles, context-usage badge, markdown; file-preview overlay: `TranscriptOverlayView`, `TranscriptOverlayCoordinator`, `TranscriptOverlayEnvironment`, `OverlayFileView`, `OverlayFileLinkAction`, `LocalFileLinker`, `TranscriptNodeCache`)
- `JumpMenu/` — Cmd-K worktree jump palette
- `MenuBar/ModelProfileMenu.swift`, `Settings/` (general, terminal incl. `TerminalThemeEditorView`/`TerminalThemeEditorViewModel`, repo hooks, model profiles, AWS/Bedrock pickers)
- `Diagnostics/` — hang watchdog, main-thread sampler, transcript signposts
- `Services/` — Mac notifications, notification sounds
- `FileViewer/FileViewerPanel.swift` — git status file viewer

## Tests/
Swift Testing framework. `TBDDaemonTests/` (database, git, lifecycle, tmux, hooks, RPC routing, model profiles, sessions, transcripts, suspend/resume, ...), `TBDSharedTests/` (models, emoji), `TBDAppTests/` (layout, pane content).

## Scripts & Docs
- `scripts/restart.sh` — rebuild + restart; `install-hooks.sh` — git hooks; `import-conductor.sh` / `import-claude-code-desktop.sh` — one-script migrations into TBD; `move-home-dir.sh`
- `docs/` — `tmux-integration.md`, `diagnostics-strategy.md`, `worktree-hooks.md`, `worktree-location-design.md`, `transcript-context-usage.md`, plus `specs/` & `plans/`
