import Darwin
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// A claim sweep against a real holder: the app says it no longer holds a
/// session, and the daemon reads that session again.
///
/// `HolderClaimReconcileTests` covers which claims a sweep selects, on a
/// registry with no holder behind it. This file covers what a sweep's
/// take-back then does with a real pty and a real job: the reader the attach
/// suspended goes back on the descriptor, the census records the daemon
/// reading again, and the job is jiggled — `takeBacksCompleted` counts only a
/// take-back that got past its jiggle.
///
/// Every viewer here is vended to `HandbackFixture.viewerApp` under
/// `attachSeq` 5, and every sweep is that app's, through `throughSeq` 5 with
/// nothing held: the app has closed its descriptor and stopped listing the
/// session, which is the statement a sweep acts on. The exception is
/// `attachRequestRecordsItsSeq`, whose attach is a real `attach.request`
/// numbered 9.
///
/// The last two tests go through the router (`holder.reconcileClaims`), whose
/// app-identity resolver is scripted to resolve `viewerApp`'s pid to
/// `viewerApp`; the sidecar records the same identity for every vend.
///
/// **Tier 3.** A real `TBDHolder`, a real pty, a real job.
@Suite(.serialized)
struct HolderClaimReconcileLiveTests {

    /// The speak-only-when-spoken-to job the handback suites use: a job writing
    /// on its own would fill the terminal queue during the windows these tests
    /// spend with nobody reading.
    private static let echoJob = "while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done"

    /// The app's number for every attach here, and the sweep's `throughSeq`.
    private static let attachSeq: UInt64 = 5

    // MARK: - Taken back

