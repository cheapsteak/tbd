# Archive Jitter Fix — Implementation Plan

**Goal:** Stop an archived worktree's sidebar row from disappearing→reappearing→disappearing by guarding `refreshWorktrees` against stale daemon snapshots that predate the archive.

**Architecture:** Add a timestamped "tombstone" map of recently-removed worktree IDs to `AppState`. `refreshWorktrees` filters tombstoned IDs out of daemon data, so a `listWorktrees` poll issued *before* the daemon flipped the worktree's status can no longer resurrect the row. Tombstones are evicted once the daemon confirms the archive (worktree returns as `.archived` or is absent) or after a safety TTL (failed/stuck archive). The already-defined-but-unhandled `.worktreeArchived` delta is wired up so removal is also event-driven. Revive clears the tombstone so a re-revived worktree isn't suppressed.

**Tech Stack:** Swift, SwiftUI, Swift Package Manager. `AppState` is `@MainActor`.

**Scope:** 1 phase. No design plan — derived from the fleshed-out spec in this conversation.

**Codebase verified:** 2026-05-22 via codebase-investigator.

---

## Acceptance Criteria Coverage

This phase implements and tests:

### AC1: Stale poll cannot resurrect an archived row
- **AC1.1 Success:** When a worktree ID is tombstoned, `visibleWorktrees(from:tombstones:)` excludes that worktree from the result even if the daemon snapshot still reports it `.active`.
- **AC1.2 Success:** `reconcileTombstones` keeps a tombstone while the daemon still reports the worktree `.active` and the tombstone is younger than the TTL.

### AC2: Tombstones do not permanently suppress worktrees
- **AC2.1 Success:** `reconcileTombstones` evicts a tombstone once the daemon reports the worktree `.archived` or absent.
- **AC2.2 Failure:** `reconcileTombstones` evicts a tombstone older than the TTL even if the daemon still reports the worktree `.active` (failed/stuck archive recovers).
- **AC2.3 Success:** A worktree with no tombstone is never excluded by `visibleWorktrees(from:tombstones:)`.

### AC3: `.worktreeArchived` delta removes the row
- **AC3.1 Success:** `handleDelta(.worktreeArchived(...))` removes the worktree from `worktrees` and adds it to the tombstone map.

### AC4: Revive clears the tombstone
- **AC4.1 Success:** Reviving a worktree removes its ID from the tombstone map so a subsequent refresh can show it again.

---

<!-- START_SUBCOMPONENT_A (tasks 1-4) -->

<!-- START_TASK_1 -->
### Task 1: Add tombstone state and pure reconciliation/filter functions

**Verifies:** AC1.1, AC1.2, AC2.1, AC2.2, AC2.3

**Files:**
- Modify: `Sources/TBDApp/AppState.swift` — add a stored property near `pendingWorktreeIDs` (declared at `AppState.swift:200`).
- Create: `Sources/TBDApp/AppState+ArchiveTombstones.swift` — pure functions + a constant.

**Implementation:**

In `AppState.swift`, immediately after the `pendingWorktreeIDs` declaration (line ~200), add:

```swift
/// Worktree IDs optimistically removed by an archive that has not yet been
/// confirmed by daemon data. `refreshWorktrees` filters these out so a
/// `listWorktrees` poll issued before the daemon flipped the status cannot
/// resurrect the row. Value is the time the tombstone was created, used for
/// TTL-based eviction when an archive fails or stalls.
var recentlyArchivedWorktreeIDs: [UUID: Date] = [:]
```

Do NOT mark it `@Published` — it does not drive the view directly; it gates mutations of the already-`@Published` `worktrees`. Leave it `internal` (default) so tests can read it via `@testable import TBDApp`.

Create `Sources/TBDApp/AppState+ArchiveTombstones.swift` with pure, daemon-free logic:

