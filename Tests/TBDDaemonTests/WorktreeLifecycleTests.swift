import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A create with no folder, branch or display name — what the app sends for
/// an auto-generated worktree. Also the `useExistingBranch: false` branch of
/// that flag (the default): a fresh `tbd/<name>` is created rather than an
/// existing branch checked out; `WorktreeCreateExistingBranchTests` covers the
/// other two branches.
///
/// The display-name half is the #419 contract. The stop-rename-check hook
/// fires only while `hasDefaultDisplayName` (`displayName == name`), so the
/// app passes neither `folder` (which would disable `attemptWorktreeAdd`'s
/// collision retry) nor `displayName` (which would make the daemon mint a
/// second, independent slug for `name`). The daemon generates `name` and
/// `WorktreeStore.create` defaults `displayName ?? name`, so the two match.
@Test func testCreateWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

    #expect(result.status == .active)
    #expect(result.name.contains("-"))
    #expect(result.branch.hasPrefix("tbd/"), "a fresh tbd/* branch, not an existing one")
    #expect(FileManager.default.fileExists(atPath: result.localPath))

    // Under the canonical layout (<tempDir>/.tbd/worktrees/<name>), because
    // makeTestRepo overrides worktreeRoot to <tempDir>/.tbd/worktrees.
    #expect(result.localPath.hasPrefix(tempDir.path))
    #expect(result.localPath.contains(".tbd/worktrees/"))
    #expect(result.localPath.contains(result.name))

    // #419: name == displayName, so the stop-rename-check hook will fire.
    #expect(result.displayName == result.name, "daemon defaults displayName to name")
    #expect(result.hasDefaultDisplayName)

    // The primary only: no setup hook is installed, so no setup tab opens.
    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.count == 1)
}

@Test func testCreateWorktreeUsesCodexPrimaryAgentPreference() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    try await db.config.setPrimaryAgentPreference(.codex)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        codexExecutableResolver: CodexLaunchTestStub.executableResolver,
        codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    let terminals = try await db.terminals.list(worktreeID: result.id)
    #expect(terminals.count == 1, "the primary only: no setup hook is installed")
    #expect(terminals.contains { $0.kind == .codex && $0.label == "Codex" })
    #expect(!terminals.contains { $0.kind == .claude || $0.label == "Claude Code" })
}

@Test func testCreateWorktreeExplicitAgentOverrideWinsBothDirections() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        codexExecutableResolver: CodexLaunchTestStub.executableResolver,
        codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())
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
    // Through the holder spawn double, so no process is started.
    let holder = FakeHolderLaunch()
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        codexExecutableResolver: CodexLaunchTestStub.executableResolver,
        codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: holder)

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let result = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)
    let terminals = try await db.terminals.list(worktreeID: result.id)
    let primary = try #require(terminals.first)

    #expect(primary.transport == .holder)
    #expect(Set(holder.launches.map(\.terminalID)) == Set(terminals.map(\.id)))
    #expect(primary.kind == .codex)
    #expect(primary.label == "Codex")
    // The tab order holds only the terminals.
    #expect(try await db.worktrees.getTabOrder(worktreeID: result.id) == terminals.map(\.id))
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

    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        modelProfileResolver: resolver,
        codexExecutableResolver: CodexLaunchTestStub.executableResolver,
        codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.createWorktree(repoID: UUID(), skipClaude: true)
    }
}

@Test func testCreateWithExplicitFolderAndBranch() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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

@Test func testCreateCollisionWithUserFolderFails() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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

@Test func testArchiveWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )

    await #expect(throws: WorktreeLifecycleError.self) {
        try await lifecycle.archiveWorktree(worktreeID: UUID())
    }
}

@Test func testReviveWorktree() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
    try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)

    let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)

    #expect(revived.status == .active)
    #expect(FileManager.default.fileExists(atPath: revived.localPath))

    // Verify a fresh primary was created (no setup hook, so no setup tab)
    let terminals = try await db.terminals.list(worktreeID: revived.id)
    #expect(terminals.count == 1)
}