    /// **A lost handback**, recovered. The panel closed its descriptor and its
    /// `pane.detach` never arrived, so the claim stands with nothing reading
    /// the pty. The app's next sweep leaves the session out, and the daemon
    /// puts its own suspended reader back on the pty: one reader, the same
    /// one, and the session is live again.
    @Test func anOwnedUnheldCoveredClaimIsTakenBack() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let viewer = try await fixture.attachAViewer(attachSeq: Self.attachSeq)
        let suspended = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID)
                    == .viewer(attach: viewer.generation))
        let completedBefore = await fixture.registry.takeBacksCompleted
        // The panel leaves the pty, and its handback is lost on the way.
        viewer.close()

        let sweep = await fixture.registry.reconcileClaims(
            heldBy: HandbackFixture.viewerApp, held: [], throughSeq: Self.attachSeq)

        #expect(sweep == HolderClaimSweep(takenBack: [fixture.terminalID], wouldTakeBack: []))
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil, """
            the sweep left the claim standing, so this session stays undrained and refused to \
            every attach until the app quits
            """)
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon, """
            the census does not show the daemon reading the session the sweep took back
            """)
        #expect(await fixture.registry.takeBacksCompleted == completedBefore + 1, """
            the sweep's take-back did not finish, so the job was never jiggled to repaint
            """)
        #expect(await fixture.registry.readerCensusViolations == 0)
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(resumed === suspended, """
            the sweep opened a second hand-over for a session whose own reader had never left \
            the descriptor
            """)
        #expect(await resumed.isDraining, "the sweep took the session back without reading it")

        try await resumed.write(Data("AFTER-THE-SWEEP\n".utf8))
        #expect(await pollUntil("the job's answer after the sweep") {
            await resumed.renderScreen().contains("GOT:AFTER-THE-SWEEP")
        })
    }

    /// **A lost attach reply**, recovered. The descriptor reached the app but
    /// the reply carrying the generation did not, so the app cannot hand back
    /// an attach it cannot name: it closes the descriptor and stops listing
    /// the session. The attach is still pending, delivered to that app, and
    /// the sweep covers it — settled and taken back in one pass, so its
    /// ready-timeout finds nothing left to turn into a claim.
    @Test func aSentPendingAttachIsCovered() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }

        let vend = try await fixture.registry.beginAttach(
            terminalID: fixture.terminalID, attachSeq: Self.attachSeq)
        await fixture.registry.recordAttachRecipient(
            HandbackFixture.viewerApp, terminalID: fixture.terminalID, generation: vend.generation)
        let held = try #require(await fixture.registry.reader(for: fixture.terminalID))
        Darwin.close(vend.ptyFD)

        let sweep = await fixture.registry.reconcileClaims(
            heldBy: HandbackFixture.viewerApp, held: [], throughSeq: Self.attachSeq)

        #expect(sweep == HolderClaimSweep(takenBack: [fixture.terminalID], wouldTakeBack: []), """
            an attach delivered to the app, which it says it no longer holds, was not taken back
            """)
        #expect(await fixture.registry.pendingAttachGeneration(for: fixture.terminalID) == nil)
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil)
        #expect(await fixture.registry.ptyReader(for: fixture.terminalID) == .daemon)
        #expect(await fixture.registry.takeBacksCompleted == 1)
        #expect(await fixture.registry.readerCensusViolations == 0)
        let resumed = try #require(await fixture.registry.reader(for: fixture.terminalID))
        #expect(resumed === held, "the take-back opened a second hand-over")
        #expect(await resumed.isDraining, "the suspended reader was not put back on the pty")

        // The ready-timeout still fires, late, and finds nothing left to settle.
        await fixture.registry.cancelPendingAttach(
            terminalID: fixture.terminalID, generation: vend.generation, reason: .unacknowledged)
        #expect(await fixture.registry.viewerAttachment(for: fixture.terminalID) == nil, """
            a late ready-timeout claimed a session the sweep had already taken back
            """)

        try await resumed.write(Data("AFTER-THE-LOST-REPLY\n".utf8))
        #expect(await pollUntil("the job's answer after the pending attach was taken back") {
            await resumed.renderScreen().contains("GOT:AFTER-THE-LOST-REPLY")
        })
    }

    // MARK: - One take-back at a time

    /// The app's handback attempt gave up waiting for its answer, so the
    /// session left the held set while the daemon was still putting the
    /// reader back — and the next sweep arrives inside that take-back. The
    /// claim is held across the resume by design, so the sweep sees it
    /// standing; it must leave the outcome to the take-back in flight rather
    /// than resume the same reader a second time, which the census would count
    /// as the daemon starting to read a pty it already reads.
    ///
    /// Parked through the take-back barrier rather than raced: the real window
    /// is a single `await` on the reader's actor.
    @Test func aTakeBackInFlightIsNotDoubled() async throws {
        let fixture = try await HandbackFixture.start(command: Self.echoJob)
        defer { fixture.tearDown() }
        // Only Sendable values cross into the task below.
        let registry = fixture.registry
        let terminalID = fixture.terminalID
        let row = fixture.terminalRow

        let viewer = try await fixture.attachAViewer(attachSeq: Self.attachSeq)
        let suspended = try #require(await registry.reader(for: terminalID))
        let generation = viewer.generation
        let preamble = viewer.terminal.snapshot()
        viewer.close()

        let barrier = ReentryBarrier()
        await registry.setTakeBackBarrier(barrier.hook())
        let handback = Task {
            try await registry.acceptHandback(
                terminal: row, generation: generation, preamble: preamble)
        }
        #expect(await pollUntil("the handback to reach the take-back barrier") {
            await barrier.hasParked
        })

        let sweep = await registry.reconcileClaims(
            heldBy: HandbackFixture.viewerApp, held: [], throughSeq: Self.attachSeq)

        #expect(sweep == HolderClaimSweep(takenBack: [], wouldTakeBack: []), """
            the sweep claimed a take-back the handback in flight owns
            """)
        #expect(await !suspended.isDraining, """
            the sweep resumed the reader while the handback was still taking the session back
            """)
        #expect(await registry.viewerAttachment(for: terminalID) == generation, """
            the sweep cleared a claim the handback is holding across its resume
            """)
        #expect(await registry.takeBacksCompleted == 0)

        await barrier.release()
        try await handback.value

        #expect(await registry.takeBacksCompleted == 1, "one attach was taken back twice")
        #expect(await registry.readerCensusViolations == 0, """
            a second take-back recorded the daemon as starting to read a pty it was already reading
            """)
        #expect(await registry.lastReaderCensusViolation == nil)
        #expect(await registry.viewerAttachment(for: terminalID) == nil)
        #expect(await registry.ptyReader(for: terminalID) == .daemon)
        let resumed = try #require(await registry.reader(for: terminalID))
        #expect(resumed === suspended, "the take-back opened a second hand-over")
        #expect(await resumed.isDraining, "the handback did not put the reader back on the pty")
    }

    // MARK: - Through the RPC

    /// The flag decides whether `holder.reconcileClaims` acts. Unset, the
    /// sweep names the lost handback and leaves it; written on, the way the
    /// Settings toggle writes it, the same sweep takes the session back.
    @Test func flagOnTakesBack() async throws {
        let harness = try await ReconcileRPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }

        let viewer = try await harness.fixture.attachAViewer(attachSeq: Self.attachSeq)
        let suspended = try #require(await harness.registry.reader(for: harness.terminalID))
        // The panel leaves the pty, and its handback is lost on the way.
        viewer.close()

        let report = try await harness.reconcile(throughSeq: Self.attachSeq)
        #expect(report == HolderReconcileClaimsResult(wouldTakeBack: [harness.terminalID]))
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID)
                    == viewer.generation, "a sweep with the flag unset took the session back")

        try await harness.enableTheSweep()
        let result = try await harness.reconcile(throughSeq: Self.attachSeq)

        #expect(result == HolderReconcileClaimsResult(takenBack: [harness.terminalID]), """
            with the flag on, holder.reconcileClaims did not take back a session its app says \
            it no longer holds
            """)
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == nil)
        #expect(await harness.registry.ptyReader(for: harness.terminalID) == .daemon)
        #expect(await harness.registry.readerCensusViolations == 0)
        let resumed = try #require(await harness.registry.reader(for: harness.terminalID))
        #expect(resumed === suspended, "the take-back opened a second hand-over")
        #expect(await resumed.isDraining, "the session was taken back without being read")
    }

    /// `attach.request` records the app's number for it on the attach, and
    /// the claim the attach becomes keeps it. Without that, a real attach
    /// would carry no seq and no sweep could ever take it back. The number
    /// also bounds the sweep: one built before the attach was numbered, with a
    /// `throughSeq` below it, leaves the claim alone.
    @Test func attachRequestRecordsItsSeq() async throws {
        let harness = try await ReconcileRPCHarness.start(command: Self.echoJob)
        defer { harness.tearDown() }
        try await harness.enableTheSweep()

        let response = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: harness.worktreeID, paneID: "", windowID: "",
                    attachID: UUID(), terminalID: harness.terminalID, attachSeq: 9)))
        #expect(response.success, "attach.request failed: \(response.error ?? "")")
        let generation = try #require(
            try response.decodeResult(AttachRequestResult.self).generation)
        let (vendedFD, _) = try SidecarTestSupport.receiveVend(from: harness.appSide)
        #expect(vendedFD >= 0)
        let viewer = Viewer(
            ptyFD: vendedFD, generation: generation,
            terminal: ViewerTerminal(columns: 80, rows: 24))
        defer { viewer.close() }
        let ready = await harness.router.handle(
            try RPCRequest(
                method: RPCMethod.attachReady,
                params: AttachReadyParams(
                    worktreeID: harness.worktreeID, paneID: "", generation: generation,
                    terminalID: harness.terminalID)))
        #expect(ready.success, "attach.ready failed: \(ready.error ?? "")")
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == generation)
        #expect(await harness.registry.viewerAttachmentOwner(for: harness.terminalID)
                    == HandbackFixture.viewerApp)
        let suspended = try #require(await harness.registry.reader(for: harness.terminalID))
        // The panel leaves the pty, and its handback is lost on the way.
        viewer.close()

        let before = try await harness.reconcile(throughSeq: 8)

        #expect(before == HolderReconcileClaimsResult(), """
            a sweep through seq 8 took back attach 9, which the app numbered after it built its \
            held set
            """)
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == generation)
        #expect(await !suspended.isDraining)

        let through = try await harness.reconcile(throughSeq: 9)

        #expect(through == HolderReconcileClaimsResult(takenBack: [harness.terminalID]), """
            a sweep through seq 9 did not take back attach 9: attach.request did not record \
            the app's number on the attach
            """)
        #expect(await harness.registry.viewerAttachment(for: harness.terminalID) == nil)
        #expect(await harness.registry.ptyReader(for: harness.terminalID) == .daemon)
        #expect(await suspended.isDraining, "the session was taken back without being read")
    }
}

// MARK: - The router

/// A router in front of `HandbackFixture`'s registry, with a socketpair
/// standing in for the app's fd sidecar — `HolderAttachRPCTests`' shape,
/// kept separate for the reason that suite keeps its own.
///
/// The sidecar records `HandbackFixture.viewerApp` as the peer of every vend,
/// and the router resolves that app's pid to the same identity, so a sweep
/// from that pid speaks for the app every claim here belongs to without a
/// `ps` read of this test process.
private struct ReconcileRPCHarness {
    let router: RPCRouter
    let fixture: HandbackFixture
    let worktreeID: UUID
    /// The app's end of the sidecar.
    let appSide: Int32

    var registry: HolderRegistry { fixture.registry }
    var terminalID: UUID { fixture.terminalID }

    static func start(command: String) async throws -> ReconcileRPCHarness {
        let fixture = try await HandbackFixture.start(command: command)
        do {
            return try await wire(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
    }

    private static func wire(_ fixture: HandbackFixture) async throws -> ReconcileRPCHarness {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/holder-claim-reconcile", displayName: "holder-claim-reconcile",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "holder-claim-reconcile", branch: "main",
            path: "/tmp/holder-claim-reconcile", tmuxServer: "tbd-holder-claim-reconcile")
        // The row the attach handler resolves, and branches on by transport.
        _ = try await db.terminals.create(
            id: fixture.terminalID, worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)

        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw FDChannelError.sendFailed(errno)
        }
        let vending = FDVendingServer(
            retryAttempts: 1, peerIdentity: { _ in HandbackFixture.viewerApp })
        await vending.adoptConnection(fd: pair[0])
        // Present only for its fd sidecar, the one piece of the bridge the
        // holder path borrows. The ready timeout is far beyond any test here,
        // so it never settles an attach behind one's back.
        router.controlMode = TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(), environment: [:], fdVending: vending,
            readyTimeout: .seconds(600), clock: ContinuousClock())
        router.holderRegistry = fixture.registry
        let app = HandbackFixture.viewerApp
        router.appIdentityResolver = { pid in pid == app.pid ? app : nil }

        return ReconcileRPCHarness(
            router: router, fixture: fixture, worktreeID: worktree.id, appSide: pair[1])
    }

    /// Turns the sweep on, through the RPC the Settings toggle uses.
    func enableTheSweep() async throws {
        let response = await router.handle(
            try RPCRequest(
                method: RPCMethod.configSetHolderClaimReconcileEnabled,
                params: ConfigSetHolderClaimReconcileParams(enabled: true)))
        #expect(response.success)
    }

    /// One `holder.reconcileClaims` from `viewerApp`'s pid, decoded.
    func reconcile(
        held: [UUID] = [], throughSeq: UInt64
    ) async throws -> HolderReconcileClaimsResult {
        let response = await router.handle(
            try RPCRequest(
                method: RPCMethod.holderReconcileClaims,
                params: HolderReconcileClaimsParams(
                    appPID: HandbackFixture.viewerApp.pid, held: held, throughSeq: throughSeq)))
        #expect(response.success, "holder.reconcileClaims failed: \(response.error ?? "")")
        return try response.decodeResult(HolderReconcileClaimsResult.self)
    }

    func tearDown() {
        Darwin.close(appSide)
        fixture.tearDown()
    }
}

// MARK: - Forcing an interleave

/// Holds the **first** caller that reaches the seam it is installed on, and
/// waves through every one after it — the same barrier
/// `HolderAppDeathSeizureTests` parks its handback on, for the same reason:
/// the race is a continuation-ordering accident inside an actor, so
/// reproducing it by timing would pass by luck. The polling is bounded through
/// `pollUntil`, so a barrier nobody releases fails its test with a named
/// diagnostic instead of hanging the suite.
private actor ReentryBarrier {
    private var parked = false
    private var released = false

    /// Whether a caller is being held.
    var hasParked: Bool { parked }

    /// Lets the parked caller finish.
    func release() { released = true }

    private var isReleased: Bool { released }

    /// True for the first caller only; every later one is waved through.
    private func claimPark() -> Bool {
        guard !parked else { return false }
        parked = true
        return true
    }

    nonisolated func hook() -> @Sendable () async -> Void {
        { [self] in
            guard await claimPark() else { return }
            await pollUntil("the test to release the parked take-back") { await self.isReleased }
        }
    }
}