```swift
import Foundation
import TBDShared

extension AppState {
    /// How long a tombstone survives without daemon confirmation before it is
    /// force-evicted. Generous: a stuck or failed archive recovers its row
    /// after this window rather than vanishing permanently.
    static let archiveTombstoneTTL: TimeInterval = 30

    /// Returns the tombstones that should still be kept. A tombstone is evicted
    /// when the daemon confirms the archive (worktree reported `.archived` or
    /// absent) or when it has outlived `archiveTombstoneTTL`.
    ///
    /// - Parameter daemonWorktrees: the raw, unfiltered worktree list from the
    ///   daemon (includes `.archived` rows).
    static func reconcileTombstones(
        _ tombstones: [UUID: Date],
        daemonWorktrees: [Worktree],
        now: Date,
        ttl: TimeInterval = AppState.archiveTombstoneTTL
    ) -> [UUID: Date] {
        var statusByID: [UUID: WorktreeStatus] = [:]
        for wt in daemonWorktrees { statusByID[wt.id] = wt.status }
        return tombstones.filter { id, createdAt in
            switch statusByID[id] {
            case .archived, .none:
                return false                          // daemon confirmed gone
            default:
                return now.timeIntervalSince(createdAt) < ttl   // keep until TTL
            }
        }
    }

    /// Filters daemon worktrees down to what the sidebar should treat as
    /// present: drops `.archived` rows and any tombstoned ID.
    static func visibleWorktrees(
        from daemonWorktrees: [Worktree],
        tombstones: Set<UUID>
    ) -> [Worktree] {
        daemonWorktrees.filter { $0.status != .archived && !tombstones.contains($0.id) }
    }
}
```

**Testing:**
Create `Tests/TBDAppTests/ArchiveTombstoneTests.swift`. These functions are pure (no daemon, no `@MainActor` needed beyond constructing `Worktree` values). Build `Worktree` fixtures matching the `TBDShared.Worktree` initializer (inspect `Sources/TBDShared/Models.swift` for required fields). Cover:
- AC1.1: `visibleWorktrees(from: [activeWt], tombstones: [activeWt.id])` → empty.
- AC2.3: `visibleWorktrees(from: [activeWt], tombstones: [])` → `[activeWt]`.
- AC1.2: `reconcileTombstones([id: now], daemonWorktrees: [activeWtWithId], now: now)` → still contains `id` (daemon shows `.active`, fresh).
- AC2.1 (archived): `reconcileTombstones([id: now], daemonWorktrees: [archivedWtWithId], now: now)` → empty.
- AC2.1 (absent): `reconcileTombstones([id: now], daemonWorktrees: [], now: now)` → empty.
- AC2.2: `reconcileTombstones([id: oldDate], daemonWorktrees: [activeWtWithId], now: oldDate + 31)` → empty.

**Verification:**
Run: `swift build && swift test --filter ArchiveTombstoneTests`
Expected: builds; all new tests pass.

**Commit:** `feat: add archive tombstone state and pure reconcile/filter helpers`
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Apply tombstone reconcile + filter inside `refreshWorktrees`

**Verifies:** AC1.1, AC2.1, AC2.2

**Files:**
- Modify: `Sources/TBDApp/AppState.swift` — `refreshWorktrees`, around `AppState.swift:708-735`.

**Implementation:**

`refreshWorktrees` currently does (line ~711-712):

```swift
let allWts = try await daemonClient.listWorktrees(repoID: repoID)
let fetched = allWts.filter { $0.status != .archived }
```

Replace those two lines with:

```swift
let allWts = try await daemonClient.listWorktrees(repoID: repoID)
// Drop tombstones the daemon has confirmed (or that outlived the TTL) so a
// stale poll predating an archive cannot resurrect the row.
recentlyArchivedWorktreeIDs = AppState.reconcileTombstones(
    recentlyArchivedWorktreeIDs,
    daemonWorktrees: allWts,
    now: Date()
)
let fetched = AppState.visibleWorktrees(
    from: allWts,
    tombstones: Set(recentlyArchivedWorktreeIDs.keys)
)
```

