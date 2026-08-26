import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

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
    #expect(FileManager.default.fileExists(atPath: result.localPath))

    // Verify terminals were created
    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.count == 2)
}

@Test func testCreateWorktreeUsesCodexPrimaryAgentPreference() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    try await db.config.setPrimaryAgentPreference(.codex)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.count == 2)
    #expect(terminals.contains { $0.kind == .codex && $0.label == "Codex" })
    #expect(!terminals.contains { $0.kind == .claude || $0.label == "Claude Code" })
}

@Test func testCreateWorktreeExplicitAgentOverrideWinsBothDirections() async throws {
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

    try await db.config.setPrimaryAgentPreference(.claude)
    let codex = try await lifecycle.createWorktree(
        repoID: repo.id,
        primaryAgentPreference: .codex
    )
    #expect(try await db.terminals.list(worktreeID: codex.id).contains { $0.kind == .codex })

    try await db.config.setPrimaryAgentPreference(.codex)
    let claude = try await lifecycle.createWorktree(
        repoID: repo.id,
        primaryAgentPreference: .claude
    )
    #expect(try await db.terminals.list(worktreeID: claude.id).contains { $0.kind == .claude })
}

@Test func testCreateWorktreePersistsPrimaryAgentAsFirstAndActiveTab() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    try await db.config.setPrimaryAgentPreference(.codex)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    let terminals = try await db.terminals.list(worktreeID: result.id)
    let primary = try #require(terminals.first)

    #expect(primary.kind == .codex)
    #expect(primary.label == "Codex")
    let noteIDs = try await db.notes.list(worktreeID: result.id).map(\.id)
    #expect(try await db.worktrees.getTabOrder(worktreeID: result.id)
            == terminals.map(\.id) + noteIDs)
    #expect(try await db.worktrees.getActiveTabID(worktreeID: result.id) == primary.id)
}

@Test func testCreateWorktreeWithCodexPreferenceDoesNotResolveClaudeProfile() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    try await db.config.setPrimaryAgentPreference(.codex)

    let profile = try await db.modelProfiles.create(name: "Test", kind: .apiKey)
    try await db.config.setDefaultProfileID(profile.id)

    let keychainLookups = LockedInt()
    let resolver = ModelProfileResolver(
        profiles: db.modelProfiles,
        repos: db.repos,
        config: db.config,
        keychain: { id in
            keychainLookups.increment()
            if id == profile.id.uuidString {
                return "sk-ant-api03-FAKETOKEN_value"
            }
            return nil
        }
    )

    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        modelProfileResolver: resolver
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.contains { $0.kind == .codex && $0.profileID == nil })
    #expect(keychainLookups.value == 0)
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
    #expect(result.localPath.hasSuffix("/my-folder"))
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
    #expect(FileManager.default.fileExists(atPath: wt.localPath))

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.status == .archived)
    #expect(!FileManager.default.fileExists(atPath: wt.localPath))

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
    #expect(FileManager.default.fileExists(atPath: revived.localPath))

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

    // makeTestRepo, not a bare repos.create: without the worktreeRoot override
    // the created worktree — and the stray dir this test plants where it used
    // to live — land in the developer's real ~/tbd/worktrees.
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    // Re-create a stray directory where the worktree used to live.
    try FileManager.default.createDirectory(
        atPath: wt.localPath, withIntermediateDirectories: true
    )
    try "stray".write(
        toFile: (wt.localPath as NSString).appendingPathComponent("file.txt"),
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

@Test func testReviveWithArchivedClaudeSessionsPrefersClaudeOverCurrentSetting() async throws {
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
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
    try await db.config.setPrimaryAgentPreference(.codex)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    #expect(terminals.contains { $0.kind == .claude && $0.label == "Claude Code" })
}

@Test func testReviveWithoutPriorPrimaryAgentFallsBackToConfiguredPreference() async throws {
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
    try await db.config.setPrimaryAgentPreference(.codex)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedClaudeSessions == nil)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: false)
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    #expect(terminals.contains { $0.kind == .codex && $0.label == "Codex" })
}

