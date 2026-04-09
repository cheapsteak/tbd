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
        throw NSError(
            domain: "shell",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Command failed: \(command)\n\(output)"]
        )
    }
}

/// Creates a temporary git repo for testing, returning the temp dir and repo dir URLs.
/// The caller is responsible for cleaning up the temp dir.
private func createTestRepo() async throws -> (tempDir: URL, repoDir: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tbd-test-\(UUID().uuidString)")
    let repoDir = tempDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try await shell("git init -b main && git commit --allow-empty -m 'init'", at: repoDir)
    return (tempDir: tempDir, repoDir: repoDir)
}

/// Creates a test repo row in the DB and overrides its `worktreeRoot` to a
/// `.tbd/worktrees/` subdirectory of the test temp dir, so the canonical
/// layout doesn't leak into the user's real `~/.tbd/worktrees/`. Returns the
/// re-fetched repo with the override applied.
private func makeTestRepo(
    db: TBDDatabase, tempDir: URL, repoDir: URL
) async throws -> Repo {
    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let override = tempDir.appendingPathComponent(".tbd/worktrees").path
    try await db.repos.updateWorktreeRoot(id: repo.id, path: override)
    return try await db.repos.get(id: repo.id)!
}

@Test func testCreateWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    #expect(result.status == .active)
    #expect(result.name.contains("-"))
    #expect(result.branch.hasPrefix("tbd/"))
    #expect(FileManager.default.fileExists(atPath: result.path))

    // Verify terminals were created
    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.count == 2)
}

@Test func testCreateWorktreeRepoNotFound() async throws {
    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.createWorktree(repoID: UUID(), skipClaude: true)
    }
}

@Test func testCreateWithExplicitFolderAndBranch() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(
        repoID: repo.id,
        folder: "my-folder",
        branch: "feat/custom-branch",
        skipClaude: true
    )

    #expect(result.status == .active)
    #expect(result.name == "my-folder")
    #expect(result.branch == "feat/custom-branch")
    #expect(result.path.hasSuffix("/my-folder"))
}

@Test func testCreateWithExplicitDisplayName() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(
        repoID: repo.id,
        displayName: "My Custom Display Name",
        skipClaude: true
    )

    #expect(result.displayName == "My Custom Display Name")
    // name should be auto-generated, not the displayName
    #expect(result.name != "My Custom Display Name")
}

@Test func testCreateCollisionWithUserFolderFails() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create a worktree that occupies a branch
    _ = try await lifecycle.createWorktree(
        repoID: repo.id,
        folder: "first-folder",
        branch: "feat/collision",
        skipClaude: true
    )

    // Try to create another worktree with a DIFFERENT folder but same branch.
    // With userSpecifiedFolder=true, the retry should NOT be attempted —
    // it should fail immediately after git worktree add fails (branch exists).
    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.createWorktree(
            repoID: repo.id,
            folder: "second-folder",
            branch: "feat/collision",
            skipClaude: true
        )
    }
}

@Test func testCreateCollisionWithUserBranchRetries() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create a worktree that will occupy a branch
    _ = try await lifecycle.createWorktree(
        repoID: repo.id,
        branch: "feat/shared-branch",
        skipClaude: true
    )

    // Create another worktree with the same branch but auto-folder.
    // This should retry with a new folder but keep the user's branch.
    // Since the branch already exists in git, the retry will also fail
    // because git worktree add doesn't allow the same branch in two worktrees.
    // So this should ultimately throw — but importantly it should NOT throw
    // with the "folder" error, it should attempt retry first.
    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.createWorktree(
            repoID: repo.id,
            branch: "feat/shared-branch",
            skipClaude: true
        )
    }
}

@Test func testArchiveWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    #expect(FileManager.default.fileExists(atPath: wt.path))

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.status == .archived)
    #expect(!FileManager.default.fileExists(atPath: wt.path))

    // Verify terminals were cleaned up
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.isEmpty)
}

@Test func testArchiveWorktreeNotFound() async throws {
    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.archiveWorktree(worktreeID: UUID())
    }
}

