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

The split is your repo's choice; the rule of thumb is *preSession = "the agent must not start before this finishes"*. The `preSession` hook runs in a visible terminal tab (labeled `pre-session`), so you can watch its output live. That tab is **ephemeral on success**: once the hook exits 0 and the agent terminals exist, TBD closes it automatically. If the hook exits non-zero, times out, or its pane gets killed, the tab is left open instead — dropped into a regular shell with the hook's output still on screen — and TBD raises an error notification.

`preSession` has a 600-second timeout. A non-zero exit status, a timeout, or a killed pane does **not** abort worktree creation or block the agent forever — TBD posts a notification and starts the agent anyway, leaving the hook's tab open as described above.

## Re-running `preSession`

You can re-run a worktree's `preSession` hook at any time, without recreating the worktree: right-click it in the sidebar and choose **Re-run setup hook**. It runs in a fresh background tab that does not steal focus, and it does not disturb anything already running — no restart, no hibernation, no status change. The menu item only appears when a `preSession` hook actually resolves for that worktree; where none does, it's simply absent from the menu.

Only one run is allowed per worktree at a time. Triggering a second one while the first is still in flight is refused with: `Setup hook is already running for this worktree.`

Scratch spaces can run a `preSession` hook too. Previously they couldn't, because hook spawning required a backing repo. A scratch space has no repo, so for it `TBD_REPO_PATH` (see below) falls back to the worktree's own path.

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

`preSession` and `setup` hook terminals additionally run with `DISABLE_AUTO_UPDATE=true` in their process environment, so oh-my-zsh's interactive "Would you like to update?" prompt can't block the hook. This applies only when the hook actually exists — a hook-less "Setup" tab is a plain shell — and regular shell/agent tabs are unaffected and keep omz update checks.

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