@Test func testArchiveIgnoresCodexSessionMetadata() async throws {
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

    _ = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@codex-1",
        tmuxPaneID: "%codex-1",
        label: "Codex",
        claudeSessionID: "codex-session-id",
        kind: .codex
    )
    _ = try await db.terminals.create(
        worktreeID: wt.id,
        tmuxWindowID: "@claude-1",
        tmuxPaneID: "%claude-1",
        label: "Claude Code",
        claudeSessionID: "claude-session-id",
        kind: .claude
    )

    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let archived = try await db.worktrees.get(id: wt.id)
    #expect(archived?.archivedClaudeSessions == ["claude-session-id"])
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
        cwd: wt.localPath, shellCommand: "echo test"
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

    // Seed an api-key profile row and set it as the global default.
    // (oauth profiles no longer inject a token — they use CLAUDE_CONFIG_DIR.)
    let token = try await db.modelProfiles.create(name: "Test", kind: .apiKey)
    try await db.config.setDefaultProfileID(token.id)

    let secret = "sk-ant-api03-FAKETOKEN_value"
    let resolver = ModelProfileResolver(
        profiles: db.modelProfiles,
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
        modelProfileResolver: resolver,
        // This is the only test in the file that spawns Claude against a
        // RESOLVED profile, so it is the only one whose spawn ensures a
        // per-profile config dir. Without the injection it lands in the real
        // ~/tbd/profiles.
        configDirManager: makeIsolatedConfigDirManager(tag: "lifecycle")
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    // (a) Token must be passed via tmux -e flag, NOT inlined into the shell command body.
    let snap = recorded.snapshot()
    let claudeCall = snap.first { call in
        let body = call.last ?? ""
        return body.contains("claude --session-id")
    }
    #expect(claudeCall != nil, "expected a createWindow call spawning claude")
    #expect(claudeCall?.contains("ANTHROPIC_API_KEY=\(secret)") == true,
            "expected token in tmux -e flag; got: \(claudeCall ?? [])")
    let shellBody = claudeCall?.last ?? ""
    #expect(!shellBody.contains(secret),
            "secret leaked into shell command body: \(shellBody)")
    #expect(!shellBody.contains("ANTHROPIC_API_KEY"),
            "env var name leaked into shell command body: \(shellBody)")

    // (b) Persisted terminal row has profileID set to the known token UUID.
    let terminals = try await db.terminals.list(worktreeID: wt.id)
    let claudeTerminal = terminals.first { $0.profileID != nil }
    #expect(claudeTerminal?.profileID == token.id,
            "expected the Claude terminal to persist profileID=\(token.id)")
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
    #expect(wt.localPath.hasPrefix(tempDir.path))
    #expect(wt.localPath.contains(".tbd/worktrees/"))
    #expect(wt.localPath.contains(wt.name))
}

// MARK: - Reconcile Tests

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

    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

    let terminalsAfter = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsAfter.count == 2, "Alive terminals must not be deleted during reconcile")

    // In dryRun mode, serverExists → true → windowExists path is taken.
    // windowExists → true → terminals are kept with their original IDs.
    // The important invariant: terminal COUNT must not drop.
    let windowIDsAfter = Set(terminalsAfter.map { $0.tmuxWindowID })
    #expect(!windowIDsAfter.isEmpty, "Terminal window IDs must be present after reconcile")
    // Since serverExists → true and windowExists → true, the alive-window branch
    // is taken and IDs are NOT touched (the terminal is left running as-is).
    #expect(windowIDsAfter == windowIDsBefore, "Window IDs must be unchanged when server and windows are alive")
}

@Test func testReconcileOwnedDeadRepoTerminalRemainsTrackedThroughResourceSweep() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let terminalID = UUID()
    let server = TmuxManager.serverName(forRepoPath: repoDir.path)
    let recorded = LockedCommandRecorder()
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(
            dryRun: true,
            dryRunRecorder: recorded.append,
            dryRunListWindows: { probed, _ in
                probed == server ? [(windowID: "@1", paneID: "%1")] : []
            },
            dryRunPaneSendTarget: { _, _ in
                .dead(terminalID: terminalID.uuidString.lowercased())
            }),
        hooks: HookResolver())
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let main = try await db.worktrees.createMain(
        repoID: repo.id,
        name: "main",
        branch: "main",
        path: repoDir.path,
        tmuxServer: server)
    let terminal = try await db.terminals.create(
        id: terminalID,
        worktreeID: main.id,
        tmuxWindowID: "@1",
        tmuxPaneID: "%1",
        label: "Shell",
        kind: .shell)
    try await db.tabs.setLabel(
        tabID: terminal.id, worktreeID: main.id, label: "Finished output")

    try await lifecycle.reconcile(
        repoID: repo.id,
        actuationLog: makeTestActuationLog(),
        reapSharedScratchTmuxResources: true)

    #expect(try await db.terminals.get(id: terminal.id) != nil)
    #expect(try await db.tabs.listForWorktree(worktreeID: main.id)
            .first(where: { $0.id == terminal.id })?.label == "Finished output")
    #expect(!recorded.snapshot().contains { $0.contains("kill-window") })
}

