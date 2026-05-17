import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Helper to run shell commands in tests.
private func shell(_ command: String, at dir: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = dir
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@test.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@test.com",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        throw NSError(domain: "shell", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "Command failed: \(command)\n\(output)"])
    }
}

/// Sets up a temp git repo with one worktree at an arbitrary (non-canonical) path.
/// Returns the canonicalized path (via realpath) to match what git worktree list reports.
private func makeRepoWithExternalWorktree() async throws -> (tempDir: URL, repoDir: URL, worktreePath: String, worktreeBranch: String) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-adopt-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    let extDir = tempDir.appendingPathComponent("external-worktrees/feature-x")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: extDir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
    try await shell("git worktree add -b feature-x '\(extDir.path)'", at: repoDir)

    // Get the realpath-canonicalized path (git worktree list returns realpath)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/realpath")
    process.arguments = [extDir.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let canonicalPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? extDir.path

    return (tempDir, repoDir, canonicalPath, "feature-x")
}

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

    let result = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)

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

    let first = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
    let second = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)

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

    let first = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
    try await db.worktrees.updateStatus(id: first.id, status: .archived)

    let revived = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
    #expect(revived.id == first.id)
    #expect(revived.status == .active)
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

    let result = try await lifecycle.adoptWorktree(
        repoID: repo.id, path: worktreePath, displayName: "Custom Label"
    )
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
    let canonicalPath = String(cString: resolvedBuf)
    let result = try await lifecycle.adoptWorktree(repoID: repo.id, path: canonicalPath)
    #expect(result.status == .active)
    #expect(result.name == "detached")
    #expect(result.branch == "")
}
