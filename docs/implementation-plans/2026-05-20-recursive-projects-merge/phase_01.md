# Recursive `projects/` merge — Implementation Plan

**Goal:** Replace PR #179's "one level deep" file-level collision scan in
`ClaudeProfileConfigDirManager.ensureMirrorSlot` with a fully recursive
collision scan + recursive merge. Same-name directories on both sides
recurse; only actual file-vs-file or type-mismatch collisions trigger the
atomic abort.

**Architecture:** Internal change to `ClaudeProfileConfigDirManager`. Two
private recursive helpers — `findCollisionRecursive(src:dst:)` (read-only)
and `mergeRecursive(src:dst:)` (mutating, called only after pass 1 returned
nil). Inside `ensureMirrorSlot`, the `migrateContent` branch's pass 1 and
pass 2 inner per-cwd-hash loops are replaced with calls to these helpers.
The top-level non-directory sweep stays. Non-`projects/` sidecar path is
unchanged.

No DB change, no call-site change.

**Tech stack:** Swift 6, SwiftPM, Swift Testing.

**Scope:** 1 phase, 3 tasks. Source design:
`docs/specs/2026-05-20-recursive-projects-merge-design.md`.

**Codebase verified:** 2026-05-20 — `ensureMirrorSlot` lives at
`Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`; the existing
pass 1 / pass 2 + sweep block (lines ~125–198) is the right replacement
target.

---

## Acceptance Criteria Coverage

Copied literally from the design doc.

### recursive-projects-merge.AC1: same-name directories merge by recursing
- **AC1.1 Success:** When `<profile>/projects/<cwd>/sub/` and
  `<host>/projects/<cwd>/sub/` both exist as directories and contain no
  same-named files between them, migration succeeds: every file inside the
  profile's tree ends up at the corresponding host path, the profile-side
  `projects/` is removed, and `<profile>/projects` is a symlink to host.
- **AC1.2 Success:** When the profile's `memory/` is empty and host's
  `memory/` has files, migration succeeds and the profile's empty
  `memory/` is removed alongside the rest of the profile-side `projects/`.

### recursive-projects-merge.AC2: real collisions still abort atomically
- **AC2.1 Success:** A file at `<profile>/projects/<cwd>/sub/leaf.md` whose
  name also exists at `<host>/projects/<cwd>/sub/leaf.md` triggers the
  atomic abort: no moves happen anywhere in the tree; profile-side
  `projects/` is preserved intact; no symlink created.
- **AC2.2 Success:** Type-mismatch collision (host has `foo` as a directory,
  profile has `foo` as a file) also aborts atomically.

### recursive-projects-merge.AC3: existing AC1/2 from PR #179 still hold
- **AC3.1 Success:** Top-level cwd-hash dir present only in the profile is
  still moved whole-tree.
- **AC3.2 Success:** Same-named session JSONLs in both stores still abort
  atomically.
- **AC3.3 Success:** Non-`projects/` slots still get the
  `<slot>.profile-local` sidecar treatment unchanged.
- **AC3.4 Success:** Stray non-directory entries at the top level of
  `projects/` are still swept by the explicit cleanup before the parent
  `removeItem`.

---

# Phase 1 — Recursive merge for `projects/`

Files:
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`

<!-- START_SUBCOMPONENT_A (tasks 1-3) -->

<!-- START_TASK_1 -->
### Task 1: Add the recursive helpers

**Verifies:** none directly (helper plumbing for AC1/AC2)

**Files:**
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`

**Implementation:**

Add two private helpers to the struct, near the existing `ensureMirrorSlot`:

```swift
/// Walk `src` against `dst`, returning the path of the first real collision
/// found, or nil if `src` can be merged into `dst` without overwriting any
/// existing file. Read-only.
///
/// "Real collision" means: at some matching path, both sides exist AND
/// (either they have different types, or both are non-directory files).
/// Same-named directories on both sides recurse.
private func findCollisionRecursive(src: URL, dst: URL) -> URL? {
    let fm = FileManager.default

    var dstIsDir: ObjCBool = false
    let dstExists = fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir)
    if !dstExists {
        return nil  // dst absent → src can be moved whole-tree
    }

    var srcIsDir: ObjCBool = false
    _ = fm.fileExists(atPath: src.path, isDirectory: &srcIsDir)

    // Type mismatch (one file, one directory) → real collision.
    if srcIsDir.boolValue != dstIsDir.boolValue {
        return dst
    }

    // Both files at the same path → real collision (no overwrite).
    if !srcIsDir.boolValue {
        return dst
    }

    // Both directories — recurse into src's children.
    let srcEntries = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
    for entry in srcEntries {
        let dstEntry = dst.appendingPathComponent(entry.lastPathComponent)
        if let collision = findCollisionRecursive(src: entry, dst: dstEntry) {
            return collision
        }
    }
    return nil
}

/// Move every file/subdirectory in `src` into the corresponding location
/// under `dst`. The caller must have already verified
/// `findCollisionRecursive(src:dst:)` returned nil — no overwrite checks are
/// performed here. After a successful merge, `src` is removed.
private func mergeRecursive(src: URL, dst: URL) throws {
    let fm = FileManager.default

    if !fm.fileExists(atPath: dst.path) {
        try fm.moveItem(at: src, to: dst)  // whole-subtree move
        return
    }

    // dst exists; pre-check guarantees it's a directory and src is too.
    let srcEntries = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
    for entry in srcEntries {
        let dstEntry = dst.appendingPathComponent(entry.lastPathComponent)
        try mergeRecursive(src: entry, dst: dstEntry)
    }
    try fm.removeItem(at: src)  // now empty
}
```

Place these immediately above `ensureMirrorSlot` (or wherever the
file-organization is cleanest). Add doc comments — the snippets above already
have them; refine the wording to match the file's existing tone.

**Testing:** see Task 2 — these helpers are exercised indirectly through
`ensureOAuthDir`.

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `feat: add recursive collision scan and merge helpers`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Wire recursive helpers into `ensureMirrorSlot`'s `projects/` branch

**Verifies:** AC1.1, AC1.2, AC2.1, AC2.2, AC3.1, AC3.2, AC3.4

**Files:**
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`

**Implementation:**

In `ensureMirrorSlot`, inside the `migrateContent` (i.e. `projects/`) branch
of "Profile has a real entry", replace the per-cwd-hash inner loops with
calls to the new helpers.

Pass 1 currently walks each top-level cwd-hash entry, checks if the host has
the same dir, and (if so) scans for first-level filename collisions. Replace
with:

```swift
var hasCollision = false
var collidingPath: URL?
for entry in entries {
    let cwdHashPath = profileEntry.appendingPathComponent(entry.lastPathComponent)
    let hostCwdHashPath = hostEntry.appendingPathComponent(entry.lastPathComponent)

    // Skip stray non-directory entries at the top level (e.g. .DS_Store).
    // These get swept explicitly before the final removeItem.
    var isCwdHashDir: ObjCBool = false
    guard fm.fileExists(atPath: cwdHashPath.path, isDirectory: &isCwdHashDir),
          isCwdHashDir.boolValue else { continue }

    if let collision = findCollisionRecursive(src: cwdHashPath, dst: hostCwdHashPath) {
        hasCollision = true
        collidingPath = collision
        break
    }
}

if hasCollision {
    let collisionDesc = collidingPath.map { " (\($0.path))" } ?? ""
    logger.warning("projects migration incomplete for profile due to file collision\(collisionDesc); symlink will not be created. profile-side \(name, privacy: .public)/ dir preserved.")
    return
}
```

Pass 2 currently walks each top-level cwd-hash entry and does either a
whole-dir move or a file-by-file move. Replace with:

```swift
for entry in entries {
    let cwdHashPath = profileEntry.appendingPathComponent(entry.lastPathComponent)
    let hostCwdHashPath = hostEntry.appendingPathComponent(entry.lastPathComponent)

    // Same directory-only guard as pass 1 — strays handled by the sweep below.
    var isCwdHashDir: ObjCBool = false
    guard fm.fileExists(atPath: cwdHashPath.path, isDirectory: &isCwdHashDir),
          isCwdHashDir.boolValue else { continue }

    try mergeRecursive(src: cwdHashPath, dst: hostCwdHashPath)
}
```

Keep the stray-sweep block immediately after (the `leftover` loop logging
each stray and `try? fm.removeItem(at: stray)`) unchanged. The final
`try fm.removeItem(at: profileEntry)` also stays.

Update the doc comment on `ensureMirrorSlot` (the existing block describing
"atomic with respect to name collisions" etc.) to describe the recursive
scan instead of the one-level scan. Be precise: "pass 1 walks the full
tree…", "type mismatches and same-named files are conflicts; same-named
directories recurse".

**Testing:** see Task 3.

**Verification:**
Run: `swift build`
Expected: builds without errors. Existing `ClaudeProfileConfigDirManager`
test suite should also still pass — most prior AC cases (overlapping
cwd-hash dirs with disjoint session UUIDs, cwd-only-in-profile, real
file-vs-file collision) are preserved by the new helpers.

**Commit:** `feat: recursive projects/ merge replaces one-level scan`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Tests for the recursive behavior

**Verifies:** AC1.1, AC1.2, AC2.1, AC2.2 (plus regression-protect AC3.*)

**Files:**
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`

