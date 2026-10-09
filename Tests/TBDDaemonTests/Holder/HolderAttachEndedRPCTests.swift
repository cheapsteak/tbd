import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1: `attach.request` for a holder row the registry holds no reader for.
/// No holder is spawned — the registry simply never adopted the session, which
/// is exactly the state a killed holder leaves behind — and holder liveness is
/// the router's injected `holderProcessIsLive`.
///
/// The app shows "the session keeps running, reopen the tab" for an attach
/// error, and "this session has ended" for the ended status, so the status may
/// be answered only when the row's holder is positively gone.
@Suite("A holder attach with no reader reports an ended session only when its holder is gone")
struct HolderAttachEndedRPCTests {

    private func makeRouter(holderPID: Int32?) async throws -> (RPCRouter, UUID, UUID) {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/holder-ended", displayName: "holder-ended", defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "holder-ended", branch: "main",
            path: "/tmp/holder-ended", tmuxServer: "tbd-holder-ended")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "", kind: .claude,
            transport: .holder, holderPID: holderPID, childPID: holderPID.map { $0 + 1 })
        router.controlMode = TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(), environment: [:], fdVending: FDVendingServer())
        router.holderRegistry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: [:],
            listTerminals: { [] })
        return (router, worktree.id, terminal.id)
    }

    private func attach(
        _ router: RPCRouter, worktreeID: UUID, terminalID: UUID
    ) async throws -> RPCResponse {
        await router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: worktreeID, paneID: "", windowID: "", attachID: UUID(),
                    terminalID: terminalID)))
    }

    /// A process table in which the recorded child (4243) names nothing.
    private func deadChild() -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[4243] = .init(aliveInitially: false)
        return signaller
    }

    /// A process table in which the recorded child is alive and verifiably
    /// this session's job: started at the row's anchor, running a shell.
    private func liveChild(startedAt anchor: Date) -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        signaller.startTimes[4243] = anchor
        signaller.cmdlines[4243] = "/bin/zsh -i -l -c claude"
        return signaller
    }

    @Test("a dead recorded holder whose job is gone answers the ended status")
    func deadHolderIsEnded() async throws {
        let (router, worktreeID, terminalID) = try await makeRouter(holderPID: 4242)
        let probed = LockedPIDs()
        router.holderProcessIsLive = { pid in probed.append(pid); return false }
        router.holderChildSignaller = deadChild()

        let response = try await attach(router, worktreeID: worktreeID, terminalID: terminalID)

        #expect(response.success)
        #expect(try response.decodeResult(AttachRequestResult.self).status
            == AttachRequestResult.holderSessionEndedStatus)
        #expect(probed.values == [4242])
    }

    /// The holder died but its job did not — a viewer holding a dup of the pty
    /// master keeps the job from seeing a hangup. Telling that tab its session
    /// ended would be the same lie in the other direction.
    @Test("a dead holder whose job still runs keeps the attach error")
    func deadHolderWithALiveJobIsAnError() async throws {
        let (router, worktreeID, terminalID) = try await makeRouter(holderPID: 4242)
        router.holderProcessIsLive = { _ in false }
        let row = try #require(try await router.db.terminals.get(id: terminalID))
        router.holderChildSignaller = liveChild(
            startedAt: row.holderChildStartedAt ?? row.createdAt)

        let response = try await attach(router, worktreeID: worktreeID, terminalID: terminalID)

        #expect(!response.success)
        #expect(response.error?.contains("no live holder reader") == true)
    }

    @Test("a live recorded holder keeps the attach error")
    func liveHolderIsAnError() async throws {
        let (router, worktreeID, terminalID) = try await makeRouter(holderPID: 4242)
        router.holderProcessIsLive = { _ in true }

        let response = try await attach(router, worktreeID: worktreeID, terminalID: terminalID)

        #expect(!response.success)
        #expect(response.error?.contains("no live holder reader") == true)
    }

    @Test("a row with no recorded holder is never judged ended")
    func unrecordedHolderIsAnError() async throws {
        let (router, worktreeID, terminalID) = try await makeRouter(holderPID: nil)
        router.holderProcessIsLive = { _ in false }

        let response = try await attach(router, worktreeID: worktreeID, terminalID: terminalID)

        #expect(!response.success)
    }

    /// The registry checks a viewer claim and a pending attach before it looks
    /// for a reader, so a dead holder can be refused with either of those
    /// first. All three mean ended when the holder is gone, and none of them
    /// does while it lives or when no holder pid was recorded; every other
    /// refusal is about the request, never the session.
    @Test("every refusal that can front a dead holder reads as ended, and only then")
    func refusalsThatCanFrontADeadHolder() async throws {
        let (router, _, _) = try await makeRouter(holderPID: 4242)
        let id = UUID()
        let recorded = TBDShared.Terminal(
            id: id, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder, holderPID: 4242, childPID: 4243)
        var unrecorded = recorded
        unrecorded.holderPID = nil
        let endable: [HolderRegistry.Error] = [
            .noLiveReader(terminalID: id),
            .attachedToViewer(terminalID: id),
            .attachAlreadyPending(terminalID: id, generation: 7),
        ]
        let others: [HolderRegistry.Error] = [
            .notAHolderSession(terminalID: id),
            .attachSuperseded(terminalID: id, generation: 7),
            .sessionAlreadyRegistered(terminalID: id),
        ]

        router.holderProcessIsLive = { _ in false }
        router.holderChildSignaller = deadChild()
        for error in endable {
            #expect(router.attachRefusalMeansSessionEnded(error, terminal: recorded), "\(error)")
            #expect(!router.attachRefusalMeansSessionEnded(error, terminal: unrecorded), "\(error)")
        }
        for error in others {
            #expect(!router.attachRefusalMeansSessionEnded(error, terminal: recorded), "\(error)")
        }

        router.holderProcessIsLive = { _ in true }
        for error in endable {
            #expect(!router.attachRefusalMeansSessionEnded(error, terminal: recorded), "\(error)")
        }

        router.holderProcessIsLive = { _ in false }
        router.holderChildSignaller = liveChild(startedAt: recorded.createdAt)
        for error in endable {
            #expect(!router.attachRefusalMeansSessionEnded(error, terminal: recorded), "\(error)")
        }
    }

    private final class LockedPIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int32] = []
        func append(_ pid: Int32) { lock.withLock { stored.append(pid) } }
        var values: [Int32] { lock.withLock { stored } }
    }
}