@Test func testReviveActiveWorktreeThrows() async throws {
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        codexExecutableResolver: CodexLaunchTestStub.executableResolver,
        codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        codexExecutableResolver: CodexLaunchTestStub.executableResolver,
        codexHomeEnsurer: CodexLaunchTestStub.homeEnsurer,
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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

    // The first session comes back as the primary and the second as a
    // restored tab.
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

    // The holder spawn double records what each spawn would have run.
    let holder = FakeHolderLaunch()
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        modelProfileResolver: resolver,
        // This is the only test in the file that spawns Claude against a
        // RESOLVED profile, so it is the only one whose spawn ensures a
        // per-profile config dir. Without the injection it lands in the real
        // ~/tbd/profiles.
        configDirManager: makeIsolatedConfigDirManager(tag: "lifecycle"),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: holder)

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: false)

    // (a) Token must be passed in the job's process environment, NOT inlined
    // into the shell command body.
    let claudeLaunch = holder.launches.first { launch in
        launch.commandLine?.contains("claude --session-id") == true
    }
    #expect(claudeLaunch != nil, "expected a holder launch spawning claude")
    #expect(claudeLaunch?.request.environment["ANTHROPIC_API_KEY"] == secret,
            "expected token in the job's process environment")
    let shellBody = claudeLaunch?.commandLine ?? ""
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

// MARK: - Reconcile Tests

/// A main worktree at the repo path holding two tmux shell rows on distinct
/// windows: the rows the tmux arm of reconcile judges. Seeded directly,
/// because no spawn opens a tmux window.
private func seedTmuxShellTerminals(
    db: TBDDatabase, repo: Repo, repoDir: URL
) async throws -> Worktree {
    let main = try await db.worktrees.createMain(
        repoID: repo.id, name: "main", branch: "main", path: repoDir.path,
        tmuxServer: TmuxServerName.forRepoPath(repoDir.path))
    for index in 1...2 {
        _ = try await db.terminals.create(
            worktreeID: main.id, tmuxWindowID: "@\(index)", tmuxPaneID: "%\(index)",
            label: "Shell", kind: .shell)
    }
    return main
}

/// A lifecycle whose leftover-tmux probe answers `state` for every server, so
/// no socket is asked.
private func makeProbedLifecycle(
    db: TBDDatabase, state: LeftoverTmuxServerState
) -> WorktreeLifecycle {
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
        leftoverTmuxProbe: LeftoverTmuxServerProbe { _ in state })
    return lifecycle
}

/// A main worktree with one resumable Claude terminal on tmux, under a
/// lifecycle whose probe answers `serverState` for its tmux server.
private func makeReconcileFixture(
    tempDir: URL, repoDir: URL, serverState: LeftoverTmuxServerState
) async throws -> (TBDDatabase, WorktreeLifecycle, Repo, Terminal) {
    let db = try TBDDatabase(inMemory: true)
    let server = TmuxServerName.forRepoPath(repoDir.path)
    let lifecycle = makeProbedLifecycle(db: db, state: serverState)
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

/// A tmux server the probe cannot prove gone may still be running the
/// sessions, which TBD can neither reach nor stop, so reconcile leaves every
/// row on it exactly as it was: no park, no delete, no rewritten coordinate.
@Test func testReconcileLeavesTmuxRowsUntouchedWhileTheirServerMayRun() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeProbedLifecycle(db: db, state: .running)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await seedTmuxShellTerminals(db: db, repo: repo, repoDir: repoDir)
    let before = try await db.terminals.list(worktreeID: wt.id).map(encodedRow)
    #expect(before.count == 2, "Expected the 2 seeded tmux terminals")

    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

    let after = try await db.terminals.list(worktreeID: wt.id).map(encodedRow)
    #expect(Set(after) == Set(before),
            "rows on a server that may still run must be left byte-identical")
}

/// The same rule for a resumable session: the row is not parked.
@Test func testReconcileLeavesResumableRowUntouchedWhileItsServerMayRun() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let (db, lifecycle, repo, terminal) = try await makeReconcileFixture(
        tempDir: tempDir, repoDir: repoDir, serverState: .running)
    let before = try encodedRow(try #require(try await db.terminals.get(id: terminal.id)))

    try await lifecycle.reconcile(
        repoID: repo.id, actuationLog: makeTestActuationLog())

    let after = try #require(try await db.terminals.get(id: terminal.id))
    #expect(try encodedRow(after) == before,
            "a server that may still run must leave the row byte-identical; got \(after)")
    #expect(after.hibernatedAt == nil, "must not park a session that may still run")
}

