# TBD Architecture

## System Overview

Three components, one SPM package. All daemon-managed paths live under `~/tbd/` (no dot — `TBDConstants.configDir`, overridable via `TBD_HOME`).

### tbdd (Daemon)
Long-running headless process. Owns all state and logic.
- **SQLite** at `~/tbd/state.db` — worktree ledger, repo list, terminals, notes, tabs, model profiles (WAL mode, GRDB)
- **Unix socket** at `~/tbd/sock` — primary RPC interface
- **HTTP** on localhost (port in `~/tbd/port`) — for debugging/curl
- **Tmux manager** — one tmux server per repo (`tbd-<djb2-hash-of-repo-path>`), creates/destroys windows
- **Git manager** — fetch, worktree add/remove/list, conflict check, headSHA, merge-base ancestry
- **Hook resolver** — resolves and runs worktree lifecycle hooks per priority chain
- **Worktree lifecycle** — orchestrates create/archive/revive/adopt/reconcile + conflict detection, parent/lineage resolution
- **PR status manager** — polls GitHub for PR state (open/merged/closed, mergeable) per worktree, persists last-known status to the DB so icons survive restart
- **Auto-archive-on-merge coordinator** — archives a worktree automatically once its PR merges, when armed per-worktree or via the global default
- **SSH agent resolver** — finds live SSH agent socket, maintains `~/.ssh/tbd-agent.sock` symlink
- **Suspend/resume coordinator** — auto-suspends idle Claude sessions on worktree deselection, supports manual suspend/resume
- **Model profile resolver** — picks the credential profile (oauth/apiKey/proxy/bedrock) for a spawned Claude session
- **Claude usage poller** — polls Claude OAuth usage every 30 min, broadcasts to clients
- **Session instrumentation writers** — `PluginDirWriter`, `ClaudeHookOverlay`, `SkillFileWriter`, `CodexHomeManager` (see "Session Instrumentation")
- **State broadcaster** — pushes `StateDelta` events to subscribed clients
- **Background tasks** — git fetch (60s), git status/conflict refresh (10s), SSH refresh (60s)
- **PID file** at `~/tbd/tbdd.pid`

### TBDApp (SwiftUI)
Connects to daemon on launch (starts it if not running). Stateless except for UI layout.
- **Sidebar** — collapsible repo sections, nested worktree rows (lineage by spawner), PR status icons/badges, inline rename, drag-to-reorder, repo hide/remove, sidebar extends under the titlebar
- **Tab system** — generic Tab model wrapping `PaneContent` (`.terminal`/`.webview`/`.codeViewer`/`.note`/`.liveTranscript`/`.history`); tabs are renameable, reorderable, and DB-persisted
- **Pane types** — terminal, webview (WKWebView), code viewer (Highlightr), note (text editor), live transcript (Claude conversation as chat), history (past sessions)
- **Transcript pane** — renders a Claude session's JSONL as a chat UI with per-tool cards (Read/Write/Edit/Bash/Grep/Glob/Agent/AskUserQuestion/...), context-usage badge, subagent expansion; retargets automatically when the session id rolls over
- **Terminal rendering** — grouped tmux sessions + direct PTY attachment (NOT control mode); customizable font, colors, cursor; user-defined themes via `ThemeStore` + `UserTerminalTheme` (importable from Alacritty TOML format via `AlacrittyImporter`, watched for on-disk changes by `ThemeDirectoryWatcher`)
- **Pinned terminal dock** — vertical dock showing pinned terminals from worktrees not currently visible
- **Jump menu** — Cmd-K palette that jumps to the worktree that just pinged
- **Navigation history** — browser-style back/forward across recently selected worktrees
- **State sync** — batched polling + `state.subscribe` stream for push deltas
- **AppState split** — base + Repos / Worktrees / Terminals / Tabs / Notes / Notifications / Navigation / History / ModelProfiles extensions
- **macOS native notifications** via UNUserNotificationCenter, configurable sounds
- **CLI installer coordinator** — offers to symlink `tbd` into `~/.local/bin` on launch
- **Programmatic app icon** — generated at launch (purple gradient, branch lines, "TBD" text)

