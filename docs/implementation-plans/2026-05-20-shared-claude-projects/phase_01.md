# Shared Claude state across TBD profiles — Implementation Plan

**Goal:** Make alt-profile dirs thin overlays on `~/.claude/`. Every TBD
profile mirrors the host's customization slots (`projects/`, `plugins/`,
`skills/`, `agents/`, `commands/`, `hooks/`, `CLAUDE.md`, `settings.json`) via
symlinks pointing at the corresponding entries under `~/.claude/`. Only the
per-profile identity slot (`.claude.json` plus per-path Keychain auth) is
owned by the profile.

**Architecture:** Internal change to `ClaudeProfileConfigDirManager`. Every
`ensureOAuthDir` / `ensureAPIKeyDir` call iterates a fixed mirror list and
ensures each present-on-host slot has a symlink in the profile dir, migrating
any pre-existing real `projects/` directory's contents on the way and leaving
other non-empty pre-existing slots alone. Auth (Keychain entry keyed on
`CLAUDE_CONFIG_DIR` path) and `.claude.json` remain per-profile. No DB
change, no call-site change.

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

### shared-claude-projects.AC1: profile dirs mirror host slots via symlinks

The mirror list is: `projects`, `plugins`, `skills`, `agents`, `commands`,
`hooks`, `CLAUDE.md`, `settings.json` — resolved relative to an injectable
host-base directory (default `~/.claude/`).

- **AC1.1 Success:** For each slot present in `<host-base>/`, after
  `ensureOAuthDir(forProfileID:)` runs against a fresh profile UUID,
  `<profile-dir>/claude/<slot>` exists as a symbolic link whose destination
  resolves to `<host-base>/<slot>`.
- **AC1.2 Success:** Same property after `ensureAPIKeyDir(forProfileID:apiKey:)`.
- **AC1.3 Success:** A slot that does not exist in `<host-base>/` does not
  cause a symlink to be created for it.

### shared-claude-projects.AC2: idempotent
- **AC2.1 Success:** Calling `ensureOAuthDir` / `ensureAPIKeyDir` a second
  time leaves every existing slot symlink (and its target) in place and does
  not error.

### shared-claude-projects.AC3: migrate `projects/`; respect other slots
- **AC3.1 Success:** If `<profile-dir>/claude/projects` already exists as a
  *real directory*, its contents are merged into `<host-base>/projects/`
  before being replaced by the symlink.
- **AC3.2 Success:** If any top-level entry (cwd-hash directory) of the
  profile's `projects/` already exists in the host's `projects/`, the entire
  migration is aborted and the profile-side dir is preserved intact.
  All-or-nothing atomicity prevents partial migrations that could orphan
  sessions across stores.
- **AC3.3 Success:** For *non-projects* slots, if `<profile-dir>/claude/<slot>`
  already exists as a real file or non-empty real directory, it is left in
  place and the symlink for that slot is not created. An empty real directory
  may be removed and replaced with the symlink. A symlink pointing at the
  wrong target is left alone with a log warning.

### shared-claude-projects.AC4: profile deletion preserves host state
- **AC4.1 Success:** Deleting a profile via `handleModelProfileDelete` removes
  the profile directory but leaves every file under `<host-base>/` untouched,
  including `projects/` and at least one other mirrored slot (sentinel
  seeded in both before delete).

---

# Phase 1 — Mirror host slots into profile dirs via symlinks

Files:
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileRPCTests.swift` (one new test
  around the existing delete-cleanup pair)

<!-- START_SUBCOMPONENT_A (tasks 1-3) -->

<!-- START_TASK_1 -->
### Task 1: Add the host-mirror logic to `ClaudeProfileConfigDirManager`

**Verifies:** shared-claude-projects.AC1.1, AC1.2, AC1.3, AC2.1, AC3.1, AC3.2, AC3.3

**Files:**
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`

**Implementation:**