Leave the rest of `refreshWorktrees` unchanged — both the `repoID`-scoped branch and the all-repos branch already consume `fetched`.

Note: when `refreshWorktrees(repoID:)` is scoped to one repo, `allWts` only covers that repo, so `reconcileTombstones` could see a tombstoned ID from another repo as "absent" and evict it early. That is harmless — early eviction only risks the original race, and the scoped call path is not on the archive jitter path. Do not special-case it.

**Testing:**
No new test here — Task 1 covers `reconcileTombstones`/`visibleWorktrees` purely, and `refreshWorktrees` cannot be unit-tested without a daemon (no `DaemonClient` mock exists in this codebase). The wiring is verified by the build and by manual verification in Task 5.

**Verification:**
Run: `swift build`
Expected: builds with no errors.

**Commit:** `fix: filter tombstoned worktrees out of refreshWorktrees`
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Tombstone on optimistic archive + handle the `.worktreeArchived` delta

**Verifies:** AC3.1

**Files:**
- Modify: `Sources/TBDApp/AppState+Worktrees.swift` — `archiveWorktree`, lines 57-72.
- Modify: `Sources/TBDApp/AppState.swift` — `handleDelta`, lines 451-466; add `applyWorktreeArchivedDelta` next to `applyWorktreeMovedDelta` (line ~473).

**Implementation:**

In `archiveWorktree`, after the successful `try await daemonClient.archiveWorktree(...)` and before the `removeAll` loop, add the tombstone insert:

```swift
try await daemonClient.archiveWorktree(id: id, force: force)
recentlyArchivedWorktreeIDs[id] = Date()
for repoID in worktrees.keys {
    worktrees[repoID]?.removeAll { $0.id == id }
}
```

In `AppState.swift`, add a case to `handleDelta`'s `switch` (before `default:`):

```swift
case .worktreeArchived(let d):
    applyWorktreeArchivedDelta(d)
```

Add the handler next to `applyWorktreeMovedDelta` (~line 473):

```swift
/// Daemon confirmed a worktree was archived (possibly from the CLI or another
/// client). Tombstone it and drop the row so it cannot be resurrected by a
/// poll snapshot that predates the archive.
private func applyWorktreeArchivedDelta(_ delta: WorktreeIDDelta) {
    recentlyArchivedWorktreeIDs[delta.worktreeID] = Date()
    for repoID in worktrees.keys {
        worktrees[repoID]?.removeAll { $0.id == delta.worktreeID }
    }
    selectedWorktreeIDs.remove(delta.worktreeID)
    terminals.removeValue(forKey: delta.worktreeID)
}
```

This mirrors what `archiveWorktree` does locally, so an archive triggered elsewhere produces the same UI result. Both paths are idempotent (re-inserting a tombstone / `removeAll` on an absent ID are both no-ops).

**Testing:**
Add to `Tests/TBDAppTests/ArchiveTombstoneTests.swift` an AC3.1 test. `AppState` is `@MainActor`; mark the test `@MainActor`. Construct `AppState(userDefaults: UserDefaults(suiteName:)!)` with an isolated suite (tear down with `removePersistentDomain(forName:)` per project CLAUDE.md). Seed `state.worktrees = [repoID: [worktree]]` directly, call `state.handleDelta(.worktreeArchived(WorktreeIDDelta(worktreeID: worktree.id)))`, then assert:
- `state.worktrees[repoID]` no longer contains `worktree.id`.
- `state.recentlyArchivedWorktreeIDs[worktree.id]` is non-nil.

`handleDelta` is synchronous, so no awaiting is needed. Do not call any `daemonClient` methods.

**Verification:**
Run: `swift build && swift test --filter ArchiveTombstoneTests`
Expected: builds; all tests pass including the new AC3.1 test.

**Commit:** `fix: handle worktreeArchived delta and tombstone optimistic archive`
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Clear the tombstone on revive (symmetric path)

**Verifies:** AC4.1

