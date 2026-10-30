import Foundation
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

/// A daemon that has begun shutting down attaches nothing and adopts nothing,
/// and says why.
///
/// `Daemon.stop()` releases every holder reader long before it stops the fd
/// sidecar and the RPC socket, and an app relaunched by an update reaches the
/// dying daemon in that window. Answering its attach `noLiveReader` — "this
/// session has no reader" — would read as a session the daemon lost, and
/// anything adopted in the window would build a reader `releaseAll` has
/// already decided not to visit.
///
/// Tier 1: no holder answers anywhere — `TBD_HOME` names a directory that does
/// not exist — so an adoption that did start would fail at its connect, and
/// `attachRoundTripsStarted` is what tells "refused" from "tried and failed".
@Suite("A shutting-down holder registry refuses every attach and adoption by name")
struct HolderShutdownAttachTests {

    private static func registry() -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/nonexistent/acme-tbd-home"],
            listTerminals: { [] })
    }

    private static func holderRow(id: UUID = UUID()) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: id, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder)
    }

    @Test("an attach after releaseAll is refused as daemonShuttingDown, not noLiveReader")
    func anAttachDuringShutdownNamesTheShutdown() async throws {
        let registry = Self.registry()
        let session = UUID()
        await #expect(throws: HolderRegistry.Error.noLiveReader(terminalID: session)) {
            _ = try await registry.beginAttach(terminalID: session)
        }

        await registry.releaseAll()

        #expect(await registry.isShuttingDown)
        await #expect(throws: HolderRegistry.Error.daemonShuttingDown(terminalID: session)) {
            _ = try await registry.beginAttach(terminalID: session)
        }
    }

    @Test("an adoption after releaseAll opens no hand-over")
    func anAdoptionDuringShutdownOpensNoHandOver() async throws {
        let registry = Self.registry()
        let row = Self.holderRow()
        // The control: before the shutdown, an adoption does reach for the
        // holder — and fails at the connect, since none is there.
        await #expect(throws: (any Error).self) {
            _ = try await registry.adopt(terminal: Self.holderRow())
        }
        let before = await registry.attachRoundTripsStarted
        #expect(before == 1)

        await registry.releaseAll()

        await #expect(throws: HolderRegistry.Error.daemonShuttingDown(terminalID: row.id)) {
            _ = try await registry.adopt(terminal: row)
        }
        await registry.adoptRemaining([Self.holderRow(), Self.holderRow()])
        #expect(await registry.attachRoundTripsStarted == before, """
            an adoption opened a hand-over after releaseAll began, building a reader nothing \
            will ever stop
            """)
        #expect(await registry.reader(for: row.id) == nil)
    }

    @Test("attach.request to a shutting-down daemon answers an error that names the shutdown")
    func theAttachRPCNamesTheShutdown() async throws {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/holder-shutdown", displayName: "holder-shutdown", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "holder-shutdown", branch: "main",
            path: "/tmp/holder-shutdown", tmuxServer: "tbd-holder-shutdown")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "", kind: .claude,
            transport: .holder, holderPID: 4242, childPID: 4243)
        router.controlMode = TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(), environment: [:], fdVending: FDVendingServer())
        let registry = Self.registry()
        router.holderRegistry = registry
        // A live holder, so nothing about the session reads as ended and only
        // the shutdown can explain the refusal.
        router.holderProcessIsLive = { _ in true }

        await registry.releaseAll()
        let response = await router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: worktree.id, paneID: "", windowID: "", attachID: UUID(),
                    terminalID: terminal.id)))

        #expect(!response.success)
        #expect(response.error?.contains("shutting down") == true, """
            the attach was refused without saying the daemon is shutting down: \
            \(response.error ?? "nil")
            """)
        #expect(response.error?.contains("no live holder reader") == false)
        #expect(await registry.attachRoundTripsStarted == 0)
    }
}
