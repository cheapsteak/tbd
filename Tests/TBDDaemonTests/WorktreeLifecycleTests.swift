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
