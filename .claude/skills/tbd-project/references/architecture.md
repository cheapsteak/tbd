# TBD Architecture

## System Overview

Three components, one SPM package. All daemon-managed paths live under `~/tbd/` (no dot — `TBDConstants.configDir`, overridable via `TBD_HOME`).

### tbdd (Daemon)
Long-running headless process. Owns all state and logic.
- **SQLite** at `~/tbd/state.db` — worktree ledger, repo list, terminals, notes, tabs, model profiles (WAL mode, GRDB)
- **Unix socket** at `~/tbd/sock` — the RPC interface
- **Pty holders** — every session's pty master is owned by its own `TBDHolder` process, which `HolderSpawner` starts and `HolderRegistry` re-adopts after a daemon restart; the daemon drains and emulates a session no viewer has open (see "Session Transport")
- **Leftover tmux rows** — rows an earlier version left on tmux: `LeftoverTmuxServerProbe` judges whether each one's tmux server still runs, and `TmuxResumeGate` refuses a start that could put a second agent on a session such a server may still run. TBD runs no tmux command (see "Session Transport")
- **Git manager** — fetch, worktree add/remove/list, conflict check, headSHA, merge-base ancestry
- **Hook resolver** — resolves and runs worktree lifecycle hooks per priority chain
- **Worktree lifecycle** — orchestrates create/archive/revive/adopt/reconcile + conflict detection, parent/lineage resolution
- **PR status manager** — polls GitHub for PR state (open/merged/closed, mergeable) per worktree, persists last-known status to the DB so icons survive restart
- **Auto-archive-on-merge coordinator** — archives a worktree automatically once its PR merges, when armed per-worktree or via the global default
- **SSH agent resolver** — finds live SSH agent socket, maintains `~/.ssh/tbd-agent.sock` symlink
- **Hibernation coordinator** — parks Claude sessions on the pty holder and wakes them with `claude --resume` there. It refuses to park a live tmux row. A person's wake of a session parked on tmux moves it to the holder first (`RPCRouter.moveParkedTmuxRowBeforeWake`, through `TerminalTransportMigrator.migrate`) and resumes it there; a rail's wake of one moves nothing and is refused, naming the gestures that move it. Parks come from "Hibernate now" (`terminal.hibernate`), from the idle sweep and park-on-merge (both off by default), and from the in-place profile swap; the session mod is a park's only guard for an unsent draft. A session parked by hand wakes only when asked; an automatic park also wakes when its worktree is focused
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
- **Terminal rendering** — attaches to each session's pty holder; a live tmux row shows a notice instead of a terminal (see "Session Transport"); customizable font, colors, cursor; user-defined themes via `ThemeStore` + `UserTerminalTheme` (importable from Alacritty TOML format via `AlacrittyImporter`, watched for on-disk changes by `ThemeDirectoryWatcher`)
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
- Subcommands: `repo`, `worktree`, `config`, `terminal`, `notify`, `session-event`, `ask-user-question`, `daemon`, `hooks`, `setup-hooks` (deprecated), `cleanup`, `link`, `doctor`
- `session-event`, `ask-user-question` and `hooks session-title` are internal — invoked by the Claude settings-overlay hooks, not by humans

## Session Instrumentation

TBD instruments the agent sessions it spawns. At `Daemon.start()`:

- **`PluginDirWriter`** writes a Claude Code plugin to `~/Library/Application Support/TBD/plugin/` containing `.claude-plugin/plugin.json` and `skills/tbd/SKILL.md`. The skill body is `TBDSkillContent.body`. While a session-mod feature flag is on, it also writes the session mod — the hooks module in `hooks/` and its `$.state` contract in `types/`, which the manifest names — from `SessionModContent` (generated from `SessionMod/` by `scripts/gen-session-mod-content.py`), and removes both when every flag is off. It runs after the database opens (the flags live there) and before any spawn path, writes only files whose bytes changed (each write hot-reloads the plugin in running sessions), and is skipped in mock mode. The daemon half of the mod — `spawn.json` and the other per-session files under `~/tbd/sessions/<claudeSessionID>/`, liveness, the spawn variables and the composer-draft park gate's status — lives in `Sources/TBDDaemon/SessionMod/`.
- **`ClaudeHookOverlay`** writes `~/tbd/runtime/claude-overlay.json` registering `SessionStart`, `Stop` (×2), `StopFailure`, `UserPromptSubmit` (session title), `AskUserQuestion` Pre/PostToolUse, `PostToolUse:Bash` (PR binding) and `SessionEnd` hooks. None reports agent state.
- **`SkillFileWriter`** drops the same skill body to a failsafe path so a session can `Read` it even with no harness skill registered.
- **`ClaudeSpawnCommandBuilder`** (pure function) builds the `claude` command, appending `--plugin-dir` and `--settings` (each only if the file exists). It also returns `sensitiveEnv` carrying auth/routing vars (`ANTHROPIC_API_KEY`, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_BASE_URL`, `CLAUDE_CODE_USE_BEDROCK`, ...) — passed as the pty-holder job's process environment, never inlined in the command, so secrets never appear in `ps` argv.
- **`CodexHomeManager`** does the equivalent for Codex sessions via a per-repo isolated `CODEX_HOME`.

The `SessionStart` hook calls `tbd session-event`, which RPCs the daemon with the new session id + transcript path; the daemon updates the terminal record and broadcasts `terminalSessionUpdated` so the transcript pane retargets after `/clear` or `/compact`.

Agent state comes only from the agents themselves. Claude Code and Codex report it over the Program Status Protocol (OSC 7501) on pty-holder sessions; whichever reader owns the pty (the app's terminal view, which forwards over `terminal.programStatusReport`, or the daemon's headless emulator) hands it to `ProgramStatusStore`. The store keeps the latest snapshot in memory and is the only writer of a terminal's `activityState` and wait-reason columns, mapped by `ProgramStatusColumn.swift`; it also raises the attention banner and stamps the PR-poll activity ledger. A session that cannot report (any agent on tmux, or an older agent) reads `unknown`: the idle sweep leaves it alone, and `session.states` names the cause. Design: `docs/specs/2026-10-30-osc-only-agent-status-design.md`.

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

## Session Transport

Every session opens on the pty holder (`TerminalSpawnTransport.decide`); a daemon with no `TBDHolder` beside it refuses the spawn. One `TBDHolder` process per session forks the job and owns its pty master for the session's whole life, so the session survives daemon and app restarts and crashes of both. `HolderSpawner` starts it with the launch request on a file descriptor, never on a command line `ps` can read, and the daemon reaches it over its rendezvous socket under `~/tbd/holders/`. `HolderRegistry` owns a `HolderReader` per session, the daemon's drain loop and headless emulator, and re-adopts every live holder at startup. While a person has the session open, the app takes the pty master over the fd sidecar (`FDSidecarClient`) and reads and writes it directly; the daemon's reader stands down until the app hands it back, and a daemon-originated write reaches the session through the app meanwhile (`HolderInjectionCourier`). `tbd terminal output` reads whichever of the two is live (`HolderScreenResolver`). Design: `docs/specs/2026-08-30-pty-holder-session-transport-design.md`. `AgentReaper` sweeps the children of dead holders, and `OrphanGC` their rendezvous files.

### Leftover tmux rows

TBD does not drive tmux: it runs no tmux command, and cannot show a tmux session, send to one, park one or end one. A row still recorded as `tmux`, left by an earlier version, is one of two kinds:

- **Parked** – a person's wake (any actor whose kind is not `daemon`, `TransportMigrationOnWake.isPersonStarted`) rewrites the row onto the holder and resumes it there in one step, after start admission is asked; `tbd terminal migrate` rewrites it alone, and the next wake resumes it. A rail's wake is refused and names both gestures. A row whose park is still in flight (`pendingSessionIncarnationID` set) may still be running its agent, so the migration probes its tmux server first, as for a live row, and refuses it while the server may run.
- **Live** – judged by its tmux server (`LeftoverTmuxServerProbe`, no tmux binary): `AF_UNIX` connects to each place its socket may be, then, only when every one is absent, this user's tmux processes in the process table that name the server. Reconcile (at startup, on demand, and hourly for scratch worktrees' rows while GC is on), the app's Check Again (`terminal.recreateWindow`) and `tbd terminal migrate` each probe. Once the server is gone the row is parked with its session kept (a row with nothing to resume is deleted), and a migrate goes on to wake it on the holder. While the server may still be running, the row stays live, the app shows `LeftoverTmuxSessionNotice` in place of a terminal with the `tmux -L <server> kill-server` command that ends it, and a migrate refuses with `terminalOnTmux`.

The probe is a transition measure, replaced by parking on sight on 2027-01-15. The rule and its rejected alternatives: `docs/specs/2026-10-11-holder-transport-migration-design.md`, "A live row whose tmux server outlived the update".

What TBD still does with tmux:

- Server names use the djb2 hash of the repo path (`TmuxServerName.forRepoPath`), deterministic and surviving DB recreation; the probe and the notice both name the server this way.
- Closing a tmux row's tab — or archiving or forgetting its worktree, deleting or archiving a scratch space, or reconcile's archive of a worktree gone from git — deletes the row and runs no tmux command (`WorktreeLifecycle.closeLeftoverTmuxRow`). A live row's session keeps running in its server, and so may that of a row parked with its park in flight; either, with a session id, gets a Closed Terminals entry with no screen, marked with that server (`TerminalHistoryEntry.liveOnTmuxServer`, outside the 50-entry prune). A parked row whose park is complete (`WorktreeLifecycle.sessionHasEnded`) gets an entry with the screen the park stored and no mark. A mark that cannot be written keeps the row (`LeftoverTmuxMarkUnwritable`): closing the tab fails, and the app shows the daemon's message and brings the terminal back as a tab of its own at the end of the strip; an archive or a scratch archive is refused with the worktree, its sessions and every row as they were, though the Closed Terminals entries already written for its other tmux rows stay, as every tmux row's does when an archive's status write fails after its marks; and reconcile's archive leaves the worktree for its next sweep.
- Every start of an existing session on the holder asks the resume gate (`TmuxResumeGate`), keyed by session id: one indexed read of the tmux rows whose session may still run, unparked or with a park in flight (`TerminalStore.liveTmuxServers`, a row's server being its worktree's), and one of the marked entries, and the probe only for a server they name, plus, for a revive of an archived worktree that resumes a session, the worktree's own server. A parked tmux row with no park in flight is not asked about, and a spawn that forks a Claude session (`forksSession`) asks nothing. While that server may be running, the start refuses with `terminalOnTmux` and the kill-server advice and writes nothing. The gate sits in `WorktreeLifecycle.spawnTerminal`, which every new row passes, and in `HibernationCoordinator.wake`; a revive in place, a fresh-branch revive of a Codex thread, `terminal.create` resuming a session (`session.resume`) and a Closed Terminals reopen also ask before their first write. Archive keeps a live tmux row's tab in the archived record, so a revive brings every tab back on the holder once the server is gone. The gate covers a session an open tmux row names, one whose row was closed with a mark, and every session a revive of an archived worktree resumes: an earlier build's archive wrote no mark and could leave an agent running in the worktree's server (it skipped the kill when it could not confirm the pane was the tab's own, and a kill could fail), so a revive in place or its retry, with or without the History pane's preferred session, and a fresh-branch revive of a Codex thread ask about that server whatever the records say, once per revive, and are refused while it may run. A revive that resumes nothing and a Claude fresh-branch revive, which forks, ask nothing. A repo's worktrees share the server, so a leftover server refuses those revives across its repo until it ends. The gate lets through a session that may still run in tmux with neither a row nor a mark, outside a revive: a repo removal's main-worktree rows, which go with the worktree row (`WorktreeStore.deleteForRepo`) unmarked; a forget or scratch delete, which removes the worktree's entries; and a row whose worktree has no local row, which names no server. A start without the gate puts the same second agent on each.

How TBD used to serve tmux sessions, and the case against tmux control mode: `docs/tmux-integration.md`, kept as the design record.

## Worktree Lifecycle

Split across files: base struct (`WorktreeLifecycle.swift`), `+Create`, `+Archive`, `+Reconcile`, `+Adopt`, `+Forget` (untrack without disk removal), `+PreSession` (pre-session hook terminals), `+Recovery` (resolve rows stuck in `.creating` after a crash/restart).

### Create (two-phase async)
**Phase 1 (beginCreateWorktree):** Resolve parent via `ParentResolver` → generate name → insert DB row with `status = .creating` → return immediately. App shows an optimistic placeholder before the RPC returns.

**Phase 2 (completeCreateWorktree):** Best-effort fetch → create base dir (`~/tbd/worktrees/<repo>/`) → git worktree add (retries with a new name on collision) → spawn each tab on a pty holder with `TBD_*` env vars and insert its terminal row (a setup tab only when a setup hook resolves) → status `.active`. On failure, including a daemon with no `TBDHolder` beside it, which refuses every spawn, deletes the DB row.

### Archive (two-phase async)
**Phase 1:** Validate not `.main`/`.creating` → refuse a folder with uncommitted changes or an unreadable `git status` (`WorktreeArchiveError.uncommittedChanges`, RPC code `worktreeArchiveUncommitted`; lifted by `force`, which also skips the hook, or by `discardUncommittedChanges`, which does not; auto-archive on merge keeps the worktree and notifies) → status `.archived` + `archivedAt` → tear down each terminal (dispose its holder; a tmux row runs no tmux command, as under "Leftover tmux rows") → delete terminals → return. **Phase 2:** background — run archive hook → `git worktree remove`.

### Revive / Adopt
Revive recreates a worktree from an archived branch. Adopt (`worktree.adopt`) registers an existing on-disk git worktree into TBD (idempotent).

### Conflict Detection & Reconcile
Per-repo merge-tree conflict scan against the default branch updates `hasConflicts`. On startup, `reconcile` compares `git worktree list` against the DB, marks missing worktrees archived, logs (but does not adopt) git worktrees under TBD's worktree directories that have no row (`tbd worktree adopt <path>` opts one in), prunes dead terminal records, and parks a live tmux row once its tmux server is gone (see "Leftover tmux rows"). `breakCyclicParents` runs once at startup to repair any parent-pointer cycles.

## System Prompt Layers

`SystemPromptBuilder` builds the prompt context injected into spawned Claude sessions.
- `promptLayers(repo:worktree:)` returns env-var → value pairs: `TBD_PROMPT_CONTEXT` (always — describes the `tbd` CLI), `TBD_PROMPT_INSTRUCTIONS` (per-repo `customInstructions`, if set), `TBD_PROMPT_RENAME` (rename prompt, non-main un-renamed worktrees only).
- These are set as window env vars so child processes can re-inject them.
- `build(repo:worktree:isResume:)` joins the layers for the initial `--append-system-prompt`; returns `nil` for resumed sessions.

## Model Profiles

A model profile is a named credential container routing a spawned Claude session's auth. `CredentialKind`: `oauth` (isolated `CLAUDE_CONFIG_DIR`, user `/login`s), `apiKey` (`ANTHROPIC_API_KEY` from a 0600 token file under `~/tbd/`), `proxy` (api key + `ANTHROPIC_BASE_URL`/`ANTHROPIC_MODEL`), `bedrock` (`CLAUDE_CODE_USE_BEDROCK=1` + `AWS_REGION`/`AWS_PROFILE`, AWS credential chain). `ModelProfileResolver` chains per-terminal override → per-repo override → global default. The `+` menu can pick a profile explicitly; `ClaudeProfileConfigDirManager` isolates each profile's Claude config dir under `~/tbd/profiles/<id>/claude/`.

## SSH Agent Resolver

Maintains a stable symlink at `~/.ssh/tbd-agent.sock` pointing to a live SSH agent socket. When the symlink is stale, probes candidates with `ssh-add -l` in this order: launchd's own answer (`launchctl getenv SSH_AUTH_SOCK`), then the `SSH_AUTH_SOCK` the daemon was started with (skipped when it is the symlink or leads to it), then `com.apple.launchd.*/Listeners` sockets under `/private/tmp` and `/private/var/run` (macOS 27 uses the latter), newest first. A socket named by more than one source is probed once. Updates the symlink atomically. Worktrees use `SSH_AUTH_SOCK=~/.ssh/tbd-agent.sock`.

## RPC Protocol

JSON-RPC style over the Unix socket (newline-delimited). Method families (see `Sources/TBDDaemon/Server/RPCRouter+*Handlers.swift`):

- **Repo**: `repo.add`, `repo.remove`, `repo.list`, `repo.rename`, `repo.relocate`, `repo.updateInstructions`, `repo.listBranches`, hidden/expanded toggles
- **Worktree**: `worktree.create`, `.createFailure` (why a recent create failed; in-memory, for the CLI), `.list`, `.archive`, `.revive`, `.adopt`, `.forget` (untrack without `git worktree remove`), `.rename`, `.reorder`, `.move` (reparent), `.suspend`, `.resume`, `.setAutoArchive`
- **Terminal**: `terminal.create` (`type`/`prompt`), `.list`, `.send` (`submit`), `.focus`, `.delete`, `.setPin`, `.output`, `.conversation`, `.transcript`, `.transcriptItemFullBody`, `.suspend`, `.resume`, `.recreateWindow`, `.swapProfile`, `.sessionTitle` (internal — fired by the `UserPromptSubmit` hook), `.programStatusReport` / `.programStatusList` (OSC 7501 reports forwarded by the app, and the store's snapshots)
- **Tab**: `tab.setLabel`, `tab.setOrder`, `tab.list`, `worktree.setActiveTab`
- **Session**: `session.list`, `session.messages` — list/parse Claude JSONL transcripts; plus `terminal.sessionEvent` (SessionStart hook bridge)
- **AskUserQuestion**: `terminal.askUserQuestionPending` / `terminal.askUserQuestionCleared`, backed by `PendingPromptStore`
- **Model profile**: `modelProfile.list`/`.add`/`.delete`/`.rename`/`.updateEndpoint`/`.updateBedrock`/`.setGlobalDefault`/`.setPrimaryAgentPreference`/`.setRepoOverride`/`.fetchUsage`/`.healthCheck`
- **Claude preferences**: `claude.setSpawnPreferences` — stores Claude spawn-env overrides (`ClaudeSpawnPreferences`) into the config row; handled by `RPCRouter+ClaudePreferencesHandlers.swift`
- **Env overrides**: `config.setEnvOverrides`, `repo.setEnvOverrides`, `modelProfile.setEnvOverrides` — persist free-form `[String: String]` env vars per scope; `config.get` reads the config row; `config.setAutoArchiveOnMergeDefault` sets the global auto-archive default. Handled by `RPCRouter+EnvOverridesHandlers.swift`
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
- `tbd session-event`, `tbd ask-user-question pre|post`, `tbd hooks session-title` — internal hooks fired by the settings overlay
- `tbd config get|set` — show/set global settings (e.g. auto-archive-on-merge default, env overrides)
- `tbd link [<worktree>] [--terminal <uuid> | --this-terminal] [--https]` — print a `tbd://` deep link for a worktree (default: current), optionally anchored to one terminal's tab; `--https` prints the shareable redirector form
- `tbd doctor [--dry-run]` — diagnose and repair the `~/.local/bin/tbd` CLI install (checks that it is a hard link to the TBDCLI binary sibling of the running daemon; repairs stale or missing links)
- `tbd notify`, `tbd daemon status`, `tbd cleanup`, `tbd setup-hooks` (deprecated)
