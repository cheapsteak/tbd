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
}
