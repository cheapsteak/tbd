import Testing
import TestSupport
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
@Suite("repo.add scratch guard")
struct RepoAddScratchGuardTests {
    @Test func rejectsPathUnderScratchDir() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-addguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        defer { restoreTBDHome(priorTBDHome); try? FileManager.default.removeItem(at: home) }

        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())

        let scratchChild = TBDConstants.scratchDir.appendingPathComponent("some-project").path
        try FileManager.default.createDirectory(atPath: scratchChild, withIntermediateDirectories: true)

        let response = await router.handle(try RPCRequest(method: RPCMethod.repoAdd, params: RepoAddParams(path: scratchChild)))
        #expect(!response.success)
        #expect(response.error?.contains("tbd scratch promote") == true)
    }

    @Test func acceptsPathOutsideScratchDir() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-addguard-normal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        defer { restoreTBDHome(priorTBDHome); try? FileManager.default.removeItem(at: home) }

        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())

        // Create a temporary git repo outside the scratch directory
        let repoPath = FileManager.default.temporaryDirectory.appendingPathComponent("normal-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)

        // Initialize a git repo
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init"]
        process.currentDirectoryURL = repoPath
        try process.run()
        process.waitUntilExit()

        // Set git config
        let configProcess = Process()
        configProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        configProcess.arguments = ["git", "config", "user.email", "test@test.com"]
        configProcess.currentDirectoryURL = repoPath
        try configProcess.run()
        configProcess.waitUntilExit()

        let nameProcess = Process()
        nameProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        nameProcess.arguments = ["git", "config", "user.name", "Test"]
        nameProcess.currentDirectoryURL = repoPath
        try nameProcess.run()
        nameProcess.waitUntilExit()

        // Create initial commit
        try "# Test".write(to: repoPath.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        addProcess.arguments = ["git", "add", "README.md"]
        addProcess.currentDirectoryURL = repoPath
        try addProcess.run()
        addProcess.waitUntilExit()

        let commitProcess = Process()
        commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        commitProcess.arguments = ["git", "commit", "-m", "initial commit"]
        commitProcess.currentDirectoryURL = repoPath
        try commitProcess.run()
        commitProcess.waitUntilExit()

        let response = await router.handle(try RPCRequest(method: RPCMethod.repoAdd, params: RepoAddParams(path: repoPath.path)))
        #expect(response.success)
        #expect(response.error == nil)
    }

    @Test func rejectsSymlinkBypassToScratchDir() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-addguard-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let priorTBDHome = setTBDHome(home.path)
        defer { restoreTBDHome(priorTBDHome); try? FileManager.default.removeItem(at: home) }

        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())

        // Create a scratch child directory
        let scratchChild = TBDConstants.scratchDir.appendingPathComponent("symlink-test-project")
        try FileManager.default.createDirectory(at: scratchChild, withIntermediateDirectories: true)

        // Create a symlink elsewhere that points to the scratch child
        let symlinkParent = FileManager.default.temporaryDirectory.appendingPathComponent("symlink-parent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: symlinkParent, withIntermediateDirectories: true)
        let symlinkPath = symlinkParent.appendingPathComponent("link-to-scratch")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: scratchChild)

        // Try to add via the symlink path - should still be rejected
        let response = await router.handle(try RPCRequest(method: RPCMethod.repoAdd, params: RepoAddParams(path: symlinkPath.path)))
        #expect(!response.success)
        #expect(response.error?.contains("tbd scratch promote") == true)
    }
}
}