### tbd (CLI)
Stateless. Connects to daemon socket, sends RPC, prints result, exits.
- POSIX socket client (not NIO — simpler for one-shot connections)
- Auto-resolves repo/worktree from `$PWD` via `resolve.path` RPC
- Subcommands: `repo`, `worktree`, `config`, `terminal`, `notify`, `session-event`, `terminal-activity`, `ask-user-question`, `daemon`, `hooks`, `setup-hooks` (deprecated), `cleanup`, `link`, `doctor`
- `session-event`, `terminal-activity`, and `ask-user-question` are internal — invoked by the Claude settings-overlay hooks, not by humans

## Session Instrumentation

TBD instruments the agent sessions it spawns. At `Daemon.start()`:

- **`PluginDirWriter`** writes a Claude Code plugin to `~/Library/Application Support/TBD/plugin/` containing `.claude-plugin/plugin.json` and `skills/tbd/SKILL.md`. The skill body is `TBDSkillContent.body`.
- **`ClaudeHookOverlay`** writes `~/tbd/runtime/claude-overlay.json` registering `SessionStart`, `Stop` (×2), and `AskUserQuestion` Pre/PostToolUse hooks.
- **`SkillFileWriter`** drops the same skill body to a failsafe path so a session can `Read` it even with no harness skill registered.
- **`ClaudeSpawnCommandBuilder`** (pure function) builds the `claude` command, appending `--plugin-dir` and `--settings` (each only if the file exists). It also returns `sensitiveEnv` carrying auth/routing vars (`ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`, ...) — passed via tmux `-e KEY=VALUE` so secrets never appear in `ps` argv.
- **`CodexHomeManager`** does the equivalent for Codex sessions via a per-repo isolated `CODEX_HOME`.

The `SessionStart` hook calls `tbd session-event`, which RPCs the daemon with the new session id + transcript path; the daemon updates the terminal record and broadcasts `terminalSessionUpdated` so the transcript pane retargets after `/clear` or `/compact`.

## Data Model (SQLite)

Tables: `repo`, `worktree`, `terminal`, `notification`, `note`, `tab`, `model_profile`, `model_profile_usage`, plus a `tbd_meta` key/value store. See `Sources/TBDShared/Models.swift` for struct definitions and `Sources/TBDDaemon/Database/` for GRDB stores.

### Migrations
GRDB `DatabaseMigrator`, numbered sequentially. Never modify an existing migration — always add a new one, and route all schema changes through the idempotent helpers in `MigrationHelpers.swift` (`addColumnIfMissing`/`createTableIfNotExists`/`addIndexIfMissing`). Current range: `v1`–`v34`. Notables:
- **v1–v13** — initial schema + incremental columns (gitStatus → hasConflicts, pinnedAt, claudeSessionID, suspend snapshots, notes, sortOrder, per-repo instructions, etc.)
- **v14_worktree_location** — supports the canonical `~/tbd/worktrees/` location
- **v15_model_profiles** / **v25_model_profiles_bedrock** — model profile table + bedrock fields
- **v16_archived_head_sha**, **v17_terminal_transcript_path**
- **v18_repo_hidden** — repo hide flag
- **v19_tabs_and_order** — `tab` table + tab ordering
- **v20_worktree_active_tab**, **v21_repo_expanded**, **v22_terminal_kind**
- **v23_worktree_parent** — worktree lineage (parent pointer)
- **v24_drop_conductor** — removes the retired Conductor feature's table + rows
- **v26_claude_env_settings** — adds `claude_env_settings` column to `config`; stores user-configurable spawn-time Claude env overrides (`ClaudeEnvValue`: bool/int/string, keyed by `ClaudeEnvSetting.id`)
- **v27_primary_agent_preference** — adds `primary_agent_preference` column to `config`; global preference for claude vs. codex as the default spawned agent
- **v28_notification_terminal_id** — adds `terminalID` (nullable) to `notification`; enables banner clicks to switch to the originating terminal tab
- **v29_terminal_activity_state** — adds `activityState` column to `terminal` (`TerminalActivityState`: `unknown`, `working`, `idle`, `waitingForUser`)
- **v30_model_profile_fallback_models** — adds `fallback_models` (nullable, JSON string array) to `model_profiles` — per-profile Claude `fallbackModel` list
- **v31_env_overrides** — adds `env_overrides` (nullable, JSON `[String: String]`) to `config`, `repo`, and `model_profiles` — free-form env vars applied to spawned sessions (see `docs/env-overrides.md`)
- **v32_worktree_auto_archive** — adds `autoArchiveOnMerge` (bool) to `worktree`
- **v33_config_auto_archive_default** — adds `auto_archive_on_merge_default` (bool, default false) to `config` — global default for the above
- **v34_worktree_pr_status** — adds `prStatus` (nullable, JSON-encoded `PRStatus`) to `worktree`; lets the PR icon survive app/daemon restarts