// MARK: - Reconcile and the pane consultation's two negative answers

/// Both arms below share this: a main worktree on a live (dryRun) server with
/// one live window, holding one resumable Claude terminal. The only variable is
/// what the pane consultation answers.
private func makeReconcileFixture(
    tempDir: URL, repoDir: URL, paneTarget: @escaping @Sendable (String, String) throws -> PaneSendTarget
) async throws -> (TBDDatabase, WorktreeLifecycle, Repo, Terminal) {
    let db = try TBDDatabase(inMemory: true)
    let server = TmuxManager.serverName(forRepoPath: repoDir.path)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true, dryRunPaneSendTarget: paneTarget),
        hooks: HookResolver())
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let main = try await db.worktrees.createMain(
        repoID: repo.id, name: "main", branch: "main",
        path: repoDir.path, tmuxServer: server)
    let terminal = try await db.terminals.create(
        worktreeID: main.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
        label: "claude", claudeSessionID: "sess-reconcile", kind: .claude)
    return (db, lifecycle, repo, terminal)
}

/// Encoded with sorted keys so the comparison is over the whole row rather
/// than the fields a reader thought to name.
private func encodedRow(_ terminal: Terminal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(terminal)
}

/// The destructive half of the defect. Reconcile parks resumable sessions and
/// deletes the rest, so a consultation that reached no tmux server must leave
/// the row alone: "I could not read the pane" is not "the pane is gone", and
/// getting it wrong here loses a live agent's in-flight work rather than merely
/// refusing one send.
@Test func testReconcileLeavesRowUntouchedWhenServerIsUnreachable() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let (db, lifecycle, repo, terminal) = try await makeReconcileFixture(
        tempDir: tempDir, repoDir: repoDir, paneTarget: { _, _ in .unreachable })
    let before = try encodedRow(try #require(try await db.terminals.get(id: terminal.id)))

    try await lifecycle.reconcile(
        repoID: repo.id, actuationLog: makeTestActuationLog(),
        reapSharedScratchTmuxResources: true)

    let after = try #require(try await db.terminals.get(id: terminal.id))
    let afterEncoded = try encodedRow(after)
    #expect(afterEncoded == before,
            "an unreachable server must leave the row byte-identical; got \(after)")
    // Spelled out too, because these are the three specific mutations this pass
    // makes and a reader should see them refused by name.
    #expect(after.hibernatedAt == nil, "must not park on a failed read")
    #expect(after.tmuxPaneID == "%1", "must not rewrite the coordinate on a failed read")
    #expect(after.tmuxWindowID == "@1")
}

/// The over-correction guard: a reconciler that never reclaims anything is its
/// own bug. A server that ANSWERED and does not hold the pane is positive
/// evidence of absence, and a resumable session there is still parked.
@Test func testReconcileStillParksWhenThePaneIsPositivelyAbsent() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let (db, lifecycle, repo, terminal) = try await makeReconcileFixture(
        tempDir: tempDir, repoDir: repoDir, paneTarget: { _, _ in .absent })

    try await lifecycle.reconcile(
        repoID: repo.id, actuationLog: makeTestActuationLog(),
        reapSharedScratchTmuxResources: true)

    let after = try #require(try await db.terminals.get(id: terminal.id))
    #expect(after.hibernatedAt != nil, "an absent pane must still park its resumable session")
    #expect(after.claudeSessionID == "sess-reconcile", "the session must be preserved for wake")
}

