# Worktree Hooks

TBD can run scripts at key points in a worktree's lifecycle: before the agent session starts (`preSession`), when the worktree is created (`setup`), and just before it's archived (`archive`). The canonical place to declare them is the `.worktree-hooks/` directory at the root of your repo.

## Convention

Each hook is an executable file inside `.worktree-hooks/`, named after the event:

```
my-repo/
  .worktree-hooks/
    preSession  # runs to completion BEFORE the agent terminal spawns (blocking)
    setup       # runs in the new worktree right after it's created (parallel)
    archive     # runs in the worktree just before `git worktree remove`
```

Files must be executable (`chmod +x .worktree-hooks/setup`). They can be in any language — TBD just executes them.

## `preSession` vs `setup`

Both run on worktree creation — and again when an archived worktree is revived — but they sequence differently:

- **`preSession` is blocking.** Its terminal is created first, and the agent (Claude/Codex/shell) does not spawn until the hook exits. Use it for anything the agent must not start without — copying `.env` files, writing local config, linking caches.
- **`setup` is parallel.** It runs in its own terminal alongside the agent, which is already started. Use it for slow work the agent doesn't need on its first turn — `npm install`, warming build caches.

The split is your repo's choice; the rule of thumb is *preSession = "the agent must not start before this finishes"*. The `preSession` hook runs in a visible terminal tab (labeled `pre-session`), so you can watch its output live; the pane drops into a regular shell when the hook exits.

`preSession` has a 600-second timeout. A non-zero exit status or a timeout does **not** abort worktree creation or block the agent forever — TBD posts a notification and starts the agent anyway.

## Environment

Hooks run with `cwd` set to the worktree path and receive these environment variables:

| Variable | Value |
| --- | --- |
| `TBD_EVENT` | `preSession`, `setup`, or `archive` |
| `TBD_WORKTREE_ID` | UUID of the worktree |
| `TBD_TERMINAL_ID` | UUID of the terminal the hook runs in (`preSession` and `setup` only — `archive` runs outside a terminal and does not receive it) |
| `TBD_WORKTREE_NAME` | Worktree name (the stable checkout folder name, not the renameable display name) |
| `TBD_WORKTREE_PATH` | Absolute path to the worktree checkout |
| `TBD_REPO_PATH` | Absolute path to the source repo |
| `TBD_BRANCH` | Branch name |

Hooks have a 60-second timeout (`preSession`: 600 seconds). A non-zero exit status is logged but does not block the lifecycle action.

## Example

```bash
#!/bin/bash
# .worktree-hooks/preSession — the agent waits for this
set -euo pipefail

cp ../main-checkout/.env .env 2>/dev/null || true
```

```bash
#!/bin/bash
# .worktree-hooks/setup — runs in parallel with the agent
set -euo pipefail

npm install
```

## Resolution Priority

When TBD looks up a hook for an event, it returns the first match from this chain:

1. **App per-repo config** — `~/tbd/repos/<uuid>/hooks/<event>`, set via TBD's Settings UI.
2. **`.worktree-hooks/<event>`** — the canonical in-repo location described above.
3. **`conductor.json`** `scripts.<event>` — *deprecated*, kept for backward compatibility. TBD logs a warning when this path is used.
4. **`.dmux-hooks/<event-name>`** — *deprecated*, kept for backward compatibility. TBD logs a warning when this path is used.
5. **Global default** — `~/tbd/hooks/default/<event>`.

First match wins; there is no chaining. To migrate from `conductor.json` or `.dmux-hooks/`, move your scripts into `.worktree-hooks/<event>`, ensure they are executable, and remove the old files.

## Deprecation

`conductor.json` and `.dmux-hooks/` continue to work today but will be removed in a future release. Each time TBD resolves a hook from one of these locations, it logs a warning to the `com.tbd.daemon` / `hooks` log category — stream it with:

```
log stream --level debug --predicate 'subsystem == "com.tbd.daemon" AND category == "hooks"'
```
