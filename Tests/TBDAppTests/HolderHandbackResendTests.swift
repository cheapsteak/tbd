import AppKit
import Clocks
import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// A holder handback that never reached the daemon is sent again, in the
/// background, a bounded number of times.
///
/// A lost `pane.detach` leaves the session's viewer claim standing, and while
/// this app lives nothing else clears it: every later attach is refused as
/// owned by a viewer. The resends carry on across reconnects, but only for a
/// generation at or above `AttachRequestResult.uniqueGenerationFloor`: a
/// daemon that mints those starts each process at a random base, so such a
/// generation names no claim in any other daemon, which answers a detach for
/// it with success and an `attach.ready` for it with a refusal — both answers,
/// neither sent again. A generation below the floor came from an older daemon
/// whose count restarts at 1, and is sent once.
///
/// Tier 1 for the resends (an in-process stub and an injected clock); tier 2
/// for the panel tests, which run the real reader over a `socketpair`.
@MainActor
@Suite("A holder handback lost in transit is resent in the background", .fastPassBounded)
struct HolderHandbackResendTests {

    // `nonisolated`: the stubs' scripts read these off the main actor.
    /// At or above the floor: the generation every resend in this suite
    /// relies on.
    nonisolated private static let generation: UInt64 = AttachRequestResult.uniqueGenerationFloor + 9
    /// A generation an older daemon, counting from 1, would mint.
    nonisolated private static let legacyGeneration: UInt64 = 9
    /// A request that never reached the daemon.
    nonisolated private static let lost = DaemonClientError.connectionFailed("refused")

    private func handBack(
        _ daemon: ScriptedHolderDaemon, generation: UInt64 = HolderHandbackResendTests.generation
    ) async -> Task<Void, Never>? {
        await daemon.detachResendingInBackground(
            worktreeID: UUID(), paneID: "", terminalID: UUID(), generation: generation,
            snapshotPreamble: Data())
    }

    private func release(
        _ daemon: ScriptedHolderDaemon, generation: UInt64 = HolderHandbackResendTests.generation
    ) async -> Task<Void, Never>? {
        await daemon.releaseUnconfirmedAttach(
            worktreeID: UUID(), paneID: "", terminalID: UUID(), generation: generation,
            kind: "abandoned")
    }

    // MARK: - The generation floor