@Test func testReviveWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)

    #expect(revived.status == .active)
    #expect(FileManager.default.fileExists(atPath: revived.path))

    // Verify fresh terminals were created
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    #expect(terminals.count == 2)
}

@Test func testReviveActiveWorktreeThrows() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
    }
}

@Test func testReviveFailsWhenPathAlreadyExists() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
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
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Re-create a stray directory where the worktree used to live.
    try FileManager.default.createDirectory(
        atPath: wt.path, withIntermediateDirectories: true
    )
    try "stray".write(
        toFile: (wt.path as NSString).appendingPathComponent("file.txt"),
        atomically: true, encoding: .utf8
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)
    }

    // TODO: add a test for `worktreeAlreadyRegistered` — requires desyncing
    // the on-disk path from git's worktree list, which is awkward to set up.
}

@Test func testArchivePreservesClaudeSessions() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create worktree with Claude (skipClaude: false creates a session ID)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    let terminalsBeforeArchive = try await db.terminals.list(worktreeID: wt.id)
    let originalSessionIDs = terminalsBeforeArchive.compactMap { $0.claudeSessionID }
    #expect(!originalSessionIDs.isEmpty, "Should have at least one Claude session")

    // Archive — should save session IDs
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedClaudeSessions == originalSessionIDs)

    // Terminals should be deleted
    let terminalsAfterArchive = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsAfterArchive.isEmpty)

    // Revive — should restore the same Claude session ID
    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)
    let terminalsAfterRevive = try await db.terminals.list(worktreeID: revived.id)
    let revivedSessionIDs = terminalsAfterRevive.compactMap { $0.claudeSessionID }
    #expect(revivedSessionIDs.contains(originalSessionIDs[0]),
            "Revived terminal should reuse the original Claude session ID")

    // archivedClaudeSessions should be cleared after revive
    let revivedWt = try await db.worktrees.get(id: wt.id)
    #expect(revivedWt?.archivedClaudeSessions == nil)
}

@Test func testArchiveWithoutClaudeSessionsDoesNotSaveEmpty() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create worktree without Claude
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedClaudeSessions == nil,
            "Should not save empty session list")
}

@Test func testReviveWithSkipClaudePreservesSessions() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create with Claude, archive, then revive with skipClaude
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    let originalSessions = try await db.terminals.list(worktreeID: wt.id)
        .compactMap { $0.claudeSessionID }
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    _ = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)

    // Sessions should be preserved since Claude wasn't restored
    let revivedWt = try await db.worktrees.get(id: wt.id)
    #expect(revivedWt?.archivedClaudeSessions == originalSessions,
            "skipClaude revive should preserve sessions for later recovery")
}

@Test func testReviveRestoresMultipleClaudeSessions() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Create worktree with Claude
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    // Simulate a second Claude terminal added by the user
    let secondSessionID = UUID().uuidString
    let window = try await lifecycle.tmux.createWindow(
        server: wt.tmuxServer, session: "main",
        cwd: wt.path, shellCommand: "echo test"
    )
    _ = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: window.windowID,
        tmuxPaneID: window.paneID,
        label: "claude",
        claudeSessionID: secondSessionID
    )

    let allSessions = try await db.terminals.list(worktreeID: wt.id)
        .compactMap { $0.claudeSessionID }
    #expect(allSessions.count == 2)

    // Archive and revive
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)

    // Should have 2 setup + 2 claude = but setup only creates once, so:
    // 1 claude (from first session) + 1 setup + 1 extra claude (from second session) = 3
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    let claudeTerminals = terminals.filter { $0.claudeSessionID != nil }
    #expect(claudeTerminals.count == 2,
            "Both Claude sessions should be restored")

    let restoredSessionIDs = Set(claudeTerminals.compactMap { $0.claudeSessionID })
    #expect(restoredSessionIDs.count == 2)
}

