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
- `EnvOverridesCoding.swift` — JSON encode/decode for the free-form env-override `[String: String]` maps (config/repo/profile scopes)
- `NewlineFrameScanner.swift` — incremental newline-delimited frame scanner for socket recv buffers
- `TerminalLabel.swift` — canonical terminal display-label derivation shared by daemon + app

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
- `WorktreeLifecycle.swift` (+`Create`/`Archive`/`Reconcile`/`Adopt`/`Forget`/`PreSession`/`Recovery`) — worktree create/archive/revive/adopt/reconcile orchestration; `+Forget` untracks without deleting from disk, `+PreSession` runs pre-session hook terminals, `+Recovery` resolves rows stuck in `.creating` on restart
- `ParentResolver.swift` — resolves a new worktree's parent (lineage)
- `WorktreeLayout.swift` — canonical (`~/tbd/worktrees/`) + legacy path resolution, name sanitization
- `SystemPromptBuilder.swift` — builds `TBD_PROMPT_*` layers + `--append-system-prompt`
- `SuspendResumeCoordinator.swift` — auto/manual suspend-resume of idle Claude sessions
- `PluginDirWriter.swift` — writes the TBD Claude Code plugin to Application Support
- `SkillFileWriter.swift` — writes the failsafe copy of the skill body
- `ArchivedWorktreeBackfill.swift` — repairs archived worktree rows with missing branches
- `RepoHealthValidator.swift` — flips repos with stale paths to `.missing`

### Database/
- `Database.swift` — `TBDDatabase`, GRDB setup, WAL, migrations v1–v34
- `MigrationHelpers.swift` — idempotent schema-change helpers (`addColumnIfMissing`/`createTableIfNotExists`/`addIndexIfMissing`) — required for all new migrations
- `RepoStore` / `WorktreeStore` / `TerminalStore` / `NotificationStore` / `NoteStore` / `TabStore` — GRDB CRUD stores
- `ConfigStore.swift` / `TBDMetaStore.swift` — global config + key/value meta
- `ModelProfileRecord.swift` / `ModelProfileUsageRecord.swift` — model profile GRDB records

### ModelProfile/
- `ModelProfileResolver.swift` — picks a profile per spawn (terminal → repo → global default)
- `ModelProfileHealthProbe.swift` — validates a profile's credentials
- `EnvOverrideResolver.swift` — merges free-form env overrides across scopes (global → repo → profile) with precedence

### Process/
- `AgentReaper.swift` — detects and reaps orphaned agent child processes
- `ProcessSignaller.swift` — injectable protocol wrapping OS process operations (signals, liveness checks)

### Server/
- `RPCRouter.swift` — method dispatch, owns subsystem references
- `RPCRouter+*Handlers.swift` — Repo, Worktree, Terminal, Tab, Session, Note, ModelProfile, AskUserQuestion, ManualSuspend, Selection, Subscription, LegacyHook, Relocate, Appearance (terminal COLORFGBG), ClaudePreferences (spawn-time Claude env settings), EnvOverrides (free-form env overrides per scope, `config.get`) handlers
- `SocketServer.swift` / `HTTPServer.swift` — NIO Unix-socket + HTTP RPC servers
- `StateSubscription.swift` — `StateDelta` broadcasting to subscribed clients
- `RepoSerializer.swift` — repo serialization for RPC results

### Git/ Tmux/ SSH/ Keychain/ AskUserQuestion/
- `Git/GitManager.swift` — all git operations
- `Tmux/TmuxManager.swift` — tmux server/window lifecycle, sendKeys/capture; `Tmux/ClaudeStateDetector.swift` — idle detection + session-id capture
- `SSH/SSHAgentResolver.swift` — `~/.ssh/tbd-agent.sock` symlink maintenance
- `Keychain/ModelProfileKeychain.swift` — stores apiKey profile secrets (0600 token files)
- `AskUserQuestion/PendingQuestionStore.swift` — in-memory store bridging AskUserQuestion hook payloads
- `PR/PRStatusManager.swift` — GitHub PR status polling; `PR/AutoArchiveOnMergeCoordinator.swift` — auto-archives a worktree when its PR merges (if armed)

## Sources/TBDCLI/
- `TBD.swift` — `@main`, registers subcommands
- `SocketClient.swift` / `PathResolver.swift` / `Utilities.swift` — POSIX RPC client, `$PWD`→repo/worktree resolution, helpers
- `Commands/` — `RepoCommands`, `WorktreeCommands` (+`WorktreePosition`), `ConfigCommands` (`tbd config get|set`), `TerminalCommands`, `NotifyCommand`, `HooksCommand`, `SetupHooksCommand` (deprecated), `SessionEventCommand`, `AskUserQuestionEventCommand`, `StopRenameCheckCommand`, `StopFailureCommand` (`tbd hooks stop-failure` — notify on API-error turn death), `LinkCommand`, `CleanupCommand`, `DaemonCommands`, `DoctorCommand` (`tbd doctor` — diagnose/repair CLI install), `TerminalActivityEventCommand` (agent hook → terminal-activity bridge)