/// The same absence on a NON-resumable row still deletes, so the two halves of
/// the reclaim path are both proven live.
@Test func testReconcileStillDeletesNonResumableRowWhenThePaneIsPositivelyAbsent() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let server = TmuxManager.serverName(forRepoPath: repoDir.path)
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(),
        tmux: TmuxManager(dryRun: true, dryRunPaneSendTarget: { _, _ in .absent }),
        hooks: HookResolver())
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let main = try await db.worktrees.createMain(
        repoID: repo.id, name: "main", branch: "main",
        path: repoDir.path, tmuxServer: server)
    let terminal = try await db.terminals.create(
        worktreeID: main.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
        label: "Shell", kind: .shell)

    try await lifecycle.reconcile(
        repoID: repo.id, actuationLog: makeTestActuationLog(),
        reapSharedScratchTmuxResources: true)

    let after = try await db.terminals.get(id: terminal.id)
    #expect(after == nil, "an absent pane on a non-resumable row must still be reclaimed")
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

    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

    // All terminals must still exist after reconcile.
    terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2, "Suspended terminal must not be deleted during reconcile")

    // The suspended terminal's state must be untouched.
    let suspendedAfter = try await db.terminals.get(id: suspended.id)
    #expect(suspendedAfter?.suspendedAt != nil, "suspendedAt must still be set after reconcile")
    #expect(suspendedAfter?.claudeSessionID == fakeSessionID, "claudeSessionID must be preserved for suspended terminal")
}

/// Hibernated-but-not-legacy-suspended terminals (`hibernatedAt` set,
/// `suspendedAt` nil) are parked and must be skipped by the dead-window pass
/// exactly like legacy-suspended ones: a parked row's window being gone is
/// expected, and the row is already what the pass would produce.
///
/// Regression guard for the old `suspendedAt == nil` filter, which passed
/// hibernated rows through — refreshing the park timestamp on resumable rows
/// and DELETING parked rows that aren't Claude-resumable.
@Test func testReconcileHibernatedTerminalSkippedOnDeadWindow() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    // Every window reads as dead — the exact scenario the parking pass acts on.
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true, dryRunWindowIsDead: { _ in true }),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let serverName = TmuxManager.serverName(forRepoPath: repo.path)
    // A worktree at the repo path so `git worktree list` reports it and
    // reconcile doesn't archive it as missing.
    let wt = try await db.worktrees.create(
        repoID: repo.id, name: "wt", branch: "main",
        path: repoDir.path, tmuxServer: serverName
    )

    let claude = try await db.terminals.create(
        worktreeID: wt.id, tmuxWindowID: "@hib-claude", tmuxPaneID: "%hib-claude",
        label: "claude", claudeSessionID: "sess-hib", kind: .claude
    )
    try await db.terminals.setHibernated(id: claude.id, sessionID: "sess-hib")
    // A parked row that is NOT Claude-resumable: under the old filter this
    // fell through to the delete branch and the parked row vanished.
    let codex = try await db.terminals.create(
        worktreeID: wt.id, tmuxWindowID: "@hib-codex", tmuxPaneID: "%hib-codex",
        label: "Codex", claudeSessionID: "sess-codex", kind: .codex
    )
    try await db.terminals.setHibernated(id: codex.id, sessionID: "sess-codex")

    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

    let claudeAfter = try await db.terminals.get(id: claude.id)
    #expect(claudeAfter != nil, "hibernated claude terminal must survive reconcile")
    #expect(claudeAfter?.hibernatedAt != nil, "hibernated claude must stay parked")
    #expect(claudeAfter?.suspendedAt == nil, "hibernated-only row must not gain legacy suspendedAt")
    #expect(claudeAfter?.claudeSessionID == "sess-hib")

    let codexAfter = try await db.terminals.get(id: codex.id)
    #expect(codexAfter != nil, "a parked non-Claude-resumable row must be skipped, not deleted")
    #expect(codexAfter?.hibernatedAt != nil)
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
    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog(), reapSharedScratchTmuxResources: true)

    let terminalsAfter = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminalsAfter.count == 2, "Terminal with stale window ID must survive when server is alive (dryRun)")

    // The stale window ID should be unchanged (no recreation happened).
    let terminalAfter = terminalsAfter.first { $0.id == terminal.id }
    #expect(terminalAfter?.tmuxWindowID == staleWindowID,
            "dryRun: stale window ID must not be replaced when server reports alive")

    // NOTE: The actual reboot path (serverExists → false) cannot be tested with
    // dryRun=true. See testReconcileRebootParksClaudeAndDeletesShell in
    // TBDDaemonLiveTests/WorktreeLifecycleLiveTests.swift, which drives it with a
    // real tmux server and verifies terminals are parked as suspended (not
    // recreated) when the server is gone.
}

