# Worktree Hooks

TBD can run scripts at key points in a worktree's lifecycle: when it's created (`setup`) and just before it's archived (`archive`). The canonical place to declare them is the `.worktree-hooks/` directory at the root of your repo.

## Convention

Each hook is an executable file inside `.worktree-hooks/`, named after the event:

```
my-repo/
  .worktree-hooks/
    setup       # runs in the new worktree right after it's created
    archive     # runs in the worktree just before `git worktree remove`
```

Files must be executable (`chmod +x .worktree-hooks/setup`). They can be in any language — TBD just executes them.

## Environment

Hooks run with `cwd` set to the worktree path and receive these environment variables:

| Variable | Value |
| --- | --- |
| `TBD_EVENT` | `setup` or `archive` |
| `TBD_WORKTREE_ID` | UUID of the worktree |
| `TBD_WORKTREE_NAME` | Display name |
| `TBD_WORKTREE_PATH` | Absolute path to the worktree checkout |
| `TBD_REPO_PATH` | Absolute path to the source repo |
| `TBD_BRANCH` | Branch name |

Hooks have a 60-second timeout. A non-zero exit status is logged but does not block the lifecycle action.

## Example

```bash
#!/bin/bash
# .worktree-hooks/setup
set -euo pipefail

npm install
cp ../main-checkout/.env .env 2>/dev/null || true
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
