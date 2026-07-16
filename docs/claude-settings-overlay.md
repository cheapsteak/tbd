# Claude settings overlay

TBD spawns Claude Code with a `--settings` overlay file that carries its own
hooks. Two opt-in fragments — JSON object strings — can be deep-merged into
that overlay. TBD is a pure passthrough: it never interprets or validates the
fragment contents beyond "is it a JSON object".

## Scopes and precedence

Merged in order (later wins key collisions; object-valued keys recurse):

1. **TBD hooks base** — the generated overlay body (hooks, optional
   `fallbackModel`).
2. **Repo fragment** — per-repo config, edited in the repo's settings pane
   ("Claude settings overlay") and stored on the repo row
   (`claude_settings_overlay`, plain text). Empty/whitespace clears it.
3. **Per-spawn fragment** — the `--claude-settings` flag on
   `tbd worktree create` / `tbd terminal create` (PR #451).

## When each applies

- The **repo fragment** is read fresh from the repo row at every Claude
  spawn, so it applies on ALL spawn paths: fresh create, resume,
  hibernation wake, recreate-window*, and profile swap.
  (*recreate-window respawns as shell/codex, never Claude, so no overlay
  is involved there.)
- The **per-spawn fragment** applies at fresh spawn only; resumes and wakes
  do not reapply it.

## Malformed fragments

Each fragment parses independently. A malformed one is logged
(`com.tbd.daemon` / `claude-overlay`) and dropped — the spawn proceeds with
the remaining valid fragment(s), degrading at worst to hooks-only. A bad
fragment never aborts a spawn.

## Caveat

The repo fragment is stored as plain text in `~/tbd/state.db` and written
verbatim into the per-session overlay file — do not put secrets in it.
