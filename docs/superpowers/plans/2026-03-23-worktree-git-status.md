# Worktree Git Status Indicators — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show git-level status indicators (current, behind, conflicts, merged) on worktree sidebar items so users can see at a glance which branches need attention.

**Architecture:** New `GitStatus` enum and `gitStatus` field on the `Worktree` model, persisted in SQLite. The daemon computes status via git commands in a non-blocking background task when main moves (after merge or fetch). The app renders a small SF Symbol icon next to the worktree name.

**Tech Stack:** Swift, GRDB, SwiftUI, git CLI, Swift Testing

**Spec:** `docs/superpowers/specs/2026-03-23-worktree-git-status-design.md`

---

## File Map

**Create:**
- `Tests/TBDDaemonTests/GitStatusTests.swift` — tests for git status computation and DB updates

**Modify:**
- `Sources/TBDShared/Models.swift` — add `GitStatus` enum and `gitStatus` field to `Worktree`
- `Sources/TBDShared/RPCProtocol.swift` — (no new RPC method needed — status is computed internally by daemon)
- `Sources/TBDDaemon/Database/Database.swift` — add v2 migration for `gitStatus` column
- `Sources/TBDDaemon/Database/WorktreeStore.swift` — add `gitStatus` to record, add `updateGitStatus()` method
- `Sources/TBDDaemon/Git/GitManager.swift` — add `isMergeBaseAncestor()` method
- `Sources/TBDDaemon/Server/StateSubscription.swift` — add `worktreeGitStatusChanged` delta case
- `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift` — add `refreshGitStatuses()` method, call after merge
- `Sources/TBDDaemon/Server/RPCRouter.swift` — set merged status after squash merge, trigger refresh after merge
- `Sources/TBDDaemon/Daemon.swift` — pass subscriptions to lifecycle, add startup refresh
- `Sources/TBDApp/Sidebar/WorktreeRowView.swift` — render git status icon
- `Sources/TBDApp/AppState.swift` — update worktree gitStatus from polled data

---

### Task 1: Add GitStatus enum and field to data model

**Files:**
- Modify: `Sources/TBDShared/Models.swift:22-52`

- [ ] **Step 1: Add GitStatus enum after WorktreeStatus**

Add after line 24 in `Models.swift`:

```swift
public enum GitStatus: String, Codable, Sendable {
    case current     // branch is ahead of or equal to main — no action needed
    case behind      // main has commits not on this branch
    case conflicts   // would conflict if merged into main
    case merged      // squash-merged into main (set by TBD's merge flow)
}
```

- [ ] **Step 2: Add gitStatus field to Worktree struct**

Add `public var gitStatus: GitStatus` after the `tmuxServer` field (line 36). Default to `.current` in the initializer.

```swift
public var gitStatus: GitStatus

// In init, add parameter with default:
// gitStatus: GitStatus = .current
// and assign:
// self.gitStatus = gitStatus
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | head -30`

This will fail because `WorktreeRecord` doesn't map the new field yet — that's expected. Verify the error is about `WorktreeRecord`, not a syntax issue in `Models.swift`.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDShared/Models.swift
git commit -m "feat: add GitStatus enum and gitStatus field to Worktree model"
```

---

### Task 2: Add database migration and update WorktreeRecord

**Files:**
- Modify: `Sources/TBDDaemon/Database/Database.swift:43-92`
- Modify: `Sources/TBDDaemon/Database/WorktreeStore.swift:6-47`

- [ ] **Step 1: Write failing test for migration**

Create `Tests/TBDDaemonTests/GitStatusTests.swift`:

```swift
import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Git Status Tests")
struct GitStatusTests {
    @Test func worktreeHasDefaultGitStatus() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "test-server"
        )
        #expect(wt.gitStatus == .current)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GitStatusTests 2>&1 | tail -20`
Expected: FAIL (gitStatus not recognized in WorktreeRecord)

- [ ] **Step 3: Add v2 migration in Database.swift**

After the v1 migration block (after line 89), add:

```swift
migrator.registerMigration("v2") { db in
    try db.alter(table: "worktree") { t in
        t.add(column: "gitStatus", .text).notNull().defaults(to: "current")
    }
}
```

- [ ] **Step 4: Update WorktreeRecord with gitStatus**

In `WorktreeStore.swift`, add to `WorktreeRecord` struct (after line 18):

```swift
var gitStatus: String
```

In `init(from wt:)` (after line 30), add:

```swift
self.gitStatus = wt.gitStatus.rawValue
```