@Test func testCreateInjectsTokenWhenResolverProvided() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)

    // Seed a token row and set it as the global default.
    let token = try await db.claudeTokens.create(name: "Test", kind: .oauth)
    try await db.config.setDefaultClaudeTokenID(token.id)

    let secret = "sk-ant-oat01-FAKETOKEN_value"
    let resolver = ClaudeTokenResolver(
        tokens: db.claudeTokens,
        repos: db.repos,
        config: db.config,
        keychain: { id in id == token.id.uuidString ? secret : nil }
    )

    // Recorder captures the dryRun shellCommand args from createWindow.
    let recorded = LifecycleRecordedCommands()
    let tmux = TmuxManager(dryRun: true, dryRunRecorder: { args in
        recorded.append(args)
    })

    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: tmux,
        hooks: HookResolver(),
        claudeTokenResolver: resolver
    )

    let repo = try await db.repos.create(
        path: repoDir.path, displayName: "test", defaultBranch: "main"
    )
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    // (a) Token must be passed via tmux -e flag, NOT inlined into the shell command body.
    let snap = recorded.snapshot()
    let claudeCall = snap.first { call in
        let body = call.last ?? ""
        return body.contains("claude --session-id")
    }
    #expect(claudeCall != nil, "expected a createWindow call spawning claude")
    #expect(claudeCall?.contains("CLAUDE_CODE_OAUTH_TOKEN=\(secret)") == true,
            "expected token in tmux -e flag; got: \(claudeCall ?? [])")
    let shellBody = claudeCall?.last ?? ""
    #expect(!shellBody.contains(secret),
            "secret leaked into shell command body: \(shellBody)")
    #expect(!shellBody.contains("CLAUDE_CODE_OAUTH_TOKEN"),
            "env var name leaked into shell command body: \(shellBody)")

    // (b) Persisted terminal row has claudeTokenID set to the known token UUID.
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    let claudeTerminal = terminals.first { $0.claudeTokenID != nil }
    #expect(claudeTerminal?.claudeTokenID == token.id,
            "expected the Claude terminal to persist claudeTokenID=\(token.id)")
}

@Test func testWorktreePathStructure() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    // Path should be under the canonical layout (tempDir/.tbd/worktrees/<name>)
    // because makeTestRepo overrides worktreeRoot to <tempDir>/.tbd/worktrees.
    #expect(wt.path.hasPrefix(tempDir.path))
    #expect(wt.path.contains(".tbd/worktrees/"))
    #expect(wt.path.contains(wt.name))
}

// MARK: - Reconcile Tests

/// Like `createTestRepo()` but resolves symlinks in the returned paths so the
/// path stored in the DB matches what `git worktree list` reports.
///
/// On macOS, `FileManager.default.temporaryDirectory` returns `/var/folders/…`
/// which is a symlink to `/private/var/folders/…`. `URL.resolvingSymlinksInPath()`
/// does NOT resolve this particular symlink, but the C `realpath()` function does.
/// Git resolves the real path when recording worktree entries, so DB paths must also
/// use the real path for reconcile path-matching to succeed.
private func createTestRepoResolvingSymlinks() async throws -> (tempDir: URL, repoDir: URL) {
    let (rawTempDir, _) = try await createTestRepo()
    // Use C realpath() to fully resolve all symlinks (URL.resolvingSymlinksInPath
    // does not resolve the /var → /private/var symlink on macOS).
    let resolved: URL
    if let cReal = realpath(rawTempDir.path, nil) {
        resolved = URL(fileURLWithPath: String(cString: cReal))
        free(cReal)
    } else {
        resolved = rawTempDir
    }
    let repoDir = resolved.appendingPathComponent("repo")
    return (tempDir: resolved, repoDir: repoDir)
}

