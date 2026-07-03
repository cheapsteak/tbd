import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
@Suite("scratch.create RPC")
struct ScratchCreateRPCTests {
    private func isolateTBDHome() -> (home: URL, cleanup: () -> Void) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-scratchcreate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("TBD_HOME", home.path, 1)
        return (home, { unsetenv("TBD_HOME"); try? FileManager.default.removeItem(at: home) })
    }

    @Test func createsRepoLessWorktreeRowAndDirectory() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())

        let request = try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil))
        let response = await router.handle(request)
        #expect(response.success)

        let wt = try response.decodeResult(Worktree.self)
        #expect(wt.repoID == nil)
        #expect(wt.isScratch)
        #expect(wt.path.hasPrefix(TBDConstants.scratchDir.path))
        #expect(FileManager.default.fileExists(atPath: wt.path))
        let all = try await db.worktrees.listScratch()
        #expect(all.count == 1)
    }

    @Test func honorsExplicitNameAndRegeneratesOnCollision() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date())

        let r1 = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "notes")))
        let w1 = try r1.decodeResult(Worktree.self)
        #expect(w1.name == "notes")
        // Second create with the same name must not collide on the unique path.
        let r2 = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "notes")))
        let w2 = try r2.decodeResult(Worktree.self)
        #expect(w2.path != w1.path)
    }
}
}
