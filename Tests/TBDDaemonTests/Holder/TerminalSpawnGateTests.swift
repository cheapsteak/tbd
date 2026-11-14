import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import DaemonTestSupport
import TestSupport

/// `TerminalSpawnTransport.decide(registry:)`: every new session opens on a
/// pty holder, so the gate grants a registry that can spawn and refuses
/// everything else with a reason that names the missing helper. There is no
/// tmux fallback, and a caller turns the refusal into its own error before it
/// records anything.
@Suite("Terminal spawn gate")
struct TerminalSpawnGateTests {

    private static func registry(spawner: HolderSpawner?) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: FakeHolderLaunch.scratchEnvironment(),
            listTerminals: { [] },
            spawner: spawner)
    }

    // MARK: - decide

    /// A registry holding a spawner can start a holder, so the gate grants it
    /// and carries that very registry into the spawn. `canSpawn` is decided
    /// from the spawner's presence alone, so nothing is launched here.
    @Test func aRegistryThatCanSpawnIsGranted() throws {
        let registry = Self.registry(spawner: HolderSpawner(
            executableURL: URL(fileURLWithPath: "/nonexistent/TBDHolder")))
        #expect(registry.canSpawn)

        let granted = try TerminalSpawnTransport.decide(registry: registry).get()

        #expect(granted.registry === registry)
    }

    @Test func noRegistryIsRefused() {
        let decision = TerminalSpawnTransport.decide(registry: nil)

        guard case .failure(let refusal) = decision else {
            Issue.record("the gate granted a spawn with no registry")
            return
        }
        #expect(refusal == .holderUnavailable)
    }

    /// A registry with no spawner is what a daemon builds when its `TBDHolder`
    /// binary has gone: it can still adopt a running holder, but it cannot
    /// start one, so the gate refuses rather than granting a spawn that would
    /// fail later.
    @Test func aRegistryThatCannotSpawnIsRefused() {
        let registry = Self.registry(spawner: nil)
        #expect(!registry.canSpawn)

        let decision = TerminalSpawnTransport.decide(registry: registry)

        guard case .failure(let refusal) = decision else {
            Issue.record("the gate granted a registry that cannot spawn")
            return
        }
        #expect(refusal == .holderUnavailable)
    }

    /// The refusal is phrased for the person who asked for the session: it
    /// names the missing helper and the way to put it back.
    @Test func theRefusalNamesTheMissingHelper() {
        let message = TerminalSpawnRefusal.holderUnavailable.message
        #expect(message.contains("TBDHolder"))
        #expect(message.contains("tbd update"))
        #expect("\(TerminalSpawnRefusal.holderUnavailable)" == message)
    }

    // MARK: - Through a caller

    /// `terminal.create` on a daemon that cannot start a holder answers with
    /// the gate's refusal and writes no row.
    @Test func terminalCreateRefusesWithTheGatesMessage() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(),
            actuationLog: makeTestActuationLog())
        router.holderRegistry = Self.registry(spawner: nil)
        let scratch = fencedScratchRoot(prefix: "tbdgate")
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let wtPath = "\(scratch)/wt"
        try FileManager.default.createDirectory(atPath: wtPath, withIntermediateDirectories: true)
        let repo = try await db.repos.create(
            path: "\(scratch)/repo", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: wtPath, tmuxServer: "tbd-gate-test")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktree.id, cmd: "htop")))

        #expect(!response.success)
        #expect(response.error == TerminalSpawnRefusal.holderUnavailable.message)
        #expect(try await db.terminals.list(worktreeID: worktree.id).isEmpty)
    }

    /// `worktree.create` on a daemon that cannot start a holder answers with
    /// the gate's refusal before phase 1, so the caller sees it, and no row
    /// exists for a detached phase 2 to fail later.
    @Test func worktreeCreateRefusesBeforeAnythingIsMade() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(),
            actuationLog: makeTestActuationLog())
        router.holderRegistry = Self.registry(spawner: nil)
        let scratch = fencedScratchRoot(prefix: "tbdgate")
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let repo = try await db.repos.create(
            path: "\(scratch)/repo", displayName: "acme", defaultBranch: "main")

        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repo.id)))

        #expect(!response.success)
        #expect(response.error == TerminalSpawnRefusal.holderUnavailable.message)
        #expect(try await db.worktrees.list(repoID: repo.id).isEmpty,
                "the refused create wrote a worktree row")
    }

    /// The revive entry points that ask start admission.
    enum ReviveEntry: CaseIterable, Sendable {
        case revive
        case reviveConversationFresh
    }

    /// A revive on a daemon that cannot start a holder answers with the gate's
    /// refusal before start admission is asked, even with admission set to
    /// hold. The person learns the helper is missing instead of reading a hold
    /// reason for a start that could never run, and the worktree stays
    /// archived.
    @Test(arguments: ReviveEntry.allCases)
    func aReviveIsRefusedBeforeStartAdmission(_ entry: ReviveEntry) async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true), startTime: Date(),
            actuationLog: makeTestActuationLog())
        router.holderRegistry = Self.registry(spawner: nil)
        let admission = StubAdmission(.hold(reason: "camera in use"))
        router.startAdmission = admission
        try await db.config.setStartAdmissionEnabled(true)
        let scratch = fencedScratchRoot(prefix: "tbdgate")
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let repo = try await db.repos.create(
            path: "\(scratch)/repo", displayName: "acme", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "wt", branch: "tbd/wt",
            path: "\(scratch)/wt", tmuxServer: "tbd-gate-test")
        try await db.worktrees.archive(id: worktree.id)

        let request: RPCRequest
        switch entry {
        case .revive:
            request = try RPCRequest(
                method: RPCMethod.worktreeRevive,
                params: WorktreeReviveParams(worktreeID: worktree.id))
        case .reviveConversationFresh:
            request = try RPCRequest(
                method: RPCMethod.worktreeReviveConversationFresh,
                params: WorktreeReviveConversationFreshParams(
                    archivedWorktreeID: worktree.id, sessionID: "acme-session"))
        }
        let response = await router.handle(request)

        #expect(response.error == TerminalSpawnRefusal.holderUnavailable.message)
        #expect(response.errorCode != RPCErrorCode.startHeld.rawValue)
        #expect(admission.requests.isEmpty,
                "start admission was asked about a revive that cannot start")
        #expect(try await db.worktrees.get(id: worktree.id)?.status == .archived,
                "the refused revive changed the row's status")
    }
}
