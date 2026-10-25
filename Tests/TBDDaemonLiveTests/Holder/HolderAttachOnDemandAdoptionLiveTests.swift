import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// An attach adopts a live session the registry never adopted, and leaves a
/// session whose reader is being released alone.
///
/// The first is the state a failed startup adoption leaves: the holder and its
/// job are running, the row names them, and no reader exists. `attach.request`
/// is where somebody asks to see that session, so it adopts it and vends the
/// pty it just took. The second is the line it must not cross: a reader on its
/// way out is a teardown, a reclaim or a shutdown in progress, and adopting
/// beside it would resurrect a session something has decided to let go.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, a real job, and a real
/// `socketpair` standing in for the app's sidecar.
@Suite(.serialized)
struct HolderAttachOnDemandAdoptionLiveTests {

    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    @Test func anAttachToALiveSessionNobodyAdoptedVendsItsPty() async throws {
        let process = try await HolderProcessFixture.start(command: Self.echoJob)
        defer { process.tearDown() }
        // The spawner's handshake connection goes, and nothing takes its
        // place: no adoption ever runs for this session before the attach.
        await process.client.close()
        let registry = HolderRegistry(
            owner: process.owner,
            environment: HolderProcessFixture.environment(home: process.home),
            listTerminals: { [] })
        defer { Task.detached { await registry.releaseAll() } }
        let harness = try await SidecarRouter.make(
            terminalID: process.sessionID, registry: registry)
        defer { harness.tearDown() }
        #expect(await registry.reader(for: process.sessionID) == nil)

        let attachID = UUID()
        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: harness.worktreeID, paneID: "", windowID: "",
                    attachID: attachID, terminalID: process.sessionID)))

        try #require(response.success, """
            an attach to a live session nobody had adopted was refused, so the session stays \
            undrained and unattachable for the daemon's life: \(response.error ?? "nil")
            """)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "pending")
        #expect(result.generation != nil)
        let (vendedFD, header) = try SidecarTestSupport.receiveVend(from: harness.appSide)
        defer { Darwin.close(vendedFD) }
        #expect(header.attachID == attachID)

        // The descriptor is the session's live pty, not merely a descriptor.
        try writePTY(fd: vendedFD, "ON-DEMAND\n")
        #expect(readPTYUntil(fd: vendedFD, contains: "GOT:ON-DEMAND") != nil,
                "the vended descriptor never carried the job's answer")
        // One adoption, by the attach, and the daemon stepped off the pty at
        // the vend exactly as it does for a session adopted at startup.
        #expect(await registry.drainLoopsStarted == 1)
        let reader = try #require(await registry.reader(for: process.sessionID))
        #expect(await !reader.isDraining)
        #expect(await registry.peakLiveDrainLoops == 1)
    }

    @Test func anAttachDoesNotAdoptASessionWhoseReaderIsBeingReleased() async throws {
        let process = try await HolderProcessFixture.start(command: Self.echoJob)
        defer { process.tearDown() }
        await process.client.close()
        let registry = HolderRegistry(
            owner: process.owner,
            environment: HolderProcessFixture.environment(home: process.home),
            listTerminals: { [] })
        defer { Task.detached { await registry.releaseAll() } }
        let row = TBDShared.Terminal(
            id: process.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
        _ = try await registry.adopt(terminal: row)
        #expect(await registry.attachRoundTripsStarted == 1)
        // The attach handler's fast path: an adopted session has nothing to
        // adopt, so the handler asks nothing further.
        #expect(await !registry.needsAdoptionForAttach(terminalID: row.id))

        // The release is held with its reader still on the pty: the slot reads
        // `.releasing` for as long as the test keeps it there.
        let hold = ReleaseHold()
        await registry.setReleaseBarrier(hold.hook())
        let releasing = Task { await registry.release(terminalID: row.id) }
        let parked = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await hold.parked == 1
        }
        guard parked == .satisfied else {
            await hold.release()
            await releasing.value
            Issue.record(BoundedWaitTimeout(
                what: "the release to reach its barrier",
                observed: "no release parked", deadline: TestDeadlines.saturatedPass))
            return
        }

        try await registry.adoptForAttach(terminal: row)
        await hold.release()
        await releasing.value

        // Read after the release has finished, which is when an adoption that
        // had waited the release out would open its hand-over.
        #expect(await registry.attachRoundTripsStarted == 1, """
            an attach adopted a session whose reader was being released, resurrecting a session \
            something had decided to let go
            """)
        #expect(await registry.reader(for: row.id) == nil)
        #expect(await registry.drainLoopsStarted == 1)
    }
}

// MARK: - Support

/// A router whose only holder row is `terminalID`, with a socketpair standing
/// in for the app's sidecar.
private struct SidecarRouter {
    let router: RPCRouter
    let worktreeID: UUID
    /// The app's end of the sidecar.
    let appSide: Int32

    static func make(terminalID: UUID, registry: HolderRegistry) async throws -> SidecarRouter {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/holder-attach-on-demand", displayName: "holder-attach-on-demand",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "holder-attach-on-demand", branch: "main",
            path: "/tmp/holder-attach-on-demand", tmuxServer: "tbd-holder-attach-on-demand")
        _ = try await db.terminals.create(
            id: terminalID, worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)

        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw FDChannelError.sendFailed(errno)
        }
        let vending = FDVendingServer(retryAttempts: 1)
        await vending.adoptConnection(fd: pair[0])
        // Present for its fd sidecar alone. The ready timeout is far past the
        // test, so no acknowledgement is ever owed within it.
        router.controlMode = TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(), environment: [:], fdVending: vending,
            readyTimeout: .seconds(600))
        router.holderRegistry = registry
        return SidecarRouter(router: router, worktreeID: worktree.id, appSide: pair[1])
    }

    func tearDown() {
        Darwin.close(appSide)
    }
}

/// Holds every release that reaches the release seam until the test lets it
/// through. Suspends rather than blocking a thread.
private actor ReleaseHold {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var parked = 0

    func park() async {
        if released { return }
        parked += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    nonisolated func hook() -> @Sendable () async -> Void {
        { [self] in await self.park() }
    }
}
