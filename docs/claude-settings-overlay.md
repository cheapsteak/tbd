# Claude settings overlay

TBD spawns Claude Code with a `--settings` overlay file that carries its own
hooks. Two opt-in fragments — JSON object strings — can be deep-merged into
that overlay. TBD is a pure passthrough: it never interprets or validates the
fragment contents beyond "is it a JSON object". A terminal can also carry
extra plugin folders, which TBD passes to Claude Code as `--plugin-dir` (see
"Plugin folders").

## Scopes and precedence

Merged in order (later wins key collisions; object-valued keys recurse; lists join, earlier entries first, exact duplicates dropped):

1. **TBD hooks base** — the generated overlay body (hooks, optional
   `fallbackModel`).
2. **Repo fragment** — a plain JSON file at
   `~/tbd/repos/<repoID>/claude-settings.json`, alongside the repo's hooks
   and notes. Edited in the repo's settings pane ("Claude settings overlay",
   which shows the backing path with a copy button) or externally with any
   editor. An empty/whitespace save in the pane deletes the file; a missing
   file means no fragment.
3. **Per-spawn fragment** — the `claudeSettingsOverlay` param on
   `terminal.create` / `worktree.create`, or the `--claude-settings` flag on
   `tbd terminal create` / `tbd worktree create`. On a worktree create it
   goes to the primary Claude terminal. TBD keeps it with that terminal (see
   "When each applies").

Because lists join, a later layer cannot narrow or clear a list an earlier
layer set: for example, a terminal's `--claude-settings` cannot remove a deny
rule the repo file adds.

## When each applies

- The **repo fragment** is read fresh from the file at actual spawn time, so
  it applies on every Claude start — create, resume, hibernation wake,
  account switch, reopen and revive — and edits made while a preSession hook
  is still running are picked up by the spawn it gates. (recreate-window
  respawns as shell/codex, never Claude, so no overlay is involved there.)
- The **per-spawn fragment** is kept with its terminal, beside the terminal's
  plugin folders, and both apply on every start of that terminal's Claude
  session:
  - **Terminal create**, fresh or resuming a session by id, with the values
    that create passed. A resume by id that passes none starts without them:
    TBD never copies values from an older terminal. The app's History →
    Resume passes none.
  - **Worktree create** — the primary Claude terminal, whether it starts at
    once, after a preSession hook, or from recovery after a daemon restart
    during that hook.
  - **Wake** from hibernation, which also serves transport migration, a
    forced restart and reboot recovery.
  - **Account switch** — in place; cold, where the next wake applies them;
    and fork, which copies them to the new terminal.
  - **Reopen** from Closed Terminals. A Claude terminal's closed entry keeps
    its values; a shell's keeps none.
  - **Worktree revive** — inline, after a preSession hook, and by recovery.
    Archiving keeps each Claude session's values beside its session id, and
    each revived session starts with its own.
  - **Revive a conversation on a fresh branch**, which starts with the
    archived session's values.

  Continue in Claude from a Codex tab has no Claude values to carry.

## Plugin folders

- **Passing them** – `pluginDirs`, a list of paths, on `terminal.create` and
  `worktree.create`, or `--plugin-dir <path>`, repeatable, on
  `tbd terminal create` and `tbd worktree create`. On a worktree create they
  go to the primary Claude terminal and are ignored when the primary is
  Codex. A terminal create refuses them for any terminal that is not Claude.
- **What a path names** – a plugin folder, a folder of plugins, or a `.zip`:
  whatever Claude Code's `--plugin-dir` accepts. TBD checks only that the
  path exists.
- **Path rules** – on the socket a path must be absolute or start with `~/`.
  TBD expands `~/` once, at create, and stores the absolute path. The CLI
  turns a relative path into an absolute one against the shell's current
  folder before sending it. A create with a relative path on the socket, or
  with a path that does not exist, is refused.
- **Order** – TBD's own plugin folder comes first, then the terminal's in the
  order given, with duplicates dropped. Each is passed as its own
  `--plugin-dir`.
- **A folder missing at a later start** – skipped, with a warning logged
  (`com.tbd.daemon` / `claude-overlay`), and the start goes on. The folder
  stays stored, so it loads again once it is back.
- **When they apply** – at the same starts as the per-spawn fragment (see
  "When each applies").
- **Where they are stored** – with the terminal's per-spawn fragment, in
  `~/tbd/state.db`: on the terminal's row, on its Closed Terminals entry, and,
  while a worktree is archived, under each Claude session's id.
  `tbd terminal list --json` shows each terminal's values under
  `claudeSpawnExtras`.

## Malformed fragments

Each fragment parses independently. A malformed one is logged
(`com.tbd.daemon` / `claude-overlay`) and dropped — the spawn proceeds with
the remaining valid fragment(s), degrading at worst to hooks-only. A bad
fragment never aborts a spawn.

## Legacy column sweep

PR #452 briefly stored the repo fragment in the DB
(`repo.claude_settings_overlay`, migration v53). On startup the daemon runs
an idempotent sweep: any non-NULL column value is written to the overlay
file (unless the file already exists — the file wins) and the column is
NULLed. The column remains in the schema as a vestige.

## Caveat

Both fragments are written verbatim into the per-session overlay file, and
the per-spawn fragment is also stored as plain text in `~/tbd/state.db` — do
not put secrets in either.
