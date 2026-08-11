import Testing
import TestSupport
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
        let priorTBDHome = setTBDHome(home.path)
        return (home, { restoreTBDHome(priorTBDHome); try? FileManager.default.removeItem(at: home) })
    }

    @Test func createsRepoLessWorktreeRowAndDirectory() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

        let request = try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil))
        let response = await router.handle(request)
        #expect(response.success)

        let wt = try response.decodeResult(Worktree.self)
        #expect(wt.repoID == nil)
        #expect(wt.isScratch)
        #expect(wt.localPath.hasPrefix(TBDConstants.scratchDir.path))
        #expect(FileManager.default.fileExists(atPath: wt.localPath))
        let all = try await db.worktrees.listScratch()
        #expect(all.count == 1)
    }

    /// Scratch create now spawns exactly ONE default primary agent terminal —
    /// no "Setup" tab (that's the repo-only `if let repo` branch in
    /// spawnPrimaryTerminals). With the default primaryAgentPreference the
    /// primary is a Claude terminal, and it is the single tab / active tab.
    @Test func spawnsSingleDefaultClaudePrimaryTerminal() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

        let response = await router.handle(
            try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        #expect(response.success)
        let wt = try response.decodeResult(Worktree.self)

        // Exactly one terminal: the primary. No "Setup" tab for scratch.
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 1)
        let primary = try #require(terminals.first)
        #expect(primary.kind == .claude)          // default primaryAgentPreference
        #expect(primary.label == TerminalLabel.claudeCode)
        #expect(!terminals.contains { $0.label == TerminalLabel.setup })

        // Tab order + active tab are that single terminal.
        let tabOrder = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        #expect(tabOrder == [primary.id])
        let activeTab = try await db.worktrees.getActiveTabID(worktreeID: wt.id)
        #expect(activeTab == primary.id)
    }

    /// With the global primaryAgentPreference set to `.codex`, the single
    /// spawned scratch terminal is a Codex terminal.
    @Test func spawnsCodexPrimaryWhenPreferenceIsCodex() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        // Codex spawn resolves CODEX_HOME via CodexHomeManager; point it at a
        // sandbox temp dir so it never touches the developer's real config.
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-scratch-codex-\(UUID().uuidString)")
        let priorCodexHome = setCodexTestHome(codexHome.path)
        defer {
            restoreCodexTestHome(priorCodexHome)
            try? FileManager.default.removeItem(at: codexHome)
        }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPrimaryAgentPreference(.codex)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

        let response = await router.handle(
            try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: nil)))
        #expect(response.success)
        let wt = try response.decodeResult(Worktree.self)

        let terminals = try await db.terminals.list(worktreeID: wt.id)
        #expect(terminals.count == 1)
        let primary = try #require(terminals.first)
        #expect(primary.kind == .codex)
        #expect(primary.label == TerminalLabel.codex)
    }

    @Test func honorsExplicitNameAndRegeneratesOnCollision() async throws {
        let iso = isolateTBDHome(); defer { iso.cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(), actuationLog: makeTestActuationLog())

        let r1 = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "notes")))
        let w1 = try r1.decodeResult(Worktree.self)
        #expect(w1.name == "notes")
        // Second create with the same name must not collide on the unique path.
        let r2 = await router.handle(try RPCRequest(method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: "notes")))
        let w2 = try r2.decodeResult(Worktree.self)
        #expect(w2.localPath != w1.localPath)
    }
}
}