### Key model types
- `WorktreeStatus`: `.active`, `.archived`, `.main`, `.creating`
- `RepoStatus`: `.ok`, `.missing` (stale path)
- `Repo`: `renamePrompt` + `customInstructions` (per-repo prompt customization), `hidden`, `expanded`
- `Worktree`: `hasConflicts`, `sortOrder`, `parentID` (lineage), `activeTabID`, `tabOrder`, `archivedHeadSHA`, `autoArchiveOnMerge`, `prStatus` (persisted last-known `PRStatus`)
- `Terminal`: `kind` (`TerminalKind`), `pinnedAt`, `claudeSessionID`, `transcriptPath`, `suspendedAt`/`suspendedSnapshot`, `modelProfileID`, `activityState` (`TerminalActivityState`: `unknown`, `working`, `idle`, `waitingForUser`)
- `TerminalKind` / `TerminalCreateType`: `shell`, `claude`, `codex`
- `CredentialKind`: `oauth`, `apiKey`, `proxy`, `bedrock`
- `ModelProfile`: named credential container — kind + routing fields (baseURL/model for proxy, awsRegion/awsProfile for bedrock), `fallbackModels`, per-profile `envOverrides`
- `Config`: global config row — `defaultProfileID`, `primaryAgentPreference` (`PrimaryAgentPreference`: `.claude`/`.codex`), `envSettingOverrides` (map of `ClaudeEnvSetting.id` → `ClaudeEnvValue`), `envOverrides` (free-form `[String: String]`), `autoArchiveOnMergeDefault`
- `Notification`: gained `terminalID` (optional `UUID`) — the terminal that triggered the notification
- `Note`: freeform editor content tied to a worktree
- `TabState`: persisted tab metadata (label, order)
- `SessionSummary` / session message types: parsed Claude JSONL transcript items
- `PRStatus`: PR number + URL + `PRMergeableState`
- `PaneContent` / `Tab` / `LayoutNode`: app-side pane tree (Codable, in `Sources/TBDApp/Terminal/`)

## Tmux Architecture

**Grouped sessions** (not control mode). Rationale in `docs/tmux-integration.md`.

```
tmux server: tbd-<djb2-hash-of-repo-path>
├── Session "main" (daemon-managed, persists across app restarts)
│   ├── Window @1: claude code
│   ├── Window @2: setup hook / shell
│   └── ...
└── Session "tbd-view-abc123" (grouped, created by app for viewing)
```

- Daemon creates windows in `main`; app creates grouped sessions per visible terminal panel
- Each grouped session shares all windows but has independent current-window and PTY size
- `main` persists when app closes; grouped sessions are ephemeral
- Server name uses djb2 hash of repo path (deterministic, survives DB recreations)
- Secrets/routing env reach windows via tmux's `-e KEY=VALUE` (`createWindow(sensitiveEnv:)`), keeping them out of `ps`

