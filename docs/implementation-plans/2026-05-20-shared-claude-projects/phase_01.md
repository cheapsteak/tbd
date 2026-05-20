# Shared Claude session store — Implementation Plan

**Goal:** Make `~/.claude/projects/` the canonical session-transcript store and
symlink each TBD profile's `claude/projects` into it, so cross-profile resume
works and pre-redesign sessions remain reachable after TBD restarts.

**Architecture:** Internal change to `ClaudeProfileConfigDirManager`. Every
`ensureOAuthDir` / `ensureAPIKeyDir` call ensures `<host-projects>/` exists,
then ensures `<profile-dir>/claude/projects` is a symlink to it (migrating any
pre-existing real directory's contents on the way). Auth (Keychain entry keyed
on `CLAUDE_CONFIG_DIR` path), `.claude.json`, and per-profile settings remain
isolated. No DB change, no call-site change.

**Tech stack:** Swift 6, SwiftPM, Swift Testing (`@Test`/`#expect`).

**Scope:** 1 phase, 3 tasks. Source design:
`docs/specs/2026-05-20-shared-claude-projects-design.md`.

**Codebase verified:** 2026-05-20 — `ClaudeProfileConfigDirManager` lives at
`Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift` and is the only
place where profile config dirs are created. Both ensure-dir methods are the
right hook point.

---

## Acceptance Criteria Coverage

Copied literally from the design doc.

### shared-claude-projects.AC1: profile dirs symlink into the host store
- **AC1.1 Success:** After `ensureOAuthDir(forProfileID:)` runs against a fresh
  profile UUID, `<profile-dir>/claude/projects` exists as a symbolic link whose
  destination resolves to `<host-projects>/` (default `~/.claude/projects/`,
  injectable for tests).
- **AC1.2 Success:** Same property after `ensureAPIKeyDir(forProfileID:apiKey:)`.

### shared-claude-projects.AC2: idempotent
- **AC2.1 Success:** Calling `ensureOAuthDir` / `ensureAPIKeyDir` a second time
  for the same profile leaves the existing symlink (and its target) in place
  and does not error.

### shared-claude-projects.AC3: migrate pre-existing `projects/` content
- **AC3.1 Success:** If `<profile-dir>/claude/projects` already exists as a
  *real directory*, its contents are merged into `<host-projects>/` before
  being replaced by the symlink. Files surviving from before the migration are
  preserved on the host side.
- **AC3.2 Success:** A `<host-projects>/<cwd-hash>/<id>.jsonl` that already
  existed before the migration is NOT overwritten — collisions skip rather
  than clobber.

### shared-claude-projects.AC4: profile deletion preserves host sessions
- **AC4.1 Success:** Deleting a profile via `handleModelProfileDelete` removes
  the profile directory but leaves every file under `<host-projects>/`
  untouched.

---

# Phase 1 — Symlink profile `projects/` into the host store

Files:
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileRPCTests.swift` (one new test
  around the existing delete-cleanup pair)

<!-- START_SUBCOMPONENT_A (tasks 1-3) -->

<!-- START_TASK_1 -->
### Task 1: Add the symlink + migration logic to `ClaudeProfileConfigDirManager`

**Verifies:** shared-claude-projects.AC1.1, AC1.2, AC2.1, AC3.1, AC3.2

**Files:**
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`

**Implementation:**

1. Add an injectable host-projects URL to the struct so tests can redirect it
   without touching `~/.claude/`. Follow the existing `baseDirectory`
   precedent:

   ```swift
   public struct ClaudeProfileConfigDirManager: Sendable {
       let baseDirectory: URL
       let hostProjectsDirectory: URL

       public init(
           baseDirectory: URL? = nil,
           hostProjectsDirectory: URL? = nil
       ) {
           self.baseDirectory = baseDirectory
               ?? TBDConstants.configDir.appendingPathComponent("profiles", isDirectory: true)
           self.hostProjectsDirectory = hostProjectsDirectory
               ?? FileManager.default.homeDirectoryForCurrentUser
                   .appendingPathComponent(".claude", isDirectory: true)
                   .appendingPathComponent("projects", isDirectory: true)
       }
   }
   ```

2. Add a private helper that ensures `<profile-dir>/claude/projects` is a
   symlink to `hostProjectsDirectory`, migrating any pre-existing real
   directory's contents first. Idempotent.

   ```swift
   private func ensureProjectsSymlink(in profileClaudeDir: URL) throws {
       let fm = FileManager.default
       try fm.createDirectory(at: hostProjectsDirectory, withIntermediateDirectories: true)

       let profileProjects = profileClaudeDir.appendingPathComponent("projects", isDirectory: true)

       // Already a symlink? Validate destination; if it points at the right
       // place leave it; if it points elsewhere log and leave it (don't fight
       // an owner we don't recognize).
       if let dest = try? fm.destinationOfSymbolicLink(atPath: profileProjects.path) {
           let resolved = URL(fileURLWithPath: dest, relativeTo: profileProjects.deletingLastPathComponent())
               .standardizedFileURL
           if resolved == hostProjectsDirectory.standardizedFileURL {
               return
           }
           logger.warning("profile projects symlink points elsewhere: \(resolved.path, privacy: .public); leaving as-is")
           return
       }

       // Pre-existing real directory? Migrate contents into the host store
       // (skip on collision), then remove.
       var isDir: ObjCBool = false
       if fm.fileExists(atPath: profileProjects.path, isDirectory: &isDir), isDir.boolValue {
           let entries = (try? fm.contentsOfDirectory(at: profileProjects, includingPropertiesForKeys: nil)) ?? []
           for entry in entries {
               let dest = hostProjectsDirectory.appendingPathComponent(entry.lastPathComponent)
               if fm.fileExists(atPath: dest.path) {
                   logger.debug("collision migrating \(entry.lastPathComponent, privacy: .public); skipping")
                   continue
               }
               try fm.moveItem(at: entry, to: dest)
           }
           try fm.removeItem(at: profileProjects)
       }

       try fm.createSymbolicLink(at: profileProjects, withDestinationURL: hostProjectsDirectory)
   }
   ```

