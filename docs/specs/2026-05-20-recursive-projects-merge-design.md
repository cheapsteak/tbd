# Recursive merge for `projects/` migration

**Date:** 2026-05-20
**Status:** Design (follow-up to `2026-05-20-file-level-collisions-design.md`)

## Problem

PR #179 made `projects/` collision detection recurse **exactly one level** —
walk each profile-side cwd-hash directory and check for individual entries
inside that match host entries. That fixed the dominant case (same cwd worked
from host and profile, disjoint session UUIDs).

It's still too coarse in one realistic shape: Claude Code's auto-memory
system creates a `memory/` subdirectory inside each cwd-hash directory,
alongside the session JSONLs. Encountered live:

- Host: `~/.claude/projects/-Users-chang-projects-longeye-app/` contains
  many session JSONLs **plus** a `memory/` directory with ~22 markdown
  notes.
- Profile 22222: `<profile>/.../projects/-Users-chang-projects-longeye-app/`
  contains a `memory/` directory too — but **empty**, never populated.

PR #179's check at this level sees `memory` in both → marks it as a
file-level collision → atomic abort. But these aren't conflicting files —
they're both *directories*, one full and one empty, with no actual name
collisions inside.

This blocks swap-profile from any cwd whose profile-side cwd-hash dir
contains an empty (or merely-disjoint) `memory/` subdirectory. The user
deliberately kept profile 22222 in this state as a regression test for
this fix.

## Goal

After this change, the `projects/` migration succeeds whenever **no actual
file-vs-file (or type-mismatch) collision** exists anywhere in the tree —
not just at one fixed depth. Same name on both sides where both are
directories: recurse and merge. Same name where both are files, or types
differ: abort atomically.

## Out of scope

- Changing the non-`projects/` sidecar policy (verified working in the wild
  this cycle — `plugins → ~/.claude/plugins`, `settings.json` symlinked,
  with `.profile-local` sidecars preserving overridden content).
- Three-way content merge for files that share a name (still treated as a
  hard conflict that aborts atomically).
- Anything from prior follow-ups' "Out of scope".

## Approach

Replace PR #179's hand-rolled "one level deep" loops with two recursive
helpers:

**Pass 1 — collision scan (read-only):**
```
findCollisionRecursive(src, dst) -> URL?
  if dst does not exist:
    return nil                      // dst absent → src can be moved whole
  if src and dst types differ (one is file, one is directory):
    return dst                      // type mismatch is a real collision
  if both are files:
    return dst                      // same name + both files → real collision
  // Both directories. Recurse for each entry in src.
  for entry in src:
    if let collision = findCollisionRecursive(entry, dst/entry.name):
      return collision
  return nil
```

**Pass 2 — recursive merge (mutating, only invoked if pass 1 returned nil
for every cwd-hash dir):**
```
mergeRecursive(src, dst) throws
  if dst does not exist:
    moveItem(src → dst)             // whole-subtree move
    return
  // Pre-checked: dst exists and both are directories. Iterate src.
  for entry in src:
    mergeRecursive(entry, dst/entry.name)
  removeItem(src)                   // src is now empty
```

These two functions get called from `ensureMirrorSlot`'s `projects/` branch
in place of the existing per-cwd-hash loops. The "stray non-directory entry
at the top level" sweep added last cycle is preserved unchanged.

The atomicity guarantee tightens slightly — pass 1 walks the whole tree, not
just one level. The wall-clock cost is bounded by the number of files in the
profile's `projects/`, which is small (one user, one machine).

## Why a recursive merge instead of "just recurse two levels"

`memory/` is one example; future Claude Code versions could introduce other
nested directories under `<cwd-hash>/`. A fixed depth keeps fragility around.
Recursive merge matches the semantics we actually want — "move src into dst,
without overwriting any existing file" — and stops being surprised when
claude adds new subdirectory structures.

## Acceptance criteria

### recursive-projects-merge.AC1: same-name directories merge by recursing

- **AC1.1 Success:** When `<profile>/projects/<cwd>/sub/` and
  `<host>/projects/<cwd>/sub/` both exist as directories and contain no
  same-named files between them, migration succeeds: every file inside the
  profile's tree ends up at the corresponding host path, the profile-side
  `projects/` is removed, and `<profile>/projects` is a symlink to host.
- **AC1.2 Success:** When the profile's `memory/` is empty and host's
  `memory/` has files, migration succeeds and the profile's empty
  `memory/` (now also empty after recursive descent) is removed alongside
  the rest of the profile-side `projects/`.

### recursive-projects-merge.AC2: real collisions still abort atomically

- **AC2.1 Success:** A file at `<profile>/projects/<cwd>/sub/leaf.md`
  whose name also exists at `<host>/projects/<cwd>/sub/leaf.md` (regardless
  of content) triggers the atomic abort. No moves happen anywhere in the
  tree; profile-side `projects/` is preserved intact; no symlink created.
- **AC2.2 Success:** Type-mismatch collision (e.g. host has `foo` as a
  directory, profile has `foo` as a file at the same logical path) also
  aborts atomically with no moves.

### recursive-projects-merge.AC3: existing AC1/2 from PR #179 still hold

- **AC3.1 Success:** Top-level cwd-hash dir present only in the profile is
  still moved whole-tree (PR #179's AC1.2).
- **AC3.2 Success:** Same-named session JSONLs in both stores still abort
  atomically (PR #179's AC1.3).
- **AC3.3 Success:** Non-`projects/` slots still get the
  `<slot>.profile-local` sidecar treatment unchanged.
- **AC3.4 Success:** Stray non-directory entries at the top level of
  `projects/` are still swept by the explicit cleanup before the parent
  `removeItem`.

## Risks / known limitations

1. **Pre-existing files in deep host subdirs are never overwritten.** This
   is the design's central guarantee, but it means a profile that had
   accumulated *content* (not just an empty subdir) in `memory/` whose
   filenames also exist in host's `memory/` will still abort. Acceptable —
   no data loss, just requires manual conflict resolution.
2. **Recursive walk cost grows with file count under `projects/`.** O(N)
   in profile-side file count. In practice N is small (~hundreds at most).

## Compatibility / migration

- No DB change, no call-site change.
- Daemon restart re-runs `ensureOAuthDir` / `ensureAPIKeyDir` per profile;
  the new recursive scan handles the dir-vs-dir case that PR #179 misread
  as a collision.
- Profiles that PR #179 successfully migrated have symlinks in place and
  pass through the idempotent check unchanged.
