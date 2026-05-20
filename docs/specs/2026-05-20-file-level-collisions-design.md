# File-level collision detection in alt-profile mirror migration

**Date:** 2026-05-20
**Status:** Design (follow-up to `2026-05-20-shared-claude-projects-design.md`)

## Problem

PR #178 made every TBD alt-profile dir mirror customization slots from
`~/.claude/` via symlinks. The `projects/` slot has special migration logic
because pre-existing profiles built up real content there during the PR #177
window. The migration is **atomic on collision**: if any top-level entry in the
profile's `projects/` already exists in the host's `projects/`, the whole
migration is aborted and the profile-side `projects/` is preserved as a real
directory — no symlink is created.

That policy was correct for atomicity but **too coarse**. Encountered in the
wild this morning:

- A profile with five cwd-hash directories in its `projects/`, every one of
  which also exists in `~/.claude/projects/` (same working directories, used
  from both host and profile over time).
- The session UUIDs *inside* those cwd-hash dirs were entirely disjoint
  between host and profile — zero file-level conflicts.
- But the dir-level collision check fired five times → atomic abort → no
  symlink → profile's `projects/` stays a real dir → `claude --resume <id>`
  spawned under that profile can't see sessions in `~/.claude/projects/` →
  the swap-profile feature exits to a shell.

This is the dominant case for any actively-used pre-existing profile, not an
edge case. The fix is to detect collisions at the *file* level — where they
actually mean "data conflict" — not at the directory level.

A related issue: **non-`projects/` slots with real content** (`plugins/`,
`settings.json`, etc.) are left alone with no symlink under the current
policy. Two profiles in the wild are affected. The user loses access to
host-installed plugins and host settings when spawning under those profiles.
Less urgent than the `projects/` failure but worth addressing in the same
pass.

## Goal

After this change:

1. The `projects/` migration succeeds whenever no *individual session file* in
   the profile would clobber an existing host file. Cwd-hash directory-name
   overlaps are no longer a barrier.
2. Non-`projects/` slots that have accumulated real content during the PR
   #177 era are also migrated: profile's content is set aside under a
   `<slot>.profile-local` sibling and the symlink to host is created. No
   user data is destroyed, customization losses are recoverable, and the
   alt-profile session sees host plugins / settings / etc. from the next
   spawn onward.

## Out of scope

- Three-way merging of `plugins/installed_plugins.json` or `settings.json`
  JSON content. Profile-local versions are preserved on disk under a sibling
  name; users who care can re-apply by hand. Auto-merge of arbitrary JSON is
  brittle and not worth the engineering for two profiles.
- Anything else from the prior follow-ups' "Out of scope" list.

## Approach

### `projects/` — recurse one level deep

The shape Claude Code writes is exactly:
```
projects/<cwd-hash>/<session-uuid>.jsonl
```
Two levels of directory below the slot root. The migration recurses one level
deep:

```
For each top-level entry E in profile/projects/:
  hostE = host/projects/<E>
  if hostE does not exist:
    Nothing collides → safe to migrate E whole.
  else:
    For each file F in profile/projects/<E>/:
      if host/projects/<E>/<F> exists → mark file-level collision.

If any file-level collision exists:
  Abort. Profile/projects/ left as a real directory (current behavior).
Else:
  For each top-level entry E:
    if host/projects/<E> does not exist:
      moveItem(profile/projects/<E>, host/projects/<E>)        // whole dir
    else:
      For each F in profile/projects/<E>/:
        moveItem(profile/projects/<E>/<F>, host/projects/<E>/<F>)  // per-file
      removeItem(profile/projects/<E>)                          // now empty
  removeItem(profile/projects/)
  createSymbolicLink(profile/projects → host/projects/)
```

Same all-or-nothing atomicity guarantee as before, just with sharper
granularity. Session UUIDs are UUIDs, so file-level collisions are
astronomically improbable in practice — but if one ever happens, the abort
preserves both sides.

### Non-`projects/` slots — sidecar-and-symlink

For every other mirror slot (`plugins/`, `skills/`, `agents/`, `commands/`,
`hooks/`, `CLAUDE.md`, `settings.json`), if the profile entry exists as a
real file or non-empty real directory **and** the host has that slot:

```
profile/<slot>  →  rename to  profile/<slot>.profile-local
createSymbolicLink(profile/<slot> → host/<slot>)
```

Profile-side content is preserved verbatim under a recoverable sibling name.
The symlink is created so the alt-profile sees host customizations from now
on. Log a warning so the user knows the sidecar exists.

If `profile/<slot>.profile-local` already exists (a prior migration ran),
skip the rename — leave the existing sidecar untouched and proceed to
attempting the symlink (which will no-op if the symlink already points right).

Empty real directories and missing entries follow current behavior unchanged.

### Why a sidecar instead of three-way merge

Two profiles in the wild are affected. The sidecar approach is mechanical,
zero-loss, reversible by `mv <slot>.profile-local <slot>`, and doesn't
require us to understand the schema of every file claude writes. Engineering
a JSON-aware merger for `installed_plugins.json` etc. would be substantially
more code for two known users.

## Acceptance criteria

### file-level-collisions.AC1: `projects/` migration recurses to file level

- **AC1.1 Success:** When `<profile>/projects/<cwd>/` overlaps a host
  `projects/<cwd>/` directory but the individual `.jsonl` files inside have
  disjoint UUIDs, migration succeeds: every profile-side file ends up in the
  corresponding host directory, the profile-side `projects/` is removed, and
  `<profile>/projects` is a symlink to `<host>/projects/`.
- **AC1.2 Success:** When a top-level cwd-hash directory exists only in the
  profile (no host directory of the same name), the whole directory is
  moved intact to host (`moveItem` of the directory, not per-file).
- **AC1.3 Success:** When any individual `.jsonl` file exists with the same
  name in both `<profile>/projects/<cwd>/<id>.jsonl` and
  `<host>/projects/<cwd>/<id>.jsonl`, the migration aborts atomically: no
  files are moved, profile-side `projects/` is preserved intact, no symlink
  is created.

### file-level-collisions.AC2: non-`projects/` slots get sidecar-and-symlink

- **AC2.1 Success:** For a non-`projects/` slot present on the host where the
  profile has a real non-empty file or directory, after
  `ensureOAuthDir` / `ensureAPIKeyDir` runs: the original profile-side
  content lives at `<profile>/<slot>.profile-local`, and `<profile>/<slot>`
  is a symlink to `<host>/<slot>`.
- **AC2.2 Success:** Re-running `ensureOAuthDir` / `ensureAPIKeyDir` does not
  overwrite an existing `<slot>.profile-local` sidecar — it's left untouched.
- **AC2.3 Success:** When the host has the slot but the profile entry is
  missing (or an empty directory), the symlink is created as before — no
  sidecar produced.

### file-level-collisions.AC3: profile deletion still preserves host state

- **AC3.1 Success:** Deleting a profile whose dir contains both the symlinks
  and a `<slot>.profile-local` sidecar removes the profile dir (including the
  sidecar) but leaves every file under `<host>/` untouched. The sidecar is
  unique to the profile and goes away with it; host state is unaffected.

## Risks / known limitations

1. **Profile-side plugin settings are not auto-merged into host.** Users
   who had `enabledPlugins` or other profile-specific plugin state in
   `<profile>/plugins/installed_plugins.json` need to manually merge it into
   `~/.claude/plugins/installed_plugins.json` if they want those plugins
   under that profile. The sidecar at `<profile>/plugins.profile-local`
   preserves the originals.
2. **Same for `settings.json`.** If the user had profile-specific settings,
   they're at `<profile>/settings.json.profile-local`; the alt-profile now
   uses host's `~/.claude/settings.json`.
3. **Astronomical UUID collisions still abort.** If the same session UUID
   appears in both stores, the abort preserves both — current dir-level
   atomicity for the rare file-collision case. Not a regression.

## Compatibility / migration

- No DB change.
- No call-site change (still internal to `ClaudeProfileConfigDirManager`).
- On the next daemon restart, every reconciled profile's `ensure*Dir`
  call runs the new logic. Profiles that successfully migrated under PR #178
  already have symlinks — they pass through the idempotent check and are
  left alone. The two affected profiles get their migration completed on
  this restart.