1. Add an injectable `hostBaseDirectory: URL` to the struct (defaults to
   `~/.claude/`). Follow the existing `baseDirectory` precedent:

   ```swift
   public struct ClaudeProfileConfigDirManager: Sendable {
       let baseDirectory: URL
       let hostBaseDirectory: URL

       public init(
           baseDirectory: URL? = nil,
           hostBaseDirectory: URL? = nil
       ) {
           self.baseDirectory = baseDirectory
               ?? TBDConstants.configDir.appendingPathComponent("profiles", isDirectory: true)
           self.hostBaseDirectory = hostBaseDirectory
               ?? FileManager.default.homeDirectoryForCurrentUser
                   .appendingPathComponent(".claude", isDirectory: true)
       }
   }
   ```

2. Define the mirror list as a private static array. Order does not matter
   functionally but keep it stable for test predictability:

   ```swift
   /// Slots that each TBD profile dir mirrors from the host's claude config dir.
   /// Symlinked from <profile>/claude/<slot> to <host-base>/<slot>.
   /// `projects` is special: pre-existing real-dir content is migrated into
   /// the host store before symlinking. Every other slot is left alone if it
   /// already exists as a non-empty real file or directory.
   private static let mirrorSlots: [String] = [
       "projects",
       "plugins",
       "skills",
       "agents",
       "commands",
       "hooks",
       "CLAUDE.md",
       "settings.json",
   ]
   ```

3. Add a private helper that processes one slot, then a wrapper that loops:

   ```swift
   /// Ensure one host-mirror slot is a symlink from the profile dir into the
   /// host base. Best-effort: filesystem errors are logged and swallowed.
   private func ensureMirrorSlot(
       _ name: String,
       in profileClaudeDir: URL,
       migrateContent: Bool
   ) {
       let fm = FileManager.default
       let hostEntry = hostBaseDirectory.appendingPathComponent(name)

       // Skip if the host doesn't have this slot at all.
       guard fm.fileExists(atPath: hostEntry.path) else { return }

       let profileEntry = profileClaudeDir.appendingPathComponent(name)

       // Already a symlink? Check target; if it's right, done. If wrong,
       // leave it and log (don't fight an owner we don't recognize).
       if let dest = try? fm.destinationOfSymbolicLink(atPath: profileEntry.path) {
           let resolved = URL(fileURLWithPath: dest, relativeTo: profileEntry.deletingLastPathComponent())
               .standardizedFileURL
           if resolved == hostEntry.standardizedFileURL { return }
           logger.warning("mirror slot \(name, privacy: .public) symlink for profile points elsewhere; leaving as-is")
           return
       }

       // Profile has a real entry. Handle per slot policy.
       var isDir: ObjCBool = false
       if fm.fileExists(atPath: profileEntry.path, isDirectory: &isDir) {
           if isDir.boolValue, migrateContent {
               // projects/ special-case: merge content into host store, then
               // remove the profile-side dir and proceed to symlink.
               do {
                   // Ensure host dir exists (created above by fileExists check
                   // succeeding, but be defensive on race / non-dir).
                   try fm.createDirectory(at: hostEntry, withIntermediateDirectories: true)
                   let entries = (try? fm.contentsOfDirectory(at: profileEntry, includingPropertiesForKeys: nil)) ?? []
                   for entry in entries {
                       let dest = hostEntry.appendingPathComponent(entry.lastPathComponent)
                       if fm.fileExists(atPath: dest.path) {
                           logger.debug("collision migrating \(entry.lastPathComponent, privacy: .public) into \(name, privacy: .public); skipping")
                           continue
                       }
                       try fm.moveItem(at: entry, to: dest)
                   }
                   try fm.removeItem(at: profileEntry)
               } catch {
                   logger.warning("failed migrating \(name, privacy: .public) for profile: \(error.localizedDescription, privacy: .public)")
                   return
               }
           } else if isDir.boolValue {
               // Non-projects directory in profile: replace only if empty.
               let entries = (try? fm.contentsOfDirectory(at: profileEntry, includingPropertiesForKeys: nil)) ?? []
               if entries.isEmpty {
                   try? fm.removeItem(at: profileEntry)
               } else {
                   logger.warning("profile has real \(name, privacy: .public)/ with content; leaving as-is")
                   return
               }
           } else {
               // Real file (e.g. profile-side settings.json or CLAUDE.md).
               // Don't destroy user content; leave alone.
               logger.warning("profile has real \(name, privacy: .public) file; leaving as-is")
               return
           }
       }

       // Create the symlink. Best-effort.
       do {
           try fm.createSymbolicLink(at: profileEntry, withDestinationURL: hostEntry)
       } catch {
           logger.warning("failed creating mirror symlink for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
       }
   }

   /// Ensure every host-mirror slot is symlinked into the profile dir.
   /// Best-effort and per-entry isolated — one failing slot does not block
   /// the others.
   private func ensureHostMirrors(in profileClaudeDir: URL) {
       for slot in Self.mirrorSlots {
           ensureMirrorSlot(slot, in: profileClaudeDir, migrateContent: slot == "projects")
       }
   }
   ```