### TmuxManager API highlights
- `sendKeys` — literal text (tmux `-l`); `sendKey` — a key name like "Enter"; `sendCommand` — text + Enter
- `capturePaneOutput` / `capturePaneWithAnsi` — plain or ANSI-escaped snapshot
- `paneCurrentCommand` / `panePID` — used by `ClaudeStateDetector`
- `windowExists` — reconcile check; `dryRun` mode for tests

## Worktree Lifecycle

Split across files: base struct (`WorktreeLifecycle.swift`), `+Create`, `+Archive`, `+Reconcile`, `+Adopt`, `+Forget` (untrack without disk removal), `+PreSession` (pre-session hook terminals), `+Recovery` (resolve rows stuck in `.creating` after a crash/restart).

### Create (two-phase async)
**Phase 1 (beginCreateWorktree):** Resolve parent via `ParentResolver` → generate name → insert DB row with `status = .creating` → return immediately. App shows an optimistic placeholder before the RPC returns.

**Phase 2 (completeCreateWorktree):** Best-effort fetch → create base dir (`~/tbd/worktrees/<repo>/`) → git worktree add (retries with a new name on collision) → ensure tmux server → create windows with `TBD_*` env vars → insert terminals → status `.active`. On failure, deletes the DB row.

### Archive (two-phase async)
**Phase 1:** Validate not `.main`/`.creating` → status `.archived` + `archivedAt` → kill tmux windows → delete terminals → return. **Phase 2:** background — run archive hook → `git worktree remove`.

### Revive / Adopt
Revive recreates a worktree from an archived branch. Adopt (`worktree.adopt`) registers an existing on-disk git worktree into TBD (idempotent).

### Conflict Detection & Reconcile
Per-repo merge-tree conflict scan against the default branch updates `hasConflicts`. On startup, `reconcile` compares `git worktree list` against the DB, marks missing worktrees archived, adopts unknown ones, fixes stale tmux server names, and prunes dead terminal records. `breakCyclicParents` runs once at startup to repair any parent-pointer cycles.

## System Prompt Layers

`SystemPromptBuilder` builds the prompt context injected into spawned Claude sessions.
- `promptLayers(repo:worktree:)` returns env-var → value pairs: `TBD_PROMPT_CONTEXT` (always — describes the `tbd` CLI), `TBD_PROMPT_INSTRUCTIONS` (per-repo `customInstructions`, if set), `TBD_PROMPT_RENAME` (rename prompt, non-main un-renamed worktrees only).
- These are set as window env vars so child processes can re-inject them.
- `build(repo:worktree:isResume:)` joins the layers for the initial `--append-system-prompt`; returns `nil` for resumed sessions.

## Model Profiles

A model profile is a named credential container routing a spawned Claude session's auth. `CredentialKind`: `oauth` (isolated `CLAUDE_CONFIG_DIR`, user `/login`s), `apiKey` (`ANTHROPIC_API_KEY` from a 0600 token file under `~/tbd/`), `proxy` (api key + `ANTHROPIC_BASE_URL`/`ANTHROPIC_MODEL`), `bedrock` (`CLAUDE_CODE_USE_BEDROCK=1` + `AWS_REGION`/`AWS_PROFILE`, AWS credential chain). `ModelProfileResolver` chains per-terminal override → per-repo override → global default. The `+` menu can pick a profile explicitly; `ClaudeProfileConfigDirManager` isolates each profile's Claude config dir under `~/tbd/profiles/<id>/claude/`.

## SSH Agent Resolver

Maintains a stable symlink at `~/.ssh/tbd-agent.sock` pointing to a live SSH agent socket. Probes candidates from `/private/tmp/com.apple.launchd.*/Listeners` with `ssh-add -l`, updates the symlink atomically. Worktrees use `SSH_AUTH_SOCK=~/.ssh/tbd-agent.sock`.

## RPC Protocol

JSON-RPC style over Unix socket (newline-delimited) and HTTP POST `/rpc`. Method families (see `Sources/TBDDaemon/Server/RPCRouter+*Handlers.swift`):