@Test func testCreateWorktreeTrapBugScenario() async throws {
    // TRAP: Reproduces the OLD BROKEN behavior when displayName is passed
    // without folder. This documents the exact broken state that prompted
    // the fix in Sources/TBDApp/AppState+Worktrees.swift:65.
    //
    // When AppState sent `displayName: <slug>, folder: nil`, the daemon would
    // auto-generate a different name, causing displayName != name and
    // hasDefaultDisplayName == false, which defeats the stop-rename-check hook.
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

    // Simulate the OLD app behavior: pass displayName without folder.
    // The daemon will auto-generate a different name.
    let explicitSlug = "20260101-test-otter"
    let wt = try await lifecycle.createWorktree(
        repoID: repo.id,
        folder: nil,
        displayName: explicitSlug,
        skipClaude: true
    )

    // TRAP: verify the daemon really does diverge
    #expect(wt.displayName == explicitSlug, "displayName was passed explicitly")
    #expect(wt.name != explicitSlug, "name is auto-generated, different from displayName")
    #expect(!wt.hasDefaultDisplayName, "hasDefaultDisplayName is false; stop-rename-check hook would skip")
    #expect(wt.branch.hasPrefix("tbd/"), "Auto-generated worktrees use tbd/* branch")
}

@Test func testCreateWorktreeAutoGeneratedBranchFixesDisplayName() async throws {
    // CONTRACT: Verifies the fix for when the app sends neither folder nor displayName.
    // The daemon's WorktreeStore.create defaults `displayName ?? name`, so the daemon
    // generates a name and sets displayName equal to it, keeping name == displayName
    // and hasDefaultDisplayName == true. This is the contract the fixed app relies on
    // (Sources/TBDApp/AppState+Worktrees.swift lines 63-72).
    //
    // The app now passes NEITHER folder NOR displayName for auto-generated branches:
    // folder is omitted to keep collision-retry safety net enabled in attemptWorktreeAdd;
    // displayName is omitted to let the daemon default it to name.
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

    // Simulate the FIXED app behavior: pass neither folder nor displayName.
    let wt = try await lifecycle.createWorktree(
        repoID: repo.id,
        folder: nil,
        displayName: nil,
        skipClaude: true
    )

    // CONTRACT: verify the fix works
    #expect(wt.name != nil && !wt.name.isEmpty, "name should be auto-generated")
    #expect(wt.displayName == wt.name, "daemon defaults displayName to name")
    #expect(wt.name == wt.displayName, "name == displayName; hasDefaultDisplayName is true")
    #expect(wt.hasDefaultDisplayName, "stop-rename-check hook will fire")
    #expect(wt.branch.hasPrefix("tbd/"), "Auto-generated worktrees use tbd/* branch")
    #expect(FileManager.default.fileExists(atPath: wt.localPath))
}

@Test func testCreateWorktreeExistingBranchWithoutFolderHasDefaultDisplayName() async throws {
    // Companion test: verifies the existing-branch case maintains the contract.
    // When creating from an existing branch, AppState now passes NEITHER folder
    // nor displayName (Sources/TBDApp/AppState+Worktrees.swift lines 63-72).
    // The daemon derives folder from the branch name (WorktreeLifecycle+Create.swift),
    // and defaults displayName to name via WorktreeStore.create's `displayName ?? name`.
    // This test verifies that when no dedup suffix is needed, name == displayName.
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Pre-seed a local branch that the new worktree will check out.
    try await shell("git branch my-feature", at: repoDir)

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver()
    )

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

    // Simulate the app's input for existing branches: no folder, no displayName.
    // Only pass the branch (which the daemon will check out) and useExistingBranch flag.
    let wt = try await lifecycle.createWorktree(
        repoID: repo.id,
        folder: nil,
        branch: "my-feature",
        displayName: nil,
        skipClaude: true,
        useExistingBranch: true
    )

    // For existing branches without dedup conflicts, the folder is derived
    // from the branch name (sanitized), so name == displayName == local branch name.
    #expect(wt.name == "my-feature", "folder derived from branch name")
    #expect(wt.displayName == "my-feature", "daemon defaults displayName to name")
    #expect(wt.name == wt.displayName, "Existing-branch worktrees must have name == displayName")
    #expect(wt.hasDefaultDisplayName, "Existing-branch worktrees must have hasDefaultDisplayName == true")
    #expect(wt.branch == "my-feature")
    #expect(FileManager.default.fileExists(atPath: wt.localPath))
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

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        storage += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