3. Call `ensureProjectsSymlink(in: dir)` at the end of both
   `ensureOAuthDir(forProfileID:)` and `ensureAPIKeyDir(forProfileID:apiKey:)`,
   *after* the existing `.claude.json` write. Use `try` — failures here
   propagate up like the existing filesystem failures already do, and the
   call sites (`resolveConfigDir`) already catch+log+return nil on throw.

4. Update the type-level doc comment to describe the new `projects/` symlink
   behavior alongside the existing per-profile-isolation note.

**Testing:** see Task 2.

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `feat: symlink profile claude/projects into host store`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Tests for the symlink + migration

**Verifies:** shared-claude-projects.AC1.1, AC1.2, AC2.1, AC3.1, AC3.2

**Files:**
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`

**Testing:**

All tests must run against a temp `hostProjectsDirectory` (NOT
`~/.claude/projects/`). Follow the existing pattern of `tempBase()` and add a
`tempHostProjects()` helper. Construct the manager with both injected.

- AC1.1: call `ensureOAuthDir` on a fresh profile UUID, assert
  `<profile-dir>/claude/projects` is a symlink whose `destinationOfSymbolicLink`
  resolves to the temp host-projects path.
- AC1.2: same for `ensureAPIKeyDir`.
- AC2.1: call `ensureOAuthDir` twice; second call still leaves the symlink
  pointing at the same target and does not throw. Same for `ensureAPIKeyDir`.
- AC3.1: pre-create `<profile-dir>/claude/projects/-Users-test-cwd/sess-1.jsonl`
  as a real file in a real directory; call `ensureOAuthDir`; assert
  `<host-projects>/-Users-test-cwd/sess-1.jsonl` now exists, the old path is a
  symlink (not the original real dir), and the file content matches.
- AC3.2: pre-create `<host-projects>/-Users-test-cwd/sess-X.jsonl` with content
  "HOST" and `<profile-dir>/claude/projects/-Users-test-cwd/sess-X.jsonl` with
  content "PROFILE"; call `ensureOAuthDir`; assert host file still contains
  "HOST" (collision skipped).
- A small test that an existing symlink to the right place is left alone:
  call `ensureOAuthDir` twice; capture the inode/identity of the symlink after
  the first call and confirm it's unchanged after the second.

**Verification:**
Run: `swift test --filter ClaudeProfileConfigDirManager`
Expected: all tests pass.

**Commit:** `test: cover projects symlink and migration`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Lock in that profile deletion does not follow the symlink

**Verifies:** shared-claude-projects.AC4.1

**Files:**
- Modify: `Tests/TBDDaemonTests/ModelProfileRPCTests.swift`

**Testing:**

The existing `deleteOAuthRemovesConfigDir` and `deleteAPIKeyRemovesConfigDir`
tests verify the profile directory is removed. Add one new test (or extend
those two) verifying that with `projects/` as a symlink, host sessions survive
the delete. Use the existing test pattern (in-memory DB,
`ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostProjectsDirectory: tempHost)`,
inject into `makeRouter`).

- Create a profile (oauth or apiKey), call `ensureOAuthDir`/`ensureAPIKeyDir`
  so the symlink is created.
- Write a sentinel file at `<tempHost>/-Users-test-cwd/sentinel.jsonl`.
- Invoke `handleModelProfileDelete` for that profile.
- Assert: `<profile-dir>` no longer exists, AND
  `<tempHost>/-Users-test-cwd/sentinel.jsonl` still exists with the original
  content (symlink removal did not propagate into the host store).

This locks in macOS's `FileManager.removeItem(at:)` non-symlink-following
behavior so a future refactor (e.g. switching to a recursive walker that does
follow links) can't silently destroy session history.

**Verification:**
Run: `swift test --filter ModelProfile`
Expected: all tests pass.

**Commit:** `test: profile delete preserves host session store`
<!-- END_TASK_3 -->

<!-- END_SUBCOMPONENT_A -->

---

## Final verification (single-phase plan)

- `swift build` — clean.
- `swift test` — full suite passes.
- `swift package plugin --allow-writing-to-package-directory swiftlint --strict`
  — no violations.
- Manual cross-profile resume check before opening the PR for review:
  1. Restart TBD on this branch via `scripts/restart.sh`.
  2. Spawn `claude` under profile A in some worktree; have a short
     conversation; note the session UUID.
  3. Spawn `claude --resume <uuid>` under profile B in the same worktree's
     cwd; confirm the transcript loads and a new turn proceeds.
  4. (Bonus) Confirm `~/.claude/projects/<cwd-hash>/` shows the session JSONL.

## Out of scope / follow-ups (not blocking)

- Soft lock against simultaneous resume of the same session.
- Swap-time UX warning that the prior transcript will be sent to the target
  account.
- "Stash recovered" affordance for terminals that already reincarnated blank
  between PR #177 merging and this follow-up landing.