In `toModel()` (after line 44, inside the Worktree initializer), add the `gitStatus` parameter:

```swift
gitStatus: GitStatus(rawValue: gitStatus) ?? .current,
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter GitStatusTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Database/Database.swift Sources/TBDDaemon/Database/WorktreeStore.swift Tests/TBDDaemonTests/GitStatusTests.swift
git commit -m "feat: add gitStatus column to worktree table with v2 migration"
```

---

### Task 3: Add updateGitStatus method to WorktreeStore

**Files:**
- Modify: `Sources/TBDDaemon/Database/WorktreeStore.swift:154-163` (after `rename()`)

- [ ] **Step 1: Write failing test**

Add to `GitStatusTests.swift`:

```swift
@Test func updateGitStatus() async throws {
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
        path: "/tmp/test-repo-\(UUID().uuidString)",
        displayName: "test",
        defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "test-wt",
        branch: "tbd/test-wt",
        path: "/tmp/test-wt-\(UUID().uuidString)",
        tmuxServer: "test-server"
    )
    #expect(wt.gitStatus == .current)

    try await db.worktrees.updateGitStatus(id: wt.id, gitStatus: .conflicts)
    let updated = try await db.worktrees.get(id: wt.id)
    #expect(updated?.gitStatus == .conflicts)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "updateGitStatus" 2>&1 | tail -20`
Expected: FAIL — `updateGitStatus` not found

- [ ] **Step 3: Implement updateGitStatus**

Add to `WorktreeStore` after the `rename()` method:

```swift
/// Update a worktree's git status.
public func updateGitStatus(id: UUID, gitStatus: GitStatus) async throws {
    try await writer.write { db in
        guard var record = try WorktreeRecord.fetchOne(db, key: id.uuidString) else {
            throw DatabaseError(message: "Worktree not found")
        }
        record.gitStatus = gitStatus.rawValue
        try record.update(db)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "updateGitStatus" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Database/WorktreeStore.swift Tests/TBDDaemonTests/GitStatusTests.swift
git commit -m "feat: add updateGitStatus method to WorktreeStore"
```

---

### Task 4: Add isMergeBaseAncestor to GitManager

**Files:**
- Modify: `Sources/TBDDaemon/Git/GitManager.swift`

- [ ] **Step 1: Write failing test**

Add to `GitStatusTests.swift`:

```swift
@Test func isMergeBaseAncestor() async throws {
    // Create a temp repo with a branch
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("git-status-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let git = GitManager()

    // Init repo with initial commit
    func shell(_ cmd: String) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = repoDir
        try p.run()
        p.waitUntilExit()
    }

    try await shell("git init -b main")
    try await shell("git config user.email 'test@test.com'")
    try await shell("git config user.name 'Test'")
    try await shell("git commit --allow-empty -m 'init'")

    // Create a branch and add a commit
    try await shell("git checkout -b feature")
    try await shell("git commit --allow-empty -m 'feature commit'")

    // Main is an ancestor of feature
    let isAncestor = await git.isMergeBaseAncestor(
        repoPath: repoDir.path, base: "main", branch: "feature"
    )
    #expect(isAncestor == true)

    // Feature is NOT an ancestor of main (main hasn't moved)
    // But we want to check: is main ancestor of feature? Yes.
    // Now add a commit to main so they diverge
    try await shell("git checkout main")
    try await shell("git commit --allow-empty -m 'main moved'")

    let isDiverged = await git.isMergeBaseAncestor(
        repoPath: repoDir.path, base: "main", branch: "feature"
    )
    #expect(isDiverged == false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "isMergeBaseAncestor" 2>&1 | tail -20`
Expected: FAIL — method doesn't exist

- [ ] **Step 3: Implement isMergeBaseAncestor**

Add to `GitManager` after `commitCount()` (after line 133):

```swift
/// Returns true if `base` is an ancestor of `branch` (i.e., branch is ahead or equal, no divergence).
public func isMergeBaseAncestor(repoPath: String, base: String, branch: String) async -> Bool {
    do {
        _ = try await run(arguments: ["merge-base", "--is-ancestor", base, branch], at: repoPath)
        return true  // exit code 0 means base IS an ancestor
    } catch {
        return false  // exit code 1 means it's NOT an ancestor
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter "isMergeBaseAncestor" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Git/GitManager.swift Tests/TBDDaemonTests/GitStatusTests.swift
git commit -m "feat: add isMergeBaseAncestor to GitManager"
```

---

### Task 5: Add StateDelta case for git status changes

**Files:**
- Modify: `Sources/TBDDaemon/Server/StateSubscription.swift:7-18`

