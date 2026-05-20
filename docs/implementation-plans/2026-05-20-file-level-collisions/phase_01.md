# File-level collision detection — Implementation Plan

**Goal:** Change `ClaudeProfileConfigDirManager.ensureMirrorSlot` so the
`projects/` migration detects collisions at the individual session-file level
(not the cwd-hash directory level), and non-`projects/` slots with
pre-existing real content are migrated via a `<slot>.profile-local` sidecar
plus symlink.

**Architecture:** Internal change to `ClaudeProfileConfigDirManager`. Two
behavior changes in `ensureMirrorSlot`'s "profile has a real entry" path:
- For `migrateContent` (i.e. `projects/`): two-pass with one level of
  recursion. Pass 1 checks each profile cwd-hash dir against the host —
  whole-dir-new = no collision, dir-exists-on-host = check files inside for
  name collisions. If any file collides, abort. Pass 2 moves either whole
  cwd-hash dirs or individual files into the host store.
- For non-`migrateContent` real entries: rename to
  `<slot>.profile-local` (if no such sidecar already exists) and proceed to
  create the symlink. Replaces today's "leave alone, no symlink" path.

No DB change, no call-site change.

**Tech stack:** Swift 6, SwiftPM, Swift Testing (`@Test`/`#expect`).

**Scope:** 1 phase, 3 tasks. Source design:
`docs/specs/2026-05-20-file-level-collisions-design.md`.

**Codebase verified:** 2026-05-20 — `ensureMirrorSlot` lives at
`Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`; the current
two-pass dir-level collision detection is around lines 115–137.

---

## Acceptance Criteria Coverage

Copied literally from the design doc.

### file-level-collisions.AC1: `projects/` migration recurses to file level
- **AC1.1 Success:** When `<profile>/projects/<cwd>/` overlaps a host
  `projects/<cwd>/` directory but the individual `.jsonl` files inside have
  disjoint UUIDs, migration succeeds: every profile-side file ends up in the
  corresponding host directory, the profile-side `projects/` is removed,
  and `<profile>/projects` is a symlink to `<host>/projects/`.
- **AC1.2 Success:** When a top-level cwd-hash directory exists only in the
  profile, the whole directory is moved intact to host.
- **AC1.3 Success:** When any individual `.jsonl` file exists with the same
  name in both stores, the migration aborts atomically: no files moved,
  profile-side `projects/` preserved, no symlink.

### file-level-collisions.AC2: non-`projects/` slots get sidecar-and-symlink
- **AC2.1 Success:** Real non-empty file or directory in the profile gets
  renamed to `<slot>.profile-local`, then `<profile>/<slot>` becomes a
  symlink to `<host>/<slot>`.
- **AC2.2 Success:** Re-running does not overwrite an existing
  `<slot>.profile-local` — left untouched.
- **AC2.3 Success:** Empty real directory and missing entry paths keep
  current behavior — symlink created without sidecar.

### file-level-collisions.AC3: profile deletion preserves host state
- **AC3.1 Success:** Deleting a profile that contains both symlinks and a
  `<slot>.profile-local` sidecar removes the profile dir (sidecar included)
  but leaves all of `<host>/` untouched.

---

# Phase 1 — File-level collisions + sidecar fallback

Files:
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileRPCTests.swift` (extend the
  existing `deletePreservesHostMirrors` test to also seed a sidecar)

<!-- START_SUBCOMPONENT_A (tasks 1-3) -->

<!-- START_TASK_1 -->
### Task 1: `projects/` migration with file-level recursion + sidecar fallback for other slots

**Verifies:** all of AC1, all of AC2

**Files:**
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`

**Implementation:**

Locate the `ensureMirrorSlot` function and replace the "Profile has a real
entry" branch. There are two cases to handle:

**Case A — `migrateContent` is true (i.e. `projects/`)**:

Replace the current "two-pass at directory level" logic with a "two-pass at
file level, recursing one directory deep" logic. Concretely:

1. List the top-level entries of `profileEntry` (these are cwd-hash dirs,
   e.g. `-Users-chang-myrepo`).
2. **Collision scan** (pass 1, mutation-free):
   - For each top-level entry `E`:
     - If `host/<slot>/<E>` does not exist on disk, no collision possible for
       this entry. Skip.
     - Else, the dir exists on host. List the files inside the profile's
       `<E>/`. For each file `F`, if `host/<slot>/<E>/<F>` exists, mark
       `hasCollision = true` and break out of all loops.
3. If `hasCollision` is true: log a warning naming the slot and the colliding
   file (one is enough), return without creating the symlink. Profile-side
   directory remains intact.
