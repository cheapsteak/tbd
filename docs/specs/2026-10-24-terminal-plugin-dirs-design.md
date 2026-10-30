# Plugin folders and settings that stay with a terminal

TBD starts Claude Code sessions in terminals, and it starts them again later: a wake from
hibernation, an account switch, a reopen from Closed Terminals, a worktree revive. A starter
can give a session extra settings today, but only its first start gets them. This spec lets
a starter give a terminal **extra plugin folders** as well, and makes TBD **reapply both the
plugin folders and the settings on every start** of that terminal's Claude session.

## Why

- **A starter's settings last for the first start only.** `terminal.create` and
  `worktree.create` take `claudeSettingsOverlay`, a settings fragment merged into the
  session's `--settings` file. Every later start drops it: wake (which also serves
  transport migration, a forced restart and reboot recovery), account switch, reopen,
  worktree revive, and a resume by session id through `terminal.create`. A starter that
  depends on those settings — permission deny rules, guard hooks — gets a session with fewer
  limits than it asked for, and nothing says so. PR #451 recorded this as a known ceiling.
  Callers work around it by writing into the worktree's `.claude/settings.local.json`, which
  writes into the user's tree.
- **There is no way to load an extra plugin in one session.** TBD passes only its own plugin
  with `--plugin-dir`. Environment overrides can carry `CLAUDE_CODE_PLUGIN_DIRS`, but their
  scopes (global, repo, model profile) reach every session in that scope.
- **What Claude Code does** (measured on 2.1.310 with the zero-token stub):
  - `--plugin-dir` can repeat; each folder loads.
  - A missing `--plugin-dir` folder is skipped without a message, exit 0.
  - `CLAUDE_CODE_PLUGIN_DIRS` in a `--settings` file's `env` block also loads the plugin,
    interactive and headless. But the variable then reaches every child process — hook
    commands and Bash tool commands both see it — so a nested `claude` loads the plugin too.
    A settings `env` value also replaces a user's own value rather than adding to it.
- **TBD's settings merge drops entries.** It recurses into objects but replaces lists. A
  fragment that sets `hooks.PreToolUse` or `hooks.PostToolUse` removes TBD's own hooks for
  that event (the AskUserQuestion bridge, the PR binding after `gh pr create`), and a
  terminal's `permissions.deny` replaces the repo file's deny list. Claude Code itself joins
  lists across its settings scopes.

## User story

As a program that starts Claude sessions in TBD terminals for its tasks, I want each session
to load my plugin and my settings on every start TBD makes, so that I hear every turn end and
my guard rules always apply, without editing an account's profile or the worktree's files.

## Non-goals

- **Codex sessions.** Codex has no `--plugin-dir`; TBD instruments it through its own
  `CODEX_HOME`.
- **App UI.** The values are set through the socket and the CLI.
- **A verb that changes a live terminal's values.** A starter that wants new values closes
  the terminal and resumes the session by id with them.
- **Named, reusable setups.** See "Considered and deferred".

## Design

### Starting a session

- `terminal.create` and `worktree.create` take a new `pluginDirs` (a list of paths) beside
  the existing `claudeSettingsOverlay`. On `worktree.create` both apply to the primary Claude
  terminal.
- `tbd terminal create` and `tbd worktree create` take `--plugin-dir <path>`, repeatable,
  beside the existing `--claude-settings`.
- Each path names a plugin folder, a folder of plugins, or a `.zip` — whatever Claude Code's
  `--plugin-dir` accepts. TBD checks only that the path exists; Claude Code judges the rest.
- On the socket a path must be absolute or start with `~/`. TBD expands `~/` once, at
  create, and stores the absolute path, so `tbd terminal list` shows the real location. The
  CLI turns a relative path into an absolute one against the shell's current folder before
  sending it: a stored relative path would point somewhere else at a later start, because the
  CLI, the app and the daemon each run in a different folder.
- A create with a relative path on the socket, or a path that does not exist, is
  **refused**, since the starter is there to see the error.
- `terminal.create` with `resumeSessionID` honors the values it is given; today it drops the
  overlay on purpose. With none, the session starts without them: TBD does not
  copy them from an older row, which may be gone, and "nothing passed" keeps one meaning.
  The app's History → Resume takes this path and passes nothing, so it starts without them.

### What one start gets

Settings layers apply in this order; a later layer wins a key clash:

1. TBD's own settings (its hooks, a profile's `fallbackModel`).
2. The repo's `~/tbd/repos/<repoID>/claude-settings.json`, read fresh at every start.
3. The terminal's `claudeSettingsOverlay`.

Settings merge by one rule, used for every layer: objects merge key by key,
**lists join** in layer order with exact duplicates dropped, and any other value is replaced
by the later layer. This matches how Claude Code combines its own settings scopes. It fixes
the dropped-entries bug: a terminal's `PreToolUse` hooks run beside TBD's, and its
`permissions.deny` adds to the repo's. A later layer cannot remove a list entry an earlier
layer added. TBD's own `fallbackModel` list joins a layer's list the same way, TBD's models
first.

Plugin folders: TBD's own folder first, then the terminal's, duplicates dropped, each passed
as one `--plugin-dir`.

### What TBD stores

TBD stores the values the starter passed, unchanged, so it can apply them to starts the
starter does not make. They are kept together as one JSON object,
`{"claudeSettingsOverlay": <string>, "pluginDirs": [<path>, ...]}`, with either key
omitted when it was not passed. New keys can join the object later without a migration.

Three new columns, one per table:

- **`terminal`** — the object. The pre-session hook's terminal is an ordinary `terminal` row,
  so it carries one too: a primary Claude started by recovery after a daemon restart during a
  pre-session hook reads it from there.
- **`terminal_history`** — the object, copied when the terminal closes.
- **`worktree`** — a map from Claude session id to the object, written in the archive
  transaction beside `archivedClaudeSessions` and cleared with it on revive.

Each column is nullable TEXT with no SQL default; old rows read NULL, meaning "nothing
stored", and an object that does not decode reads as nothing stored, with a warning. Each
column dies with its row, so no new reconciler is needed. The migration, the GRDB records
and the shared `Models.swift` types change in one commit.

The overlay is stored as plain text in `~/tbd/state.db`, like the repo settings file and
environment overrides; it must not hold secrets.

### Which starts reapply the values

Every start of the terminal's Claude session reads its stored values:

- **Terminal create**, fresh or resuming by id (with the values passed).
- **Worktree create**: the direct primary spawn, the pre-session phase-3 spawn, and recovery
  after a daemon restart.
- **Wake** from hibernation — which also serves transport migration, a forced restart and
  reboot recovery. Wake and account switch plan their settings file through
  `ReplacementSpawnOverlay`, which gains the stored overlay.
- **Account switch**: in place (same row), cold (a parked row re-homed; its next wake reads
  the row) and fork (a new row and session id; the values are copied to the new row).
- **Reopen from Closed Terminals**, from the history row.
- **Worktree revive**, inline, after a pre-session hook, and by recovery — all through
  `spawnPrimaryTerminals`, which reads the archived map.
- **Revive a conversation on a fresh branch**, which looks up the archived session's values
  in the same map.

**Continue in Claude** from a Codex tab has no Claude values to carry and is unchanged.

### When something is missing

- **A plugin folder does not exist at a later start**: it is skipped, a warning is logged,
  and the start goes on; the terminal is not marked. Refusing would strand a wake that runs
  with nobody watching, and Claude Code would skip the folder silently anyway. The folder
  stays stored, so it loads again once it is back.
- **A malformed overlay**: dropped and logged, as today. A bad value never blocks a start.

### Seeing it

- `tbd terminal list --json` shows each terminal's `claudeSettingsOverlay` and `pluginDirs`.
- Logs: `com.tbd.daemon`, category `claude-overlay`.

### Behavior changes for existing callers

- A `claudeSettingsOverlay` passed today now lasts for every later start, not only the
  first.
- The list-joining merge applies to the repo settings file too: its lists now add to TBD's
  instead of replacing them.

### No feature flag

Nothing changes until a starter passes plugin folders or an overlay; joining lists is a bug
fix; and keeping the overlay lifts the limit PR #451 recorded as a known ceiling. None of it
acts without a gesture, kills a process, or removes state.

## Testing

All tests run under `scripts/test.sh`.

- **Merge**: lists join with duplicates dropped; TBD's `PreToolUse` and `PostToolUse` hooks
  survive a layer that sets the same events; `permissions.deny` from the repo file and the
  terminal join.
- **Command builder**: several `--plugin-dir` flags, TBD's first; missing folders skipped
  through the injected `fileExists`.
- **Storage**: old rows read NULL; terminal, pre-session row, history and the archived map
  round-trip.
- **Start paths**: each start listed above reapplies the stored values, through the existing
  spawn-capturing harnesses — including resume by id with and without values, the fork arms,
  pre-session recovery, and a wake whose plugin folder was deleted (skipped, start goes on).
- **Create validation**: a relative or missing path is refused; `~/` is expanded and stored
  absolute.
- **CLI**: repeated `--plugin-dir` parses, relative paths become absolute against the current
  folder, and the values reach the params.

## Delivery

Two PRs, the second stacked on the first:

1. **fix:** join lists when merging settings layers. It helps current users at once: a repo
   settings file or an overlay with hooks or deny rules stops removing TBD's hooks and the
   repo's rules.
2. **feat:** plugin folders and settings kept with the terminal and reapplied on every start.
   Keeping guard settings on every start relies on the merge no longer dropping entries.

Separate PRs keep each review small and let either be reverted alone.

Docs: `docs/claude-settings-overlay.md` covers the kept overlay, the plugin folders and the
merge rule; the bundled `tbd` skill learns `--plugin-dir`.

## Considered and deferred

**Named presets.** Files such as `~/tbd/presets/<name>.json`, each listing plugin folders and
settings, with a `base` that every start gets and a `default` used when the starter names
none; a terminal would store only the preset's name, and every start would read the file
again, so an edited preset would reach a parked terminal at its next wake. Repos could commit
presets too. Deferred because no caller needs named setups yet: the one real caller passes
its values on every start it makes, and stored values cover the starts TBD makes on its own.
Presets also carry the most risk — plugins named by repo content, precedence between a
repo's and a user's `base`, and a move of the repo settings file into the new scheme. The
layer order leaves room for them: a preset layer would sit between the repo settings file
and the terminal's own values.

## Rejected alternatives

- **`CLAUDE_CODE_PLUGIN_DIRS` in the overlay's `env` block** instead of a `pluginDirs`
  param. It works in Claude Code 2.1.310, but the variable reaches every child process,
  replaces a user's own value, and hides the folder from TBD.
- **A launch hook script that prints each start's values.** It costs a process on every start
  and can hang or fail, where stored values cannot.
- **Keying stored values by Claude session id.** A terminal's session id changes on `/clear`
  and `/compact`, so every rollover would need a copy; a terminal row stays put.
- **Reapplying on the same terminal row only.** People bring sessions back through worktree
  revive and Closed Terminals; values that drop there drop silently.
