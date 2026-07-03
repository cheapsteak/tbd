import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

extension TBDHomeSerialized {
@Suite("scratch.promote RPC")
struct ScratchPromoteRPCTests {
    private func isolate() -> (URL, () -> Void) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-promote-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("TBD_HOME", home.path, 1)
        return (home, { unsetenv("TBD_HOME"); try? FileManager.default.removeItem(at: home) })
    }

    private func makeRouter(_ db: TBDDatabase) -> RPCRouter {
        RPCRouter(db: db,
                  lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
                  tmux: TmuxManager(dryRun: true), startTime: Date())
    }

    private func gitInitCommit(at path: String) throws {
        for args in [["init"], ["-c","user.email=t@t","-c","user.name=t","commit","--allow-empty","-m","init"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", path] + args; try p.run(); p.waitUntilExit()
        }
    }

    @Test func happyPathMovesRegistersAndMarksPromoted() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)
        try gitInitCommit(at: wt.path)

        let dest = home.appendingPathComponent("projects/myapp").path
        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(resp.success)
        let result = try resp.decodeResult(ScratchPromoteResult.self)
        #expect(FileManager.default.fileExists(atPath: dest))
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        let row = try await db.worktrees.get(id: wt.id)
        #expect(row?.promotedToRepoID == result.repoID)
        #expect(try await db.repos.get(id: result.repoID) != nil)
    }

    @Test func noGitLeavesEverythingUntouched() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)   // no git init

        let dest = home.appendingPathComponent("projects/nope").path
        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(!resp.success)
        #expect(FileManager.default.fileExists(atPath: wt.path))       // not moved
        #expect(!FileManager.default.fileExists(atPath: dest))         // dest not created
        #expect(try await db.worktrees.get(id: wt.id)?.promotedToRepoID == nil)
    }

    @Test func displayNamePriority_renamedScratchWins() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        var wt = try created.decodeResult(Worktree.self)
        try await db.worktrees.rename(id: wt.id, displayName: "My Cool App")  // displayName != name now
        wt = try await db.worktrees.get(id: wt.id)!
        try gitInitCommit(at: wt.path)

        let dest = home.appendingPathComponent("projects/folder-name").path
        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        let result = try resp.decodeResult(ScratchPromoteResult.self)
        #expect(result.repoDisplayName == "My Cool App")   // renamed scratch name inherited
    }

    @Test func displayNamePriority_explicitFlagOverridesEverything() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        var wt = try created.decodeResult(Worktree.self)
        try await db.worktrees.rename(id: wt.id, displayName: "Renamed Scratch")
        wt = try await db.worktrees.get(id: wt.id)!
        try gitInitCommit(at: wt.path)

        let dest = home.appendingPathComponent("projects/folder-name").path
        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: "Explicit Name")))
        let result = try resp.decodeResult(ScratchPromoteResult.self)
        #expect(result.repoDisplayName == "Explicit Name")
    }

    @Test func displayNamePriority_defaultScratchFallsBackToFolderName() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)   // displayName == name (still default)
        try gitInitCommit(at: wt.path)

        let dest = home.appendingPathComponent("projects/coolfolder").path
        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        let result = try resp.decodeResult(ScratchPromoteResult.self)
        #expect(result.repoDisplayName == "coolfolder")   // repo.add's folder-name default
    }

    @Test func rejectsNonScratchWorktree() async throws {
        let (_, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let repo = try await db.repos.create(path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let wt = try await db.worktrees.create(repoID: repo.id, name: "w", branch: "b",
                                               path: "/tmp/w-\(UUID().uuidString)", tmuxServer: "tbd-x")
        let repoCountBefore = try await db.repos.list().count

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("promote-dest-\(UUID().uuidString)").path
        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(!resp.success)
        #expect(!FileManager.default.fileExists(atPath: dest))
        let row = try await db.worktrees.get(id: wt.id)
        #expect(row?.path == wt.path)
        #expect(row?.promotedToRepoID == nil)
        #expect(try await db.repos.list().count == repoCountBefore)
    }

    @Test func rejectsExistingDestination() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)
        try gitInitCommit(at: wt.path)
        let repoCountBefore = try await db.repos.list().count

        let dest = home.appendingPathComponent("projects/already-here").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dest), withIntermediateDirectories: true)

        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(!resp.success)
        #expect(FileManager.default.fileExists(atPath: wt.path))          // scratch folder untouched
        let row = try await db.worktrees.get(id: wt.id)
        #expect(row?.path == wt.path)
        #expect(row?.promotedToRepoID == nil)
        #expect(try await db.repos.list().count == repoCountBefore)       // no repo row created
    }

    @Test func rejectsGitRepoWithZeroCommits() async throws {
        let (home, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)
        // git init WITHOUT a commit — distinct from the no-git-at-all case,
        // exercises the hasCommits guard specifically.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", wt.path, "init"]; try p.run(); p.waitUntilExit()
        let repoCountBefore = try await db.repos.list().count

        let dest = home.appendingPathComponent("projects/no-commits-yet").path
        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(!resp.success)
        #expect(FileManager.default.fileExists(atPath: wt.path))
        #expect(!FileManager.default.fileExists(atPath: dest))
        let row = try await db.worktrees.get(id: wt.id)
        #expect(row?.path == wt.path)
        #expect(row?.promotedToRepoID == nil)
        #expect(try await db.repos.list().count == repoCountBefore)
    }

    @Test func rejectsDestInsideScratchDir() async throws {
        let (_, cleanup) = isolate(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = makeRouter(db)
        let created = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        let wt = try created.decodeResult(Worktree.self)
        try gitInitCommit(at: wt.path)
        let repoCountBefore = try await db.repos.list().count

        // Dest is another path under the scratch base — must be rejected
        // before any mutation, same boundary check as the repo.add guard.
        let dest = TBDConstants.scratchDir.appendingPathComponent("sneaky-dest").path
        let resp = await router.handle(try RPCRequest(method: RPCMethod.scratchPromote,
            params: ScratchPromoteParams(worktreeID: wt.id, destPath: dest, displayName: nil)))
        #expect(!resp.success)
        #expect(FileManager.default.fileExists(atPath: wt.path))
        #expect(!FileManager.default.fileExists(atPath: dest))
        let row = try await db.worktrees.get(id: wt.id)
        #expect(row?.path == wt.path)
        #expect(row?.promotedToRepoID == nil)
        #expect(try await db.repos.list().count == repoCountBefore)
    }
}
}
