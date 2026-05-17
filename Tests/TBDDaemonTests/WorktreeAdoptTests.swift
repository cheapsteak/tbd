import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Test func testAdoptInsertsRowForExistingWorktree() async throws {
    let (tempDir, repoDir, worktreePath, branch) = try await makeRepoWithExternalWorktree()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )

    let outcome = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
    guard case .inserted(let result) = outcome else {
        Issue.record("expected .inserted, got \(outcome)")
        return
    }

    #expect(result.status == .active)
    #expect(result.path == worktreePath)
    #expect(result.branch == branch)
    #expect(result.name == "feature-x")
    #expect(result.repoID == repo.id)
}

@Test func testAdoptIsIdempotentForActiveRow() async throws {
    let (tempDir, repoDir, worktreePath, _) = try await makeRepoWithExternalWorktree()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )

    let firstOutcome = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
    guard case .inserted(let first) = firstOutcome else {
        Issue.record("expected .inserted, got \(firstOutcome)")
        return
    }
    let secondOutcome = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
    guard case .unchanged(let second) = secondOutcome else {
        Issue.record("expected .unchanged, got \(secondOutcome)")
        return
    }

    #expect(first.id == second.id)
    let allActive = try await db.worktrees.list(repoID: repo.id, status: .active)
    #expect(allActive.filter { $0.path == worktreePath }.count == 1)
}

@Test func testAdoptRevivesArchivedRow() async throws {
    let (tempDir, repoDir, worktreePath, _) = try await makeRepoWithExternalWorktree()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )

    let firstOutcome = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
    guard case .inserted(let first) = firstOutcome else {
        Issue.record("expected .inserted, got \(firstOutcome)")
        return
    }
    try await db.worktrees.updateStatus(id: first.id, status: .archived)

    let revivedOutcome = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
    guard case .revived(let revived) = revivedOutcome else {
        Issue.record("expected .revived, got \(revivedOutcome)")
        return
    }
    #expect(revived.id == first.id)
    #expect(revived.status == .active)
}

/// Revival must honor a `displayName` override — without this, a user
/// re-adopting an archived worktree with `--name "New Label"` would silently
/// keep the old archived name.
@Test func testAdoptRevivalAppliesDisplayNameOverride() async throws {
    let (tempDir, repoDir, worktreePath, _) = try await makeRepoWithExternalWorktree()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )

    let firstOutcome = try await lifecycle.adoptWorktree(
        repoID: repo.id, path: worktreePath, displayName: "Original"
    )
    guard case .inserted(let first) = firstOutcome else {
        Issue.record("expected .inserted, got \(firstOutcome)")
        return
    }
    try await db.worktrees.updateStatus(id: first.id, status: .archived)

    let revivedOutcome = try await lifecycle.adoptWorktree(
        repoID: repo.id, path: worktreePath, displayName: "Renamed"
    )
    guard case .revived(let revived) = revivedOutcome else {
        Issue.record("expected .revived, got \(revivedOutcome)")
        return
    }
    #expect(revived.id == first.id)
    #expect(revived.displayName == "Renamed")
}

@Test func testAdoptRejectsPathNotInGitWorktreeList() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-adopt-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    let bogusPath = tempDir.appendingPathComponent("not-a-real-worktree").path
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: bogusPath, withIntermediateDirectories: true)
    try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )

    await #expect(throws: WorktreeAdoptError.self) {
        _ = try await lifecycle.adoptWorktree(repoID: repo.id, path: bogusPath)
    }
}

@Test func testAdoptErrorsForUnknownRepo() async throws {
    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let bogusRepoID = UUID()
    await #expect(throws: WorktreeLifecycleError.self) {
        _ = try await lifecycle.adoptWorktree(repoID: bogusRepoID, path: "/tmp/anywhere")
    }
}

@Test func testAdoptHonorsDisplayNameOverride() async throws {
    let (tempDir, repoDir, worktreePath, _) = try await makeRepoWithExternalWorktree()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )

    let outcome = try await lifecycle.adoptWorktree(
        repoID: repo.id, path: worktreePath, displayName: "Custom Label"
    )
    let result = outcome.worktree
    #expect(result.displayName == "Custom Label")
    #expect(result.name == "feature-x")
}

/// Detached-HEAD worktrees are accepted (no crash, no error), but TBD's
/// `git worktree list --porcelain` parser only extracts the `branch ` line —
/// detached worktrees emit `HEAD <sha>` + `detached` instead, so the branch
/// column ends up empty. Documented as a known limitation in the design doc;
/// real-world Conductor migrations don't hit this because Conductor always
/// names branches `cw/<name>`. This test pins the behavior so future parser
/// changes that surface the SHA will deliberately break it.
@Test func testAdoptDetachedHeadStoresEmptyBranch() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-adopt-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    let extDir = tempDir.appendingPathComponent("external-worktrees/detached")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: extDir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
    try await shell("git worktree add --detach '\(extDir.path)' HEAD", at: repoDir)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true), hooks: HookResolver()
    )
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )

    // Resolve via realpath so the path matches what git's worktree-list
    // reports (/var/folders/... canonicalizes to /private/var/folders/...
    // on macOS, and Foundation's URL APIs don't follow `/var` → `/private/var`).
    var resolvedBuf = [Int8](repeating: 0, count: Int(PATH_MAX))
    guard realpath(extDir.path, &resolvedBuf) != nil else {
        throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "realpath failed for \(extDir.path)"])
    }
    let canonicalPath = resolvedBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    let outcome = try await lifecycle.adoptWorktree(repoID: repo.id, path: canonicalPath)
    let result = outcome.worktree
    #expect(result.status == .active)
    #expect(result.name == "detached")
    #expect(result.branch == "")
}
