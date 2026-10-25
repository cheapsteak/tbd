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
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

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
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

        // A temporary git repo with a commit, outside the scratch directory
        let (repoTemp, repoPath) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: repoTemp) }

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
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

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
