import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// An attach adopts the session it names when the registry is not reading it,
/// and never one that is on its way out.
///
/// Startup adoption can leave a live session unadopted — a holder busy or
/// silent past its budget, a row deferred past the startup budget, a take-back
/// whose hand-over failed — and an attach that only refused such a session as
/// `noLiveReader` would refuse it for the daemon's whole life, since nothing
/// else comes back for it. The other half of the contract is what must stay
/// refused: a parked
/// row, one a park, wake or swap is moving, a holder this daemon told to let
/// go, a job that has ended, a viewer's pty, a shutting-down daemon.
///
/// **No holder answers anywhere here.** `TBD_HOME` names a directory that does
/// not exist, so an adoption that starts fails at its connect. What tells
/// "tried" from "refused" is `attachRoundTripsStarted`, which counts the
/// hand-overs the registry committed to; the success path, with a real holder
/// on the other end, is `HolderAttachOnDemandAdoptionLiveTests`'.
///
/// Tier 1: no holder, no pty, and virtual time where anything waits.
@Suite(.clockDriven) struct HolderAttachAdoptionTests {

    private static let budget: Duration = .seconds(5)

    private static func registry(
        clock: any Clock<Duration> = ContinuousClock()
    ) -> HolderRegistry {
        HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/nonexistent/acme-tbd-home"],
            listTerminals: { [] },
            attachAdoptionBudget: budget,
            clock: clock)
    }

    private static func holderRow(id: UUID = UUID()) -> TBDShared.Terminal {
        TBDShared.Terminal(
            id: id, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder)
    }

    // MARK: - What the registry adopts, and what it leaves alone

    /// The control every refusal below is measured against: a session nobody
    /// is reading, with nothing said against it, gets a hand-over.
    @Test func anAttachReachesForTheHolderOfASessionNobodyIsReading() async throws {
        let registry = Self.registry()
        let row = Self.holderRow()

        try await registry.adoptForAttach(terminal: row)

        #expect(await registry.attachRoundTripsStarted == 1, """
            an attach to a session no reader holds did not try to adopt it, so the session stays \
            undrained and refused to every attach
            """)
        // Nothing answered, so nothing was published and `beginAttach` is left
        // to say so — the error the attach handler reads as ended or not.
        #expect(await registry.reader(for: row.id) == nil)
        await #expect(throws: HolderRegistry.Error.noLiveReader(terminalID: row.id)) {
            _ = try await registry.beginAttach(terminalID: row.id)
        }
    }

    /// A torn-down or parked session's holder has been told to forget its pty,
    /// and `abandon` empties the slot before it says so. An attach arriving in
    /// that gap must not take the pty of a holder that is letting go.
    @Test func aSessionWhoseHolderWasToldToLetGoIsNotAdopted() async throws {
        let registry = Self.registry()
        let row = Self.holderRow()
        _ = await registry.abandon(terminalID: row.id, holderPID: nil, childPID: nil)

        try await registry.adoptForAttach(terminal: row)

        #expect(await registry.attachRoundTripsStarted == 0, """
            an attach reached for the holder of a session this daemon had already told to let go
            """)
    }

    /// A holder whose job has exited still hands over its master, so the
    /// output nobody read can be rescued — which makes the remembered status
    /// the only thing standing between an attach and a reader over a finished
    /// session.
    @Test(arguments: [HolderChildStatus.exited(code: 0), .exitedStatusUnknown])
    func aSessionWhoseJobHasEndedIsNotAdopted(_ ended: HolderChildStatus) async throws {
        let registry = Self.registry()
        let row = Self.holderRow()
        await registry.recordStatusForTesting(ended, for: row.id)

        try await registry.adoptForAttach(terminal: row)

        #expect(await registry.attachRoundTripsStarted == 0, """
            an attach adopted a session whose job had already ended (\(ended))
            """)
    }

    /// The other side of the status gate: a job last seen alive is no reason
    /// to stay away, or the gate would refuse every session that was ever
    /// adopted and then lost its reader.
    @Test func aSessionLastSeenAliveIsStillAdopted() async throws {
        let registry = Self.registry()
        let row = Self.holderRow()
        await registry.recordStatusForTesting(.alive, for: row.id)

        try await registry.adoptForAttach(terminal: row)

        #expect(await registry.attachRoundTripsStarted == 1)
    }

    /// A viewer's pty is never the daemon's to read, and the refusal belongs
    /// to `beginAttach`, which names it.
    @Test func aSessionAViewerHoldsIsNotAdopted() async throws {
        let registry = Self.registry()
        let row = Self.holderRow()
        await registry.recordViewerClaimForTesting(terminalID: row.id, generation: 3, owner: nil)

        try await registry.adoptForAttach(terminal: row)

        #expect(await registry.attachRoundTripsStarted == 0)
        await #expect(throws: HolderRegistry.Error.attachedToViewer(terminalID: row.id)) {
            _ = try await registry.beginAttach(terminalID: row.id)
        }
    }

    /// The fast path's question: an attach looks no further — no coordinator
    /// hop, no task, no timer — when a viewer claim or a pending attach means
    /// `beginAttach` will refuse anyway. (The commonest no, a published
    /// reader, needs a holder; `HolderAttachOnDemandAdoptionLiveTests` asks
    /// it there.)
    @Test func anAttachLooksFurtherOnlyWhenNothingAlreadyAnswersIt() async throws {
        let registry = Self.registry()
        let unread = UUID()
        let claimed = UUID()
        let pending = UUID()
        await registry.recordViewerClaimForTesting(terminalID: claimed, generation: 1, owner: nil)
        await registry.recordPendingAttachForTesting(
            terminalID: pending, generation: 2,
            reader: HolderReader(
                sessionID: pending, ptyFD: -1, columns: 80, rows: 24,
                observedChildFromStart: true),
            recipient: nil)

        #expect(await registry.needsAdoptionForAttach(terminalID: unread))
        #expect(await !registry.needsAdoptionForAttach(terminalID: claimed))
        #expect(await !registry.needsAdoptionForAttach(terminalID: pending))
    }

    @Test func aShuttingDownRegistryRefusesTheAdoptionByName() async throws {
        let registry = Self.registry()
        let row = Self.holderRow()
        await registry.releaseAll()

        await #expect(throws: HolderRegistry.Error.daemonShuttingDown(terminalID: row.id)) {
            try await registry.adoptForAttach(terminal: row)
        }
        #expect(await registry.attachRoundTripsStarted == 0)
    }

    // MARK: - The wait is bounded

    /// An attach waits for its adoption only as long as the budget, on the
    /// injected clock. The adoption is held at its publish step — after its
    /// connect has failed, before it settles — for as long as the test likes,
    /// which is exactly a holder that never finishes answering. Without the
    /// bound the attach would wait with it, and so would the RPC.
    @Test func anAttachGoesOnWithoutAnAdoptionThatOutlastsTheBudget() async throws {
        let clock = EventDrivenTestClock()
        let registry = Self.registry(clock: clock)
        let hold = PublishHold()
        await registry.setPublishBarrier(hold.hook())
        let row = Self.holderRow()
        let returned = ReturnFlag()

        let attaching = Task {
            try await registry.adoptForAttach(terminal: row)
            returned.set()
        }
        // Held first, so the limit can only fire on an adoption that has not
        // settled — whatever the attach does next is the bound's doing.
        let held = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await hold.parked == 1
        }
        guard held == .satisfied else {
            await hold.release()
            Issue.record(BoundedWaitTimeout(
                what: "the attach's adoption to reach its publish step",
                observed: "no adoption parked", deadline: TestDeadlines.saturatedPass))
            return
        }
        do {
            try await clock.requireAdvanceWhenArmed(by: Self.budget)
        } catch {
            await hold.release()
            throw error
        }
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { returned.isSet }
        // Let the held adoption finish either way, so nothing outlives the test.
        await hold.release()
        try await attaching.value

        if outcome == .timedOut {
            Issue.record(BoundedWaitTimeout(
                what: "adoptForAttach to return once its budget passed",
                observed: "it was still waiting on an adoption held at its publish step",
                deadline: TestDeadlines.saturatedPass))
        }
        #expect(await registry.attachRoundTripsStarted == 1)
    }

    /// The other arm of the race: work that settles first is what the caller
    /// gets, and the timer it beat is cancelled rather than left asleep.
    @Test func workThatSettlesFirstIsReturnedAndItsTimerCancelled() async throws {
        let clock = EventDrivenTestClock()
        let work = Task<Int, any Error> { 7 }

        let outcome = await HolderRegistry.settlement(of: work, within: .seconds(3), clock: clock)

        #expect(try outcome?.get() == 7)
        let quiet = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { !clock.hasSleeper }
        #expect(quiet == .satisfied, "the race left its timer asleep after the work had won")
    }

    // MARK: - What the attach handler rules out first

    /// The row-level gates live in the router, because only the row knows it
    /// is parked and only the hibernation coordinator knows a transition is
    /// moving it. Each is measured against the same awake, unadopted row.
    @Test func anAttachAdoptsOnlyAnAwakeRowNothingIsMoving() async throws {
        let harness = try await RouterHarness.make()

        _ = try await harness.attach()
        #expect(await harness.registry.attachRoundTripsStarted == 1, """
            an attach to an awake row nobody is reading did not try to adopt it
            """)

        #expect(await harness.router.hibernationCoordinator.claimSwap(terminalID: harness.terminalID))
        _ = try await harness.attach()
        #expect(await harness.registry.attachRoundTripsStarted == 1, """
            an attach adopted a session an in-place profile swap was moving
            """)
        await harness.router.hibernationCoordinator.releaseSwap(terminalID: harness.terminalID)

        try await harness.db.terminals.setHibernated(
            id: harness.terminalID, sessionID: "sess-acme")
        let response = try await harness.attach()
        #expect(await harness.registry.attachRoundTripsStarted == 1, """
            an attach adopted a parked session, whose job its park had ended
            """)
        #expect(!response.success)
    }

    /// The park and wake branches of the same gate, each against its own
    /// control: the row is adopted on demand once the claim is gone, so the
    /// claim alone is what held the attach back.
    @Test(arguments: [InFlightClaim.hibernate, .wake])
    func anAttachDoesNotAdoptARowAParkOrWakeIsMoving(_ claim: InFlightClaim) async throws {
        let harness = try await RouterHarness.make()
        let coordinator = harness.router.hibernationCoordinator

        await coordinator.holdForTesting(claim, terminalID: harness.terminalID)
        #expect(await coordinator.transitionInFlight(terminalID: harness.terminalID))
        _ = try await harness.attach()
        #expect(await harness.registry.attachRoundTripsStarted == 0, """
            an attach adopted a session a \(claim) in flight was moving
            """)

        await coordinator.releaseForTesting(claim, terminalID: harness.terminalID)
        #expect(await !coordinator.transitionInFlight(terminalID: harness.terminalID))
        _ = try await harness.attach()
        #expect(await harness.registry.attachRoundTripsStarted == 1, """
            with the \(claim) claim gone the attach still did not adopt, so the claim was not \
            what held it back
            """)
    }

    /// An ended session is answered as ended, and without reaching for its
    /// holder first: the status gate stops the adoption, and the handler's
    /// own verdict on a dead holder and a gone job does the rest.
    @Test func anAttachToAnEndedSessionAnswersEndedWithoutAdopting() async throws {
        let harness = try await RouterHarness.make()
        await harness.registry.recordStatusForTesting(.exitedStatusUnknown, for: harness.terminalID)
        harness.router.holderProcessIsLive = { _ in false }
        let signaller = FakeProcessSignaller()
        signaller.behaviors[4243] = .init(aliveInitially: false)
        harness.router.holderChildSignaller = signaller

        let response = try await harness.attach()

        #expect(response.success)
        #expect(try response.decodeResult(AttachRequestResult.self).status
            == AttachRequestResult.holderSessionEndedStatus)
        #expect(await harness.registry.attachRoundTripsStarted == 0)
    }
}

// MARK: - Support

/// The coordinator claims a test can stand up without running the park or
/// wake that takes it. The swap's claim has its own entry points
/// (`claimSwap`, `releaseSwap`).
enum InFlightClaim: String, Sendable, CustomStringConvertible {
    case hibernate = "park"
    case wake

    var description: String { rawValue }
}

extension HibernationCoordinator {
    /// Records `claim` on a row as its own operation would on entry.
    /// Test-facing: the real claims are taken inside `performHibernate` and
    /// `wake`, which would also run what this test means to keep still.
    func holdForTesting(_ claim: InFlightClaim, terminalID: UUID) {
        switch claim {
        case .hibernate: hibernatesInFlight.insert(terminalID)
        case .wake: wakesInFlight.insert(terminalID)
        }
    }

    /// Drops a claim `holdForTesting` recorded.
    func releaseForTesting(_ claim: InFlightClaim, terminalID: UUID) {
        switch claim {
        case .hibernate: hibernatesInFlight.remove(terminalID)
        case .wake: wakesInFlight.remove(terminalID)
        }
    }
}

/// A router with one awake holder row behind it and a registry that has
/// adopted nothing.
private struct RouterHarness {
    let router: RPCRouter
    let db: TBDDatabase
    let registry: HolderRegistry
    let worktreeID: UUID
    let terminalID: UUID

    static func make() async throws -> RouterHarness {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/holder-attach-adopt", displayName: "holder-attach-adopt",
            defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "holder-attach-adopt", branch: "main",
            path: "/tmp/holder-attach-adopt", tmuxServer: "tbd-holder-attach-adopt")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "", tmuxPaneID: "", kind: .claude,
            transport: .holder, holderPID: 4242, childPID: 4243)
        router.controlMode = TmuxControlModeBridge(
            supervisor: TmuxControlSupervisor(), environment: [:], fdVending: FDVendingServer())
        let registry = HolderRegistry(
            owner: HolderOwnerToken(rawValue: "acme-installation"),
            environment: ["TBD_HOME": "/nonexistent/acme-tbd-home"],
            listTerminals: { [] })
        router.holderRegistry = registry
        // A live holder, so a refused attach stays an error rather than an
        // ended status — except where a test says otherwise.
        router.holderProcessIsLive = { _ in true }
        return RouterHarness(
            router: router, db: db, registry: registry, worktreeID: worktree.id,
            terminalID: terminal.id)
    }

    func attach() async throws -> RPCResponse {
        await router.handle(
            try RPCRequest(
                method: RPCMethod.attachRequest,
                params: AttachRequestParams(
                    worktreeID: worktreeID, paneID: "", windowID: "", attachID: UUID(),
                    terminalID: terminalID)))
    }
}

/// Holds every adoption that reaches the publish seam until the test lets it
/// through — a hand-over that never finishes, without a holder or a wall
/// clock. Suspends rather than blocking a thread, so nothing here can starve
/// the cooperative pool.
private actor PublishHold {
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

/// Set once by the task under test, read by the test's bounded poll.
private final class ReturnFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