4. **Migration** (pass 2, all moves):
   - For each top-level entry `E`:
     - If `host/<slot>/<E>` does not exist: `moveItem(E → host/<slot>/<E>)`
       (whole directory).
     - Else: list `E`'s files; for each `F`, `moveItem(E/F → host/<slot>/<E>/F)`;
       then `removeItem(E)` (now empty).
   - `removeItem(profileEntry)` (now empty).
5. Fall through to `createSymbolicLink(profileEntry → hostEntry)`.

Preserve the existing logger.debug for skipped-collisions only when it
provides useful diagnostic — actually drop the per-collision debug noise from
the current code; one warning at abort time is enough.

**Case B — `migrateContent` is false (every other dir slot, plus file
slots)**:

Replace the current "log warning, leave alone, no symlink" early-return with
a sidecar-and-symlink path:

1. Compute the sidecar URL: `profileEntry.appendingPathExtension("profile-local")`
   resolves to `<profile>/<slot>.profile-local`. Note: for `CLAUDE.md` this
   produces `CLAUDE.md.profile-local` — that's fine, the literal dot is
   acceptable in a sidecar name.
2. If `<slot>.profile-local` already exists, do NOT overwrite. Log a debug
   message, skip the rename, and proceed to step 4 — we still want to
   attempt the symlink (the previous run may have failed midway).
3. Otherwise: `moveItem(profileEntry → sidecarURL)`. Log a warning naming the
   slot and the sidecar path.
4. Fall through to `createSymbolicLink(profileEntry → hostEntry)`.

The empty-real-directory branch (current behavior — `removeItem` then
fall-through to symlink) should be preserved unchanged. The sidecar path is
only for non-empty real entries (files always, and dirs with `entries` count
> 0).

**Doc comment update:**

Update `ensureMirrorSlot`'s doc comment so it accurately describes:
- file-level collision detection for `projects/`,
- sidecar-and-symlink for other real entries,
- still-best-effort, still logs and continues across slots.

Also update the type-level doc comment if it mentions either policy.

**Testing:** see Task 2.

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `feat: file-level collisions + sidecar for non-projects slots`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Tests for the new behavior

**Verifies:** all of AC1, all of AC2

