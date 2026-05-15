# Generic `.worktree-hooks/` Convention

**Date:** 2026-05-15
**Status:** Approved, ready for implementation plan

## Goal

Introduce a generic, product-name-free in-repo hooks directory — `.worktree-hooks/` — as the canonical way for repos to declare worktree lifecycle hooks. Demote the existing `conductor.json` and `.dmux-hooks/` integrations to backward-compatibility fallbacks that emit a deprecation warning when used.

## Motivation

`HookResolver` currently bakes in two specific product names: Conductor (`conductor.json`) and dmux (`.dmux-hooks/`). Both products are vestigial in this codebase — Conductor was retired in commit `6cb865b` and the dmux skill notes it is no longer in use. A repo that uses neither product has no in-repo way to declare hooks; the only options are the app's per-repo GUI config (stored under `~/tbd/`) or a global default. Adding a tool-agnostic location closes that gap and gives a clean migration target for the legacy paths.

## Convention

- **Location:** `<repo>/.worktree-hooks/<event>` — one executable file per event, checked into the repo.
- **Event filenames:** match `HookEvent.rawValue`. Initially `setup` and `archive`. (`preMerge` and `postMerge` exist in the enum but are not fired by the lifecycle today; they remain out of scope here.)
- **Permissions:** must be executable (`chmod +x`), same requirement as `.dmux-hooks/` files.
- **Env contract:** unchanged. Hooks receive the same `TBD_EVENT`, `TBD_WORKTREE_ID`, `TBD_WORKTREE_NAME`, `TBD_WORKTREE_PATH`, `TBD_REPO_PATH`, and `TBD_BRANCH` environment variables that existing conductor/dmux hooks receive.
- **Timeout:** unchanged. 60 seconds, same as today.
- **Working directory:** unchanged. Hook runs with `cwd` set to the worktree path.

## Resolution Priority

First match wins, no chaining (same model as today). The new order:

1. App per-repo config — `~/tbd/repos/<uuid>/hooks/<event>`
2. **`.worktree-hooks/<event>`** ← new canonical in-repo path
3. `conductor.json` `scripts.<event>` ← legacy fallback, logs deprecation warning
4. `.dmux-hooks/<event>` ← legacy fallback, logs deprecation warning
5. Global default — `~/tbd/hooks/default/<event>`

Steps 3 and 4 retain their existing resolution logic. The change is positional (now after the new generic location) and adds a one-line `os.Logger` warning when they are used.

## Code Changes

### `Sources/TBDDaemon/Hooks/HookResolver.swift`

- Add a private `resolveWorktreeHooks(event:repoPath:)` method, mirroring `resolveDmux`, that returns `<repoPath>/.worktree-hooks/<event.rawValue>` if that path exists and is executable.
- In `resolve(event:repoPath:appHookPath:)`, insert the new lookup as step 2, between the existing app-config check and the conductor check.
- When `resolveConductor` returns a non-nil path, log a `.warning` via `Logger(subsystem: "com.tbd.daemon", category: "hooks")` with a message like `"conductor.json hook resolved for <event>; consider migrating to .worktree-hooks/"`.
- When `resolveDmux` returns a non-nil path, log an analogous warning referencing `.dmux-hooks/`.

The `HookEvent` enum's `conductorKey` and `dmuxHookName` properties stay as-is — they're still needed for the legacy lookups.

### `Tests/TBDDaemonTests/HookResolverTests.swift`

Add the following tests:

- `worktreeHooksSetup` — only `.worktree-hooks/setup` exists; resolver returns that path.
- `worktreeHooksArchive` — only `.worktree-hooks/archive` exists; resolver returns that path.
- `worktreeHooksBeatsConductor` — both `.worktree-hooks/setup` and a matching `conductor.json` entry exist; resolver returns the `.worktree-hooks/` path.
- `worktreeHooksBeatsDmux` — both `.worktree-hooks/setup` and `.dmux-hooks/worktree_created` exist; resolver returns the `.worktree-hooks/` path.
- `appConfigBeatsWorktreeHooks` — confirms the existing top-of-priority behavior still holds.

Existing tests for conductor, dmux, app-config, global-default, and no-hooks-returns-nil continue to pass unchanged.

## Documentation

Add a new `docs/worktree-hooks.md` covering:

- The `.worktree-hooks/<event>` convention (one executable per event).
- The full resolution priority chain.
- The env-var contract passed to hooks.
- The deprecation status of `conductor.json` and `.dmux-hooks/` — keep working today, will be removed in a future release.
- A minimal example: `.worktree-hooks/setup` shell script that runs `npm install` or similar.

If the main `README.md` or `CLAUDE.md` mentions hooks today, add a single-line pointer to the new doc; otherwise, leave them alone.

## Out of Scope

- Wiring `preMerge` and `postMerge` events into the lifecycle. They remain defined in the enum but unfired.
- Renaming the `TBD_*` env vars to tool-agnostic names. The contract belongs to TBD; the location is what's being made generic.
- An automated migration command. The deprecation warning at resolution time is the migration prompt.
- Removing `conductor.json` and `.dmux-hooks/` support. That happens in a later change once the warning has been in place long enough.