## Sources/TBDApp/
- `TBDApp.swift` — `@main` App + AppDelegate
- `AppState.swift` + `AppState+*.swift` — observable state split (Repos/Worktrees/Terminals/Tabs/Notes/Notifications/Navigation/History/ModelProfiles/ArchiveTombstones/TerminalFocus)
- `AutoTabLabelResolver.swift` — derives display labels for terminal tabs automatically
- `PRStatusPresentation.swift` — color/label helpers for PR status display
- `DaemonClient.swift` — actor, POSIX RPC client; `DeepLinkHandler.swift` — `tbd://` routing
- `ContentView.swift` / `RepoDetailView.swift` / `RepoInstructionsView.swift` / `TabBar.swift` / `ArchivedWorktreesView.swift`
- `CLIInstallerCoordinator.swift` / `LegacyHooksCoordinator.swift` — launch-time install + legacy-hook migration prompts
- `Sidebar/` — repo sections, nested worktree rows/subtrees, context menu, emoji picker, inline rename, `BranchPickerView` (option-click `+` to create worktree from an existing branch), `RowStatusIndicator` (single priority-ranked status dot per row), `RowTooltipPreference` (hover-tooltip preference key + bubble)
- `Terminal/` — TmuxBridge, TBDTerminalView, panels, split layout, LayoutNode, PaneContent, pinned dock, appearance/color schemes, WorktreePager; custom/importable terminal themes: `ThemeStore`, `UserTerminalTheme`, `AlacrittyImporter` (TOML), `ThemeDirectoryWatcher`, `TmuxConfigStyleDetector`
- `Panes/` — code viewer, note, webview, history, `LiveTranscriptPaneView`, `ViewerRouting` (routes file clicks to reuse/split the code viewer), `Transcript/` (per-tool cards with body/header split files, chat bubbles, context-usage badge, markdown; file-preview overlay: `TranscriptOverlayView`, `TranscriptOverlayCoordinator`, `TranscriptOverlayEnvironment`, `OverlayFileView`, `OverlayFileLinkAction`, `LocalFileLinker`, `TranscriptNodeCache`)
- `Panes/Transcript/TextKit/` — the #129 native transcript rebuild (env-gated): `STTextViewTranscriptPaneView`/`STTextViewTranscriptView` (TextKit 2 / STTextView renderer), `TranscriptDocumentBuilder` (nodes → `NSAttributedString`), `TranscriptDocument` (bubble role classification + background drawing), `TranscriptCardFactory`/`TranscriptCardAttachment`/`TranscriptCardContext` (SwiftUI tool cards hosted inline via `NSTextAttachment`), `TranscriptStreamPlan` (classifies incremental TextKit edits from polls)
- `Panes/Transcript/Table/` — alternate `NSTableView` transcript renderer (`TableTranscriptPaneView`/`TableTranscriptView`) with per-row cells (`TranscriptBubbleCellView`, `ActivityRowCellView`, `ActivityRowPresentation`)
- `Panes/Transcript/Renderer/` — Markdown → `NSAttributedString` (`MarkdownAttributedRenderer`), fenced code blocks (`MarkdownCodeBlock`), GFM tables (`MarkdownTable`/`TranscriptTableView`), visual spec (`TranscriptTextTheme`)
- `JumpMenu/` — Cmd-K worktree jump palette
- `MenuBar/ModelProfileMenu.swift`, `Settings/` (general, terminal incl. `TerminalThemeEditorView`/`TerminalThemeEditorViewModel`, repo hooks, model profiles, env-overrides editor (`EnvOverridesEditor`), AWS/Bedrock pickers: `AWSProfiles`/`BedrockModels`/`BedrockRegions`/`ComboBoxField`)
- `Diagnostics/` — hang watchdog, hang stack writer, main-thread sampler, transcript signposts, transcript perf harness
- `Services/` — Mac notifications, notification sounds
- `Helpers/` — `KeyboardShortcuts` (text-finder action routing via responder chain), `StatusBarView` (source/selection status display)
- `Toolbar/OpenInEditorButton.swift` — lists installed editors, opens the worktree externally
- `FileViewer/FileViewerPanel.swift` — git status file viewer

## Tests/
Swift Testing framework. `TBDDaemonTests/` (database, git, lifecycle, tmux, hooks, RPC routing, model profiles, sessions, transcripts, suspend/resume, ...), `TBDSharedTests/` (models, emoji), `TBDAppTests/` (layout, pane content).

## Scripts & Docs
- `scripts/restart.sh` — rebuild + restart; `install-hooks.sh` — git hooks; `import-conductor.sh` / `import-claude-code-desktop.sh` — one-script migrations into TBD; `move-home-dir.sh`; `recipe-check.sh`; `git-hooks/`
- `docs/` — `tmux-integration.md`, `diagnostics-strategy.md`, `worktree-hooks.md`, `worktree-location-design.md`, `transcript-context-usage.md`, `env-overrides.md`, `tcc-signing.md`, plus `specs/`, `plans/` & `perf/`