**Files:**
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`

**Testing:**

All tests run against an injected temp `hostBaseDirectory` and `baseDirectory`
— never `~/.claude/`. Use the existing `tempBase()` / `tempHostBase()`
helpers.

Replace or augment the existing collision tests with the file-level versions.
The existing `hostMirrorProjectsMigrationCollisionAbortsAtomically` test
currently asserts atomic abort on dir-level collision — its scenario (same
cwd-hash dir on both sides, different individual files) will now SUCCEED
under the new logic. Either rewrite that test to match the new behavior, or
rename it and add a new test for the actual file-level abort.

Concrete cases to cover:

- **AC1.1 — overlapping cwd-hash dirs, disjoint files merge:**
  Seed `<host>/projects/-cwd-A/sess-host.jsonl` ("HOST") and
  `<profile>/claude/projects/-cwd-A/sess-profile.jsonl` ("PROFILE"). Call
  `ensureOAuthDir`. Assert:
  - `<host>/projects/-cwd-A/sess-host.jsonl` content "HOST" (untouched).
  - `<host>/projects/-cwd-A/sess-profile.jsonl` content "PROFILE" (moved in).
  - `<profile>/claude/projects/-cwd-A/` no longer exists at the profile path
    OR is a symlink (the migration removes the original real dir).
  - `<profile>/claude/projects` is a symlink.
- **AC1.2 — cwd-hash dir only in profile, moved whole:**
  Seed `<profile>/claude/projects/-cwd-only-profile/sess-X.jsonl`
  with no corresponding host directory. Call `ensureOAuthDir`. Assert
  `<host>/projects/-cwd-only-profile/sess-X.jsonl` now exists with original
  content and `<profile>/claude/projects` is a symlink.
- **AC1.3 — same session UUID in both, abort atomically:**
  Seed `<host>/projects/-cwd-A/sess-collide.jsonl` content "HOST"
  AND `<profile>/claude/projects/-cwd-A/sess-collide.jsonl` content
  "PROFILE" (deliberate file-name collision). Also seed a non-colliding
  `<profile>/claude/projects/-cwd-B/sess-clean.jsonl`. Call
  `ensureOAuthDir`. Assert:
  - `<host>/projects/-cwd-A/sess-collide.jsonl` content still "HOST".
  - `<profile>/claude/projects/-cwd-A/sess-collide.jsonl` content still
    "PROFILE" (un-moved).
  - `<profile>/claude/projects/-cwd-B/sess-clean.jsonl` still exists at the
    profile path (NOT moved — atomic abort).
  - `<host>/projects/-cwd-B/` does NOT exist.
  - `<profile>/claude/projects` is a real directory, NOT a symlink.

- **AC2.1 — non-`projects` real dir gets sidecar + symlink:**
  Seed `<host>/plugins/somefile.txt` AND
  `<profile>/claude/plugins/profile-only.txt`. Call `ensureOAuthDir`.
  Assert:
  - `<profile>/claude/plugins.profile-local/profile-only.txt` exists with
    original content.
  - `<profile>/claude/plugins` is a symlink to `<host>/plugins/`.
- **AC2.1 (file variant) — non-`projects` real file gets sidecar + symlink:**
  Seed `<host>/CLAUDE.md` AND `<profile>/claude/CLAUDE.md` with content
  "PROFILE-OWNED". Call `ensureOAuthDir`. Assert:
  - `<profile>/claude/CLAUDE.md.profile-local` contains "PROFILE-OWNED".
  - `<profile>/claude/CLAUDE.md` is a symlink to `<host>/CLAUDE.md`.
- **AC2.2 — pre-existing sidecar not overwritten:**
  Seed `<profile>/claude/CLAUDE.md` with "RUN-1", call `ensureOAuthDir`
  (creates sidecar with "RUN-1"). Then write a new
  `<profile>/claude/CLAUDE.md` with "RUN-2" (simulating claude writing
  something later, before the next mirror call). Call `ensureOAuthDir`
  again. Assert the existing `.profile-local` sidecar still reads "RUN-1"
  (not "RUN-2"). The new "RUN-2" file is left alone in place (the rename
  is skipped because the sidecar already exists), so no second symlink
  attempt — but the existing first-pass symlink should still resolve to
  host. Phrase the assertions according to whichever clean behavior the
  implementation produces — the key point is: don't overwrite the sidecar.
- **AC2.3 — empty real directory still becomes a symlink (no sidecar):**
  Seed `<host>/skills/whatever` AND an empty `<profile>/claude/skills/`
  directory. Call `ensureOAuthDir`. Assert no
  `skills.profile-local` exists, and `<profile>/claude/skills` is a
  symlink to `<host>/skills/`.

Update or remove the old `hostMirrorProjectsMigrationCollisionAbortsAtomically`
test that encoded dir-level abort as the "right" behavior — under the new
logic that exact scenario succeeds, so the test will fail unless rewritten.

**Verification:**
Run: `swift test --filter ClaudeProfileConfigDirManager`
Expected: all tests pass; new AC1.x / AC2.x tests cover the new behavior;
prior tests that assumed dir-level abort are either updated to assert the
new merge behavior or removed.

**Commit:** `test: cover file-level collisions and sidecar policy`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Sidecar survives profile deletion (no host leakage)

**Verifies:** file-level-collisions.AC3.1

**Files:**
- Modify: `Tests/TBDDaemonTests/ModelProfileRPCTests.swift`

**Testing:**

Find the existing `deletePreservesHostMirrors` test (or whichever name it
goes by — read the file to confirm). It already seeds sentinels in
`<host>/projects/` and `<host>/plugins/` and verifies they survive profile
deletion. Extend it (or add a sibling test) to also seed a
`<profile>/<id>/claude/CLAUDE.md.profile-local` sidecar before deletion, and
assert:
- The profile directory is gone after delete.
- Both `<host>/` sentinels still exist (existing assertions).
- The sidecar is also gone (it lived under the profile dir).

This locks in that `removeItem(at: profileDir)` removes the sidecar with the
profile but doesn't traverse into the host store via the symlinks — a
property that follows directly from macOS `FileManager`'s
non-symlink-following recursive delete, but worth pinning down explicitly
for the sidecar case.

**Verification:**
Run: `swift test --filter ModelProfile`
Expected: all tests pass.

**Commit:** `test: profile delete cleans up sidecar with the profile dir`
<!-- END_TASK_3 -->

<!-- END_SUBCOMPONENT_A -->

---

## Final verification

- `swift build` — clean.
- `swift test` — full suite passes (currently 980 tests; will gain ~6).
- `swift package plugin --allow-writing-to-package-directory swiftlint --strict`
  — no violations.
- Manual sanity check:
  - Restart TBD via `scripts/restart.sh`.
  - Pick a known affected profile (e.g. the "22222" example), spawn into it
    (or attempt the swap-profile that previously failed). Confirm the
    `projects/` symlink got created and the swap-resume now finds the
    session.
  - Confirm the affected profile's `<profile>/claude/plugins` and
    `settings.json` are now symlinks, with the originals at
    `plugins.profile-local` / `settings.json.profile-local`.