    @Test("a lost handback whose generation is at or above the floor is resent")
    func aHandbackAtTheFloorIsResent() async throws {
        let daemon = ScriptedHolderDaemon(detach: { call in if call == 0 { throw Self.lost } })

        let resending = try #require(await handBack(
            daemon, generation: AttachRequestResult.uniqueGenerationFloor))
        await resending.value

        #expect(daemon.detaches == 2, "the floor itself is a unique generation: \(daemon.detaches)")
    }

    /// An older daemon numbers its attaches from 1 in every process, so a
    /// resend that reached its successor could hand back a claim another
    /// attach holds under the same number. Such a generation gets the one
    /// attempt it always had, and no background task is started for it.
    @Test("a lost handback whose generation is below the floor is attempted once and never resent")
    func aHandbackBelowTheFloorIsNotResent() async {
        for generation in [Self.legacyGeneration, AttachRequestResult.uniqueGenerationFloor - 1] {
            let daemon = ScriptedHolderDaemon(detach: { _ in throw Self.lost })

            #expect(await handBack(daemon, generation: generation) == nil,
                    "generation \(generation) started a resend")
            #expect(daemon.detaches == 1, "generation \(generation) was resent: \(daemon.detaches)")
        }
    }

    @Test("the release of an unconfirmed attach is resent above the floor and sent once below it")
    func aReleaseFollowsTheFloor() async {
        func lostBoth() -> ScriptedHolderDaemon {
            ScriptedHolderDaemon(
                ready: { call in if call == 0 { throw DaemonClientError.sendFailed("short send") } },
                detach: { call in if call == 0 { throw Self.lost } })
        }

        let unique = lostBoth()
        await release(unique)?.value
        #expect(unique.events == ["ready", "detach", "ready", "detach"],
                "a unique generation's lost release must be resent: \(unique.events)")

        let legacy = lostBoth()
        #expect(await release(legacy, generation: Self.legacyGeneration) == nil,
                "a legacy generation's release started a resend")
        #expect(legacy.events == ["ready", "detach"],
                "a legacy generation's release must be sent once: \(legacy.events)")
    }

    // MARK: - The handback

    @Test("a handback lost in transit is resent until it lands")
    func aLostHandbackIsResent() async throws {
        let daemon = ScriptedHolderDaemon(detach: { call in if call < 2 { throw Self.lost } })

        let resending = try #require(await handBack(daemon), "a lost handback must be resent")
        await resending.value

        #expect(daemon.detaches == 3, "two lost copies, then the one that landed: \(daemon.detaches)")
    }

    @Test("a handback returns after its first attempt and resends in the background")
    func theHandbackReturnsBeforeItsResends() async throws {
        let clock = EventDrivenTestClock()
        let daemon = ScriptedHolderDaemon(
            detach: { call in if call == 0 { throw DaemonClientError.daemonNotRunning } },
            clock: clock)

        let resending = try #require(await handBack(daemon))
        // Back already, with only the first copy sent: whoever held the ledger
        // for this handback is free to settle it now.
        #expect(daemon.detaches == 1)

        try await clock.requireAdvanceWhenArmed(
            by: HolderAttachRetry.handbackResendDelays[0], timeout: TestDeadlines.saturatedPass)
        await resending.value
        #expect(daemon.detaches == 2)
    }

    @Test("a handback the daemon answered is not resent, whatever it answered")
    func anAnsweredHandbackIsNotResent() async {
        let accepted = ScriptedHolderDaemon()
        #expect(await handBack(accepted) == nil)
        #expect(accepted.detaches == 1)

        // Any RPC error is an answer — the daemon was reached.
        let refused = ScriptedHolderDaemon(detach: { _ in
            throw DaemonClientError.rpcError("malformed request", code: nil)
        })
        #expect(await handBack(refused) == nil)
        #expect(refused.detaches == 1)
    }

    @Test("the resends are bounded by the client's own schedule")
    func theResendsAreBounded() async throws {
        // Two waits, not the default's five: the schedule is the client's.
        let schedule: [Duration] = [.milliseconds(10), .milliseconds(20)]
        let daemon = ScriptedHolderDaemon(detach: { _ in throw Self.lost }, resendDelays: schedule)

        let resending = try #require(await handBack(daemon))
        await resending.value

        #expect(daemon.detaches == schedule.count + 1, "\(daemon.detaches)")
    }

    /// A successor refused while this handback's claim stands is retrying on
    /// the attach schedule, so the resends usually land inside it. Time in
    /// transit is not counted here; the successor's wait for a resend still
    /// going covers that (`aSuccessorWaitsOutASlowResend`).
    @Test("the handback resend schedule is shorter than the attach retry budget")
    func theResendsFinishInsideTheAttachBudget() {
        let resends = HolderAttachRetry.handbackResendDelays.reduce(Duration.zero, +)
        let attach = HolderAttachRetry.delays.reduce(Duration.zero, +)
        #expect(resends + .seconds(2) <= attach, "resends take \(resends) against \(attach)")
    }

    @Test("a cancelled resend sends nothing more")
    func aCancelledResendStops() async throws {
        let clock = EventDrivenTestClock()
        let daemon = ScriptedHolderDaemon(
            detach: { _ in throw DaemonClientError.daemonNotRunning }, clock: clock)

        let resending = try #require(await handBack(daemon))
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        resending.cancel()
        await resending.value

        #expect(daemon.detaches == 1, "a cancelled wait must not be followed by a resend")
    }

    // MARK: - The release of an unconfirmed attach

    @Test("a release whose requests both got answers resends nothing")
    func anAnsweredReleaseResendsNothing() async {
        // The ack refused — the daemon never minted this generation, or has
        // settled it — and the detach accepted, which it does either way.
        let daemon = ScriptedHolderDaemon(ready: { _ in
            throw DaemonClientError.rpcError("attach.ready refused: superseded", code: nil)
        })

        #expect(await release(daemon) == nil, "a refused ack is an answer, not a reason to resend")
        #expect(daemon.events == ["ready", "detach"])
    }

    @Test("a release whose ack was lost resends the ack, then detaches again")
    func aLostReleaseAckIsResentThenDetached() async throws {
        let daemon = ScriptedHolderDaemon(ready: { call in
            if call == 0 { throw DaemonClientError.sendFailed("short send") }
        })

        let resending = try #require(await release(daemon))
        await resending.value

        #expect(daemon.events == ["ready", "detach", "ready", "detach"], """
            an ack that never arrived can leave the attach pending, and the daemon's ready \
            timeout turns that into a claim after the first detach went by — so the ack is \
            resent and a fresh detach follows it: \(daemon.events)
            """)
    }

    @Test("a release whose resent ack is refused still detaches")
    func aRefusedResentAckStillDetaches() async throws {
        let daemon = ScriptedHolderDaemon(ready: { call in
            if call == 0 { throw DaemonClientError.receiveFailed("reset") }
            throw DaemonClientError.rpcError("attach.ready refused: superseded", code: nil)
        })

        let resending = try #require(await release(daemon))
        await resending.value

        #expect(daemon.events == ["ready", "detach", "ready", "detach"],
                "a refused ack has reached the daemon, so the detach must follow it: \(daemon.events)")
    }

    @Test("a release whose detach was lost resends only the detach")
    func aLostReleaseDetachIsResent() async throws {
        let daemon = ScriptedHolderDaemon(detach: { call in if call == 0 { throw Self.lost } })

        let resending = try #require(await release(daemon))
        await resending.value

        #expect(daemon.events == ["ready", "detach", "detach"], "\(daemon.events)")
    }

    // MARK: - Through the panel

    /// One holder session in an `AppState`, and the panels a test builds on
    /// it — a predecessor and a successor share its ledger, as production
    /// panels do.
    @MainActor
    private final class Session {
        let state: AppState
        let terminalID: UUID
        private let defaults: UserDefaults
        private let suiteName: String

        init() {
            let name = "TBDAppTests.HolderHandbackResend.\(UUID().uuidString)"
            let suite = UserDefaults(suiteName: name)!
            let terminalID = UUID()
            let worktreeID = UUID()
            let state = AppState(userDefaults: suite)
            state.terminals[worktreeID] = [TBDShared.Terminal(
                id: terminalID, worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
                label: "Shell", kind: .shell, transport: .holder)]
            self.suiteName = name
            self.defaults = suite
            self.terminalID = terminalID
            self.state = state
        }

        var ledger: HolderHandbackLedger { state.holderHandbackLedger }

        func panel(
            clock: EventDrivenTestClock, client: any HolderAttaching
        ) -> (coordinator: TerminalPanelRepresentable.Coordinator, view: TBDTerminalView) {
            let view = TBDTerminalView(
                frame: CGRect(x: 0, y: 0, width: 600, height: 300),
                font: TBDTerminalView.defaultMonospaceFont,
                appearance: AppearanceSettings(defaults: defaults))
            let coordinator = TerminalPanelRepresentable.Coordinator(clock: clock)
            coordinator.appState = state
            coordinator.panelID = terminalID
            coordinator.terminalView = view
            view.terminalDelegate = coordinator
            coordinator.holderAttachClient = client
            return (coordinator, view)
        }

        func tearDown() { defaults.removePersistentDomain(forName: suiteName) }
    }

    /// Counts on the main actor, where the panel's callbacks run.
    @MainActor
    private final class Counter {
        var value = 0
    }

    /// The successor's daemon: refuses the attach until `claimCleared`.
    private static func successorDaemon(
        claimCleared: HolderTestLatch, attachment: HolderAttachment
    ) -> ScriptedHolderDaemon {
        ScriptedHolderDaemon(attach: { _ in
            guard claimCleared.isSet else {
                throw DaemonClientError.rpcError("attach failed: attached to a viewer", code: nil)
            }
            return attachment
        })
    }

    @Test("a panel's lost handback settles the ledger after one attempt and is resent behind it")
    func aPanelSettlesItsLedgerBeforeTheResend() async throws {
        let session = Session()
        defer { session.tearDown() }
        let pty = HolderTestPTY()
        defer { pty.closeFar() }
        let clock = EventDrivenTestClock()
        let attachment = pty.attachment(generation: Self.generation)
        let daemon = ScriptedHolderDaemon(
            attach: { _ in attachment },
            detach: { call in if call == 0 { throw Self.lost } },
            clock: clock)
        let panel = session.panel(clock: clock, client: daemon)

        await panel.coordinator.startHolderClient(terminalView: panel.view)
        #expect(daemon.events == ["attach", "ready"], "the attach must be live first: \(daemon.events)")

        panel.coordinator.cleanup()
        // The ledger settles on the first attempt: a successor waits for the
        // panel to be off the descriptor and for one detach, not for a resend
        // schedule that can run for seconds. The resend is recorded instead.
        let ledger = session.ledger
        let terminalID = session.terminalID
        try await waitFor("the handback's ledger entry to settle", observed: { "\(daemon.events)" }) {
            await MainActor.run { !ledger.isInFlight(terminalID: terminalID) }
        }
        #expect(daemon.detaches == 1, "the ledger waited out a resend: \(daemon.events)")
        #expect(ledger.isResending(terminalID: terminalID),
                "a successor about to give up must be able to see the resend still going")

        try await clock.requireAdvanceWhenArmed(
            by: HolderAttachRetry.handbackResendDelays[0], timeout: TestDeadlines.saturatedPass)
        try await waitFor("the handback to be resent", observed: { "\(daemon.events)" }) {
            daemon.detaches >= 2
        }
        #expect(daemon.detaches == 2, "one lost copy, then the resend that landed: \(daemon.events)")
    }

    /// The window the short resend schedule exists for: a predecessor whose
    /// handback was lost in transit settles its ledger at once and resends in
    /// the background, while its successor is refused and retries. The claim
    /// clears on the last resend, and the successor must still be retrying
    /// then.
    ///
    /// Each panel waits on a clock of its own, and the test steps the two
    /// along one timeline built from their schedules — an attempt before a
    /// resend on a tie, the order that would lose the race — so the
    /// successor's last attempt comes after the clearing resend or the test
    /// fails.
    @Test("a successor whose claim clears on the predecessor's last resend still attaches")
    func aSuccessorSeesTheLastResend() async throws {
        let resendSchedule: [Duration] = [.milliseconds(500), .seconds(1)]
        let attachSchedule: [Duration] = [.seconds(1), .seconds(2)]
        let session = Session()
        defer { session.tearDown() }
        let claimCleared = HolderTestLatch()
        let first = HolderTestPTY()
        let second = HolderTestPTY()
        defer { first.closeFar(); second.closeFar() }
        let predecessorClock = EventDrivenTestClock()
        let successorClock = EventDrivenTestClock()
        let firstAttachment = first.attachment(generation: Self.generation)
        let predecessorDaemon = ScriptedHolderDaemon(
            attach: { _ in firstAttachment },
            // The first copy and every resend but the last are lost.
            detach: { call in
                guard call == resendSchedule.count else { throw Self.lost }
                claimCleared.set()
            },
            resendDelays: resendSchedule, clock: predecessorClock)
        let successorDaemon = Self.successorDaemon(
            claimCleared: claimCleared, attachment: second.attachment(generation: Self.generation + 1))
        let predecessor = session.panel(clock: predecessorClock, client: predecessorDaemon)
        let successor = session.panel(clock: successorClock, client: successorDaemon)
        successor.coordinator.holderAttachRetryDelays = attachSchedule
        defer { successor.coordinator.cleanup() }
        let successorPlacards = Counter()
        successor.coordinator.onHolderAttachRetryOffered = { successorPlacards.value += 1 }

        await predecessor.coordinator.startHolderClient(terminalView: predecessor.view)
        #expect(predecessorDaemon.events == ["attach", "ready"])
        predecessor.coordinator.cleanup()
        let attaching = Task { @MainActor in
            await successor.coordinator.startHolderClient(terminalView: successor.view)
        }
        try await waitFor("the successor's first attempt") { successorDaemon.attaches == 1 }

        func offsets(_ schedule: [Duration]) -> [Duration] {
            var total = Duration.zero
            return schedule.map { total += $0; return total }
        }
        let timeline = (offsets(resendSchedule).map { (at: $0, isResend: true) }
            + offsets(attachSchedule).map { (at: $0, isResend: false) })
            .sorted { $0.at != $1.at ? $0.at < $1.at : !$0.isResend }
        var predecessorNow = Duration.zero
        var successorNow = Duration.zero
        var resends = 0
        var attempts = 1
        for event in timeline {
            if event.isResend {
                try await predecessorClock.requireAdvanceWhenArmed(
                    by: event.at - predecessorNow, timeout: TestDeadlines.saturatedPass)
                predecessorNow = event.at
                resends += 1
                let expected = resends + 1
                try await waitFor("resend \(resends)") { predecessorDaemon.detaches == expected }
            } else {
                let attachedBefore = claimCleared.isSet
                try await successorClock.requireAdvanceWhenArmed(
                    by: event.at - successorNow, timeout: TestDeadlines.saturatedPass)
                successorNow = event.at
                attempts += 1
                let expected = attempts
                try await waitFor("attempt \(attempts)") { successorDaemon.attaches == expected }
                if attachedBefore { break }
            }
        }
        await attaching.value

        #expect(successorDaemon.readies == 1, """
            the successor gave up before the predecessor's last resend cleared the claim: \
            \(successorDaemon.attaches) attempts, claim cleared \(claimCleared.isSet)
            """)
        #expect(successorPlacards.value == 0, "a successor that attached must not show the placard")
    }

    /// Each failed resend spends time in transit as well as its scheduled
    /// wait, so the schedules alone cannot promise the last resend lands while
    /// a successor is still retrying. Here it plainly does not: the one resend
    /// is still in flight when the successor's retries run out. The successor
    /// must wait for it, and ask once more when it has cleared the claim.
    @Test("a successor out of retries waits out a resend still going, then attaches")
    func aSuccessorWaitsOutASlowResend() async throws {
        let session = Session()
        defer { session.tearDown() }
        let claimCleared = HolderTestLatch()
        let gate = HolderTestGate()
        let first = HolderTestPTY()
        let second = HolderTestPTY()
        defer { first.closeFar(); second.closeFar() }
        let predecessorClock = EventDrivenTestClock()
        let successorClock = EventDrivenTestClock()
        let firstAttachment = first.attachment(generation: Self.generation)
        let predecessorDaemon = ScriptedHolderDaemon(
            attach: { _ in firstAttachment },
            // The first copy is lost; the one resend is slow, and lands.
            detach: { call in
                if call == 0 { throw Self.lost }
                await gate.wait()
                claimCleared.set()
            },
            resendDelays: [.milliseconds(500)], clock: predecessorClock)
        let successorDaemon = Self.successorDaemon(
            claimCleared: claimCleared, attachment: second.attachment(generation: Self.generation + 1))
        let predecessor = session.panel(clock: predecessorClock, client: predecessorDaemon)
        let successor = session.panel(clock: successorClock, client: successorDaemon)
        successor.coordinator.holderAttachRetryDelays = [.seconds(1)]
        defer { successor.coordinator.cleanup() }
        let successorPlacards = Counter()
        successor.coordinator.onHolderAttachRetryOffered = { successorPlacards.value += 1 }
        let ledger = session.ledger

        await predecessor.coordinator.startHolderClient(terminalView: predecessor.view)
        predecessor.coordinator.cleanup()
        let attaching = Task { @MainActor in
            await successor.coordinator.startHolderClient(terminalView: successor.view)
        }
        try await waitFor("the successor's first attempt") { successorDaemon.attaches == 1 }

        // The resend goes out, and hangs in transit.
        try await predecessorClock.requireAdvanceWhenArmed(
            by: .milliseconds(500), timeout: TestDeadlines.saturatedPass)
        try await waitFor("the resend to be in flight") { predecessorDaemon.detaches == 2 }
        // The successor's last retry is refused, with the resend still going.
        try await successorClock.requireAdvanceWhenArmed(
            by: .seconds(1), timeout: TestDeadlines.saturatedPass)
        try await waitFor("the successor to wait for the resend", observed: {
            "\(successorDaemon.attaches) attempts"
        }) {
            await MainActor.run { ledger.resendWaiters == 1 }
        }
        #expect(successorDaemon.attaches == 2)

        await gate.open()
        await attaching.value

        #expect(successorDaemon.attaches == 3, "the successor must ask once more after the resend")
        #expect(successorDaemon.readies == 1, "the claim cleared, so the successor must attach")
        #expect(successorPlacards.value == 0, "a successor that attached must not show the placard")
    }

    // MARK: - The held set

    /// Raised on the main actor, where the waits it records run.
    @MainActor
    private final class Flag {
        var isSet = false
    }

    /// A terminal leaves the held set only once its handback has ended, so a
    /// claim sweep acts only on a handback that was truly lost and the orderly
    /// path keeps its screen. Two shapes: a detach that stalls in transit, and
    /// one that is lost and resent.
    @Test("a panel's terminal stays held until its handback has ended, resends and all")
    func thePanelHoldsUntilItsHandbackEnds() async throws {
        let session = Session()
        defer { session.tearDown() }
        let ledger = session.ledger
        let terminalID = session.terminalID

        // A detach that stalls: held until it answers.
        do {
            let pty = HolderTestPTY()
            defer { pty.closeFar() }
            let gate = HolderTestGate()
            let attachment = pty.attachment(generation: Self.generation)
            let daemon = ScriptedHolderDaemon(
                attach: { _ in attachment },
                detach: { _ in await gate.wait() })
            let panel = session.panel(clock: EventDrivenTestClock(), client: daemon)

            await panel.coordinator.startHolderClient(terminalView: panel.view)
            #expect(daemon.events == ["attach", "ready"], "the attach must be live first: \(daemon.events)")
            #expect(ledger.isHeld(terminalID), "a live attach must be held")

            panel.coordinator.cleanup()
            try await waitFor("the handback's detach to be in flight", observed: { "\(daemon.events)" }) {
                daemon.detaches == 1
            }
            #expect(ledger.isHeld(terminalID), "the hold ended while the handback's detach was unanswered")

            await gate.open()
            try await waitFor("the hold to end with the handback", observed: { "\(daemon.events)" }) {
                await MainActor.run { !ledger.isHeld(terminalID) }
            }
        }

        // A detach lost in transit: held until the last resend ends.
        do {
            let pty = HolderTestPTY()
            defer { pty.closeFar() }
            let clock = EventDrivenTestClock()
            let attachment = pty.attachment(generation: Self.generation + 1)
            let daemon = ScriptedHolderDaemon(
                attach: { _ in attachment },
                detach: { call in if call < 2 { throw Self.lost } },
                clock: clock)
            let panel = session.panel(clock: clock, client: daemon)

            await panel.coordinator.startHolderClient(terminalView: panel.view)
            #expect(daemon.events == ["attach", "ready"], "the attach must be live first: \(daemon.events)")

            panel.coordinator.cleanup()
            try await waitFor("the handback's first pass to settle", observed: { "\(daemon.events)" }) {
                await MainActor.run { !ledger.isInFlight(terminalID: terminalID) }
            }
            #expect(daemon.detaches == 1, "\(daemon.events)")
            #expect(ledger.isHeld(terminalID), "the hold ended with a first pass that left a resend owed")

            try await clock.requireAdvanceWhenArmed(
                by: HolderAttachRetry.handbackResendDelays[0], timeout: TestDeadlines.saturatedPass)
            try await waitFor("the first resend", observed: { "\(daemon.events)" }) {
                daemon.detaches == 2
            }
            #expect(ledger.isHeld(terminalID), "the hold ended while the resends were still going")

            try await clock.requireAdvanceWhenArmed(
                by: HolderAttachRetry.handbackResendDelays[1], timeout: TestDeadlines.saturatedPass)
            try await waitFor("the hold to end with the last resend", observed: { "\(daemon.events)" }) {
                await MainActor.run { !ledger.isHeld(terminalID) }
            }
            #expect(daemon.detaches == 3, "two lost copies, then the resend that landed: \(daemon.events)")
        }
    }

    /// The teardown-during-ack race: `cleanup()` reaches the handback with the
    /// attach not recorded yet — the ack is still pending — so the handback
    /// returns early with the reader stopped but not yet closed. That early
    /// return must keep the hold. Whichever way the ack then goes, the hold
    /// ends with the hand-back that ack leads to: the abandoned attach's
    /// release when it fails, the live handback when it succeeds.
    @Test("a teardown during the ack keeps the hold until the ack's outcome is handed back",
          arguments: [false, true])
    func aTeardownDuringTheAckKeepsTheHold(ackSucceeds: Bool) async throws {
        let session = Session()
        defer { session.tearDown() }
        let pty = HolderTestPTY()
        defer { pty.closeFar() }
        let ackGate = HolderTestGate()
        let detachGate = HolderTestGate()
        let attachment = pty.attachment(generation: Self.generation)
        let daemon = ScriptedHolderDaemon(
            attach: { _ in attachment },
            ready: { call in
                // Later acks are the abandoned attach's release, answered at once.
                guard call == 0 else { return }
                await ackGate.wait()
                if !ackSucceeds { throw Self.lost }
            },
            detach: { _ in await detachGate.wait() })
        let panel = session.panel(clock: EventDrivenTestClock(), client: daemon)
        let ledger = session.ledger
        let terminalID = session.terminalID

        let attaching = Task { @MainActor in
            await panel.coordinator.startHolderClient(terminalView: panel.view)
        }
        try await waitFor("the ack to be in flight", observed: { "\(daemon.events)" }) {
            daemon.readies == 1
        }
        panel.coordinator.cleanup()
        #expect(ledger.isHeld(terminalID),
                "the teardown ended the hold of an attach whose ack was still pending")

        await ackGate.open()
        await attaching.value
        try await waitFor("the attach to be handed back", observed: { "\(daemon.events)" }) {
            daemon.detaches == 1
        }
        let expected = ackSucceeds
            ? ["attach", "ready", "detach"]
            : ["attach", "ready", "ready", "detach"]
        #expect(daemon.events == expected, "\(daemon.events)")
        #expect(ledger.isHeld(terminalID), "the hold ended before the hand-back had an answer")

        await detachGate.open()
        try await waitFor("the hold to end with the hand-back", observed: { "\(daemon.events)" }) {
            await MainActor.run { !ledger.isHeld(terminalID) }
        }
    }

    /// The ledger's own contract: a successor waits for a predecessor's first
    /// pass, never its resends. The resend carries the hold instead, so the
    /// terminal stays held after the successor's wait has ended.
    @Test("a successor's wait ends after the handback's first pass, with the terminal held until the resend ends")
    func successorsDoNotWaitForResends() async throws {
        let session = Session()
        defer { session.tearDown() }
        let pty = HolderTestPTY()
        defer { pty.closeFar() }
        let clock = EventDrivenTestClock()
        let attachment = pty.attachment(generation: Self.generation)
        let daemon = ScriptedHolderDaemon(
            attach: { _ in attachment },
            detach: { call in if call == 0 { throw Self.lost } },
            clock: clock)
        let panel = session.panel(clock: clock, client: daemon)
        let ledger = session.ledger
        let terminalID = session.terminalID

        await panel.coordinator.startHolderClient(terminalView: panel.view)
        panel.coordinator.cleanup()
        // What a successor does before it asks. Nothing advances the clock
        // until this has ended, so a wait that took in the resend never would.
        let waited = Flag()
        let successorWait = Task { @MainActor in
            await ledger.awaitSettled(terminalID: terminalID)
            waited.isSet = true
        }
        try await waitFor("a successor's wait to end after the handback's first pass", observed: {
            "\(daemon.events)"
        }) {
            await MainActor.run { waited.isSet }
        }
        #expect(daemon.detaches == 1, "\(daemon.events)")
        #expect(ledger.isResending(terminalID: terminalID))
        #expect(ledger.isHeld(terminalID), "the hold ended with a first pass that left a resend owed")

        try await clock.requireAdvanceWhenArmed(
            by: HolderAttachRetry.handbackResendDelays[0], timeout: TestDeadlines.saturatedPass)
        try await waitFor("the hold to end with the resend", observed: { "\(daemon.events)" }) {
            await MainActor.run { !ledger.isHeld(terminalID) }
        }
        #expect(daemon.detaches == 2, "\(daemon.events)")
        await successorWait.value
    }
}