- [ ] **Step 1: Add delta payload struct**

Add after `TerminalIDDelta` (after line 89):

```swift
/// Delta payload for worktree git status change.
public struct WorktreeGitStatusDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let gitStatus: GitStatus
    public init(worktreeID: UUID, gitStatus: GitStatus) {
        self.worktreeID = worktreeID; self.gitStatus = gitStatus
    }
}
```

- [ ] **Step 2: Add delta case**

Add to `StateDelta` enum (after line 17):

```swift
case worktreeGitStatusChanged(WorktreeGitStatusDelta)
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Server/StateSubscription.swift
git commit -m "feat: add worktreeGitStatusChanged delta case"
```

---

### Task 6: Add refreshGitStatuses to WorktreeLifecycle

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift`

- [ ] **Step 1: Write failing test**

Add to `GitStatusTests.swift`:

```swift
@Test func refreshGitStatusesSetsConflicts() async throws {
    // Create temp repo with main + feature branch that diverge
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("git-status-refresh-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    let wtDir = tempDir.appendingPathComponent("feature-wt")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    func shell(_ cmd: String, at dir: URL? = nil) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir ?? repoDir
        try p.run()
        p.waitUntilExit()
    }

    try await shell("git init -b main")
    try await shell("git config user.email 'test@test.com'")
    try await shell("git config user.name 'Test'")
    // Create a file so we can make conflicting changes
    try "hello".write(to: repoDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await shell("git add . && git commit -m 'init'")

    // Create worktree with a branch
    try await shell("git worktree add \(wtDir.path) -b tbd/feature")

    // Make conflicting changes on both sides
    try "main-change".write(to: repoDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await shell("git add . && git commit -m 'main change'")
    try "feature-change".write(to: wtDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await shell("git add . && git commit -m 'feature change'", at: wtDir)

    // Set up DB with repo + worktree
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
        path: repoDir.path,
        displayName: "test",
        defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id,
        name: "feature",
        branch: "tbd/feature",
        path: wtDir.path,
        tmuxServer: "test-server"
    )
    #expect(wt.gitStatus == .current)

    let git = GitManager()
    let subscriptions = StateSubscriptionManager()
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: git,
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        subscriptions: subscriptions
    )

    await lifecycle.refreshGitStatuses(repoID: repo.id)

    let updated = try await db.worktrees.get(id: wt.id)
    #expect(updated?.gitStatus == .conflicts)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "refreshGitStatusesSetsConflicts" 2>&1 | tail -20`
Expected: FAIL — `refreshGitStatuses` doesn't exist. Also check if `WorktreeLifecycle.init` needs `subscriptions` parameter — if not, we'll add it.

- [ ] **Step 3: Add subscriptions parameter to WorktreeLifecycle**

Check the current `WorktreeLifecycle` init. If it doesn't accept a `subscriptions` parameter, add one:

```swift
public let subscriptions: StateSubscriptionManager?

// In init, add:
// subscriptions: StateSubscriptionManager? = nil
```

Store it and use it for broadcasting git status changes.

- [ ] **Step 4: Implement refreshGitStatuses**

Add to `WorktreeLifecycle`:

```swift
/// Recompute git status for all active worktrees in a repo.
/// Runs git checks concurrently and updates the DB + broadcasts deltas.
/// Safe to call from a background Task — does not block the caller.
public func refreshGitStatuses(repoID: UUID) async {
    guard let repo = try? await db.repos.get(id: repoID) else { return }
    let worktrees = (try? await db.worktrees.list(repoID: repoID, status: .active)) ?? []

    await withTaskGroup(of: Void.self) { group in
        for wt in worktrees {
            // Skip already-merged worktrees (terminal state)
            if wt.gitStatus == .merged { continue }

            group.addTask {
                let newStatus = await self.computeGitStatus(
                    repoPath: repo.path,
                    defaultBranch: repo.defaultBranch,
                    branch: wt.branch
                )
                guard newStatus != wt.gitStatus else { return }
                try? await self.db.worktrees.updateGitStatus(id: wt.id, gitStatus: newStatus)
                self.subscriptions?.broadcast(delta: .worktreeGitStatusChanged(
                    WorktreeGitStatusDelta(worktreeID: wt.id, gitStatus: newStatus)
                ))
            }
        }
    }
}

/// Compute git status for a single branch relative to the default branch.
private func computeGitStatus(repoPath: String, defaultBranch: String, branch: String) async -> GitStatus {
    // Check if default branch is an ancestor of the feature branch
    let isAncestor = await git.isMergeBaseAncestor(
        repoPath: repoPath, base: defaultBranch, branch: branch
    )
    if isAncestor {
        return .current
    }

    // Branches have diverged — check for conflicts
    let (hasConflicts, _) = await git.checkMergeConflicts(
        repoPath: repoPath, branch: branch, targetBranch: defaultBranch
    )
    return hasConflicts ? .conflicts : .behind
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter "refreshGitStatusesSetsConflicts" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 6: Write test for behind status**

Add to `GitStatusTests.swift`:

```swift
@Test func refreshGitStatusesSetsBehind() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("git-status-behind-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    let wtDir = tempDir.appendingPathComponent("feature-wt")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    func shell(_ cmd: String, at dir: URL? = nil) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir ?? repoDir
        try p.run()
        p.waitUntilExit()
    }

    try await shell("git init -b main")
    try await shell("git config user.email 'test@test.com'")
    try await shell("git config user.name 'Test'")
    try "hello".write(to: repoDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await shell("git add . && git commit -m 'init'")
    try await shell("git worktree add \(wtDir.path) -b tbd/feature")

    // Only main moves — feature stays put, no conflicting file changes
    try "new-content".write(to: repoDir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
    try await shell("git add . && git commit -m 'main adds other file'")

    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "feature", branch: "tbd/feature",
        path: wtDir.path, tmuxServer: "test-server"
    )

    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(), subscriptions: StateSubscriptionManager()
    )

    await lifecycle.refreshGitStatuses(repoID: repo.id)

    let updated = try await db.worktrees.get(id: wt.id)
    #expect(updated?.gitStatus == .behind)
}
```

- [ ] **Step 7: Run test**

Run: `swift test --filter "refreshGitStatusesSetsBehind" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 8: Write test that merged worktrees are skipped**

Add to `GitStatusTests.swift`:

```swift
@Test func refreshGitStatusesSkipsMerged() async throws {
    let db = try TBDDatabase(inMemory: true)
    let repo = try await db.repos.create(
        path: "/tmp/test-repo-\(UUID().uuidString)",
        displayName: "test", defaultBranch: "main"
    )
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "done-wt", branch: "tbd/done-wt",
        path: "/tmp/done-wt-\(UUID().uuidString)", tmuxServer: "test-server"
    )
    try await db.worktrees.updateGitStatus(id: wt.id, gitStatus: .merged)

    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(), subscriptions: StateSubscriptionManager()
    )

    await lifecycle.refreshGitStatuses(repoID: repo.id)

    let updated = try await db.worktrees.get(id: wt.id)
    #expect(updated?.gitStatus == .merged)
}
```

- [ ] **Step 9: Run test**

Run: `swift test --filter "refreshGitStatusesSkipsMerged" 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 10: Run all git status tests**

Run: `swift test --filter GitStatusTests 2>&1 | tail -20`
Expected: All PASS

- [ ] **Step 11: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift Tests/TBDDaemonTests/GitStatusTests.swift
git commit -m "feat: add refreshGitStatuses to compute git status for all active worktrees"
```

---

### Task 7: Wire up triggers — set merged after squash merge, refresh after merge

**Files:**
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift:251-263`

- [ ] **Step 1: Set merged status and trigger refresh after squash merge**

In `handleWorktreeMerge()` (line 251), after the merge succeeds and before broadcasting, add:

```swift
// Mark the merged worktree's git status as .merged
try await db.worktrees.updateGitStatus(id: params.worktreeID, gitStatus: .merged)

// Find the repo for this worktree to refresh other worktrees
if let mergedWt = try await db.worktrees.get(id: params.worktreeID) {
    let repoID = mergedWt.repoID
    // Broadcast merged status for this worktree
    subscriptions.broadcast(delta: .worktreeGitStatusChanged(
        WorktreeGitStatusDelta(worktreeID: params.worktreeID, gitStatus: .merged)
    ))
    // Refresh all other active worktrees in background (main just moved)
    Task {
        await lifecycle.refreshGitStatuses(repoID: repoID)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter.swift
git commit -m "feat: set merged status after squash merge and trigger git status refresh"
```

---

### Task 8: Wire up Daemon.swift — pass subscriptions to lifecycle + startup refresh

**Files:**
- Modify: `Sources/TBDDaemon/Daemon.swift:44-95`

**Important context:** In `Daemon.swift`, initialization order is:
- Line 52-55: git, tmux, hooks, lifecycle are created
- Line 58: StateSubscriptionManager is created
- Line 62-68: RPCRouter is created (accepts subscriptions in its init but currently not receiving it)

The lifecycle needs `subscriptions` to broadcast git status deltas. The RPCRouter also needs `subscriptions`.

- [ ] **Step 1: Reorder initialization so subscriptions is created before lifecycle**

Move `StateSubscriptionManager` creation before `WorktreeLifecycle`. Update `Daemon.start()` lines 51-68:

```swift
// 6. Initialize state subscriptions (before lifecycle/router so they can broadcast)
let subs = StateSubscriptionManager()
self.subscriptions = subs

// 7. Initialize managers
let git = GitManager()
let tmux = TmuxManager()
let hooks = HookResolver()
let lifecycle = WorktreeLifecycle(db: database, git: git, tmux: tmux, hooks: hooks, subscriptions: subs)

// 8. Initialize RPC router
let rpcRouter = RPCRouter(
    db: database,
    lifecycle: lifecycle,
    tmux: tmux,
    git: git,
    startTime: startTime,
    subscriptions: subs
)
```

- [ ] **Step 2: Add startup git status refresh after reconciliation**

After the reconciliation loop (after line 93), add:

```swift
// 12. Refresh git statuses for all repos in background (cold recovery)
Task {
    let allRepos = (try? await database.repos.list()) ?? []
    for repo in allRepos {
        await lifecycle.refreshGitStatuses(repoID: repo.id)
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Daemon.swift
git commit -m "feat: pass subscriptions to lifecycle and refresh git statuses on startup"
```

---

### Task 9: Render git status icon in WorktreeRowView

**Files:**
- Modify: `Sources/TBDApp/Sidebar/WorktreeRowView.swift:4-87`

- [ ] **Step 1: Add computed properties for git status display**

Add after `badgeColor` (after line 35):

```swift
private var gitStatusIcon: String? {
    guard !isMain else { return nil }
    switch worktree.gitStatus {
    case .current: return nil
    case .behind: return "arrow.down"
    case .conflicts: return "exclamationmark.triangle"
    case .merged: return "checkmark.circle"
    }
}

private var gitStatusColor: Color {
    switch worktree.gitStatus {
    case .current: return .secondary
    case .behind: return .secondary
    case .conflicts: return .orange
    case .merged: return .green
    }
}
```

- [ ] **Step 2: Add icon to HStack**

In the `body` HStack, after the notification badge circle (after line 48) and before the text/edit field (before line 49), add:

```swift
if let icon = gitStatusIcon {
    Image(systemName: icon)
        .font(.caption2)
        .foregroundStyle(gitStatusColor)
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Sidebar/WorktreeRowView.swift
git commit -m "feat: render git status icon in worktree sidebar row"
```

---

### Task 10: Ensure AppState picks up gitStatus from polling

**Files:**
- Modify: `Sources/TBDApp/AppState.swift:96-135`

- [ ] **Step 1: Update refreshWorktrees to detect gitStatus changes**

The current `refreshWorktrees()` only checks if worktree IDs changed. It needs to also detect when `gitStatus` changes. Update the comparison logic in `refreshWorktrees()`.

In the `else` branch (lines 110-119), change the comparison to also check for content changes:

```swift
// Replace the ID-only comparison with one that also catches gitStatus changes
let oldWts = worktrees.values.flatMap { $0 }
let newWts = grouped.values.flatMap { $0 }
let changed = oldWts.count != newWts.count ||
    zip(oldWts.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
        newWts.sorted(by: { $0.id.uuidString < $1.id.uuidString }))
    .contains(where: { $0.id != $1.id || $0.gitStatus != $1.gitStatus || $0.displayName != $1.displayName })
if changed {
    worktrees = grouped
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/AppState.swift
git commit -m "feat: detect gitStatus changes in polling refresh"
```

---

### Task 11: Full integration test and cleanup

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass

- [ ] **Step 2: Build the full project**

Run: `swift build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Manual smoke test**

Run: `scripts/restart.sh`

Verify:
- Worktrees show no icon by default (current status)
- After merging a worktree, it shows a green checkmark
- Other worktrees refresh their status after the merge

- [ ] **Step 4: Final commit if any cleanup needed**

```bash
git add -A
git commit -m "fix: cleanup from integration testing"
```

---

### Known Gaps (out of scope for this plan)

- **Fetch/pull trigger**: The spec lists "after fetch/pull of main" as a trigger point. No fetch/pull RPC handler exists yet. When one is added, it should call `lifecycle.refreshGitStatuses(repoID:)` in a background Task after completing the fetch.