/// The over-correction guard: a reconciler that never reclaims anything is its
/// own bug. A server whose socket is positively gone took its sessions with it,
/// and a resumable session there is parked with its identity kept.
@Test func testReconcileParksResumableRowOnceItsServerIsGone() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let (db, lifecycle, repo, terminal) = try await makeReconcileFixture(
        tempDir: tempDir, repoDir: repoDir, serverState: .absent)

    try await lifecycle.reconcile(
        repoID: repo.id, actuationLog: makeTestActuationLog())

    let after = try #require(try await db.terminals.get(id: terminal.id))
    #expect(after.hibernatedAt != nil, "a gone server must still park its resumable session")
    #expect(after.hibernateReason == .recovery)
    #expect(after.claudeSessionID == "sess-reconcile", "the session must be preserved for wake")
    #expect(after.transport == .tmux, "reconcile parks the row; migration moves it")
}

/// The same absence on a NON-resumable row still deletes, so the two halves of
/// the reclaim path are both proven live.
@Test func testReconcileDeletesNonResumableRowOnceItsServerIsGone() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeProbedLifecycle(db: db, state: .absent)
    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await seedTmuxShellTerminals(db: db, repo: repo, repoDir: repoDir)

    try await lifecycle.reconcile(
        repoID: repo.id, actuationLog: makeTestActuationLog())

    #expect(try await db.terminals.list(worktreeID: wt.id).isEmpty,
            "a gone server's non-resumable rows must still be reclaimed")
}

/// Suspended terminals must not be touched during reconcile, even once their
/// server is gone: a parked row has no process to reach, and is already what
/// the pass would produce. The unparked row beside it is reclaimed, which
/// proves the pass ran.
@Test func testReconcileSuspendedTerminalSkippedOnReboot() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    let lifecycle = makeProbedLifecycle(db: db, state: .absent)

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let wt = try await seedTmuxShellTerminals(db: db, repo: repo, repoDir: repoDir)

    let terminals = try await db.terminals.list(worktreeID: wt.id)
    #expect(terminals.count == 2)

    // Suspend one terminal — simulate a terminal that was suspended before reboot.
    let suspended = terminals[0]
    let unparked = terminals[1]
    let fakeSessionID = UUID().uuidString
    try await db.terminals.setSuspended(id: suspended.id, sessionID: fakeSessionID)

    // Verify suspension was recorded.
    let suspendedBefore = try #require(try await db.terminals.get(id: suspended.id))
    #expect(suspendedBefore.suspendedAt != nil, "Terminal should have suspendedAt set")

    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

    // The suspended terminal's state must be untouched.
    let suspendedAfter = try #require(try await db.terminals.get(id: suspended.id),
                                      "Suspended terminal must not be deleted during reconcile")
    #expect(try encodedRow(suspendedAfter) == encodedRow(suspendedBefore))
    #expect(suspendedAfter.claudeSessionID == fakeSessionID,
            "claudeSessionID must be preserved for suspended terminal")
    #expect(try await db.terminals.get(id: unparked.id) == nil,
            "the unparked shell on the gone server must be reclaimed")
}

/// Hibernated-but-not-legacy-suspended terminals (`hibernatedAt` set,
/// `suspendedAt` nil) are parked and must be skipped exactly like
/// legacy-suspended ones — and never probed: a parked row has no process to
/// reach, and the row is already what the pass would produce.
///
/// Regression guard for the old `suspendedAt == nil` filter, which passed
/// hibernated rows through — refreshing the park timestamp on resumable rows
/// and DELETING parked rows that aren't Claude-resumable.
@Test func testReconcileHibernatedTerminalSkippedOnceItsServerIsGone() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    // The server reads as gone — the exact scenario the parking pass acts on.
    let probe = RecordingLeftoverTmuxProbe(answer: { _ in .absent })
    let lifecycle = WorktreeLifecycle(
        db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver(),
        leftoverTmuxProbe: probe.probe)

    let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
    let serverName = TmuxServerName.forRepoPath(repo.path)
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
    let codexBefore = try #require(try await db.terminals.get(id: codex.id))

    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())

    #expect(probe.servers.isEmpty, "a parked row was probed: \(probe.servers)")

    let claudeAfter = try await db.terminals.get(id: claude.id)
    #expect(claudeAfter != nil, "hibernated claude terminal must survive reconcile")
    #expect(claudeAfter?.hibernatedAt != nil, "hibernated claude must stay parked")
    #expect(claudeAfter?.suspendedAt == nil, "hibernated-only row must not gain legacy suspendedAt")
    #expect(claudeAfter?.claudeSessionID == "sess-hib")

    let codexAfter = try await db.terminals.get(id: codex.id)
    #expect(codexAfter != nil, "a parked non-Claude-resumable row must be skipped, not deleted")
    #expect(codexAfter?.hibernatedAt != nil)
    #expect(try encodedRow(try #require(codexAfter)) == encodedRow(codexBefore))
}

