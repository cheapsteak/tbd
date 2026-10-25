import AppKit
import Clocks
import Darwin
import Foundation
import SwiftTerm
import TBDShared
import Testing

@testable import TBDApp
import TestSupport

/// A holder panel tries its attach again before it paints the placard.
///
/// Refusals cluster around daemon restarts and updates — a reader not adopted
/// yet, an attach still pending, a sidecar that was not connected — and every
/// one of them used to be final: the panel painted the placard on the first
/// and never asked again. These drive the real attach path through
/// `Coordinator.startHolderClient` with an injected `HolderAttaching` stub and
/// an injected clock, and assert what was asked, how often, and what the panel
/// ended up showing.
///
/// Tier 2: a real `TBDTerminalView` and the real reader thread over a
/// `socketpair`; no daemon. The backoff runs on `ImmediateClock` where only the
/// number of attempts matters, and on `EventDrivenTestClock` where the test
/// has to act while the panel is waiting.
@MainActor
@Suite("A holder panel retries a failed attach before it gives up", .fastPassBounded)
struct HolderAttachRetryTests {

    private static let generation: UInt64 = 5

    @MainActor
    private struct Fixture {
        let state: AppState
        let coordinator: TerminalPanelRepresentable.Coordinator
        let view: TBDTerminalView
        let stub: ScriptedHolderDaemon
        let retryOffers: Counter
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            coordinator.cleanup()
            defaults.removePersistentDomain(forName: suiteName)
        }