4. Call `ensureHostMirrors(in: dir)` at the end of both
   `ensureOAuthDir(forProfileID:)` and `ensureAPIKeyDir(forProfileID:apiKey:)`,
   *after* the existing `.claude.json` write. The wrapper is non-throwing, so
   no signature change is needed at the call sites — the existing
   `resolveConfigDir` catch path still covers any throws from earlier in the
   ensure methods.

5. Update the type-level doc comment: list the slots that are mirrored, note
   that `.claude.json` and credentials stay per-profile, mention the
   `apiKeyHelper` caveat in a brief sentence.

**Testing:** see Task 2.

**Verification:**
Run: `swift build`
Expected: builds without errors.

**Commit:** `feat: mirror host claude state slots into profile dirs`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Tests for the host-mirror behavior

**Verifies:** shared-claude-projects.AC1.1, AC1.2, AC1.3, AC2.1, AC3.1, AC3.2, AC3.3

**Files:**
- Modify: `Tests/TBDDaemonTests/ClaudeProfileConfigDirManagerTests.swift`

**Testing:**

All tests must run against a temp `hostBaseDirectory` (NOT `~/.claude/`).
Add a `tempHostBase()` helper alongside the existing `tempBase()`. Construct
the manager with both injected.

Cover the policy rather than every slot — pick a representative slot per
category to keep the suite tight:

- AC1.1 / AC1.2: pre-create `<tempHost>/plugins/` (dir) and
  `<tempHost>/CLAUDE.md` (file). Call `ensureOAuthDir` then
  `ensureAPIKeyDir`. Assert `<profile-dir>/claude/plugins` is a symlink whose
  destination resolves to `<tempHost>/plugins/`, and likewise for `CLAUDE.md`.
- AC1.3 (host slot absent): with `<tempHost>/skills/` not created, call
  `ensureOAuthDir`. Assert `<profile-dir>/claude/skills` does NOT exist.
- AC2.1 (idempotent): with `<tempHost>/plugins/` created, call
  `ensureOAuthDir` twice; second call leaves the symlink intact, same target,
  no throw.
- AC3.1 (projects migration — directory): pre-create `<tempHost>/projects/`,
  pre-create `<profile-dir>/claude/projects/-Users-test-cwd/sess-1.jsonl` as
  a real file. Call `ensureOAuthDir`. Assert
  `<tempHost>/projects/-Users-test-cwd/sess-1.jsonl` now exists with original
  content, `<profile-dir>/claude/projects` is a symlink, the original real
  dir is gone.
- AC3.2 (projects migration collision-skip): pre-create
  `<tempHost>/projects/-Users-test-cwd/sess-X.jsonl` containing "HOST" and
  `<profile-dir>/claude/projects/-Users-test-cwd/sess-X.jsonl` containing
  "PROFILE". Call `ensureOAuthDir`. Host file still reads "HOST".
- AC3.3a (non-projects directory with content): pre-create
  `<tempHost>/plugins/` AND `<profile-dir>/claude/plugins/foo.txt`. Call
  `ensureOAuthDir`. Assert `<profile-dir>/claude/plugins` is still a real
  directory (NOT a symlink) and `foo.txt` is still there.