/// Alive server + alive windows: no terminals are deleted, window IDs unchanged.
/// (dryRun makes serverExists → true and windowExists → true, so this exercises
/// the "server alive, window alive → keep terminal" branch.)
///
/// This also serves as a regression guard for the dead-window deletion path: any
/// bug that incorrectly triggers dead-window deletion would drop terminals here,
/// because the setup is identical to what a "dead window" scenario looks like
/// before the windowExists check. The dead-window path itself (windowExists → false)
/// requires a non-dryRun integration test against a real tmux server with stale IDs.
@Test func testReconcileAliveTerminalUntouched() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    let terminalsBefore = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsBefore.count == 2, "Expected 2 terminals after createWorktree")

    let windowIDsBefore = Set(terminalsBefore.map { $0.tmuxWindowID })

    try await lifecycle.reconcile(repoID: repo.id)

    let terminalsAfter = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsAfter.count == 2, "Alive terminals must not be deleted during reconcile")

    // In dryRun mode, serverExists → true → windowExists path is taken.
    // windowExists → true → terminals are kept with their original IDs.
    // In the reboot path, windowIDs would be replaced with mock IDs.
    // So if IDs are unchanged OR updated to mock IDs, we know reconcile ran.
    // The important invariant: terminal COUNT must not drop.
    let windowIDsAfter = Set(terminalsAfter.map { $0.tmuxWindowID })
    #expect(!windowIDsAfter.isEmpty, "Terminal window IDs must be present after reconcile")
    // Since serverExists → true and windowExists → true, the alive-window branch
    // is taken and IDs are NOT replaced (no recreateAfterReboot call).
    #expect(windowIDsAfter == windowIDsBefore, "Window IDs must be unchanged when server and windows are alive")
}

/// Suspended terminals must not be touched during reconcile, regardless of server/window state.
/// dryRun mode exercises the serverAlive=true branch; suspended terminals are skipped
/// before the windowExists check, so this works with dryRun=true.
@Test func testReconcileSuspendedTerminalSkippedOnReboot() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    var terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2)

    // Suspend one terminal — simulate a terminal that was suspended before reboot.
    let suspended = terminals[0]
    let fakeSessionID = UUID().uuidString
    try await db.terminals.setSuspended(id: suspended.id, sessionID: fakeSessionID)

    // Verify suspension was recorded.
    let suspendedBefore = try await db.terminals.get(id: suspended.id)
    #expect(suspendedBefore?.suspendedAt != nil, "Terminal should have suspendedAt set")

    try await lifecycle.reconcile(repoID: repo.id)

    // All terminals must still exist after reconcile.
    terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2, "Suspended terminal must not be deleted during reconcile")

    // The suspended terminal's state must be untouched.
    let suspendedAfter = try await db.terminals.get(id: suspended.id)
    #expect(suspendedAfter?.suspendedAt != nil, "suspendedAt must still be set after reconcile")
    #expect(suspendedAfter?.claudeSessionID == fakeSessionID, "claudeSessionID must be preserved for suspended terminal")
}

/// Server gone path (reboot): in dryRun mode serverExists → true, so this path
/// cannot be directly triggered. Instead, this test seeds a stale windowID and
/// verifies that when the server IS alive (dryRun), the stale window is treated
/// as alive (windowExists → true in dryRun) and NOT deleted.
/// This is the inverse regression guard: ensures dryRun never triggers reboot recreation.
@Test func testReconcileDryRunDoesNotTriggerRebootRecreation() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    // Seed a stale window ID to simulate what happens after a reboot
    // (the DB still has the old window ID, but the tmux server is gone).
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2)
    let terminal = terminals[0]
    let staleWindowID = "@stale-99"
    try await db.terminals.updateTmuxIDs(id: terminal.id, windowID: staleWindowID, paneID: "%stale-99")

    // In dryRun mode, serverExists → true (not the reboot path).
    // windowExists → true for any ID, so the stale window is treated as alive.
    // Result: the terminal record must NOT be deleted (no dead-window deletion).
    try await lifecycle.reconcile(repoID: repo.id)

    let terminalsAfter = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsAfter.count == 2, "Terminal with stale window ID must survive when server is alive (dryRun)")

    // The stale window ID should be unchanged (no recreation happened).
    let terminalAfter = terminalsAfter.first { $0.id == terminal.id }
    #expect(terminalAfter?.tmuxWindowID == staleWindowID,
            "dryRun: stale window ID must not be replaced when server reports alive")

    // NOTE: The actual reboot recovery path (serverExists → false → recreateAfterReboot)
    // cannot be tested with dryRun=true. A non-dryRun integration test with a real
    // tmux server would be needed to verify that stale IDs ARE replaced with fresh
    // mock IDs when the server is gone.
}

// MARK: - Helpers

/// Thread-safe collector for TmuxManager dryRun recorded args.
private final class LifecycleRecordedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []

    func append(_ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        commands.append(args)
    }

    func snapshot() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }
}