/// An identified Codex row on a gone server takes the same recovery park a
/// Claude row does, with its native thread id and launch options kept; a
/// Codex row with no thread id has nothing to keep and is deleted.
@Test func testReconcileParksIdentifiedCodexOnceItsServerIsGone() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let (db, lifecycle, repo, claude) = try await makeReconcileFixture(
        tempDir: tempDir, repoDir: repoDir, serverState: .absent)
    let codex = try await seedRecoveryTerminal(db: db, worktreeID: claude.worktreeID, transport: .tmux)
    let unidentified = try await db.terminals.create(
        worktreeID: claude.worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .codex)
    let logPath = tempDir.appendingPathComponent("recovery.jsonl").path
    try await lifecycle.reconcile(repoID: repo.id, actuationLog: ActuationLog(path: logPath))
    try await expectRecoveryPark(db: db, before: codex, logPath: logPath)
    #expect(try await db.terminals.get(id: unidentified.id) == nil)
}

@Test func testReconcileLeavesCodexUntouchedWhileItsServerMayRun() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let (db, lifecycle, repo, claude) = try await makeReconcileFixture(
        tempDir: tempDir, repoDir: repoDir, serverState: .running)
    let codex = try await seedRecoveryTerminal(db: db, worktreeID: claude.worktreeID, transport: .tmux)
    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())
    #expect(try encodedRow(try #require(try await db.terminals.get(id: codex.id))) == encodedRow(codex))
}

/// A nonparked Codex row with a pending incarnation is a Continue in Claude
/// fence an earlier build left unfinished. Reconcile keeps it as it is, even
/// when its server is gone, rather than park it with the fence still set.
@Test func testReconcileKeepsAnUnfinishedContinueInClaudeFence() async throws {
    let (tempDir, repoDir) = try await createTestRepoResolvingSymlinks()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let (db, lifecycle, repo, claude) = try await makeReconcileFixture(
        tempDir: tempDir, repoDir: repoDir, serverState: .absent)
    let codex = try await seedRecoveryTerminal(db: db, worktreeID: claude.worktreeID, transport: .tmux)
    let pendingID = UUID()
    try await db.writerForTests.write { db in
        try db.execute(sql: "UPDATE terminal SET pendingSessionIncarnationID = ? WHERE id = ?",
                       arguments: [pendingID.uuidString, codex.id.uuidString])
    }
    let before = try #require(try await db.terminals.get(id: codex.id))
    #expect(before.pendingSessionIncarnationID == pendingID)
    try await lifecycle.reconcile(repoID: repo.id, actuationLog: makeTestActuationLog())
    #expect(try encodedRow(try #require(try await db.terminals.get(id: codex.id))) == encodedRow(before))
}

@Test func testCreateWorktreeTrapBugScenario() async throws {
    // TRAP: Reproduces the OLD BROKEN behavior when displayName is passed
    // without folder. This documents the exact broken state that prompted
    // the fix in Sources/TBDApp/AppState+Worktrees.swift:65.
    //
    // When AppState sent `displayName: <slug>, folder: nil`, the daemon would
    // auto-generate a different name, causing displayName != name and
    // hasDefaultDisplayName == false, which defeats the stop-rename-check hook.
    //
    // It is also the explicit-display-name case: a displayName passed alone is
    // kept as given, and the folder name is still generated.
    let (tempDir, repoDir) = try await createTestRepo()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let db = try TBDDatabase(inMemory: true)
    var lifecycle = WorktreeLifecycle(
        db: db,
        git: GitManager(),
        tmux: TmuxManager(dryRun: true),
        hooks: HookResolver(),
        leftoverTmuxProbe: .absent
    )
    lifecycle.holderRegistry = makeHolderRegistryDouble(launch: FakeHolderLaunch())

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

// MARK: - Helpers

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