        /// Whether `message` was fed. Consumes the answer — ask once per message.
        func didFeed(_ message: String) -> Bool {
            !coordinator.shouldFeedPreparationMessage(message)
        }
    }

    @MainActor
    private final class Counter {
        var value = 0
    }

    private func makeFixture(
        clock: any Clock<Duration>, stub: ScriptedHolderDaemon,
        delays: [Duration] = HolderAttachRetry.delays
    ) -> Fixture {
        let worktreeID = UUID()
        let terminalID = UUID()
        let state = AppState()
        state.terminals[worktreeID] = [TBDShared.Terminal(
            id: terminalID, worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            label: "Shell", kind: .shell, transport: .holder)]
        let suiteName = "TBDAppTests.HolderAttachRetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 300),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
        let coordinator = TerminalPanelRepresentable.Coordinator(clock: clock)
        coordinator.appState = state
        coordinator.panelID = terminalID
        coordinator.terminalView = view
        coordinator.holderAttachClient = stub
        coordinator.holderAttachRetryDelays = delays
        let retryOffers = Counter()
        coordinator.onHolderAttachRetryOffered = { retryOffers.value += 1 }
        return Fixture(
            state: state, coordinator: coordinator, view: view, stub: stub,
            retryOffers: retryOffers, defaults: defaults, suiteName: suiteName)
    }

    private struct NoLiveReader: Error {}

    // MARK: - The policy

    @Test("only a definitive answer is final; every transient refusal is retried")
    func retryPolicy() {
        let definitive: [any Error] = [
            DaemonClientError.attachUnavailable(AttachRequestResult.holderSessionEndedStatus),
            DaemonClientError.attachUnavailable("unavailable"),
            HolderAttachError.missingGeneration,
            CancellationError(),
        ]
        for error in definitive {
            #expect(!HolderAttachRetry.isRetryable(error), "\(error) is a definitive answer")
        }
        // Permanent refusals get copy without Retry; cancellation is not one.
        for error in definitive.dropLast() {
            #expect(HolderAttachRetry.isPermanentRefusal(error), "\(error) cannot change on Retry")
        }
        #expect(!HolderAttachRetry.isPermanentRefusal(CancellationError()))
        let transient: [any Error] = [
            DaemonClientError.rpcError("attach failed: no live holder reader", code: nil),
            DaemonClientError.rpcError("attach failed: the fd sidecar is not connected", code: nil),
            DaemonClientError.rpcError("attach.ready refused: superseded", code: nil),
            DaemonClientError.daemonNotRunning,
            DaemonClientError.connectionFailed("refused"),
            DaemonClientError.receiveFailed("reset"),
            FDSidecarError.timedOut,
            FDSidecarError.disconnected,
            NoLiveReader(),
        ]
        for error in transient {
            #expect(HolderAttachRetry.isRetryable(error), "\(error) describes a moment, not the session")
        }
        // Bounded, and long enough to outlast a daemon restart.
        let total = HolderAttachRetry.delays.reduce(Duration.zero, +)
        #expect(total >= .seconds(10) && total <= .seconds(15), "total backoff \(total)")
        #expect(HolderAttachRetry.delays == HolderAttachRetry.delays.sorted(), "the backoff never shortens")
    }

    // MARK: - Retrying

    @Test("a transient refusal followed by success attaches without a placard")
    func transientRefusalThenSuccess() async throws {
        let pty = HolderTestPTY()
        defer { pty.closeFar() }
        let clock = EventDrivenTestClock()
        let attachment = pty.attachment(generation: Self.generation)
        let stub = ScriptedHolderDaemon(attach: { call in
            if call == 0 {
                throw DaemonClientError.rpcError("attach failed: no live holder reader", code: nil)
            }
            return attachment
        })
        let fixture = makeFixture(clock: clock, stub: stub)
        defer { fixture.tearDown() }

        let attaching = Task { @MainActor in
            await fixture.coordinator.startHolderClient(terminalView: fixture.view)
        }
        // The first wait is exactly the schedule's first step: advancing by it
        // must be what releases the second attempt.
        try await clock.requireAdvanceWhenArmed(
            by: HolderAttachRetry.delays[0], timeout: TestDeadlines.saturatedPass)
        await attaching.value

        #expect(stub.events == ["attach", "attach", "ready"], "\(stub.events)")
        #expect(!fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage),
                "an attach that succeeded on retry must not paint the placard")
        #expect(fixture.retryOffers.value == 0)
    }

    @Test("repeated refusals end in the placard once the attempts run out")
    func repeatedRefusalsEndInThePlacard() async throws {
        let stub = ScriptedHolderDaemon(attach: { _ in
            throw DaemonClientError.rpcError("attach failed: attached to a viewer", code: nil)
        })
        let fixture = makeFixture(clock: ImmediateClock<Duration>(), stub: stub)
        defer { fixture.tearDown() }

        await fixture.coordinator.startHolderClient(terminalView: fixture.view)

        #expect(stub.attaches == HolderAttachRetry.delays.count + 1,
                "one attempt, then one per scheduled wait, and no more: \(stub.attaches)")
        #expect(fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage),
                "an attach that never went through must say so")
        #expect(fixture.retryOffers.value == 1, "the placard's Retry must be offered once")
    }

    @Test("an ended session is not retried")
    func endedIsNotRetried() async throws {
        let stub = ScriptedHolderDaemon(attach: { _ in
            throw DaemonClientError.attachUnavailable(AttachRequestResult.holderSessionEndedStatus)
        })
        // An immediate clock: were "ended" retried, the attempts would show it.
        let fixture = makeFixture(clock: ImmediateClock<Duration>(), stub: stub)
        defer { fixture.tearDown() }

        await fixture.coordinator.startHolderClient(terminalView: fixture.view)

        #expect(stub.attaches == 1, "a session that has ended has nothing to retry against")
        #expect(fixture.didFeed(TerminalPreparationPresentation.holderSessionEndedMessage))
        #expect(fixture.retryOffers.value == 0)
    }

    @Test("an attempt whose ack failed is handed back before the next one asks")
    func aFailedAckIsReleasedBeforeTheRetry() async throws {
        let first = HolderTestPTY()
        let second = HolderTestPTY()
        defer { first.closeFar(); second.closeFar() }
        let firstAttachment = first.attachment(generation: Self.generation)
        let secondAttachment = second.attachment(generation: Self.generation)
        let stub = ScriptedHolderDaemon(
            attach: { call in call == 0 ? firstAttachment : secondAttachment },
            // The first ack never reaches the daemon; every later one does.
            ready: { call in
                if call == 0 { throw DaemonClientError.connectionFailed("refused") }
            })
        let fixture = makeFixture(clock: ImmediateClock<Duration>(), stub: stub)
        defer { fixture.tearDown() }

        await fixture.coordinator.startHolderClient(terminalView: fixture.view)

        #expect(stub.events == ["attach", "ready", "ready", "detach", "attach", "ready"], """
            the first attempt's attach must be released — acked again, then detached — before \
            the second attempt asks, or the daemon refuses it as pending or claimed: \
            \(stub.events)
            """)
        #expect(first.vendedIsClosed, "the first attempt's descriptor must be closed, not leaked")
        #expect(!fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage))
    }

    /// The release of an attach whose descriptor never arrived can still be
    /// resending when this panel runs out of retries. The panel must record
    /// that resend and wait for it, not paint the placard a moment before the
    /// claim it was refused for clears.
    @Test("a panel out of retries waits for its undelivered attach's release to finish resending")
    func aPanelWaitsForItsUndeliveredRelease() async throws {
        let gate = HolderTestGate()
        let claimCleared = HolderTestLatch()
        let releaseResend = Task {
            await gate.wait()
            claimCleared.set()
        }
        let pty = HolderTestPTY()
        defer { pty.closeFar() }
        let attachment = pty.attachment(generation: Self.generation)
        let stub = ScriptedHolderDaemon(attach: { call in
            if call == 0 {
                throw HolderAttachUndelivered(cause: FDSidecarError.timedOut, releaseResend: releaseResend)
            }
            guard claimCleared.isSet else {
                throw DaemonClientError.rpcError("attach failed: attached to a viewer", code: nil)
            }
            return attachment
        })
        // No retries: the release's resend is the only thing left to wait for.
        let fixture = makeFixture(clock: ImmediateClock<Duration>(), stub: stub, delays: [])
        defer { fixture.tearDown() }
        let ledger = fixture.state.holderHandbackLedger

        let attaching = Task { @MainActor in
            await fixture.coordinator.startHolderClient(terminalView: fixture.view)
        }
        try await waitFor("the panel to wait for its release's resend", observed: {
            "\(stub.attaches) attempts"
        }) {
            await MainActor.run { ledger.resendWaiters == 1 }
        }
        #expect(stub.attaches == 1)

        await gate.open()
        await attaching.value

        #expect(stub.events == ["attach", "attach", "ready"], "\(stub.events)")
        #expect(!fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage),
                "the claim cleared, so the panel must attach rather than paint the placard")
    }

    /// An attempt whose descriptor never arrives spends the client's timeout
    /// on top of the scheduled waits, so the schedule alone does not bound
    /// how long a panel stays blank. Each attempt here spends three seconds.
    @Test("no new attempt starts once the deadline has passed, however much of the schedule is left")
    func theDeadlineEndsTheRetries() async throws {
        let clock = EventDrivenTestClock()
        let stub = ScriptedHolderDaemon(attach: { _ in
            try await clock.sleep(for: .seconds(3))
            throw FDSidecarError.timedOut
        })
        let fixture = makeFixture(
            clock: clock, stub: stub, delays: [.seconds(1), .seconds(1), .seconds(1)])
        fixture.coordinator.holderAttachDeadline = .seconds(5)
        defer { fixture.tearDown() }
        let finished = Flag()

        let attaching = Task { @MainActor in
            await fixture.coordinator.startHolderClient(terminalView: fixture.view)
            finished.isSet = true
        }
        // The first attempt fails at 3 s; a retry at 4 s is inside the deadline.
        try await clock.requireAdvanceWhenArmed(by: .seconds(3), timeout: TestDeadlines.saturatedPass)
        try await clock.requireAdvanceWhenArmed(by: .seconds(1), timeout: TestDeadlines.saturatedPass)
        // The second fails at 7 s: a third would start at 8 s, past it.
        try await clock.requireAdvanceWhenArmed(by: .seconds(3), timeout: TestDeadlines.saturatedPass)
        let ended = try await waitFor("the panel to stop at the deadline") {
            await MainActor.run { finished.isSet }
        }
        if !ended { attaching.cancel() }  // unwedge a failing run
        await attaching.value

        #expect(stub.attaches == 2, "an attempt started past the deadline: \(stub.attaches)")
        #expect(fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage))
    }

    // MARK: - Stopping

    @Test("a teardown during the backoff ends the retries silently")
    func teardownDuringBackoffStops() async throws {
        let clock = EventDrivenTestClock()
        let stub = ScriptedHolderDaemon(attach: { _ in
            throw DaemonClientError.rpcError("attach failed: no live holder reader", code: nil)
        })
        let fixture = makeFixture(clock: clock, stub: stub)
        defer { fixture.tearDown() }

        let attaching = Task { @MainActor in
            await fixture.coordinator.startHolderClient(terminalView: fixture.view)
        }
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        fixture.coordinator.cleanup()
        await clock.advance(by: .seconds(60))
        await attaching.value

        #expect(stub.attaches == 1, "a torn-down panel must not ask again: \(stub.attaches)")
        #expect(!fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage),
                "a torn-down panel has nobody to show a placard to")
        #expect(fixture.retryOffers.value == 0)
    }

    /// `isConnected` can drop and come back inside one refresh without any
    /// panel being rebuilt. A retry loop that gave up on that would paint the
    /// placard over a healthy session; a real reconnect tears the panel down,
    /// and the teardown test above covers that.
    ///
    /// The connection is held down across one wake and restored across the
    /// next, so a loop that checked `isConnected` after its sleep stops at
    /// the first, and one that watched for the reconnect stops at the second.
    @Test("a flicker of the daemon connection during the backoff does not stop the retries")
    func aConnectionFlickerDoesNotStopTheRetries() async throws {
        let pty = HolderTestPTY()
        defer { pty.closeFar() }
        let clock = EventDrivenTestClock()
        let attachment = pty.attachment(generation: Self.generation)
        let stub = ScriptedHolderDaemon(attach: { call in
            if call < 2 { throw DaemonClientError.connectionFailed("refused") }
            return attachment
        })
        let fixture = makeFixture(clock: clock, stub: stub)
        defer { fixture.tearDown() }
        fixture.state.isConnected = true

        let attaching = Task { @MainActor in
            await fixture.coordinator.startHolderClient(terminalView: fixture.view)
        }
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        fixture.state.isConnected = false
        // Wakes with the connection down; must ask again, fail, and sleep.
        try await clock.requireAdvanceWhenArmed(
            by: HolderAttachRetry.delays[0], timeout: TestDeadlines.saturatedPass)
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        #expect(stub.attaches == 2, "the loop gave up while the connection was down: \(stub.events)")
        fixture.state.isConnected = true
        // Wakes after the connection came back; must ask again and attach.
        try await clock.requireAdvanceWhenArmed(
            by: HolderAttachRetry.delays[1], timeout: TestDeadlines.saturatedPass)
        await attaching.value

        #expect(stub.events == ["attach", "attach", "attach", "ready"],
                "the retry must survive a connection flicker: \(stub.events)")
        #expect(!fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage))
    }

    /// Only `cleanup()` cancels a panel's attach, so a cancelled backoff is
    /// a teardown: no further attempt, and no placard for nobody.
    @Test("a cancelled backoff ends the retries quietly, as a teardown")
    func aCancelledBackoffStops() async throws {
        let clock = EventDrivenTestClock()
        let stub = ScriptedHolderDaemon(attach: { _ in
            throw DaemonClientError.rpcError("attach failed: no live holder reader", code: nil)
        })
        let fixture = makeFixture(clock: clock, stub: stub)
        defer { fixture.tearDown() }

        let attaching = Task { @MainActor in
            await fixture.coordinator.startHolderClient(terminalView: fixture.view)
        }
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        attaching.cancel()
        await attaching.value

        #expect(stub.attaches == 1, "a cancelled wait must not be followed by another attempt")
        #expect(!fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage),
                "a cancelled attach is a torn-down panel, with nobody to show a placard to")
        #expect(fixture.retryOffers.value == 0)
    }

    @MainActor
    private final class Flag {
        var isSet = false
    }

    /// The retry loop sleeps holding its coordinator. `cleanup()` must cancel
    /// that sleep rather than leave it to run out: nothing advances the clock
    /// here, so the attach can end only if the teardown woke it.
    @Test("a teardown cancels the retry backoff instead of waiting it out")
    func teardownCancelsTheBackoff() async throws {
        let clock = EventDrivenTestClock()
        let stub = ScriptedHolderDaemon(attach: { _ in
            throw DaemonClientError.rpcError("attach failed: no live holder reader", code: nil)
        })
        let fixture = makeFixture(clock: clock, stub: stub)
        defer { fixture.tearDown() }
        let finished = Flag()

        // Through the production entry point, which is where the attach task
        // `cleanup()` cancels is started.
        let attaching = Task { @MainActor in
            await fixture.coordinator.startTmuxClient(
                terminalView: fixture.view, bridge: fixture.state.tmuxBridge,
                server: "", windowID: "", panelID: fixture.coordinator.panelID)
            finished.isSet = true
        }
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        fixture.coordinator.cleanup()

        let ended = try await waitFor("the attach to end on teardown, with no advance") {
            await MainActor.run { finished.isSet }
        }
        if !ended { await clock.advance(by: .seconds(60)) }  // unwedge a failing run
        await attaching.value

        #expect(stub.attaches == 1, "a torn-down panel must not ask again")
        #expect(!fixture.didFeed(TerminalPreparationPresentation.holderAttachFailedMessage))
    }
}