**Testing:**

All tests use injected `baseDirectory:` and `hostBaseDirectory:` — never
touch `~/.claude/` or `~/tbd/`. Follow the existing `tempBase()` /
`tempHostBase()` helpers.

Confirm with `git diff` that the PR #179 collision tests
(`hostMirrorProjectsMigrationFileCollisionAbortsAtomically`,
`hostMirrorProjectsMigrationMergesDisjointFiles`,
`hostMirrorProjectsMigrationMovesProfileOnlyDir`) are still relevant after
the helper swap — they should be, since their scenarios are well within
what the recursive merge handles. Read the test file before writing to
confirm exact existing test names.

New tests:

- **AC1.1 — nested dir-vs-dir with disjoint files merges:**
  Seed:
  - `<host>/projects/-cwd-A/sub/host-leaf.md` ("HOST")
  - `<profile>/claude/projects/-cwd-A/sub/profile-leaf.md` ("PROFILE")
  Call `ensureOAuthDir`. Assert:
  - `<host>/projects/-cwd-A/sub/host-leaf.md` content "HOST" (untouched).
  - `<host>/projects/-cwd-A/sub/profile-leaf.md` content "PROFILE" (moved
    in).
  - `<profile>/claude/projects` is a symlink to `<host>/projects/`.

- **AC1.2 — empty profile-side `memory/` merges (the real bug):**
  Seed `<host>/projects/-cwd-A/memory/note.md` ("HOST NOTE") and an empty
  `<profile>/claude/projects/-cwd-A/memory/` directory (mkdir-only, no
  files). Call `ensureOAuthDir`. Assert:
  - `<host>/projects/-cwd-A/memory/note.md` still "HOST NOTE".
  - The recursive merge removed the empty `<profile>/claude/projects/-cwd-A/memory/`
    (or its parents) on the way to the symlink.
  - `<profile>/claude/projects` is a symlink.

- **AC2.1 — nested file-vs-file collision aborts atomically:**
  Seed:
  - `<host>/projects/-cwd-A/sub/leaf.md` ("HOST LEAF")
  - `<profile>/claude/projects/-cwd-A/sub/leaf.md` ("PROFILE LEAF") —
    same name, both files
  Also seed a non-colliding `<profile>/claude/projects/-cwd-B/x.md` so
  atomicity can be verified.
  Call `ensureOAuthDir`. Assert:
  - `<host>/projects/-cwd-A/sub/leaf.md` content still "HOST LEAF".
  - `<profile>/claude/projects/-cwd-A/sub/leaf.md` content still
    "PROFILE LEAF".
  - `<profile>/claude/projects/-cwd-B/x.md` still exists at the profile
    path (not moved — atomic abort).
  - `<host>/projects/-cwd-B/` does not exist.
  - `<profile>/claude/projects` is a real directory, NOT a symlink.

- **AC2.2 — type-mismatch collision aborts atomically:**
  Seed:
  - `<host>/projects/-cwd-A/foo` as a *directory* containing some file
  - `<profile>/claude/projects/-cwd-A/foo` as a *file* with content
  Call `ensureOAuthDir`. Assert:
  - Both sides retain their original type and content.
  - `<profile>/claude/projects` is a real directory, NOT a symlink.

After adding these, run the full filter and confirm prior tests still pass.

**Verification:**
Run: `swift test --filter ClaudeProfileConfigDirManager`
Expected: all tests pass, including the new AC1.x / AC2.x and the
preserved PR #179 cases.

**Commit:** `test: cover recursive collision and merge`
<!-- END_TASK_3 -->

<!-- END_SUBCOMPONENT_A -->

---

## Final verification

- `swift build` — clean.
- `swift test` — full suite passes (currently 984; will gain ~4).
- `swift package plugin --allow-writing-to-package-directory swiftlint --strict`
  — no violations.
- Manual sanity check (the user is keeping profile 22222 in its broken state
  on purpose as a regression-test fixture):
  - Restart TBD via `scripts/restart.sh`.
  - Attempt swap-profile from the current host conversation to profile
    22222.
  - Confirm `<profile>/claude/projects` becomes a symlink to
    `~/.claude/projects/` and the swap-resume lands in claude with full
    transcript loaded.