**Files:**
- Modify: `Sources/TBDApp/AppState+Worktrees.swift` — `reviveWorktree`, lines 78-104.

**Implementation:**

`reviveWorktree` revives an archived worktree and expects it to reappear. If the worktree was archived within the last 30s its ID is still tombstoned, and `refreshWorktrees` would keep hiding it. On a successful revive, clear the tombstone before refreshing.

In `reviveWorktree`, in the success branch, after `revivingArchived[id] = .done(snapshot: snapshot)` and before `await refreshWorktrees()`:

```swift
revivingArchived[id] = .done(snapshot: snapshot)
recentlyArchivedWorktreeIDs.removeValue(forKey: id)
await refreshWorktrees()
```

**Testing:**
Add an AC4.1 test to `ArchiveTombstoneTests.swift`, `@MainActor`. Reviving end-to-end needs a daemon (`reviveWorktree` awaits `daemonClient.reviveWorktree`), which cannot be mocked here — so instead unit-test the tombstone-clearing as a direct state assertion: seed `state.recentlyArchivedWorktreeIDs = [id: Date()]`, call `state.recentlyArchivedWorktreeIDs.removeValue(forKey: id)` is trivial — instead, verify the *intended invariant* by asserting that after a tombstone is cleared, `AppState.visibleWorktrees(from: [activeWtWithId], tombstones: Set(state.recentlyArchivedWorktreeIDs.keys))` includes the worktree. This proves clearing the tombstone makes the row visible again.

If, while implementing, you find `reviveWorktree` can be exercised far enough without a live daemon to assert the `removeValue` runs, prefer that. Otherwise the invariant test above is sufficient — note the limitation in the commit body.

**Verification:**
Run: `swift build && swift test --filter ArchiveTombstoneTests`
Expected: builds; all tests pass.

**Commit:** `fix: clear archive tombstone on revive so revived worktrees reappear`
<!-- END_TASK_4 -->

<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_5 -->
### Task 5: Full verification

**Files:** none (verification only).

**Step 1: Full build + test**

Run: `swift build`
Expected: no errors.

Run: `swift test`
Expected: all tests pass (existing + new `ArchiveTombstoneTests`).

**Step 2: Lint**

Run: `swift package plugin --allow-writing-to-package-directory swiftlint --strict`
Expected: no violations (note the `no_print_in_sources` rule — use `os.Logger` if any logging is added; none should be needed).

**Step 3: Manual verification**

Restart and observe the archive jitter is gone:

Run: `scripts/restart.sh` (relative path, from the worktree cwd)
Then verify exactly one daemon + one app process from this worktree:
Run: `ps aux | grep -E "\.build/debug/TBD" | grep -v grep`

In the app, archive a worktree with at least one terminal and watch the sidebar row: it must disappear once and stay gone — no reappearance after ~2s. Repeat 3-4 times. Then revive an archived worktree and confirm its row reappears.

**Step 4: Commit any final touch-ups**

If steps 1-3 surfaced fixes, commit them: `fix: <description>`. Otherwise nothing to commit.
<!-- END_TASK_5 -->

---

## Notes for the executor

- `AppState` is `@MainActor`; all of `recentlyArchivedWorktreeIDs`, `refreshWorktrees`, `handleDelta`, `archiveWorktree`, `reviveWorktree` run on the main actor — no extra synchronization needed.
- There is **no `DaemonClient` mock/protocol** in this codebase. Do not introduce one for this fix. Keep testable logic in the pure static helpers (Task 1) and synchronous delta handler (Task 3); that is why the plan is structured this way.
- Project CLAUDE.md: tests that construct `AppState` and touch `UserDefaults` must use `AppState(userDefaults: UserDefaults(suiteName:)!)` and tear the suite down with `removePersistentDomain(forName:)`.
- `no_print_in_sources` SwiftLint rule applies to `Sources/` — use `os.Logger` if logging is needed (it should not be for this fix).
- Commit after each task with the conventional-commit message given. Verify `swift build` before each commit.
