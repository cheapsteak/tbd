# Claude settings overlay

TBD spawns Claude Code with a `--settings` overlay file that carries its own
hooks. Two opt-in fragments — JSON object strings — can be deep-merged into
that overlay. TBD is a pure passthrough: it never interprets or validates the
fragment contents beyond "is it a JSON object".

## Scopes and precedence

Merged in order (later wins key collisions; object-valued keys recurse):

1. **TBD hooks base** — the generated overlay body (hooks, optional
   `fallbackModel`).
2. **Repo fragment** — a plain JSON file at
   `~/tbd/repos/<repoID>/claude-settings.json`, alongside the repo's hooks
   and notes. Edited in the repo's settings pane ("Claude settings overlay",
   which shows the backing path with a copy button) or externally with any
   editor. An empty/whitespace save in the pane deletes the file; a missing
   file means no fragment.
3. **Per-spawn fragment** — the `--claude-settings` flag on
   `tbd worktree create` / `tbd terminal create` (PR #451).

## When each applies

- The **repo fragment** is read fresh from the file at actual spawn time, so
  it applies on ALL spawn paths — fresh create, resume, hibernation wake,
  and profile swap — and edits made while a preSession hook is still running
  are picked up by the spawn it gates. (recreate-window respawns as
  shell/codex, never Claude, so no overlay is involved there.)
- The **per-spawn fragment** applies at fresh spawn only; resumes and wakes
  do not reapply it.

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

The repo fragment is written verbatim into the per-session overlay file —
do not put secrets in it.