- AC3.3b (non-projects empty directory): pre-create `<tempHost>/plugins/` AND
  an empty `<profile-dir>/claude/plugins/`. Call `ensureOAuthDir`. Assert the
  profile-side `plugins` is now a symlink to host.
- AC3.3c (non-projects file): pre-create `<tempHost>/CLAUDE.md` AND
  `<profile-dir>/claude/CLAUDE.md` with content "PROFILE-OWNED". Call
  `ensureOAuthDir`. Assert `<profile-dir>/claude/CLAUDE.md` is still a real
  file containing "PROFILE-OWNED" (NOT a symlink).
- Symlink-wrong-target: pre-create `<tempHost>/plugins/` and a symlink
  `<profile-dir>/claude/plugins` pointing at a junk dir. Call
  `ensureOAuthDir`. Assert the symlink is left alone (still points at junk).

**Verification:**
Run: `swift test --filter ClaudeProfileConfigDirManager`
Expected: all tests pass.

**Commit:** `test: cover host-slot mirror policy`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Lock in that profile deletion does not follow mirror symlinks

**Verifies:** shared-claude-projects.AC4.1

**Files:**
- Modify: `Tests/TBDDaemonTests/ModelProfileRPCTests.swift`

**Testing:**

Extend (or add alongside) the existing `deleteOAuthRemovesConfigDir` /
`deleteAPIKeyRemovesConfigDir` tests with a version that seeds sentinels
under at least two host slots and asserts they survive profile deletion.
Use the existing test pattern (in-memory DB,
`ClaudeProfileConfigDirManager(baseDirectory: tempBase, hostBaseDirectory: tempHost)`,
inject into `makeRouter`).

- Create a profile (oauth or apiKey), pre-create `<tempHost>/projects/` and
  `<tempHost>/plugins/`, call the appropriate `ensure*Dir` method so the
  symlinks are created.
- Write sentinel files:
  - `<tempHost>/projects/-Users-test-cwd/sentinel.jsonl` with known content
  - `<tempHost>/plugins/sentinel.txt` with known content
- Invoke `handleModelProfileDelete` for that profile.
- Assert: `<profile-dir>` no longer exists, BOTH sentinels still exist on the
  host side with their original content.

This locks in macOS `FileManager.removeItem(at:)`'s non-symlink-following
behavior across multiple mirrored slots so a future refactor can't silently
destroy host state.

**Verification:**
Run: `swift test --filter ModelProfile`
Expected: all tests pass.

**Commit:** `test: profile delete preserves host mirror targets`
<!-- END_TASK_3 -->

<!-- END_SUBCOMPONENT_A -->

---

## Final verification (single-phase plan)

- `swift build` — clean.
- `swift test` — full suite passes.
- `swift package plugin --allow-writing-to-package-directory swiftlint --strict`
  — no violations.
- Manual checks before opening the PR for review:
  1. Restart TBD on this branch via `scripts/restart.sh`.
  2. **Cross-profile resume.** Spawn `claude` under profile A in some
     worktree; have a short conversation; note the session UUID. Spawn
     `claude --resume <uuid>` under profile B in the same worktree's cwd;
     confirm the transcript loads and a new turn proceeds. Bonus: confirm
     `~/.claude/projects/<cwd-hash>/` shows the session JSONL.
  3. **Customizations visible.** In an alt-profile session, run a slash
     command from `~/.claude/commands/` and verify it works; invoke a skill
     that lives in `~/.claude/skills/`; check that `claude --help`-listed
     plugins include the user-installed ones from `~/.claude/plugins/`.
  4. **Pre-redesign session resume.** Pick a terminal that existed pre-PR
     #177 (still pointing at an OAuth or direct-apiKey profile, session
     stored under `~/.claude/projects/`). Restart TBD; confirm the terminal
     resumes with full history instead of reincarnating blank.

## Out of scope / follow-ups (not blocking)

- Soft lock against simultaneous resume of the same session.
- Swap-time UX warning that the prior transcript will be sent to the target
  account.
- "Stash recovered" affordance for terminals that already reincarnated blank
  between PR #177 merging and this follow-up landing.