- **Repo**: `repo.add`, `repo.remove`, `repo.list`, `repo.rename`, `repo.relocate`, `repo.updateInstructions`, `repo.listBranches`, hidden/expanded toggles
- **Worktree**: `worktree.create`, `.list`, `.archive`, `.revive`, `.adopt`, `.forget` (untrack without `git worktree remove`), `.rename`, `.reorder`, `.move` (reparent), `.selectionChanged`, `.suspend`, `.resume`, `.setAutoArchive`
- **Terminal**: `terminal.create` (`type`/`prompt`), `.list`, `.send` (`submit`), `.focus`, `.delete`, `.setPin`, `.output`, `.conversation`, `.transcript`, `.transcriptItemFullBody`, `.suspend`, `.resume`, `.recreateWindow`, `.swapProfile`, `.activityEvent` (internal — fired by the terminal-activity hook)
- **Tab**: `tab.setLabel`, `tab.setOrder`, `tab.list`, `worktree.setActiveTab`
- **Session**: `session.list`, `session.messages` — list/parse Claude JSONL transcripts; plus `terminal.sessionEvent` (SessionStart hook bridge)
- **AskUserQuestion**: `terminal.askUserQuestionPending` / `terminal.askUserQuestionCleared`, backed by `PendingQuestionStore`
- **Model profile**: `modelProfile.list`/`.add`/`.delete`/`.rename`/`.updateEndpoint`/`.updateBedrock`/`.setGlobalDefault`/`.setPrimaryAgentPreference`/`.setRepoOverride`/`.fetchUsage`/`.healthCheck`
- **Claude preferences**: `claude.setSpawnPreferences` — stores Claude spawn-env overrides (`ClaudeSpawnPreferences`) into the config row; handled by `RPCRouter+ClaudePreferencesHandlers.swift`
- **Env overrides**: `config.setEnvOverrides`, `repo.setEnvOverrides`, `modelProfile.setEnvOverrides` — persist free-form `[String: String]` env vars per scope; `config.get` reads the config row; `config.setAutoArchiveOnMergeDefault` sets the global auto-archive default. Handled by `RPCRouter+EnvOverridesHandlers.swift`
- **Appearance**: `appearance.updateColorFgBg` — fans out `COLORFGBG` env update to all active tmux servers; handled by `RPCRouter+AppearanceHandlers.swift`
- **Notification**: `notify`, `notifications.list`, `notifications.markRead`
- **PR**: `pr.list`, `pr.refresh`
- **Note**: `note.create`/`.get`/`.update`/`.delete`/`.list`
- **Legacy hooks**: `daemon.legacyHooksStatus`, `daemon.removeLegacyGlobalHooks`
- **Meta**: `daemon.status`, `resolve.path`, `cleanup`, `state.subscribe`, `app.setForegroundState`, `app.setMainAreaSize`

## CLI Commands

See `Sources/TBDCLI/Commands/`. Highlights:
- `tbd worktree create [--position child|sibling|root] [--branch] [--prompt|--prompt-file] [--no-wait] [--json]`, plus `list`, `adopt`, `archive`, `revive`, `rename`, `reparent`, `forget` (untrack without removing from disk), `auto-archive` (toggle archive-on-PR-merge)
- `tbd terminal create <worktree> [--type shell|claude|codex] [--cmd] [--prompt|--prompt-file] [--json]`, `send --terminal <id> --text <t> [--submit]`, `list`, `output`, `conversation`
- `tbd hooks status` — show the Claude overlay + legacy hook state; `tbd hooks stop-rename-check` — internal Stop-hook
- `tbd session-event`, `tbd terminal-activity`, `tbd ask-user-question pre|post` — internal hooks fired by the settings overlay
- `tbd config get|set` — show/set global settings (e.g. auto-archive-on-merge default, env overrides)
- `tbd link` — print a `tbd://` deep link for the current worktree
- `tbd doctor [--dry-run]` — diagnose and repair the `~/.local/bin/tbd` CLI install (checks that it is a hard link to the TBDCLI binary sibling of the running daemon; repairs stale or missing links)
- `tbd notify`, `tbd daemon status`, `tbd cleanup`, `tbd setup-hooks` (deprecated)
